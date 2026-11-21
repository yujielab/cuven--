import Foundation

enum APIError: LocalizedError {
    case http(Int, String?)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .http: return "服务暂时不可用，请稍后再试。"
        case .badResponse: return "出了点问题，请稍后再试。"
        }
    }
}

/// 给人看的错误说明：发行版不露技术细节（HTTP 状态码、服务器的原话、系统的英文错误），只说怎么了、该怎么办
enum FriendlyError {
    static func message(_ error: Error) -> String {
        let e = error as NSError
        if e.domain == NSURLErrorDomain {
            switch e.code {
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorDataNotAllowed:
                return "网络连接已断开，请检查网络后重试。"
            case NSURLErrorTimedOut:
                return "连接超时，请稍后再试。"
            case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed:
                return "无法连接服务器，请稍后再试。"
            default:
                break
            }
        }
        return "请稍后再试。"
    }
}

/// 直连 Stream Worker 的接口。生产环境没开签名（AUTH_SECRET 为空），不需要登录态。
final class APIClient: @unchecked Sendable {
    static let shared = APIClient()
    static let base = "https://stream.cuven.online"

    let session: URLSession
    private let decoder = JSONDecoder()

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 25
        cfg.timeoutIntervalForResource = 120
        cfg.waitsForConnectivity = false
        cfg.httpAdditionalHeaders = ["Accept": "application/json"]
        cfg.urlCache = URLCache(memoryCapacity: 8 << 20, diskCapacity: 64 << 20)
        session = URLSession(configuration: cfg)
    }

    /// 拼 URL。查询值里的「+」要转成 %2B：后端按 URLSearchParams 解，裸的 + 会被当成空格
    func url(_ path: String, _ query: [(String, String)] = [], base: String = APIClient.base) -> URL {
        var comps = URLComponents(string: base + path)!
        if !query.isEmpty {
            comps.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
            comps.percentEncodedQuery = comps.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        return comps.url!
    }

    private func check(_ resp: URLResponse, _ data: Data) throws {
        guard let http = resp as? HTTPURLResponse else { throw APIError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            var msg: String?
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                msg = obj["error"] as? String
            }
            throw APIError.http(http.statusCode, msg)
        }
    }

    /// 发请求；回包的字节数记进流量（账户页「流量概览」的「图片与资料」，按解压后的大小，略偏大）
    private func load(_ req: URLRequest) async throws -> (Data, URLResponse) {
        let (data, resp) = try await session.data(for: req)
        UsageMeter.shared.add(data.count, to: .data)
        return (data, resp)
    }

    func get<T: Decodable>(_ path: String, _ query: [(String, String)] = [], timeout: TimeInterval = 25, fresh: Bool = false) async throws -> T {
        var req = URLRequest(url: url(path, query), timeoutInterval: timeout)
        if fresh { req.cachePolicy = .reloadIgnoringLocalCacheData }
        let (data, resp) = try await load(req)
        try check(resp, data)
        return try decoder.decode(T.self, from: data)
    }

    func post<T: Decodable>(_ path: String, json: [String: Any], timeout: TimeInterval = 40) async throws -> T {
        var req = URLRequest(url: url(path), timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: json)
        let (data, resp) = try await load(req)
        try check(resp, data)
        return try decoder.decode(T.self, from: data)
    }

    // MARK: 片库

    func library() async throws -> LibraryPayload {
        try await get("/api/all", timeout: 30, fresh: true)
    }

    /// 一个文件夹里的子文件夹与视频（网页版 enterFolder）：path 是相对片库根目录的路径
    func list(path: String) async throws -> FolderListing {
        try await get("/api/list", [("path", path)], timeout: 15)
    }

    /// 一批文件名 → TMDB 结果。回包里：值为 null = 后端确定认不出（不显示）；没有这个键 = 这次没问成（过会儿再问）。
    /// full = true 时带字标、演员、剧照（详情页用）
    func metaBatch(_ names: [String], full: Bool = false) async throws -> [String: Meta?] {
        let queries: [[String: Any]] = names.map { full ? ["name": $0, "logo": true] : ["name": $0] }
        let batch: MetaBatch = try await post("/api/tmdb-batch", json: ["queries": queries])
        return batch.items
    }

    /// 单条 TMDB（剧集按剧集表认好的编号取，详情页要字标 / 纯净海报 / 剧照）
    func tmdb(query: String, year: String?, type: String?, id: Int?, full: Bool) async throws -> Meta? {
        var q: [(String, String)] = [("query", query), ("language", "zh-CN")]
        if full { q += [("logo", "1"), ("include_image_language", "zh,en,null")] }
        if let year, !year.isEmpty { q.append(("year", year)) }
        if let type { q.append(("type", type)) }
        if let id { q.append(("id", String(id))) }
        return try await get("/api/tmdb", q, timeout: 20)
    }

    // MARK: 剧集

    /// 请片库马上重看一眼 /auto（请求添加刚自动通过最终审核、片库清单里还没有这一部时）。后端 10 秒内最多真列一次；出错不管
    func autoSync() async {
        if DemoData.enabled { return }
        var req = URLRequest(url: url("/api/auto/sync", [("tv", "1")]), timeoutInterval: 20)
        req.httpMethod = "POST"
        _ = try? await load(req)
    }

    /// 剧集表：不用本机缓存（后端回 max-age=60）——请求添加刚就绪、还在 /auto 里的那一季要马上能「立即播放」
    func tvList() async throws -> [Series] {
        let p: TVPayload = try await get("/api/tv", timeout: 30, fresh: true)
        return p.series
    }

    func episodes(seriesPath: String) async throws -> [EpisodeFile] {
        let p: EpisodesPayload = try await get("/api/tv/episodes", [("path", seriesPath)], timeout: 25)
        return p.episodes
    }

    func season(tmdbId: Int, season: Int) async throws -> [SeasonEpisode] {
        let p: SeasonPayload = try await get("/api/tmdb/season", [("id", String(tmdbId)), ("season", String(season))], timeout: 20)
        return p.episodes
    }

    // MARK: 演员

    /// 演员个人页：简介、出生、出生地、全部作品的编号（老 Worker 没有这个接口：抛错，调用的地方当没有）
    func person(id: Int) async throws -> PersonInfo {
        try await get("/api/tmdb/person", [("id", String(id))], timeout: 15)
    }

    // MARK: 首页大图

    func heroes() async throws -> [Hero] {
        let p: HeroPayload = try await get("/api/atv/hero", timeout: 20)
        return p.heroes
    }

    // MARK: 预告片

    /// 按片名（英文名）在 Apple TV 上找这部片，连预告片一起
    func atvLookup(title: String) async throws -> AtvLookup {
        try await get("/api/atv/lookup", [("title", title), ("video", "1")], timeout: 20)
    }

    /// 后端还没有 /api/atv/art（Worker 没重新部署）：这一次打开就不再问，画面全用 TMDB
    struct AtvArtUnavailable: Error {}

    private struct AtvArtRequest: Encodable { let items: [AtvArtQuery] }

    /// 一批电影的 Apple TV 素材（全片库：海报、竖版主视觉、16:9、无字背景、字标）。一次最多 120 部。
    /// 404 / 405 → AtvArtUnavailable；回包解不出来也按「没有这个接口」算（老版本的 Worker）
    func atvArt(_ items: [AtvArtQuery]) async throws -> AtvArtResponse {
        var req = URLRequest(url: url("/api/atv/art", [("w", "1280"), ("pw", "600"), ("f", "webp")]), timeoutInterval: 40)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(AtvArtRequest(items: items))
        let (data, resp) = try await load(req)
        if let http = resp as? HTTPURLResponse, http.statusCode == 404 || http.statusCode == 405 {
            throw AtvArtUnavailable()
        }
        try check(resp, data)
        guard let r = try? decoder.decode(AtvArtResponse.self, from: data) else { throw AtvArtUnavailable() }
        return r
    }

    // MARK: 在线字幕

    private struct SubsWarm: Decodable {
        struct Item: Decodable { var online: Bool? }
        var subs: [Item]?
    }

    /// 详情页一打开就让后台先去找这部片的在线字幕（warm=1：后端立刻回，不等结果）。
    /// 每部片都会有一条在线字幕备选；片子自带中文字幕时仍默认用自带的。播放时 HLS 主列表里就有它，不必等。
    /// 已经找好的（回包里有在线那一条）记在本机，之后再打开不再问（用户要求「自动缓存已经获取的字幕避免触发拉取」：SubsReady）
    func warmSubs(path: String) async {
        if SubsReady.has(path) { return }
        let r: SubsWarm? = try? await get("/api/subs", [("path", path), ("warm", "1")], timeout: 15, fresh: true)
        if r?.subs?.contains(where: { $0.online == true }) == true { SubsReady.mark(path) }
    }

    /// 在线字幕服务的状态（账户页「播放」里「在线字幕」那一行）。fresh：点了那一行重新检测（后端 1 分钟内最多真问一次 OpenSubtitles）
    func subsStatus(fresh: Bool) async throws -> SubsServiceStatus {
        try await get("/api/subs/status", fresh ? [("fresh", "1")] : [], timeout: 20, fresh: true)
    }

    // MARK: 播放

    func streamSign(path: String) async throws -> StreamSign {
        try await get("/api/stream-sign", [("path", path)], timeout: 12, fresh: true)
    }

    /// HLS 的 info.json：200 且 ok → 能放；4xx（404 除外）→ 这个文件转不了，带着原因；404 / 网络错 → 退回直链
    func hlsInfo(_ url: URL) async -> (status: Int, info: HLSInfo?) {
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, resp) = try? await load(req), let http = resp as? HTTPURLResponse else { return (0, nil) }
        return (http.statusCode, try? decoder.decode(HLSInfo.self, from: data))
    }

    /// 直链：文件名只是装饰，后端只认 ?path=。MP4 / MOV 带 safari=1（后端的 FourCC 热修补）
    /// base：影片走哪个入口（Cuven Pass Pro 开着时是加速节点；签名只盖路径，换主机名照样有效）
    func streamURL(path: String, name: String, sign: StreamSign?, base: String = APIClient.base) -> URL {
        let ext = (name as NSString).pathExtension.lowercased()
        var q: [(String, String)] = [("path", path)]
        if let exp = sign?.exp, let sig = sign?.sig, !exp.isEmpty, !sig.isEmpty { q += [("exp", exp), ("sig", sig)] }
        if ["mp4", "m4v", "mov"].contains(ext) { q.append(("safari", "1")) }
        let file = "Cuven." + (ext.isEmpty ? "mp4" : ext)
        return url("/stream/" + file, q, base: base)
    }
}

/// /api/tmdb-batch 的回包：{ 文件名: Meta | null, …, "__match": 2 }
struct MetaBatch: Decodable {
    var items: [String: Meta?] = [:]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        for k in c.allKeys where !k.stringValue.hasPrefix("__") {
            if (try? c.decodeNil(forKey: k)) == true {
                items[k.stringValue] = .some(nil)
            } else if let m = try? c.decode(Meta.self, forKey: k) {
                items[k.stringValue] = .some(m)
            }
        }
    }
}

/// 在线字幕已经找好的片子（本机记着：路径 → 记下的时间）。后端那条记录按文件存在 R2，每部片只用一次 OpenSubtitles 的下载配额；
/// 这里再省掉每次打开详情页都去问一遍（后端要列一次目录、拿一次临时链接）。30 天后再问一次（换了文件、换了字幕也跟得上），最多记 3000 部
enum SubsReady {
    private static let key = "subs-ready.v1"
    private static let ttl: Double = 30 * 86_400
    private static let cap = 3000

    static func has(_ path: String) -> Bool {
        guard let d = UserDefaults.standard.dictionary(forKey: key) as? [String: Double], let t = d[path] else { return false }
        return Date().timeIntervalSince1970 - t < ttl
    }

    static func mark(_ path: String) {
        var d = (UserDefaults.standard.dictionary(forKey: key) as? [String: Double]) ?? [:]
        d[path] = Date().timeIntervalSince1970
        if d.count > cap {
            for k in d.sorted(by: { $0.value < $1.value }).prefix(d.count - cap).map(\.key) { d.removeValue(forKey: k) }
        }
        UserDefaults.standard.set(d, forKey: key)
    }
}
