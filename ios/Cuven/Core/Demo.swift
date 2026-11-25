import SwiftUI
import UIKit
import CoreText

/// 演示数据：启动参数 `-CuvenDemo YES` 时整个 App 用合成的片单（片名、海报、字标都是本地画的），不连服务器。
/// 用途：仓库是公开的，模拟器截图不能带真实片库；用演示数据截图核对布局（尤其 iPhone Duo 的几种形态）。
enum DemoData {
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "CuvenDemo") }

    private static let titles = [
        "星际回声", "长夜将明", "北方来信", "雾中灯塔", "盛夏未至", "无声海岸", "第七号站台", "远山的回响",
        "白昼之下", "风暴来临前", "迷城", "最后一班列车", "月光走廊", "冬日来客", "极光之城", "沉默的证人",
        "春潮", "银色轨道", "午夜书店", "南方小镇", "荒原守望者", "时间旅人", "潮汐", "雪国列车长",
        "红色信号", "旧梦重温", "城市之光", "无尽之夏", "山海之间", "边境线", "夜航", "深蓝",
    ]
    private static let english = [
        "Echoes of Stars", "Before the Dawn", "Letters from the North", "Lighthouse in the Fog", "Not Yet Summer", "Silent Coast",
        "Platform Seven", "Echo of Mountains", "Beneath the Daylight", "Before the Storm", "Labyrinth City", "The Last Train",
        "Moonlit Corridor", "Winter Guest", "City of Aurora", "Silent Witness", "Spring Tide", "Silver Track", "Midnight Bookstore",
        "Southern Town", "Wasteland Watcher", "Time Traveler", "Tides", "Snow Conductor", "Red Signal", "Old Dreams", "City Lights",
        "Endless Summer", "Between Mountains and Seas", "Borderline", "Night Flight", "Deep Blue",
    ]
    private static let genres = [["科幻", "冒险"], ["剧情"], ["爱情", "剧情"], ["悬疑", "惊悚"], ["动画", "家庭"], ["动作", "犯罪"], ["喜剧"], ["历史", "战争"]]
    /// 演示用的演员名单（虚构的名字，头像是本地画的色块）
    private static let people = ["陈默", "林夏", "周远", "许晴", "沈川", "苏念", "顾言", "唐宁", "叶舟", "程露"]
    private static let roles = ["艾琳", "船长", "老周", "记者", "向导", "医生", "警探", "少年", "画家", "邮差"]
    private static func cast(_ i: Int) -> [CastMember] {
        (0..<8).map { k in
            let n = (i + k * 3) % people.count
            return CastMember(id: 100 + n, name: people[n], character: roles[(i + k) % roles.count], profilePath: url("face", 200 + n))
        }
    }

    private static let seriesTitles = ["灯火人间", "海港往事", "无人之境", "长街", "旧城新事", "风起时", "极地来信", "午夜电台"]

    /// sub：字标下面那行副标题（演示字标照真的电影字标画：主字标 + 小厂牌 + 黄色副标题，见 renderLogo）
    private static func url(_ kind: String, _ seed: Int, _ text: String? = nil, sub: String? = nil, dark: Bool = false) -> String {
        var s = "demo://\(kind)/\(seed)"
        var q: [String] = []
        if let text { q.append("t=" + (text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")) }
        if let sub { q.append("s=" + (sub.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")) }
        if dark { q.append("dark=1") }
        if !q.isEmpty { s += "?" + q.joined(separator: "&") }
        return s
    }

    /// 演示用的两段「预告片」：只有画面、名字和时长（地址是 demo://，不连网，点开也放不出来），核对预告片卡的样子用
    static func trailers(for v: Video) -> [Trailer] {
        let seed = v.path.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xffff }
        return [
            Trailer(title: "正式预告", hls: "demo://trailer/\(seed)/1", duration: 148, image: url("backdrop", 300 + seed % 40)),
            Trailer(title: "先导预告", hls: "demo://trailer/\(seed)/2", duration: 62, image: url("backdrop", 340 + seed % 40)),
        ]
    }

    @MainActor
    static func populate(_ m: AppModel) {
        let now = Date()
        let iso = ISO8601DateFormatter()
        var videos: [Video] = []
        var metas: [String: Meta] = [:]
        for (i, t) in titles.enumerated() {
            let year = 2026 - (i % 8)
            let name = "Demo.\(english[i].replacingOccurrences(of: " ", with: ".")).\(year).2160p.DV.Atmos.mkv"
            let added = iso.string(from: now.addingTimeInterval(-Double(i) * 86400 * 3))
            videos.append(Video(name: name, path: "/demo/\(name)", size: Int64(8_000_000_000 + i * 731_000_000), added: added))
            var meta = Meta(id: 9000 + i, title: t, en: english[i], year: String(year),
                               poster: url("poster", i, t), posterClean: url("poster", i), backdrop: url("backdrop", i),
                               logo: url("logo", i, t, sub: english[i], dark: i % 5 == 2),
                               overview: "这是演示数据里的一部片：用来核对版面，不是真实的片库内容。画面、片名与简介都是本地生成的。",
                               rating: 6 + Double(i % 7) * 0.5, type: "movie", runtime: 92 + i * 3, genres: genres[i % genres.count])
            meta.cast = cast(i)
            meta.director = people[(i + 5) % people.count]
            // 剧照（资料库每章底下那一排、详情页）：本地画的几张横图
            meta.stills = (0..<4).map { k in Still(url: url("backdrop", 200 + i * 4 + k), thumb: url("backdrop", 200 + i * 4 + k)) }
            metas[name] = meta
        }
        m.videos = videos
        m.metas = metas
        // 根下一级的几个文件夹（首页最后那排「文件夹」）：名字是合成的
        m.folders = folderNames.map { LibraryFolder(name: $0, path: "/demo/\($0)") }
        m.libraryRoot = "/demo"
        // 看到一半的一部（只在内存里）：首页「继续观看」里有一张
        let cw = videos[3]
        m.playback.update(WatchEntry(path: cw.path, name: cw.name, title: titles[3], subtitle: String(2026 - 3 % 8),
                                     artwork: url("backdrop", 3), position: 1_520, duration: 6_300,
                                     updated: now.addingTimeInterval(-7_200)))

        var series: [Series] = []
        var sm: [String: Meta] = [:]
        for (i, t) in seriesTitles.enumerated() {
            let path = "/demo-tv/\(t)"
            let year = String(2026 - i % 3)
            series.append(Series(id: "demo-\(i)", path: path, title: t, en: english[(i * 3) % english.count], season: 1 + i % 2,
                                 year: year, episodes: 8 + i, full: i % 3 != 1, tags: ["4K", "杜比视界"],
                                 added: iso.string(from: now.addingTimeInterval(-Double(i) * 86400 * 5))))
            sm[path] = Meta(id: 7000 + i, title: t, en: english[(i * 3) % english.count], year: year,
                            poster: url("poster", 40 + i, t), posterClean: url("poster", 40 + i), backdrop: url("backdrop", 40 + i),
                            logo: url("logo", 40 + i, t, sub: english[(i * 3) % english.count], dark: i % 4 == 1),
                            overview: "演示剧集：本地生成的画面与分集，用来核对版面。", rating: 8, type: "tv", genres: ["剧情"],
                            stills: [Still(url: url("backdrop", 60 + i), thumb: url("backdrop", 60 + i))])
        }
        // 第一部剧再多一季（同一个 TMDB 编号）：剧集详情的季切换有东西可切
        let s2 = "/demo-tv/\(seriesTitles[0]) 第二季"
        series.append(Series(id: "demo-0-s2", path: s2, title: seriesTitles[0], en: english[0], season: 2, year: "2026",
                             episodes: 6, full: false, tags: ["4K"], added: iso.string(from: now.addingTimeInterval(-86400 * 60))))
        sm[s2] = Meta(id: 7000, title: seriesTitles[0], en: english[0], year: "2026",
                      poster: url("poster", 48, seriesTitles[0]), posterClean: url("poster", 48), backdrop: url("backdrop", 48),
                      logo: url("logo", 40, seriesTitles[0], sub: english[0]),
                      overview: "演示剧集第二季：本地生成的画面与分集，用来核对季切换。", rating: 8.4, type: "tv", genres: ["剧情"],
                      stills: [Still(url: url("backdrop", 68), thumb: url("backdrop", 68))])
        m.series = series
        m.seriesMetas = sm

        m.heroes = (0..<6).map { i in
            let v = videos[i]
            return Hero(path: v.path, name: v.name, title: english[i], year: 2026 - i, background: url("backdrop", i),
                        poster: url("tall", i), logo: url("logo", i, titles[i], sub: english[i], dark: i % 5 == 2))
        }
    }

    /// 演示用的文件夹名（合成的）
    private static let folderNames = ["合集 · 星际旅程", "导演剪辑版", "纪录片精选"]

    /// 文件夹页的内容：第一个文件夹里还有一个子文件夹；视频从演示片单里按文件夹名挑一段（每次打开都一样）
    static func folderContents(_ f: LibraryFolder, videos: [Video]) -> (folders: [LibraryFolder], videos: [Video]) {
        guard !videos.isEmpty else { return ([], []) }
        let seed = f.path.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        let count = min(videos.count, 7 + seed % 5)
        let start = seed % videos.count
        let picked = (0..<count).map { videos[(start + $0 * 3) % videos.count] }
        var seen = Set<String>()
        let unique = picked.filter { seen.insert($0.path).inserted }
        let subs = f.path == "/demo/\(folderNames[0])" ? [LibraryFolder(name: "第一部分", path: f.path + "/第一部分")] : []
        return (subs, unique)
    }

    static func episodes(_ s: Series) -> [EpisodeFile] {
        (1...(s.episodes ?? 8)).map { n in EpisodeFile(ep: n, path: s.path + "/E\(n).mkv", name: "Demo.S01E\(String(format: "%02d", n)).mkv") }
    }

    static func season(_ s: Series) -> [Int: SeasonEpisode] {
        var d: [Int: SeasonEpisode] = [:]
        for n in 1...(s.episodes ?? 8) {
            // 第 1 集的简介故意写长：超过三行，卡上第三行末尾才会压一枚「更多」（核对分集「更多」弹层）
            let overview = n == 1
                ? "演示分集简介：本地生成，用来核对分集清单的版面。这一集的简介故意写得长一些，好让卡片下面的字超过三行——超过三行时，第三行末尾压一枚「更多」，点开是整段简介的弹层，和网页版一样。弹层里能滚，底下是「关闭」。"
                : "演示分集简介：本地生成，用来核对分集清单的版面。"
            d[n] = SeasonEpisode(ep: n, name: "第 \(n) 个故事", overview: overview,
                                 still: "demo://backdrop/\(100 + n)", runtime: 42 + n)
        }
        return d
    }

    // MARK: 本地画图

    static func render(_ url: URL, maxPixel: CGFloat) -> UIImage? {
        let kind = url.host ?? "poster"
        let seed = Int(url.lastPathComponent) ?? 0
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let text = comps?.queryItems?.first { $0.name == "t" }?.value
        let dark = comps?.queryItems?.contains { $0.name == "dark" } ?? false
        let w = min(max(maxPixel, 200), 900)
        if kind == "logo" {
            let sub = comps?.queryItems?.first { $0.name == "s" }?.value
            return renderLogo(title: text ?? "Cuven", subtitle: sub, dark: dark, width: w)
        }
        let ratio: CGFloat
        switch kind {
        case "poster": ratio = 1.5
        case "tall": ratio = 2.16
        case "face": ratio = 1
        default: ratio = 9.0 / 16.0
        }
        let size = CGSize(width: w, height: (w * ratio).rounded())
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = true
        return UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            let cg = ctx.cgContext
            let hue = CGFloat((seed * 47) % 360) / 360
            let c1 = UIColor(hue: hue, saturation: 0.55, brightness: 0.62, alpha: 1)
            let c2 = UIColor(hue: (hue + 0.13).truncatingRemainder(dividingBy: 1), saturation: 0.7, brightness: 0.16, alpha: 1)
            let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [c1.cgColor, c2.cgColor] as CFArray, locations: [0, 1])!
            cg.drawLinearGradient(g, start: CGPoint(x: 0, y: 0), end: CGPoint(x: size.width * 0.5, y: size.height), options: [])
            // 一大一小两个柔光圆，画面不至于是一块死板的渐变
            UIColor(white: 1, alpha: 0.10).setFill()
            cg.fillEllipse(in: CGRect(x: size.width * 0.45, y: size.height * 0.08, width: size.width * 0.7, height: size.width * 0.7))
            UIColor(white: 1, alpha: 0.06).setFill()
            cg.fillEllipse(in: CGRect(x: -size.width * 0.2, y: size.height * 0.55, width: size.width * 0.6, height: size.width * 0.6))
            if kind == "poster", let t = text {
                let font = UIFont.systemFont(ofSize: size.width * 0.13, weight: .heavy)
                let attr = NSAttributedString(string: t, attributes: [.font: font, .foregroundColor: UIColor.white])
                let b = attr.boundingRect(with: CGSize(width: size.width * 0.86, height: size.height), options: [.usesLineFragmentOrigin], context: nil)
                attr.draw(with: CGRect(x: size.width * 0.07, y: size.height * 0.78 - b.height / 2, width: size.width * 0.86, height: b.height),
                          options: [.usesLineFragmentOrigin], context: nil)
            }
        }
    }
}

extension DemoData {
    /// 演示数据里的演员简介：本地编的（不连网、不是真实的人）；作品不给编号，库中作品按演示片库的演员表找
    static func person(_ m: CastMember) -> PersonInfo {
        let seed = m.name.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        let places = ["中国 上海", "中国 北京", "中国 台北", "新加坡", "中国 香港", "中国 成都"]
        let year = 1968 + seed % 30
        let month = 1 + seed % 12
        let day = 1 + seed % 27
        let bio = "\(m.name.isEmpty ? "这位演员" : m.name)是演示数据里的一位演员，用来核对演员个人页的版面：照片、名字、简介、来自与出生都是本地生成的。"
            + "从影以来塑造过许多让人记得住的角色，戏路宽，既能演细腻的文艺片，也能撑起节奏很快的类型片。"
            + "这段文字故意写得长一些，好看出简介弹层里「关于」那一段的排版和行距。"
        return PersonInfo(id: m.id ?? seed, name: m.name, biography: bio,
                          birthday: String(format: "%04ld-%02ld-%02ld", year, month, day), deathday: nil,
                          placeOfBirth: places[seed % places.count], knownFor: "Acting",
                          profilePath: m.profilePath, credits: nil)
    }
}

// MARK: 演示字标

extension DemoData {
    /// 演示字标（用户要求：详情页的大字标往下滚时化成细粒子、飞进顶上那条再拼成左上角的小字标；粒子直接从字标的形状和颜色上取样，
    /// 所以演示片要有一枚像样的彩色透明字标，CI 截图才看得出红、蓝粒子里夹着几点黄，以及主字标先拼好、厂牌和副标题后到）。
    /// 照真的电影字标画：透明底；正中一行粗体主字标（红字、蓝边，往左下压一层蓝色的厚度，稍微右斜），
    /// 上面一枚小厂牌（红色小方块里镂空「CUVEN」+「STUDIOS」），下面一行黄色的英文副标题。
    /// 图按墨迹的外框裁齐、左边不留空（详情页字标靠左对齐，条里的小字标和它同一个左边距）。
    /// dark：同一个样子换成深色墨（压在暗画面上看不见的那种），字标管线会把它反白（核对 LogoTone / LogoHDR）
    static func renderLogo(title: String, subtitle: String?, dark: Bool, width: CGFloat) -> UIImage? {
        func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor { UIColor(red: r, green: g, blue: b, alpha: 1).cgColor }
        // 亮的那套：红字最深处的亮度也压在 LogoTone 的「暗墨」线以上，整枚字标不会被当成深色字标反白
        let fillTop = dark ? rgb(0.11, 0.11, 0.12) : rgb(0.98, 0.26, 0.20)
        let fillBottom = dark ? rgb(0.04, 0.04, 0.05) : rgb(0.84, 0.08, 0.10)
        let edgeColor = dark ? rgb(0.0, 0.12, 0.42) : rgb(0.13, 0.27, 0.80)
        let depthColor = dark ? rgb(0.0, 0.06, 0.24) : rgb(0.05, 0.11, 0.44)
        let subColor = dark ? rgb(0.36, 0.26, 0.0) : rgb(1.0, 0.86, 0.12)
        let markColor = dark ? rgb(0.0, 0.12, 0.42) : rgb(0.86, 0.10, 0.12)
        let studioColor = dark ? rgb(0.08, 0.08, 0.09) : rgb(0.95, 0.95, 0.97)

        // 设计单位：主字标字号 100，最后整枚按宽缩放
        let F: CGFloat = 100
        let edgeW = F * 0.10          // 蓝边（描边宽，露在字外面一半）
        let boldW = F * 0.035         // 红字再描一圈同色的，笔画更粗
        let depth = F * 0.075         // 往左下压的蓝色厚度
        let depthDir = CGVector(dx: -0.45, dy: 1)

        // 主字标：字形轮廓，稍微右斜（上沿往右推）；摆成墨迹的左上角在原点
        let shear = CGAffineTransform(a: 1, b: 0, c: -0.16, d: 1, tx: 0, ty: 0)
        let rawWord = glyphPath(title, font: .systemFont(ofSize: F, weight: .black), kern: F * 0.01, transform: shear)
        let rb = rawWord.boundingBoxOfPath
        guard !rawWord.isEmpty, !rb.isNull, rb.width > 1, rb.height > 1 else { return nil }
        let word = placed(rawWord, dx: -rb.minX, dy: -rb.minY)
        let wordRect = CGRect(x: 0, y: 0, width: rb.width, height: rb.height)

        // 上面的小厂牌：正中压在主字标上方
        let markF = F * 0.16
        let markA = glyphPath("CUVEN", font: .systemFont(ofSize: markF, weight: .black), kern: markF * 0.04)
        let markB = glyphPath("STUDIOS", font: .systemFont(ofSize: markF, weight: .semibold), kern: markF * 0.08)
        let ab = markA.boundingBoxOfPath, bb = markB.boundingBoxOfPath
        let hasMark = !markA.isEmpty && !markB.isEmpty && !ab.isNull && !bb.isNull
        var boxRect = CGRect.zero
        var markPathA: CGPath?
        var markPathB: CGPath?
        if hasMark {
            let padY = ab.height * 0.32, padX = ab.height * 0.42, gap = ab.height * 0.4
            let box = CGSize(width: ab.width + padX * 2, height: ab.height + padY * 2)
            let markW = box.width + gap + bb.width
            boxRect = CGRect(x: wordRect.midX - markW / 2, y: -(edgeW / 2 + F * 0.08 + box.height), width: box.width, height: box.height)
            markPathA = placed(markA, dx: boxRect.minX + padX - ab.minX, dy: boxRect.minY + padY - ab.minY)
            markPathB = placed(markB, dx: boxRect.maxX + gap - bb.minX, dy: boxRect.midY - bb.midY)
        }

        // 下面一行黄色副标题：英文片名大写、字距拉开；比主字标宽就缩小字号
        var subPath: CGPath?
        let subText = (subtitle ?? "").uppercased()
        if !subText.isEmpty {
            var subF = F * 0.30
            var sp = glyphPath(subText, font: .systemFont(ofSize: subF, weight: .heavy), kern: subF * 0.12)
            let limit = rb.width * 1.02
            let natural = sp.boundingBoxOfPath.width
            if !sp.isEmpty, natural > limit {
                subF = max(F * 0.16, subF * limit / natural)
                sp = glyphPath(subText, font: .systemFont(ofSize: subF, weight: .heavy), kern: subF * 0.12)
            }
            let sb = sp.boundingBoxOfPath
            if !sp.isEmpty, !sb.isNull {
                subPath = placed(sp, dx: wordRect.midX - sb.midX + F * 0.04,
                                 dy: rb.height + depth + edgeW / 2 + F * 0.07 - sb.minY)
            }
        }

        // 整枚的墨迹外框（蓝边、厚度都算上），四周只留一点给抗锯齿
        var ink = wordRect.insetBy(dx: -edgeW / 2, dy: -edgeW / 2)
        ink = ink.union(ink.offsetBy(dx: depthDir.dx * depth, dy: depthDir.dy * depth))
        if hasMark, let markPathB {
            ink = ink.union(boxRect).union(markPathB.boundingBoxOfPath)
        }
        if let subPath { ink = ink.union(subPath.boundingBoxOfPath) }
        ink = ink.insetBy(dx: -F * 0.02, dy: -F * 0.02)

        let s = max(1, width) / ink.width
        let size = CGSize(width: max(1, (ink.width * s).rounded()), height: max(1, (ink.height * s).rounded()))
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = false
        return UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            let cg = ctx.cgContext
            cg.scaleBy(x: s, y: s)
            cg.translateBy(x: -ink.minX, y: -ink.minY)
            cg.setLineJoin(.round)
            cg.setLineCap(.round)

            // 1. 蓝色的厚度：主字标的剪影往左下一层层压过去
            cg.setFillColor(depthColor)
            cg.setStrokeColor(depthColor)
            cg.setLineWidth(edgeW)
            let steps = 12
            for k in stride(from: steps, through: 1, by: -1) {
                let t = depth * CGFloat(k) / CGFloat(steps)
                cg.saveGState()
                cg.translateBy(x: depthDir.dx * t, y: depthDir.dy * t)
                cg.addPath(word)
                cg.drawPath(using: .fillStroke)
                cg.restoreGState()
            }

            // 2. 蓝边
            cg.setFillColor(edgeColor)
            cg.setStrokeColor(edgeColor)
            cg.setLineWidth(edgeW)
            cg.addPath(word)
            cg.drawPath(using: .fillStroke)

            // 3. 红字：加粗一圈，上亮下深（单独一层里上色，渐变只落在红字上）
            cg.saveGState()
            cg.beginTransparencyLayer(auxiliaryInfo: nil)
            cg.setFillColor(fillBottom)
            cg.setStrokeColor(fillBottom)
            cg.setLineWidth(boldW)
            cg.addPath(word)
            cg.drawPath(using: .fillStroke)
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [fillTop, fillBottom] as CFArray, locations: [0, 1]) {
                cg.setBlendMode(.sourceAtop)
                cg.drawLinearGradient(g, start: CGPoint(x: 0, y: wordRect.minY), end: CGPoint(x: 0, y: wordRect.maxY),
                                      options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
            cg.endTransparencyLayer()
            cg.restoreGState()

            // 4. 小厂牌：红色小方块里镂空「CUVEN」（单独一层里挖，挖不到别的），旁边「STUDIOS」
            if hasMark, let markPathA, let markPathB {
                cg.saveGState()
                cg.beginTransparencyLayer(auxiliaryInfo: nil)
                cg.setFillColor(markColor)
                let r = min(boxRect.height * 0.12, boxRect.width * 0.25)
                cg.addPath(CGPath(roundedRect: boxRect, cornerWidth: r, cornerHeight: r, transform: nil))
                cg.fillPath()
                cg.setBlendMode(.clear)
                cg.addPath(markPathA)
                cg.fillPath()
                cg.endTransparencyLayer()
                cg.restoreGState()
                cg.setFillColor(studioColor)
                cg.addPath(markPathB)
                cg.fillPath()
            }

            // 5. 黄色副标题
            if let subPath {
                cg.setFillColor(subColor)
                cg.addPath(subPath)
                cg.fillPath()
            }
        }
    }

    /// 一行字的字形轮廓：y 朝下、原点在基线左端，再套上 transform。墨迹多大按真的轮廓量（不靠行高猜），
    /// 蓝边、厚度也是照轮廓描的；中文字落到系统的中文字体上，按每一段实际用的字体取轮廓
    private static func glyphPath(_ text: String, font: UIFont, kern: CGFloat, transform: CGAffineTransform = .identity) -> CGPath {
        let out = CGMutablePath()
        guard !text.isEmpty else { return out }
        let attr = NSAttributedString(string: text, attributes: [.font: font, .kern: kern])
        let line = CTLineCreateWithAttributedString(attr as CFAttributedString)
        let runs = CTLineGetGlyphRuns(line) as! [CTRun]
        for run in runs {
            let n = CTRunGetGlyphCount(run)
            guard n > 0, let value = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName as String] else { continue }
            let runFont = value as! CTFont
            var glyphs = [CGGlyph](repeating: 0, count: n)
            var positions = [CGPoint](repeating: .zero, count: n)
            CTRunGetGlyphs(run, CFRange(location: 0, length: n), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: n), &positions)
            for k in 0..<n {
                guard let g = CTFontCreatePathForGlyph(runFont, glyphs[k], nil) else { continue }
                // 字形坐标 y 朝上：翻成 y 朝下、挪到这个字的位置，再斜切
                let place = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: positions[k].x, ty: -positions[k].y)
                out.addPath(g, transform: place.concatenating(transform))
            }
        }
        return out
    }

    private static func placed(_ path: CGPath, dx: CGFloat, dy: CGFloat) -> CGPath {
        let out = CGMutablePath()
        out.addPath(path, transform: CGAffineTransform(translationX: dx, y: dy))
        return out
    }
}
