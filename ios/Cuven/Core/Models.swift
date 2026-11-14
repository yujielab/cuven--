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
    /// 根目录下一级的文件夹（网页版首页最后那排「文件夹」）
    var folders: [LibraryFolder]

    enum CodingKeys: String, CodingKey { case root, videos, folders }

    init(root: String?, videos: [Video], folders: [LibraryFolder] = []) { self.root = root; self.videos = videos; self.folders = folders }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        root = c.str(.root)
        videos = ((try? c.decode([Video].self, forKey: .videos)) ?? []).filter { !$0.path.isEmpty }
        folders = ((try? c.decode([LibraryFolder].self, forKey: .folders)) ?? []).filter { !$0.path.isEmpty }
    }
}

/// 片库里的一个文件夹（/api/all 的 folders、/api/list 里 type 为 folder 的那几项）
struct LibraryFolder: Codable, Hashable, Identifiable, Sendable {
    var name: String
    var path: String
    var id: String { path }

    enum CodingKeys: String, CodingKey { case name, path }

    init(name: String, path: String) { self.name = name; self.path = path }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = c.str(.path) ?? ""
        name = c.str(.name) ?? (path as NSString).lastPathComponent
    }
}

/// /api/list?path=… 的回包：{ folder, items: [{ name, path, type: "folder" | "file", size, modified, added }] }
struct FolderListing: Decodable, Sendable {
    var items: [Item]

    struct Item: Decodable, Sendable {
        var name: String
        var path: String
        var type: String?
        var size: Int64?
        var modified: String?
        var added: String?

        enum CodingKeys: String, CodingKey { case name, path, type, size, modified, added }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            path = c.str(.path) ?? ""
            name = c.str(.name) ?? (path as NSString).lastPathComponent
            type = c.str(.type)
            size = c.int64(.size)
            modified = c.str(.modified)
            added = c.str(.added)
        }
    }

    enum CodingKeys: String, CodingKey { case items }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = ((try? c.decode([Item].self, forKey: .items)) ?? []).filter { !$0.path.isEmpty }
    }
}

// MARK: - TMDB 元数据（/api/tmdb、/api/tmdb-batch）

struct CastMember: Codable, Hashable, Sendable {
    var id: Int?
    var name: String
    var character: String?
    var profilePath: String?

    enum CodingKeys: String, CodingKey { case id, name, character, profilePath = "profile_path" }

    init(id: Int? = nil, name: String, character: String? = nil, profilePath: String? = nil) {
        self.id = id; self.name = name; self.character = character; self.profilePath = profilePath
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.int(.id)
        name = c.str(.name) ?? ""
        character = c.str(.character)
        profilePath = c.str(.profilePath)
    }

    var profileURL: URL? {
        guard let p = profilePath, !p.isEmpty else { return nil }
        return URL(string: p.hasPrefix("http") || p.hasPrefix("demo:") ? p : "https://image.tmdb.org/t/p/w185" + p)
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
    /// TMDB 上没有字的那张横版剧照（iso_639_1 为空的 backdrop；只在全量结果里，首页头图横拿时兜底用）
    var backdropClean: String?
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
        case id, title, en, year, poster, posterClean, backdrop, backdropClean, logo, logoChecked, overview, rating, type, runtime, genres, cast, director, stills
        case originalTitle = "original_title"
        case releaseDate = "release_date"
    }

    init(id: Int? = nil, title: String? = nil, en: String? = nil, year: String? = nil, poster: String? = nil, posterClean: String? = nil,
         backdrop: String? = nil, logo: String? = nil, overview: String? = nil, rating: Double? = nil, type: String? = nil,
         runtime: Int? = nil, genres: [String]? = nil, stills: [Still]? = nil) {
        self.id = id; self.title = title; self.en = en; self.year = year; self.poster = poster; self.posterClean = posterClean
        self.backdrop = backdrop; self.logo = logo; self.logoChecked = true; self.overview = overview; self.rating = rating
        self.type = type; self.runtime = runtime; self.genres = genres; self.stills = stills
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
        backdropClean = c.str(.backdropClean)
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
    /// 目录名里读出来的音轨语种（「国语」「英语」）与音频格式（Atmos / TrueHD …）：详情页「语言」那一块用
    var langs: [String]?
    var audio: String?
    var full: Bool?
    var complete: Bool?
    var tmdbId: Int?
    var tmdbMiss: Bool?
    var episodes: Int?
    var total: Int?
    var size: Int64?
    var added: String?

    enum CodingKeys: String, CodingKey {
        case id, path, folder, title, zh, en, season, seasonLabel, year, res, hdr, tags, langs, audio, full, complete, tmdbId, tmdbMiss, episodes, total, size, added
    }

    init(id: String, path: String, title: String, en: String?, season: Int, year: String, episodes: Int, full: Bool, tags: [String] = [], added: String) {
        self.id = id; self.path = path; self.title = title; self.zh = title; self.en = en; self.season = season
        self.seasonLabel = "第 \(season) 季"; self.year = year; self.episodes = episodes; self.full = full; self.complete = full
        self.tags = tags; self.added = added; self.total = full ? episodes : episodes + 4
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
        langs = try? c.decodeIfPresent([String].self, forKey: .langs)
        audio = c.str(.audio)
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
    init(ep: Int?, path: String, name: String, size: Int64? = nil) { self.ep = ep; self.path = path; self.name = name; self.size = size }
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
    init(ep: Int?, name: String?, overview: String?, still: String?, runtime: Int?) {
        self.ep = ep; self.name = name; self.overview = overview; self.still = still; self.runtime = runtime; self.airDate = nil
    }
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

/// 头图里的一部（首页最上面那张轮播）：无字的横图和字标两样都要有才上；竖版无字图可能没有（竖着的屏就把横图居中裁）
struct HeroPick: Identifiable, Hashable {
    let video: Video
    var hero: Hero?
    let wide: String
    var tall: String?
    let logo: String
    var id: String { video.path }
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
    init(path: String, name: String? = nil, title: String? = nil, year: Int? = nil, background: String?, poster: String?, logo: String? = nil) {
        self.path = path; self.name = name; self.title = title; self.type = "Movie"; self.year = year
        self.background = background; self.poster = poster; self.logo = logo
    }
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
    /// 网页版的文件夹页（首页最后那排「文件夹」点进去）
    case folder(LibraryFolder)
    case movie(Video)
    case series(Series)
    case year(Int)
    case shelf(Shelf)
}

/// Apple TV 上这部片的预告片（/api/atv/lookup?video=1，HLS，系统播放器直接能放）
/// /api/atv/lookup 的回包：Apple TV 上的那一部（预告片 + 官方素材）。图都是 Apple 图床（mzstatic）现成的地址
struct AtvLookup: Decodable, Sendable {
    var title: String?
    var year: Int?
    var type: String?
    var trailers: [Trailer]?
    /// 16:9 带片名排版的成品图（搜索层的 shelfImage；id 直查时是 posterArt）
    var image: String?
    /// 16:9 无字的干净背景（只有按片名搜才有）
    var background: String?
    /// 4:3 内容图
    var image43: String?
    /// 竖版全屏图（TV app 手机端 hero 用的那张，约 0.46 宽高比）
    var imageTall: String?
    /// 片名字标（PNG）
    var logo: String?
}

struct Trailer: Decodable, Hashable, Identifiable, Sendable {
    var title: String?
    var hls: String
    /// 时长（秒）和这一段自己的画面：Apple 给了才有（Worker 原样带过来）
    var duration: Double? = nil
    var image: String? = nil
    var id: String { hls }
}

// MARK: - 全片库的 Apple TV 素材（POST /api/atv/art）
//
// 电影的画面一律 Apple TV 优先、TMDB 兜底（片名、简介、类型这些字仍是 TMDB 的中文）。
// 后端按英文名 + 年份在 Apple TV 上对片（片名对得上、年份差一年以内才算），成品存在 R2，一次回一批。

/// 一部电影在 Apple TV 上的素材：都是 Apple 图床（mzstatic）现成的地址，没有的项是 nil
struct AtvArt: Codable, Hashable, Sendable {
    var id: String?
    var title: String?
    var year: Int?
    /// 2:3 带片名的海报（Apple 有才有），pw 宽
    var poster: String?
    /// 竖版无字主视觉（宽高比约 0.46），pw 宽：放进 2:3 的卡里居中裁，再压上字标
    var tall: String?
    /// 16:9 带片名排版的成品图，w 宽
    var wide: String?
    /// 16:9 无字背景，w 宽
    var background: String?
    /// 片名字标（PNG，1000 宽）
    var logo: String?

    enum CodingKeys: String, CodingKey { case id, title, year, poster, tall, wide, background, logo }

    init(id: String? = nil, title: String? = nil, year: Int? = nil, poster: String? = nil, tall: String? = nil,
         wide: String? = nil, background: String? = nil, logo: String? = nil) {
        self.id = id; self.title = title; self.year = year; self.poster = poster; self.tall = tall
        self.wide = wide; self.background = background; self.logo = logo
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.str(.id)
        title = c.str(.title)
        year = c.int(.year)
        poster = c.str(.poster)
        tall = c.str(.tall)
        wide = c.str(.wide)
        background = c.str(.background)
        logo = c.str(.logo)
    }
}

/// 回包：items 是对上的；pending 是这一轮还没来得及问（后端每次有预算），过一秒再问；两边都没有的键 = Apple TV 上没有
struct AtvArtResponse: Decodable, Sendable {
    var items: [String: AtvArt]
    var pending: [String]

    enum CodingKeys: String, CodingKey { case items, pending }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // 值写成 null 的键也当「没有」
        let raw = (try? c.decode([String: AtvArt?].self, forKey: .items)) ?? [:]
        items = raw.compactMapValues { $0 }
        pending = (try? c.decode([String].self, forKey: .pending)) ?? []
    }
}

/// 问一部：k 是客户端自己的键（同一部片的各个版本共用），t 是拉丁字母的片名（最好的在前，最多三个），y 是年份
struct AtvArtQuery: Encodable, Hashable, Sendable {
    var k: String
    var t: [String]
    var y: Int?
}

/// 整页清单：首页分区标题「›」进去的，和搜索页「浏览」里的某一类
enum Shelf: Hashable {
    case newest, picks, series, watchlist, continueWatching
    case genre(String)
    /// 主页的五个大类之一（引人入胜的剧情……）：电影和剧集都在里面
    case category(HomeCategory)

    var title: String {
        switch self {
        case .newest: return "最新加入"
        case .picks: return "今日推荐"
        case .series: return "Cuven TV · 剧集"
        case .watchlist: return "想看"
        case .continueWatching: return "继续观看"
        case .genre(let g): return g
        case .category(let c): return c.title
        }
    }

    /// 缩放转场的来源标记（同一部片出现在不同清单里，各算各的）
    var key: String {
        switch self {
        case .newest: return "newest"
        case .picks: return "picks"
        case .series: return "series"
        case .watchlist: return "watchlist"
        case .continueWatching: return "continue"
        case .genre(let g): return "genre-" + g
        case .category(let c): return "cat-" + c.rawValue
        }
    }
}

/// 主页一排里的一项：电影或剧集（今年、去年那两排，和五个大类，两样都有）
enum HomeEntry: Identifiable, Hashable {
    case movie(Video)
    case series(Series)

    var id: String {
        switch self {
        case .movie(let v): return "m:" + v.path
        case .series(let s): return "s:" + s.path
        }
    }
}

/// 主页的五个大类（Apple TV 那种主题货架）：标题，和它认的 TMDB 类型名。
/// 电影和剧集的类型名写法不一样（剧集是「科幻奇幻」「动作冒险」这种合写的，有时还是英文），按「含这几个字」认
enum HomeCategory: String, CaseIterable, Identifiable, Hashable, Sendable {
    case drama, tense, fantasy, action, crime

    var id: String { rawValue }

    var title: String {
        switch self {
        case .drama: return "引人入胜的剧情"
        case .tense: return "令人坐立难安"
        case .fantasy: return "科幻和奇幻之旅"
        case .action: return "动作演员就位"
        case .crime: return "刺激犯罪与偷窃"
        }
    }

    var keywords: [String] {
        switch self {
        case .drama: return ["剧情", "Drama"]
        case .tense: return ["惊悚", "悬疑", "恐怖", "Thriller", "Mystery", "Horror"]
        case .fantasy: return ["科幻", "奇幻", "Sci-Fi", "Science Fiction", "Fantasy"]
        case .action: return ["动作", "Action"]
        case .crime: return ["犯罪", "Crime"]
        }
    }

    func matches(_ genres: [String]?) -> Bool {
        guard let genres, !genres.isEmpty else { return false }
        return genres.contains { g in keywords.contains { g.localizedCaseInsensitiveContains($0) } }
    }
}
