import SwiftUI
import UIKit

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
    private static let seriesTitles = ["灯火人间", "海港往事", "无人之境", "长街", "旧城新事", "风起时", "极地来信", "午夜电台"]

    private static func url(_ kind: String, _ seed: Int, _ text: String? = nil, dark: Bool = false) -> String {
        var s = "demo://\(kind)/\(seed)"
        var q: [String] = []
        if let text { q.append("t=" + (text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")) }
        if dark { q.append("dark=1") }
        if !q.isEmpty { s += "?" + q.joined(separator: "&") }
        return s
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
            metas[name] = Meta(id: 9000 + i, title: t, en: english[i], year: String(year),
                               poster: url("poster", i, t), posterClean: url("poster", i), backdrop: url("backdrop", i),
                               logo: url("logo", i, t, dark: i % 5 == 2),
                               overview: "这是演示数据里的一部片：用来核对版面，不是真实的片库内容。画面、片名与简介都是本地生成的。",
                               rating: 6 + Double(i % 7) * 0.5, type: "movie", runtime: 92 + i * 3, genres: genres[i % genres.count])
        }
        m.videos = videos
        m.metas = metas

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
                            logo: url("logo", 40 + i, t, dark: i % 4 == 1),
                            overview: "演示剧集：本地生成的画面与分集，用来核对版面。", rating: 8, type: "tv", genres: ["剧情"],
                            stills: [Still(url: url("backdrop", 60 + i), thumb: url("backdrop", 60 + i))])
        }
        m.series = series
        m.seriesMetas = sm

        m.heroes = (0..<6).map { i in
            let v = videos[i]
            return Hero(path: v.path, name: v.name, title: english[i], year: 2026 - i, background: url("backdrop", i),
                        poster: url("tall", i), logo: url("logo", i, titles[i], dark: i % 5 == 2))
        }
    }

    static func episodes(_ s: Series) -> [EpisodeFile] {
        (1...(s.episodes ?? 8)).map { n in EpisodeFile(ep: n, path: s.path + "/E\(n).mkv", name: "Demo.S01E\(String(format: "%02d", n)).mkv") }
    }

    static func season(_ s: Series) -> [Int: SeasonEpisode] {
        var d: [Int: SeasonEpisode] = [:]
        for n in 1...(s.episodes ?? 8) {
            d[n] = SeasonEpisode(ep: n, name: "第 \(n) 个故事", overview: "演示分集简介：本地生成，用来核对分集清单的版面。",
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
        let ratio: CGFloat
        switch kind {
        case "poster": ratio = 1.5
        case "tall": ratio = 2.16
        case "logo": ratio = 0.3
        default: ratio = 9.0 / 16.0
        }
        let w = min(max(maxPixel, 200), 900)
        let size = CGSize(width: w, height: (w * ratio).rounded())
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = kind != "logo"
        return UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            let cg = ctx.cgContext
            if kind == "logo" {
                let t = text ?? "Cuven"
                let font = UIFont.systemFont(ofSize: size.height * 0.62, weight: .black)
                let color = dark ? UIColor(white: 0.07, alpha: 1) : UIColor.white
                let attr = NSAttributedString(string: t, attributes: [.font: font, .foregroundColor: color])
                let b = attr.boundingRect(with: size, options: [.usesLineFragmentOrigin], context: nil)
                let scale = min(1, (size.width * 0.96) / max(1, b.width))
                cg.translateBy(x: size.width / 2, y: size.height / 2)
                cg.scaleBy(x: scale, y: scale)
                attr.draw(at: CGPoint(x: -b.width / 2, y: -b.height / 2))
                return
            }
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
