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
// · 下哪一档跟着账户页「网络速度」走（用户要求「预告片缓存机制按照设置中的网络速度走，100% 时启用 4K/HDR」，见 Tier）：
//   100% 不设上限（4K / HDR，挑得到的最好那一档）；75–99% 1080p；50–74% 720p；25–49% 540p；25% 以下是省流量，不下。
//   调高了（比如从 80% 拉到 100%），本机那份比现在要的档低就重下一份，下好了才换掉旧的；调低了不重下（本机那份放起来不费流量）；
// · 只在 Wi-Fi 下（蜂窝、个人热点、低数据模式都不下：后台悄悄下不该花流量）；演示数据（UI 测试）不下；
// · 主页头图（用户要求「hero区自动缓存和使用预告片背景」）：头图那 5 部的预告片也交过来（wantHeroes），和编辑推荐排成一队，
//   一次只下一段，下完一段接着下下一段（头图第一页 → 编辑推荐 → 头图其余几页）；头图只放本机下好的那份（不从网上放）；
// · 本机最多留 6 段（头图 5 部 + 编辑推荐；有 4K 那一档的时候 3 段：一段几百兆，只下排在最前的 3 段），
//   超了先删现在不要的（换轮以后的旧头图、换掉的编辑推荐），再按下好的先后删旧的，连文件一起删；本机那份不完整（系统清掉了、没下完）就当没有，照样从网上放；
// · 只下画面和默认的那一条声音，不下字幕：预告片是静音的背景画面，不显示字幕，放的时候也不去选字幕（ShowcaseTrailer），
//   不会因为系统「字幕与隐藏式字幕」的设置跑去网上拉字幕。
// 放的时候：ShowcaseTrailer.mount 先问 localURL，有就直接放本机那份（一开始就是清楚的，马上露出来）。

@MainActor
final class TrailerCache {
    static let shared = TrailerCache()

    /// 下哪一档（数越大越清楚）。旧版本记下的没有档位，当 1080p
    enum Tier: Int, Codable, Comparable {
        case p540 = 1, p720 = 2, p1080 = 3, best = 4

        static func < (a: Tier, b: Tier) -> Bool { a.rawValue < b.rawValue }

        /// 账户页「网络速度」→ 档位；省流量（25% 以下）是 nil：不下
        static func of(_ percent: Int) -> Tier? {
            switch percent {
            case 100...: return .best
            case 75..<100: return .p1080
            case 50..<75: return .p720
            case 25..<50: return .p540
            default: return nil
            }
        }

        /// 挑档的条件：最好那一档不设（系统挑最好的，4K / HDR 都行）；别的按画面高和峰值码率卡住
        var qualifiers: [AVAssetVariantQualifier] {
            let cap: (height: CGFloat, bitrate: Double)
            switch self {
            case .best: return []
            case .p1080: cap = (1100, 12_000_000)
            case .p720: cap = (800, 6_000_000)
            case .p540: cap = (600, 3_000_000)
            }
            let height = AVAssetVariantQualifier.predicate(forPresentationHeight: cap.height, operatorType: .lessThanOrEqualTo)
            let rate = NSPredicate(format: "peakBitRate <= %f", cap.bitrate)
            return [AVAssetVariantQualifier(predicate: NSCompoundPredicate(andPredicateWithSubpredicates: [height, rate]))]
        }
    }

    /// 一段：key 是哪一部（视频路径），hls 是哪一段预告片（换了预告片就重下），rel 是本机位置（相对主目录：App 更新后容器路径会变）
    private struct Entry: Codable {
        var key: String
        var hls: String
        var rel: String?
        var done: Bool
        var at: Double
        var tier: Tier?

        var level: Tier { tier ?? .p1080 }
    }

    private static let storeKey = "trailer-cache.v1"
    private static let sessionID = "us.cuven.tv.trailer-cache"

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
    /// 系统交回上次的任务之前先别新建（免得同一段又从头下一遍）：交回来以后再按 editor / heroes 排一遍
    private var adopted = false
    /// 编辑推荐交过来的那一段、头图交过来的那几段（「网络速度」一改、下完一段，都按它们再排一遍）
    private var editor: (key: String, hls: String)?
    private var heroes: [(key: String, hls: String)] = []
    private var lastTier: Tier?
    /// 这回打开 App 每一段排过几次（下完一段就自动排下一段：哪一段老是下不成、下完了又放不了，最多试 3 次，不一直重下）
    private var attempts: [String: Int] = [:]

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
        lastTier = Tier.of(NetworkSpeed.current)
        let nc = NotificationCenter.default
        observers = [
            nc.addObserver(forName: .cuvenPlayerPresented, object: nil, queue: .main) { _ in
                Task { @MainActor in TrailerCache.shared.setPlayerUp(true) }
            },
            nc.addObserver(forName: .cuvenPlayerClosed, object: nil, queue: .main) { _ in
                Task { @MainActor in TrailerCache.shared.setPlayerUp(false) }
            },
            // 「网络速度」改了（手动拖、自动调整选了别的数）：档位变了就按新的档位再看一遍
            nc.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
                Task { @MainActor in TrailerCache.shared.speedMaybeChanged() }
            },
        ]
        let s = makeSession()
        s.getAllTasks { list in
            let found = list.compactMap { $0 as? AVAssetDownloadTask }.map { (key: $0.taskDescription ?? "", task: $0) }
            Task { @MainActor in TrailerCache.shared.adopt(found) }
        }
    }

    /// 本机有这一段、而且是完整的：直接放它（有几份时放最清楚的那份）
    func localURL(key: String, hls: String) -> URL? {
        let done = entries.filter { $0.key == key && $0.hls == hls && $0.done }.sorted { $0.level > $1.level }
        for e in done {
            guard let rel = e.rel else { continue }
            let url = Self.home.appendingPathComponent(rel)
            guard FileManager.default.fileExists(atPath: url.path),
                  AVURLAsset(url: url).assetCache?.isPlayableOffline == true else { continue }
            return url
        }
        return nil
    }

    /// 编辑推荐的这一部（key = 视频路径）有这段预告片：本机还没有（或者本机那份比「网络速度」要的档低）就排进队里下（空闲时才真的在下）
    func want(key: String, hls: String) {
        guard !DemoData.enabled else { return }
        editor = (key, hls)
        pump()
    }

    /// 头图这几部（按页的顺序）的预告片：一样排进队里下；不在这里的旧头图那几段，本机放不下时先删
    func wantHeroes(_ list: [(key: String, hls: String)]) {
        guard !DemoData.enabled else { return }
        heroes = list
        pump()
    }

    /// 本机要留的那几段，排得越前越先下：头图第一页 → 编辑推荐 → 头图其余几页；放不下的（4K 时只留 3 段）不下
    private var wanted: [(key: String, hls: String)] {
        var out: [(key: String, hls: String)] = []
        var all: [(key: String, hls: String)] = []
        if let first = heroes.first { all.append(first) }
        if let e = editor { all.append(e) }
        all += heroes.dropFirst()
        for w in all where !out.contains(where: { $0.key == w.key }) {
            guard let url = URL(string: w.hls), url.scheme?.hasPrefix("http") == true else { continue }
            out.append(w)
        }
        return Array(out.prefix(keepLimit))
    }

    /// 本机最多留几段：头图 5 部 + 编辑推荐；要下 4K（或者本机已经有 4K 的）时 3 段
    private var keepLimit: Int {
        let best = Tier.of(NetworkSpeed.current) == .best || entries.contains { $0.done && $0.level == .best }
        return best ? 3 : 6
    }

    /// 排一遍队：不要的（换了一部、换了预告片、换了档）没下完的取消；正在下的还要就接着下；没有在下的，就下排在最前、本机还没有的那一段
    private func pump() {
        guard !DemoData.enabled else { return }
        start()
        guard adopted else { return }
        guard let tier = Tier.of(NetworkSpeed.current) else { return }
        let list = wanted
        for (k, t) in tasks {
            let w = list.first { $0.key == k }
            let p = entries.first { $0.key == k && !$0.done }
            if let w, let p, p.hls == w.hls, p.level == tier { continue }
            // 编辑推荐还没交过来（主页还没滑到那一块；刚启动、系统刚交回上次的任务）：不在头图里的那一段可能是它的，先接着下
            if w == nil, editor == nil, let p, p.level == tier { continue }
            t.cancel()
            tasks[k] = nil
            entries.removeAll { $0.key == k && !$0.done }
        }
        // 记录里还在等、却没有任务的（上次的任务系统没交回来）：不算
        entries.removeAll { !$0.done && tasks[$0.key] == nil }
        // 一次只下一段：正在下的那段下完了（completed）再排下一段
        guard tasks.isEmpty else { save(); apply(); return }
        guard let next = list.first(where: { w in
            if (attempts[w.key + "|" + w.hls] ?? 0) >= 3 { return false }
            guard let have = bestDone(key: w.key, hls: w.hls) else { return true }
            return have.level < tier
        }), let url = URL(string: next.hls) else { save(); return }
        let key = next.key, hls = next.hls
        attempts[key + "|" + hls, default: 0] += 1
        // 换了预告片：旧的那段删掉（同一段的低档那份留着，新的下好了才换）
        for e in entries where e.key == key && e.hls != hls { remove(e) }
        entries.removeAll { $0.key == key && $0.hls != hls }
        let s = makeSession()
        let config = AVAssetDownloadConfiguration(asset: AVURLAsset(url: url), title: "Cuven")
        config.primaryContentConfiguration.variantQualifiers = tier.qualifiers
        let made: AVAssetDownloadTask? = s.makeAssetDownloadTask(downloadConfiguration: config)
        guard let task = made else { save(); return }
        task.taskDescription = key
        tasks[key] = task
        entries.append(Entry(key: key, hls: hls, rel: nil, done: false, at: Date().timeIntervalSince1970, tier: tier))
        save()
        Perf.log("trailer-cache: queued (tier \(tier.rawValue))")
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

    private func bestDone(key: String, hls: String) -> Entry? {
        guard localURL(key: key, hls: hls) != nil else { return nil }
        return entries.filter { $0.key == key && $0.hls == hls && $0.done }.max { $0.level < $1.level }
    }

    private func setPlayerUp(_ on: Bool) {
        guard playerUp != on else { return }
        playerUp = on
        apply()
    }

    /// 存储一有变化系统就叫（自己存记录也会叫）：只在「网络速度」换了档位时才动
    private func speedMaybeChanged() {
        let tier = Tier.of(NetworkSpeed.current)
        guard tier != lastTier else { return }
        lastTier = tier
        if tier == nil {
            // 调到省流量：没下完的不再下（下好的留着，放起来不费流量）
            for (k, t) in tasks { t.cancel(); tasks[k] = nil }
            entries.removeAll { !$0.done }
            save()
        } else {
            pump()
        }
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
        pump()
    }

    fileprivate func located(task id: Int, location: URL) {
        locations[id] = location
    }

    /// 一个任务结束了。是不是现在管着的那一个：key 对得上、编号也对得上（启动时还没接上的、记录里还在等的也算）；
    /// 不是（换了一部、换了预告片、换了档时取消的旧任务），只把它留下的半截文件删掉
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
            // 同一部之前下的那份（低一档的）这时才换掉
            let fresh = entries[i]
            for e in entries where e.key == key && e.done && e.rel != fresh.rel { remove(e) }
            entries.removeAll { $0.key == key && $0.done && $0.rel != fresh.rel }
            Perf.log("trailer-cache: ready (tier \(fresh.level.rawValue))")
        } else {
            // 没下成（取消、断网太久、系统清掉）：连半截文件一起删，下次主页再交过来时重下（之前下好的那份留着）
            if let loc { try? FileManager.default.removeItem(at: loc) }
            entries.remove(at: i)
            Perf.log("trailer-cache: failed")
        }
        prune()
        save()
        // 头图停在这一页的话马上换成预告片（记录存好了再说）
        if ok { NotificationCenter.default.post(name: .cuvenTrailerCached, object: nil, userInfo: ["key": key]) }
        // 接着下队里的下一段
        pump()
    }

    /// 最多留 keepLimit 段下好的：现在要的（头图、编辑推荐，排在前面的优先）留着，别的按下好的先后，旧的删掉
    private func prune() {
        let want = wanted
        func rank(_ e: Entry) -> Int { want.firstIndex { $0.key == e.key && $0.hls == e.hls } ?? Int.max }
        let done = entries.filter(\.done).sorted { a, b in
            let ra = rank(a), rb = rank(b)
            return ra != rb ? ra < rb : a.at > b.at
        }
        for e in done.dropFirst(keepLimit) {
            remove(e)
            entries.removeAll { $0.key == e.key && $0.done && $0.rel == e.rel }
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

extension Notification.Name {
    /// TrailerCache 下好了一段（userInfo["key"] 是哪一部）：主页头图停在这一页的话，马上换成预告片
    static let cuvenTrailerCached = Notification.Name("cuven.trailer.cached")
}
