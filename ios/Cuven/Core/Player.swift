import AVKit
import AVFoundation
import UIKit
import os

/// 播放器状态日志：只记来源类型、状态与进度，不记片名与地址（Debug 构建另写一份进诊断文件，见 Perf）
private let playerLog = Logger(subsystem: "us.cuven.tv", category: "player")

private func plog(_ s: String, error: Bool = false) {
    if error { playerLog.error("\(s, privacy: .public)") } else { playerLog.info("\(s, privacy: .public)") }
    Perf.file("player: " + s)
}

/// 一次播放请求。剧集带上后面的几集（queue），播完自动接下一集
struct PlayRequest {
    var path: String
    var name: String
    var title: String
    var subtitle: String? = nil
    var artwork: String? = nil
    var seriesPath: String? = nil
    var episode: Int? = nil
    var queue: [PlayRequest] = []
}

enum PlayError: LocalizedError {
    /// 这个文件放不了。带着的是服务器给的技术原因：只记进诊断日志，不给人看
    case unsupported(String)
    var errorDescription: String? { "此视频的格式不受支持。" }
    var detail: String {
        switch self { case .unsupported(let m): return m }
    }
}

/// AVPlayerViewController 直接全屏呈现（系统播放器：音轨 / 字幕 / 画中画 / AirPlay / 杜比视界都是系统的）。
/// 点了「播放」就弹出来；从点下去到首帧出来，上面盖着和网页版一样的加载画面（PlayerLoadingOverlay：顶层窗口，用户要求）
final class CuvenPlayerViewController: AVPlayerViewController {
    var onClose: (() -> Void)?
    /// 方向（用户要求）：除了 iPhone 展开，一律横屏、只在左右两个横向之间转（VideoOrientation.swift）
    private lazy var orientation = VideoOrientationLock()
    /// iPhone Duo 半折（横着的折痕）时：上面画面、下面控制面板（用户要求；UI/PlayerTabletop.swift）
    private(set) lazy var tabletop = TabletopPlayerHost()

    /// 半折面板上的「锁定屏幕」：锁在按下时的方向，转动设备不跟着转（用户要求）。解开、点「全屏」、合上 / 摊平时回到原来的规则
    private var lockedOrientation: UIInterfaceOrientation? {
        didSet { if lockedOrientation != oldValue { setNeedsUpdateOfSupportedInterfaceOrientations() } }
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        if let o = lockedOrientation, let m = Self.mask(o) { return m }
        return orientation.mask
    }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { orientation.preferred }

    private static func mask(_ o: UIInterfaceOrientation) -> UIInterfaceOrientationMask? {
        switch o {
        case .portrait: .portrait
        case .portraitUpsideDown: .portraitUpsideDown
        case .landscapeLeft: .landscapeLeft
        case .landscapeRight: .landscapeRight
        default: nil
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tabletop.install(in: self) { on in plog("tabletop \(on ? "on" : "off")") }
        tabletop.model.onOrientationLock = { [weak self] on in
            guard let self else { return }
            self.lockedOrientation = on ? self.view.window?.windowScene?.effectiveGeometry.interfaceOrientation : nil
            plog("orientation lock \(on ? "on" : "off")")
        }
    }

    /// 片源挂上来：半折时画面交给面板那一层（这一层不接），别的时候照常
    func attach(_ p: AVPlayer) {
        tabletop.model.player = p
        if !tabletop.model.active { player = p }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        tabletop.keepOnTop()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        tabletop.model.visible = true
    }

    override func viewWillTransition(to size: CGSize, with coordinator: any UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        orientation.refresh(self, after: coordinator)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        tabletop.model.visible = false
        if isBeingDismissed || presentingViewController == nil { onClose?() }
    }
}

// 加载画面（PlayerLoadingOverlay）在 UI/PlayerLoading.swift：和网页版一样的极光 + Cuven max + 胶囊进度条 + 提示，顶层窗口

@MainActor
final class PlayerCoordinator: NSObject, AVPlayerViewControllerDelegate {
    static let shared = PlayerCoordinator()
    /// 账户与设置里的「自动播放下一集」
    nonisolated static let autoplayKey = "autoplay_next"
    private var autoplayNext: Bool { UserDefaults.standard.object(forKey: Self.autoplayKey) as? Bool ?? true }

    private var player: AVPlayer?
    private var controller: CuvenPlayerViewController?
    private var current: PlayRequest?
    /// 播到了片尾的那一部（收起时据此问要不要移除预处理数据）
    private var endedPath: String?
    private var timeObserver: Any?
    private var itemObservers: [NSObjectProtocol] = []
    private var statusObservation: NSKeyValueObservation?
    private var controlObservation: NSKeyValueObservation?
    private var pendingSeek: Double?
    private var inPiP = false
    private weak var model: AppModel?
    /// 每次点播放 / 换集加一：片源准备好之前用户关掉了、或者又点了别的，旧的结果作废
    private var loadToken = 0
    /// 起播计时（诊断用）：从点下去算起
    private var tapAt = Date()
    private var startedPlaying = false
    private var lastWaitReason: String?
    /// 正片用掉的流量（账户页「流量概览」的「视频播放」）：每 5 秒看一眼访问日志，换片 / 播完 / 关掉时结清
    private let usage = UsageTap(.video)
    /// 账户页「首选音轨 · 自然」：这一集的原声语种（手上的），和手上的不是 TMDB 给的时候重新问的那一次（和取片源同时开始）
    private var audioOrigin: TrackPrefs.Origin?
    private var originRefresh: Task<TrackPrefs.Origin?, Never>?
    /// 这一集按首选项挑好的字幕和音轨（「可以播了」「开播了」时拿它对一遍，被系统的自动选择改掉了就改回来）
    private var trackPicks: TrackPrefs.Picks?
    /// 这一集的片源走的是 Cuven Pass Pro 的加速节点
    private var sourceViaPass = false
    /// 这一集已经从加速节点改走过普通线路（只改一次）
    private var passFallbackTried = false
    /// 改进兼容性（Compat.swift）：这一集的 HLS 经本机代理改标记再给播放器。设置里开着就一开始用；
    /// 没开的、起播就失败（不是网络错）的，自动开一次再试
    private var compatActive = false
    /// 这一集的片源是 HLS / 走的是预先缓存的本机代理
    private var sourceIsHLS = false
    private var sourcePrecached = false

    func play(_ req: PlayRequest, model: AppModel) {
        self.model = model
        if DemoData.enabled { alert("演示模式", "演示模式下无法播放。"); return }
        Haptics.success()
        plog("tap")
        PlayerLoadingOverlay.shared.onClose = { [weak self] in self?.cancelLoading() }
        presentPlayer(req)
        begin(req)
    }

    /// 加载画面上点了关闭：收起加载画面和播放器（播放器收起时走 closedByUser）
    private func cancelLoading() {
        plog("cancelled while loading")
        PlayerLoadingOverlay.shared.hide()
        if let vc = controller, vc.presentingViewController != nil, !inPiP {
            vc.dismiss(animated: true)
        } else {
            closedByUser()
        }
    }

    /// 开始准备一集（新点的，或者播完接着的下一集）
    private func begin(_ req: PlayRequest) {
        tapAt = Date()
        endedPath = nil
        startedPlaying = false
        lastWaitReason = nil
        loadToken += 1
        let token = loadToken
        passFallbackTried = false
        compatActive = Compat.isOn
        audioOrigin = nil
        originRefresh = nil
        if TrackPrefs.audio == .natural, let model {
            let o = model.audioOrigin(name: req.name, seriesPath: req.seriesPath)
            audioOrigin = o.origin
            if !o.settled {
                originRefresh = Task { await model.refreshAudioOrigin(name: req.name, seriesPath: req.seriesPath) }
            }
        }
        // 加载画面盖上（播完接下一集也盖：同一个样子）
        PlayerLoadingOverlay.shared.show(title: coverTitle(req))
        // 半折时的控制面板：片名、「下一集」、下面那块（简介 / InSight / 继续观看 / 推荐）跟着换
        controller?.tabletop.show(req)
        configurePanel(req)
        Task { await start(req, token: token) }
    }

    /// 半折面板下面那块的内容和按钮（PlayerPanelData）：简介、演员、继续观看、推荐；剧集的分集标题和简介晚一点补上
    private func configurePanel(_ req: PlayRequest) {
        guard let vm = controller?.tabletop.model, let model else { return }
        let info = PlayerPanelData.info(for: req, model: model)
        vm.info = info
        vm.continueItems = PlayerPanelData.continueItems(excluding: req, model: model)
        vm.recommendations = PlayerPanelData.recommendations(for: req, model: model)
        vm.watchlisted = Set(model.watchlist.items.map(\.key))
        vm.deckTab = .continueWatching
        let route = PlayerPanelData.route(for: req, model: model)
        vm.onGoToShow = { [weak self, weak model] in
            guard let route else { return }
            self?.goToShow(route, model: model)
        }
        vm.onPlayItem = { [weak self, weak model] item in
            guard let self, let model, let e = model.playback.entry(item.id) else { return }
            plog("panel continue watching")
            self.resume(e, model: model)
        }
        vm.onOpenRecommendation = { [weak self, weak model] item in
            guard let self, let model, let v = model.video(path: item.id) else { return }
            plog("panel recommendation")
            self.play(PlayRequest(path: v.path, name: v.name, title: model.title(v), artwork: model.backgroundArtString(v)),
                      model: model)
        }
        vm.onToggleWatchlist = { [weak model, weak vm] item in
            guard let model, let key = item.watchKey else { return }
            model.watchlist.toggle(key, kind: .movie)
            vm?.watchlisted = Set(model.watchlist.items.map(\.key))
        }
        let token = loadToken
        Task { [weak self, weak model] in
            guard let model, let better = await PlayerPanelData.refine(info, for: req, model: model) else { return }
            guard let self, self.loadToken == token else { return }
            self.controller?.tabletop.model.info = better
        }
    }

    /// 「前往节目」：收起播放器，推进这一部的详情页
    private func goToShow(_ route: Route, model: AppModel?) {
        plog("go to show")
        if let vc = controller, vc.presentingViewController != nil {
            vc.dismiss(animated: true) { model?.openRequest = route }
        } else {
            model?.openRequest = route
        }
    }

    /// 接着放「继续观看」里的一部（主页那一排、半折面板下面那块都用）：剧集接着放这一集，后面的几集排进队列
    func resume(_ e: WatchEntry, model: AppModel) {
        if let sp = e.seriesPath, model.series.contains(where: { $0.path == sp }) {
            Task {
                let files = (try? await APIClient.shared.episodes(seriesPath: sp)) ?? []
                let sorted = files.sorted { ($0.ep ?? 0) < ($1.ep ?? 0) }
                let idx = sorted.firstIndex { $0.path == e.path }
                let queue = idx.map { Array(sorted[($0 + 1)...]) } ?? []
                let title = e.title
                play(PlayRequest(path: e.path, name: e.name, title: title, subtitle: e.subtitle, artwork: e.artwork,
                                 seriesPath: sp, episode: e.episode,
                                 queue: queue.map { f in
                                     PlayRequest(path: f.path, name: f.name, title: title,
                                                 subtitle: f.ep.map { "第 \($0) 集" }, artwork: e.artwork,
                                                 seriesPath: sp, episode: f.ep)
                                 }), model: model)
            }
        } else {
            play(PlayRequest(path: e.path, name: e.name, title: e.title, subtitle: e.subtitle, artwork: e.artwork), model: model)
        }
    }

    private func start(_ req: PlayRequest, token: Int) async {
        do {
            let url = try await resolve(req)
            guard token == loadToken, controller != nil || inPiP else { plog("source ready after close, dropped"); return }
            show(url, req)
        } catch {
            guard token == loadToken else { return }
            plog("resolve failed\((error as? PlayError).map { ": " + $0.detail } ?? "")", error: true)
            closeThenAlert("无法播放", (error as? PlayError)?.errorDescription ?? PlayerErrorText.message(error) ?? FriendlyError.message(error))
        }
    }

    /// 片源：后端给了 HLS（MKV 实时重封装）就走 HLS —— 先看 info.json：能放才放，4xx 带着原因报错；
    /// 其余走直链（MP4 / MOV 带 safari=1）
    /// direct：不走 Cuven Pass Pro（加速节点出错后改走普通线路）
    private func resolve(_ req: PlayRequest, direct: Bool = false) async throws -> URL {
        let t0 = Date()
        let sign = try? await APIClient.shared.streamSign(path: req.path)
        // Cuven Pass Pro：影片走加速节点（开着、节点能用时）；签名、资料照旧直连 Worker
        let route: (base: String, viaPass: Bool)
        if direct { route = (APIClient.base, false) } else { route = await PassPro.shared.mediaBase() }
        sourceViaPass = route.viaPass
        sourceIsHLS = false
        sourcePrecached = false
        plog("sign \(sign == nil ? "failed" : "ok") in \(Perf.ms(since: t0)) ms\(route.viaPass ? ", via pass pro" : "")")
        PlayerLoadingOverlay.shared.stage(.source)
        let isMKV = req.name.lowercased().hasSuffix(".mkv")
        if let hls = sign?.hls, !hls.isEmpty, let master = URL(string: route.base + hls) {
            let info = master.deletingLastPathComponent().appendingPathComponent("info.json")
            let t1 = Date()
            let (status, body) = await APIClient.shared.hlsInfo(info)
            // 视频格式也记下（编码、动态范围、尺寸、杜比视界档位；不含片名与地址）：放不了的时候知道是哪种格式
            plog("source hls, info.json \(status) in \(Perf.ms(since: t1)) ms\(body?.video.map { " (\($0.summary))" } ?? "")")
            // 半折面板的光影：HDR / 杜比视界的片子不取画面的帧（见 VideoFrameProcessor）
            controller?.tabletop.updateRange(from: body?.video)
            PlayerLoadingOverlay.shared.stage(.meta)
            if (200..<300).contains(status) && body?.ok != false { return await compatible(await precached(req, master) ?? master) }
            if status >= 400 && status < 500 && status != 404 {
                throw PlayError.unsupported(body?.error ?? "这个文件转不了 HLS（HTTP \(status)）")
            }
            if isMKV { return await compatible(await precached(req, master) ?? master) }   // info.json 没取到（网络抖动）：让播放器自己试
        }
        if isMKV { throw PlayError.unsupported("服务器没有为这个 MKV 提供 HLS，iPhone 无法直接播放 MKV") }
        plog("source direct")
        return APIClient.shared.streamURL(path: req.path, name: req.name, sign: sign, base: route.base)
    }

    /// 这部片有弱网预先缓存（详情页「预先画面质量处理」）：从本机代理放——下好的从本机出、没有的边取边存，并接着往后缓存
    private func precached(_ req: PlayRequest, _ master: URL) async -> URL? {
        guard let local = await Precache.shared.playbackURL(path: req.path, upstreamMaster: master) else { return nil }
        plog("source precache")
        sourcePrecached = true
        return local
    }

    /// HLS 主列表：「改进兼容性」开着就换成本机代理改过标记的那一份（Compat.swift）
    private func compatible(_ master: URL) async -> URL {
        sourceIsHLS = true
        guard compatActive, let u = await PrecacheServer.shared.compatURL(master: master) else { return master }
        plog("source compat")
        return u
    }

    /// 点了就弹：系统播放器先出来（加载封面在上面），片源准备好再挂上
    private func presentPlayer(_ req: PlayRequest) {
        if controller?.presentingViewController != nil || inPiP { return }
        let p = player ?? AVPlayer()
        p.automaticallyWaitsToMinimizeStalling = true
        p.allowsExternalPlayback = true
        player = p
        observePlayer(p)
        let vc = CuvenPlayerViewController()
        vc.player = p
        vc.allowsPictureInPicturePlayback = true
        vc.canStartPictureInPictureAutomaticallyFromInline = true
        vc.updatesNowPlayingInfoCenter = true
        vc.entersFullScreenWhenPlaybackBegins = false
        vc.exitsFullScreenWhenPlaybackEnds = false
        vc.delegate = self
        vc.modalPresentationStyle = .fullScreen
        vc.onClose = { [weak self] in self?.closedByUser() }
        vc.tabletop.model.player = p
        vc.tabletop.model.onNext = { [weak self] in self?.playNext() }
        controller = vc
        plog("present")
        NotificationCenter.default.post(name: .cuvenPlayerPresented, object: nil)
        UIApplication.topViewController()?.present(vc, animated: true)
    }

    private func show(_ url: URL, _ req: PlayRequest) {
        saveProgress()
        detachItem()
        current = req

        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        item.externalMetadata = metadata(req)
        // 账户页「网络速度」：往前缓冲多少秒（100% 交给系统；80% → 90 秒）。改了从下一个片源起生效。
        // 从本机代理放（预先缓存）：缓冲交给系统——下好的那截从本机读，不费流量
        let proxied = url.host == "127.0.0.1"
        item.preferredForwardBufferDuration = sourcePrecached ? 0 : NetworkSpeed.forwardBuffer()
        // 账户页「首选音轨 / 首选字幕」：和播放器读播放列表同时进行，通常赶在首帧之前挑好并选上（「自动」也选：
        // 字幕打开服务器标成默认的那条、音轨是片源默认的那条，不交给系统按手机语言挑；TrackPrefs.swift）。
        // 「自然」带上这一集的原声语种
        let origin = audioOrigin, refresh = originRefresh
        let picks = TrackPrefs.Picks()
        trackPicks = picks
        Task { @MainActor in
            await TrackPrefs.apply(to: item, picks: picks, origin: origin, refresh: refresh)
            plog("tracks: \(picks.summary)")
        }

        if player == nil || (controller?.presentingViewController == nil && !inPiP) {
            presentPlayer(req)                       // 兜底：没弹出来（比如当时找不到能弹的页面）就现在弹
            controller?.tabletop.show(req)
            configurePanel(req)
        }
        guard let p = player else { return }
        // 本机代理的地址只在这台手机上有效：这时不投屏到别的设备（AirPlay 那头取不到 127.0.0.1）
        p.allowsExternalPlayback = !proxied
        pendingSeek = model?.playback.resumePosition(req.path)
        usage.flush(item)                            // 旧片源最后那一截先结清
        p.replaceCurrentItem(with: item)
        observe(item)
        controller?.attach(p)
        PlayerLoadingOverlay.shared.stage(.data)
        plog("attach after \(Perf.ms(since: tapAt)) ms")
        if pendingSeek == nil { p.play() }
    }

    private func coverTitle(_ req: PlayRequest) -> String {
        guard let s = req.subtitle, !s.isEmpty else { return req.title }
        return "\(req.title) · \(s)"
    }

    private func metadata(_ req: PlayRequest) -> [AVMetadataItem] {
        func item(_ id: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
            let m = AVMutableMetadataItem()
            m.identifier = id
            m.value = value as NSString
            m.extendedLanguageTag = "und"
            return m
        }
        var out = [item(.commonIdentifierTitle, req.title)]
        if let s = req.subtitle, !s.isEmpty { out.append(item(.iTunesMetadataTrackSubTitle, s)) }
        return out
    }

    /// 播放器级别：真正开播（首帧）收起加载封面；等待的原因记进诊断
    private func observePlayer(_ p: AVPlayer) {
        controlObservation = p.observe(\.timeControlStatus, options: [.new]) { [weak self] pl, _ in
            Task { @MainActor [weak self] in self?.controlChanged(pl) }
        }
        if timeObserver == nil {
            timeObserver = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 5, preferredTimescale: 1), queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.saveProgress()
                    self?.meterUsage()
                }
            }
        }
    }

    /// 正片流量：看一眼当前片源收到了多少（时间回调本来就是 5 秒一次；节流放宽到 4 秒，免得抖一下就隔一次）
    private func meterUsage() {
        usage.sample(player?.currentItem, every: 4)
    }

    private func controlChanged(_ p: AVPlayer) {
        guard p === player, p.currentItem != nil else { return }
        switch p.timeControlStatus {
        case .playing:
            lastWaitReason = nil
            if !startedPlaying {
                startedPlaying = true
                plog("playing after \(Perf.ms(since: tapAt)) ms")
                reassertTracks(p.currentItem, at: "playing")
                PlayerLoadingOverlay.shared.finish()
            }
        case .waitingToPlayAtSpecifiedRate:
            let r = p.reasonForWaitingToPlay?.rawValue ?? "-"
            if r != lastWaitReason {
                lastWaitReason = r
                plog("waiting: \(r.replacingOccurrences(of: "AVPlayerWaiting", with: "").replacingOccurrences(of: "Reason", with: ""))")
            }
        default:
            break
        }
    }

    /// 首选的字幕和音轨：片源「可以播了」、真正开播这两个时刻再对一遍。系统的自动选择（按手机语言挑音轨、只开强制字幕）
    /// 可能在片源准备好时又改一遍，被改掉了就改回来。开播以后人在播放器里手动换的不再动
    private func reassertTracks(_ item: AVPlayerItem?, at moment: String) {
        guard let item, item === player?.currentItem, let picks = trackPicks else { return }
        if TrackPrefs.reassert(picks, on: item) { plog("tracks re-applied at \(moment): \(picks.summary)") }
    }

    private func observe(_ item: AVPlayerItem) {
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] it, _ in
            Task { @MainActor [weak self] in self?.statusChanged(it) }
        }
        let nc = NotificationCenter.default
        itemObservers = [
            nc.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.finished() }
            },
            nc.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] note in
                let err = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
                Task { @MainActor [weak self] in self?.interrupted(err) }
            },
            nc.addObserver(forName: .AVPlayerItemPlaybackStalled, object: item, queue: .main) { _ in
                Task { @MainActor in plog("stalled") }
            },
            nc.addObserver(forName: .AVPlayerItemNewErrorLogEntry, object: item, queue: .main) { [weak item] _ in
                // 只记错误域与状态码（errorComment 可能带地址，不记）
                let e = item?.errorLog()?.events.last
                let line = "errorlog \(e?.errorDomain ?? "-") \(e?.errorStatusCode ?? 0)"
                Task { @MainActor in plog(line) }
            },
        ]
    }

    private func statusChanged(_ item: AVPlayerItem) {
        guard item === player?.currentItem else { return }
        switch item.status {
        case .readyToPlay:
            let d = item.duration.seconds
            plog("ready after \(Perf.ms(since: tapAt)) ms, duration \(d.isFinite ? Int(d) : -1)")
            PlayerLoadingOverlay.shared.stage(.ready)
            reassertTracks(item, at: "ready")
            if let s = pendingSeek {
                pendingSeek = nil
                player?.seek(to: CMTime(seconds: s, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: CMTime(seconds: 1, preferredTimescale: 600)) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.player?.play() }
                }
            }
        case .failed:
            let msg = "此视频暂时无法播放，请稍后再试。"
            let code = (item.error as NSError?).map { "\($0.domain) \($0.code)" } ?? "-"
            // 底下那一层错误、播放器错误日志的最后一条（只记域和代码：说明文字里可能带着地址）
            let under = ((item.error as NSError?)?.userInfo[NSUnderlyingErrorKey] as? NSError).map { " ← \($0.domain) \($0.code)" } ?? ""
            let last = item.errorLog()?.events.last.map { " · log \($0.errorDomain) \($0.errorStatusCode)" } ?? ""
            plog("failed: \(code)\(under)\(last)", error: true)
            if fallBackToCompat(item.error) { return }
            if fallBackFromPass("failed") { return }
            closeThenAlert("播放失败", PlayerErrorText.message(item.error) ?? msg)
        default:
            break
        }
    }

    /// 播到一半断了（网络断、片源出错）：关掉播放器，说一声
    private func interrupted(_ err: NSError?) {
        plog("interrupted: \(err.map { "\($0.domain) \($0.code)" } ?? "-")", error: true)
        if fallBackFromPass("interrupted") { return }
        saveProgress()
        closeThenAlert("播放中断", PlayerErrorText.message(err) ?? "播放进度已保存，稍后可以继续观看。")
    }

    /// 起播就失败、不是网络错、这一集还没按兼容方式试过：按「改进兼容性」的方式再试一次（旧机型照着片源的标记拒播）
    private func fallBackToCompat(_ err: Error?) -> Bool {
        guard !compatActive, !startedPlaying, sourceIsHLS, let req = current else { return false }
        if let e = err as NSError?, e.domain == NSURLErrorDomain { return false }
        compatActive = true
        plog("start failed, retrying with compat signaling")
        let token = loadToken
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let url = try await self.resolve(req, direct: self.passFallbackTried)
                guard token == self.loadToken, self.controller != nil || self.inPiP else { return }
                self.show(url, req)
            } catch {
                guard token == self.loadToken else { return }
                self.closeThenAlert("无法播放", (error as? PlayError)?.errorDescription ?? PlayerErrorText.message(error) ?? FriendlyError.message(error))
            }
        }
        return true
    }

    /// Cuven Pass Pro 的加速节点出错（起播失败、播到一半断了）：节点 10 分钟内不再用，这一集从当前位置改走普通线路接着放。
    /// 每集只改一次；改了以后还出错，照常报错
    private func fallBackFromPass(_ why: String) -> Bool {
        guard sourceViaPass, !passFallbackTried, let req = current else { return false }
        passFallbackTried = true
        PassPro.shared.markDown()
        plog("pass pro \(why), switching to the direct route")
        let token = loadToken
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let url = try await self.resolve(req, direct: true)
                guard token == self.loadToken, self.controller != nil || self.inPiP else { return }
                self.show(url, req)          // show 先存下当前进度，新片源从这里接着放
            } catch {
                guard token == self.loadToken else { return }
                self.closeThenAlert("无法播放", (error as? PlayError)?.errorDescription ?? PlayerErrorText.message(error) ?? FriendlyError.message(error))
            }
        }
        return true
    }

    private func saveProgress() {
        guard let req = current, let p = player, let item = p.currentItem else { return }
        let pos = p.currentTime().seconds
        let dur = item.duration.seconds
        plog(String(format: "time %.0f / %.0f, rate %.2f, buffer %@", pos.isFinite ? pos : -1, dur.isFinite ? dur : -1, p.rate,
                    item.isPlaybackLikelyToKeepUp ? "ok" : "low"))
        guard pos.isFinite, dur.isFinite, dur > 0, pos > 1 else { return }
        model?.playback.update(WatchEntry(path: req.path, name: req.name, title: req.title, subtitle: req.subtitle, artwork: req.artwork,
                                          position: pos, duration: dur, updated: Date(), seriesPath: req.seriesPath, episode: req.episode))
    }

    /// 播完：清掉进度；剧集接着放下一集（播放器不关，盖上加载封面），电影关掉播放器
    private func finished() {
        guard let req = current else { return }
        plog("ended")
        usage.flush(player?.currentItem)
        model?.playback.finish(req.path)
        if autoplayNext, var next = req.queue.first {
            next.queue = Array(req.queue.dropFirst())
            begin(next)
        } else {
            endedPath = req.path
            controller?.dismiss(animated: true)
        }
    }

    /// 半折面板上的「下一集」：这一集的进度照常存着（没看完不清），接着放下一集（播放器不关，盖上加载画面）
    private func playNext() {
        guard let req = current, var next = req.queue.first else { return }
        plog("next by user")
        saveProgress()
        usage.flush(player?.currentItem)
        next.queue = Array(req.queue.dropFirst())
        begin(next)
    }

    private func closedByUser() {
        guard !inPiP else { return }
        plog("closed")
        // 看完了（播到片尾，或者看到 97% 以后自己关掉）：先记下是哪一部，收拾完再问要不要移除预处理数据
        let watched = watchedThrough()
        PlayerLoadingOverlay.shared.hide()
        loadToken += 1
        saveProgress()
        player?.pause()
        detachItem()
        if let t = timeObserver { player?.removeTimeObserver(t) }
        timeObserver = nil
        controlObservation?.invalidate()
        controlObservation = nil
        usage.flush(nil)
        player?.replaceCurrentItem(with: nil)
        player = nil
        controller = nil
        current = nil
        NotificationCenter.default.post(name: .cuvenPlayerClosed, object: nil)
        if let watched { askRemovePrecache(path: watched.path, title: watched.title) }
    }

    /// 这一部算不算看完了：播到了片尾，或者真的放起来以后、看过 97% 才自己关掉。
    /// 出错被关掉的（closing）不算：那时候已经有一个出错的提示要弹
    private func watchedThrough() -> (path: String, title: String)? {
        guard let req = current, !closing else { return nil }
        if endedPath == req.path { return (req.path, req.title) }
        guard startedPlaying, let p = player, let item = p.currentItem else { return nil }
        let pos = p.currentTime().seconds, dur = item.duration.seconds
        guard pos.isFinite, dur.isFinite, dur > 0, pos / dur > 0.97 else { return nil }
        return (req.path, req.title)
    }

    /// 用户要求：看完以后，这一部有预处理数据（弱网预先缓存、下载）就问要不要移除，腾出空间。
    /// 等播放器收起来再问；「保留」什么都不动
    private func askRemovePrecache(path: String, title: String) {
        guard let it = Precache.shared.item(path: path), it.bytes > 0 else { return }
        let size = ByteCountFormatter.string(fromByteCount: it.bytes, countStyle: .file)
        plog("ask to remove precache")
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            // 这半秒里又开始放别的了、或者已经有别的提示在屏上：不问了
            guard let self, self.controller == nil, !self.inPiP,
                  Precache.shared.item(path: path) != nil,
                  let top = UIApplication.topViewController(), !(top is UIAlertController) else { return }
            let a = UIAlertController(title: "移除预处理数据？",
                                      message: "《\(title)》已看完。移除后可释放 \(size) 空间，再看时会从网络播放。",
                                      preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "保留", style: .cancel))
            a.addAction(UIAlertAction(title: "移除", style: .destructive) { _ in
                Task { @MainActor in
                    Precache.shared.delete(path: path)
                    Haptics.success()
                }
            })
            top.present(a, animated: true)
        }
    }

    private func detachItem() {
        statusObservation?.invalidate()
        statusObservation = nil
        for o in itemObservers { NotificationCenter.default.removeObserver(o) }
        itemObservers = []
    }

    // MARK: 半折面板自己的画中画（CuvenPlayerView 那一层画面；系统播放器的画中画在下面）

    /// 开始：收起播放器回到 App，画面在画中画里接着放（收起时不当作「关掉」）
    func panelPictureInPictureWillStart() {
        inPiP = true
        plog("panel pip start")
        if let vc = controller, vc.presentingViewController != nil { vc.dismiss(animated: true) }
    }

    /// 结束：点了「还原」的话播放器已经弹回来了；直接关掉画中画的，收拾干净
    func panelPictureInPictureDidStop() {
        inPiP = false
        plog("panel pip stop")
        if controller?.presentingViewController == nil { closedByUser() }
    }

    /// 画中画里点了「还原」：把播放器弹回来
    func panelPictureInPictureRestore(_ completion: @escaping (Bool) -> Void) {
        if let vc = controller, vc.presentingViewController == nil, let top = UIApplication.topViewController() {
            top.present(vc, animated: true) { completion(true) }
        } else {
            completion(true)
        }
    }

    // MARK: 画中画

    nonisolated func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
        Task { @MainActor in self.inPiP = true }
    }

    nonisolated func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
        Task { @MainActor in
            self.inPiP = false
            if self.controller?.presentingViewController == nil { self.closedByUser() }
        }
    }

    nonisolated func playerViewController(_ playerViewController: AVPlayerViewController,
                                          restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        Task { @MainActor in
            if let vc = self.controller, vc.presentingViewController == nil, let top = UIApplication.topViewController() {
                top.present(vc, animated: true) { completionHandler(true) }
            } else {
                completionHandler(true)
            }
        }
    }

    // MARK: 提示

    /// 播放器还在屏上时先把它关掉、关完再弹提示 —— 直接弹会撞上正在收起的播放器，提示根本出不来。
    /// 同一次出错可能同时来两个信号（状态 failed + 播放中断通知）：只提示一次
    private var closing = false
    private func closeThenAlert(_ title: String, _ message: String) {
        PlayerLoadingOverlay.shared.hide()
        guard !closing else { return }
        if let vc = controller, vc.presentingViewController != nil, !inPiP {
            closing = true
            vc.dismiss(animated: true) { [weak self] in
                self?.closing = false
                self?.alert(title, message)
            }
        } else {
            alert(title, message)
        }
    }

    private func alert(_ title: String, _ message: String) {
        Haptics.error()
        let a = UIAlertController(title: title, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "好", style: .default))
        UIApplication.topViewController()?.present(a, animated: true)
    }
}

extension UIApplication {
    @MainActor
    static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let window = scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first
        var vc = window?.rootViewController
        while let p = vc?.presentedViewController, !p.isBeingDismissed { vc = p }
        return vc
    }
}

enum Haptics {
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "haptics") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "haptics") }
    }

    @MainActor static func light() { guard enabled else { return }; UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    @MainActor static func selection() { guard enabled else { return }; UISelectionFeedbackGenerator().selectionChanged() }
    @MainActor static func success() { guard enabled else { return }; UINotificationFeedbackGenerator().notificationOccurred(.success) }
    @MainActor static func error() { guard enabled else { return }; UINotificationFeedbackGenerator().notificationOccurred(.error) }
}

extension Notification.Name {
    /// 播放器盖上来 / 关掉：资料库那段静音预告片跟着停 / 接着放
    static let cuvenPlayerPresented = Notification.Name("cuven.player.presented")
    static let cuvenPlayerClosed = Notification.Name("cuven.player.closed")
}

/// 放不了的时候给人看的话（F87：说清楚哪里不行、该怎么办）。常见的几种按错误码说；认不出来的返回 nil，用系统的说明。
/// 系统的说明常常只有一句「无法完成操作」：比如 CI 的模拟器上 4K HDR（HEVC 10 bit、PQ）的片子报 AVFoundation -11868
///（没有这块屏幕放得了的码流），外接显示器、隔空播放到不支持 HDR 的电视上也是这一个
enum PlayerErrorText {
    static func message(_ error: Error?) -> String? {
        guard let e = error as NSError? else { return nil }
        // 外面一层常常是笼统的 AVFoundation 错误，真正的原因（网络断了、超时）在底下那一层
        for x in [e, e.userInfo[NSUnderlyingErrorKey] as? NSError].compactMap({ $0 }) {
            if x.domain == AVFoundationErrorDomain, let code = AVError.Code(rawValue: x.code) {
                switch code {
                case .noCompatibleAlternatesForExternalDisplay:
                    return "当前显示屏不支持这部影片的画面格式（4K 或 HDR）。请断开外接显示器或隔空播放后再试。"
                case .decoderNotFound, .decodeFailed, .undecodableMediaData, .fileFormatNotRecognized:
                    return "这台设备不支持这部影片的视频格式。"
                default:
                    break
                }
            }
            if x.domain == NSURLErrorDomain {
                switch x.code {
                case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
                    return "网络连接已断开。请连接网络后再试。"
                case NSURLErrorTimedOut:
                    return "连接超时。请稍后再试。"
                default:
                    break
                }
            }
        }
        return nil
    }
}
