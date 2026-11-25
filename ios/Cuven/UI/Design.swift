import SwiftUI
import UIKit
import AVFoundation

// MARK: - 设计系统：按 Apple HIG 收拾过的一套（规则出处见 docs/ios-design.md，编号 F = 基础、T = tvOS、S = 触屏上的 tvOS、D = iPhone Duo）
//
// 原则：内容在前，界面退后（F1、F80、T1）。分组靠留白，不靠描边和底板（F3）；玻璃只给系统栏和少数控件，内容层不用（F38）；
// 字一律用系统文字样式（F15），层级靠字重、字号和 .secondary（F18）；颜色只给一个主操作（F32、F33）。
// 同一套设计随屏幕长大（S1、D2）：折起是它，展开就是更大的它——更大的头图、每排更多的卡、更从容的留白。
// 卡只放画面：无字的主视觉 + 官方字标（没有无字的那张，就用本来就印着片名的海报），卡下不写片名（T20：画面自己说明是哪一部）。
// 卡在排里不放大、不压暗别的卡：滑动时只有画面在卡里极轻地挪一点（S12：约 2%，几乎觉察不到 F61）；按下去略缩，是触感反馈（F55）。
// 打开「减弱动态效果」：视差、自动翻页都停（F59、S24）。

/// 版面尺寸：都从当前宽度算（F9、D4：看宽度和尺寸类别，不看机型），矮的屏再看一眼高。
/// 边距按 tvOS 的 80（以 1920 宽为准）缩到眼前的宽度、iPhone 至少 20（S3、S5）；卡与卡之间比 tvOS 的 40 再松一些，
/// 排与排之间留足（T24），每排露出下一张的一截，告诉人还能往右滑（S8、I13）。
/// 折起（窄于 600）沿用一屏几张的老规矩；展开（Duo 展开、iPad、横拿）按每种卡的目标宽来排（`fit`）：
/// 屏越宽一排放得越多，卡只在目标附近小幅变化，不会像按档位排那样「屏更宽、卡反而更小」（用户要求：展开时卡片大小、间距、间隔随屏幕）
struct DSMetrics {
    let width: CGFloat
    /// 两侧的安全区（iPhone Duo 侧边那一列）：横着的一排一直铺到它底下（dsBleedRow），字和网格留在安全区里
    var leadingInset: CGFloat = 0
    var trailingInset: CGFloat = 0
    /// 安全区里能用的高；0 = 没给（只按宽算）。展开横拿、横拿的手机这种矮的屏，排距和大卡按它收一收
    var height: CGFloat = 0

    /// 展开的 Duo、iPad、横拿：一排多放几张，字号上一级
    var wide: Bool { width >= 600 }

    /// iPad 的几档（用户要求按 Apple 的做法给普通 iPad、iPad Pro 11 / 13 寸定制版面：只看窗口宽，不认机型——
    /// iPadOS 26 每台 iPad 都能把 App 放进随意缩放的窗口）：
    /// 窄 < 600（分屏里的窄窗口，和 iPhone 一样）· 中 600–950（普通 iPad 竖拿 820、Pro 11 竖拿 834）·
    /// 大 950–1300（Pro 13 竖拿 1032、普通 iPad 横拿 1180、Pro 11 横拿 1210）· 特大 ≥ 1300（Pro 13 横拿 1376）
    enum Tier: Int, Comparable {
        case compact, medium, large, xl
        static func < (a: Tier, b: Tier) -> Bool { a.rawValue < b.rawValue }
    }
    static let largeWidth: CGFloat = 950
    static let xlWidth: CGFloat = 1300
    var tier: Tier {
        width >= Self.xlWidth ? .xl : (width >= Self.largeWidth ? .large : (wide ? .medium : .compact))
    }
    /// 左右边距（S5：80·s；iPhone 至少 20）
    var margin: CGFloat { max(20, (width * 80 / 1920).rounded()) }
    /// 卡与卡的间距：折起至少 18、展开至少 24（留白分组：F3、F12）
    var gutter: CGFloat { max(wide ? 24 : 18, (width * 48 / 1920).rounded()) }
    /// 排与排之间（T24「行距至少 100」按比例缩，再给标题留位：F12）。用户要求「保持一定的留白，整个界面看上去不会拥挤」：
    /// 折起 / 手机 48 → 56（高的大卡、编辑推荐之间以前读着像一整面墙）；
    /// 展开时按屏高定（约屏高的 8.5%，56–62）：展开横拿只有六百多点高，一屏要看得到不止一排；
    /// 展开竖拿也不比横拿松太多（以前按宽算是 66，比横拿的 55 还大：用户要求展开竖拿的间距也要合适）。
    /// 没给高的页（搜索：键盘弹出来版面不跟着变）也按 62 封顶，不会比别的页松一截（以前 iPad 上是 75）
    var shelfGap: CGFloat {
        let byWidth = max(wide ? 56 : 52, (width * 120 / 1920).rounded() + (wide ? 24 : 32))
        guard wide else { return byWidth }
        let cap = height > 0 ? clamp((height * 0.085).rounded(), 56, 62) : 62
        return min(byWidth, cap)
    }
    /// 分区标题到那一排卡（排自己上下还有 4 点给按下去的回弹：看到的是 18 / 22）
    var titleGap: CGFloat { wide ? 18 : 14 }
    /// 标题到一张卡、一块列表（不是横排的 DSShelf，没有那 4 点）：看上去和标题到一排卡一样远
    var blockTitleGap: CGFloat { titleGap + 4 }
    /// 同一节里的两排（全部影片一年里的「电影」「剧集」）：比标题到卡远一倍多，看得出下一个标题管的是下一排（F12）
    var subsectionGap: CGFloat { wide ? 40 : 32 }
    /// 网格的行距：比卡与卡的左右间距宽一些（T24：竖着的间距大于横着的），大卡带色条的网格不会连成一条
    var gridRowGap: CGFloat { gutter + (wide ? 10 : 8) }
    /// 大标题到页面第一块、页面最底下留多少（各页以前各写各的：4、8、12 / 40、44、48）
    var pageTop: CGFloat { titleGap }
    var pageBottom: CGFloat { shelfGap }

    /// 竖版海报宽：折起一排两张半；展开约 124–190 点（屏宽的 15%），Duo 展开竖拿四张多、横拿五张半（S6、S8）。
    /// 只看宽：各页（有没有导航栏、键盘弹没弹出来）同一种卡一样大
    var posterWidth: CGFloat {
        guard wide else { return cardWidth(visible: width < 500 ? 2.6 : 4.4) }
        return fit(target: clamp(width * 0.15, 124, 190), min: 112)
    }
    /// 主页四个分类区（动画片区 …）的竖版海报：比别处大一成；展开时也按 fit 排，最后露出下一张一截
    /// （以前直接 × 1.1：iPad 竖拿 5 张刚好排到右边 10 点处、第 6 张一点不露，右边挤着、看不出还能往右滑：S8）
    var categoryPosterWidth: CGFloat {
        guard wide else { return posterWidth }
        return fit(target: (posterWidth * 1.1).rounded(.down), min: posterWidth)
    }
    /// 16:9 卡宽（继续观看、资料库、预告片）：折起一张多一点；展开约 283–400 点（屏宽的 36%），Duo 展开两张半（S6）
    var wideCardWidth: CGFloat {
        guard wide else { return cardWidth(visible: width < 500 ? 1.15 : 2.2) }
        return fit(target: clamp(width * 0.36, 283, 400), min: 250)
    }
    /// 年份那两排的预告片卡：16:9 画面下面还有一行小海报 + 字标 + 片名 + 灰字 +「查看」——
    /// 展开时约 320–420 点，至少 270（窄于 300 时那一行收紧：YearTrailerCard），片名不再只剩两三个字
    /// （用户截图：展开横拿时卡只有 229 点，片名、季数都被截断）。展开竖拿一屏两张多（约 275 点），
    /// 不是一张半的大卡（iPad mini 竖拿的截图里一张半的年份卡太大、下面那一行空出一大截）
    var trailerCardWidth: CGFloat {
        guard wide else { return wideCardWidth }
        return fit(target: clamp(width * 0.38, 320, 420), min: 270, aspect: 9.0 / 16, extra: 82)
    }
    /// 精选卡（带底栏的 5:4 大卡）：折起「一屏一张多一截」再大 30%（用户要求）；
    /// 展开约 340–460 点（底栏里小海报、片名、「Cuven 独占 · 类型」、「查看」放得下）
    var featureCardWidth: CGFloat {
        guard wide else { return (cardWidth(visible: width < 500 ? 1.3 : 2.3) * 1.3).rounded(.down) }
        return fit(target: clamp(width * 0.4, 340, 460), min: 320, aspect: 0.8)
    }
    /// 精选电影的大竖卡（3 : 4，用户要求「整个精选电影区使用大卡片设计」，照 Apple TV「What We're Watching」）：
    /// 折起和精选卡同宽（一屏一张、露出下一张一截，约 337 点）；展开按目标宽排（屏宽 30%，280–400），卡高不过屏高的 60%
    var bigCardWidth: CGFloat {
        guard wide else { return featureCardWidth }
        return fit(target: clamp(width * 0.3, 280, 400), min: 260, aspect: 4.0 / 3)
    }
    /// 片段合集的竖卡（9 : 16，用户要求，照 Apple TV「Explore Clip Collections」）：折起一屏两张多一截（约 140 点）；
    /// 展开约 150–220 点（屏宽的 19%），卡高不过屏高的 60%
    var clipCardWidth: CGFloat {
        guard wide else { return cardWidth(visible: width < 500 ? 2.4 : 3.6) }
        return fit(target: clamp(width * 0.19, 150, 220), min: 140, aspect: 16.0 / 9)
    }
    /// 长文案的分集卡：比原来的方卡宽 30%、高不变（1.3 : 1；用户要求），折起约 222 点；展开约 260–364 点
    var episodeTallCardWidth: CGFloat {
        guard wide else { return (cardWidth(visible: width < 500 ? 1.9 : 2.9) * 1.3).rounded(.down) }
        return fit(target: clamp(width * 0.34, 260, 364), min: 247)
    }
    /// 详情页「简介」那一排卡：折起一张多一截（Apple TV 的简介卡约占屏宽七成）；展开约 260–380 点
    var aboutCardWidth: CGFloat {
        guard wide else { return cardWidth(visible: width < 500 ? 1.4 : 2.4) }
        return fit(target: clamp(width * 0.32, 260, 380), min: 240)
    }

    /// 一屏看得见 visible 张（整数部分完整、小数部分是露出来的那一截）时每张多宽
    func cardWidth(visible v: CGFloat) -> CGFloat {
        let full = max(1, v.rounded(.down))
        return ((width - margin - full * gutter) / max(1, v)).rounded(.down)
    }

    /// 展开时一排卡多宽（D2、S6、S8）：一屏放 n 张整的、再露出下一张的一截，
    /// 在所有放法里挑卡宽最接近 target、又不小于 min 的那种。
    /// 露出的那一截先只在 0.15 到 1/2 张里挑（大卡露一小截，和折起时一张多一点的大卡一样；小卡露得多些）：
    /// 看得出是「还能往右滑」，不会露出四分之三张、像被截断了（用户要求：展开竖拿时卡片要合适）；排不下才放宽到 0.85 张。
    /// aspect（卡高 ÷ 卡宽）和 extra（画面下面的字那一截）给了的话：矮的屏上一张卡连字不超过屏高的 60%
    func fit(target: CGFloat, min floor: CGFloat, aspect: CGFloat = 0, extra: CGFloat = 0) -> CGFloat {
        var target = target, floor = floor
        if aspect > 0, height > 0 {
            let cap = max(120, (height * 0.6 - extra) / aspect)
            target = min(target, cap)
            floor = min(floor, cap)
        }
        let avail = width - margin
        var widest: CGFloat = 0
        for (lo, hi) in [(CGFloat(0.15), CGFloat(0.5)), (0.15, 0.85)] {
            var best: CGFloat = 0, bestErr = CGFloat.infinity
            for n in 1...12 {
                let room = avail - CGFloat(n) * gutter
                guard room > 0 else { break }
                let w = min(room / (CGFloat(n) + lo), max(room / (CGFloat(n) + hi), target))
                widest = max(widest, w)
                guard w >= floor else { continue }
                if abs(w - target) < bestErr { bestErr = abs(w - target); best = w }
            }
            if best > 0 { return best.rounded(.down) }
        }
        return widest.rounded(.down)
    }

    private func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { min(hi, max(lo, v)) }

    /// 网格：一行整数张，左右都是边距（年份页、清单、搜索、文件夹）。折起 3 / 4 张；展开按海报的目标宽排。
    /// 大屏（iPad 横拿、Pro 13）海报不再越放越大：大档约 165 点（一行 6–7 张）、特大档约 150 点（一行 7–8 张），一屏看得到更多
    func gridColumns() -> Int {
        guard wide else { return width < 500 ? 3 : 4 }
        let target: CGFloat = tier == .xl ? 150 : (tier == .large ? 165 : clamp(width * 0.15, 124, 190))
        var best = 4, bestErr = CGFloat.infinity
        for n in 3...10 {
            let err = abs(cardWidth(columns: n) - target)
            if err < bestErr { bestErr = err; best = n }
        }
        return best
    }
    func gridCardWidth() -> CGFloat { cardWidth(columns: gridColumns()) }

    /// 一行正好 n 张、左右都是边距时每张多宽
    func cardWidth(columns n: Int) -> CGFloat {
        let c = CGFloat(max(1, n))
        return ((width - margin * 2 - (c - 1) * gutter) / c).rounded(.down)
    }
}

// MARK: - 文字（F15–F19：系统文字样式；设计轮 1：同一种角色只用一种字、一种颜色）

extension Font {
    /// 分区标题（设计轮 1）：Title 2 粗体，折起、展开一样（App Store、游戏 App 的分区标题）。
    /// 以前折起是 Title 3 半粗，详情页的组名却是 Title 2 粗体：同一页上「简介」「预告片」「剧照」「影片详细信息」两种标题交替出现
    static let dsSectionTitle: Font = .title2.bold()
    /// 大一级的分区标题：只给主页年份那两排「2026 ›」（折起 Title 1、展开 Large Title，粗体：S4 展开时上一级）
    static func dsShowcaseTitle(wide: Bool) -> Font { wide ? .largeTitle.bold() : .title.bold() }
    /// 分区标题下面那一行灰字（「今年上映的新片与新剧」「向左滑动查看更多」）：Body 常规，不再一个 Title 3、一个 Headline 半粗
    static let dsSectionSubtitle: Font = .body
    /// 压在画面上的大号展示标题（「编辑推荐」「精选电影」）：字的大小跟着那一块画面走，所以是定值
    static func dsDisplay(wide: Bool) -> Font { .system(size: wide ? 44 : 36, weight: .heavy) }
    /// 三行以上的正文（简介、关于）：松一点的行距，中文长段落读起来不串行（F21）
    static let dsReading: Font = .body.leading(.loose)
}

/// 字的颜色（设计轮 1）：深色页面和画面上都是白字，层级靠透明度分三级，同一种角色用同一级（F18）。
/// 以前同是「第二行」的灰字有 0.55、0.6、0.62、0.72、0.78、0.8、0.85 七种
enum DSInk {
    /// 次一级：一行信息（「电影 · 2026 · 科幻」）、卡和面板上的第二行（「2026 · 科幻」「▶ 45 分钟」）、说明
    static let secondary = Color.white.opacity(0.72)
    /// 再轻一级：分区标题下的副标题、标题后的「›」、提示
    static let tertiary = Color.white.opacity(0.55)
}

// MARK: - 形状、底色、取色（设计轮 2（并行·home）：同一种东西同一种圆角、同一种底、同一种取色）

/// 圆角：卡的圆角跟着卡宽走（约卡宽的 5.5%，12–22 点），同样宽的卡一样圆（F12）。
/// 以前同是 16:9、折起 283 点宽的卡，继续观看 12、分集卡 14、年份卡 17 三种；海报（118–190 点）照旧是 12
enum DSRadius {
    static func card(_ width: CGFloat) -> CGFloat { min(22, max(12, (width * 0.055).rounded())) }
    /// 带底条的大卡（精选那排、合集页；照参考图的大圆角）
    static let feature: CGFloat = 28
    /// 面板、底条里的小海报：宽的 20%（40–60 点宽 → 8–12 点）
    static func thumb(_ width: CGFloat) -> CGFloat { (width * 0.2).rounded() }
}

/// 底色：画面没到之前卡的底、深色页面上卡的那圈细边
enum DSFill {
    /// 以前 0.08、0.1、0.11、0.12 四种灰，载入时一排排卡深浅不一
    static let placeholder = Color(white: 0.11)
    /// 以前 6%、8% 两种
    static let hairline = Color.white.opacity(0.08)
}

/// 从画面取的底色（编辑推荐的面板、合集卡的底条同一个算法；以前一个亮度压到 0.2–0.38、一个 0.22–0.42）：
/// 色相照画面，饱和度最多 0.45，亮度 0.2–0.36——白字 9 : 1 以上，72% 的灰字（DSInk.secondary）最亮的黄绿底上也有 4.5 : 1（F30、F72、C58）
enum DSTint {
    static func panel(_ c: UIColor) -> Color? {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard c.getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return nil }
        return Color(hue: Double(h), saturation: Double(min(0.45, s)), brightness: Double(min(0.36, max(0.2, b * 0.7))))
    }
}

/// 面板、卡底条里的小海报（2:3）：同一种圆角（宽的 20%）、同一圈细边、同一团小影子。
/// 以前编辑推荐、年份卡、精选卡、合集卡各写一份（细边 14–16% 白，影子三种，年份卡没有）
struct DSThumb: View {
    let url: URL?
    let width: CGFloat
    var maxPixel: CGFloat = 200

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DSRadius.thumb(width), style: .continuous)
        RemoteImage(url: url, maxPixel: maxPixel)
            .frame(width: width, height: (width * 1.5).rounded())
            .clipShape(shape)
            .overlay(shape.strokeBorder(.white.opacity(0.15), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
            .accessibilityHidden(true)
    }
}

/// 卡和面板上的「查看」胶囊：只是样子（整张卡才是那颗按钮，点按区是整张卡：F74），不单独念给旁白。
/// 以前四处各写一份：高 30 / 32、两边 12 / 16 / 18、底 12% / 18% / 20%。
/// 压在画面、取色面板、磨砂条上（onArt）：白字、20% 白的底；在黑的页面上（年份卡下面那一行）：蓝字、12% 白的底
/// （App Store「获取」那样；底再亮，蓝字的对比度反而掉到 4.5 : 1 以下）。宁可片名截断，胶囊不被挤扁
struct DSViewPill: View {
    var onArt = true
    var compact = false

    var body: some View {
        Text("查看")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(onArt ? Color.white : Theme.accent)
            .lineLimit(1)
            .padding(.horizontal, compact ? 12 : 16)
            .frame(minHeight: 32)
            .background(Capsule().fill(Color.white.opacity(onArt ? 0.2 : 0.12)))
            .fixedSize()
            .accessibilityHidden(true)
    }
}

extension View {
    /// 分区标题这种矮的链接（一行 Title 2 约 28 点高）：点按区上下各多 8 点，够 44 点（F74）；
    /// 外面再用 `.padding(.vertical, -8)` 收回去，版面一点不动
    func dsTallHitArea() -> some View {
        padding(.vertical, 8).contentShape(Rectangle())
    }
}

// MARK: - 分区：标题 + 一排

/// 分区标题的字（设计轮 1：全 App 的分区标题、组名都是它，只有两级）：标题、有去处时一个「›」、可选的一行副标题。
/// 只管字；点不点、左右边距由外面那一层管（NavigationLink、Button）
struct DSSectionLabel: View {
    let title: String
    var subtitle: String? = nil
    var chevron = false
    /// 大一级（主页年份那两排）
    var showcase = false
    var wide = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: showcase ? 8 : 6) {
                Text(title)
                    .font(showcase ? .dsShowcaseTitle(wide: wide) : .dsSectionTitle)
                    .foregroundStyle(.white)
                if chevron {
                    // 「›」跟着标题的大小走，颜色退一级（以前有的 15 点、有的 20 点，灰度四种）
                    Image(systemName: "chevron.forward")
                        .font((showcase ? Font.title2 : Font.title3).weight(.semibold))
                        .foregroundStyle(DSInk.tertiary)
                        .accessibilityHidden(true)
                }
                Spacer(minLength: 0)
            }
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.dsSectionSubtitle)
                    .foregroundStyle(DSInk.tertiary)
            }
        }
    }
}

/// 分区标题（F2：和卡片同一条左边线；F86：不全大写）。有去处时后面一个「›」，整行可点
struct DSShelfTitle: View {
    let title: String
    let metrics: DSMetrics
    var route: Route? = nil

    var body: some View {
        let label = DSSectionLabel(title: title, chevron: route != nil)
            .padding(.horizontal, metrics.margin)
            .accessibilityAddTraits(.isHeader)

        if let route {
            // 设计轮 2：点按区够 44 高（F74），版面不变
            NavigationLink(value: route) { label.dsTallHitArea() }
                .buttonStyle(PressableStyle(scale: 0.98))
                .padding(.vertical, -8)
                .accessibilityIdentifier("section-\(title)")
        } else {
            label
        }
    }
}

/// 一排卡（T23：只用标准的横排；S8：卡停在左侧边线上，右边露出下一张的一截）。
/// 卡不放大，所以上下只留按下去时略缩的那一点空
struct DSShelf<Content: View>: View {
    let metrics: DSMetrics
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: metrics.gutter) { content() }
                .scrollTargetLayout()
                .padding(.vertical, 4)
        }
        .dsBleedRow(metrics)
        .scrollTargetBehavior(.viewAligned)
        .scrollClipDisabled()
    }
}

extension View {
    /// 横着的一排（用户要求：所有元素都能越过安全区）：滚动区一直铺到两侧安全区底下（iPhone Duo 侧边那一列），
    /// 卡滑过去时从那一列底下过、不在安全区边上被切掉，在那一列上也能滑；第一张仍停在左边线上，最后一张能滑回安全区里
    func dsBleedRow(_ m: DSMetrics) -> some View {
        self
            .contentMargins(.leading, m.margin + m.leadingInset, for: .scrollContent)
            .contentMargins(.trailing, m.margin + m.trailingInset, for: .scrollContent)
            .padding(.leading, -m.leadingInset)
            .padding(.trailing, -m.trailingInset)
    }
}

/// 一个分区 = 标题 + 一排；分区之间只靠留白分开（F3、F12）
struct DSSection<Content: View>: View {
    let title: String
    let metrics: DSMetrics
    var route: Route? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.titleGap) {
            DSShelfTitle(title: title, metrics: metrics, route: route)
            content()
        }
    }
}

// MARK: - 画面

/// 卡里的画面视差：画面比卡宽一点，随卡在排里的位置往反方向挪几点（S12：约 2%、几乎觉察不到 F61）。
/// 只挪画面、不缩放、不改明暗——卡本身在排里一动不动
struct DSParallaxArt: View {
    let url: URL?
    let metrics: DSMetrics
    let size: CGSize
    /// 解码后的处理：分集卡、预告片卡底部的渐进式模糊
    var effect: ImageEffect = .none
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let travel = reduceMotion ? 0 : (size.width * 0.02).rounded()
        let keyline = metrics.margin
        let span = size.width + metrics.gutter
        Color(white: 0.11)
            .overlay {
                RemoteImage(url: url, maxPixel: size.width * 3, placeholder: .clear, effect: effect)
                    .frame(width: size.width + travel * 2, height: size.height)
                    .visualEffect { c, proxy in
                        // 卡在左边线右边（还没到）时画面偏左，滑过以后偏右：像一层在后面的画
                        let x = proxy.frame(in: .scrollView(axis: .horizontal)).minX + travel
                        let t = max(-1, min(1, (x - keyline) / max(1, span)))
                        return c.offset(x: -t * travel)
                    }
            }
            .frame(width: size.width, height: size.height)
            .clipped()
    }
}

/// 竖版画面上压的字标：画面本身没有片名（Apple TV 的无字主视觉、TMDB 的纯净海报）时，卡靠它认出是哪一部（T20）。
/// 底部一层渐暗保证对比度（F34、C58）；所有卡的字标一样高（卡高的 16%），太宽的按卡宽的 78% 收（统一的视觉重量：F12）
struct DSPosterLogo: View {
    let logo: URL
    let size: CGSize
    var title: String? = nil

    var body: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(stops: [
                .init(color: .clear, location: 0.5),
                .init(color: .black.opacity(0.65), location: 1),
            ], startPoint: .top, endPoint: .bottom)
            LogoImage(url: logo, height: (size.height * 0.16).rounded(), alignment: .center,
                      fallback: title, maxWidth: (size.width * 0.78).rounded())
                .padding(.horizontal, (size.width * 0.11).rounded())
                .padding(.bottom, (size.height * 0.07).rounded())
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// 横版画面上压的字标：左下，高为卡高的 22%、宽不超过卡宽的一半；左下角一团渐暗托住它（F34）
struct DSWideLogo: View {
    let logo: URL
    let size: CGSize
    var title: String? = nil

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(stops: [
                .init(color: .clear, location: 0.35),
                .init(color: .black.opacity(0.6), location: 1),
            ], startPoint: .top, endPoint: .bottom)
            LogoImage(url: logo, height: (size.height * 0.22).rounded(), alignment: .leading,
                      fallback: title, maxWidth: (size.width * 0.5).rounded())
                .padding(.leading, (size.width * 0.06).rounded())
                .padding(.bottom, (size.height * 0.1).rounded())
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - 卡（只有画面：无字主视觉 + 字标，或本来就印着片名的海报。片名只给旁白念：F75）

/// 竖版海报（2:3）。logo：画面没有片名时压在下面的字标
struct DSPosterLockup: View {
    let art: URL?
    let title: String
    /// 只给旁白（卡上不写字）
    var subtitle: String? = nil
    let metrics: DSMetrics
    var width: CGFloat? = nil
    var logo: URL? = nil

    var body: some View {
        let w = width ?? metrics.posterWidth
        let h = (w * 1.5).rounded()
        // 设计轮 2：圆角取 DSRadius.card（海报这么宽仍是 12）
        let shape = RoundedRectangle(cornerRadius: DSRadius.card(w), style: .continuous)
        DSParallaxArt(url: art, metrics: metrics, size: CGSize(width: w, height: h))
            .overlay {
                if let logo { DSPosterLogo(logo: logo, size: CGSize(width: w, height: h), title: title) }
            }
            .clipShape(shape)
            .frame(width: w, height: h)
            .contentShape(shape)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel([title, subtitle].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "，"))
    }
}

/// 16:9 卡：画面 + 左下字标；可选进度条（F36：进度用形状表达，不只靠颜色）。
/// 分集、预告片的卡是下面的 DSMediaCard（字压在渐进式模糊上）
struct DSWideLockup: View {
    let art: URL?
    let title: String
    var subtitle: String? = nil
    var progress: Double? = nil
    let metrics: DSMetrics
    var width: CGFloat? = nil
    var logo: URL? = nil

    var body: some View {
        let w = width ?? metrics.wideCardWidth
        let h = (w * 9 / 16).rounded()
        VStack(alignment: .leading, spacing: 10) {
            DSParallaxArt(url: art, metrics: metrics, size: CGSize(width: w, height: h))
                .overlay {
                    if let logo {
                        DSWideLogo(logo: logo, size: CGSize(width: w, height: h), title: title)
                    }
                }
                .overlay(alignment: .bottom) {
                    if let p = progress, p > 0.01 {
                        // 进度：底部一条细的胶囊（F36），上面一颗液态玻璃的百分比气泡（用户要求），尖角指着看到的地方。
                        // 气泡一直贴着进度条（用户要求「百分比遮挡字标没关系，因为是透明的」）：以前有字标时浮到字标上沿上面，
                        // 两行的字标一高，气泡离进度条一大截，尖角指的不知道是哪儿
                        DSPercentProgress(value: p)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 10)
                    }
                }
                // 设计轮 2：12 → DSRadius.card（折起 283 点宽 16），和同样宽的年份卡、分集卡一样圆
                .clipShape(RoundedRectangle(cornerRadius: DSRadius.card(w), style: .continuous))
        }
        .frame(width: w, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel)
    }

    /// 旁白：片名，剩余时间，已看百分之几
    private var spokenLabel: String {
        var parts: [String] = [title]
        if let s = subtitle, !s.isEmpty { parts.append(s) }
        if let p = progress, p > 0.01 { parts.append("已看 \(DSPercentProgress.percent(p))%") }
        return parts.joined(separator: "，")
    }
}

/// 继续观看的进度（用户要求「添加一个液态玻璃百分比进度条显示器」）：底部一条 4 点高的细胶囊，
/// 走过的那一段白色；上面一颗液态玻璃的小气泡写着「32%」，底下一个小尖角指着看到的那个点。
/// 气泡在两头不出界（靠边时气泡停在边上，尖角照样指着真正的位置）；气泡和尖角是一个形状，玻璃连成一整块
struct DSPercentProgress: View {
    let value: Double
    /// 气泡的尖角离进度条上沿多高
    var lift: CGFloat = 3

    static func percent(_ v: Double) -> Int { Int((min(1, max(0, v)) * 100).rounded()) }

    var body: some View {
        let p = min(1, max(0, value))
        GeometryReader { g in
            let w = g.size.width
            let x = w * p
            let bw = DSProgressBubble.width
            let left = min(max(x - bw / 2, 0), max(0, w - bw))
            Capsule()
                .fill(Color.white.opacity(0.3))
                .overlay(alignment: .leading) {
                    Capsule().fill(Color.white).frame(width: max(4, x))
                }
                .overlay(alignment: .bottomLeading) {
                    DSProgressBubble(text: "\(Self.percent(p))%", tailX: x - left)
                        .offset(x: left, y: -(g.size.height + lift))
                }
        }
        .frame(height: 4)
        .animation(.snappy(duration: 0.3), value: lift)
        .accessibilityHidden(true)
    }
}

/// 百分比气泡：液态玻璃（iOS 26 glassEffect），胶囊 + 底下的小尖角
struct DSProgressBubble: View {
    let text: String
    /// 尖角在气泡里的横向位置（从气泡左边算）
    let tailX: CGFloat

    static let width: CGFloat = 46
    static let height: CGFloat = 22
    static let tail: CGFloat = 5

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: Self.width, height: Self.height)
            .padding(.bottom, Self.tail)
            .glassEffect(.regular, in: DSBubbleShape(tailX: tailX, tail: Self.tail))
            .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
            // 气泡是定死大小的：字放大也不撑破
            .dynamicTypeSize(...DynamicTypeSize.xLarge)
    }
}

/// 胶囊 + 底边一个朝下的小尖角（合成一个形状：玻璃不会在接缝处断开）
struct DSBubbleShape: Shape {
    var tailX: CGFloat
    var tail: CGFloat

    var animatableData: CGFloat {
        get { tailX }
        set { tailX = newValue }
    }

    func path(in r: CGRect) -> Path {
        let h = max(1, r.height - tail)
        let body = Path(roundedRect: CGRect(x: r.minX, y: r.minY, width: r.width, height: h),
                        cornerRadius: h / 2, style: .continuous)
        // 尖角不进圆头那一段：靠边时贴着圆头的内侧
        let tx = min(max(r.minX + tailX, r.minX + h / 2), r.maxX - h / 2)
        var tri = Path()
        tri.move(to: CGPoint(x: tx - tail, y: r.minY + h - 1))
        tri.addLine(to: CGPoint(x: tx, y: r.maxY))
        tri.addLine(to: CGPoint(x: tx + tail, y: r.minY + h - 1))
        tri.closeSubpath()
        return Path(body.cgPath.union(tri.cgPath))
    }
}

// MARK: - 分集卡 / 预告片卡（Apple TV 的样子：字压在渐进式模糊上）
//
// 16:9、圆角；画面底部一段渐进式模糊（上半张清楚，往下越来越糊：ImageEffect.bottomBlur，Core Image 算一次、缓存），
// 再压一层很淡的暗（F34、C58：亮画面上白字也看得清）。两行白字直接压在模糊上：
// 标题（Headline，一行，放不下截断）和「▶ 45 分钟」（看到一半：▶ + 一小段进度条 + 剩余时间：F36 进度用形状表达）；
// 第二行右边一颗「•••」系统菜单（C45：更多操作收进菜单；点按区 44 点：F74）。整张卡点一下就放（C88）；
// 按下时整张卡连同「•••」一起微缩、略压暗（和别的卡同一个手感）

struct DSMediaCard<MenuItems: View>: View {
    let art: URL?
    let title: String
    /// 第二行的字：「45 分钟」「剩余 12 分钟」「2 分钟」「预告片」
    var detail: String? = nil
    /// 第二行前面那个小符号：默认 ▶；剧照卡是一摞照片（和预告片同一排，用户要求合成一组）
    var glyph: String = "play.fill"
    /// 看到一半：第二行在 ▶ 后面先放一小段进度条
    var progress: Double? = nil
    /// 长文案的样子（1.3 : 1 的卡，用户要求：短文案、长文案两种卡）：标题上面一行小字（「第 2 集」），下面两行简介
    var tall = false
    var kicker: String? = nil
    var overview: String? = nil
    let metrics: DSMetrics
    var width: CGFloat? = nil
    /// 整张卡那颗按钮的无障碍标识（UI 测试用）
    var identifier: String = ""
    let action: () -> Void
    @ViewBuilder var menu: () -> MenuItems

    @State private var pressed = false

    var body: some View {
        let w = width ?? (tall ? metrics.episodeTallCardWidth : metrics.wideCardWidth)
        // 长文案的卡 1.3 : 1（用户要求：宽 30%、高不变；剧照是 16:9，也比方卡少裁两边）
        let h = tall ? (w / 1.3).rounded() : (w * 9 / 16).rounded()
        // 圆角跟着卡宽走（参考图那种大圆角；方卡按 1.4 倍宽算，和 16:9 卡看着一样圆）。
        // 设计轮 2：4.5%（14–22）→ 全 App 同一个 DSRadius.card（5.5%，12–22）：折起 16:9 卡 14 → 16，和继续观看、年份卡一样
        let radius: CGFloat = DSRadius.card(tall ? w * 1.4 : w)
        // 字离左、下两边的距离；「•••」的点按区按它摆，三个点的右缘和字的边线对齐
        let pad: CGFloat = metrics.wide ? 18 : 14
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack(alignment: .bottomTrailing) {
            Button(action: action) {
                ZStack(alignment: .bottomLeading) {
                    DSParallaxArt(url: art, metrics: metrics, size: CGSize(width: w, height: h), effect: tall ? .bottomBlurTall : .bottomBlur)
                    LinearGradient(stops: tall ? DSMediaCardStyle.shadeTall : DSMediaCardStyle.shade, startPoint: .top, endPoint: .bottom)
                    Group {
                        if tall { longCopy } else { shortCopy }
                    }
                    // 字只在模糊那一段里：特大字号时也不冲出去
                    .dynamicTypeSize(...(tall ? DynamicTypeSize.large : DynamicTypeSize.xLarge))
                    .padding(.horizontal, pad)
                    .padding(.bottom, pad - 2)
                    .frame(width: w, alignment: .leading)
                }
                .frame(width: w, height: h)
                .clipShape(shape)
                .contentShape(shape)
            }
            .buttonStyle(DSPressReporting(pressed: $pressed))
            .accessibilityLabel([title, detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "，"))
            .accessibilityIdentifier(identifier)

            Menu {
                menu()
            } label: {
                Image(systemName: "ellipsis")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(DSInk.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("更多")
            .padding(.trailing, pad - 14)
            .padding(.bottom, pad - 14)
        }
        .frame(width: w, height: h)
        .scaleEffect(pressed ? 0.96 : 1)
        .brightness(pressed ? -0.06 : 0)
        .animation(.spring(response: 0.28, dampingFraction: 0.68), value: pressed)
    }

    /// 短文案：标题一行 +「▶ 45 分钟」
    private var shortCopy: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.white)
                .lineLimit(1)
            detailRow(glyph: true)
        }
    }

    /// 长文案（参考图）：「第 2 集」→ 集名 → 两行简介（用户要求折起来；整段在长按的预览里）→「42 分钟」
    private var longCopy: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let kicker, !kicker.isEmpty {
                Text(kicker)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(DSInk.secondary)
                    .lineLimit(1)
            }
            Text(title)
                .font(.headline)
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.top, 1)
            if let overview, !overview.isEmpty {
                Text(overview)
                    .font(.subheadline)
                    .foregroundStyle(DSInk.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 3)
            }
            detailRow(glyph: false)
                .padding(.top, 8)
        }
    }

    /// 最后一行：（▶）+ 看到一半的一小段进度条 + 片长 / 剩余；右边让给「•••」
    private func detailRow(glyph: Bool) -> some View {
        HStack(spacing: 6) {
            if glyph {
                Image(systemName: self.glyph)
                    .font(.caption2)
            }
            if let p = progress, p > 0.01 {
                DSMiniProgress(value: p)
                    .frame(width: 32, height: 4)
            }
            if let detail, !detail.isEmpty {
                Text(detail)
                    .lineLimit(1)
            }
        }
        .font(.subheadline)
        // 片长、剩余时间用等宽数字：一排卡的「45 分钟」「剩余 12 分钟」数字宽窄一致，看完回来数字变了也不跳
        .monospacedDigit()
        .foregroundStyle(DSInk.secondary)
        .padding(.trailing, 30)
    }
}

// MARK: - 精选卡（Apple TV 的精选：一张大号竖卡）
//
// 3:4、大圆角，一圈很细的亮边（深色页面上卡的轮廓）；画面铺满（ImageEffect.featureCard：裁成 3:4，下半段渐进式模糊），
// 再压一层由透明到暗的渐变（F34、C58）；左下一列：字标（没有就是粗体片名）→「★ 为您的口味量身定制的内容」（一颗小黑圆章 + 白字）
// →「Cuven 独占」（灰字）。卡下不写字（T20）

struct DSFeatureCard: View {
    let art: URL?
    let logo: URL?
    let title: String
    /// 白字那一行（小黑圆章后面）
    let kicker: String
    /// 灰字那一行
    let line: String
    let width: CGFloat

    var body: some View {
        let w = width
        let h = (w * 4 / 3).rounded()
        let radius = max(16, min(24, (w * 0.05).rounded()))
        let pad = max(16, (w * 0.055).rounded())
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack(alignment: .bottomLeading) {
            Color(white: 0.11)
            RemoteImage(url: art, maxPixel: w * 3, placeholder: .clear, effect: .featureCard)
                .frame(width: w, height: h)
            LinearGradient(stops: DSFeatureCardStyle.shade, startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 14) {
                if let logo {
                    LogoImage(url: logo, height: max(36, min(64, (w * 0.14).rounded())), alignment: .leading,
                              fallback: title, maxWidth: (w * 0.7).rounded())
                } else {
                    Text(title)
                        .font(.title.bold())
                        .foregroundStyle(.white)
                        .lineLimit(2)
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(Color.black.opacity(0.85), in: Circle())
                        Text(kicker)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }
                    if !line.isEmpty {
                        Text(line)
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                }
                .font(.body)
            }
            // 字收在下面那一段暗里：特大字号时也不往上冲
            .dynamicTypeSize(...DynamicTypeSize.xLarge)
            .padding(pad)
        }
        .frame(width: w, height: h)
        .clipShape(shape)
        .overlay { shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 1) }
        .contentShape(shape)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([title, kicker, line].filter { !$0.isEmpty }.joined(separator: "，"))
    }
}

enum DSFeatureCardStyle {
    /// 下半段的暗：离顶 40% 开始，到底 62%；alpha 走 smoothstep
    static let shade: [Gradient.Stop] = (0...8).map { i in
        let t = Double(i) / 8
        let s = t * t * (3 - 2 * t)
        return Gradient.Stop(color: .black.opacity(0.62 * s), location: 0.4 + 0.6 * t)
    }
}

enum DSMediaCardStyle {
    /// 长文案方卡上的淡暗：离顶 36% 开始，到底 44%
    static let shadeTall: [Gradient.Stop] = (0...8).map { i in
        let t = Double(i) / 8
        let s = t * t * (3 - 2 * t)
        return Gradient.Stop(color: .black.opacity(0.44 * s), location: 0.36 + 0.64 * t)
    }
    /// 模糊那一段上的一层淡暗：离顶 42% 开始，到底 36%；alpha 走 smoothstep，OLED 上不起条带
    static let shade: [Gradient.Stop] = (0...8).map { i in
        let t = Double(i) / 8
        let s = t * t * (3 - 2 * t)
        return Gradient.Stop(color: .black.opacity(0.36 * s), location: 0.42 + 0.58 * t)
    }
}

/// 第二行里那一小段进度条（底 30% 白、值 90% 白）
struct DSMiniProgress: View {
    let value: Double

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.3))
                Capsule().fill(.white.opacity(0.9))
                    .frame(width: max(3, g.size.width * min(1, max(0, value))))
            }
        }
        .accessibilityHidden(true)
    }
}

/// 只把「按下了没有」报出去：缩放、压暗由卡片自己做（连同右下角那颗「•••」一起，不然点卡时只有画面缩、点点不动）
struct DSPressReporting: ButtonStyle {
    @Binding var pressed: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, p in pressed = p }
    }
}

// MARK: - 按钮（S17：主操作是白色胶囊黑字——tvOS 聚焦的按钮；次操作是半透明材质。都至少 44 高：F74）

struct DSPlayButtonStyle: ButtonStyle {
    /// 按自然宽度放大几倍（头图上的「播放」是 1.45：用户要求加宽 45%）；字和图标在中间。
    /// 1 就是原来的样子：按字的宽度，标签自己带了 maxWidth 的（详情页、资料库）照旧拉满
    var widen: CGFloat = 1

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        if widen > 1 {
            let layout = DSWiden(factor: widen)
            layout {
                configuration.label
                    .font(.headline)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 22)
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .modifier(DSPlayChrome(pressed: configuration.isPressed))
        } else {
            configuration.label
                .font(.headline)
                .foregroundStyle(.black)
                .padding(.horizontal, 22)
                .frame(minHeight: 48)
                .modifier(DSPlayChrome(pressed: configuration.isPressed))
        }
    }
}

/// 白色胶囊、按下缩一点。设计轮 2：按压和卡片、分区标题同一个手感（DSMotion.press：略缩到 0.96、略暗 6%），
/// 以前是另一条弹簧（0.3 秒、阻尼 0.8）、按下变半透明
private struct DSPlayChrome: ViewModifier {
    let pressed: Bool

    func body(content: Content) -> some View {
        content
            .background(Color.white, in: Capsule())
            .scaleEffect(pressed ? 0.96 : 1)
            .brightness(pressed ? -0.06 : 0)
            .animation(DSMotion.press, value: pressed)
            .contentShape(Capsule())
    }
}

/// 把唯一的子视图按理想宽度放大 factor 倍（高照旧）：头图上加宽的「播放」
struct DSWiden: Layout {
    var factor: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let s = subviews.first else { return .zero }
        let ideal = s.sizeThatFits(.unspecified)
        return CGSize(width: (ideal.width * max(1, factor)).rounded(), height: ideal.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center,
                              proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

struct DSSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .frame(minHeight: 48)
            .background(.thinMaterial, in: Capsule())
            .environment(\.colorScheme, .dark)
            // 设计轮 2：和「播放」、卡片同一个按压手感（DSMotion.press，略缩略暗）
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .brightness(configuration.isPressed ? -0.06 : 0)
            .animation(DSMotion.press, value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

extension ButtonStyle where Self == DSPlayButtonStyle {
    static var dsPlay: DSPlayButtonStyle { DSPlayButtonStyle() }
}

extension ButtonStyle where Self == DSSecondaryButtonStyle {
    static var dsSecondary: DSSecondaryButtonStyle { DSSecondaryButtonStyle() }
}

// MARK: - 头图（Top Shelf 的全屏轮播：T30–T32、S15–S17）

/// 头图的一页：画面（横 / 竖各一张，按屏幕取）、字标或片名、一行信息、播放与详情
struct DSHeroPage: Identifiable {
    let id: String
    var wideArt: String?
    var tallArt: String?
    var logo: String?
    var title: String
    /// 「电影 · 2025 · 科幻」这样的一行（F84：短、平实）
    var meta: String
    var playTitle: String = "播放"
    var play: () -> Void
    var detail: Route
    /// 这一页的预告片（hls）：TrailerCache 下好了本机那份，这一页的背景就换成它（静音、循环）；没下好就只放画面
    var trailerHLS: String? = nil
}

/// 全屏轮播：一页一部，左右翻。画面单独一层、不跟着页走：换页时旧画面模糊淡出、新画面从模糊里淡入，
/// 不带任何进入方向（用户要求；新画面解码好了才换，不会先闪一下空的）；字和按钮跟着手指左右翻（直接操控：F54）。
/// 没碰它时 7 秒翻一页（页码点那颗胶囊跟着填满），一碰就不再自己翻（S17、F79）；「减弱动态效果」或旁白开着时不自己翻（S17、F59）。
/// 只认真的左右翻页才算「碰过」：竖着滑从头图上开始也照样滚动整页（原来挂的拖动手势会把竖滑吃掉）。
/// 画面铺满整个窗口宽（fullWidth，含 iPhone Duo 侧边那一列：画面在那一列底下平铺过去，F6、S19），
/// 字和按钮留在安全区里（leadingInset / trailingInset，F7）；页码点浮在画面底部（S16）
struct DSHeroCarousel: View {
    let pages: [DSHeroPage]
    let metrics: DSMetrics
    let height: CGFloat
    /// 画面铺多宽（整个窗口，含侧边那一列）；不给就是内容区的宽
    var fullWidth: CGFloat? = nil
    /// 字要躲开的左右安全区
    var leadingInset: CGFloat = 0
    var trailingInset: CGFloat = 0
    @State private var current: String?
    @State private var touched = false
    /// 这一页开始停留的时刻（页码胶囊按它填满）；不自己翻页时是 nil
    @State private var pageStart: Date?
    /// 背景的预告片（用户要求「hero区自动缓存和使用预告片背景」）：只放 TrailerCache 下好的本机那份（主页不为头图从网上拉流），
    /// 第一次要放时才建（别在每次重绘时白建一个播放器）
    @State private var trailer: ShowcaseTrailer?
    @State private var onScreen = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.zoomNamespace) private var zoomNamespace

    private static let interval: Double = 7

    var body: some View {
        let w = fullWidth ?? metrics.width
        let tall = height > w
        let shown = pages.first { $0.id == current } ?? pages.first
        ZStack(alignment: .bottom) {
            // 后面一层：当前这一页的画面 + 渐暗。不接点按——只有「详情」钮进详情页（用户要求：翻页、滑动时不会误进），
            // 详情页仍从这张画面上放大出来、返回时缩回去（F57：这张画面是缩放转场的起点）
            if let shown {
                DSHeroBackdrop(page: shown, tall: tall, width: w, height: height, trailer: trailer)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 0) {
                        ForEach(pages) { p in
                            foreground(p, width: w)
                                .frame(width: w, height: height, alignment: .bottomLeading)
                                .id(p.id)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $current)
                // 翻页按整页宽对齐：不让系统按侧边那一列的安全区给它加内边距，否则每一页都错开一截（F6）
                .contentMargins(.horizontal, 0, for: .scrollContent)
                .ignoresSafeArea(.container, edges: .horizontal)
                .frame(width: w, height: height)
                // 真的左右翻了才算碰过（只是从这里开始竖着滑，不算）
                .onScrollPhaseChange { _, phase in
                    if phase == .interacting && !touched {
                        touched = true
                        pageStart = nil
                    }
                }
                // 窗口变宽 / 变窄（转屏、Duo 折起 / 展开）：每一页跟着变宽，滚到的位置却还停在旧宽度的整数倍上，
                // 不在第一页时这一页会错开一截（iPad 竖拿转横拿后，第二页的字跑到了屏幕中间）。宽度一变就把这一页重新对齐
                .onChange(of: w) { _, _ in
                    guard let id = current ?? pages.first?.id else { return }
                    DispatchQueue.main.async {
                        var t = Transaction()
                        t.disablesAnimations = true
                        withTransaction(t) { proxy.scrollTo(id, anchor: .leading) }
                    }
                }
            }

            if pages.count > 1 {
                // 页码点浮在画面底部、内容区的正中（不算侧边那一列：S16）
                DSPageDots(ids: pages.map(\.id), current: current ?? pages.first?.id,
                           pageStart: pageStart, interval: Self.interval)
                    .padding(.bottom, 18)
                    .offset(x: (leadingInset - trailingInset) / 2)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: w, height: height)
        // 预告片：换页了、这几页的预告片问到了、TrailerCache 刚下好一段，都再看一遍这一页有没有本机那份
        .onAppear {
            trailer?.setVisible(true)
            syncTrailer()
        }
        .onDisappear { trailer?.setVisible(false) }
        .onChange(of: current) { syncTrailer() }
        .onChange(of: trailerSignature) { syncTrailer() }
        .onChange(of: reduceMotion) { syncTrailer() }
        .onReceive(NotificationCenter.default.publisher(for: .cuvenTrailerCached)) { _ in syncTrailer() }
        // 头图滑出屏幕：停（全 App 同一时刻只放一段：TrailerFocus；编辑推荐放起来，这里就停在当前那一帧）
        .onScrollVisibilityChange(threshold: 0.3) { visible in
            onScreen = visible
            trailer?.setCovered(!visible)
        }
        .task(id: [touched, holding]) {
            // 自己翻页：没被碰过、没开「减弱动态效果」和旁白时才翻
            guard !touched, !reduceMotion, !voiceOver, pages.count > 1 else {
                pageStart = nil
                return
            }
            // 这一页的预告片在放：不按 7 秒翻，放完了再翻（advanceAfterTrailer）
            if holding {
                pageStart = nil
                return
            }
            // 先把每一页的画面解码进缓存：换页时新画面马上就有
            for p in pages {
                if let u = TMDBImage.url(tall ? (p.tallArt ?? p.wideArt) : (p.wideArt ?? p.tallArt), "w1280") {
                    _ = await ImagePipeline.shared.image(u, maxPixel: 2000)
                }
            }
            while !Task.isCancelled {
                pageStart = Date()
                try? await Task.sleep(nanoseconds: UInt64(Self.interval * 1_000_000_000))
                guard !Task.isCancelled, !touched else { return }
                let ids = pages.map(\.id)
                let i = ids.firstIndex(of: current ?? ids[0]) ?? 0
                withAnimation(.smooth(duration: 0.8)) { current = ids[(i + 1) % ids.count] }
            }
        }
    }

    /// 这一页的预告片真的出画面了（自己翻页这时停下，等它放完）
    private var holding: Bool {
        guard let t = trailer, t.showing, let p = t.path else { return false }
        return p == (current ?? pages.first?.id)
    }

    private var trailerSignature: [String] { pages.map { $0.id + "|" + ($0.trailerHLS ?? "") } }

    /// 这一页（id 不给就是当前这一页）有本机下好的预告片、又允许自动放（没开「减弱动态效果」、系统「自动播放视频预览」开着、
    /// 不是省流量）：挂上，静音放；不然卸下，停在画面上。只放本机那份：头图不从网上拉流，主页保持轻
    private func syncTrailer(_ id: String? = nil) {
        let key = id ?? current ?? pages.first?.id
        guard let page = pages.first(where: { $0.id == key }) ?? pages.first,
              !reduceMotion, UIAccessibility.isVideoAutoplayEnabled, !NetworkSpeed.dataSaver,
              let hls = page.trailerHLS, let file = TrailerCache.shared.localURL(key: page.id, hls: hls) else {
            if trailer?.path != nil { trailer?.unmount() }
            return
        }
        let t: ShowcaseTrailer
        if let existing = trailer {
            t = existing
        } else {
            t = ShowcaseTrailer()
            trailer = t
        }
        t.onEnd = { advanceAfterTrailer() }
        t.mountLocal(key: page.id, file: file)
        t.setCovered(!onScreen)
    }

    /// 预告片放完：自己翻页的时候翻到下一页（下一页有本机的预告片就接着放它）；不自己翻（碰过、减弱动态效果、旁白、只有一页）就回到起点接着放
    private func advanceAfterTrailer() {
        guard !touched, !reduceMotion, !voiceOver, pages.count > 1 else { return }
        let ids = pages.map(\.id)
        let i = ids.firstIndex(of: current ?? ids[0]) ?? 0
        let next = ids[(i + 1) % ids.count]
        withAnimation(.smooth(duration: 0.8)) { current = next }
        syncTrailer(next)
    }

    /// 前面一层：字标、信息、按钮（左对齐：F1、F2）。字本身不接手势
    private func foreground(_ p: DSHeroPage, width w: CGFloat) -> some View {
        // 字标：所有页一样高，太宽的按屏宽的 45% 收（统一的视觉重量；F12）
        let logoHeight = min(132, max(84, (w * 0.2).rounded()))
        let logoMaxWidth = (w * 0.45).rounded()
        return VStack(alignment: .leading, spacing: 14) {
            // 字标和一行信息合成旁白的一个标题：字标是图，以前旁白只念得出「电影 · 2025 · 剧情」、念不出片名（设计轮 2；F76）
            VStack(alignment: .leading, spacing: 14) {
                if let logo = p.logo, !logo.isEmpty {
                    LogoImage(url: TMDBImage.url(logo, "w500"), height: logoHeight, alignment: .leading,
                              fallback: p.title, maxWidth: logoMaxWidth)
                        .frame(width: logoMaxWidth, height: logoHeight, alignment: .bottomLeading)
                } else {
                    Text(p.title)
                        .font(metrics.wide ? .largeTitle.bold() : .title.bold())
                        .foregroundStyle(.white)
                        .lineLimit(2)
                }
                if !p.meta.isEmpty {
                    Text(p.meta)
                        .font(.subheadline)
                        .foregroundStyle(DSInk.secondary)
                        .lineLimit(1)
                }
            }
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel([p.title, p.meta].filter { !$0.isEmpty }.joined(separator: "，"))
            .accessibilityAddTraits(.isHeader)
            HStack(spacing: 12) {
                // 「播放」比自然宽度宽 45%（用户要求）
                Button(action: p.play) { Label(p.playTitle, systemImage: "play.fill") }
                    .buttonStyle(DSPlayButtonStyle(widen: 1.45))
                    .accessibilityIdentifier("hero-play")
                detailLink(p)
                    .buttonStyle(.dsSecondary)
                    .accessibilityIdentifier("hero-detail")
            }
            .padding(.top, 4)
        }
        // 设计轮 2：字号最大到 xxLarge。再大，加宽 45% 的「继续播放」和「详情」在折起的 Duo 上（可用约 324 点）一行放不下，
        // 「详情」被挤到侧边那一列底下；画面上的字本来就有固定的地方（和分集卡、精选卡一样封顶；F23）
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .padding(.leading, leadingInset + metrics.margin)
        .padding(.trailing, trailingInset + metrics.margin)
        // 下面给页码点留一行（S16）
        .padding(.bottom, pages.count > 1 ? 52 : 32)
        .frame(maxWidth: min(w, leadingInset + metrics.margin + 560), alignment: .leading)
    }

    /// 「详情」推进和点画面同一个目标：详情页同样从这张画面上放大出来（F57）
    @ViewBuilder
    private func detailLink(_ p: DSHeroPage) -> some View {
        if zoomNamespace != nil {
            NavigationLink(value: ZoomTarget(route: p.detail, slot: "hero")) { Text("详情") }
        } else {
            NavigationLink(value: p.detail) { Text("详情") }
        }
    }
}

/// 头图画面当缩放转场的起点：「详情」推进的是同一个 ZoomTarget，详情页就从这张画面上放大出来（F57）
private struct DSHeroZoomSource: ViewModifier {
    let route: Route
    @Environment(\.zoomNamespace) private var ns

    func body(content: Content) -> some View {
        if let ns {
            content.matchedTransitionSource(id: ZoomTarget(route: route, slot: "hero"), in: ns)
        } else {
            content
        }
    }
}

/// 头图画面那一层：当前这一页的画面（换页时模糊淡入：DSBlurFadeImage）+ 顶上浅浅压暗 + 底部渐暗融进页面的黑。
/// 它是「详情」缩放转场的起点（F57）
struct DSHeroBackdrop: View {
    let page: DSHeroPage
    let tall: Bool
    let width: CGFloat
    let height: CGFloat
    /// 头图背景的预告片（挂着这一页的时候画在画面上面，第一帧出来以后淡入；之前一直是画面）
    var trailer: ShowcaseTrailer? = nil

    var body: some View {
        let art = tall ? (page.tallArt ?? page.wideArt) : (page.wideArt ?? page.tallArt)
        ZStack {
            Color.black
            // 竖版画面顶部对齐（用户要求：iPhone Duo 上头图海报用顶部对齐）：折起的 Duo 头图比 2 : 3 的竖图宽，
            // 按宽铺满要裁掉一百多点高，居中裁时上面那一截（人物的头）被切掉；从顶上排，裁掉的都在底下（底下本来就压暗了）。
            // 普通 iPhone 竖图按高铺满、只裁左右，对齐不起作用；横图仍居中
            DSBlurFadeImage(url: TMDBImage.url(art, "w1280"), maxPixel: 2000)
                .frame(width: width, height: height, alignment: tall ? .top : .center)
                .clipped()
            if let trailer, trailer.path == page.id {
                VideoSurface(player: trailer.player, gravity: .resizeAspectFill, background: .clear)
                    .frame(width: width, height: height)
                    .clipped()
                    .opacity(trailer.showing ? 1 : 0)
                    .animation(.easeInOut(duration: 0.8), value: trailer.showing)
                    .allowsHitTesting(false)
            }
            // 顶上浅浅压暗：状态栏和左上的标题停在画面上也看得清（F34）
            LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.22))
            // 底部渐暗，最后融进页面的黑：字和页码点在画面上的对比度靠它（S17、F34、C58）
            LinearGradient(stops: [
                .init(color: .clear, location: 0.42),
                .init(color: .black.opacity(0.5), location: 0.7),
                .init(color: .black.opacity(0.9), location: 0.94),
                .init(color: .black, location: 1),
            ], startPoint: .top, endPoint: .bottom)
        }
        .frame(width: width, height: height)
        .modifier(DSHeroZoomSource(route: page.detail))
    }
}

/// 页码点（照 iOS 的页码控件，用户给的参考图）：当前那颗拉长成胶囊，自动翻页时从左往右填满（满了就翻到下一页）；
/// 别的点半透明，离当前越远越小（远处两三颗逐级缩小），一排不超过 10 颗（S16）。浮在画面上，带一点影子托住（F34）
struct DSPageDots: View {
    let ids: [String]
    let current: String?
    /// 这一页开始停留的时刻；nil 就是不自己翻页（胶囊整颗是白的）
    var pageStart: Date? = nil
    var interval: Double = 7

    var body: some View {
        let list = Array(ids.prefix(10))
        let ci = list.firstIndex(of: current ?? "") ?? 0
        HStack(spacing: 8) {
            ForEach(Array(list.enumerated()), id: \.element) { i, _ in
                let d = abs(i - ci)
                if d == 0 {
                    DSPageCapsule(pageStart: pageStart, interval: interval)
                        .transition(.opacity)
                } else {
                    Circle()
                        .fill(Color.white.opacity(0.5))
                        .frame(width: Self.size(d), height: Self.size(d))
                        .frame(width: 8, height: 8)
                }
            }
        }
        .shadow(color: .black.opacity(0.3), radius: 4, y: 1)
        .animation(.smooth(duration: 0.35), value: ci)
        .accessibilityHidden(true)
    }

    /// 离当前那颗 1–2：8 点；3：6 点；再远：4.5 点
    private static func size(_ d: Int) -> CGFloat { d <= 2 ? 8 : (d == 3 ? 6 : 4.5) }
}

/// 当前那颗：28×8 的胶囊，底 50% 白，白色的那段随这一页停留的时间填满
struct DSPageCapsule: View {
    let pageStart: Date?
    let interval: Double

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: pageStart == nil)) { tl in
            let p = pageStart.map { min(1, max(0, tl.date.timeIntervalSince($0) / interval)) } ?? 1
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.5))
                Capsule().fill(Color.white).frame(width: max(8, 28 * p))
            }
        }
        .frame(width: 28, height: 8)
    }
}

/// 一张铺满的图：换图时旧图模糊淡出、新图从模糊里淡入，不带任何方向；新图解码好了才换（不会先闪一下空的）。
/// 「减弱动态效果」时只淡入淡出、不模糊（F59）
struct DSBlurFadeImage: View {
    let url: URL?
    let maxPixel: CGFloat
    let duration: Double
    @State private var shown: Shown?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Shown: Equatable {
        let url: URL
        let image: UIImage
        /// 按多大取的（尺寸变大了才换更清楚的，见 RemoteImage）
        var pixel: CGFloat
        static func == (a: Shown, b: Shown) -> Bool { a.url == b.url }
    }

    private struct LoadKey: Equatable {
        let url: URL?
        let pixel: Int
    }

    /// 内存里已经有：第一次画就直接是它（回到主页时头图不再淡入一遍）
    init(url: URL?, maxPixel: CGFloat = 1800, duration: Double = 0.9) {
        self.url = url
        self.maxPixel = maxPixel
        self.duration = duration
        if let url, maxPixel >= RemoteImage.minPixel, let hit = ImagePipeline.shared.cached(url, maxPixel: maxPixel) {
            _shown = State(initialValue: Shown(url: url, image: hit, pixel: maxPixel))
        }
    }

    var body: some View {
        ZStack {
            if let s = shown {
                Image(uiImage: s.image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .id(s.url)
                    .transition(reduceMotion ? .opacity : .dsBlurFade)
            }
        }
        // 地址或尺寸变了才取：还没量出尺寸（0）先不取；同一张图尺寸变大了换更清楚的、原地换不再淡入（见 RemoteImage）
        .task(id: LoadKey(url: url, pixel: maxPixel.isFinite ? Int(maxPixel) : 0)) {
            guard let url, maxPixel.isFinite, maxPixel >= RemoteImage.minPixel else { return }
            if let s = shown, s.url == url, s.pixel >= maxPixel * 0.8 { return }
            guard let img = await ImagePipeline.shared.image(url, maxPixel: maxPixel), !Task.isCancelled else { return }
            if shown?.url == url {
                shown = Shown(url: url, image: img, pixel: maxPixel)
            } else {
                withAnimation(.easeInOut(duration: duration)) { shown = Shown(url: url, image: img, pixel: maxPixel) }
            }
        }
    }
}

/// 模糊淡入 / 淡出（不带方向）：出现时从 24 点模糊、全透明到清楚、不透明；消失时反过来
struct DSBlurFade: ViewModifier {
    let on: Bool
    var radius: CGFloat = 24
    /// 不透明的模糊（整张画面：四边不往里渗透明）。字标、文字这种带透明底的要用 false，
    /// 不然透明的地方在淡入那一瞬间被糊成一块黑底（详情页字标「闪一下黑框」就是这个）
    var opaque = true

    func body(content: Content) -> some View {
        content
            .blur(radius: on ? radius : 0, opaque: opaque)
            .opacity(on ? 0 : 1)
    }
}

extension AnyTransition {
    static var dsBlurFade: AnyTransition {
        .modifier(active: DSBlurFade(on: true), identity: DSBlurFade(on: false))
    }

    /// 轻一点的模糊淡入（卡上的图第一次载入）
    static func dsBlurFade(radius: CGFloat) -> AnyTransition {
        .modifier(active: DSBlurFade(on: true, radius: radius), identity: DSBlurFade(on: false, radius: radius))
    }

    /// 带透明底的东西（字标、文字）的模糊淡入：透明的地方保持透明，不出黑框
    static func dsBlurFadeClear(radius: CGFloat = 24) -> AnyTransition {
        .modifier(active: DSBlurFade(on: true, radius: radius, opaque: false),
                  identity: DSBlurFade(on: false, radius: radius, opaque: false))
    }
}

// MARK: - 顶栏的底：渐进式模糊（用户要求：所有顶部导航栏都用渐进式模糊，不允许有硬边界线）

/// 钉在顶上的条、自己画的顶栏用它当底：两层磨砂从上往下淡掉（上面那层更厚、淡得更早），再压一层这一页的颜色同样往下淡——
/// 越往下越清楚，最底下完全透明，没有底线、没有一条硬边。solid：从顶上到这个比例是满的（条上的字和钮压在这一段里，看得清），
/// 下面那一截慢慢淡掉；给它的高要比条本身高出一截（那一截就是淡出去的部分）。
/// 系统的导航栏用系统自己的柔和滚动边缘（`dsSoftTopEdge()`），也是渐进式模糊
struct DSProgressiveBar: View {
    var tint: Color = .black
    var tintOpacity: Double = 0.6
    var solid: CGFloat = 0.55

    var body: some View {
        let s = min(max(solid, 0), 0.95)
        let fade = LinearGradient(stops: [
            .init(color: .black, location: 0),
            .init(color: .black, location: s),
            .init(color: .clear, location: 1),
        ], startPoint: .top, endPoint: .bottom)
        let core = LinearGradient(stops: [
            .init(color: .black, location: 0),
            .init(color: .black, location: s * 0.6),
            .init(color: .clear, location: min(1, s + 0.2)),
        ], startPoint: .top, endPoint: .bottom)
        ZStack {
            Rectangle().fill(.ultraThinMaterial).mask(fade)
            Rectangle().fill(.thinMaterial).mask(core)
            Rectangle().fill(tint).opacity(tintOpacity).mask(fade)
        }
        .environment(\.colorScheme, .dark)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension View {
    /// 系统导航栏底下的滚动边缘一律用柔和的那种（iOS 26 的渐进式模糊）：内容滑到栏下面慢慢糊掉、淡掉，
    /// 不要「硬」的那种（一块实色底 + 一条硬边，用户截图里账户页顶上那一条就是）
    func dsSoftTopEdge() -> some View {
        scrollEdgeEffectStyle(.soft, for: .top)
    }
}
