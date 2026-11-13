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
    @ObservationIgnored private var trailerCache: [String: [Trailer]] = [:]
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
            return
        }
        restore()
        phase = videos.isEmpty ? .loading : .ready
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
        if let m = try? await APIClient.shared.metaBatch([v.name], full: true), let hit = m[v.name], let meta = hit {
            return meta
        }
        return metas[v.name]
    }

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

    /// 详情页「预告片」：拿英文名去 Apple TV 找，年份差一年以内才算同一部（免得是同名的别的片）。
    /// 只留公开的预告（订阅才看得了的花絮不要）；结果记在内存里，一部片只问一次
    func trailers(for v: Video) async -> [Trailer] {
        if DemoData.enabled { return [] }
        if let hit = trailerCache[v.path] { return hit }
        let m = meta(v)
        let latin = [m?.en, m?.originalTitle].compactMap { $0 }
            .first { !$0.isEmpty && $0.range(of: "\\p{Han}", options: .regularExpression) == nil }
        guard let name = latin, let r = try? await APIClient.shared.atvLookup(title: name) else { return [] }
        var list = (r.trailers ?? []).filter { !$0.hls.isEmpty && !$0.hls.contains("/subscription/") }
        if let y = year(v), let ry = r.year, abs(y - ry) > 1 { list = [] }
        trailerCache[v.path] = list
        Perf.log("trailers: \(list.count) (of \(r.trailers?.count ?? 0))")
        return list
    }

    /// 片库里的类型（电影 + 剧集都算），片子多的在前：搜索页「浏览」的格子
    var genres: [(name: String, count: Int)] {
        var n: [String: Int] = [:]
        for v in movies { for g in meta(v)?.genres ?? [] { n[g, default: 0] += 1 } }
        for s in series { for g in seriesMetas[s.path]?.genres ?? [] { n[g, default: 0] += 1 } }
        return n.map { (name: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
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
                                  image: TMDBImage.url(m?.poster, "w185"), score: s))
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
