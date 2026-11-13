import Foundation

// 后端（Stream Worker，https://stream.cuven.online）回包的形状。
// 字段一律宽松解：后端多一个字段、某个字段换了类型，都不该让整份片库解不出来。

// MARK: - 宽松解码

struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int?
    init(stringValue: String) { self.stringValue = stringValue; self.intValue = nil }
    init?(intValue: Int) { self.stringValue = String(intValue); self.intValue = intValue }
}

extension KeyedDecodingContainer {
    func str(_ key: Key) -> String? {
        if let s = try? decodeIfPresent(String.self, forKey: key) { return s }
        if let i = try? decodeIfPresent(Int.self, forKey: key) { return String(i) }
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return String(d) }
        return nil
    }
    func int(_ key: Key) -> Int? {
        if let i = try? decodeIfPresent(Int.self, forKey: key) { return i }
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return Int(d) }
        if let s = try? decodeIfPresent(String.self, forKey: key) { return Int(s) }
        return nil
    }
    func int64(_ key: Key) -> Int64? {
        if let i = try? decodeIfPresent(Int64.self, forKey: key) { return i }
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return Int64(d) }
        return nil
    }
    func double(_ key: Key) -> Double? {
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return d }
        if let s = try? decodeIfPresent(String.self, forKey: key) { return Double(s) }
        return nil
    }
    func bool(_ key: Key) -> Bool? {
        if let b = try? decodeIfPresent(Bool.self, forKey: key) { return b }
        if let i = try? decodeIfPresent(Int.self, forKey: key) { return i != 0 }
        return nil
    }
}

// MARK: - 片库（/api/all）

struct Video: Codable, Hashable, Identifiable, Sendable {
    var name: String
    var path: String
    var size: Int64?
    var modified: String?
    var added: String?
    var id: String { path }

    enum CodingKeys: String, CodingKey { case name, path, size, modified, added }

    init(name: String, path: String, size: Int64? = nil, modified: String? = nil, added: String? = nil) {
        self.name = name; self.path = path; self.size = size; self.modified = modified; self.added = added
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = c.str(.path) ?? ""
        name = c.str(.name) ?? (path as NSString).lastPathComponent
        size = c.int64(.size)
        modified = c.str(.modified)
        added = c.str(.added)
    }

    /// 入库时间（排序用）：没有 added 就退到 modified
    var addedKey: String { added ?? modified ?? "" }
}

struct LibraryPayload: Codable, Sendable {
    var root: String?
    var videos: [Video]

    enum CodingKeys: String, CodingKey { case root, videos }

    init(root: String?, videos: [Video]) { self.root = root; self.videos = videos }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        root = c.str(.root)
        videos = ((try? c.decode([Video].self, forKey: .videos)) ?? []).filter { !$0.path.isEmpty }
    }
}

// MARK: - TMDB 元数据（/api/tmdb、/api/tmdb-batch）

struct CastMember: Codable, Hashable, Sendable {
    var id: Int?
    var name: String
    var character: String?
    var profilePath: String?

    enum CodingKeys: String, CodingKey { case id, name, character, profilePath = "profile_path" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.int(.id)
        name = c.str(.name) ?? ""
        character = c.str(.character)
        profilePath = c.str(.profilePath)
    }

    var profileURL: URL? {
        guard let p = profilePath, !p.isEmpty else { return nil }
        return URL(string: p.hasPrefix("http") ? p : "https://image.tmdb.org/t/p/w185" + p)
    }
}

struct Still: Codable, Hashable, Sendable {
    var url: String?
    var thumb: String?
}

struct Meta: Codable, Hashable, Sendable {
    var id: Int?
    var title: String?
    var en: String?
    var originalTitle: String?
    var year: String?
    var releaseDate: String?
    var poster: String?
    var posterClean: String?
    var backdrop: String?
    var logo: String?
    var logoChecked: Bool?
    var overview: String?
    var rating: Double?
    var type: String?
    var runtime: Int?
    var genres: [String]?
    var cast: [CastMember]?
    var director: String?
    var stills: [Still]?

    enum CodingKeys: String, CodingKey {
        case id, title, en, year, poster, posterClean, backdrop, logo, logoChecked, overview, rating, type, runtime, genres, cast, director, stills
        case originalTitle = "original_title"
        case releaseDate = "release_date"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.int(.id)
        title = c.str(.title)
        en = c.str(.en)
        originalTitle = c.str(.originalTitle)
        year = c.str(.year)
        releaseDate = c.str(.releaseDate)
        poster = c.str(.poster)
        posterClean = c.str(.posterClean)
        backdrop = c.str(.backdrop)
        logo = c.str(.logo)
        logoChecked = c.bool(.logoChecked)
        overview = c.str(.overview)
        rating = c.double(.rating)
        type = c.str(.type)
        runtime = c.int(.runtime)
        genres = try? c.decodeIfPresent([String].self, forKey: .genres)
        cast = try? c.decodeIfPresent([CastMember].self, forKey: .cast)
        director = c.str(.director)
        stills = try? c.decodeIfPresent([Still].self, forKey: .stills)
    }

    /// 有没有封面：海报或纯净海报，至少一张
    var hasArt: Bool { !(poster ?? "").isEmpty || !(posterClean ?? "").isEmpty }
}

// MARK: - 剧集（/api/tv、/api/tv/episodes、/api/tmdb/season）

struct Series: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var path: String
    var folder: String?
    var title: String?
    var zh: String?
    var en: String?
    var season: Int?
    var seasonLabel: String?
    var year: String?
    var res: String?
    var hdr: String?
    var tags: [String]?
    var full: Bool?
    var complete: Bool?
    var tmdbId: Int?
    var tmdbMiss: Bool?
    var episodes: Int?
    var total: Int?
    var size: Int64?
    var added: String?

    enum CodingKeys: String, CodingKey {
        case id, path, folder, title, zh, en, season, seasonLabel, year, res, hdr, tags, full, complete, tmdbId, tmdbMiss, episodes, total, size, added
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = c.str(.path) ?? ""
        id = c.str(.id) ?? path
        folder = c.str(.folder)
        title = c.str(.title)
        zh = c.str(.zh)
        en = c.str(.en)
        season = c.int(.season)
        seasonLabel = c.str(.seasonLabel)
        year = c.str(.year)
        res = c.str(.res)
        hdr = c.str(.hdr)
        tags = try? c.decodeIfPresent([String].self, forKey: .tags)
        full = c.bool(.full)
        complete = c.bool(.complete)
        tmdbId = c.int(.tmdbId)
        tmdbMiss = c.bool(.tmdbMiss)
        episodes = c.int(.episodes)
        total = c.int(.total)
        size = c.int64(.size)
        added = c.str(.added)
    }

    var name: String { title ?? zh ?? en ?? folder ?? "剧集" }
    /// 「全 8 集」/「更新至第 5 集 / 共 10 集」
    var countLabel: String {
        let n = episodes ?? 0
        if full == true || complete == true { return "全 \(n) 集" }
        if let t = total, t > n { return "更新至第 \(n) 集 / 共 \(t) 集" }
        return "更新至第 \(n) 集"
    }
}

struct TVPayload: Codable, Sendable {
    var series: [Series]
    enum CodingKeys: String, CodingKey { case series }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        series = ((try? c.decode([Series].self, forKey: .series)) ?? []).filter { !$0.path.isEmpty }
    }
}

struct EpisodeFile: Codable, Hashable, Identifiable, Sendable {
    var ep: Int?
    var path: String
    var name: String
    var size: Int64?
    var id: String { path }

    enum CodingKeys: String, CodingKey { case ep, path, name, size }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ep = c.int(.ep)
        path = c.str(.path) ?? ""
        name = c.str(.name) ?? (path as NSString).lastPathComponent
        size = c.int64(.size)
    }
}

struct EpisodesPayload: Codable, Sendable {
    var episodes: [EpisodeFile]
    enum CodingKeys: String, CodingKey { case episodes }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        episodes = ((try? c.decode([EpisodeFile].self, forKey: .episodes)) ?? []).filter { !$0.path.isEmpty }
    }
}

struct SeasonEpisode: Codable, Hashable, Sendable {
    var ep: Int?
    var name: String?
    var overview: String?
    var still: String?
    var runtime: Int?
    var airDate: String?

    enum CodingKeys: String, CodingKey { case ep, name, overview, still, runtime, airDate = "air_date" }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ep = c.int(.ep)
        name = c.str(.name)
        overview = c.str(.overview)
        still = c.str(.still)
        runtime = c.int(.runtime)
        airDate = c.str(.airDate)
    }
}

struct SeasonPayload: Codable, Sendable {
    var episodes: [SeasonEpisode]
    enum CodingKeys: String, CodingKey { case episodes }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        episodes = (try? c.decode([SeasonEpisode].self, forKey: .episodes)) ?? []
    }
}

// MARK: - 首页大图（/api/atv/hero：Apple TV 商店最新发行里、库里有的那些）

struct Hero: Codable, Hashable, Identifiable, Sendable {
    var path: String
    var name: String?
    var title: String?
    var type: String?
    var year: Int?
    var background: String?
    var poster: String?
    var logo: String?
    var id: String { path }

    enum CodingKeys: String, CodingKey { case path, name, title, type, year, background, poster, logo }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = c.str(.path) ?? ""
        name = c.str(.name)
        title = c.str(.title)
        type = c.str(.type)
        year = c.int(.year)
        background = c.str(.background)
        poster = c.str(.poster)
        logo = c.str(.logo)
    }
}

struct HeroPayload: Codable, Sendable {
    var heroes: [Hero]
    enum CodingKeys: String, CodingKey { case heroes }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        heroes = ((try? c.decode([Hero].self, forKey: .heroes)) ?? []).filter { !$0.path.isEmpty }
    }
}

// MARK: - 播放（/api/stream-sign 与 HLS 的 info.json）

struct StreamSign: Codable, Sendable {
    var exp: String?
    var sig: String?
    var hls: String?

    enum CodingKeys: String, CodingKey { case exp, sig, hls }
    init(exp: String? = nil, sig: String? = nil, hls: String? = nil) { self.exp = exp; self.sig = sig; self.hls = hls }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        exp = c.str(.exp)
        sig = c.str(.sig)
        hls = c.str(.hls)
    }
}

struct HLSInfo: Codable, Sendable {
    var ok: Bool?
    var error: String?
    enum CodingKeys: String, CodingKey { case ok, error }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = c.bool(.ok)
        error = c.str(.error)
    }
}

// MARK: - 导航

enum Route: Hashable {
    case movie(Video)
    case series(Series)
    case year(Int)
}
