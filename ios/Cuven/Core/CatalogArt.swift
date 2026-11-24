import Foundation

// MARK: - 可申请的片：剧照、字标、类型（「全部影片 › 可申请」的横卡用）
//
// 影片库索引只给片名、年份、竖版海报；横卡上面那张剧照、下面那枚字标要问片库的 TMDB 代理。
// · 一排里看得到的几张一起问：卡出现时排进队，60 毫秒内排进来的合成一次 /api/tmdb-batch（按 TMDB 编号，v25.6）
// · 片库还是老版本、不认按编号问：退回一张一张问 /api/tmdb?id=（同时最多 4 个，只问看得到的那几张）；10 分钟后再试一次批量
// · 问到的记在本机（Caches，30 天，最多 3000 部）：第二次打开「全部影片」卡片直接是全的
// · TMDB 说没有这部的也记下（空的一条），不反复问；这次没问成的 1 分钟内不再问

@MainActor
@Observable
final class CatalogArt {
    static let shared = CatalogArt()

    struct Art: Codable, Equatable, Sendable {
        /// 剧照（没字的那张优先）
        var backdrop: String?
        var logo: String?
        var genre: String?
        /// 记下的时间（秒）
        var at: Double
    }

    private(set) var arts: [String: Art] = [:]

    @ObservationIgnored private var pending: [String: CatalogItem] = [:]
    @ObservationIgnored private var inflight: Set<String> = []
    @ObservationIgnored private var failedAt: [String: Date] = [:]
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var batchOffUntil: Date?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var loaded = false

    private static let ttl: Double = 30 * 86_400
    private static let cap = 3000
    private static var file: URL {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("cuven", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("catalog-art.v1.json")
    }

    /// 第一次用到时（「全部影片」打开）把本机存的读进来：不在画卡的时候改状态
    private init() { loadIfNeeded() }

    static func key(_ item: CatalogItem) -> String { (item.src == "tv" ? "tv" : "movie") + ":" + String(item.id) }

    func art(_ item: CatalogItem) -> Art? {
        // 演示数据（截图用）：本地画的剧照
        if DemoData.enabled { return Art(backdrop: "demo://backdrop/\(item.id % 97)", logo: nil, genre: item.src == "tv" ? "剧情" : "悬疑", at: 0) }
        return arts[Self.key(item)]
    }

    /// 这张卡出现了：还没有资料就排进队（60 毫秒内排进来的一起问）
    func want(_ item: CatalogItem) {
        guard !DemoData.enabled, item.id > 0 else { return }
        let k = Self.key(item)
        guard arts[k] == nil, !inflight.contains(k), pending[k] == nil else { return }
        if let t = failedAt[k], Date().timeIntervalSince(t) < 60 { return }
        pending[k] = item
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            await self?.flush()
        }
    }

    private func flush() async {
        flushTask = nil
        let batch = pending
        pending = [:]
        guard !batch.isEmpty else { return }
        inflight.formUnion(batch.keys)
        defer { inflight.subtract(batch.keys) }
        var left = batch
        if batchOffUntil.map({ Date() >= $0 }) ?? true {
            let keys = Array(batch.keys)
            for start in stride(from: 0, to: keys.count, by: 40) {
                let chunk = Array(keys[start..<min(start + 40, keys.count)])
                let ask = chunk.compactMap { k -> (type: String, id: Int)? in
                    guard let it = batch[k] else { return nil }
                    return (it.src == "tv" ? "tv" : "movie", it.id)
                }
                guard let r = try? await APIClient.shared.metaByID(ask, logo: true) else {
                    for k in chunk { failedAt[k] = Date() }
                    for k in chunk { left.removeValue(forKey: k) }
                    continue
                }
                let answered = chunk.filter { r[$0] != nil }
                if answered.isEmpty {
                    // 老版本的片库不认按编号问（一个这样的键都不回）：这一批改成一张一张问，10 分钟后再试批量
                    batchOffUntil = Date().addingTimeInterval(600)
                    break
                }
                for k in chunk {
                    left.removeValue(forKey: k)
                    if let hit = r[k] { store(k, hit) } else { failedAt[k] = Date() }
                }
            }
        }
        guard !left.isEmpty else { scheduleSave(); return }
        // 一张一张问（同时最多 4 个）
        let items = Array(left)
        await withTaskGroup(of: (String, Meta??).self) { g in
            var i = 0
            func add() {
                guard i < items.count else { return }
                let (k, it) = items[i]
                i += 1
                g.addTask {
                    do {
                        let m = try await APIClient.shared.tmdb(query: it.title, year: it.year.isEmpty ? nil : String(it.year.prefix(4)),
                                                                type: it.src == "tv" ? "tv" : "movie", id: it.id, full: true)
                        return (k, .some(m))
                    } catch {
                        return (k, nil)
                    }
                }
            }
            for _ in 0..<4 { add() }
            while let r = await g.next() {
                // 问成了（TMDB 说没有也算问成了，记一条空的）；出错的 1 分钟内不再问
                if let m = r.1 { store(r.0, m) } else { failedAt[r.0] = Date() }
                add()
            }
        }
        scheduleSave()
    }

    private func store(_ k: String, _ m: Meta?) {
        arts[k] = Art(backdrop: m?.backdropClean ?? m?.backdrop, logo: m?.logo, genre: m?.genres?.first,
                      at: Date().timeIntervalSince1970)
    }

    // MARK: 本机缓存

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard !DemoData.enabled, let data = try? Data(contentsOf: Self.file),
              let all = try? JSONDecoder().decode([String: Art].self, from: data) else { return }
        let now = Date().timeIntervalSince1970
        arts = all.filter { now - $0.value.at < Self.ttl }
    }

    private func scheduleSave() {
        guard !DemoData.enabled else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            var all = self.arts
            if all.count > Self.cap {
                for k in all.sorted(by: { $0.value.at < $1.value.at }).prefix(all.count - Self.cap).map(\.key) { all.removeValue(forKey: k) }
            }
            let url = Self.file
            Task.detached(priority: .utility) {
                if let data = try? JSONEncoder().encode(all) { try? data.write(to: url, options: .atomic) }
            }
        }
    }
}
