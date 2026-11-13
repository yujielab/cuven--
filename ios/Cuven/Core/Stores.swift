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

// MARK: - 片库

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

    let playback = PlaybackStore()

    @ObservationIgnored private var started = false
    @ObservationIgnored private var seriesInflight: Set<String> = []
    @ObservationIgnored private var metaRound = 0

    // MARK: 启动 / 刷新

    func start() {
        guard !started else { return }
        started = true
        restore()
        phase = videos.isEmpty ? .loading : .ready
        Task { await refreshLibrary() }
        Task { await refreshSeries() }
        Task { await refreshHeroes() }
    }

    func refreshAll() async {
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
        metaReady = !metas.isEmpty
    }

    func refreshLibrary() async {
        do {
            let lib = try await APIClient.shared.library()
            let vids = lib.videos.filter { FileName.isVideo($0.name) }.sorted { $0.addedKey > $1.addedKey }
            videos = vids
            phase = .ready
            DiskCache.save(vids, "library.json")
            metaRound = 0
            await loadMetas()
        } catch {
            if videos.isEmpty { phase = .failed(error.localizedDescription) }
        }
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
            let results = await withTaskGroup(of: [String: Meta?].self, returning: [[String: Meta?]].self) { g in
                for c in group { g.addTask { (try? await APIClient.shared.metaBatch(c)) ?? [:] } }
                var out: [[String: Meta?]] = []
                for await r in g { out.append(r) }
                return out
            }
            for r in results { apply(r) }
            metaReady = true
        }
        DiskCache.save(metas, "metas.json")
        DiskCache.save(Array(hidden), "hidden.json")
        let left = videos.contains { metas[$0.name] == nil && !hidden.contains($0.name) }
        if left && metaRound < 3 {
            metaRound += 1
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            await loadMetas()
        }
    }

    private func apply(_ r: [String: Meta?]) {
        for (name, value) in r {
            if let m = value, m.hasArt {
                metas[name] = m
                hidden.remove(name)
            } else {
                hidden.insert(name)       // 后端确定认不出，或认出来了却没有海报
            }
        }
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

    /// 电影详情：全量结果（字标、演员、纯净海报）
    func fullMeta(for v: Video) async -> Meta? {
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

    /// 能显示的电影：有 TMDB、有海报；同一部片（同一个 TMDB 编号）只留最新入库的那个文件
    var movies: [Video] {
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
        return out
    }

    /// 同一部片的所有文件（4K / 1080p 等不同版本）
    func versions(of v: Video) -> [Video] {
        guard let id = metas[v.name]?.id else { return [v] }
        let all = videos.filter { metas[$0.name]?.id == id }
        return all.isEmpty ? [v] : all
    }

    var newest: [Video] { Array(movies.prefix(15)) }

    var yearGroups: [(year: Int, videos: [Video])] {
        var by: [Int: [Video]] = [:]
        for v in movies { if let y = year(v) { by[y, default: []].append(v) } }
        return by.keys.sorted(by: >).map { ($0, by[$0]!) }
    }

    func movies(inYear y: Int) -> [Video] { movies.filter { year($0) == y } }

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
        var seen = Set<String>()
        let pool = movies.filter { seen.insert(title($0).lowercased()).inserted }
        let picks = Array(Self.shuffle(pool, seed: seed).prefix(15))
        return picks.sorted { a, b in
            let ra = metas[a.name]?.rating ?? 0, rb = metas[b.name]?.rating ?? 0
            if ra != rb { return ra > rb }
            let ya = year(a) ?? 0, yb = year(b) ?? 0
            if ya != yb { return ya > yb }
            return a.name < b.name
        }
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
