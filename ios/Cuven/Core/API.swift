import Foundation

enum APIError: LocalizedError {
    case http(Int, String?)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .http(let code, let msg): return msg ?? "服务器返回 \(code)"
        case .badResponse: return "服务器回包无法识别"
        }
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
    func url(_ path: String, _ query: [(String, String)] = []) -> URL {
        var comps = URLComponents(string: Self.base + path)!
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

    func get<T: Decodable>(_ path: String, _ query: [(String, String)] = [], timeout: TimeInterval = 25, fresh: Bool = false) async throws -> T {
        var req = URLRequest(url: url(path, query), timeoutInterval: timeout)
        if fresh { req.cachePolicy = .reloadIgnoringLocalCacheData }
        let (data, resp) = try await session.data(for: req)
        try check(resp, data)
        return try decoder.decode(T.self, from: data)
    }

    func post<T: Decodable>(_ path: String, json: [String: Any], timeout: TimeInterval = 40) async throws -> T {
        var req = URLRequest(url: url(path), timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: json)
        let (data, resp) = try await session.data(for: req)
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

    func tvList() async throws -> [Series] {
        let p: TVPayload = try await get("/api/tv", timeout: 30)
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
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode == 404 || http.statusCode == 405 {
            throw AtvArtUnavailable()
        }
        try check(resp, data)
        guard let r = try? decoder.decode(AtvArtResponse.self, from: data) else { throw AtvArtUnavailable() }
        return r
    }

    // MARK: 在线字幕

    private struct SubsWarm: Decodable {}

    /// 详情页一打开就让后台先去找这部片的在线字幕（warm=1：后端立刻回，不等结果）。
    /// 每部片都会有一条在线字幕备选；片子自带中文字幕时仍默认用自带的。播放时 HLS 主列表里就有它，不必等
    func warmSubs(path: String) async {
        let _: SubsWarm? = try? await get("/api/subs", [("path", path), ("warm", "1")], timeout: 15, fresh: true)
    }

    // MARK: 播放

    func streamSign(path: String) async throws -> StreamSign {
        try await get("/api/stream-sign", [("path", path)], timeout: 12, fresh: true)
    }

    /// HLS 的 info.json：200 且 ok → 能放；4xx（404 除外）→ 这个文件转不了，带着原因；404 / 网络错 → 退回直链
    func hlsInfo(_ url: URL) async -> (status: Int, info: HLSInfo?) {
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, resp) = try? await session.data(for: req), let http = resp as? HTTPURLResponse else { return (0, nil) }
        return (http.statusCode, try? decoder.decode(HLSInfo.self, from: data))
    }

    /// 直链：文件名只是装饰，后端只认 ?path=。MP4 / MOV 带 safari=1（后端的 FourCC 热修补）
    func streamURL(path: String, name: String, sign: StreamSign?) -> URL {
        let ext = (name as NSString).pathExtension.lowercased()
        var q: [(String, String)] = [("path", path)]
        if let exp = sign?.exp, let sig = sign?.sig, !exp.isEmpty, !sig.isEmpty { q += [("exp", exp), ("sig", sig)] }
        if ["mp4", "m4v", "mov"].contains(ext) { q.append(("safari", "1")) }
        let file = "Cuven." + (ext.isEmpty ? "mp4" : ext)
        return url("/stream/" + file, q)
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
