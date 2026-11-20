import Foundation
import BackgroundTasks
import UserNotifications

// MARK: - 请求添加（tj.cuven.us，代码在仓库的 request/）
//
// 影片库（lb.cuven.us）索引里的全部已知电影和剧集都能在 App 里看到，片库里没有的那部，详情页的「播放」换成「请求添加」。
// 按下去请求添加 Worker 就接管整条链：推到 PikPak → 云下载 → 清洗 → 传到 Dropbox → 等工作人员发行。
// App 这边只做三件事：发请求、轮询进度（详情页那张五步进度卡）、状态一变发一条本机通知。
// 通知只在这三处发：进入最终发行审批、已就绪、没能添加（只说结果，不说内部出了什么事）。App 不在前台时靠系统的后台刷新（BGAppRefreshTask）偶尔看一眼，不保证准时。

/// 索引里的一部片 / 一部剧（还没在片库里），详情页的路由参数
struct CatalogTitle: Hashable, Sendable {
    enum Kind: String, Hashable, Sendable { case movie, tv }
    var kind: Kind
    /// TMDB 编号
    var id: Int
    var title: String
    var year: String
    var poster: String?
}

/// 进度里的一条（服务器的 view()）
struct RequestStatus: Decodable, Hashable, Identifiable, Sendable {
    enum State: String, Decodable, Sendable { case active, done, failed, cancelled }
    struct Spec: Decodable, Hashable, Sendable {
        var res: String?
        var labels: [String]?
        var size: String?
    }

    var id: Int
    var src: String
    var tmdb: Int
    var season: Int
    var title: String
    var year: String
    var poster: String?
    var stage: String
    var state: State
    var step: Int
    var steps: Int
    var pct: Int
    var label: String
    var note: String
    var spec: Spec?
    var tries: Int
    var updated: Double

    enum CodingKeys: String, CodingKey {
        case id, src, tmdb, season, title, year, poster, stage, state, step, steps, pct, label, note, spec, tries, updated
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        src = (try? c.decode(String.self, forKey: .src)) ?? "movie"
        tmdb = (try? c.decode(Int.self, forKey: .tmdb)) ?? 0
        season = (try? c.decode(Int.self, forKey: .season)) ?? 0
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        year = c.looseString(.year)
        poster = try? c.decode(String.self, forKey: .poster)
        stage = (try? c.decode(String.self, forKey: .stage)) ?? "queued"
        state = (try? c.decode(State.self, forKey: .state)) ?? .active
        step = (try? c.decode(Int.self, forKey: .step)) ?? 1
        steps = (try? c.decode(Int.self, forKey: .steps)) ?? 5
        pct = (try? c.decode(Int.self, forKey: .pct)) ?? 0
        label = (try? c.decode(String.self, forKey: .label)) ?? ""
        note = (try? c.decode(String.self, forKey: .note)) ?? ""
        spec = try? c.decode(Spec.self, forKey: .spec)
        tries = (try? c.decode(Int.self, forKey: .tries)) ?? 0
        updated = (try? c.decode(Double.self, forKey: .updated)) ?? 0
    }

    /// 演示 / 刚按下去还没等到服务器回话时用的那一条
    init(id: Int, title: CatalogTitle, season: Int, step: Int, pct: Int, note: String, state: State = .active) {
        self.id = id; src = title.kind.rawValue; tmdb = title.id; self.season = season
        self.title = title.title; year = title.year; poster = title.poster
        stage = step >= 5 ? "release" : "queued"; self.state = state; self.step = step; steps = 5; self.pct = pct
        label = RequestStatus.labels[max(0, min(4, step - 1))]; self.note = note; spec = nil; tries = 0
        updated = Date().timeIntervalSince1970 * 1000
    }

    /// 五步的名字（和服务器的 STEP_LABELS 一致）
    static let labels = ["等待制片商", "等待回应", "等待品质管理", "等待传输", "最终发行审批"]

    var key: String { RequestStatus.key(src: src, id: tmdb, season: season) }
    /// 这条请求对应的那部（详情页、播放用）
    var catalogTitle: CatalogTitle {
        CatalogTitle(kind: src == "tv" ? .tv : .movie, id: tmdb, title: title, year: year, poster: poster)
    }
    static func key(src: String, id: Int, season: Int) -> String { "\(src)-\(id)-\(season)" }

    /// 这一步自己走了多少（0…1）：百分比 =（第几步 − 1 + 这一步的进度）÷ 5
    var stepProgress: Double {
        guard state == .active else { return 0 }
        return max(0, min(1, Double(pct) / 100 * Double(steps) - Double(step - 1)))
    }
}

/// /app/catalog 的一条
struct CatalogItem: Decodable, Hashable, Identifiable, Sendable {
    var id: Int
    var src: String
    var title: String
    var year: String
    var poster: String?
    var vote: Double?
    var res: String?
    var req: RequestStatus?

    enum CodingKeys: String, CodingKey { case id, src, title, year, poster, vote, res, req }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        src = (try? c.decode(String.self, forKey: .src)) ?? "movie"
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        year = c.looseString(.year)
        poster = try? c.decode(String.self, forKey: .poster)
        vote = try? c.decode(Double.self, forKey: .vote)
        res = try? c.decode(String.self, forKey: .res)
        req = try? c.decode(RequestStatus.self, forKey: .req)
    }

    init(demo id: Int, src: String, title: String, year: String, poster: String?) {
        self.id = id; self.src = src; self.title = title; self.year = year; self.poster = poster
        vote = nil; res = nil; req = nil
    }

    var uid: String { "\(src)-\(id)" }
    var catalogTitle: CatalogTitle {
        CatalogTitle(kind: src == "tv" ? .tv : .movie, id: id, title: title, year: year, poster: poster)
    }
}

/// /app/detail：有没有可请求的资源、每一季的进度
struct CatalogDetail: Decodable, Sendable {
    var id: Int
    var src: String
    var known: Int
    var title: String?
    var year: String
    var poster: String?
    var seasons: [Int]
    var season: Int
    var count: Int
    var best: RequestStatus.Spec?
    var req: RequestStatus?
    var reqs: [String: RequestStatus]

    enum CodingKeys: String, CodingKey { case id, src, known, title, year, poster, seasons, season, count, best, req, reqs }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(Int.self, forKey: .id)) ?? 0
        src = (try? c.decode(String.self, forKey: .src)) ?? "movie"
        known = (try? c.decode(Int.self, forKey: .known)) ?? 0
        title = try? c.decode(String.self, forKey: .title)
        year = c.looseString(.year)
        poster = try? c.decode(String.self, forKey: .poster)
        seasons = (try? c.decode([Int].self, forKey: .seasons)) ?? []
        season = (try? c.decode(Int.self, forKey: .season)) ?? 0
        count = (try? c.decode(Int.self, forKey: .count)) ?? 0
        best = try? c.decode(RequestStatus.Spec.self, forKey: .best)
        req = try? c.decode(RequestStatus.self, forKey: .req)
        reqs = (try? c.decode([String: RequestStatus].self, forKey: .reqs)) ?? [:]
    }

    init(demo title: CatalogTitle, seasons: [Int], count: Int, best: RequestStatus.Spec?) {
        id = title.id; src = title.kind.rawValue; known = 1; self.title = title.title; year = title.year; poster = title.poster
        self.seasons = seasons; season = seasons.last ?? 0; self.count = count; self.best = best; req = nil; reqs = [:]
    }
}

private extension KeyedDecodingContainer {
    /// 年份有时是字符串有时是数字
    func looseString(_ k: Key) -> String {
        if let s = try? decode(String.self, forKey: k) { return s }
        if let i = try? decode(Int.self, forKey: k) { return String(i) }
        return ""
    }
}

enum RequestAPIError: LocalizedError {
    case server(String)
    var errorDescription: String? { if case .server(let m) = self { return m }; return nil }
}

/// tj.cuven.us 的 App 接口
enum RequestAPI {
    static let base = "https://tj.cuven.us"

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        cfg.httpAdditionalHeaders = ["Accept": "application/json"]
        cfg.urlCache = nil
        return URLSession(configuration: cfg)
    }()

    private static func url(_ path: String, _ q: [(String, String)]) -> URL {
        var c = URLComponents(string: base + path)!
        if !q.isEmpty {
            c.queryItems = q.map { URLQueryItem(name: $0.0, value: $0.1) }
            c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        return c.url!
    }

    /// 用户名放进头里：头里只能放 ASCII，按 encodeURIComponent 编码（服务器那头解回来）
    private static func userHeader(_ user: String) -> String {
        user.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_.!~*'()"))) ?? user
    }

    private static func send<T: Decodable>(_ req: URLRequest) async throws -> T {
        let (data, resp) = try await session.data(for: req)
        UsageMeter.shared.add(data.count, to: .data)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if !(200..<300).contains(code) {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw RequestAPIError.server(msg ?? "服务暂时不可用，请稍后再试。")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    struct CatalogPage: Decodable { var items: [CatalogItem] }

    static func catalog(src: String = "all", query: String = "", sort: String = "new", own: String = "all", page: Int = 1) async throws -> [CatalogItem] {
        var q: [(String, String)] = [("src", src), ("sort", sort), ("own", own), ("page", String(page))]
        if !query.isEmpty { q.append(("q", query)) }
        let p: CatalogPage = try await send(URLRequest(url: url("/app/catalog", q)))
        return p.items
    }

    static func detail(_ t: CatalogTitle, season: Int?) async throws -> CatalogDetail {
        var q: [(String, String)] = [("src", t.kind.rawValue), ("id", String(t.id))]
        if let season, season > 0 { q.append(("season", String(season))) }
        return try await send(URLRequest(url: url("/app/detail", q)))
    }

    struct Mine: Decodable { var items: [RequestStatus] }

    /// 我的请求。带上次的 ETag：没变服务器回 304，这里回 items = nil（不用重新解码、不重画）
    static func mine(user: String, etag: String?) async throws -> (items: [RequestStatus]?, etag: String?) {
        var r = URLRequest(url: url("/app/requests", []))
        r.setValue(userHeader(user), forHTTPHeaderField: "x-cuven-user")
        if let etag { r.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let (data, resp) = try await session.data(for: r)
        UsageMeter.shared.add(data.count, to: .data)
        let http = resp as? HTTPURLResponse
        let tag = http?.value(forHTTPHeaderField: "ETag")
        switch http?.statusCode ?? 0 {
        case 304: return (nil, etag)
        case 200..<300: return (try JSONDecoder().decode(Mine.self, from: data).items, tag)
        default:
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw RequestAPIError.server(msg ?? "服务暂时不可用，请稍后再试。")
        }
    }

    struct Created: Decodable { var request: RequestStatus }

    static func create(user: String, title: CatalogTitle, season: Int) async throws -> RequestStatus {
        var r = URLRequest(url: url("/app/requests", []))
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue(userHeader(user), forHTTPHeaderField: "x-cuven-user")
        var body: [String: Any] = ["src": title.kind.rawValue, "id": title.id]
        if title.kind == .tv { body["season"] = season }
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        let c: Created = try await send(r)
        return c.request
    }
}

// MARK: - 我的请求：轮询 + 本机通知

@MainActor
@Observable
final class RequestStore {
    static let shared = RequestStore()
    static let refreshTask = "us.cuven.tv.requests"

    /// 知道的所有请求进度（我的 + 详情页 / 目录里带回来的别人的）：查某一部、某一季的进度用
    private(set) var items: [RequestStatus] = []
    /// 只有我自己的请求（/app/requests 和刚提交的），新的在前：请求中心用
    private(set) var mine: [RequestStatus] = []
    /// 主页「可请求添加」那一排（十分钟内不重取）
    private(set) var shelf: [CatalogItem] = []
    @ObservationIgnored private var shelfAt: Date?

    @ObservationIgnored private var user: String?
    @ObservationIgnored private var loop: Task<Void, Never>?
    /// 上一次「我的请求」的 ETag：没变服务器回 304
    @ObservationIgnored private var etag: String?
    /// 正在问：回到前台、轮询、后台刷新撞在一起时只问一次
    @ObservationIgnored private var refreshing = false
    /// 连着问失败几次（没网、服务器出错）：轮询按 2 的倍数放慢，最慢 10 分钟一次
    @ObservationIgnored private var failures = 0
    /// 有请求刚发行：片库里多了这部，让 App 刷新片库（RootView 接上 AppModel）。同一时间只刷一次
    @ObservationIgnored var onReleased: (() async -> Void)?
    @ObservationIgnored private var releaseRefresh: Task<Void, Never>?
    /// 上次看到的每一条是什么状态（id → "stage|state"）：变了才发通知；存在本机，App 重开后照样比得出来
    @ObservationIgnored private var seen: [Int: String]
    private static let seenKey = "cuven_requests_seen"
    private static let userKey = "cuven_requests_user"

    private init() {
        seen = (UserDefaults.standard.dictionary(forKey: Self.seenKey) as? [String: String] ?? [:])
            .reduce(into: [:]) { out, kv in if let k = Int(kv.key) { out[k] = kv.value } }
    }

    var hasActive: Bool { items.contains { $0.state == .active && $0.stage != "release" } }
    /// 我进行中的请求有几个（标签栏「请求」上的角标）
    var activeCount: Int { mine.filter { $0.state == .active }.count }

    /// 这一部 / 这一季最要紧的那一条：进行中的优先，其次最新的
    func status(src: String, id: Int, season: Int) -> RequestStatus? {
        let k = RequestStatus.key(src: src, id: id, season: season)
        let all = items.filter { $0.key == k }
        return all.first { $0.state == .active } ?? all.max { $0.id < $1.id }
    }

    /// 一部剧任何一季的进度（目录卡上的角标）
    func anyStatus(src: String, id: Int) -> RequestStatus? {
        let all = items.filter { $0.src == src && $0.tmdb == id }
        return all.first { $0.state == .active } ?? all.max { $0.id < $1.id }
    }

    /// 服务器回来的（详情页、目录里带的）也记下，详情页切季时马上有；是我的那条就连请求中心一起更新
    func merge(_ s: RequestStatus?) {
        guard let s else { return }
        if let i = items.firstIndex(where: { $0.id == s.id }) {
            if items[i] != s { items[i] = s }
        } else {
            items.insert(s, at: 0)
        }
        if let i = mine.firstIndex(where: { $0.id == s.id }), mine[i] != s { mine[i] = s }
    }

    // MARK: 轮询

    /// 登录后开始：有进行中的每 30 秒看一次，没有就 5 分钟一次；回到前台马上看一次。
    /// 问失败了（没网、服务器出错）按 2 的倍数放慢（最慢 10 分钟），通了马上回到原来的节奏；间隔带一点随机，
    /// 很多台手机不会在同一秒一起问
    func start(user: String?) {
        guard self.user != user || loop == nil else { return }
        self.user = user
        UserDefaults.standard.set(user, forKey: Self.userKey)
        loop?.cancel()
        items = []
        mine = []
        etag = nil
        failures = 0
        if DemoData.enabled { loadDemo(); return }
        guard let user, !user.isEmpty else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh(user: user)
                guard let self else { return }
                let base: Double = self.hasActive ? 30 : 300
                let backoff = self.failures > 0 ? min(600, base * pow(2, Double(min(self.failures, 4)))) : base
                try? await Task.sleep(for: .seconds(backoff * Double.random(in: 0.9...1.1)))
            }
        }
    }

    /// 请求中心打开 / 下拉时：马上问一次
    func refreshNow() async {
        guard let user, !DemoData.enabled else { return }
        await refresh(user: user)
    }

    func appBecameActive() {
        guard let user, !DemoData.enabled else { return }
        Task { await refresh(user: user) }
    }

    func refresh(user: String) async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let r = try await RequestAPI.mine(user: user, etag: etag)
            failures = 0
            guard self.user == user else { return }          // 问的时候换了账户：这份作废
            if let list = r.items {
                apply(list)
                etag = r.etag
            }
        } catch {
            failures += 1
        }
    }

    private func apply(_ list: [RequestStatus]) {
        for s in list { notifyIfChanged(s) }
        items = list
        mine = list.sorted { $0.id > $1.id }
        UserDefaults.standard.set(seen.reduce(into: [String: String]()) { $0[String($1.key)] = $1.value }, forKey: Self.seenKey)
    }

    private func notifyIfChanged(_ s: RequestStatus) {
        let tag = s.stage + "|" + s.state.rawValue
        defer { seen[s.id] = tag }
        guard let before = seen[s.id], before != tag else { return }
        let name = s.title.isEmpty ? "这部影片" : "《\(s.title)》" + (s.season > 0 ? "第 \(s.season) 季" : "")
        if s.state == .done {
            RequestNotice.post(id: s.id, body: "\(name)已就绪，现在可以观看了。")
            refreshLibraryAfterRelease()
        } else if s.state == .failed {
            RequestNotice.post(id: s.id, body: "\(name)暂时无法添加，请稍后再试。")
        } else if s.stage == "release" && !before.hasPrefix("release|") {
            RequestNotice.post(id: s.id, body: "\(name)已进入最终发行审批，就绪后会再提醒您。")
        }
    }

    /// 刚发行的那部要能马上「立即播放」：刷新一次片库（几条同时发行也只刷一次）
    private func refreshLibraryAfterRelease() {
        guard releaseRefresh == nil, let hook = onReleased else { return }
        releaseRefresh = Task { [weak self] in
            await hook()
            self?.releaseRefresh = nil
        }
    }

    // MARK: 请求

    func request(_ t: CatalogTitle, season: Int) async throws -> RequestStatus {
        if DemoData.enabled { return demoRequest(t, season: season) }
        guard let user, !user.isEmpty else { throw RequestAPIError.server("登录后才能请求添加。") }
        let s = try await RequestAPI.create(user: user, title: t, season: season)
        seen[s.id] = seen[s.id] ?? (s.stage + "|" + s.state.rawValue)
        merge(s)
        mine.removeAll { $0.id == s.id }
        mine.insert(s, at: 0)
        etag = nil                                            // 列表变了：下一次轮询完整取一份
        RequestNotice.requestPermission()
        return s
    }

    /// 演示数据（截图用）：请求中心里几条不同阶段的请求（不含详情页演示用的那部）
    private func loadDemo() {
        let t = Date().timeIntervalSince1970 * 1000
        func make(_ id: Int, _ kind: CatalogTitle.Kind, _ name: String, _ year: String, poster: Int, season: Int = 0,
                  step: Int, pct: Int, state: RequestStatus.State = .active, stage: String, ago: Double) -> RequestStatus {
            var s = RequestStatus(id: id, title: CatalogTitle(kind: kind, id: 5000 + id, title: name, year: year, poster: "demo://poster/\(poster)"),
                                  season: season, step: step, pct: pct, note: "", state: state)
            s.stage = stage
            s.updated = t - ago * 60_000
            return s
        }
        mine = [
            make(18, .movie, "北方来信", "2026", poster: 2, step: 4, pct: 66, stage: "copy", ago: 3),
            make(17, .tv, "盛夏未至", "2025", poster: 4, season: 1, step: 3, pct: 46, stage: "rename", ago: 9),
            make(16, .movie, "雾中灯塔", "2026", poster: 3, step: 2, pct: 31, stage: "download", ago: 14),
            make(15, .movie, "第七号站台", "2024", poster: 6, step: 5, pct: 80, stage: "release", ago: 52),
            make(14, .movie, "无声海岸", "2025", poster: 5, step: 5, pct: 100, state: .done, stage: "done", ago: 190),
            make(13, .tv, "远山的回响", "2023", poster: 7, season: 2, step: 2, pct: 20, state: .failed, stage: "failed", ago: 1500),
            make(12, .movie, "白昼之下", "2026", poster: 8, step: 5, pct: 100, state: .done, stage: "done", ago: 3000),
        ]
        items = mine
    }

    /// 演示数据：先停在第 1 步，1.6 秒后走到第 3 步 40%（截图用）
    private func demoRequest(_ t: CatalogTitle, season: Int) -> RequestStatus {
        let s = RequestStatus(id: 9000 + t.id % 1000, title: t, season: season, step: 1, pct: 0, note: "排队，准备推送到 PikPak")
        merge(s)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1600))
            var next = RequestStatus(id: s.id, title: t, season: season, step: 3, pct: 40, note: "")
            next.stage = "check"
            merge(next)
            /* 再过一会儿走完（截图：卡停在 100%，再收回成「立即播放」） */
            try? await Task.sleep(for: .milliseconds(3000))
            var done = RequestStatus(id: s.id, title: t, season: season, step: 5, pct: 100, note: "", state: .done)
            done.stage = "done"
            merge(done)
        }
        return s
    }

    // MARK: 主页那一排

    func loadShelf() async {
        if DemoData.enabled || (shelfAt.map { Date().timeIntervalSince($0) < 600 } ?? false) { return }
        guard let list = try? await RequestAPI.catalog(src: "all", sort: "new", own: "hide") else { return }
        shelf = list
        shelfAt = Date()
        for i in list { if let r = i.req { merge(r) } }
    }

    // MARK: 后台刷新（App 不在前台时偶尔看一眼，发通知）

    /// 进后台时：还有在跑的请求就排一次后台刷新（系统决定什么时候真的叫醒，最早 15 分钟后）
    func scheduleBackgroundRefresh() {
        guard hasActive || items.contains(where: { $0.stage == "release" && $0.state == .active }) else { return }
        let r = BGAppRefreshTaskRequest(identifier: Self.refreshTask)
        r.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(r)
    }

    func handleBackgroundRefresh() async {
        let u = user ?? UserDefaults.standard.string(forKey: Self.userKey)
        guard let u, !u.isEmpty else { return }
        await refresh(user: u)
        scheduleBackgroundRefresh()
    }
}

/// 请求添加的本机通知（App 在前台也弹横幅：PrecacheNotice 装的那个代理）
enum RequestNotice {
    static func requestPermission() {
        Task {
            let center = UNUserNotificationCenter.current()
            let s = await center.notificationSettings()
            guard s.authorizationStatus == .notDetermined else { return }
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
    }

    static func post(id: Int, body: String) {
        let c = UNMutableNotificationContent()
        c.title = "请求添加"
        c.body = body
        c.sound = .default
        c.threadIdentifier = "requests"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "request-\(id)-\(UUID().uuidString.prefix(6))", content: c, trigger: nil))
    }
}

// MARK: - 片库里已经有的（TMDB 编号）：目录里不再列

extension AppModel {
    /// 片库里电影的 TMDB 编号
    var ownedMovieIDs: Set<Int> { Set(movies.compactMap { meta($0)?.id }) }
    /// 片库里剧集的 TMDB 编号 → 有哪几季
    var ownedSeasons: [Int: Set<Int>] {
        var out: [Int: Set<Int>] = [:]
        for s in series {
            guard let id = s.tmdbId ?? seriesMetas[s.path]?.id else { continue }
            out[id, default: []].insert(s.season ?? 1)
        }
        return out
    }

    /// 目录里这一条是不是片库里已经有了（剧集：有任何一季就算有，整部剧走片库的详情页）
    func owns(_ item: CatalogItem, movies: Set<Int>, shows: [Int: Set<Int>]) -> Bool {
        item.src == "tv" ? shows[item.id] != nil : movies.contains(item.id)
    }
}
