import Foundation

// MARK: - 可申请的片：剧照、字标、类型（「全部影片 › 可申请」的横卡用）
//
// 影片库索引只给片名、年份、竖版海报；横卡上面那张剧照、下面那枚字标要问片库的 TMDB 代理。
// · 一排里看得到的几张一起问：卡出现时排进队，60 毫秒内排进来的合成一次 /api/tmdb-batch（按 TMDB 编号，v25.6）
// · 片库还是老版本、不认按编号问（回包没有 __byId、问的键一个都不回）：退回一张一张问 /api/tmdb?id=（同时最多 4 个，只问看得到的那几张）；
//   10 分钟后再试一次批量。有 __byId 却没回的键、整批 503，都只是这次没问成：1 分钟后再问，批量不关
// · 问到的记在本机（Caches，30 天，最多 3000 部）：第二次打开「全部影片」卡片直接是全的
// · TMDB 说没有这部的也记下（空的一条），不反复问；这次没问成的 1 分钟内不再问
// · 字标那一问没问成的半份（logoChecked: false）不算答案：剧照先在内存里画着，不存本机，10 分钟后再问

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
        /// 字标那一问有答案（TMDB 说没有这部也算）。false = 半份：只在内存里、不存本机，10 分钟后再问。
        /// nil = 老版本存的（没有这个记号，照样解得出来；读进来时按有没有字标分，见 loadIfNeeded）
        var checked: Bool? = nil
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
    /// 半份过多久再问（TMDB 那一下抖动一般早过去了；不必每次卡片出现都问）
    private static let halfRetry: Double = 600
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
        // 有了的不再问；半份（字标没问成）先拿剧照画着，隔 10 分钟再问一次（再问没问成也隔 10 分钟：剧照已经有了，不急）
        var wait: Double = 60
        if let a = arts[k] {
            guard a.checked == false, Date().timeIntervalSince1970 - a.at >= Self.halfRetry else { return }
            wait = Self.halfRetry
        }
        guard !inflight.contains(k), pending[k] == nil else { return }
        if let t = failedAt[k], Date().timeIntervalSince(t) < wait { return }
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
                // 没问成（网络错、回包解不出、非 2xx —— v25.6 全批编号都没答出来回 503）：这几部过会儿再问（1 分钟，已有半份的 10 分钟），批量不关
                guard let r = try? await APIClient.shared.metaByID(ask, logo: true) else {
                    for k in chunk { failedAt[k] = Date() }
                    for k in chunk { left.removeValue(forKey: k) }
                    continue
                }
                // 老版本的片库不认按编号问：没有 __byId 记号、问的键一个都不回 → 这一批改成一张一张问，10 分钟后再试批量。
                // 有记号就是认得：没回的键是这次没问成（TMDB 出错、超预算、只有半份），只按下面记 failedAt，不关批量
                if !r.byId, !chunk.contains(where: { r.items[$0] != nil }) {
                    batchOffUntil = Date().addingTimeInterval(600)
                    break
                }
                for k in chunk {
                    left.removeValue(forKey: k)
                    if let hit = r.items[k] { store(k, hit) } else { failedAt[k] = Date() }
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
                // 问成了（TMDB 说没有也算问成了，记一条空的；半份见 store）；出错的 1 分钟内不再问
                if let m = r.1 { store(r.0, m) } else { failedAt[r.0] = Date() }
                add()
            }
        }
        scheduleSave()
    }

    /// 半份（logoChecked: false，后端那一下 TMDB images 没问成，字标、无字剧照都是空的）：剧照照样先画，
    /// 但不当答案 —— checked = false，不存本机，want() 10 分钟后再问；不然一个月都是没字标、带字的那张剧照
    private func store(_ k: String, _ m: Meta?) {
        arts[k] = Art(backdrop: m?.backdropClean ?? m?.backdrop, logo: m?.logo, genre: m?.genres?.first,
                      at: Date().timeIntervalSince1970, checked: m?.logoChecked != false)
    }

    // MARK: 本机缓存

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard !DemoData.enabled, let data = try? Data(contentsOf: Self.file),
              let all = try? JSONDecoder().decode([String: Art].self, from: data) else { return }
        let now = Date().timeIntervalSince1970
        // 半份不该在文件里；老版本存的没有 checked：有字标的一定问全了，留着，没字标的分不清是「TMDB 上没有」还是半份，丢掉再问一次
        arts = all.filter { now - $0.value.at < Self.ttl && ($0.value.checked == true || ($0.value.checked == nil && $0.value.logo != nil)) }
    }

    private func scheduleSave() {
        guard !DemoData.enabled else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            // 半份只在内存里（不存本机：下次打开再问）
            var all = self.arts.filter { $0.value.checked != false }
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
