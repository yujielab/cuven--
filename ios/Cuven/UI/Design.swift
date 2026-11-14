import SwiftUI

// MARK: - 设计系统：按 Apple HIG 收拾过的一套（规则出处见 docs/ios-design.md，编号 F = 基础、T = tvOS、S = 触屏上的 tvOS、D = iPhone Duo）
//
// 原则：内容在前，界面退后（F1、F80、T1）。分组靠留白，不靠描边和底板（F3）；玻璃只给系统栏和少数控件，内容层不用（F38）；
// 字一律用系统文字样式（F15），层级靠字重、字号和 .secondary（F18）；颜色只给一个主操作（F32、F33）。
// 同一套设计随屏幕长大（S1、D2）：折起是它，展开就是更大的它——更大的头图、每排更多的卡、更从容的留白。
// 卡只放画面：无字的主视觉 + 官方字标（没有无字的那张，就用本来就印着片名的海报），卡下不写片名（T20：画面自己说明是哪一部）。
// 卡在排里不放大、不压暗别的卡：滑动时只有画面在卡里极轻地挪一点（S12：约 2%，几乎觉察不到 F61）；按下去略缩，是触感反馈（F55）。
// 打开「减弱动态效果」：视差、自动翻页都停（F59、S24）。

/// 版面尺寸：都从当前宽度算（F9、D4：看宽度和尺寸类别，不看机型）。
/// 边距按 tvOS 的 80（以 1920 宽为准）缩到眼前的宽度、iPhone 至少 20（S3、S5）；卡与卡之间比 tvOS 的 40 再松一些，
/// 排与排之间留足（T24），每排露出下一张的一截，告诉人还能往右滑（S8、I13）
struct DSMetrics {
    let width: CGFloat

    /// 展开的 Duo、iPad、横拿：一排多放几张，字号上一级
    var wide: Bool { width >= 600 }
    /// 左右边距（S5：80·s；iPhone 至少 20）
    var margin: CGFloat { max(20, (width * 80 / 1920).rounded()) }
    /// 卡与卡的间距：折起至少 18、展开至少 24（留白分组：F3、F12）
    var gutter: CGFloat { max(wide ? 24 : 18, (width * 48 / 1920).rounded()) }
    /// 排与排之间（T24「行距至少 100」按比例缩，再给标题留位：F12）
    var shelfGap: CGFloat { max(wide ? 56 : 44, (width * 120 / 1920).rounded() + 24) }
    /// 分区标题到那一排卡
    var titleGap: CGFloat { wide ? 16 : 12 }

    /// 竖版海报宽：折起一排两张半、展开竖拿四张多、横拿六张多——最后那张露出一截（S6、S8）
    var posterWidth: CGFloat { cardWidth(visible: width < 500 ? 2.6 : (width < 800 ? 4.4 : 6.4)) }
    /// 16:9 卡宽：折起一张多一点，展开两张多（竖）/ 三张多（横）（S6）
    var wideCardWidth: CGFloat { cardWidth(visible: width < 500 ? 1.15 : (width < 800 ? 2.2 : 3.3)) }
    /// 精选卡（3:4 的大号竖卡）：折起一屏一张多一截，展开两张多 / 三张多
    var featureCardWidth: CGFloat { cardWidth(visible: width < 500 ? 1.3 : (width < 800 ? 2.3 : 3.4)) }
    /// 长文案的分集卡（方卡）：折起一屏将近两张，展开三张、四张
    var episodeTallCardWidth: CGFloat { cardWidth(visible: width < 500 ? 1.9 : (width < 800 ? 2.9 : 4.1)) }
    /// 详情页「简介」那一排卡：折起一张多一截（Apple TV 的简介卡约占屏宽七成）
    var aboutCardWidth: CGFloat { cardWidth(visible: width < 500 ? 1.4 : (width < 800 ? 2.4 : 3.4)) }

    /// 一屏看得见 visible 张（整数部分完整、小数部分是露出来的那一截）时每张多宽
    func cardWidth(visible v: CGFloat) -> CGFloat {
        let full = max(1, v.rounded(.down))
        return ((width - margin - full * gutter) / max(1, v)).rounded(.down)
    }

    /// 网格：一行整数张，左右都是边距（年份页、清单、搜索、文件夹）
    func gridColumns() -> Int { width < 500 ? 3 : (width < 800 ? 4 : 6) }
    func gridCardWidth() -> CGFloat { cardWidth(columns: gridColumns()) }

    /// 一行正好 n 张、左右都是边距时每张多宽
    func cardWidth(columns n: Int) -> CGFloat {
        let c = CGFloat(max(1, n))
        return ((width - margin * 2 - (c - 1) * gutter) / c).rounded(.down)
    }
}

// MARK: - 文字（F15–F19：系统文字样式；展开时标题上一级，S4）

extension Font {
    /// 分区标题：折起 Title 3 半粗，展开 Title 2 粗
    static func dsShelfTitle(wide: Bool) -> Font { wide ? .title2.bold() : .title3.weight(.semibold) }
}

// MARK: - 分区：标题 + 一排

/// 分区标题（F2：和卡片同一条左边线；F86：不全大写）。有去处时后面一个「›」，整行可点
struct DSShelfTitle: View {
    let title: String
    let metrics: DSMetrics
    var route: Route? = nil

    var body: some View {
        let label = HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
                .font(.dsShelfTitle(wide: metrics.wide))
                .foregroundStyle(.primary)
            if route != nil {
                Image(systemName: "chevron.forward")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, metrics.margin)
        .accessibilityAddTraits(.isHeader)

        if let route {
            NavigationLink(value: route) { label.contentShape(Rectangle()) }
                .buttonStyle(.plain)
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
        .contentMargins(.horizontal, metrics.margin, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
        .scrollClipDisabled()
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
        DSParallaxArt(url: art, metrics: metrics, size: CGSize(width: w, height: h))
            .overlay {
                if let logo { DSPosterLogo(logo: logo, size: CGSize(width: w, height: h), title: title) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .frame(width: w, height: h)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
                    if let logo { DSWideLogo(logo: logo, size: CGSize(width: w, height: h), title: title) }
                }
                .overlay(alignment: .bottom) {
                    if let p = progress, p > 0.01 {
                        // 进度：底部一条细的胶囊（F36）
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.white.opacity(0.3))
                                Capsule().fill(.white).frame(width: max(4, g.size.width * min(1, p)))
                            }
                        }
                        .frame(height: 4)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 10)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .frame(width: w, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([title, subtitle].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "，"))
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
    /// 看到一半：第二行在 ▶ 后面先放一小段进度条
    var progress: Double? = nil
    /// 长文案的样子（方卡，用户要求：短文案、长文案两种卡）：标题上面一行小字（「第 2 集」），下面三行简介
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
        let h = tall ? w : (w * 9 / 16).rounded()
        // 圆角跟着卡宽走（参考图那种大圆角：约卡宽的 4.5%，14–22 点；方卡按 1.4 倍宽算，和 16:9 卡看着一样圆）
        let radius: CGFloat = max(14, min(22, ((tall ? w * 1.4 : w) * 0.045).rounded()))
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
                    .foregroundStyle(.white.opacity(0.78))
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

    /// 长文案（参考图）：「第 2 集」→ 集名 → 三行简介 →「42 分钟」
    private var longCopy: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let kicker, !kicker.isEmpty {
                Text(kicker)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white.opacity(0.72))
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
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(3)
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
                Image(systemName: "play.fill")
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
        .foregroundStyle(.white.opacity(0.78))
        .padding(.trailing, 30)
    }
}

// MARK: - 精选卡（Apple TV 的精选：一张大号竖卡）
//
// 3:4、大圆角，一圈很细的亮边（深色页面上卡的轮廓）；画面铺满（ImageEffect.featureCard：裁成 3:4，下半段渐进式模糊），
// 再压一层由透明到暗的渐变（F34、C58）；左下一列：字标（没有就是粗体片名）→「★ 电影 · 剧情 · 惊悚」（一颗小黑圆章 + 白字）
// →「评分 8.6 · 2025 · 2 小时 15 分钟」（灰字）。卡下不写字（T20）

struct DSFeatureCard: View {
    let art: URL?
    let logo: URL?
    let title: String
    /// 白字那一行：「电影 · 剧情 · 惊悚」
    let kicker: String
    /// 灰字那一行：「评分 8.6 · 2025 · 2 小时 15 分钟」
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
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.black)
            .padding(.horizontal, 22)
            .frame(minHeight: 48)
            .background(Color.white, in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: configuration.isPressed)
            .contentShape(Capsule())
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
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: configuration.isPressed)
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
                DSHeroBackdrop(page: shown, tall: tall, width: w, height: height)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

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
        .task(id: touched) {
            // 自己翻页：没被碰过、没开「减弱动态效果」和旁白时才翻
            guard !touched, !reduceMotion, !voiceOver, pages.count > 1 else {
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

    /// 前面一层：字标、信息、按钮（左对齐：F1、F2）。字本身不接手势
    private func foreground(_ p: DSHeroPage, width w: CGFloat) -> some View {
        // 字标：所有页一样高，太宽的按屏宽的 45% 收（统一的视觉重量；F12）
        let logoHeight = min(132, max(84, (w * 0.2).rounded()))
        let logoMaxWidth = (w * 0.45).rounded()
        return VStack(alignment: .leading, spacing: 14) {
            Group {
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
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1)
                }
            }
            .allowsHitTesting(false)
            HStack(spacing: 12) {
                Button(action: p.play) { Label(p.playTitle, systemImage: "play.fill") }
                    .buttonStyle(.dsPlay)
                    .accessibilityIdentifier("hero-play")
                detailLink(p)
                    .buttonStyle(.dsSecondary)
                    .accessibilityIdentifier("hero-detail")
            }
            .padding(.top, 4)
        }
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

    var body: some View {
        let art = tall ? (page.tallArt ?? page.wideArt) : (page.wideArt ?? page.tallArt)
        ZStack {
            Color.black
            DSBlurFadeImage(url: TMDBImage.url(art, "w1280"), maxPixel: 2000)
                .frame(width: width, height: height)
                .clipped()
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
    var maxPixel: CGFloat = 1800
    var duration: Double = 0.9
    @State private var shown: Shown?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Shown: Equatable {
        let url: URL
        let image: UIImage
        static func == (a: Shown, b: Shown) -> Bool { a.url == b.url }
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
        .task(id: url) {
            guard let url else { return }
            if shown?.url == url { return }
            guard let img = await ImagePipeline.shared.image(url, maxPixel: maxPixel), !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: duration)) { shown = Shown(url: url, image: img) }
        }
    }
}

/// 模糊淡入 / 淡出（不带方向）：出现时从 24 点模糊、全透明到清楚、不透明；消失时反过来
struct DSBlurFade: ViewModifier {
    let on: Bool
    var radius: CGFloat = 24

    func body(content: Content) -> some View {
        content
            .blur(radius: on ? radius : 0, opaque: true)
            .opacity(on ? 0 : 1)
    }
}

extension AnyTransition {
    static var dsBlurFade: AnyTransition {
        .modifier(active: DSBlurFade(on: true), identity: DSBlurFade(on: false))
    }
}
