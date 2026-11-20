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

    static func mine(user: String) async throws -> [RequestStatus] {
        var r = URLRequest(url: url("/app/requests", []))
        r.setValue(userHeader(user), forHTTPHeaderField: "x-cuven-user")
        let m: Mine = try await send(r)
        return m.items
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

    /// 我的请求（进行中的 + 30 天内结束的），按编号倒序
    private(set) var items: [RequestStatus] = []
    /// 主页「可请求添加」那一排（十分钟内不重取）
    private(set) var shelf: [CatalogItem] = []
    @ObservationIgnored private var shelfAt: Date?

    @ObservationIgnored private var user: String?
    @ObservationIgnored private var loop: Task<Void, Never>?
    /// 上次看到的每一条是什么状态（id → "stage|state"）：变了才发通知；存在本机，App 重开后照样比得出来
    @ObservationIgnored private var seen: [Int: String]
    private static let seenKey = "cuven_requests_seen"
    private static let userKey = "cuven_requests_user"

    private init() {
        seen = (UserDefaults.standard.dictionary(forKey: Self.seenKey) as? [String: String] ?? [:])
            .reduce(into: [:]) { out, kv in if let k = Int(kv.key) { out[k] = kv.value } }
    }

    var hasActive: Bool { items.contains { $0.state == .active && $0.stage != "release" } }

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

    /// 服务器回来的（详情页、目录里带的）也记下，详情页切季时马上有
    func merge(_ s: RequestStatus?) {
        guard let s else { return }
        if let i = items.firstIndex(where: { $0.id == s.id }) {
            if items[i] != s { items[i] = s }
        } else {
            items.insert(s, at: 0)
        }
    }

    // MARK: 轮询

    /// 登录后开始：有进行中的每 30 秒看一次，没有就 5 分钟一次；回到前台马上看一次
    func start(user: String?) {
        guard self.user != user || loop == nil else { return }
        self.user = user
        UserDefaults.standard.set(user, forKey: Self.userKey)
        loop?.cancel()
        items = []
        guard let user, !user.isEmpty, !DemoData.enabled else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh(user: user)
                let active = self?.hasActive ?? false
                try? await Task.sleep(for: .seconds(active ? 30 : 300))
            }
        }
    }

    func appBecameActive() {
        guard let user, !DemoData.enabled else { return }
        Task { await refresh(user: user) }
    }

    func refresh(user: String) async {
        guard let list = try? await RequestAPI.mine(user: user) else { return }
        apply(list)
    }

    private func apply(_ list: [RequestStatus]) {
        for s in list { notifyIfChanged(s) }
        items = list
        UserDefaults.standard.set(seen.reduce(into: [String: String]()) { $0[String($1.key)] = $1.value }, forKey: Self.seenKey)
    }

    private func notifyIfChanged(_ s: RequestStatus) {
        let tag = s.stage + "|" + s.state.rawValue
        defer { seen[s.id] = tag }
        guard let before = seen[s.id], before != tag else { return }
        let name = s.title.isEmpty ? "这部影片" : "《\(s.title)》" + (s.season > 0 ? "第 \(s.season) 季" : "")
        if s.state == .done {
            RequestNotice.post(id: s.id, body: "\(name)已就绪，现在可以观看了。")
        } else if s.state == .failed {
            RequestNotice.post(id: s.id, body: "\(name)暂时无法添加，请稍后再试。")
        } else if s.stage == "release" && !before.hasPrefix("release|") {
            RequestNotice.post(id: s.id, body: "\(name)已进入最终发行审批，就绪后会再提醒您。")
        }
    }

    // MARK: 请求

    func request(_ t: CatalogTitle, season: Int) async throws -> RequestStatus {
        if DemoData.enabled { return demoRequest(t, season: season) }
        guard let user, !user.isEmpty else { throw RequestAPIError.server("登录后才能请求添加。") }
        let s = try await RequestAPI.create(user: user, title: t, season: season)
        seen[s.id] = seen[s.id] ?? (s.stage + "|" + s.state.rawValue)
        merge(s)
        RequestNotice.requestPermission()
        return s
    }

    /// 演示数据：先停在第 1 步，1.6 秒后走到第 3 步 40%（截图用）
    private func demoRequest(_ t: CatalogTitle, season: Int) -> RequestStatus {
        let s = RequestStatus(id: 9000 + t.id % 1000, title: t, season: season, step: 1, pct: 0, note: "排队，准备推送到 PikPak")
        merge(s)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1600))
            var next = RequestStatus(id: s.id, title: t, season: season, step: 3, pct: 40, note: "整理并核对整季")
            next.stage = "check"
            merge(next)
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
            guard let id = seriesMetas[s.path]?.id else { continue }
            out[id, default: []].insert(s.season ?? 1)
        }
        return out
    }

    /// 目录里这一条是不是片库里已经有了（剧集：有任何一季就算有，整部剧走片库的详情页）
    func owns(_ item: CatalogItem, movies: Set<Int>, shows: [Int: Set<Int>]) -> Bool {
        item.src == "tv" ? shows[item.id] != nil : movies.contains(item.id)
    }
}
