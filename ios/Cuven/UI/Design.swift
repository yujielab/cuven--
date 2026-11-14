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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let travel = reduceMotion ? 0 : (size.width * 0.02).rounded()
        let keyline = metrics.margin
        let span = size.width + metrics.gutter
        Color(white: 0.11)
            .overlay {
                RemoteImage(url: url, maxPixel: size.width * 3, placeholder: .clear)
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
/// caption：分集、预告片这种卡下的字本身就是内容（第 3 集 · 集名），才把字写出来
struct DSWideLockup: View {
    let art: URL?
    let title: String
    var subtitle: String? = nil
    var progress: Double? = nil
    let metrics: DSMetrics
    var width: CGFloat? = nil
    var logo: URL? = nil
    var caption = false

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
            if caption {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(width: w, alignment: .leading)
            }
        }
        .frame(width: w, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([title, subtitle].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "，"))
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

/// 全屏轮播：一页一部，左右翻；画面在后、字在前，翻页时画面比字走得慢一点（两层视差：S12、S15）；
/// 没碰它时 7 秒翻一页，一碰就不再自己翻（S17、F79）；「减弱动态效果」或旁白开着时不自己翻（S17、F59）。
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.zoomNamespace) private var zoomNamespace

    var body: some View {
        let w = fullWidth ?? metrics.width
        let tall = height > w
        ZStack(alignment: .bottom) {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 0) {
                    ForEach(pages) { p in
                        page(p, tall: tall, width: w)
                            .frame(width: w, height: height)
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
            .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { _ in touched = true })

            if pages.count > 1 {
                // 页码点浮在画面底部、内容区的正中（不算侧边那一列：S16）
                DSPageDots(ids: pages.map(\.id), current: current ?? pages.first?.id)
                    .padding(.bottom, 18)
                    .offset(x: (leadingInset - trailingInset) / 2)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: w, height: height)
        .task(id: touched) {
            // 自己翻页：没被碰过、没开「减弱动态效果」和旁白时才翻
            guard !touched, !reduceMotion, !voiceOver, pages.count > 1 else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 7_000_000_000)
                guard !Task.isCancelled, !touched else { return }
                let ids = pages.map(\.id)
                let i = ids.firstIndex(of: current ?? ids[0]) ?? 0
                withAnimation(.smooth(duration: 0.8)) { current = ids[(i + 1) % ids.count] }
            }
        }
    }

    private func page(_ p: DSHeroPage, tall: Bool, width w: CGFloat) -> some View {
        let art = tall ? (p.tallArt ?? p.wideArt) : (p.wideArt ?? p.tallArt)
        let still = reduceMotion
        // 字标：所有页一样高，太宽的按屏宽的 45% 收（统一的视觉重量；F12）
        let logoHeight = min(132, max(84, (w * 0.2).rounded()))
        let logoMaxWidth = (w * 0.45).rounded()
        return ZStack(alignment: .bottomLeading) {
            // 后面一层：画面 + 渐暗。画面本身不接点按——只有「详情」钮进详情页（用户要求：翻页、滑动时不会误进），
            // 详情页仍从这张画面上放大出来、返回时缩回去（F57：这张画面是缩放转场的起点）
            ZStack {
                // 画面（翻页时只走 85%：比字慢，像在后面：S12）
                Color.black
                    .overlay {
                        RemoteImage(url: TMDBImage.url(art, "w1280"), maxPixel: 2000, placeholder: .clear)
                            .visualEffect { c, proxy in
                                let x = proxy.frame(in: .scrollView(axis: .horizontal)).minX
                                return c.offset(x: still ? 0 : -x * 0.15)
                            }
                    }
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
            .frame(width: w, height: height)
            .modifier(DSHeroZoomSource(route: p.detail))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            // 前面一层：字标、信息、按钮（左对齐：F1、F2）。字本身不接手势，点在字上也是点到后面的画面
            VStack(alignment: .leading, spacing: 14) {
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
        .contentShape(Rectangle())
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

/// 页码点（Page controls：居中、不超过约 10 个：S16）；当前那颗拉长一点。浮在画面上，带一点影子托住（F34）
struct DSPageDots: View {
    let ids: [String]
    let current: String?

    var body: some View {
        HStack(spacing: 8) {
            ForEach(ids.prefix(10), id: \.self) { id in
                Capsule()
                    .fill(id == current ? Color.white : Color.white.opacity(0.4))
                    .frame(width: id == current ? 18 : 6, height: 6)
            }
        }
        .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
        .animation(.smooth(duration: 0.3), value: current)
        .accessibilityHidden(true)
    }
}
