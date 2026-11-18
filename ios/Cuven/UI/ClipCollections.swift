import SwiftUI
import AVFoundation

// MARK: - 主页「探索片段合集」与刷视频式的影片浏览
//
// 用户要求：「更新 2026 年（年份下）的主页显示，参考设计图，分类为电视剧、动漫、电影、纪录片、迪士尼、漫威、DC，
// 打开后显示为图 3 4 5 的类似刷视频逻辑的影片浏览新界面」。参考图是 Apple TV App 的「Explore Clip Collections」：
// · 主页 2026 那一排下面一排 9 : 16 的竖卡：整幅画面、下段压暗，左下大号粗体的分类名；在排里不放大、不压暗；
// · 点开（从卡上放大出来）：一部一屏，上下滑换一部（分页对齐，像刷短视频）。每一屏是一张大圆角卡：
//   后面是这一部的预告片（静音、从第 10 秒起、循环；起来之前是竖版主视觉），顶上不写分类名（用户要求移除），
//   底下字标（HDR）、一行「电影 · 2026 · 科幻」、「加入想看」玻璃胶囊和 ⓘ（推进详情页），最底下一条预告片进度；
//   轻点画面暂停 / 接着放；右边（iPhone Duo 折起是侧边那一列，对着状态栏的中线）关闭、分享，下面一串竖着的页码点。
// 分类：电视剧 = 全部剧集；动漫 = TMDB「动画」；电影 = 全部电影；纪录片 = TMDB「纪录」；
// 迪士尼 / 漫威 / DC = 按片名认（ClipFranchise：Worker 给的 TMDB 资料里没有出品公司）。
// 每个合集里查到有预告片的在前（刷起来都是会动的），再按上映年份新的在前、同一年按入库时间；最多 80 部。

/// 七个片段合集
enum ClipCollection: String, CaseIterable, Identifiable, Hashable, Sendable {
    case series, anime, movies, documentary, disney, marvel, dc

    var id: String { rawValue }

    var title: String {
        switch self {
        case .series: return "电视剧"
        case .anime: return "动漫"
        case .movies: return "电影"
        case .documentary: return "纪录片"
        case .disney: return "迪士尼"
        case .marvel: return "漫威"
        case .dc: return "DC"
        }
    }

    /// 一个合集里最多放几部
    static let limit = 80

    /// 这一部算不算这个合集（genres：TMDB 类型名；names：英文名、原名、中文名、目录名）
    @MainActor
    func matches(genres: [String]?, names: [String?]) -> Bool {
        switch self {
        case .series, .movies:
            return true
        case .anime:
            return HomeCategory.animation.matches(genres)
        case .documentary:
            return (genres ?? []).contains { $0.contains("纪录") || $0.localizedCaseInsensitiveContains("Documentary") }
        case .disney, .marvel, .dc:
            return ClipFranchise.tags(names).contains(self)
        }
    }

    /// 这个合集里有哪几部：上映年份新的在前、同一年按入库时间（AppModel.clipEntries 按片库版本缓存它）
    @MainActor
    static func members(_ c: ClipCollection, model: AppModel, movies: [Video]) -> [HomeEntry] {
        var rows: [(entry: HomeEntry, year: Int, key: String)] = []
        if c != .series {
            for v in movies {
                let m = model.meta(v)
                var names: [String?] = [m?.en, m?.originalTitle, m?.title]
                if m?.en == nil { names.append(FileName.title(v.name)) }
                guard c.matches(genres: m?.genres, names: names) else { continue }
                rows.append((.movie(v), model.year(v) ?? 0, v.addedKey))
            }
        }
        if c != .movies {
            for s in model.series where model.seriesCardReady(s) {
                let m = model.seriesMetas[s.path]
                var names: [String?] = [s.en, m?.en, m?.originalTitle, s.zh, m?.title, s.title]
                if s.en == nil && m?.en == nil { names.append(s.folder) }
                guard c.matches(genres: m?.genres, names: names) else { continue }
                rows.append((.series(s), Int(s.year ?? "") ?? 0, s.added ?? ""))
            }
        }
        rows.sort { a, b in a.year != b.year ? a.year > b.year : a.key > b.key }
        return rows.map(\.entry)
    }

    /// 刷起来都是会动的：查到有预告片的电影在前，还不知道的（剧集都算这一档）其次，查过没有的最后；每一档里照原来的顺序
    @MainActor
    static func ordered(_ members: [HomeEntry], model: AppModel) -> [HomeEntry] {
        var first: [HomeEntry] = [], middle: [HomeEntry] = [], last: [HomeEntry] = []
        for e in members {
            switch e {
            case .movie(let v):
                switch model.trailerKnown[v.path] {
                case true?: first.append(e)
                case false?: last.append(e)
                case nil: middle.append(e)
                }
            case .series:
                middle.append(e)
            }
            if first.count >= limit { break }
        }
        return Array((first + middle + last).prefix(limit))
    }
}

// MARK: - 迪士尼 / 漫威 / DC：按片名认

/// Worker 给的 TMDB 资料里没有出品公司，按片名认：英文名、原名、中文名、目录名对一份系列名单。
/// 英文按整词比：片名拆成词，连着的一到五个词拼成短语去查表（「thor」不会认到「thorough」，「x men」认得出「X-Men」）；
/// 很短、容易撞名的（Up、Cars、Coco、Arrow…）要整个片名就是它（后面可以跟续集数字）。
/// 中文按「片名里有这几个字」；「超人」「小丑」「鹰眼」这种会撞到别的片名的，要整个片名就是它（或者后面跟「：」副标题）——
/// 「超人总动员」是皮克斯的。一部片的名字认过一次就记住（按名字记），片库刷新时不再从头认
enum ClipFranchise {
    private static let marvelWords = [
        "marvel", "avengers", "iron man", "captain america", "thor", "hulk", "she hulk", "black widow",
        "black panther", "spider man", "spiderman", "spider verse", "doctor strange", "ant man",
        "guardians of the galaxy", "captain marvel", "the marvels", "eternals", "shang chi", "thunderbolts",
        "fantastic four", "deadpool", "wolverine", "x men", "venom", "morbius", "madame web", "kraven",
        "moon knight", "loki", "wandavision", "hawkeye", "ms marvel", "secret invasion", "daredevil",
        "ironheart", "agatha all along", "punisher", "jessica jones", "luke cage", "iron fist", "the defenders",
        "new mutants", "ghost rider", "elektra", "werewolf by night", "wonder man", "inhumans"]
    private static let marvelExact = ["logan", "blade", "blade ii", "blade trinity", "echo"]
    private static let marvelHan = [
        "漫威", "复仇者", "钢铁侠", "美国队长", "雷神", "绿巨人", "女浩克", "黑寡妇", "黑豹", "蜘蛛侠", "奇异博士",
        "蚁人", "银河护卫队", "惊奇队长", "惊奇少女", "永恒族", "尚气", "雷霆特攻队", "神奇四侠", "死侍", "金刚狼",
        "X战警", "毒液", "莫比亚斯", "蜘蛛夫人", "猎人克莱文", "月光骑士", "洛基", "旺达幻视", "秘密入侵", "夜魔侠",
        "钢铁之心", "惩罚者", "神盾局特工", "猎鹰与冬兵", "恶灵骑士", "刀锋战士"]
    private static let marvelHanExact = ["鹰眼"]

    private static let dcWords = [
        "batman", "superman", "supergirl", "wonder woman", "aquaman", "justice league", "the flash", "shazam",
        "black adam", "blue beetle", "suicide squad", "peacemaker", "the penguin", "green lantern",
        "creature commandos", "harley quinn", "birds of prey", "man of steel", "watchmen", "constantine",
        "doom patrol", "joker", "catwoman", "batgirl", "batwoman", "gotham", "smallville", "stargirl",
        "black lightning", "legends of tomorrow", "sandman", "dead boy detectives", "swamp thing", "clayface",
        "super pets", "teen titans", "lucifer"]
    private static let dcExact = ["arrow", "titans", "krypton", "lanterns"]
    private static let dcHan = [
        "蝙蝠侠", "神奇女侠", "海王", "正义联盟", "闪电侠", "沙赞", "黑亚当", "蓝甲虫", "自杀小队", "X特遣队",
        "和平使者", "企鹅人", "绿灯侠", "小丑女", "哈莉·奎茵", "哈莉奎茵", "猛禽小队", "守望者", "康斯坦丁",
        "毁灭巡逻队", "绿箭侠", "哥谭", "猫女", "蝙蝠女侠", "女超人", "超人前传", "超人和露易斯", "超级宠物"]
    private static let dcHanExact = ["超人", "小丑"]

    private static let disneyWords = [
        "disney", "pixar", "toy story", "inside out", "finding nemo", "finding dory", "monsters inc",
        "monsters university", "incredibles", "ratatouille", "wall e", "a bug s life", "the good dinosaur",
        "turning red", "elemental", "lightyear", "hoppers", "frozen", "moana", "zootopia", "encanto",
        "raya and the last dragon", "tangled", "big hero 6", "wreck it ralph", "ralph breaks the internet",
        "strange world", "lilo stitch", "the lion king", "mufasa", "aladdin", "beauty and the beast", "mulan",
        "cinderella", "the little mermaid", "sleeping beauty", "pinocchio", "peter pan", "bambi", "dumbo",
        "the jungle book", "pocahontas", "the princess and the frog", "maleficent", "cruella", "mary poppins",
        "pirates of the caribbean", "tron", "the nightmare before christmas", "winnie the pooh", "fantasia",
        "enchanted", "the aristocats", "101 dalmatians", "lady and the tramp", "the emperor s new groove",
        "treasure planet", "meet the robinsons", "chicken little"]
    private static let disneyExact = ["up", "cars", "coco", "soul", "luca", "onward", "brave", "elio", "wish", "bolt",
                                      "planes", "hercules", "tarzan", "snow white", "snow white and the seven dwarfs"]
    private static let disneyHan = [
        "迪士尼", "皮克斯", "玩具总动员", "头脑特工队", "海底总动员", "多莉去哪儿", "怪兽电力公司", "怪兽大学",
        "超人总动员", "超人特工队", "美食总动员", "机器人总动员", "赛车总动员", "飞屋环游记", "勇敢传说",
        "寻梦环游记", "心灵奇旅", "夏日友晴天", "二分之一的魔法", "1/2的魔法", "青春变形记", "疯狂元素城",
        "光年正传", "冰雪奇缘", "海洋奇缘", "疯狂动物城", "魔法满屋", "寻龙传说", "魔发奇缘", "长发公主",
        "超能陆战队", "无敌破坏王", "奇异世界", "星际宝贝", "狮子王", "木法沙", "阿拉丁", "美女与野兽", "花木兰",
        "灰姑娘", "小美人鱼", "白雪公主", "睡美人", "木偶奇遇记", "小飞侠", "小鹿斑比", "小飞象", "森林王子",
        "风中奇缘", "人猿泰山", "公主与青蛙", "闪电狗", "沉睡魔咒", "黑白魔女库伊拉", "欢乐满人间", "加勒比海盗",
        "创：战纪", "创：战神", "圣诞夜惊魂", "小熊维尼", "幻想曲", "艾利欧", "星愿"]

    /// 英文短语（一到五个词）→ 哪个合集
    private static let phrases: [String: ClipCollection] = {
        var d: [String: ClipCollection] = [:]
        for w in marvelWords { d[w] = .marvel }
        for w in dcWords { d[w] = .dc }
        for w in disneyWords { d[w] = .disney }
        return d
    }()
    /// 英文：整个片名（去掉结尾的续集数字）→ 哪个合集
    private static let exactTitles: [String: ClipCollection] = {
        var d: [String: ClipCollection] = [:]
        for w in marvelExact { d[w] = .marvel }
        for w in dcExact { d[w] = .dc }
        for w in disneyExact { d[w] = .disney }
        return d
    }()
    private static let hanKeys: [(String, ClipCollection)] = {
        var out: [(String, ClipCollection)] = []
        for k in marvelHan { out.append((k, ClipCollection.marvel)) }
        for k in dcHan { out.append((k, ClipCollection.dc)) }
        for k in disneyHan { out.append((k, ClipCollection.disney)) }
        return out
    }()
    private static let hanExactKeys: [(String, ClipCollection)] = {
        var out: [(String, ClipCollection)] = []
        for k in marvelHanExact { out.append((k, ClipCollection.marvel)) }
        for k in dcHanExact { out.append((k, ClipCollection.dc)) }
        return out
    }()
    private static let maxWords = 5

    /// 认过的（按名字记）
    @MainActor private static var memo: [String: Set<ClipCollection>] = [:]

    /// 这一组名字属于哪几个系列合集（迪士尼 / 漫威 / DC，可能一个都不是）
    @MainActor
    static func tags(_ names: [String?]) -> Set<ClipCollection> {
        var seen = Set<String>()
        let list = names.compactMap { $0 }.filter { !$0.isEmpty && seen.insert($0).inserted }
        guard !list.isEmpty else { return [] }
        let sig = list.joined(separator: "\u{1F}")
        if let hit = memo[sig] { return hit }
        let out = classify(list)
        memo[sig] = out
        return out
    }

    static func classify(_ names: [String]) -> Set<ClipCollection> {
        var out = Set<ClipCollection>()
        for raw in names {
            let words = tokens(raw)
            if !words.isEmpty {
                // 整个片名（去掉结尾的续集数字：「cars 2」→「cars」）
                var core = words
                while core.count > 1, let last = core.last, last.allSatisfy(\.isNumber) { core.removeLast() }
                if let c = exactTitles[core.joined(separator: " ")] { out.insert(c) }
                // 连着的一到五个词
                for i in words.indices {
                    var phrase = ""
                    for j in i..<min(words.count, i + maxWords) {
                        phrase = j == i ? words[j] : phrase + " " + words[j]
                        if let c = phrases[phrase] { out.insert(c) }
                    }
                }
            }
            // 有中文（CJK 区段）才比中文
            if raw.unicodeScalars.contains(where: { $0.value >= 0x2E80 }) {
                let han = raw.replacingOccurrences(of: " ", with: "")
                for (k, c) in hanKeys where han.contains(k) { out.insert(c) }
                for (k, c) in hanExactKeys where han == k || han.hasPrefix(k + "：") || han.hasPrefix(k + ":") { out.insert(c) }
            }
        }
        return out
    }

    /// 英文拆词：去掉重音、小写，只留 a–z、0–9 连成的词（「Spider-Man: No Way Home」→ spider man no way home）
    static func tokens(_ s: String) -> [String] {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        var words: [String] = []
        var cur = String.UnicodeScalarView()
        for u in folded.unicodeScalars {
            let v = u.value
            if (v >= 0x30 && v <= 0x39) || (v >= 0x61 && v <= 0x7A) {
                cur.append(u)
            } else if !cur.isEmpty {
                words.append(String(cur))
                cur = String.UnicodeScalarView()
            }
        }
        if !cur.isEmpty { words.append(String(cur)) }
        return words
    }
}

// MARK: - 画面

extension AppModel {
    /// 片段合集用的竖版画面（卡、刷视频那一屏的底）：Apple TV 无字的竖版主视觉 → TMDB 纯净海报 → 海报 → 横版剧照。
    /// width 是要显示的宽（点）：Apple 的图按 宽 × 3 要像素
    /// 竖版画面的候选，按顺序（刷视频页用 RemoteImageChain 一张张试：前面那张取不到就换下一张）：
    /// Apple TV 竖版主视觉 → TMDB 纯净海报 → Apple 海报 → TMDB 海报 → 横版的无字背景 / 剧照 → TMDB 剧照。
    /// full：这一部的全量结果（纯净海报、无字横版剧照、剧照都在里面；片库的简要结果没有）
    func clipArtCandidates(_ e: HomeEntry, width: CGFloat, full: Meta? = nil) -> [URL] {
        func some(_ s: String?) -> String? { (s?.isEmpty ?? true) ? nil : s }
        let px = Int(min(1600, max(450, width * 3)).rounded())
        let size = width * 3 > 500 ? "w780" : "w500"
        var out: [URL] = []
        func add(_ u: URL?) { if let u, !out.contains(u) { out.append(u) } }
        func apple(_ s: String?, _ w: Int) { if let s = some(s) { add(URL(string: AppleImage.sized(s, width: w) ?? s)) } }
        func tmdb(_ a: String?, _ b: String?, _ size: String) { add(TMDBImage.url(some(a) ?? some(b), size)) }
        switch e {
        case .movie(let v):
            let a = appleArt(v), m = meta(v)
            apple(a?.tall, px)
            tmdb(full?.posterClean, m?.posterClean, size)
            apple(a?.poster, px)
            tmdb(full?.poster, m?.poster, size)
            tmdb(full?.backdropClean, m?.backdropClean, "w1280")
            apple(a?.background, 1920)
            tmdb(full?.backdrop, m?.backdrop, "w1280")
            apple(a?.wide, 1920)
            for st in (full?.stills ?? m?.stills ?? []).prefix(2) { tmdb(st.url, st.thumb, "w1280") }
        case .series(let s):
            let m = seriesMetas[s.path] ?? full
            tmdb(m?.posterClean, nil, size)
            tmdb(m?.poster, nil, size)
            tmdb(m?.backdropClean, nil, "w1280")
            tmdb(m?.backdrop, nil, "w1280")
            for st in (m?.stills ?? []).prefix(2) { tmdb(st.url, st.thumb, "w1280") }
        }
        return out
    }

    /// 有没有竖版画面（选主页卡的封面：没有的不拿来当封面）
    func hasClipArt(_ e: HomeEntry) -> Bool {
        func some(_ s: String?) -> Bool { !(s?.isEmpty ?? true) }
        switch e {
        case .movie(let v):
            let a = appleArt(v), m = meta(v)
            return some(a?.tall) || some(m?.posterClean) || some(a?.poster) || some(m?.poster)
        case .series(let s):
            let m = seriesMetas[s.path]
            return some(m?.posterClean) || some(m?.poster)
        }
    }

    /// 字标（HDR 管线由 LogoImage 走）
    func clipLogo(_ e: HomeEntry) -> URL? {
        switch e {
        case .movie(let v): return logoArt(v)
        case .series(let s): return seriesWideArt(s).logo
        }
    }

    func clipTitle(_ e: HomeEntry) -> String {
        switch e {
        case .movie(let v): return title(v)
        case .series(let s): return seriesMetas[s.path]?.title ?? s.name
        }
    }
}

// MARK: - 主页那一排

/// 主页「探索片段合集」：2026 那一排下面（用户要求），一排 9 : 16 的竖卡，点开是刷视频式的浏览（从卡上放大出来）。
/// 每个合集的封面是排在最前、有竖版画面的那一部（几个合集不拿同一部当封面）；一部都没有的合集不出卡
struct ClipCollectionsShelf: View {
    @Environment(AppModel.self) private var model
    let metrics: DSMetrics
    @State private var open: ClipCollection?
    @Namespace private var ns

    private struct Cover: Identifiable {
        let collection: ClipCollection
        let entry: HomeEntry
        var id: String { collection.rawValue }
    }

    private var covers: [Cover] {
        var used = Set<String>()
        var out: [Cover] = []
        for c in ClipCollection.allCases {
            let list = model.clipEntries(c)
            guard !list.isEmpty else { continue }
            let pick = list.first { model.hasClipArt($0) && !used.contains($0.id) }
                ?? list.first { !used.contains($0.id) } ?? list[0]
            used.insert(pick.id)
            out.append(Cover(collection: c, entry: pick))
        }
        return out
    }

    var body: some View {
        let list = covers
        let w = metrics.clipCardWidth
        if !list.isEmpty {
            DSSection(title: "探索片段合集", metrics: metrics) {
                DSShelf(metrics: metrics) {
                    ForEach(list) { cover in
                        Button {
                            Haptics.light()
                            open = cover.collection
                        } label: {
                            ClipCollectionCard(title: cover.collection.title, arts: model.clipArtCandidates(cover.entry, width: w), width: w)
                        }
                        .buttonStyle(PressableStyle())
                        .matchedTransitionSource(id: cover.collection, in: ns)
                        .accessibilityLabel(cover.collection.title)
                        .accessibilityHint("上下滑动，随心浏览")
                        .accessibilityIdentifier("clip-collection-\(cover.collection.rawValue)")
                    }
                }
            }
            .fullScreenCover(item: $open) { c in
                ClipFeedView(collection: c, entries: model.clipEntries(c))
                    .navigationTransition(.zoom(sourceID: c, in: ns))
            }
        }
    }
}

/// 一张合集竖卡（参考图）：9 : 16、圆角、一圈细边；整幅画面，下段渐进式模糊（用户要求）再压一层淡暗，
/// 左下大号粗体的分类名压在模糊上
struct ClipCollectionCard: View {
    let title: String
    /// 画面的候选（前面那张取不到就换下一张：RemoteImageChain）
    let arts: [URL]
    let width: CGFloat

    var body: some View {
        let h = (width * 16 / 9).rounded()
        let shape = RoundedRectangle(cornerRadius: min(22, max(16, (width * 0.13).rounded())), style: .continuous)
        Color.clear
            .frame(width: width, height: h)
            // 画面先裁成 9 : 16、下段渐进式模糊（ImageEffect.clipCard，后台算一次、缓存），糊的那一段正好垫在分类名下面
            .overlay { RemoteImageChain(urls: arts, maxPixel: width * 3, placeholder: Color(white: 0.12), effect: .clipCard) }
            .overlay {
                // 糊过以后只要很淡的一层暗：白字看得清（C58），画面颜色还在
                LinearGradient(stops: [.init(color: .black.opacity(0), location: 0.5),
                                       .init(color: .black.opacity(0.2), location: 0.75),
                                       .init(color: .black.opacity(0.45), location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
            .overlay(alignment: .bottomLeading) {
                Text(title)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 16)
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
            .contentShape(shape)
    }
}

// MARK: - 刷视频式的浏览

/// 一部一屏，上下滑换一部（分页对齐）。只有正对着的那一屏挂预告片（ShowcaseTrailer：静音、第 10 秒起、循环、码流够清楚才露画面；
/// 全 App 同一时刻只放一段：这里一开，主页那几段停在当前那一帧）。ⓘ 在这一层自己的导航栈里推进详情页，回来接着刷
struct ClipFeedView: View {
    let collection: ClipCollection
    let entries: [HomeEntry]
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var current: String?
    @State private var trailer = ShowcaseTrailer(revealHeight: 1080)
    @State private var path: [Route] = []

    var body: some View {
        NavigationStack(path: $path) {
            GeometryReader { geo in
                let ins = geo.safeAreaInsets
                // iPhone Duo 折起（竖拿）：系统的状态栏在右边那一列，关闭、分享、页码点也放进那一列（参考图）
                let column = ins.trailing >= 40
                ZStack {
                    Color.black.ignoresSafeArea()
                    feed(column: column, insets: ins)
                    controls(column: column, insets: ins)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Route.self) { RouteView(route: $0).dsSoftTopEdge() }
        }
        .onAppear {
            if current == nil { current = entries.first?.id }
            mountCurrent()
        }
        .onDisappear { trailer.unmount() }
        .onChange(of: current) { _, _ in
            Haptics.selection()
            mountCurrent()
        }
        // 推进详情页：预告片停着；回来接着放
        .onChange(of: path) { _, p in trailer.setVisible(p.isEmpty) }
        .environment(\.colorScheme, .dark)
    }

    private var index: Int { entries.firstIndex { $0.id == current } ?? 0 }
    private var currentEntry: HomeEntry? { entries.isEmpty ? nil : entries[min(index, entries.count - 1)] }

    /// 一页就是整个屏的高（上下的安全区也算在页里，卡自己往里让）：以前滚动区自己伸到底下的安全区里，
    /// 页却只有安全区那么高，底下总露出下一张卡的一截（用户截图）
    private func feed(column: Bool, insets ins: EdgeInsets) -> some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(entries) { e in
                    ClipFeedPage(entry: e, collection: collection, active: current == e.id, trailer: trailer,
                                 insetTop: ins.top, insetBottom: ins.bottom) {
                        path.append(Self.route(e))
                    }
                    .containerRelativeFrame([.horizontal, .vertical])
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $current)
        .scrollIndicators(.hidden)
        .ignoresSafeArea(edges: .vertical)
    }

    @ViewBuilder
    private func controls(column: Bool, insets ins: EdgeInsets) -> some View {
        if column {
            // 对着系统状态栏那一列的中线（DuoRail：主页侧边导航量到的）。以前按这一层自己读到的右侧安全区（84 点）居中，
            // 比状态栏的时间、信号偏外约 6 点（用户截图：控件对齐）
            let rail = DuoRail.shared.fromTrailing ?? ins.trailing / 2
            VStack(spacing: 14) {
                closeButton
                if let e = currentEntry { shareButton(e) }
                ClipFeedDots(count: entries.count, index: index)
                    .padding(.top, 34)
            }
            .frame(width: rail * 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(.top, ins.top + 168)
            .ignoresSafeArea()
        } else {
            ZStack(alignment: .topTrailing) {
                HStack(spacing: 12) {
                    if let e = currentEntry { shareButton(e) }
                    closeButton
                }
                .padding(.top, 18)
                .padding(.trailing, 20)
                ClipFeedDots(count: entries.count, index: index)
                    .padding(.trailing, 18)
                    .frame(maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
    }

    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .accessibilityLabel("关闭")
        .accessibilityIdentifier("clip-feed-close")
    }

    @ViewBuilder
    private func shareButton(_ e: HomeEntry) -> some View {
        let title = model.clipTitle(e)
        Group {
            if let url = Self.shareURL(e, model: model) {
                ShareLink(item: url, subject: Text(title)) { shareGlyph }
            } else {
                ShareLink(item: title) { shareGlyph }
            }
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .accessibilityLabel("分享")
    }

    private var shareGlyph: some View {
        Image(systemName: "square.and.arrow.up")
            .font(.title3.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: 48, height: 48)
            .contentShape(Circle())
    }

    /// 正对着的那一部挂上预告片（剧集去 Apple TV 查）；是人点开来刷的：不看系统「自动播放视频预览」和省流量，照样放
    private func mountCurrent() {
        guard let e = currentEntry else { return }
        switch e {
        case .movie(let v):
            trailer.mount(v, model: model, userStarted: true)
        case .series(let s):
            trailer.mount(key: Self.key(e), userStarted: true) { @MainActor [model] in
                let hit = await model.atv(for: s)
                return AppModel.playable(hit?.trailers)
            }
        }
    }

    static func key(_ e: HomeEntry) -> String {
        switch e {
        case .movie(let v): return v.path
        case .series(let s): return "s:" + s.path
        }
    }

    static func route(_ e: HomeEntry) -> Route {
        switch e {
        case .movie(let v): return .movie(v)
        case .series(let s): return .series(s)
        }
    }

    /// 分享：TMDB 上这一部的页面（和详情页的分享一样）；没有编号就分享片名
    static func shareURL(_ e: HomeEntry, model: AppModel) -> URL? {
        switch e {
        case .movie(let v):
            return model.meta(v)?.id.flatMap { URL(string: "https://www.themoviedb.org/movie/\($0)") }
        case .series(let s):
            return (s.tmdbId ?? model.seriesMetas[s.path]?.id).flatMap { URL(string: "https://www.themoviedb.org/tv/\($0)") }
        }
    }
}

/// 一屏：一张大圆角卡。底是竖版主视觉，正对着时预告片起来就盖上去（淡入）；顶上不写分类名（用户要求移除），
/// 底下（参考图）：高分的一颗胶囊、字标、「电影 · 2026 · 科幻」、「加入想看」+ ⓘ、预告片进度
struct ClipFeedPage: View {
    let entry: HomeEntry
    let collection: ClipCollection
    let active: Bool
    let trailer: ShowcaseTrailer
    /// 上下的安全区：页铺满整个屏，卡往里让这么多
    var insetTop: CGFloat = 0
    var insetBottom: CGFloat = 0
    let onInfo: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 这一部的全量结果（纯净海报、无字横版剧照、剧照）：底图多几张候选
    @State private var full: Meta?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 30, style: .continuous)
        let playing = active && trailer.path == ClipFeedView.key(entry)
        let showing = playing && trailer.showing
        GeometryReader { g in
            // 一块定死大小的底，画面、预告片、压暗、字和按钮全放在它的 overlay 里：fill 的图比卡大也撑不大这一层。
            // 以前放在 ZStack 里，竖版主视觉按 fill 铺开比卡高一截，把整列字一起撑高、上下各被裁掉一截
            // （用户截图：按钮只剩上半截、进度条不见了，顶上的分类名也没了）
            Color(white: 0.06)
                .overlay {
                    // 用户截图：整页黑着——以前只试一张竖版画面，它取不到就什么都没有。现在按顺序试几张（RemoteImageChain）
                    RemoteImageChain(urls: model.clipArtCandidates(entry, width: g.size.width, full: full),
                                     maxPixel: max(g.size.width, g.size.height) * 3)
                }
                .overlay {
                    if showing {
                        VideoSurface(player: trailer.player, gravity: .resizeAspectFill, background: .clear)
                            .transition(.opacity)
                            .accessibilityHidden(true)
                    }
                }
                // 上下两段压暗：顶上的关闭、分享（没有侧边那一列时在卡的右上角），底下的字标和按钮压在上面看得清（C58）
                .overlay {
                    LinearGradient(stops: [.init(color: .black.opacity(0.45), location: 0),
                                           .init(color: .black.opacity(0), location: 0.22),
                                           .init(color: .black.opacity(0), location: 0.5),
                                           .init(color: .black.opacity(0.5), location: 0.78),
                                           .init(color: .black.opacity(0.8), location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                }
                .overlay {
                    if playing && trailer.paused {
                        Image(systemName: "play.fill")
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 76, height: 76)
                            .glassEffect(.regular, in: Circle())
                            .transition(.scale(scale: 0.8).combined(with: .opacity))
                    }
                }
                .overlay(alignment: .bottom) {
                    bottom(width: g.size.width, playing: playing)
                }
                .frame(width: g.size.width, height: g.size.height)
                // 轻点画面：暂停 / 接着放（刷短视频的习惯）
                .contentShape(Rectangle())
                .onTapGesture {
                    guard playing, trailer.loaded else { return }
                    withAnimation(.snappy(duration: 0.25)) { trailer.togglePause() }
                }
                .animation(reduceMotion ? .easeInOut(duration: 0.2) : .easeInOut(duration: 0.5), value: showing)
        }
        .clipShape(shape)
        .padding(.horizontal, 8)
        .padding(.top, insetTop + 6)
        .padding(.bottom, insetBottom + 6)
        // 滑到这一页才问（懒加载的一页一页来）；问过的在内存里，滑回来不再问
        .task(id: ClipFeedView.key(entry)) {
            if case .movie(let v) = entry, full == nil { full = await model.fullMeta(for: v) }
        }
    }

    private func bottom(width: CGFloat, playing: Bool) -> some View {
        let title = model.clipTitle(entry)
        let line = typeLine
        return VStack(spacing: 12) {
            if let badge {
                Text(badge)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.black.opacity(0.35)))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.28), lineWidth: 1))
            }
            LogoImage(url: model.clipLogo(entry), height: 64, alignment: .center, fallback: title,
                      maxWidth: min(320, width * 0.7))
                .accessibilityLabel(title)
            HStack(spacing: 8) {
                Image(systemName: isSeries ? "tv" : "film")
                    .font(.footnote.weight(.semibold))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.white.opacity(0.16)))
                    .accessibilityHidden(true)
                Text(line)
                    .lineLimit(1)
            }
            .font(.title3)
            .foregroundStyle(.white)
            HStack(spacing: 12) {
                watchlistButton
                Button(action: onInfo) {
                    Image(systemName: "info.circle")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: Circle())
                .accessibilityLabel("详细信息")
                .accessibilityIdentifier("clip-feed-info")
            }
            .padding(.top, 2)
            ClipFeedProgress(value: playing ? trailer.progress : 0)
                .padding(.horizontal, 22)
                .padding(.top, 10)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 22)
    }

    private var isSeries: Bool {
        if case .series = entry { return true }
        return false
    }

    /// 「电影 · 2026 · 科幻」/「剧集 · 2025 · 剧情」
    private var typeLine: String {
        switch entry {
        case .movie(let v):
            return DetailText.line(["电影", model.year(v).map { String($0) }, model.meta(v)?.genres?.first])
        case .series(let s):
            return DetailText.line(["剧集", s.year, model.seriesMetas[s.path]?.genres?.first])
        }
    }

    /// 参考图「2026 Oscar® Winner」那颗胶囊：我们没有奖项，TMDB 8 分以上写「高分佳作」
    private var badge: String? {
        let r: Double?
        switch entry {
        case .movie(let v): r = model.meta(v)?.rating
        case .series(let s): r = model.seriesMetas[s.path]?.rating
        }
        // 9.6 分以上多半是没几个人打的分（截图里一部恐怖片「TMDB 10.0」）：不当高分佳作
        guard let r, r >= 8, r < 9.6 else { return nil }
        return String(format: "TMDB %.1f · 高分佳作", r)
    }

    private var watchKey: (key: String, kind: WatchItem.Kind) {
        switch entry {
        case .movie(let v): return (v.path, .movie)
        case .series(let s): return (s.path, .series)
        }
    }

    private var watchlistButton: some View {
        let w = watchKey
        let added = model.watchlist.contains(w.key)
        return Button {
            Haptics.light()
            withAnimation(.snappy) { model.watchlist.toggle(w.key, kind: w.kind) }
        } label: {
            Label(added ? "已在想看" : "加入想看", systemImage: added ? "checkmark" : "plus")
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.horizontal, 24)
                .frame(height: 52)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
        .accessibilityIdentifier("clip-feed-watchlist")
    }
}

/// 预告片进度：一条细胶囊，走过的是白色
struct ClipFeedProgress: View {
    let value: Double

    var body: some View {
        Capsule()
            .fill(Color.white.opacity(0.22))
            .frame(height: 4)
            .overlay(alignment: .leading) {
                GeometryReader { g in
                    Capsule()
                        .fill(Color.white)
                        .frame(width: max(0, min(1, value)) * g.size.width)
                }
            }
            .animation(.linear(duration: 0.25), value: value)
            .accessibilityHidden(true)
    }
}

/// 竖着的页码点（参考图）：当前那颗白、大一点，离得越远越小越淡，最多看得到七颗
struct ClipFeedDots: View {
    let count: Int
    let index: Int

    var body: some View {
        if count > 1 {
            let span = 3
            let lo = max(0, min(index - span, count - (span * 2 + 1)))
            let hi = min(count - 1, lo + span * 2)
            VStack(spacing: 10) {
                ForEach(lo...hi, id: \.self) { i in
                    let d = abs(i - index)
                    let size: CGFloat = d == 0 ? 10 : (d == 1 ? 8.5 : (d == 2 ? 7 : 5))
                    Circle()
                        .fill(Color.white.opacity(d == 0 ? 1 : (d == 1 ? 0.5 : 0.35)))
                        .frame(width: size, height: size)
                }
            }
            .frame(width: 14)
            .animation(.snappy(duration: 0.3), value: index)
            .accessibilityHidden(true)
        }
    }
}
