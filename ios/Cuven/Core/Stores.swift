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
        Perf.log("restore: \(videos.count) videos, \(metas.count) metas")
    }

    func refreshLibrary() async {
        do {
            let t0 = Date()
            let lib = try await APIClient.shared.library()
            let vids = lib.videos.filter { FileName.isVideo($0.name) }.sorted { $0.addedKey > $1.addedKey }
            videos = vids
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
            if videos.isEmpty { phase = .failed(error.localizedDescription) }
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

    /// 挑头图：候选是 Apple TV 头图池（/api/atv/hero）的顺序，再是最新加入的；每一部都要有
    /// 无字的横图（Apple TV 无字背景 → TMDB 没有字的剧照）和字标（Apple → TMDB），两样缺一就不上；按候选顺序取前 5 部。
    /// 片名要先认出来（Apple TV 按英文名查），所以元数据到了以后才挑
    func resolveHeroes() async {
        guard metaReady, !heroResolving else { return }
        heroResolving = true
        defer { heroResolving = false }
        var seen = Set<String>()
        var cands: [(video: Video, hero: Hero?)] = []
        for h in heroes { if let v = video(path: h.path), seen.insert(v.path).inserted { cands.append((v, h)) } }
        for v in newest where seen.insert(v.path).inserted { cands.append((v, nil)) }
        cands = Array(cands.prefix(12))
        if DemoData.enabled {
            // 演示数据：合成的头图本来就是无字背景 + 字标
            heroPicks = Array(cands.compactMap { c -> HeroPick? in
                guard let h = c.hero, let w = h.background, let l = h.logo else { return nil }
                return HeroPick(video: c.video, hero: h, wide: w, tall: h.poster, logo: l)
            }.prefix(5))
            heroResolved = true
            return
        }
        let picked = await withTaskGroup(of: (Int, HeroPick?).self) { g in
            for (i, c) in cands.enumerated() {
                g.addTask { (i, await self.heroPick(c.video, hero: c.hero)) }
            }
            var out = [HeroPick?](repeating: nil, count: cands.count)
            for await (i, p) in g { out[i] = p }
            return out
        }
        let picks = Array(picked.compactMap { $0 }.prefix(5))
        if picks != heroPicks { heroPicks = picks }
        heroResolved = true
        Perf.log("hero: \(picks.count) of \(cands.count) candidates have a clean background and a logo")
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

    /// 派生清单按 dataVersion 缓存。先读一下 videos / metas：调用它的视图照样会跟着这两样刷新
    private func derive() {
        _ = videos.count
        _ = metas.count
        guard derivedVersion != dataVersion else { return }
        derivedVersion = dataVersion
        let t0 = Date()
        // 能显示的电影：有 TMDB、有海报；同一部片（同一个 TMDB 编号）只留最新入库的那个文件
        var seen = Set<Int>()
        var out: [Video] = []
        for v in videos {
            guard let m = metas[v.name], m.hasArt, m.type != "tv" else { continue }
            if let id = m.id {
                if seen.contains(id) { continue }
                seen.insert(id)
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

    /// 这个评分在片库里高过百分之几的电影（剧集就和剧集比）；有评分的不到 20 部就不算（数太少，说了也没意义）
    func ratingPercentile(_ r: Double, series: Bool) -> Int? {
        let all: [Double] = series
            ? self.series.compactMap { seriesMetas[$0.path]?.rating }.filter { $0 > 0 }
            : movies.compactMap { meta($0)?.rating }.filter { $0 > 0 }
        guard all.count >= 20 else { return nil }
        let below = all.reduce(0) { $0 + ($1 < r ? 1 : 0) }
        return Int((Double(below) / Double(all.count) * 100).rounded(.down))
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

    /// 主页「精选剧集」：评分 6 分以上、有海报也有剧照的剧，评分高的在前（同分的新的在前）；同一部剧的几季只出一次
    func featuredSeries(limit: Int = .max) -> [Series] {
        var seen = Set<String>()
        var list: [(series: Series, rating: Double, year: String)] = []
        for s in series {
            let m = seriesMetas[s.path]
            guard let r = m?.rating, r >= 6,
                  Self.nonEmpty(m?.poster) != nil || Self.nonEmpty(m?.posterClean) != nil,
                  Self.nonEmpty(m?.backdrop) != nil else { continue }
            let key = (s.tmdbId ?? m?.id).map { "t\($0)" } ?? "n" + s.name
            guard seen.insert(key).inserted else { continue }
            list.append((s, r, s.year ?? m?.year ?? ""))
        }
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

    /// 列表行里的小图（行里已经写着片名，不压字标）：Apple 海报 → Apple 竖版主视觉 → TMDB 海报
    func thumbArt(_ v: Video) -> URL? {
        if let a = appleArt(v), let s = Self.nonEmpty(a.poster) ?? Self.nonEmpty(a.tall) {
            return URL(string: AppleImage.sized(s, width: 200) ?? s)
        }
        let m = meta(v)
        return TMDBImage.url(m?.poster ?? m?.posterClean, "w185")
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

    // MARK: 主页的分区：今年、去年的电影和剧集，然后五个大类

    /// 剧集能上主页的卡：TMDB 取到了（有海报或剧照）
    func seriesCardReady(_ s: Series) -> Bool {
        guard let m = seriesMetas[s.path] else { return false }
        return m.hasArt || !(m.backdrop ?? "").isEmpty
    }

    /// 某一年的电影和剧集，最新入库的在前（主页「2026」「2025」两排，年份页一样的顺序）
    func homeYear(_ y: Int, limit: Int = .max) -> [HomeEntry] {
        var out: [(key: String, entry: HomeEntry)] = movies(inYear: y).map { ($0.addedKey, .movie($0)) }
        for s in seriesInYear(y) where seriesCardReady(s) { out.append((s.added ?? "", .series(s))) }
        out.sort { $0.key > $1.key }
        return out.prefix(limit).map(\.entry)
    }

    /// 五个大类之一：电影和剧集都算，新的年份在前、同一年按入库时间
    func categoryEntries(_ c: HomeCategory, limit: Int = .max) -> [HomeEntry] {
        var out: [(year: Int, key: String, entry: HomeEntry)] = []
        for v in movies where c.matches(meta(v)?.genres) { out.append((year(v) ?? 0, v.addedKey, .movie(v))) }
        for s in series where seriesCardReady(s) && c.matches(seriesMetas[s.path]?.genres) {
            out.append((Int(s.year ?? "") ?? 0, s.added ?? "", .series(s)))
        }
        out.sort { $0.year != $1.year ? $0.year > $1.year : $0.key > $1.key }
        return out.prefix(limit).map(\.entry)
    }

    func movies(inGenre g: String) -> [Video] { movies.filter { meta($0)?.genres?.contains(g) == true } }
    func series(inGenre g: String) -> [Series] { series.filter { seriesMetas[$0.path]?.genres?.contains(g) == true } }

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

    func seriesInYear(_ y: Int) -> [Series] { series.filter { Int($0.year ?? "") == y } }

    /// 首页只出有字标的剧集（与网页版同一条规矩）
    var homeSeries: [Series] {
        series.filter { s in
            guard let m = seriesMetas[s.path], let logo = m.logo, !logo.isEmpty else { return false }
            return m.hasArt || !(m.backdrop ?? "").isEmpty
        }
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
        for se in series {
            let m = seriesMetas[se.path]
            var s = score([se.title, se.zh, se.en, m?.title, m?.en, se.folder])
            if s == 0, se.year == q { s = 40 }
            guard s > 0 else { continue }
            let sub = [se.year, se.seasonLabel, se.countLabel].compactMap { $0 }.joined(separator: " · ")
            hits.append(SearchHit(kind: .series(se), title: se.name, subtitle: sub,
                                  image: TMDBImage.url(m?.poster ?? m?.posterClean, "w185"), score: s + 1))
        }
        return hits.sorted { $0.score != $1.score ? $0.score > $1.score : $0.title < $1.title }.prefix(80).map { $0 }
    }

    func clearCaches() {
        DiskCache.clear()
        URLCache.shared.removeAllCachedResponses()
    }
}
