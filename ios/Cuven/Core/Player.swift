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
    case unsupported(String)
    var errorDescription: String? {
        switch self { case .unsupported(let m): return m }
    }
}

/// AVPlayerViewController 直接全屏呈现（系统播放器：音轨 / 字幕 / 画中画 / AirPlay / 杜比视界都是系统的）。
/// 点了「播放」就弹出来，片源还在准备时盖一层加载封面（剧照 + 片名 + 状态），真正开播才淡出
final class CuvenPlayerViewController: AVPlayerViewController {
    var onClose: (() -> Void)?
    private let cover = PlayerLoadingCover()

    override func viewDidLoad() {
        super.viewDidLoad()
        if let host = contentOverlayView {
            cover.frame = host.bounds
            cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            host.addSubview(cover)
        }
    }

    /// preparing：片源准备中（自己转圈）；buffering：片源已挂上、等首帧（系统播放器自己会转圈，这里只留封面和字）；
    /// playing：淡出
    enum Phase { case preparing, buffering, playing }

    func setPhase(_ phase: Phase) {
        loadViewIfNeeded()
        cover.setPhase(phase)
    }

    func configureCover(title: String, artwork: URL?) {
        loadViewIfNeeded()
        cover.configure(title: title, artwork: artwork)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil { onClose?() }
    }
}

/// 加载封面：剧照铺满压暗、居中片名 + 状态；不拦触摸（关闭钮等系统控件照常能点）
final class PlayerLoadingCover: UIView {
    private let art = UIImageView()
    private let shade = UIView()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let titleLabel = UILabel()
    private let statusLabel = UILabel()
    private var artTask: Task<Void, Never>?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isUserInteractionEnabled = false
        art.contentMode = .scaleAspectFill
        art.clipsToBounds = true
        art.alpha = 0
        shade.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        for v in [art, shade] {
            v.frame = bounds
            v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(v)
        }
        spinner.color = .white
        spinner.hidesWhenStopped = true
        titleLabel.font = .systemFont(ofSize: 22, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 2
        statusLabel.font = .systemFont(ofSize: 14, weight: .medium)
        statusLabel.textColor = UIColor.white.withAlphaComponent(0.7)
        statusLabel.textAlignment = .center
        let stack = UIStackView(arrangedSubviews: [spinner, titleLabel, statusLabel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8
        stack.setCustomSpacing(20, after: spinner)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -32),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(title: String, artwork: URL?) {
        titleLabel.text = title
        artTask?.cancel()
        art.image = nil
        art.alpha = 0
        guard let artwork else { return }
        artTask = Task { @MainActor [weak self] in
            let img = await ImagePipeline.shared.image(artwork, maxPixel: 1400)
            guard let self, !Task.isCancelled, let img else { return }
            self.art.image = img
            UIView.animate(withDuration: 0.3) { self.art.alpha = 1 }
        }
    }

    func setPhase(_ phase: CuvenPlayerViewController.Phase) {
        switch phase {
        case .preparing:
            statusLabel.text = "正在准备片源…"
            spinner.startAnimating()
            alpha = 1
        case .buffering:
            statusLabel.text = "正在缓冲…"
            spinner.stopAnimating()
            alpha = 1
        case .playing:
            spinner.stopAnimating()
            UIView.animate(withDuration: 0.35) { self.alpha = 0 }
        }
    }
}

@MainActor
final class PlayerCoordinator: NSObject, AVPlayerViewControllerDelegate {
    static let shared = PlayerCoordinator()
    /// 账户与设置里的「自动播放下一集」
    nonisolated static let autoplayKey = "autoplay_next"
    private var autoplayNext: Bool { UserDefaults.standard.object(forKey: Self.autoplayKey) as? Bool ?? true }

    private var player: AVPlayer?
    private var controller: CuvenPlayerViewController?
    private var current: PlayRequest?
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

    func play(_ req: PlayRequest, model: AppModel) {
        self.model = model
        if DemoData.enabled { alert("演示模式", "演示数据没有片源，不能播放。"); return }
        Haptics.success()
        plog("tap")
        presentPlayer(req)
        begin(req)
    }

    /// 开始准备一集（新点的，或者播完接着的下一集）
    private func begin(_ req: PlayRequest) {
        tapAt = Date()
        startedPlaying = false
        lastWaitReason = nil
        loadToken += 1
        let token = loadToken
        controller?.configureCover(title: coverTitle(req), artwork: TMDBImage.url(req.artwork, "w1280"))
        controller?.setPhase(.preparing)
        Task { await start(req, token: token) }
    }

    private func start(_ req: PlayRequest, token: Int) async {
        do {
            let url = try await resolve(req)
            guard token == loadToken, controller != nil || inPiP else { plog("source ready after close, dropped"); return }
            show(url, req)
        } catch {
            guard token == loadToken else { return }
            plog("resolve failed", error: true)
            closeThenAlert("无法播放", error.localizedDescription)
        }
    }

    /// 片源：后端给了 HLS（MKV 实时重封装）就走 HLS —— 先看 info.json：能放才放，4xx 带着原因报错；
    /// 其余走直链（MP4 / MOV 带 safari=1）
    private func resolve(_ req: PlayRequest) async throws -> URL {
        let t0 = Date()
        let sign = try? await APIClient.shared.streamSign(path: req.path)
        plog("sign \(sign == nil ? "failed" : "ok") in \(Perf.ms(since: t0)) ms")
        let isMKV = req.name.lowercased().hasSuffix(".mkv")
        if let hls = sign?.hls, !hls.isEmpty, let master = URL(string: APIClient.base + hls) {
            let info = master.deletingLastPathComponent().appendingPathComponent("info.json")
            let t1 = Date()
            let (status, body) = await APIClient.shared.hlsInfo(info)
            plog("source hls, info.json \(status) in \(Perf.ms(since: t1)) ms")
            if (200..<300).contains(status) && body?.ok != false { return master }
            if status >= 400 && status < 500 && status != 404 {
                throw PlayError.unsupported(body?.error ?? "这个文件转不了 HLS（HTTP \(status)）")
            }
            if isMKV { return master }            // info.json 没取到（网络抖动）：让播放器自己试
        }
        if isMKV { throw PlayError.unsupported("服务器没有为这个 MKV 提供 HLS，iPhone 无法直接播放 MKV") }
        plog("source direct")
        return APIClient.shared.streamURL(path: req.path, name: req.name, sign: sign)
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

        if player == nil || (controller?.presentingViewController == nil && !inPiP) {
            presentPlayer(req)                       // 兜底：没弹出来（比如当时找不到能弹的页面）就现在弹
            controller?.configureCover(title: coverTitle(req), artwork: TMDBImage.url(req.artwork, "w1280"))
        }
        guard let p = player else { return }
        pendingSeek = model?.playback.resumePosition(req.path)
        p.replaceCurrentItem(with: item)
        observe(item)
        controller?.player = p
        controller?.setPhase(.buffering)
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
                Task { @MainActor [weak self] in self?.saveProgress() }
            }
        }
    }

    private func controlChanged(_ p: AVPlayer) {
        guard p === player, p.currentItem != nil else { return }
        switch p.timeControlStatus {
        case .playing:
            lastWaitReason = nil
            if !startedPlaying {
                startedPlaying = true
                plog("playing after \(Perf.ms(since: tapAt)) ms")
                controller?.setPhase(.playing)
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
            if let s = pendingSeek {
                pendingSeek = nil
                player?.seek(to: CMTime(seconds: s, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: CMTime(seconds: 1, preferredTimescale: 600)) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.player?.play() }
                }
            }
        case .failed:
            let msg = item.error?.localizedDescription ?? "未知错误"
            let code = (item.error as NSError?).map { "\($0.domain) \($0.code)" } ?? "-"
            plog("failed: \(code)", error: true)
            closeThenAlert("播放失败", msg)
        default:
            break
        }
    }

    /// 播到一半断了（网络断、片源出错）：关掉播放器，说一声
    private func interrupted(_ err: NSError?) {
        plog("interrupted: \(err.map { "\($0.domain) \($0.code)" } ?? "-")", error: true)
        saveProgress()
        closeThenAlert("播放中断", err?.localizedDescription ?? "网络或片源出了问题，进度已保存，可以稍后接着看。")
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
        model?.playback.finish(req.path)
        if autoplayNext, var next = req.queue.first {
            next.queue = Array(req.queue.dropFirst())
            begin(next)
        } else {
            controller?.dismiss(animated: true)
        }
    }

    private func closedByUser() {
        guard !inPiP else { return }
        plog("closed")
        loadToken += 1
        saveProgress()
        player?.pause()
        detachItem()
        if let t = timeObserver { player?.removeTimeObserver(t) }
        timeObserver = nil
        controlObservation?.invalidate()
        controlObservation = nil
        player?.replaceCurrentItem(with: nil)
        player = nil
        controller = nil
        current = nil
        NotificationCenter.default.post(name: .cuvenPlayerClosed, object: nil)
    }

    private func detachItem() {
        statusObservation?.invalidate()
        statusObservation = nil
        for o in itemObservers { NotificationCenter.default.removeObserver(o) }
        itemObservers = []
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
