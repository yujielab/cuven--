import Foundation
import Observation
import SwiftUI

// MARK: - 本地缓存（Caches/cuven/*.json）：下次打开先用上次的，网络回来再换新

enum DiskCache {
    static var dir: URL {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("cuven", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func save<T: Encodable>(_ value: T, _ name: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        let url = dir.appendingPathComponent(name)
        Task.detached(priority: .background) { try? data.write(to: url, options: .atomic) }
    }

    static func load<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: dir)
    }

    static func size() -> Int64 {
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return items.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
}

// MARK: - 播放进度（继续观看）

struct WatchEntry: Codable, Hashable, Identifiable {
    var path: String
    var name: String
    var title: String
    var subtitle: String?
    var artwork: String?
    var position: Double
    var duration: Double
    var updated: Date
    var seriesPath: String?
    var episode: Int?
    var id: String { path }

    var fraction: Double { duration > 0 ? min(1, max(0, position / duration)) : 0 }
    var remaining: Double { max(0, duration - position) }
}

@MainActor
@Observable
final class PlaybackStore {
    private(set) var entries: [String: WatchEntry] = [:]
    private let key = "cuven_progress_v1"
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init() {
        // 演示数据模式：进度只在内存里，不读也不写本地（截图里不能混进真实的观看记录）
        if DemoData.enabled { return }
        if let data = UserDefaults.standard.data(forKey: key),
           let list = try? JSONDecoder().decode([WatchEntry].self, from: data) {
            entries = Dictionary(list.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        }
    }

    /// 从哪儿接着放：看过 30 秒以上、没看到 95%
    func resumePosition(_ path: String) -> Double? {
        guard let e = entries[path], e.position > 30, e.fraction < 0.95 else { return nil }
        return e.position
    }

    func entry(_ path: String) -> WatchEntry? { entries[path] }

    func update(_ e: WatchEntry) {
        guard e.duration > 0, e.position.isFinite else { return }
        if e.fraction >= 0.95 { finish(e.path); return }
        entries[e.path] = e
        persist()
    }

    func finish(_ path: String) {
        guard entries[path] != nil else { return }
        entries[path] = nil
        persist()
    }

    func clearAll() {
        entries = [:]
        persist()
    }

    /// 继续观看：每部剧只留最近那一集
    var continueWatching: [WatchEntry] {
        var seen = Set<String>()
        return entries.values
            .filter { $0.position > 30 && $0.fraction < 0.95 }
            .sorted { $0.updated > $1.updated }
            .filter { e in
                guard let s = e.seriesPath else { return true }
                return seen.insert(s).inserted
            }
            .prefix(20)
            .map { $0 }
    }

    /// 某部剧最近看到哪一集
    func lastEpisode(of seriesPath: String) -> WatchEntry? {
        entries.values.filter { $0.seriesPath == seriesPath }.max { $0.updated < $1.updated }
    }

    /// 请求添加的片子名字里带追踪码（[auto-m550-r13]）：工作人员把它从 /auto 挪进片库以后路径变了、追踪码没变——
    /// 按追踪码把进度接到新路径上（「继续观看」不丢、接着放的位置也在）。只动旧路径已经不在片库里的
    func relink(videos: [Video], series: [Series]) {
        guard !entries.isEmpty else { return }
        var movieAt: [String: String] = [:], seriesAt: [String: String] = [:]
        for v in videos { if let c = AutoTag.code(in: v.path) { movieAt[c] = v.path } }
        for s in series { if let c = AutoTag.code(in: s.path) { seriesAt[c] = s.path } }
        guard !movieAt.isEmpty || !seriesAt.isEmpty else { return }
        let livePaths = Set(videos.map(\.path)), liveSeries = Set(series.map(\.path))
        var next = entries, changed = false
        for (key, e) in entries {
            if let sp = e.seriesPath {
                guard !liveSeries.contains(sp), let c = AutoTag.code(in: sp), let np = seriesAt[c], np != sp else { continue }
                var ne = e
                ne.seriesPath = np
                let oldDir = Self.dir(sp), newDir = Self.dir(np)
                if e.path.hasPrefix(oldDir + "/") { ne.path = newDir + e.path.dropFirst(oldDir.count) }
                next[key] = nil
                next[ne.path] = ne
                changed = true
            } else {
                guard !livePaths.contains(e.path), let c = AutoTag.code(in: e.path), let np = movieAt[c], np != e.path else { continue }
                var ne = e
                ne.path = np
                next[key] = nil
                next[np] = ne
                changed = true
            }
        }
        if changed { entries = next; persist() }
    }

    /// 剧集表里一季的路径可能带「#S2」（一个文件夹混着几季时拆开的）：文件夹部分
    private static func dir(_ seriesPath: String) -> String {
        seriesPath.split(separator: "#", maxSplits: 1).first.map(String.init) ?? seriesPath
    }

    private func persist() {
        if DemoData.enabled { return }
        saveTask?.cancel()
        let list = Array(entries.values)
        let key = self.key
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            if let data = try? JSONEncoder().encode(list) { UserDefaults.standard.set(data, forKey: key) }
        }
    }
}

// MARK: - 想看（Apple TV 的「+」：加进来的电影 / 剧集，在首页有一排）

struct WatchItem: Codable, Hashable {
    enum Kind: String, Codable { case movie, series }
    var key: String          // 电影：文件路径；剧集：剧集目录
    var kind: Kind
    var added: Date
}

@MainActor
@Observable
final class WatchlistStore {
    private(set) var items: [WatchItem] = []
    private let storeKey = "cuven_watchlist_v1"

    init() {
        // 演示数据模式：只在内存里（截图里不混进真实的片单）
        if DemoData.enabled { return }
        if let d = UserDefaults.standard.data(forKey: storeKey), let list = try? JSONDecoder().decode([WatchItem].self, from: d) {
            items = list
        }
    }

    func contains(_ key: String) -> Bool { items.contains { $0.key == key } }

    func toggle(_ key: String, kind: WatchItem.Kind) {
        if let i = items.firstIndex(where: { $0.key == key }) {
            items.remove(at: i)
        } else {
            items.insert(WatchItem(key: key, kind: kind, added: Date()), at: 0)
        }
        save()
    }

    /// 和 PlaybackStore.relink 一样：带追踪码的片子被挪了位置，片单跟到新路径
    func relink(videos: [Video], series: [Series]) {
        guard !items.isEmpty else { return }
        var movieAt: [String: String] = [:], seriesAt: [String: String] = [:]
        for v in videos { if let c = AutoTag.code(in: v.path) { movieAt[c] = v.path } }
        for s in series { if let c = AutoTag.code(in: s.path) { seriesAt[c] = s.path } }
        guard !movieAt.isEmpty || !seriesAt.isEmpty else { return }
        let live = Set(videos.map(\.path)).union(series.map(\.path))
        var changed = false
        items = items.map { it in
            guard !live.contains(it.key), let c = AutoTag.code(in: it.key),
                  let np = it.kind == .movie ? movieAt[c] : seriesAt[c], np != it.key else { return it }
            changed = true
            var n = it
            n.key = np
            return n
        }
        if changed { save() }
    }

    private func save() {
        guard !DemoData.enabled, let d = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(d, forKey: storeKey)
    }
}

// MARK: - 片库

/// 文件夹那一份缓存：根目录 + 根下一级的文件夹
struct FolderCache: Codable {
    var root: String
    var folders: [LibraryFolder]
}

/// 资料库要的：每部电影有没有 Apple TV 预告片（和详情页同一次查询），查过的时间也记下来，第二次打开直接知道
struct TrailerIndex: Codable {
    var known: [String: Bool] = [:]
    var stamps: [String: Double] = [:]
}

/// 全片库 Apple TV 素材的本地那一份：对上的素材、各自问到的时间、Apple TV 上没有的（记下时间，过几天再问）
struct AtvArtCache: Codable {
    var items: [String: AtvArt] = [:]
    var stamps: [String: Double] = [:]
    var misses: [String: Double] = [:]
}

@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable { case idle, loading, ready, failed(String) }

    var phase: Phase = .idle
    var videos: [Video] = []
    var metas: [String: Meta] = [:]          // 文件名 → TMDB
    var hidden: Set<String> = []             // 确定认不出 / 没有海报：不显示
    var series: [Series] = []
    var seriesMetas: [String: Meta] = [:]    // 剧集目录 → TMDB（带字标）
    var heroes: [Hero] = []
    var metaReady = false
    /// 演员弹层「在资料库中搜索」：要搜的词。根视图看到就换到「搜索」标签，搜索页填进搜索框后清掉
    var searchRequest: String?
    /// 打开分享来的链接（DeepLink）：要推进的那一页；主页推进去以后清掉
    var openRequest: Route?
    /// 分享来的链接在片库里找不到：说一声
    var linkMissing = false
    /// 片库还没载入时来的链接：载入了再找
    @ObservationIgnored private var pendingLink: DeepLink.Target?
    /// 片库根下一级的文件夹（首页最后那排「文件夹」）；libraryRoot 是 /api/all 回包里的根目录，进文件夹时换成相对路径
    var folders: [LibraryFolder] = []
    @ObservationIgnored var libraryRoot = ""
    /// 「新」角标（网页版 Notify.freshSet）：上次看到的最新入库时间之后才进来的片子，只标首页「最新加入」那一排。
    /// 一次会话只算一次、算完立刻把水位抬到这一回的最新：从详情页回来角标不会当场消失，下次打开就没了
    private(set) var freshPaths: Set<String> = []
    @ObservationIgnored private var freshFrozen = false
    private static let seenKey = "cuven_lib_seen_v1"

    let playback = PlaybackStore()
    let watchlist = WatchlistStore()

    @ObservationIgnored private var started = false
    /// Apple TV 上对上的那一部（电影按文件路径、剧集按目录记）；对不上记 nil，一部只问一次
    @ObservationIgnored private var atvCache: [String: AtvLookup?] = [:]
    /// 全片库电影的 Apple TV 素材（POST /api/atv/art），键见 atvArtKey：同一部片的各个版本共用一份。
    /// 画面一律从下面几个取用函数拿：Apple TV 优先，TMDB 兜底
    private(set) var atvArtIndex: [String: AtvArt] = [:]
    @ObservationIgnored private var atvArtStamps: [String: Double] = [:]
    @ObservationIgnored private var atvArtMisses: [String: Double] = [:]
    /// 后端还没有这个接口（Worker 没重新部署）：这次打开不再问
    @ObservationIgnored private var atvArtUnavailable = false
    @ObservationIgnored private var atvArtLoading = false
    @ObservationIgnored private var seriesInflight: Set<String> = []
    @ObservationIgnored private var metaRound = 0
    /// 片库 / 元数据每变一次加一：首页那几排（电影清单、按年份、今日推荐）按它缓存，不在每次重绘时重算
    @ObservationIgnored private var dataVersion = 0
    @ObservationIgnored private var derivedVersion = -1
    @ObservationIgnored private var cachedMovies: [Video] = []
    @ObservationIgnored private var cachedYearGroups: [(year: Int, videos: [Video])] = []
    @ObservationIgnored private var cachedPicks: (version: Int, seed: UInt32, list: [Video])?

    // MARK: 启动 / 刷新

    func start() {
        guard !started else { return }
        started = true
        if DemoData.enabled {                       // 演示数据：不连服务器、不读写本地缓存
            DemoData.populate(self)
            freezeFresh()
            dataVersion &+= 1
            phase = .ready
            metaReady = true
            Task { await resolveHeroes() }
            Task { await scanTrailers() }
            return
        }
        restore()
        phase = videos.isEmpty ? .loading : .ready
        Task { await resolveHeroes() }
        Task { await refreshLibrary() }
        Task { await refreshSeries() }
        Task { await refreshHeroes() }
    }

    func refreshAll() async {
        if DemoData.enabled { return }
        async let a: Void = refreshLibrary()
        async let b: Void = refreshSeries()
        async let c: Void = refreshHeroes()
        _ = await (a, b, c)
    }

    private func restore() {
        let t0 = Date()
        if let v = DiskCache.load([Video].self, "library.json") { videos = v }
        if let m = DiskCache.load([String: Meta].self, "metas.json") { metas = m }
        if let h = DiskCache.load([String].self, "hidden.json") { hidden = Set(h) }
        if let s = DiskCache.load([Series].self, "series.json") { series = s }
        if let sm = DiskCache.load([String: Meta].self, "series-metas.json") { seriesMetas = sm }
        if let he = DiskCache.load([Hero].self, "heroes.json") { heroes = he }
        if let f = DiskCache.load(FolderCache.self, "folders.json") { folders = f.folders; libraryRoot = f.root }
        if let a = DiskCache.load(AtvArtCache.self, "atv-art.json") {
            atvArtIndex = a.items; atvArtStamps = a.stamps; atvArtMisses = a.misses
        }
        if let t = DiskCache.load(TrailerIndex.self, "trailer-index.json") {
            trailerKnown = t.known; trailerStamps = t.stamps
        }
        metaReady = !metas.isEmpty
        dataVersion &+= 1
        // 读本地缓存要多久（启动时在主线程上：CI 的二次启动看这一行）
        Perf.log("restore: \(videos.count) videos, \(metas.count) metas in \(Perf.ms(since: t0)) ms")
    }

    func refreshLibrary() async {
        do {
            let t0 = Date()
            let lib = try await APIClient.shared.library()
            let vids = lib.videos.filter { FileName.isVideo($0.name) }.sorted { $0.addedKey > $1.addedKey }
            videos = vids
            // 带追踪码的片子被工作人员挪了位置：进度和片单跟到新路径
            playback.relink(videos: vids, series: series)
            watchlist.relink(videos: vids, series: series)
            freezeFresh()
            folders = lib.folders
            libraryRoot = lib.root ?? ""
            dataVersion &+= 1
            Perf.log("library: \(vids.count) videos, \(lib.folders.count) folders in \(Perf.ms(since: t0)) ms")
            phase = .ready
            DiskCache.save(vids, "library.json")
            DiskCache.save(FolderCache(root: libraryRoot, folders: lib.folders), "folders.json")
            metaRound = 0
            await loadMetas()
            // 片名、年份齐了再挑头图（要按英文名去 Apple TV 查无字背景和字标）
            await resolveHeroes()
            // 资料库：后台查哪些电影有预告片（只放有的）
            Task { await self.scanTrailers() }
            // 再去 Apple TV 对全片库的画面：放到后台，不让下拉刷新等它（一轮可能要一两分钟）
            Task { await self.loadAtvArt() }
        } catch {
            if videos.isEmpty { phase = .failed(FriendlyError.message(error)) }
            freezeFresh()   // 没连上：就按上次存下的片库算
        }
    }

    /// 片库第一次拿到真数据时算一回「新」（网页版 renderHome 之后的 Notify.mount）：
    /// 入库时间（added，没有就 modified）晚于上次记下的水位的算新；第一次打开整个库都比 0 新——那不叫新片，叫片库，
    /// 所以首次只记水位、不标新。算完立刻把水位抬到这一回最新的入库时间
    private func freezeFresh() {
        guard !freshFrozen, !videos.isEmpty else { return }
        freshFrozen = true
        let stamps = videos.map { (path: $0.path, t: Relative.date($0.addedKey)?.timeIntervalSince1970 ?? 0) }
        if DemoData.enabled {
            // 演示数据：当作上次是 4 天前打开的（最新入库的两部算新），不读写真实的水位
            let seen = Date().timeIntervalSince1970 - 4 * 86_400
            freshPaths = Set(stamps.filter { $0.t > seen }.map { $0.path })
            return
        }
        let seen = UserDefaults.standard.double(forKey: Self.seenKey)
        freshPaths = seen > 0 ? Set(stamps.filter { $0.t > seen }.map { $0.path }) : []
        let newest = stamps.map { $0.t }.max() ?? 0
        if newest > 0 { UserDefaults.standard.set(newest, forKey: Self.seenKey) }
    }

    /// 片库里每个文件名问一次 TMDB（批接口一次 80 个，两路并发）。没回答的过一会儿再问，最多三轮
    func loadMetas() async {
        let need = videos.map(\.name).filter { metas[$0] == nil && !hidden.contains($0) }
        if need.isEmpty { metaReady = true; return }
        let chunks = stride(from: 0, to: need.count, by: 80).map { Array(need[$0..<min($0 + 80, need.count)]) }
        var i = 0
        while i < chunks.count {
            let group = Array(chunks[i..<min(i + 2, chunks.count)])
            i += 2
            let t0 = Date()
            let results = await withTaskGroup(of: [String: Meta?].self, returning: [[String: Meta?]].self) { g in
                for c in group { g.addTask { (try? await APIClient.shared.metaBatch(c)) ?? [:] } }
                var out: [[String: Meta?]] = []
                for await r in g { out.append(r) }
                return out
            }
            let t1 = Date()
            apply(results)
            metaReady = true
            Perf.log("metas: +\(results.reduce(0) { $0 + $1.count }) → \(metas.count) (fetch \(Perf.ms(t0, t1)) ms, apply \(Perf.ms(since: t1)) ms)")
        }
        let t2 = Date()
        DiskCache.save(metas, "metas.json")
        DiskCache.save(Array(hidden), "hidden.json")
        Perf.log("metas saved in \(Perf.ms(since: t2)) ms")
        let left = videos.contains { metas[$0.name] == nil && !hidden.contains($0.name) }
        if left && metaRound < 3 {
            metaRound += 1
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            await loadMetas()
        }
    }

    /// 一批结果改在副本上、最后各写回一次：观察者只收到一次变更，也不会每改一条就把整张表复制一遍
    private func apply(_ results: [[String: Meta?]]) {
        var m = metas, h = hidden
        for r in results {
            for (name, value) in r {
                if let meta = value, meta.hasArt {
                    m[name] = meta
                    h.remove(name)
                } else {
                    h.insert(name)       // 后端确定认不出，或认出来了却没有海报
                }
            }
        }
        metas = m
        hidden = h
        dataVersion &+= 1
    }

    func refreshSeries() async {
        guard let list = try? await APIClient.shared.tvList() else { return }
        series = list.filter { $0.tmdbMiss != true && ($0.episodes ?? 0) > 0 }
            .sorted { ($0.added ?? "") > ($1.added ?? "") }
        DiskCache.save(series, "series.json")
        playback.relink(videos: videos, series: series)
        watchlist.relink(videos: videos, series: series)
        // 首页那排要先知道谁有字标：最新的 24 部先取
        await withTaskGroup(of: Void.self) { g in
            for s in series.prefix(24) { g.addTask { await self.ensureSeriesMeta(s) } }
        }
        DiskCache.save(seriesMetas, "series-metas.json")
    }

    func refreshHeroes() async {
        guard let list = try? await APIClient.shared.heroes(), !list.isEmpty else { return }
        heroes = list
        DiskCache.save(list, "heroes.json")
        await resolveHeroes()
    }

    // MARK: 首页头图（只放拿到了无字背景 + 字标的，最多 5 部）

    /// 挑好的头图（resolveHeroes 填）
    private(set) var heroPicks: [HeroPick] = []
    /// 至少挑过一轮了：之前头图位置先占着，不先放一张不合格的再换掉
    private(set) var heroResolved = false
    @ObservationIgnored private var heroResolving = false

    /// 头图每一部的预告片（视频路径 → hls）：头图挑好以后去问（和详情页同一次 Apple TV 查询），问到的交给 TrailerCache 在后台下到本机
    private(set) var heroTrailers: [String: String] = [:]
    /// 这一轮头图是哪一个 6 小时（heroSlotNow）
    @ObservationIgnored private var heroSlot: Int?
    /// 这回打开 App 里试过、拿不到无字横图或字标的（不再算进头图池）
    @ObservationIgnored private var heroMisses: Set<String> = []
    @ObservationIgnored private var heroTimer: Task<Void, Never>?

    /// 一轮 6 小时，按钟点切（时间戳整除 21600：同一轮里重开 App 还是那几部）
    static let heroSlotLength: Double = 21_600
    static var heroSlotNow: Int { Int(Date().timeIntervalSince1970 / heroSlotLength) }

    /// 记在本机的轮换：这一轮挑了哪几部、之前几轮放过哪些（seen，放过的先不再上，池子快轮完了才清）、上一轮那几部（清的时候也躲开）
    private struct HeroRotation: Codable {
        var slot: Int
        var picks: [String]
        var seen: [String]
        var previous: [String]
    }

    private static let heroRotationKey = "hero-rotation.v1"

    /// 挑头图（用户要求「每 6 小时更新一次，从高分的影片池中随机挑选，按照年份排序，尽可能不要在轮换中出现相同的影片」）：
    /// 池子是 TMDB 评分 7 分以上的电影（不到 15 部就放宽到 6.5 分；Apple TV 头图池里的片子也在里面，用它带的素材），
    /// 每一部都要有无字的横图（Apple TV 无字背景 → TMDB 没有字的剧照）和字标（Apple → TMDB），两样缺一就不上。
    /// 每一轮（6 小时）按这一轮的编号当种子打乱，放过的往后排：先挑没放过的，再挑早先放过的，上一轮那几部排最后；
    /// 没放过的不到 5 部就把记录清掉（只留上一轮的照样躲开）。挑出 5 部按年份新的在前。
    /// 片名要先认出来（Apple TV 按英文名查），所以元数据到了以后才挑
    func resolveHeroes() async {
        guard metaReady, !heroResolving else { return }
        heroResolving = true
        defer { heroResolving = false }
        let slot = Self.heroSlotNow
        if DemoData.enabled {
            // 演示数据：合成的头图本来就是无字背景 + 字标（照旧按头图池的顺序，不轮换、不读写本机记录）
            var seen = Set<String>()
            var cands: [(video: Video, hero: Hero?)] = []
            for h in heroes { if let v = video(path: h.path), seen.insert(v.path).inserted { cands.append((v, h)) } }
            heroPicks = Array(cands.compactMap { c -> HeroPick? in
                guard let h = c.hero, let w = h.background, let l = h.logo else { return nil }
                return HeroPick(video: c.video, hero: h, wide: w, tall: h.poster, logo: l)
            }.prefix(5))
            heroResolved = true
            heroSlot = slot
            return
        }
        var heroArt: [String: Hero] = [:]
        for h in heroes where heroArt[h.path] == nil { heroArt[h.path] = h }

        // 池子：Apple TV 头图池里的片子 + 全片库电影（同一部片的几个版本只算一次），评分够、知道有字标的
        var keys = Set<String>()
        var all: [Video] = []
        for h in heroes { if let v = video(path: h.path), keys.insert(atvArtKey(v)).inserted { all.append(v) } }
        for v in movies where keys.insert(atvArtKey(v)).inserted { all.append(v) }
        func rated(_ least: Double) -> [Video] {
            all.filter { v in
                guard !heroMisses.contains(v.path), let r = meta(v)?.rating, r >= least else { return false }
                return Self.nonEmpty(heroArt[v.path]?.logo) != nil || Self.nonEmpty(appleArt(v)?.logo) != nil
                    || Self.nonEmpty(meta(v)?.logo) != nil
            }
        }
        var pool = rated(7.0)
        if pool.count < 15 { pool = rated(6.5) }

        // 这一轮的记录：换了一轮，上一轮挑的记进「放过的」
        var rot = Self.loadHeroRotation() ?? HeroRotation(slot: slot, picks: [], seen: [], previous: [])
        if rot.slot != slot {
            rot = HeroRotation(slot: slot, picks: [], seen: rot.seen + rot.picks, previous: rot.picks)
        }
        let poolPaths = Set(pool.map(\.path))
        var seenSet = Set(rot.seen)
        let prevSet = Set(rot.previous)
        // 池子里没放过的不到 5 部：从头再轮（上一轮那几部照样躲开）
        if poolPaths.subtracting(seenSet).subtracting(prevSet).count < 5 {
            rot.seen = rot.previous
            seenSet = prevSet
        }

        // 候选顺序：这一轮已经挑好的（同一轮里重开 App 不变）→ 没放过的 → 早先放过的 → 上一轮的
        let shuffled = Self.shuffle(pool, seed: UInt32(truncatingIfNeeded: slot &* 7919 &+ 17))
        var order: [Video] = rot.picks.compactMap { p in pool.first { $0.path == p } ?? video(path: p) }
        order += shuffled.filter { !seenSet.contains($0.path) && !prevSet.contains($0.path) }
        order += shuffled.filter { seenSet.contains($0.path) && !prevSet.contains($0.path) }
        order += shuffled.filter { prevSet.contains($0.path) }
        // 池子里凑不够 5 部（池子太小、元数据还不全、素材拿不到）：照旧拿头图池和最新加入的补上，排在最后
        order += heroes.compactMap { video(path: $0.path) }
        order += newest
        var orderSeen = Set<String>()
        order = order.filter { orderSeen.insert($0.path).inserted }

        // 按顺序一批 8 部去拿素材，凑够 5 部就停（池子可能有上百部，不一口气全查）
        var picks: [HeroPick] = []
        var misses: [String] = []
        var i = 0
        while picks.count < 5 && i < order.count && i < 60 {
            let batch = Array(order[i..<min(i + 8, order.count)])
            i += batch.count
            let got = await withTaskGroup(of: (Int, HeroPick?).self) { g in
                for (j, v) in batch.enumerated() {
                    let h = heroArt[v.path]
                    g.addTask { (j, await self.heroPick(v, hero: h)) }
                }
                var out = [HeroPick?](repeating: nil, count: batch.count)
                for await (j, p) in g { out[j] = p }
                return out
            }
            for (j, p) in got.enumerated() {
                if let p { if picks.count < 5 { picks.append(p) } } else { misses.append(batch[j].path) }
            }
        }
        // 拿得到别的素材（网是通的）才把拿不到的记下来：断网时一部都拿不到，不能把整个池子都记成「没有」
        if !picks.isEmpty { heroMisses.formUnion(misses) }

        // 按年份排，新的在前（同一年的按挑出来的先后）
        var ranked: [(i: Int, p: HeroPick, y: Int)] = []
        for (n, p) in picks.enumerated() { ranked.append((n, p, p.hero?.year ?? year(p.video) ?? 0)) }
        ranked.sort { a, b in a.y != b.y ? a.y > b.y : a.i < b.i }
        picks = ranked.map { $0.p }

        if !picks.isEmpty {
            rot.picks = picks.map(\.video.path)
            // 记录别越记越长：只留还在片库里的，最多 300 部
            let known = Set(videos.map(\.path))
            rot.seen = Array(rot.seen.filter { known.contains($0) && !rot.picks.contains($0) }.suffix(300))
            Self.saveHeroRotation(rot)
        }
        if picks != heroPicks { heroPicks = picks }
        heroResolved = true
        heroSlot = slot
        scheduleHeroSlot()
        Perf.log("hero: slot \(slot), \(picks.count) picks from a pool of \(pool.count) (\(seenSet.count) shown recently)")
        let chosen = picks
        Task { await self.loadHeroTrailers(chosen) }
    }

    /// 换轮了（App 开着跨过了 6 小时的整点、或者从后台回来）：重新挑
    func heroSlotCheck() async {
        guard heroResolved, let s = heroSlot, s != Self.heroSlotNow else { return }
        await resolveHeroes()
    }

    /// 到下一轮的整点叫一次 heroSlotCheck（App 在后台时睡着的不算：回到前台时 HomeView 再叫一次）
    private func scheduleHeroSlot() {
        guard heroTimer == nil, !DemoData.enabled else { return }
        heroTimer = Task { [weak self] in
            while !Task.isCancelled {
                let now = Date().timeIntervalSince1970
                let len = AppModel.heroSlotLength
                let next = (floor(now / len) + 1) * len
                try? await Task.sleep(nanoseconds: UInt64(max(1, next - now + 2) * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                await self.heroSlotCheck()
            }
        }
    }

    /// 头图每一部的预告片：问到的交给 TrailerCache 在后台下到本机（只在 Wi-Fi、空闲时）；头图只放本机下好的那份
    private func loadHeroTrailers(_ picks: [HeroPick]) async {
        let found = await withTaskGroup(of: (String, String?).self, returning: [String: String].self) { g in
            for p in picks {
                let v = p.video
                g.addTask { (v.path, await self.trailers(for: v).first?.hls) }
            }
            var out: [String: String] = [:]
            for await (k, h) in g { if let h { out[k] = h } }
            return out
        }
        guard picks == heroPicks else { return }
        if found != heroTrailers { heroTrailers = found }
        TrailerCache.shared.wantHeroes(picks.compactMap { p in found[p.video.path].map { (key: p.video.path, hls: $0) } })
    }

    private static func loadHeroRotation() -> HeroRotation? {
        guard let data = UserDefaults.standard.data(forKey: heroRotationKey) else { return nil }
        return try? JSONDecoder().decode(HeroRotation.self, from: data)
    }

    private static func saveHeroRotation(_ r: HeroRotation) {
        if let data = try? JSONEncoder().encode(r) { UserDefaults.standard.set(data, forKey: heroRotationKey) }
    }

    /// 一部能不能上头图：无字横图 + 字标都拿到才算（Apple TV 素材表 → 这一部的 Apple TV 查询 → TMDB 全量结果）
    private func heroPick(_ v: Video, hero h: Hero?) async -> HeroPick? {
        let a = appleArt(v)
        var wide = Self.nonEmpty(a?.background)
        var logo = Self.nonEmpty(h?.logo) ?? Self.nonEmpty(a?.logo)
        var tall = Self.nonEmpty(h?.poster) ?? Self.nonEmpty(a?.tall)
        // 片名还没认出来就先不查（Apple TV 按英文名查；查不到会记成「没有」，等元数据到了再挑）
        if wide == nil || logo == nil || tall == nil, meta(v) != nil, let r = await atv(for: v) {
            wide = wide ?? Self.nonEmpty(r.background)
            logo = logo ?? Self.nonEmpty(r.logo)
            tall = tall ?? Self.nonEmpty(r.imageTall)
        }
        if wide == nil || logo == nil {
            let m = await fullMeta(for: v)
            wide = wide ?? Self.nonEmpty(m?.backdropClean)
            logo = logo ?? Self.nonEmpty(m?.logo)
        }
        guard let w = wide, let l = logo else { return nil }
        return HeroPick(video: v, hero: h, wide: AppleImage.sized(w, width: 1920) ?? w,
                        tall: tall.map { AppleImage.sized($0, width: 1290) ?? $0 }, logo: l)
    }

    /// 剧集的 TMDB（按剧集表认好的编号取，带字标 / 纯净海报 / 剧照）
    func ensureSeriesMeta(_ s: Series, force: Bool = false) async {
        if DemoData.enabled { return }
        if !force, seriesMetas[s.path] != nil { return }
        if seriesInflight.contains(s.path) { return }
        seriesInflight.insert(s.path)
        defer { seriesInflight.remove(s.path) }
        let q = s.en ?? s.zh ?? s.title ?? s.folder ?? ""
        if let m = try? await APIClient.shared.tmdb(query: q, year: s.year, type: "tv", id: s.tmdbId, full: true) {
            seriesMetas[s.path] = m
            if seriesMetas.count % 8 == 0 { DiskCache.save(seriesMetas, "series-metas.json") }
        }
    }

    /// 文件夹页（网页版 enterFolder）：子文件夹与视频。演示数据里是合成的，不请求接口
    func folderContents(_ f: LibraryFolder) async throws -> (folders: [LibraryFolder], videos: [Video]) {
        if DemoData.enabled { return DemoData.folderContents(f, videos: videos) }
        let root = libraryRoot
        let rel = !root.isEmpty && f.path.lowercased().hasPrefix(root.lowercased()) ? String(f.path.dropFirst(root.count)) : f.path
        let r = try await APIClient.shared.list(path: rel)
        let subs = r.items.filter { $0.type == "folder" }.map { LibraryFolder(name: $0.name, path: $0.path) }
        let vids = r.items.filter { $0.type != "folder" && FileName.isVideo($0.name) }
            .map { Video(name: $0.name, path: $0.path, size: $0.size, modified: $0.modified, added: $0.added) }
        return (subs, vids)
    }

    /// 片库总表之外临时出现的文件（文件夹页）：没问过 TMDB 的补问一次，一批 80 个
    func ensureMetas(for list: [Video]) async {
        if DemoData.enabled { return }
        let need = Array(Set(list.map(\.name).filter { metas[$0] == nil && !hidden.contains($0) }))
        guard !need.isEmpty else { return }
        for start in stride(from: 0, to: need.count, by: 80) {
            let chunk = Array(need[start..<min(start + 80, need.count)])
            if let r = try? await APIClient.shared.metaBatch(chunk) { apply([r]) }
        }
    }

    /// 电影详情：全量结果（字标、演员、纯净海报）
    func fullMeta(for v: Video) async -> Meta? {
        if DemoData.enabled { return metas[v.name] }
        if let hit = fullMetaCache[v.name] { return hit }
        if let m = try? await APIClient.shared.metaBatch([v.name], full: true), let hit = m[v.name], let meta = hit {
            fullMetaCache[v.name] = meta
            return meta
        }
        return metas[v.name]
    }

    /// 全量结果（演员、剧照、字标）记在内存里：资料库一章章滑过去、来回看详情页，不再重复问
    @ObservationIgnored private var fullMetaCache: [String: Meta] = [:]

    // MARK: 「首选音轨 · 自然」：原声语种

    /// 这一部的原声语种：先看详情页取过的全量结果，再看片库的简要结果（剧集看剧集的结果），TMDB 给了原始语言的那份优先。
    /// settled = 是 TMDB 给的原始语言；不是（按原名猜的、或者不知道：老 Worker、存在本机的旧结果）就值得重新问一次
    func audioOrigin(name: String, seriesPath: String?) -> (origin: TrackPrefs.Origin?, settled: Bool) {
        let found: [Meta?] = seriesPath.map { [seriesMetas[$0]] } ?? [fullMetaCache[name], metas[name]]
        for m in found { if let o = TrackPrefs.origin(of: m), o.fromTMDB { return (o, true) } }
        for m in found { if let o = TrackPrefs.origin(of: m) { return (o, false) } }
        return (nil, false)
    }

    /// 手上没有 TMDB 原始语言时重新问一次（电影问全量结果，剧集强制重取；这回打开 App 每部只问一次），问完再算
    func refreshAudioOrigin(name: String, seriesPath: String?) async -> TrackPrefs.Origin? {
        if !DemoData.enabled, originAsked.insert(seriesPath ?? name).inserted {
            if let sp = seriesPath {
                if let s = series.first(where: { $0.path == sp }) { await ensureSeriesMeta(s, force: true) }
            } else if let r = try? await APIClient.shared.metaBatch([name], full: true), let hit = r[name], let meta = hit {
                fullMetaCache[name] = meta
            }
        }
        return audioOrigin(name: name, seriesPath: seriesPath).origin
    }

    /// 这回打开 App 已经为「自然」重新问过的（电影的文件名 / 剧集的目录）
    @ObservationIgnored private var originAsked: Set<String> = []

    // MARK: 取用

    func meta(_ v: Video) -> Meta? { metas[v.name] }

    func title(_ v: Video) -> String {
        if let t = metas[v.name]?.title, !t.isEmpty { return t }
        return FileName.title(v.name)
    }

    func year(_ v: Video) -> Int? {
        if let y = metas[v.name]?.year, let n = Int(y.prefix(4)) { return n }
        return FileName.year(v.name)
    }

    func video(path: String) -> Video? { videos.first { $0.path == path } }

    /// 分享来的链接（cuven://movie/…）：找到这一部就推进它的详情页；片库还没载入就先记着
    func openLink(_ url: URL) {
        guard let t = DeepLink.parse(url) else { return }
        if let v = resolveLink(t) {
            openRequest = .movie(v)
        } else if movies.isEmpty {
            pendingLink = t
        } else {
            linkMissing = true
        }
    }

    /// 片库载入了：之前记着的链接再找一次
    func retryPendingLink() {
        guard let t = pendingLink, !movies.isEmpty else { return }
        pendingLink = nil
        if let v = resolveLink(t) { openRequest = .movie(v) } else { linkMissing = true }
    }

    private func resolveLink(_ t: DeepLink.Target) -> Video? {
        if let id = t.tmdbID, let v = movies.first(where: { meta($0)?.id == id }) { return v }
        if let p = t.pathID, let v = videos.first(where: { PrecacheFiles.id(for: $0.path) == p }) { return v }
        return nil
    }

    /// 派生清单按 dataVersion 缓存。先读一下 videos / metas：调用它的视图照样会跟着这两样刷新
    private func derive() {
        _ = videos.count
        _ = metas.count
        guard derivedVersion != dataVersion else { return }
        derivedVersion = dataVersion
        let t0 = Date()
        // 能显示的电影：有 TMDB、有海报。同一部片（同一个 TMDB 编号）有几个文件时只放规格最高的那一个
        // （用户要求「有重复影片时自动隐藏，仅展示较高规格」：分辨率 → 动态范围 → 音轨 → REMUX → 文件大；都一样的留最新入库的）。
        // 排在这部片最新入库的那个文件的位置上（「最新加入」的先后不跟着变）；别的版本在详情页里照样找得到（versions）
        var slot: [Int: Int] = [:]
        var out: [Video] = []
        for v in videos {
            guard let m = metas[v.name], m.hasArt, m.type != "tv" else { continue }
            if let id = m.id {
                if let i = slot[id] {
                    if Self.higherSpec(v, than: out[i]) { out[i] = v }
                    continue
                }
                slot[id] = out.count
            }
            out.append(v)
        }
        cachedMovies = out
        var by: [Int: [Video]] = [:]
        for v in out { if let y = year(v) { by[y, default: []].append(v) } }
        cachedYearGroups = by.keys.sorted(by: >).map { ($0, by[$0]!) }
        Perf.log("derive: \(out.count) movies, \(by.count) years in \(Perf.ms(since: t0)) ms")
    }

    var movies: [Video] {
        derive()
        return cachedMovies
    }

    /// 同一部片的两个文件比规格：a 比 b 高才换（一样高的不换：留着先排到的、最新入库的那个）
    static func higherSpec(_ a: Video, than b: Video) -> Bool {
        let ra = specRank(a.name), rb = specRank(b.name)
        if ra != rb { return ra > rb }
        return (a.size ?? 0) > (b.size ?? 0)
    }

    static func specRank(_ name: String) -> Int {
        MediaSpec(name: name).rank + (name.localizedCaseInsensitiveContains("remux") ? 1 : 0)
    }

    /// 同一部片的所有文件（4K / 1080p 等不同版本）
    func versions(of v: Video) -> [Video] {
        guard let id = metas[v.name]?.id else { return [v] }
        let all = videos.filter { metas[$0.name]?.id == id }
        return all.isEmpty ? [v] : all
    }

    var newest: [Video] { Array(movies.prefix(15)) }

    /// 去 Apple TV 找这部片：拿英文名（或原名）搜，片名要对得上、年份差一年以内才算同一部（免得是同名的别的片）。
    /// 预告片和官方素材（无字背景、竖版全屏图、字标）都从这一次里来；结果记在内存里，一部只问一次
    func atv(for v: Video) async -> AtvLookup? {
        if DemoData.enabled { return nil }
        if let hit = atvCache[v.path] { return hit }
        let m = meta(v)
        let (r, transient) = await atvFetch(names: [m?.en, m?.originalTitle], year: year(v), type: "Movie")
        // 网络断了 / 后端出错：这次算没有，但不记下来（下次再问）；确定没有（404、对不上）才记
        if !transient { atvCache[v.path] = .some(r) }
        return r
    }

    /// 这一部（电影或剧集，按路径）的 Apple TV 这次打开 App 里已经问过了：.some(nil) 是问过、没有；nil 是还没问
    func atvCached(path: String) -> AtvLookup?? { atvCache[path] }

    // MARK: 资料库：只放有预告片的电影（Apple TV 上的公开预告，和详情页同一次查询）

    /// path → 有没有预告片。查过的存在本地（trailer-index.json）：有的 30 天、没有的 7 天后再查一次
    private(set) var trailerKnown: [String: Bool] = [:]
    @ObservationIgnored private var trailerStamps: [String: Double] = [:]
    /// 正在后台查（资料库空着的时候显示转圈）
    private(set) var trailerScanning = false
    /// 全片库都查过一轮了（本地记着的那份已经覆盖全片库，也算）：资料库这时开始首尾相接地循环；
    /// 之后再查到新入库的，按顺序插进去，不会把整个资料库清空重来
    private(set) var trailerScanDone = false
    /// 上一轮查到一半连着出错（断网、后端出错），停下了：资料库空着的话要说清楚、给一颗重试
    private(set) var trailerScanFailed = false

    /// 资料库的顺序（网页版 lib-showcase 的 sortOrder）：上映新的在前；同一天按入库时间；再按片名。
    /// 按 dataVersion 缓存（资料库每换一章都要读一次，全片库排一遍不便宜）
    var showcaseOrder: [Video] {
        let list = movies
        if showcaseOrderVersion == dataVersion { return showcaseOrderCache }
        let sorted = list.sorted { a, b in
            let ra = releaseKey(a), rb = releaseKey(b)
            if ra != rb { return ra > rb }
            if a.addedKey != b.addedKey { return a.addedKey > b.addedKey }
            return title(a).localizedCompare(title(b)) == .orderedAscending
        }
        showcaseOrderCache = sorted
        showcaseOrderVersion = dataVersion
        return sorted
    }

    @ObservationIgnored private var showcaseOrderCache: [Video] = []
    @ObservationIgnored private var showcaseOrderVersion = -1

    // MARK: 片段合集（主页「探索片段合集」那一排、刷视频式浏览：ClipCollections.swift）

    /// 一个片段合集里的片子（ClipCollections.swift）。两层缓存：
    /// · 哪几部（认迪士尼 / 漫威 / DC 要把片名过一遍）：片库、剧集、剧集资料变了才重算；
    /// · 排序（查到有预告片的在前）：预告片索引一变就重排，只是分三档，便宜
    func clipEntries(_ c: ClipCollection) -> [HomeEntry] {
        let list = movies
        let membersKey = "\(dataVersion)-\(series.count)-\(seriesMetas.count)"
        if clipMembersKey != membersKey {
            clipMembers = [:]
            clipOrdered = [:]
            clipMembersKey = membersKey
        }
        let tier = trailerKnown.count
        if clipOrderedTier != tier {
            clipOrdered = [:]
            clipOrderedTier = tier
        }
        if let hit = clipOrdered[c] { return hit }
        let members: [HomeEntry]
        if let m = clipMembers[c] {
            members = m
        } else {
            // 同一部剧的几季 / 两份只出一张（用户反馈重复影片）；这一层有缓存，片库变了才重算
            members = uniqueShows(ClipCollection.members(c, model: self, movies: list))
            clipMembers[c] = members
        }
        let out = ClipCollection.ordered(members, model: self)
        clipOrdered[c] = out
        return out
    }

    @ObservationIgnored private var clipMembers: [ClipCollection: [HomeEntry]] = [:]
    @ObservationIgnored private var clipMembersKey = ""
    @ObservationIgnored private var clipOrdered: [ClipCollection: [HomeEntry]] = [:]
    @ObservationIgnored private var clipOrderedTier = -1

    private func releaseKey(_ v: Video) -> String {
        if let d = meta(v)?.releaseDate, !d.isEmpty { return d }
        if let y = year(v) { return String(y) + "-07-01" }
        return ""
    }

    /// 资料库里放的：按顺序，只要查到有预告片的。
    /// 第一轮还在查的时候，还没查到的那一部后面先不放——查到了再往后接，不会插进已经滑过的位置；
    /// 一轮查完以后，这次没问成的先跳过（下次再问）
    var showcaseMovies: [Video] {
        var out: [Video] = []
        for v in showcaseOrder {
            guard let has = trailerKnown[v.path] else {
                if trailerScanDone { continue } else { break }
            }
            if has { out.append(v) }
        }
        return out
    }

    // MARK: 探索（标签栏第二格，以前叫「资料库」）的顺序

    /// 这一轮探索的种子（用户要求「每次打开都不一样，像 Netflix 一样」）：每次启动换一个；
    /// 回到前台隔了 30 分钟以上换一个；在「探索」上再点一下「探索」也换。同一轮里顺序不变（切到别的标签再回来，还在原来那一部）
    private(set) var exploreSeed = UInt64.random(in: 1...UInt64.max)
    @ObservationIgnored private var exploreAwayAt: Date?
    @ObservationIgnored private var exploreCache: (key: String, list: [Video])?

    func reshuffleExplore() {
        exploreSeed = UInt64.random(in: 1...UInt64.max)
    }

    /// App 进后台 / 回到前台（RootView 的 scenePhase）：离开超过 30 分钟就换一轮
    func exploreScene(active: Bool) {
        if active {
            if let t = exploreAwayAt, Date().timeIntervalSince(t) > 30 * 60 { reshuffleExplore() }
            exploreAwayAt = nil
        } else if exploreAwayAt == nil {
            exploreAwayAt = Date()
        }
    }

    /// 探索里放的：有预告片的电影（showcaseMovies），按这一轮的种子加权随机排（ExploreOrder）：
    /// 分高、值得一看的大概率在前，年份混着来，同一类型、同一年不连着出
    var exploreMovies: [Video] {
        let base = showcaseMovies
        let key = "\(exploreSeed)-\(dataVersion)-\(base.count)-\(watchlist.items.count)-\(metas.count)"
        if let c = exploreCache, c.key == key { return c.list }
        let list = ExploreOrder.order(base, seed: exploreSeed, score: { exploreScore($0) },
                                      genre: { meta($0)?.genres?.first }, year: { year($0) })
        exploreCache = (key, list)
        return list
    }

    /// 值不值得先看：TMDB 评分为主（没有评分的按 6.5 算）；7.5 分以上（高分）再加一点，近两年上映的加一点，
    /// 在「想看」里的加一点；看了一部分的（主页「继续观看」里已经有）往后放一点
    private func exploreScore(_ v: Video) -> Double {
        var s = meta(v)?.rating.flatMap { $0 > 0 ? $0 : nil } ?? 6.5
        if s >= 7.5 { s += 0.6 }
        if let y = year(v), y >= Calendar.current.component(.year, from: Date()) - 1 { s += 0.4 }
        if watchlist.contains(v.path) { s += 0.5 }
        if let e = playback.entry(v.path), e.fraction > 0.03 { s -= 0.8 }
        return s
    }

    /// 后台按资料库的顺序一部一部查有没有预告片（4 部一起），边查边放出来
    func scanTrailers() async {
        if trailerScanning { return }
        if DemoData.enabled {
            // 演示数据不连网：都当有（画幅停在合成的剧照上，慢推镜）
            for v in movies { trailerKnown[v.path] = true }
            trailerScanDone = true
            return
        }
        let order = showcaseOrder
        // 片库还没载入：没什么可查的，也不算查完（不然资料库会拿半截清单开始循环）
        guard !order.isEmpty else { return }
        trailerScanning = true
        trailerScanFailed = false
        defer { trailerScanning = false }
        // 本地记着的那份已经覆盖全片库（有的过期了也先照用，后台再问）：资料库直接按它放
        if order.allSatisfy({ trailerKnown[$0.path] != nil }) { trailerScanDone = true }
        let now = Date().timeIntervalSince1970
        let todo = order.filter { v in
            guard let has = trailerKnown[v.path], let t = trailerStamps[v.path] else { return true }
            return now - t > (has ? 30 : 7) * 86_400
        }
        var i = 0, streak = 0
        while i < todo.count {
            let chunk = Array(todo[i..<min(i + 4, todo.count)])
            let results = await withTaskGroup(of: (String, Bool?).self) { g in
                for v in chunk { g.addTask { (v.path, await self.trailerProbe(v)) } }
                var r: [(String, Bool?)] = []
                for await x in g { r.append(x) }
                return r
            }
            let stamp = Date().timeIntervalSince1970
            for (p, has) in results {
                guard let has else { streak += 1; continue }
                if trailerKnown[p] != has { trailerKnown[p] = has }
                trailerStamps[p] = stamp
                streak = 0
            }
            i += chunk.count
            if i % 24 == 0 { saveTrailerIndex() }
            // 连着出错（断网、后端出错）：先停，下次打开资料库 / 刷新再接着查
            if streak >= 8 || Task.isCancelled { break }
        }
        saveTrailerIndex()
        // 被取消的（App 退出这一轮）不算出错，也不算查完
        if Task.isCancelled { return }
        trailerScanFailed = streak >= 8
        trailerScanDone = true
        Perf.log("trailers: \(trailerKnown.values.filter { $0 }.count) of \(trailerKnown.count) movies have one")
    }

    /// 这部有没有预告片：nil = 这次没问成（网络 / 后端出错），下次再问
    private func trailerProbe(_ v: Video) async -> Bool? {
        if let hit = atvCache[v.path] { return !Self.playable(hit?.trailers).isEmpty }
        let m = meta(v)
        let (r, transient) = await atvFetch(names: [m?.en, m?.originalTitle], year: year(v), type: "Movie")
        if transient { return nil }
        atvCache[v.path] = .some(r)
        return !Self.playable(r?.trailers).isEmpty
    }

    static func playable(_ t: [Trailer]?) -> [Trailer] {
        (t ?? []).filter { !$0.hls.isEmpty && !$0.hls.contains("/subscription/") }
    }

    private func saveTrailerIndex() {
        DiskCache.save(TrailerIndex(known: trailerKnown, stamps: trailerStamps), "trailer-index.json")
    }

    /// 剧集：同样按英文名找，类型要是 Show
    func atv(for s: Series) async -> AtvLookup? {
        if DemoData.enabled { return nil }
        if let hit = atvCache[s.path] { return hit }
        let m = seriesMetas[s.path]
        let r = await atvLookup(names: [s.en, m?.en, m?.originalTitle], year: Int(s.year ?? "") ?? m?.year.flatMap { Int($0.prefix(4)) }, type: "Show")
        atvCache[s.path] = .some(r)
        return r
    }

    private func atvLookup(names: [String?], year: Int?, type: String) async -> AtvLookup? {
        await atvFetch(names: names, year: year, type: type).0
    }

    /// 同上，另外说清楚「没有」是确定的（404、对不上）还是这次没问成（transient：网络断了、后端出错）
    private func atvFetch(names: [String?], year: Int?, type: String) async -> (AtvLookup?, transient: Bool) {
        let latin = names.compactMap { $0 }
            .first { !$0.isEmpty && $0.range(of: "\\p{Han}", options: .regularExpression) == nil }
        guard let name = latin else { return (nil, false) }
        let r: AtvLookup
        do { r = try await APIClient.shared.atvLookup(title: name) }
        catch APIError.http(let code, _) where code == 404 { return (nil, false) }
        catch { return (nil, true) }
        return (atvValidate(r, name: name, year: year, type: type), false)
    }

    private func atvValidate(_ r: AtvLookup, name: String, year: Int?, type: String) -> AtvLookup? {
        if let t = r.type, t != type { return nil }
        if let y = year, let ry = r.year, abs(y - ry) > 1 { return nil }
        // 搜索层同名的优先，没有同名就给排序第一条：片名得对得上才敢用它的图
        func norm(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let a = norm(name), b = norm(r.title ?? "")
        guard !a.isEmpty, !b.isEmpty, a == b || ((a.hasPrefix(b) || b.hasPrefix(a)) && year != nil && r.year == year) else { return nil }
        Perf.log("atv: matched (trailers \(r.trailers?.count ?? 0), tall \(r.imageTall != nil), bg \(r.background != nil))")
        return r
    }

    /// 资料库展映的预告片：Apple TV 上这部片的公开预告（订阅才看得了的花絮不要）
    func trailers(for v: Video) async -> [Trailer] {
        if DemoData.enabled { return DemoData.trailers(for: v) }
        guard let r = await atv(for: v) else { return [] }
        return Self.playable(r.trailers)
    }

    // MARK: 全片库的 Apple TV 素材（Apple TV 优先，TMDB 兜底）

    /// 素材表的键：认出了 TMDB 编号的按编号（同一部片的 4K / 1080p 等版本共用一份），没认出的按文件路径
    func atvArtKey(_ v: Video) -> String {
        if let id = metas[v.name]?.id { return "m\(id)" }
        return v.path
    }

    /// 这部电影在 Apple TV 上的素材（还没问到 / Apple TV 上没有就是 nil）
    func appleArt(_ v: Video) -> AtvArt? { atvArtIndex[atvArtKey(v)] }

    /// 去 Apple TV 对全片库的电影：片名、年份齐了以后在后台跑，一批 100 部；
    /// 后端每次有预算，问不完的放在 pending 里，过一秒接着问。对上的、没有的都记在本地：
    /// 没有的过 3 天再问，对上的 14 天后刷新一次（Apple 换图）。后端还没这个接口（404）就这次打开不再问
    func loadAtvArt() async {
        if DemoData.enabled || atvArtUnavailable || atvArtLoading { return }
        atvArtLoading = true
        defer { atvArtLoading = false }
        let now = Date().timeIntervalSince1970
        let missTTL: Double = 3 * 86_400, refreshAfter: Double = 14 * 86_400

        // 先问首页上看得见的（今日推荐、最新加入），再按入库新旧问其余的；没问过的在前，要刷新的在后
        var fresh: [AtvArtQuery] = [], stale: [AtvArtQuery] = []
        var seen = Set<String>()
        for v in todayPicks + movies {
            let k = atvArtKey(v)
            guard seen.insert(k).inserted else { continue }
            if let t = atvArtMisses[k], now - t < missTTL { continue }
            let known = atvArtIndex[k] != nil
            if known, let t = atvArtStamps[k], now - t < refreshAfter { continue }
            guard let q = atvArtQuery(v, key: k) else { continue }
            if known { stale.append(q) } else { fresh.append(q) }
        }
        var queue = fresh + stale
        guard !queue.isEmpty else { return }
        Perf.log("atv-art: asking for \(queue.count) movies (\(fresh.count) new)")

        // 结果攒在副本上，隔几轮才写回一次：看着这张表的视图（首页每一张卡）不至于每秒都重画。
        // 第一轮马上写回——那一批就是首页上看得见的几部
        var index = atvArtIndex
        func publish() { if index != atvArtIndex { atvArtIndex = index } }
        var rounds = 0, stalls = 0
        while !queue.isEmpty && rounds < 40 {
            rounds += 1
            let batch = Array(queue.prefix(100))
            let resp: AtvArtResponse
            do {
                resp = try await APIClient.shared.atvArt(batch)
            } catch is APIClient.AtvArtUnavailable {
                atvArtUnavailable = true
                Perf.log("atv-art: endpoint not deployed, TMDB art only")
                break
            } catch {
                break      // 网络断了：下次刷新再接着问
            }
            let pending = Set(resp.pending)
            let stamp = Date().timeIntervalSince1970
            for q in batch where !pending.contains(q.k) {
                if let art = resp.items[q.k] {
                    index[q.k] = art
                    atvArtStamps[q.k] = stamp
                    atvArtMisses[q.k] = nil
                } else if index[q.k] == nil {
                    atvArtMisses[q.k] = stamp            // Apple TV 上没有：过 3 天再问
                } else {
                    atvArtStamps[q.k] = stamp            // 以前对上过、这次没回：留着旧的，过 14 天再刷新
                }
            }
            if rounds == 1 || rounds % 4 == 0 { publish() }
            let done = batch.count - pending.count
            queue = batch.filter { pending.contains($0.k) } + Array(queue.dropFirst(batch.count))
            if rounds % 8 == 0 { saveAtvArt() }
            if done == 0 {
                stalls += 1
                if stalls >= 2 { break }        // 后端这会儿一部也问不动：下次再来
            } else {
                stalls = 0
            }
            if !pending.isEmpty { try? await Task.sleep(nanoseconds: 1_000_000_000) }
        }
        publish()
        saveAtvArt()
        Perf.log("atv-art: \(atvArtIndex.count) matched, \(atvArtMisses.count) not on Apple TV, \(queue.count) left after \(rounds) rounds")
    }

    /// 问一部用的片名：TMDB 的英文名、原名、文件名里的片名，只留拉丁字母的（Apple TV 美区目录按英文名搜），最多三个
    private func atvArtQuery(_ v: Video, key: String) -> AtvArtQuery? {
        let m = meta(v)
        var names: [String] = []
        for raw in [m?.en, m?.originalTitle, FileName.title(v.name)] {
            guard let s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty,
                  s.range(of: "\\p{Han}", options: .regularExpression) == nil,
                  s.range(of: "[A-Za-z]", options: .regularExpression) != nil,
                  !names.contains(where: { $0.caseInsensitiveCompare(s) == .orderedSame }) else { continue }
            names.append(s)
            if names.count == 3 { break }
        }
        guard !names.isEmpty else { return nil }
        return AtvArtQuery(k: key, t: names, y: year(v))
    }

    private func saveAtvArt() {
        DiskCache.save(AtvArtCache(items: atvArtIndex, stamps: atvArtStamps, misses: atvArtMisses), "atv-art.json")
    }

    /// 海报卡（2:3）：纯净画面 + 字标优先（卡下不写片名，画面自己说明是哪一部：T20）——
    /// Apple 无字的竖版主视觉 + 字标 → TMDB 纯净海报 + 字标 → Apple 印着片名的海报 → TMDB 海报（印着片名）。
    /// 字标先用 Apple 的、没有再用 TMDB 的；两样都没有就用印着片名的那张，免得卡上一个字都没有、认不出是哪一部。
    /// width 是卡宽（点）：Apple 的图按 点 × 3 要像素（F62），TMDB 的取 w342 / w500
    func posterArt(_ v: Video, width: CGFloat = 0) -> (url: URL?, logo: URL?) {
        let m = meta(v)
        let a = appleArt(v)
        let px = width > 0 ? Int(min(1200, max(342, width * 3)).rounded()) : 0
        let size = width * 3 > 342 ? "w500" : "w342"
        let logo = (Self.nonEmpty(a?.logo) ?? Self.nonEmpty(m?.logo)).flatMap { TMDBImage.url($0, "w500") }
        if let t = Self.nonEmpty(a?.tall), let logo { return (URL(string: AppleImage.sized(t, width: px) ?? t), logo) }
        if let c = Self.nonEmpty(m?.posterClean), let logo { return (TMDBImage.url(c, size), logo) }
        if let p = Self.nonEmpty(a?.poster) { return (URL(string: AppleImage.sized(p, width: px) ?? p), nil) }
        return (TMDBImage.url(m?.poster ?? m?.posterClean, size), nil)
    }

    /// 精选卡的画面：无字的竖版画面 + 字标，两样都有才算（和头图同一个门槛：没有字标、只有印着片名的海报的不上）。
    /// Apple TV 的竖版主视觉 → TMDB 纯净海报；卡大，要的图也大一档
    func featuredArt(_ v: Video, width: CGFloat = 0) -> (url: URL?, logo: URL?)? {
        let m = meta(v)
        let a = appleArt(v)
        guard let logo = (Self.nonEmpty(a?.logo) ?? Self.nonEmpty(m?.logo)).flatMap({ TMDBImage.url($0, "w500") }) else { return nil }
        let px = Int(min(1600, max(600, width * 3)).rounded())
        if let t = Self.nonEmpty(a?.tall) { return (URL(string: AppleImage.sized(t, width: px) ?? t), logo) }
        if let c = Self.nonEmpty(m?.posterClean) { return (TMDBImage.url(c, "w780"), logo) }
        return nil
    }

    /// 做得成精选卡吗（featuredArt 的便宜版：只看有没有，不拼地址；主页每次刷新都要对全片库问一遍）
    private func featuredReady(_ v: Video) -> Bool {
        let m = meta(v), a = appleArt(v)
        guard Self.nonEmpty(a?.logo) != nil || Self.nonEmpty(m?.logo) != nil else { return false }
        return Self.nonEmpty(a?.tall) != nil || Self.nonEmpty(m?.posterClean) != nil
    }

    /// 主页「精选电影」：评分高的在前（同分的新上映在前、再按入库），只要做得成精选卡的、评分 6 分以上的
    func featuredMovies(limit: Int = .max) -> [Video] {
        var list: [(video: Video, rating: Double, release: String)] = []
        for v in movies {
            guard let r = meta(v)?.rating, r >= 6, featuredReady(v) else { continue }
            list.append((v, r, meta(v)?.releaseDate ?? year(v).map { String($0) } ?? ""))
        }
        list.sort { a, b in
            if a.rating != b.rating { return a.rating > b.rating }
            if a.release != b.release { return a.release > b.release }
            return a.video.addedKey > b.video.addedKey
        }
        return list.prefix(limit).map(\.video)
    }

    /// 精选区顶上的立体海报封面：印着片名的海报（一眼认得出是哪一部）——Apple 海报 → TMDB 海报 → Apple 竖版主视觉
    func coverArt(_ v: Video) -> URL? {
        let a = appleArt(v)
        if let p = Self.nonEmpty(a?.poster) { return URL(string: AppleImage.sized(p, width: 450) ?? p) }
        let m = meta(v)
        if let p = Self.nonEmpty(m?.poster) ?? Self.nonEmpty(m?.posterClean) { return TMDBImage.url(p, "w500") }
        if let t = Self.nonEmpty(a?.tall) { return URL(string: AppleImage.sized(t, width: 450) ?? t) }
        return nil
    }

    // MARK: 演员个人页

    @ObservationIgnored private var personCache: [Int: PersonInfo] = [:]

    /// 演员的简介、出生、作品编号：问一次记在内存里；演示数据给一份本地编的（不连网）；
    /// 老 Worker 没有这个接口、或者出错，是 nil（页面照样出来：照片、名字、库中作品按演员表找）
    func person(_ m: CastMember) async -> PersonInfo? {
        guard let id = m.id else { return nil }
        if let hit = personCache[id] { return hit }
        if DemoData.enabled {
            let p = DemoData.person(m)
            personCache[id] = p
            return p
        }
        guard let p = try? await APIClient.shared.person(id: id) else { return nil }
        personCache[id] = p
        return p
    }

    /// 这位演员在片库里的作品，日期新的在前、一部只出一次：
    /// 有作品编号（新 Worker）就按编号对——电影对 TMDB 电影编号、剧集对剧集编号，全片库都对得上；
    /// 没有就翻片库里的演员表（看过的详情页、简要结果里带的）
    func works(of m: CastMember, info: PersonInfo?) -> [ActorWork] {
        var out: [ActorWork] = []
        var seen = Set<String>()
        if let credits = info?.credits, !credits.isEmpty {
            var movieIndex: [Int: Video] = [:]
            for v in movies { if let id = meta(v)?.id, movieIndex[id] == nil { movieIndex[id] = v } }
            // 同一部剧有几季 / 两份时留哪一季，和主页的卡同一条规矩（preferredSeason）
            var seriesIndex: [Int: Series] = [:]
            for s in series {
                guard let id = Self.showID(s, meta: seriesMetas[s.path]) else { continue }
                if let cur = seriesIndex[id], !Self.preferredSeason(s, over: cur) { continue }
                seriesIndex[id] = s
            }
            for c in credits {
                if c.mediaType == "movie", let v = movieIndex[c.id], seen.insert("m\(c.id)").inserted {
                    out.append(ActorWork(entry: .movie(v), character: c.character, date: c.date))
                } else if c.mediaType == "tv", let s = seriesIndex[c.id], seen.insert("t\(c.id)").inserted {
                    out.append(ActorWork(entry: .series(s), character: c.character, date: c.date))
                }
            }
            return out
        }
        func role(_ cast: [CastMember]?) -> CastMember? {
            cast?.first { c in
                if let id = m.id, let cid = c.id { return id == cid }
                return !m.name.isEmpty && c.name == m.name
            }
        }
        for v in movies {
            let mm = fullMetaCache[v.name] ?? meta(v)
            if let c = role(mm?.cast), seen.insert("m:" + v.path).inserted {
                out.append(ActorWork(entry: .movie(v), character: c.character, date: mm?.releaseDate ?? mm?.year))
            }
        }
        // 剧集：先挑出有这位演员的季，再一部只留一张（和主页同一条去重规矩）
        var shows: [ActorWork] = []
        for s in series {
            let sm = seriesMetas[s.path]
            if let c = role(sm?.cast) {
                shows.append(ActorWork(entry: .series(s), character: c.character, date: sm?.releaseDate ?? sm?.year ?? s.year))
            }
        }
        out += dedupeShows(shows) { w in
            if case .series(let s) = w.entry { return s }
            return nil
        }
        out.sort { ($0.date ?? "") > ($1.date ?? "") }
        return out
    }

    /// 这一项有没有字标（Apple TV 的或 TMDB 的）：主页年份那两排只放有字标的（用户要求）
    func hasLogo(_ e: HomeEntry) -> Bool {
        switch e {
        case .movie(let v): return wideLockupArt(v).logo != nil
        case .series(let s): return seriesWideArt(s).logo != nil
        }
    }

    // MARK: 主页「编辑推荐」与结尾的字标卡

    @ObservationIgnored private var editorsPickCache: (day: Int, path: String)?

    /// 主页「编辑推荐」：每天换一部——评分 6.5 分以上、做得成精选卡（有字标和竖版画面）的电影，不和头图那几部撞车；
    /// 查到有预告片的在前（没查过的也行：展示区自己去问，问不到就停在画面上），在排得最靠前的 12 部里按日子轮着挑。
    /// 同一天打开几次都是同一部（头图定下来以后才记住，免得和后来定的头图撞车）
    func editorsPick() -> Video? {
        let day = Int(Date().timeIntervalSince1970 / 86_400)
        if let c = editorsPickCache, c.day == day, let v = video(path: c.path) { return v }
        let heroPaths = Set(heroPicks.map { $0.video.path })
        var pool: [(video: Video, rating: Double, known: Int)] = []
        for v in movies {
            guard !heroPaths.contains(v.path), let r = meta(v)?.rating, r >= 6.5, featuredReady(v),
                  trailerKnown[v.path] != false else { continue }
            pool.append((v, r, trailerKnown[v.path] == true ? 1 : 0))
        }
        pool.sort { a, b in a.known != b.known ? a.known > b.known : a.rating > b.rating }
        let top = Array(pool.prefix(12))
        guard !top.isEmpty else { return nil }
        let pick = top[day % top.count].video
        if heroResolved { editorsPickCache = (day, pick.path) }
        return pick
    }

    /// 主页最底下那两排横着走的 16:9 卡（用户要求照 Apple TV+ 那一页的结尾：横版、带片名字标）：最新入库的电影，
    /// Apple 带片名排版的 16:9 成品图优先（字标印在图上，排得最好看）；没有就用无字背景 + 字标；两样都没有的不放。最多 limit 张
    func finaleTiles(limit: Int = 24) -> [FinaleTile] {
        var out: [FinaleTile] = []
        for v in movies {
            let a = appleArt(v), m = meta(v)
            if let w = Self.nonEmpty(a?.wide) {
                out.append(FinaleTile(id: v.path, art: URL(string: AppleImage.sized(w, width: 960) ?? w), logo: nil))
            } else if let logo = (Self.nonEmpty(a?.logo) ?? Self.nonEmpty(m?.logo)).flatMap({ TMDBImage.url($0, "w500") }),
                      let bg = Self.nonEmpty(a?.background).flatMap({ URL(string: AppleImage.sized($0, width: 960) ?? $0) })
                        ?? TMDBImage.url(Self.nonEmpty(m?.backdropClean) ?? Self.nonEmpty(m?.backdrop), "w780") {
                out.append(FinaleTile(id: v.path, art: bg, logo: logo))
            }
            if out.count >= limit { break }
        }
        return out
    }

    /// 主页「精选剧集」：评分 6 分以上、有海报也有剧照的剧，评分高的在前（同分的新的在前）；同一部剧的几季只出一次
    func featuredSeries(limit: Int = .max) -> [Series] {
        var list: [(series: Series, rating: Double, year: String)] = []
        for s in series {
            let m = seriesMetas[s.path]
            guard let r = m?.rating, r >= 6,
                  Self.nonEmpty(m?.poster) != nil || Self.nonEmpty(m?.posterClean) != nil,
                  Self.nonEmpty(m?.backdrop) != nil else { continue }
            list.append((s, r, s.year ?? m?.year ?? ""))
        }
        // 和其它几排同一条去重规矩（showKey / preferredSeason）：留哪一季不再看谁先排到
        list = dedupeShows(list, by: { $0.series })
        list.sort { a, b in a.rating != b.rating ? a.rating > b.rating : a.year > b.year }
        return list.prefix(limit).map(\.series)
    }

    /// 剧集的海报卡：TMDB 纯净海报 + 字标 → 印着剧名的海报
    func seriesPosterArt(_ s: Series, width: CGFloat = 0) -> (url: URL?, logo: URL?) {
        let m = seriesMetas[s.path]
        let size = width * 3 > 342 ? "w500" : "w342"
        if let c = Self.nonEmpty(m?.posterClean), let l = Self.nonEmpty(m?.logo) { return (TMDBImage.url(c, size), TMDBImage.url(l, "w500")) }
        return (TMDBImage.url(m?.poster ?? m?.posterClean, size), nil)
    }

    /// 16:9 卡：Apple 无字背景 + 字标 → TMDB 剧照 + 字标 → Apple 带片名排版的 16:9 → TMDB 剧照
    func wideLockupArt(_ v: Video) -> (url: URL?, logo: URL?) {
        let m = meta(v)
        let a = appleArt(v)
        let logo = (Self.nonEmpty(a?.logo) ?? Self.nonEmpty(m?.logo)).flatMap { TMDBImage.url($0, "w500") }
        if let b = Self.nonEmpty(a?.background), let logo { return (URL(string: b), logo) }
        if let b = Self.nonEmpty(m?.backdrop), let logo { return (TMDBImage.url(b, "w780"), logo) }
        if let w = Self.nonEmpty(a?.wide) { return (URL(string: w), nil) }
        return (TMDBImage.url(m?.backdrop ?? m?.posterClean ?? m?.poster, "w780"), nil)
    }

    /// 剧集的 16:9 卡：TMDB 剧照 + 字标
    func seriesWideArt(_ s: Series) -> (url: URL?, logo: URL?) {
        let m = seriesMetas[s.path]
        let logo = Self.nonEmpty(m?.logo).flatMap { TMDBImage.url($0, "w500") }
        return (TMDBImage.url(m?.backdrop ?? m?.posterClean ?? m?.poster, "w780"), logo)
    }

    /// 小海报（列表行、合集卡和年份卡的底条、编辑推荐的面板）：Apple 海报 → TMDB 海报 → TMDB 纯净海报 → Apple 竖版主视觉。
    /// 竖版主视觉排到最后（用户截图：小海报上半截是画、下半截是一大块纯色——那种图下面是给字留的空，裁成 2:3 只剩那一块）
    func thumbArt(_ v: Video) -> URL? {
        let a = appleArt(v), m = meta(v)
        if let p = Self.nonEmpty(a?.poster) { return URL(string: AppleImage.sized(p, width: 200) ?? p) }
        if let p = Self.nonEmpty(m?.poster) ?? Self.nonEmpty(m?.posterClean) { return TMDBImage.url(p, "w185") }
        if let t = Self.nonEmpty(a?.tall) { return URL(string: AppleImage.sized(t, width: 200) ?? t) }
        return nil
    }

    /// 16:9 卡：Apple 带片名排版的 16:9 → Apple 无字背景 → TMDB 横版剧照 → TMDB 海报
    func wideArt(_ v: Video) -> URL? {
        if let a = appleArt(v), let s = Self.nonEmpty(a.wide) ?? Self.nonEmpty(a.background) { return URL(string: s) }
        let m = meta(v)
        return TMDBImage.url(m?.backdrop ?? m?.posterClean ?? m?.poster, "w780")
    }

    /// 无字的大画面（详情页横拿、资料库画幅、头图、播放器封面）：Apple 无字背景 → Apple 16:9 → TMDB 剧照。
    /// 原样的地址字符串（这些地方自己用 TMDBImage.url 换尺寸）；Apple 的要大一号，铺满展开的屏也清楚
    func backgroundArtString(_ v: Video) -> String? {
        if let a = appleArt(v), let s = Self.nonEmpty(a.background) ?? Self.nonEmpty(a.wide) {
            return AppleImage.sized(s, width: 1920)
        }
        let m = meta(v)
        return Self.nonEmpty(m?.backdrop) ?? Self.nonEmpty(m?.poster)
    }

    /// 竖版全屏图（详情页竖拿、头图）：只有 Apple TV 有；要大图
    func tallArtString(_ v: Video) -> String? {
        AppleImage.sized(Self.nonEmpty(appleArt(v)?.tall), width: 1290)
    }

    /// 字标：Apple → TMDB（原样的地址字符串，交给 LogoImage 前用 TMDBImage.url 换尺寸）
    func logoArtString(_ v: Video) -> String? {
        Self.nonEmpty(appleArt(v)?.logo) ?? Self.nonEmpty(meta(v)?.logo)
    }

    func backgroundArt(_ v: Video) -> URL? { TMDBImage.url(backgroundArtString(v), "w1280") }

    func logoArt(_ v: Video) -> URL? { TMDBImage.url(logoArtString(v), "w500") }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }

    /// 片库里的类型（电影 + 剧集都算），片子多的在前：搜索页「浏览」的格子
    var genres: [(name: String, count: Int)] {
        var n: [String: Int] = [:]
        for v in movies { for g in meta(v)?.genres ?? [] { n[g, default: 0] += 1 } }
        for s in series { for g in seriesMetas[s.path]?.genres ?? [] { n[g, default: 0] += 1 } }
        return n.map { (name: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
    }

    // MARK: 同一部剧只出一张卡（用户反馈：「严苛品质区」里「铁拳教育 · 第 1 季」出了两张一模一样的卡）

    /// 剧集的 TMDB 编号，和详情页季菜单（SeriesDetailView.seasons）同一个取法：剧集表里记了就用它，没记才看剧集资料的。
    /// 剧集表记的 0（还没认出来）不再拿资料的编号顶上：详情页认它是 0，主页要是把它并进别的季又留了它，
    /// 点进去季菜单里没有被并掉的那几季，那几季就哪儿都点不到了。0 也不算编号（不然没认出来的剧会全并成一部）
    nonisolated static func showID(_ s: Series, meta: Meta?) -> Int? {
        guard let id = s.tmdbId ?? meta?.id, id > 0 else { return nil }
        return id
    }

    /// 同一部剧的认法：同一个 TMDB 编号；没有编号的按剧名。
    /// 几季各一个目录、同一季有两份（/auto 里请求添加来的那份和整理进剧集目录的那份）都算同一部。
    /// 详情页的季菜单还是自己认（编号相同；记 0 的是所有记 0 的季；没编号的是同名的季），和这里不完全一样，
    /// 所以记 0 的和完全没编号的分开按剧名认：这里每一组都落在详情页的一组里，留下哪张卡，季菜单里都有被并掉的那几季。
    /// 这几个是纯函数（nonisolated）：详情页改成直接用 showKey 认最好（记 0 的季菜单就不会混进别的剧）
    nonisolated static func showKey(_ s: Series, meta: Meta?) -> String {
        if let id = Self.showID(s, meta: meta) { return "t\(id)" }
        return ((s.tmdbId ?? meta?.id) == nil ? "n" : "z") + s.name
    }

    func showKey(_ s: Series) -> String { Self.showKey(s, meta: seriesMetas[s.path]) }

    /// 这一季在 /auto 里（请求添加传进来、还没整理进剧集目录的那份）
    nonisolated static func inAutoFolder(_ s: Series) -> Bool { s.path.localizedCaseInsensitiveContains("/auto/") }

    /// 同一部剧几张卡留哪一张（用户要求）：季新的；同一季留 /auto 外面的、集数多的、最新入库的；
    /// 再都一样按路径（留哪张不随剧集表的先后变）
    nonisolated static func preferredSeason(_ a: Series, over b: Series) -> Bool {
        let sa = a.season ?? 0, sb = b.season ?? 0
        if sa != sb { return sa > sb }
        let aa = Self.inAutoFolder(a), ab = Self.inAutoFolder(b)
        if aa != ab { return ab }
        let ea = a.episodes ?? 0, eb = b.episodes ?? 0
        if ea != eb { return ea > eb }
        let da = a.added ?? "", db = b.added ?? ""
        if da != db { return da > db }
        return a.path < b.path
    }

    /// list 里同一部剧只留一项（showKey 认、preferredSeason 挑），留下的占这部剧第一次出现的位置，别的先后不动；
    /// 取不出剧集的（电影）原样留着。只过一遍字典：主页每次重画都跑也不费
    func dedupeShows<T>(_ list: [T], by seriesOf: (T) -> Series?) -> [T] {
        var slot: [String: Int] = [:]
        var out: [T] = []
        out.reserveCapacity(list.count)
        for x in list {
            guard let s = seriesOf(x) else { out.append(x); continue }
            let k = showKey(s)
            if let i = slot[k] {
                if let cur = seriesOf(out[i]), Self.preferredSeason(s, over: cur) { out[i] = x }
                continue
            }
            slot[k] = out.count
            out.append(x)
        }
        return out
    }

    func uniqueShows(_ list: [Series]) -> [Series] { dedupeShows(list) { $0 } }

    func uniqueShows(_ list: [HomeEntry]) -> [HomeEntry] {
        dedupeShows(list) { e in
            if case .series(let s) = e { return s }
            return nil
        }
    }

    /// 全部剧集，一部一张卡（剧集表的顺序：最新入库的在前）
    var uniqueSeries: [Series] { uniqueShows(series) }

    // MARK: 主页的分区：今年、去年的电影和剧集，然后四个大类

    /// 剧集能上主页的卡：TMDB 取到了（有海报或剧照）
    func seriesCardReady(_ s: Series) -> Bool {
        guard let m = seriesMetas[s.path] else { return false }
        return m.hasArt || !(m.backdrop ?? "").isEmpty
    }

    /// 某一年的电影和剧集，最新入库的在前（主页「2026」「2025」两排，年份页一样的顺序）。
    /// 剧集先挑能上卡的再去重：只有一份取到了 TMDB 的时候，这部剧不至于被另一份挤掉
    func homeYear(_ y: Int, limit: Int = .max) -> [HomeEntry] {
        var out: [(key: String, entry: HomeEntry)] = movies(inYear: y).map { ($0.addedKey, .movie($0)) }
        let shows = uniqueShows(series.filter { Int($0.year ?? "") == y && seriesCardReady($0) })
        for s in shows { out.append((s.added ?? "", .series(s))) }
        out.sort { $0.key > $1.key }
        return out.prefix(limit).map(\.entry)
    }

    /// 四个大类之一：电影和剧集都算。动画、动作、喜剧按类型认，新的年份在前、同一年按入库时间；严苛品质区见 premiumEntries
    func categoryEntries(_ c: HomeCategory, limit: Int = .max) -> [HomeEntry] {
        if c == .premium { return premiumEntries(limit: limit) }
        var out: [(year: Int, key: String, entry: HomeEntry)] = []
        for v in movies where c.matches(meta(v)?.genres) { out.append((year(v) ?? 0, v.addedKey, .movie(v))) }
        // 同一部剧只出一张卡（用户反馈重复影片）
        let shows = uniqueShows(series.filter { seriesCardReady($0) && c.matches(seriesMetas[$0.path]?.genres) })
        for s in shows { out.append((Int(s.year ?? "") ?? 0, s.added ?? "", .series(s))) }
        out.sort { $0.year != $1.year ? $0.year > $1.year : $0.key > $1.key }
        return out.prefix(limit).map(\.entry)
    }

    /// 「全部影片 › 可立即播放」的「电影 ›」「剧集 ›」那两页（FilmCategoryPage）：片库里的全部电影（movies 已经一部一张）/
    /// 全部剧集（一部剧一张卡：showKey / preferredSeason；没取到资料的也放，卡出现了再取，和全部影片一样全面放开），
    /// 新的年份在前、同一年最新入库的在前（和专区页同一个先后）。
    /// 几千部的片库每次重画都排一遍太费：电影按 dataVersion 缓存；剧集分两层缓存（见下）
    func playableEntries(series wantSeries: Bool) -> [HomeEntry] {
        if wantSeries {
            // 第一层：排序。refreshSeries 整个换掉剧集表、不动 dataVersion：认剧集表本身，不认部数和第一部
            // （中间换了一部、年份入库日期集数变了都认得出）。没变时两份共用一块存储，比一下是 O(1)；
            // 一样也换成新的这一份（刷新回来一模一样的另一块），往后再比还是 O(1)
            let list = series
            if list != playableSeriesSource {
                var keyed: [(year: Int, key: String, show: Series)] = []
                keyed.reserveCapacity(list.count)
                for s in list { keyed.append((Int(s.year ?? "") ?? 0, s.added ?? "", s)) }
                keyed.sort { $0.year != $1.year ? $0.year > $1.year : $0.key > $1.key }
                playableSeriesSorted = keyed.map(\.show)
                playableSeriesMetaCount = -1
            }
            playableSeriesSource = list
            // 第二层：一部剧一张卡。剧集资料是一张卡一张卡到的（卡出现了才取），到一份只重新去重一遍（过一遍字典），不重排。
            // 先排后去重：同一部剧占它排得最前那一季的位置、换成 preferredSeason 挑的那一季，还是新的年份在前
            let mc = seriesMetas.count
            if mc != playableSeriesMetaCount {
                playableSeriesCache = uniqueShows(playableSeriesSorted).map { HomeEntry.series($0) }
                playableSeriesMetaCount = mc
            }
            return playableSeriesCache
        }
        // 先读 movies：调用它的视图跟着片库、元数据刷新（derive 也在这里跑完，dataVersion 是新的）
        let list = movies
        if playableMoviesVersion == dataVersion { return playableMoviesCache }
        var out: [(year: Int, key: String, entry: HomeEntry)] = list.map { (year($0) ?? 0, $0.addedKey, .movie($0)) }
        out.sort { $0.year != $1.year ? $0.year > $1.year : $0.key > $1.key }
        playableMoviesCache = out.map(\.entry)
        playableMoviesVersion = dataVersion
        return playableMoviesCache
    }

    @ObservationIgnored private var playableMoviesCache: [HomeEntry] = []
    @ObservationIgnored private var playableMoviesVersion = -1
    @ObservationIgnored private var playableSeriesSource: [Series] = []
    @ObservationIgnored private var playableSeriesSorted: [Series] = []
    @ObservationIgnored private var playableSeriesMetaCount = -1
    @ObservationIgnored private var playableSeriesCache: [HomeEntry] = []

    /// 严苛品质区（用户要求「规格高评价好」）：片源规格够格（PremiumBar：4K 以上，再有杜比视界 / HDR、全景声 / 无损音轨或 REMUX）、
    /// TMDB 评分 7.5 以上的电影和剧集。评分高的在前，同分规格高的在前，再按年份新的在前。
    /// 电影看这部片的所有文件（同一个 TMDB 编号的各个版本），有一个版本够格就算；卡还是平常那张（规格最高的那个版本）
    func premiumEntries(limit: Int = .max) -> [HomeEntry] {
        var best: [Int: Int] = [:]
        for v in videos {
            guard let id = metas[v.name]?.id else { continue }
            let sc = specScore(file: v.name)
            if sc > best[id, default: 0] { best[id] = sc }
        }
        var out: [(rating: Double, score: Int, year: Int, entry: HomeEntry)] = []
        for v in movies {
            guard let m = meta(v), let r = m.rating, r >= PremiumBar.minRating else { continue }
            let sc = m.id.flatMap { best[$0] } ?? specScore(file: v.name)
            guard sc > 0 else { continue }
            out.append((r, sc, year(v) ?? 0, .movie(v)))
        }
        // 剧集：先挑出够格的季，再一部只留一张卡（用户反馈：同一季在 /auto 和剧集目录里各一份，出了两张一样的卡）
        var shows: [(series: Series, rating: Double, score: Int)] = []
        for s in series where seriesCardReady(s) {
            guard let r = seriesMetas[s.path]?.rating, r >= PremiumBar.minRating else { continue }
            let remux = ([s.path] + (s.tags ?? [])).contains { $0.localizedCaseInsensitiveContains("remux") }
            let sc = PremiumBar.score(MediaSpec.series(s, firstFile: nil), remux: remux)
            guard sc > 0 else { continue }
            shows.append((s, r, sc))
        }
        for x in dedupeShows(shows, by: { $0.series }) {
            out.append((x.rating, x.score, Int(x.series.year ?? "") ?? 0, .series(x.series)))
        }
        out.sort { a, b in
            if a.rating != b.rating { return a.rating > b.rating }
            if a.score != b.score { return a.score > b.score }
            return a.year > b.year
        }
        return out.prefix(limit).map(\.entry)
    }

    /// 文件名 → 规格分（PremiumBar）。文件名不会变，读一次记下来（要跑十几个正则，主页每次重画都算一遍太费）
    @ObservationIgnored private var specScores: [String: Int] = [:]

    private func specScore(file name: String) -> Int {
        if let sc = specScores[name] { return sc }
        let sc = PremiumBar.score(MediaSpec(name: name), remux: name.localizedCaseInsensitiveContains("remux"))
        specScores[name] = sc
        return sc
    }

    func movies(inGenre g: String) -> [Video] { movies.filter { meta($0)?.genres?.contains(g) == true } }
    /// 同一部剧的几季 / 两份只出一张卡（用户反馈重复影片）
    func series(inGenre g: String) -> [Series] { uniqueShows(series.filter { seriesMetas[$0.path]?.genres?.contains(g) == true }) }

    /// 详情页「你可能还喜欢」：和这部片同类型的几部，同的类型越多越靠前，再按评分；不含它自己（同一个 TMDB 编号的别的版本也不算）
    func related(to video: Video, limit: Int = 12) -> [Video] {
        guard let mine = meta(video), let g = mine.genres, !g.isEmpty else { return [] }
        let wanted = Set(g)
        var scored: [(video: Video, shared: Int, rating: Double)] = []
        for v in movies where v.path != video.path {
            guard let m = meta(v), let gs = m.genres else { continue }
            if let id = mine.id, m.id == id { continue }
            let shared = gs.reduce(0) { $0 + (wanted.contains($1) ? 1 : 0) }
            if shared > 0 { scored.append((v, shared, m.rating ?? 0)) }
        }
        scored.sort { $0.shared != $1.shared ? $0.shared > $1.shared : $0.rating > $1.rating }
        return scored.prefix(limit).map(\.video)
    }

    var yearGroups: [(year: Int, videos: [Video])] {
        derive()
        return cachedYearGroups
    }

    func movies(inYear y: Int) -> [Video] { yearGroups.first { $0.year == y }?.videos ?? [] }

    /// 这一年的剧集（全部影片、年份页）：同一部剧一张卡（用户反馈重复影片）
    func seriesInYear(_ y: Int) -> [Series] { uniqueShows(series.filter { Int($0.year ?? "") == y }) }

    /// 首页只出有字标的剧集（与网页版同一条规矩）；先挑有字标的再去重，同一部剧一张卡
    var homeSeries: [Series] {
        uniqueShows(series.filter { s in
            guard let m = seriesMetas[s.path], let logo = m.logo, !logo.isEmpty else { return false }
            return m.hasArt || !(m.backdrop ?? "").isEmpty
        })
    }

    /// 今日推荐：上午 / 下午 / 晚上 每日三换；同一个种子打乱（与网页版同一个算法），取 15 部按评分排
    var todayPicks: [Video] {
        let now = Date()
        let cal = Calendar.current
        let h = cal.component(.hour, from: now)
        var ref = now
        let period: Int
        if h >= 5 && h < 12 { period = 0 } else if h >= 12 && h < 18 { period = 1 } else {
            period = 2
            if h < 5 { ref = cal.date(byAdding: .day, value: -1, to: now) ?? now }
        }
        let c = cal.dateComponents([.year, .month, .day], from: ref)
        let dayKey = (c.year ?? 2026) * 10000 + (c.month ?? 1) * 100 + (c.day ?? 1)
        let seed = UInt32(truncatingIfNeeded: dayKey * 3 + period)
        let pool0 = movies
        if let c = cachedPicks, c.version == derivedVersion, c.seed == seed { return c.list }
        var seen = Set<String>()
        let pool = pool0.filter { seen.insert(title($0).lowercased()).inserted }
        let picks = Array(Self.shuffle(pool, seed: seed).prefix(15))
        let list = picks.sorted { a, b in
            let ra = metas[a.name]?.rating ?? 0, rb = metas[b.name]?.rating ?? 0
            if ra != rb { return ra > rb }
            let ya = year(a) ?? 0, yb = year(b) ?? 0
            if ya != yb { return ya > yb }
            return a.name < b.name
        }
        cachedPicks = (derivedVersion, seed, list)
        return list
    }

    static func shuffle<T>(_ arr: [T], seed: UInt32) -> [T] {
        var t: UInt32 = seed == 0 ? 1 : seed
        func rnd() -> Double {
            t = t &+ 0x6D2B79F5
            var r = (t ^ (t >> 15)) &* (1 | t)
            r ^= r &+ ((r ^ (r >> 7)) &* (61 | r))
            return Double(r ^ (r >> 14)) / 4294967296.0
        }
        var a = arr
        var i = a.count - 1
        while i > 0 {
            let j = min(i, Int(rnd() * Double(i + 1)))
            a.swapAt(i, j)
            i -= 1
        }
        return a
    }

    // MARK: 搜索

    struct SearchHit: Identifiable, Hashable {
        enum Kind: Hashable { case movie(Video), series(Series) }
        var kind: Kind
        var title: String
        var subtitle: String
        var image: URL?
        var score: Int
        var id: String {
            switch kind { case .movie(let v): return "m:" + v.path; case .series(let s): return "s:" + s.path }
        }
    }

    func search(_ raw: String) -> [SearchHit] {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        func score(_ keys: [String?]) -> Int {
            var best = 0
            for k in keys.compactMap({ $0?.lowercased() }) where !k.isEmpty {
                if k == q { best = max(best, 100) }
                else if k.hasPrefix(q) { best = max(best, 80) }
                else if k.contains(q) { best = max(best, 60) }
            }
            return best
        }
        var hits: [SearchHit] = []
        for v in movies {
            let m = metas[v.name]
            var s = score([m?.title, m?.en, m?.originalTitle, FileName.title(v.name)])
            if s == 0, let y = year(v), String(y) == q { s = 40 }
            guard s > 0 else { continue }
            let sub = [year(v).map { String($0) }, m?.genres?.prefix(2).joined(separator: " · ")].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            hits.append(SearchHit(kind: .movie(v), title: title(v), subtitle: sub.isEmpty ? "电影" : sub,
                                  image: thumbArt(v), score: s))
        }
        var showHits: [SearchHit] = []
        for se in series {
            let m = seriesMetas[se.path]
            var s = score([se.title, se.zh, se.en, m?.title, m?.en, se.folder])
            if s == 0, se.year == q { s = 40 }
            guard s > 0 else { continue }
            // 不写集数（用户要求全局去掉计数）
            let sub = [se.year, se.seasonLabel].compactMap { $0 }.joined(separator: " · ")
            showHits.append(SearchHit(kind: .series(se), title: se.name, subtitle: sub,
                                      image: TMDBImage.url(m?.poster ?? m?.posterClean, "w185"), score: s + 1))
        }
        // 同一部剧只出一行（用户反馈重复影片）：别的季在详情页的季菜单里切
        hits += dedupeShows(showHits) { h in
            if case .series(let s) = h.kind { return s }
            return nil
        }
        return hits.sorted { $0.score != $1.score ? $0.score > $1.score : $0.title < $1.title }.prefix(80).map { $0 }
    }

    /// 清除缓存：片库清单与影片信息（Caches/cuven）、接口回包（URLCache.shared）、海报和剧照（图片管线的磁盘缓存，以前漏了）
    func clearCaches() {
        DiskCache.clear()
        URLCache.shared.removeAllCachedResponses()
        ImagePipeline.shared.clearDisk()
    }

    /// 缓存一共占了多少：和 clearCaches 清的是同三样
    static var cacheUsage: Int64 {
        DiskCache.size() + Int64(URLCache.shared.currentDiskUsage) + ImagePipeline.shared.diskUsage
    }
}

/// 探索的排法（用户要求「随机排序，高分和值得一看的影片优先，允许不同年份，每次打开都不一样」）：
/// · 加权随机（Efraimidis–Spirakis）：每部一个 ln(u) / w，从大到小排；w = e^((分 − 7) / 0.9)：
///   8.5 分的大约是 6.5 分的 9 倍机会排在它前面，但不是每次都在最前。u 由种子和这一部的路径算出来：
///   同一轮里稳定，后台再查到的新片按同一个规矩插进来，不会把已经排好的打乱
/// · 打散：同一类型（第一个类型）、同一年不挨着；往后 6 部里找一部不撞的换上来，找不到就照原样
enum ExploreOrder {
    static func order(_ list: [Video], seed: UInt64, score: (Video) -> Double,
                      genre: (Video) -> String?, year: (Video) -> Int?) -> [Video] {
        var keyed: [(key: Double, video: Video)] = []
        keyed.reserveCapacity(list.count)
        for v in list {
            let w = exp((score(v) - 7) / 0.9)
            let u = max(1e-12, unit(seed, v.path))
            keyed.append((log(u) / w, v))
        }
        keyed.sort { $0.key > $1.key }
        var pool = keyed.map(\.video)
        var out: [Video] = []
        out.reserveCapacity(pool.count)
        while !pool.isEmpty {
            var pick = 0
            if let last = out.last {
                let lg = genre(last), ly = year(last)
                let pg = out.count >= 2 ? genre(out[out.count - 2]) : nil
                for j in 0..<min(6, pool.count) {
                    let g = genre(pool[j]), y = year(pool[j])
                    let clash = (g != nil && (g == lg || g == pg)) || (y != nil && y == ly)
                    if !clash { pick = j; break }
                }
            }
            out.append(pool.remove(at: pick))
        }
        return out
    }

    /// 种子 + 路径 → [0, 1)：FNV-1a 64 再过一遍 SplitMix64 的收尾
    private static func unit(_ seed: UInt64, _ path: String) -> Double {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325 ^ seed
        for b in path.utf8 {
            h ^= UInt64(b)
            h = h &* 0x0000_0100_0000_01b3
        }
        h = (h ^ (h >> 30)) &* 0xbf58_476d_1ce4_e5b9
        h = (h ^ (h >> 27)) &* 0x94d0_49bb_1331_11eb
        h ^= h >> 31
        return Double(h >> 11) / Double(1 << 53)
    }
}
