import SwiftUI

// MARK: - 设计系统：按 Apple HIG 收拾过的一套（规则出处见 docs/ios-design.md，编号 F = 基础、T = tvOS、S = 触屏上的 tvOS、D = iPhone Duo）
//
// 原则：内容在前，界面退后（F1、F80、T1）。分组靠留白，不靠描边和底板（F3）；玻璃只给系统栏和少数控件，内容层不用（F38）；
// 字一律用系统文字样式（F15），层级靠字重、字号和 .secondary（F18）；颜色只给一个主操作（F32、F33）。
// 同一套设计随屏幕长大（S1、D2）：折起是它，展开就是更大的它——更大的头图、每排更多的卡、更从容的留白，
// 一排里停在左侧基准线上的那张像 tvOS 的焦点那样微微放大、阴影加深、标题浮出来（S7–S9），画面里一点点视差（S12）。
// 打开「减弱动态效果」：放大、视差、自动翻页都停，只留阴影和标题（F59、S24）。

/// 版面尺寸：都从当前宽度算（F9、D4：看宽度和尺寸类别，不看机型）。
/// 边距 / 卡间距 / 排间距按 tvOS 的比例（80 / 40 / 100，以 1920 宽为准）缩到眼前的宽度，再以 iPhone 的系统边距兜底（S3、S5）
struct DSMetrics {
    let width: CGFloat

    /// 展开的 Duo、iPad、横拿：一排多放几张，字号上一级
    var wide: Bool { width >= 600 }
    /// 左右边距（S5：80·s；iPhone 至少 20）
    var margin: CGFloat { max(20, (width * 80 / 1920).rounded()) }
    /// 卡与卡的间距（S5：40·s；至少 12）
    var gutter: CGFloat { max(12, (width * 40 / 1920).rounded()) }
    /// 排与排之间（T24「行距至少 100」按比例缩，再给标题留位：F12）
    var shelfGap: CGFloat { max(40, (width * 100 / 1920).rounded() + 16) }

    /// 竖版海报宽：一排放整数张，最后一张从右边距里露出一条（S6、S8、I13）
    var posterWidth: CGFloat { cardWidth(columns: width < 500 ? 3 : (width < 800 ? 4 : 6)) }
    /// 16:9 卡宽：折起一张半屏多一点，展开两张（竖）/ 四张（横）（S6）
    var wideCardWidth: CGFloat {
        if width < 500 { return min(300, width - margin * 2 - 36) }
        return cardWidth(columns: width < 800 ? 2 : 4)
    }

    func cardWidth(columns n: Int) -> CGFloat {
        let n = CGFloat(max(1, n))
        return ((width - margin * 2 - (n - 1) * gutter) / n).rounded(.down)
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

/// 一排卡（T23：只用标准的横排；S8：卡停在左侧基准线上，右边露出下一张的一条）。
/// 留出上下的空，放大的那张不碰到上下的字（T22、S9）
struct DSShelf<Content: View>: View {
    let metrics: DSMetrics
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: metrics.gutter) { content() }
                .scrollTargetLayout()
                .padding(.vertical, 14)
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
        VStack(alignment: .leading, spacing: 6) {
            DSShelfTitle(title: title, metrics: metrics, route: route)
            content()
        }
    }
}

// MARK: - 焦点（触屏上的 tvOS 焦点：S7–S12）

/// 一张卡离左侧基准线多近：1 = 正停在基准线上（就是「焦点」那张），0 = 离开一张卡以上。全靠滚动位置算，不用计时器（S10）
private func dsEmphasis(minX: CGFloat, keyline: CGFloat, span: CGFloat) -> CGFloat {
    let d = abs(minX - keyline)
    return max(0, 1 - d / max(1, span))
}

/// 卡片的焦点样子：停在基准线上时以中心放大（不超过卡间距：S9），画面在卡里有一点点视差（S12：约 3%）。
/// 用 visualEffect 按滚动位置直接算，不进 body、不触发重排
struct DSFocusEffect: ViewModifier {
    let metrics: DSMetrics
    let cardWidth: CGFloat
    /// 竖版海报放大多一点（T27：海报约 1.14、16:9 约 1.09）
    var poster = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let keyline = metrics.margin
        let span = cardWidth + metrics.gutter
        // 两边各长出的不超过卡间距（S9）
        let target: CGFloat = poster ? 1.14 : 1.09
        let maxScale = min(target, 1 + 2 * metrics.gutter / max(1, cardWidth))
        let still = reduceMotion
        return content
            .visualEffect { c, proxy in
                let e = dsEmphasis(minX: proxy.frame(in: .scrollView(axis: .horizontal)).minX, keyline: keyline, span: span)
                return c.scaleEffect(still ? 1 : 1 + (maxScale - 1) * e)
            }
    }
}

/// 焦点卡的阴影：放大时更大、更软、更远（T8、S9）。是一层单独的影子，透明度跟着焦点走
struct DSFocusShadow: ViewModifier {
    let metrics: DSMetrics
    let cardWidth: CGFloat
    var cornerRadius: CGFloat = 12

    func body(content: Content) -> some View {
        let keyline = metrics.margin
        let span = cardWidth + metrics.gutter
        return content.background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.black)
                .blur(radius: 14)
                .offset(y: 12)
                .visualEffect { c, proxy in
                    let e = dsEmphasis(minX: proxy.frame(in: .scrollView(axis: .horizontal)).minX, keyline: keyline, span: span)
                    return c.opacity(0.25 + 0.5 * e)
                }
        }
    }
}

/// 卡下的标题槽：位置先留好，焦点那张淡入（T20：海报的标题在聚焦时才出现；S9：行高不跳）
struct DSFocusCaption: ViewModifier {
    let metrics: DSMetrics
    let cardWidth: CGFloat
    /// 一直显示（16:9 卡的标题是要读的：继续观看、最新加入）
    var always = false

    func body(content: Content) -> some View {
        let keyline = metrics.margin
        let span = cardWidth + metrics.gutter
        let always = always
        return content.visualEffect { c, proxy in
            let e = dsEmphasis(minX: proxy.frame(in: .scrollView(axis: .horizontal)).minX, keyline: keyline, span: span)
            return c.opacity(always ? 1 : Double(0.15 + 0.85 * e))
        }
    }
}

/// 卡里的画面视差：画面比卡宽一点，随卡在排里的位置往反方向挪几点（S12：约 3%、几乎觉察不到 F61）
struct DSParallaxArt: View {
    let url: URL?
    let metrics: DSMetrics
    let size: CGSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let travel = reduceMotion ? 0 : (size.width * 0.03).rounded()
        let keyline = metrics.margin
        let span = size.width + metrics.gutter
        Color(white: 0.12)
            .overlay {
                RemoteImage(url: url, maxPixel: size.width * 3, placeholder: .clear)
                    .frame(width: size.width + travel * 2, height: size.height)
                    .visualEffect { c, proxy in
                        // 卡在基准线右边（还没到）时画面偏左，滑过基准线以后偏右：像一层在后面的画
                        let x = proxy.frame(in: .scrollView(axis: .horizontal)).minX + travel
                        let t = max(-1, min(1, (x - keyline) / max(1, span)))
                        return c.offset(x: -t * travel)
                    }
            }
            .frame(width: size.width, height: size.height)
            .clipped()
    }
}

// MARK: - 卡（tvOS 的 lockup：画面 + 下面的字，一起放大缩小：T20、T22）

/// 竖版海报（2:3）：海报本来就带片名，所以卡下的字只在焦点那张出现（T20）
struct DSPosterLockup: View {
    let art: URL?
    let title: String
    var subtitle: String? = nil
    let metrics: DSMetrics
    var width: CGFloat? = nil

    var body: some View {
        let w = width ?? metrics.posterWidth
        let h = (w * 1.5).rounded()
        VStack(alignment: .leading, spacing: 10) {
            DSParallaxArt(url: art, metrics: metrics, size: CGSize(width: w, height: h))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .modifier(DSFocusShadow(metrics: metrics, cardWidth: w))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(subtitle ?? " ")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: w, alignment: .leading)
            .modifier(DSFocusCaption(metrics: metrics, cardWidth: w))
        }
        .frame(width: w, alignment: .leading)
        .modifier(DSFocusEffect(metrics: metrics, cardWidth: w, poster: true))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([title, subtitle].compactMap { $0 }.joined(separator: "，"))
    }
}

/// 16:9 卡：标题一直在（要读：继续观看、最新加入）；可选进度条（F36：进度用形状表达，不只靠颜色）
struct DSWideLockup: View {
    let art: URL?
    let title: String
    var subtitle: String? = nil
    var progress: Double? = nil
    let metrics: DSMetrics
    var width: CGFloat? = nil

    var body: some View {
        let w = width ?? metrics.wideCardWidth
        let h = (w * 9 / 16).rounded()
        VStack(alignment: .leading, spacing: 10) {
            DSParallaxArt(url: art, metrics: metrics, size: CGSize(width: w, height: h))
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
                .modifier(DSFocusShadow(metrics: metrics, cardWidth: w))
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
        .frame(width: w, alignment: .leading)
        .modifier(DSFocusEffect(metrics: metrics, cardWidth: w, poster: false))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([title, subtitle].compactMap { $0 }.joined(separator: "，"))
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
/// 没碰它时 7 秒翻一页，一碰就不再自己翻（S17、F79）；「减弱动态效果」或旁白开着时不自己翻（S17、F59）
struct DSHeroCarousel: View {
    let pages: [DSHeroPage]
    let metrics: DSMetrics
    let height: CGFloat
    @State private var current: String?
    @State private var touched = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    var body: some View {
        let tall = height > metrics.width
        VStack(spacing: 14) {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 0) {
                    ForEach(pages) { p in
                        page(p, tall: tall)
                            .frame(width: metrics.width, height: height)
                            .id(p.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $current)
            .frame(height: height)
            .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { _ in touched = true })

            if pages.count > 1 {
                DSPageDots(ids: pages.map(\.id), current: current ?? pages.first?.id)
            }
        }
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

    private func page(_ p: DSHeroPage, tall: Bool) -> some View {
        let art = tall ? (p.tallArt ?? p.wideArt) : (p.wideArt ?? p.tallArt)
        let still = reduceMotion
        let w = metrics.width
        return ZStack(alignment: .bottomLeading) {
            // 后面一层：画面（翻页时只走 85%：比字慢，像在后面：S12）
            Color.black
                .overlay {
                    RemoteImage(url: TMDBImage.url(art, "w1280"), maxPixel: 1800, placeholder: .clear)
                        .visualEffect { c, proxy in
                            let x = proxy.frame(in: .scrollView(axis: .horizontal)).minX
                            return c.offset(x: still ? 0 : -x * 0.15)
                        }
                }
                .clipped()
            // 底部渐暗：保证字的对比度（S17、F34）
            LinearGradient(stops: [
                .init(color: .clear, location: 0.45),
                .init(color: .black.opacity(0.55), location: 0.75),
                .init(color: .black.opacity(0.85), location: 1),
            ], startPoint: .top, endPoint: .bottom)
            // 前面一层：字标、信息、按钮（左对齐：F1、F2）
            VStack(alignment: .leading, spacing: 12) {
                if let logo = p.logo, !logo.isEmpty {
                    LogoImage(url: TMDBImage.url(logo, "w500"), height: metrics.wide ? 96 : 72, alignment: .leading,
                              fallback: p.title, maxWidth: min(w * 0.7, 360))
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
                HStack(spacing: 12) {
                    Button(action: p.play) { Label(p.playTitle, systemImage: "play.fill") }
                        .buttonStyle(.dsPlay)
                        .accessibilityIdentifier("hero-play")
                    NavigationLink(value: p.detail) { Text("详情") }
                        .buttonStyle(.dsSecondary)
                        .accessibilityIdentifier("hero-detail")
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, metrics.margin)
            .padding(.bottom, 28)
            .frame(maxWidth: min(w, 560), alignment: .leading)
        }
        .contentShape(Rectangle())
    }
}

/// 页码点（Page controls：居中、不超过约 10 个：S16）；当前那颗拉长一点
struct DSPageDots: View {
    let ids: [String]
    let current: String?

    var body: some View {
        HStack(spacing: 8) {
            ForEach(ids.prefix(10), id: \.self) { id in
                Capsule()
                    .fill(id == current ? Color.white : Color.white.opacity(0.35))
                    .frame(width: id == current ? 18 : 6, height: 6)
            }
        }
        .animation(.smooth(duration: 0.3), value: current)
        .accessibilityHidden(true)
    }
}
