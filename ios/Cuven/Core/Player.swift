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

/// AVPlayerViewController 直接全屏呈现（系统播放器：音轨 / 字幕 / 画中画 / AirPlay / 杜比视界都是系统的）
final class CuvenPlayerViewController: AVPlayerViewController {
    var onClose: (() -> Void)?
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil { onClose?() }
    }
}

@MainActor
final class PlayerCoordinator: NSObject, AVPlayerViewControllerDelegate {
    static let shared = PlayerCoordinator()

    private var player: AVPlayer?
    private var controller: CuvenPlayerViewController?
    private var current: PlayRequest?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var pendingSeek: Double?
    private var inPiP = false
    private weak var model: AppModel?

    func play(_ req: PlayRequest, model: AppModel) {
        self.model = model
        if DemoData.enabled { alert("演示模式", "演示数据没有片源，不能播放。"); return }
        Haptics.success()
        Task { await start(req) }
    }

    private func start(_ req: PlayRequest) async {
        do {
            let url = try await resolve(req)
            show(url, req)
        } catch {
            plog("resolve failed", error: true)
            alert("无法播放", error.localizedDescription)
        }
    }

    /// 片源：后端给了 HLS（MKV 实时重封装）就走 HLS —— 先看 info.json：能放才放，4xx 带着原因报错；
    /// 其余走直链（MP4 / MOV 带 safari=1）
    private func resolve(_ req: PlayRequest) async throws -> URL {
        let sign = try? await APIClient.shared.streamSign(path: req.path)
        let isMKV = req.name.lowercased().hasSuffix(".mkv")
        if let hls = sign?.hls, !hls.isEmpty, let master = URL(string: APIClient.base + hls) {
            let info = master.deletingLastPathComponent().appendingPathComponent("info.json")
            let (status, body) = await APIClient.shared.hlsInfo(info)
            plog("source hls, info.json \(status)")
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

    private func show(_ url: URL, _ req: PlayRequest) {
        saveProgress()
        detachItem()
        current = req

        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        item.externalMetadata = metadata(req)
        item.preferredForwardBufferDuration = 0

        let p = player ?? AVPlayer()
        p.automaticallyWaitsToMinimizeStalling = true
        p.allowsExternalPlayback = true
        player = p
        pendingSeek = model?.playback.resumePosition(req.path)
        p.replaceCurrentItem(with: item)
        observe(item)

        if controller?.presentingViewController == nil && !inPiP {
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
            UIApplication.topViewController()?.present(vc, animated: true)
        } else {
            controller?.player = p
        }
        if pendingSeek == nil { p.play() }
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

    private func observe(_ item: AVPlayerItem) {
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] it, _ in
            Task { @MainActor [weak self] in self?.statusChanged(it) }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.finished() }
        }
        if timeObserver == nil, let p = player {
            timeObserver = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 5, preferredTimescale: 1), queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.saveProgress() }
            }
        }
    }

    private func statusChanged(_ item: AVPlayerItem) {
        guard item === player?.currentItem else { return }
        switch item.status {
        case .readyToPlay:
            plog("ready, duration \(Int(item.duration.seconds.isFinite ? item.duration.seconds : -1))")
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

    /// 播完：清掉进度；剧集接着放下一集，电影关掉播放器
    private func finished() {
        guard let req = current else { return }
        model?.playback.finish(req.path)
        if var next = req.queue.first {
            next.queue = Array(req.queue.dropFirst())
            Task { await start(next) }
        } else {
            controller?.dismiss(animated: true)
        }
    }

    private func closedByUser() {
        guard !inPiP else { return }
        plog("closed")
        saveProgress()
        player?.pause()
        detachItem()
        if let t = timeObserver { player?.removeTimeObserver(t) }
        timeObserver = nil
        player?.replaceCurrentItem(with: nil)
        player = nil
        controller = nil
        current = nil
    }

    private func detachItem() {
        statusObservation?.invalidate()
        statusObservation = nil
        if let e = endObserver { NotificationCenter.default.removeObserver(e) }
        endObserver = nil
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

    /// 播放器还在屏上时先把它关掉、关完再弹提示 —— 直接弹会撞上正在收起的播放器，提示根本出不来
    private func closeThenAlert(_ title: String, _ message: String) {
        if let vc = controller, vc.presentingViewController != nil, !inPiP {
            vc.dismiss(animated: true) { [weak self] in self?.alert(title, message) }
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
