import Foundation
import AVFoundation
import UIKit

// MARK: - 编辑推荐的预告片：在后台下到本机
//
// 用户要求：「允许在后台和用户没有播放影片和其他预告片时自动缓存编辑推荐区的预告片背景，当预告片有缓存或停留时长超出 3s 时自动播放预告片」。
// · 编辑推荐每天换一部：主页一知道这一部的预告片（EditorsPick 的 .task），就交给系统的后台下载（AVAssetDownloadURLSession），
//   App 退到后台、锁屏也照样下；
// · 只在「空闲」时下：正片播放器盖上来、或者哪一段预告片正在从网上放（TrailerFocus 选中的那一段），下载就暂停，停下来再接着下——
//   不和正片、别的预告片抢网速；从本机放的那一段不算（不占网）；
// · 只下 1080p 那一档（不下 4K / HDR 的大档：编辑推荐那一块 1080 就清楚了，一段两三分钟约一两百兆），只在 Wi-Fi 下
//   （蜂窝、个人热点、低数据模式都不下：后台悄悄下不该花流量）；账户页「网络速度」调到省流量时不下；演示数据（UI 测试）不下；
// · 本机最多留 3 段（按下好的先后，旧的连文件一起删）；本机那份不完整（系统清掉了、没下完）就当没有，照样从网上放；
// · 只下画面和默认的那一条声音，不下字幕：预告片是静音的背景画面，不显示字幕，放的时候也不去选字幕（ShowcaseTrailer），
//   不会因为系统「字幕与隐藏式字幕」的设置跑去网上拉字幕。
// 放的时候：ShowcaseTrailer.mount 先问 localURL，有就直接放本机那份（一开始就是清楚的，马上露出来）。

@MainActor
final class TrailerCache {
    static let shared = TrailerCache()

    /// 一段：key 是哪一部（视频路径），hls 是哪一段预告片（换了预告片就重下），rel 是本机位置（相对主目录：App 更新后容器路径会变）
    private struct Entry: Codable {
        var key: String
        var hls: String
        var rel: String?
        var done: Bool
        var at: Double
    }

    private static let storeKey = "trailer-cache.v1"
    private static let sessionID = "us.cuven.tv.trailer-cache"
    private static let keep = 3

    private var entries: [Entry] = []
    private var session: AVAssetDownloadURLSession?
    private let delegate = TrailerCacheDelegate()
    /// 正在下的（key → 任务）
    private var tasks: [String: AVAssetDownloadTask] = [:]
    /// 系统告诉的本机位置（任务编号 → 位置）：下完了才记进那一段，没下成的照这个把半截文件删掉
    private var locations: [Int: URL] = [:]
    /// 正片播放器盖着
    private var playerUp = false
    /// 正在从网上放的预告片（ShowcaseTrailer 报上来的；弱引用：哪一段没报「停」就没了，也不会一直挡着下载）
    private var streaming: [WeakTrailer] = []
    private var observers: [NSObjectProtocol] = []
    private var started = false
    /// 系统交回上次的任务之前先别新建（免得同一段又从头下一遍）：这期间交过来的先记着
    private var adopted = false
    private var waiting: (key: String, hls: String)?

    private final class WeakTrailer {
        weak var value: AnyObject?
        init(_ v: AnyObject) { value = v }
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.storeKey),
           let list = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = list
        }
    }

    /// 一启动就把后台下载接上（上次没下完的、App 不在时下完的，系统这时把结果交回来）
    func start() {
        guard !started, !DemoData.enabled else { return }
        started = true
        let nc = NotificationCenter.default
        observers = [
            nc.addObserver(forName: .cuvenPlayerPresented, object: nil, queue: .main) { _ in
                Task { @MainActor in TrailerCache.shared.setPlayerUp(true) }
            },
            nc.addObserver(forName: .cuvenPlayerClosed, object: nil, queue: .main) { _ in
                Task { @MainActor in TrailerCache.shared.setPlayerUp(false) }
            },
        ]
        let s = makeSession()
        s.getAllTasks { list in
            let found = list.compactMap { $0 as? AVAssetDownloadTask }.map { (key: $0.taskDescription ?? "", task: $0) }
            Task { @MainActor in TrailerCache.shared.adopt(found) }
        }
    }

    /// 本机有这一段、而且是完整的：直接放它
    func localURL(key: String, hls: String) -> URL? {
        guard let e = entries.first(where: { $0.key == key && $0.hls == hls && $0.done }), let rel = e.rel else { return nil }
        let url = Self.home.appendingPathComponent(rel)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard AVURLAsset(url: url).assetCache?.isPlayableOffline == true else { return nil }
        return url
    }

    /// 编辑推荐的这一部（key = 视频路径）有这段预告片：本机还没有就开始下（空闲时才真的在下）
    func want(key: String, hls: String) {
        guard !DemoData.enabled, !NetworkSpeed.dataSaver,
              let url = URL(string: hls), url.scheme?.hasPrefix("http") == true else { return }
        start()
        guard adopted else { waiting = (key, hls); return }
        if localURL(key: key, hls: hls) != nil { return }
        if let e = entries.first(where: { $0.key == key }), e.hls == hls, tasks[key] != nil { return }
        // 编辑推荐换了一部：前一部没下完的不再下
        for (k, t) in tasks where k != key { t.cancel(); tasks[k] = nil }
        if let t = tasks[key] { t.cancel(); tasks[key] = nil }
        drop(key: key)
        let s = makeSession()
        let asset = AVURLAsset(url: url)
        let config = AVAssetDownloadConfiguration(asset: asset, title: "Cuven")
        // 1080p 那一档（高不过 1100、峰值码率不过 12 Mbps：挑得到的里面最好的那一档），不下 4K / HDR 的大档
        let height = AVAssetVariantQualifier.predicate(forPresentationHeight: 1100, operatorType: .lessThanOrEqualTo)
        let rate = NSPredicate(format: "peakBitRate <= %f", 12_000_000.0)
        config.primaryContentConfiguration.variantQualifiers = [
            AVAssetVariantQualifier(predicate: NSCompoundPredicate(andPredicateWithSubpredicates: [height, rate])),
        ]
        let made: AVAssetDownloadTask? = s.makeAssetDownloadTask(downloadConfiguration: config)
        guard let task = made else { return }
        task.taskDescription = key
        tasks[key] = task
        entries.append(Entry(key: key, hls: hls, rel: nil, done: false, at: Date().timeIntervalSince1970))
        save()
        Perf.log("trailer-cache: queued")
        apply()
    }

    /// ShowcaseTrailer 报：这一段在 / 不在从网上放
    func trailer(_ t: AnyObject, streaming on: Bool) {
        let was = streaming.contains { $0.value === t }
        guard was != on else { return }
        streaming.removeAll { $0.value == nil || $0.value === t }
        if on { streaming.append(WeakTrailer(t)) }
        apply()
    }

    // MARK: 内部

    private static var home: URL { URL(fileURLWithPath: NSHomeDirectory()) }

    private func makeSession() -> AVAssetDownloadURLSession {
        if let session { return session }
        let cfg = URLSessionConfiguration.background(withIdentifier: Self.sessionID)
        // 只在 Wi-Fi（不花蜂窝流量、个人热点），低数据模式下不下
        cfg.allowsExpensiveNetworkAccess = false
        cfg.allowsConstrainedNetworkAccess = false
        cfg.isDiscretionary = false
        cfg.sessionSendsLaunchEvents = false
        let s = AVAssetDownloadURLSession(configuration: cfg, assetDownloadDelegate: delegate, delegateQueue: .main)
        session = s
        return s
    }

    private func setPlayerUp(_ on: Bool) {
        guard playerUp != on else { return }
        playerUp = on
        apply()
    }

    /// 空闲（正片没盖着、没有预告片在从网上放）就下，不空闲就停
    private func apply() {
        streaming.removeAll { $0.value == nil }
        let idle = !playerUp && streaming.isEmpty
        for t in tasks.values {
            if idle { if t.state == .suspended { t.resume() } }
            else if t.state == .running { t.suspend() }
        }
    }

    /// 启动时系统交回来的任务：还认得的接着管，认不得的（换了一部、记录丢了）取消
    private func adopt(_ found: [(key: String, task: AVAssetDownloadTask)]) {
        for f in found {
            if tasks[f.key] == nil, entries.contains(where: { $0.key == f.key && !$0.done }) {
                tasks[f.key] = f.task
            } else if tasks[f.key] !== f.task {
                f.task.cancel()
            }
        }
        adopted = true
        apply()
        if let w = waiting {
            waiting = nil
            want(key: w.key, hls: w.hls)
        }
    }

    fileprivate func located(task id: Int, location: URL) {
        locations[id] = location
    }

    /// 一个任务结束了。是不是现在管着的那一个：key 对得上、编号也对得上（启动时还没接上的、记录里还在等的也算）；
    /// 不是（换了一部、换了预告片时取消的旧任务），只把它留下的半截文件删掉
    fileprivate func completed(task id: Int, key: String?, ok: Bool) {
        let loc = locations.removeValue(forKey: id)
        guard let key, let i = entries.firstIndex(where: { $0.key == key && !$0.done }),
              tasks[key].map({ $0.taskIdentifier == id }) ?? true else {
            if let loc { try? FileManager.default.removeItem(at: loc) }
            return
        }
        tasks[key] = nil
        if ok, let loc {
            entries[i].rel = Self.relative(loc)
            entries[i].done = true
            entries[i].at = Date().timeIntervalSince1970
            Perf.log("trailer-cache: ready")
        } else {
            // 没下成（取消、断网太久、系统清掉）：连半截文件一起删，下次主页再交过来时重下
            if let loc { try? FileManager.default.removeItem(at: loc) }
            drop(key: key)
            Perf.log("trailer-cache: failed")
        }
        prune()
        save()
    }

    /// 删掉这一部的记录和文件
    private func drop(key: String) {
        for e in entries where e.key == key { remove(e) }
        entries.removeAll { $0.key == key }
    }

    /// 最多留 keep 段下好的（旧的删掉）
    private func prune() {
        let done = entries.filter(\.done).sorted { $0.at > $1.at }
        for e in done.dropFirst(Self.keep) {
            remove(e)
            entries.removeAll { $0.key == e.key && $0.done }
        }
    }

    private func remove(_ e: Entry) {
        guard let rel = e.rel else { return }
        try? FileManager.default.removeItem(at: Self.home.appendingPathComponent(rel))
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) { UserDefaults.standard.set(data, forKey: Self.storeKey) }
    }

    /// 本机位置记成相对主目录的一段（App 更新后容器的路径会变，主目录下面那一截不变）
    private static func relative(_ url: URL) -> String {
        let path = url.path
        let homePath = NSHomeDirectory()
        if path.hasPrefix(homePath + "/") { return String(path.dropFirst(homePath.count + 1)) }
        if let r = path.range(of: "/Library/") { return String(path[path.index(after: r.lowerBound)...]) }
        return url.relativePath
    }
}

/// 后台下载的回调（系统在主队列上叫）：只把结果交回 TrailerCache（按任务编号认是哪一个）
private final class TrailerCacheDelegate: NSObject, AVAssetDownloadDelegate {
    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, willDownloadTo location: URL) {
        let id = assetDownloadTask.taskIdentifier
        Task { @MainActor in TrailerCache.shared.located(task: id, location: location) }
    }

    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didFinishDownloadingTo location: URL) {
        let id = assetDownloadTask.taskIdentifier
        Task { @MainActor in TrailerCache.shared.located(task: id, location: location) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let id = task.taskIdentifier, key = task.taskDescription
        let ok = error == nil
        Task { @MainActor in TrailerCache.shared.completed(task: id, key: key, ok: ok) }
    }
}
