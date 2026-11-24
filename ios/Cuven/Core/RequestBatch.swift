import Foundation
import SwiftUI

// MARK: - 批量请求：请求篮 + 传输流（tj 2.6）
//
// 用户要求的流程：按「请求添加」→ 放进请求中心（最多 50 部电影或剧集的一季）→ 按「确认」→ 服务器让每一部走完 PikPak 云下载和清洗
// （电影留在 /auto，剧集放进 /auto/ram2）→ 等至少 16 部清洗完 → 16 路并行传输、16 路并发核对一起传 → 请求中心最上面那张卡的动画和进度条。
// 请求篮只存在这台设备上（按账户分开存），按「确认」才发给服务器。

/// /app/flow 的回包：凑批的进度、正在跑的那一批（只有汇总的数，没有别人的片名）
struct RequestFlowInfo: Decodable, Equatable, Sendable {
    struct Gate: Decodable, Equatable, Sendable {
        /// 已经清洗完、等着凑批的有几部（所有人的）
        var ready: Int
        /// 凑满几部开始传（16）
        var need: Int
    }

    struct Batch: Decodable, Equatable, Sendable {
        var id: Int
        /// copy（传输）/ verify（两端核对）/ purge（收尾）
        var stage: String
        /// 这一批一共几部
        var items: Int
        /// 这一批里是我的那几条请求（请求编号）
        var mine: [Int]
        var bytes: Double
        var total: Double
        /// 字节 / 秒
        var speed: Double
        /// 还要多少秒（服务器算的；没有 = 不知道）
        var eta: Double?
        var filesDone: Int
        var filesTotal: Int

        enum CodingKeys: String, CodingKey { case id, stage, items, mine, bytes, total, speed, eta, files }
        enum FileKeys: String, CodingKey { case done, total }

        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            id = (try? c.decode(Int.self, forKey: .id)) ?? 0
            stage = (try? c.decode(String.self, forKey: .stage)) ?? "copy"
            items = (try? c.decode(Int.self, forKey: .items)) ?? 0
            mine = (try? c.decode([Int].self, forKey: .mine)) ?? []
            bytes = (try? c.decode(Double.self, forKey: .bytes)) ?? 0
            total = (try? c.decode(Double.self, forKey: .total)) ?? 0
            speed = (try? c.decode(Double.self, forKey: .speed)) ?? 0
            eta = try? c.decode(Double.self, forKey: .eta)
            if let f = try? c.nestedContainer(keyedBy: FileKeys.self, forKey: .files) {
                filesDone = (try? f.decode(Int.self, forKey: .done)) ?? 0
                filesTotal = (try? f.decode(Int.self, forKey: .total)) ?? 0
            } else {
                filesDone = 0
                filesTotal = 0
            }
        }

        init(id: Int, stage: String, items: Int, mine: [Int], bytes: Double, total: Double, speed: Double, eta: Double?, filesDone: Int, filesTotal: Int) {
            self.id = id; self.stage = stage; self.items = items; self.mine = mine; self.bytes = bytes; self.total = total
            self.speed = speed; self.eta = eta; self.filesDone = filesDone; self.filesTotal = filesTotal
        }
    }

    var gate: Gate?
    var batch: Batch?
    /// 服务器建议隔几秒再问（传输中 5 秒，平时 20 秒）
    var poll: Double

    enum CodingKeys: String, CodingKey { case gate, batch, poll }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        gate = try? c.decode(Gate.self, forKey: .gate)
        batch = try? c.decode(Batch.self, forKey: .batch)
        poll = (try? c.decode(Double.self, forKey: .poll)) ?? 20
    }

    init(gate: Gate?, batch: Batch?, poll: Double) {
        self.gate = gate; self.batch = batch; self.poll = poll
    }
}

/// 请求中心里还没确认的那些（最多 50 部）
@MainActor
@Observable
final class RequestBasket {
    static let shared = RequestBasket()
    static let limit = 50

    struct Item: Codable, Hashable, Identifiable, Sendable {
        var kind: CatalogTitle.Kind
        var id: Int
        /// 剧集的哪一季（电影 0）
        var season: Int
        var title: String
        var year: String
        var poster: String?
        var added: Date

        var key: String { RequestStatus.key(src: kind.rawValue, id: id, season: season) }
        var catalogTitle: CatalogTitle { CatalogTitle(kind: kind, id: id, title: title, year: year, poster: poster) }
    }

    enum AddResult { case added, already, full }

    struct Outcome {
        var accepted = 0
        var joined = 0
        var failedRecently = 0
        var refused = 0
    }

    private(set) var items: [Item] = []
    /// 正在提交：按钮转圈、请求篮不让改
    private(set) var submitting = false
    /// 请求中心要不要切过去（详情页上「去确认」）：RootView 盯着它切标签
    var openCenter = false

    @ObservationIgnored private var user: String?
    private static func key(_ user: String?) -> String { "cuven_request_basket_" + (user ?? "") }

    private init() {}

    /// 换账户（登录、退出登录）：换成这个账户的请求篮
    func load(user: String?) {
        self.user = user
        if DemoData.enabled { items = Self.demoItems(); return }
        guard let data = UserDefaults.standard.data(forKey: Self.key(user)),
              let list = try? JSONDecoder().decode([Item].self, from: data) else { items = []; return }
        items = Array(list.prefix(Self.limit))
    }

    private func save() {
        guard !DemoData.enabled, let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: Self.key(user))
    }

    func contains(_ t: CatalogTitle, season: Int) -> Bool {
        let k = RequestStatus.key(src: t.kind.rawValue, id: t.id, season: t.kind == .tv ? season : 0)
        return items.contains { $0.key == k }
    }

    /// 这一部（剧集：任何一季）在不在请求中心里（目录卡上的「已加入」）
    func containsAny(src: String, id: Int) -> Bool {
        items.contains { $0.kind.rawValue == src && $0.id == id }
    }

    /// 服务器那边已经有这一部的请求了（别的设备上提交的、跟上了别人的）：从请求篮里拿掉，免得重复提交
    func dropSubmitted(_ list: [RequestStatus]) {
        let live = Set(list.filter { $0.state == .active || $0.state == .done }.map(\.key))
        guard items.contains(where: { live.contains($0.key) }) else { return }
        items.removeAll { live.contains($0.key) }
        save()
    }

    @discardableResult
    func add(_ t: CatalogTitle, season: Int) -> AddResult {
        if contains(t, season: season) { return .already }
        guard items.count < Self.limit else { return .full }
        items.append(Item(kind: t.kind, id: t.id, season: t.kind == .tv ? season : 0, title: t.title, year: t.year, poster: t.poster, added: Date()))
        save()
        return .added
    }

    func remove(_ item: Item) {
        items.removeAll { $0.key == item.key }
        save()
    }

    func clear() {
        items = []
        save()
    }

    /// 按「确认」：整篮一次提交。提交成功（新建 / 跟上 / 刚失败过 / 超出限额都算服务器答复过）的从篮子里拿掉；
    /// 网络出错时整篮留着，可以再按一次
    func submit() async throws -> Outcome {
        guard !submitting, !items.isEmpty else { return Outcome() }
        submitting = true
        defer { submitting = false }
        let list = items
        if DemoData.enabled {
            try? await Task.sleep(for: .milliseconds(900))
            items = []
            return Outcome(accepted: list.count)
        }
        guard let user, !user.isEmpty else { throw RequestAPIError.server("登录后才能请求添加。") }
        let r = try await RequestAPI.createBatch(user: user, items: list)
        var out = Outcome()
        var answered = Set<String>()
        for i in r.items {
            let k = RequestStatus.key(src: i.src, id: i.id, season: i.src == "tv" ? i.season : 0)
            switch i.result {
            case "created": out.accepted += 1; answered.insert(k)
            case "joined": out.joined += 1; answered.insert(k)
            case "failedRecently": out.failedRecently += 1; answered.insert(k)
            case "limit": out.refused += 1
            default: out.refused += 1; answered.insert(k)
            }
            if let s = i.request { RequestStore.shared.adopt(s) }
        }
        items.removeAll { answered.contains($0.key) }
        save()
        RequestNotice.requestPermission()
        await RequestStore.shared.refreshNow()
        return out
    }

    private static func demoItems() -> [Item] {
        let now = Date()
        func make(_ id: Int, _ kind: CatalogTitle.Kind, _ name: String, _ year: String, poster: Int, season: Int = 0) -> Item {
            Item(kind: kind, id: 7000 + id, season: season, title: name, year: year, poster: "demo://poster/\(poster)", added: now)
        }
        return [
            make(1, .movie, "潮汐之间", "2026", poster: 9),
            make(2, .tv, "夜航", "2025", poster: 10, season: 2),
            make(3, .movie, "风的形状", "2024", poster: 11),
        ]
    }
}

// MARK: - 漏斗那四段的数

/// 请求中心最上面那张卡：四段（已确认 → 已下载 → 已清洗 → 已入库）各有几部。
/// 算的是「我的」请求里还在进行中的，加上 24 小时内结束（就绪或没能添加）的；取消的不算
enum RequestFlowStats {
    enum Category: String, CaseIterable, Identifiable {
        case all, movie, tv
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: "全部"
            case .movie: "电影"
            case .tv: "剧集"
            }
        }
        var palette: FlowPalette {
            switch self {
            case .all: .all
            case .movie: .movie
            case .tv: .tv
            }
        }
    }

    static let stageNames = ["已确认", "已下载", "已清洗", "已入库"]
    /// 「最大落差」那颗小标签说的是卡在哪一步
    static let gapNames = ["云下载", "清洗", "传输"]

    private static let afterDownload: Set<String> = ["clean", "check", "rename", "ready", "copy", "verify", "purge", "release", "done"]
    private static let afterClean: Set<String> = ["ready", "copy", "verify", "purge", "release", "done"]

    static func inFlow(_ list: [RequestStatus], now: Date = Date()) -> [RequestStatus] {
        let cutoff = now.timeIntervalSince1970 * 1000 - 24 * 3600 * 1000
        return list.filter { s in
            switch s.state {
            case .active: true
            case .done, .failed: s.updated >= cutoff
            case .cancelled: false
            }
        }
    }

    static func counts(_ list: [RequestStatus], category: Category) -> [Int] {
        let l = list.filter { category == .all || $0.src == category.rawValue }
        let done = l.filter { $0.state == .done }.count
        let downloaded = l.filter { $0.state == .done || ($0.state == .active && afterDownload.contains($0.stage)) }.count
        let cleaned = l.filter { $0.state == .done || ($0.state == .active && afterClean.contains($0.stage)) }.count
        return [l.count, downloaded, cleaned, done]
    }
}
