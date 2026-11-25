import SwiftUI
import UIKit

// MARK: - 主页的精选区：照用户给的参考图（Apple「游戏」App 的合集页「先體驗，再付費」）
//
// · 上半截一条染色的带：从排在最前那部的海报取主色，由黑浮上来、再沉回黑；
//   带上三张**立体海报封面**（参考图里的三枚 App 图标换成海报：有厚度的一块、斜着叠成一扇，最左边那张在最上面），
//   下面一行大号粗体标题和一段灰色说明；
// · 下面一排大卡：标题「为您的口味量身定制的内容 ›」+ 灰字「向左滑动查看更多」，
//   每张卡是整幅画面，底下一条磨砂的条：小海报、片名、「Cuven 独占 · 类型」、「查看」胶囊（参考图卡底那一条）。
// 动效：海报第一次滑进屏幕时从叠在一起的一摞弹开成一扇（一张晚一点），之后在屏上时各自轻轻浮动（错开节拍，滑走就停）；
// 合集页里整条带往上滚时海报比字慢一点（视差）；主页上不做（用户要求：主页的立体海报不跟着滚动上下挪）。
// 横滑的大卡停在左边线上（不放大、不压暗别的卡：用户早先的要求）。
// 「减弱动态效果」打开时：不弹、不浮、没有视差，只淡入。

struct FeaturedCollection<Cards: View>: View {
    /// 大号标题：「精选电影」
    let title: String
    /// 标题下的一段灰字
    let blurb: String
    /// 下面那排卡的标题（点进全部）
    let rowTitle: String
    let rowRoute: Route?
    /// 三张立体海报（排在最前的三部）
    let covers: [URL?]
    let metrics: DSMetrics
    @ViewBuilder var cards: () -> Cards

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FeaturedCollectionHeader(title: title, blurb: blurb, covers: covers, metrics: metrics)
            // 设计轮 2：说明到这一排的标题 60 / 68 → 42 / 46 点（头部底下本来留着 34 点给染色带淡出）：
            // 以前比分区与分区之间（48 / 56–62）还远，这一排看着像另起的一个分区，而不是「精选电影」自己的那一排（F12：近的才是一组）
            rowHeading
                .padding(.top, metrics.wide ? 12 : 8)
            DSShelf(metrics: metrics) { cards() }
                .padding(.top, metrics.titleGap)
        }
    }

    /// 「为您的口味量身定制的内容 ›」+ 灰字「向左滑动查看更多」（参考图：粗体标题，下面一行灰字）。
    /// 设计轮 1：和别的分区标题同一个部件、同一级（Title 2 粗体）：上面已经有大号的「精选电影」和说明，
    /// 这一行不再在展开时放大到 Title 1 去和它抢；灰字从 Headline 半粗换成 Body 常规
    @ViewBuilder
    private var rowHeading: some View {
        let label = DSSectionLabel(title: rowTitle, subtitle: "向左滑动查看更多", chevron: rowRoute != nil)
            .padding(.horizontal, metrics.margin)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
        if let rowRoute {
            NavigationLink(value: rowRoute) { label.contentShape(Rectangle()) }
                .buttonStyle(PressableStyle(scale: 0.98))
                .accessibilityIdentifier("section-\(rowTitle)")
        } else {
            label
        }
    }
}

// MARK: - 上半截：染色的带 + 立体海报 + 标题

struct FeaturedCollectionHeader: View {
    let title: String
    let blurb: String
    let covers: [URL?]
    let metrics: DSMetrics
    /// 合集页的头（整页最上面）：主色从最顶上开始、铺到状态栏和导航栏底下，往下沉到黑（参考图）；
    /// 主页里的是一条由黑浮上来、再沉回黑的带
    var page = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 排在最前那部的海报（带的颜色从它取）
    private var lead: URL? { covers.first.flatMap { $0 } }

    /// 立体海报多宽。折起（用户要求「放大，左右的边距应该一致」）：一扇的外沿（算上斜放、透视和厚度约 ±1.55 个海报宽）
    /// 正好落在左右两边的页边距上——和上面「精选剧集」大标题同一条左边线，右边留一样宽；
    /// 展开：屏宽的 27%（92–150 点），整扇海报不高过屏高的 42%（展开横拿只有六百多点高，一扇 150 点的海报连字就占掉大半屏）
    static func posterWidth(_ m: DSMetrics) -> CGFloat {
        guard m.wide else { return max(92, ((m.width - m.margin * 2) / PosterFan.spanRatio).rounded(.down)) }
        let byWidth = min(150, max(92, (m.width * 0.27).rounded()))
        guard m.height > 0 else { return byWidth }
        return min(byWidth, max(92, ((m.height * 0.42 - 12) / 2.43).rounded(.down)))
    }

    /// 大标题的底边离这一块顶上多远（合集页滚过它，才把标题接到导航栏里）
    static func titleBottom(_ m: DSMetrics) -> CGFloat {
        22 + PosterFan.height(posterWidth(m)) + 22 + (m.wide ? 52 : 43)
    }

    var body: some View {
        let posterW = Self.posterWidth(metrics)
        // 视差只在合集页：主页的立体海报跟着整页走，不再上下错开（用户要求）
        let lag: CGFloat = (reduceMotion || !page) ? 0 : 0.08
        // 染色的带、大标题和说明是 CollectionHeader（分类页那三张卡的头也用它）；这里只管上面那一扇立体海报
        CollectionHeader(title: title, blurb: blurb, lead: lead, metrics: metrics, page: page) {
            if !covers.isEmpty {
                PosterFan(covers: Array(covers.prefix(3)), width: posterW)
                    .frame(maxWidth: .infinity)
                    .frame(height: PosterFan.height(posterW))
                    .padding(.top, 22)
                    // 合集页：整条带往上滚时海报比字慢一点（视差）；主页 lag 为 0，不挪
                    .visualEffect { c, proxy in
                        let y = proxy.frame(in: .scrollView(axis: .vertical)).minY
                        return c.offset(y: max(-28, min(28, -y * lag)))
                    }
            }
        }
    }
}

// MARK: - 合集式的头：染色的带 + 上面一块（立体海报 / 三张卡）+ 大标题 + 一句说明

/// 专区页（立体海报）和「全部影片」的分类页（三张横滑的卡，用户要求替换立体海报）共用的头：
/// 底色从 lead 那张图取主色；top 是标题上面那一块，放在页边距里面（要铺满宽的自己往外伸，见 CategoryCardRow）
struct CollectionHeader<Top: View>: View {
    let title: String
    let blurb: String
    /// 底色从哪一张取（排在最前那部的海报）
    let lead: URL?
    let metrics: DSMetrics
    /// 合集页的头（整页最上面）：主色从最顶上开始、铺到状态栏和导航栏底下；主页里的是一条由黑浮上来、再沉回黑的带
    let page: Bool
    let top: Top
    /// 主色的色相、饱和度：排在最前那张海报的平均色；取到之前是灰，取到了慢慢染上
    @State private var hue: Double = 0
    @State private var sat: Double = 0

    init(title: String, blurb: String, lead: URL?, metrics: DSMetrics, page: Bool, @ViewBuilder top: () -> Top) {
        self.title = title
        self.blurb = blurb
        self.lead = lead
        self.metrics = metrics
        self.page = page
        self.top = top()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            top
            Text(title)
                .font(.dsDisplay(wide: metrics.wide))
                .foregroundStyle(.white)
                .padding(.top, 22)
                .accessibilityAddTraits(.isHeader)
            Text(blurb)
                .font(.title3)
                .foregroundStyle(DSInk.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 560, alignment: .leading)
                .padding(.top, 10)
        }
        .padding(.horizontal, metrics.margin)
        // 合集页、分类页：说明到下面那一列大卡差不多一道排距（以前 34，卡顶着说明）；
        // 主页里那条带照旧 34（带下面的分区自己还隔着一道排距）
        .padding(.bottom, page ? metrics.shelfGap - 8 : 34)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { backdrop }
        .task(id: lead) { await loadTint() }
    }

    private func tone(_ brightness: Double) -> Color { Color(hue: hue, saturation: sat, brightness: brightness) }

    /// 底色，铺到侧边那一列底下
    @ViewBuilder private var backdrop: some View {
        if page {
            // 合集页：最顶上一片主色（往上一直铺到状态栏、导航栏底下，下拉露出来的也是它），往下沉到黑。
            // 设计复查：亮度 0.74 → 0.56、0.34 → 0.30：黄绿底上白色状态栏只剩 2 : 1，上面的卡也压不过底色
            VStack(spacing: 0) {
                tone(0.56).frame(height: 800)
                LinearGradient(stops: [
                    .init(color: tone(0.56), location: 0),
                    .init(color: tone(0.30), location: 0.62),
                    .init(color: tone(0.30).opacity(0), location: 1),
                ], startPoint: .top, endPoint: .bottom)
            }
            .padding(.top, -800)
            .padding(.leading, -metrics.leadingInset)
            .padding(.trailing, -metrics.trailingInset)
            .allowsHitTesting(false)
        } else {
            // 主页里：由黑浮上来的一条主色、再沉回黑，上下都接得上前后的分区
            LinearGradient(stops: [
                .init(color: tone(0.42).opacity(0), location: 0),
                .init(color: tone(0.42), location: 0.2),
                .init(color: tone(0.42).opacity(0.55), location: 0.6),
                .init(color: tone(0.42).opacity(0), location: 1),
            ], startPoint: .top, endPoint: .bottom)
            .padding(.leading, -metrics.leadingInset)
            .padding(.trailing, -metrics.trailingInset)
            .allowsHitTesting(false)
        }
    }

    /// 主色：排在最前那张海报的平均色（只取色相，饱和度落到参考图那种浓淡，亮度由用处定）
    private func loadTint() async {
        guard let u = lead,
              let img = await ImagePipeline.shared.image(u, maxPixel: 96), let cg = img.cgImage,
              let c = ImageEffects.averageColor(cg, bottom: 1) else { return }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard c.getHue(&h, saturation: &s, brightness: &b, alpha: &a), s > 0.1 else { return }
        // 设计复查：合集页的饱和度上限 0.72 → 0.62（和上面压暗的亮度一起，是染了色的暗而不是一块色板）
        let ns = Double(min(page ? 0.62 : 0.68, max(0.36, s * 1.1)))
        withAnimation(.easeInOut(duration: 0.8)) {
            hue = Double(h)
            sat = ns
        }
    }
}

// MARK: - 立体海报：斜着叠成一扇

/// 三张立体海报：最左边的在最上面、往右一张比一张低一点，各自斜一点（参考图三枚图标的摆法）。
/// 第一次滑进屏幕时才从叠在一起的一摞弹开（主页一载入它还在屏幕下面，那时弹了看不到）；
/// 之后在屏上时各自轻轻浮动，滑出屏幕、换到别的页就停（不在背后一直跑、不费电）。
struct PosterFan: View {
    let covers: [URL?]
    let width: CGFloat
    @State private var fanned = false
    @State private var onScreen = false
    @State private var appeared = false
    /// 这一轮浮动从什么时候开始（nil = 停着）；幅度从 0 慢慢加满，开始时不跳
    @State private var floatFrom: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 三张时每一张的位置（按海报宽算）与倾斜角
    private static let fan3: [(x: CGFloat, y: CGFloat, angle: Double, tilt: Double)] = [
        (-0.92, -0.20, -9, 16),
        (0, 0.16, -2, 0),
        (0.92, 0.46, 8, -16),
    ]

    /// 不到三张（这一类只有一两部）时收拢、居中
    private static func layout(_ i: Int, of n: Int) -> (x: CGFloat, y: CGFloat, angle: Double, tilt: Double) {
        switch n {
        case 1: return (0, 0.12, -3, 0)
        case 2: return i == 0 ? (-0.48, -0.02, -7, 12) : (0.48, 0.3, 7, -12)
        default: return fan3[min(i, fan3.count - 1)]
        }
    }

    /// 一扇占的高：上沿约 -1.06、下沿约 +1.37 个海报宽（算上斜放、透视和厚度），再留浮动的上下 5 点
    static func height(_ width: CGFloat) -> CGFloat { (width * 2.43).rounded() + 12 }
    /// 一扇占的宽（三张时）：左右外沿各约 1.55 个海报宽（-1.54 / +1.56：两边差不到 2%，看着就是居中的）
    static let spanRatio: CGFloat = 3.1

    var body: some View {
        // 浮动很慢（5 点、五六秒一个来回），每秒 30 帧就够顺
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: floatFrom == nil)) { context in
            let amp = Self.amplitude(since: floatFrom, now: context.date)
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(Array(covers.enumerated()), id: \.offset) { i, url in
                    poster(i, url, t: t, amp: amp)
                }
            }
        }
        // 右边那张低、上下不对称：整扇往上挪一点，在框里居中；框就是一扇看上去那么宽（左右外沿），外面居中时左右留得一样宽
        .offset(y: -width * 0.15)
        .frame(width: width * Self.spanRatio)
        .onScrollVisibilityChange(threshold: 0.2) { visible in
            onScreen = visible
            if visible, !fanned { fanned = true }
            syncFloat()
        }
        .onAppear { appeared = true; syncFloat() }
        .onDisappear { appeared = false; syncFloat() }
        .onChange(of: reduceMotion) { syncFloat() }
        .accessibilityHidden(true)
    }

    private func poster(_ i: Int, _ url: URL?, t: Double, amp: CGFloat) -> some View {
        let l = Self.layout(i, of: covers.count)
        let spread: Bool = fanned || reduceMotion
        let tilt: Double = spread ? l.tilt : 0
        let angle: Double = spread ? l.angle : 0
        let dx: CGFloat = spread ? l.x * width : 0
        let dy: CGFloat = spread ? l.y * width : 0
        // 各自轻轻浮动：上下 5 点、斜 0.8°，周期和相位错开
        let phase: Double = t * 2 * Double.pi / (5.6 + Double(i) * 0.8) + Double(i) * 1.9
        let bob: CGFloat = 5 * amp * CGFloat(sin(phase))
        let sway: Double = 0.8 * Double(amp) * sin(phase + 1.1)
        let openAnim: Animation = reduceMotion ? Animation.easeInOut(duration: 0.3)
            : Animation.spring(response: 0.72, dampingFraction: 0.7).delay(Double(i) * 0.07)
        return Poster3D(url: url, width: width)
            .rotation3DEffect(.degrees(tilt), axis: (x: 0.15, y: 1, z: 0), perspective: 0.55)
            .rotationEffect(.degrees(angle))
            .offset(x: dx, y: dy)
            .scaleEffect(spread ? 1 : 0.86)
            .opacity(spread ? 1 : 0)
            .animation(openAnim, value: spread)
            // 浮动在弹开的动画外面：每一帧直接给位置，不被弹簧卷进去
            .offset(y: bob)
            .rotationEffect(.degrees(sway))
            .zIndex(Double(covers.count - i))
    }

    /// 浮动的幅度：弹开那一下（约 0.7 秒）走完才慢慢加上来，再过 1.4 秒到满幅
    private static func amplitude(since: Date?, now: Date) -> CGFloat {
        guard let since else { return 0 }
        let a = min(1, max(0, (now.timeIntervalSince(since) - 0.6) / 1.4))
        return CGFloat(a * a * (3 - 2 * a))
    }

    /// 在屏上（滑进来了、这一页也在前台）而且没开「减弱动态效果」才浮动
    private func syncFloat() {
        let active = appeared && onScreen && !reduceMotion
        if active, floatFrom == nil { floatFrom = Date() }
        if !active, floatFrom != nil { floatFrom = nil }
    }
}

/// 一张立体海报：正面是海报，后面垫一块深色的「厚度」往右下错开，边上一圈由亮到暗的斜边，左上一道高光，底下一团柔影
struct Poster3D: View {
    let url: URL?
    let width: CGFloat

    var body: some View {
        let h = (width * 1.5).rounded()
        let r = (width * 0.09).rounded()
        let shape = RoundedRectangle(cornerRadius: r, style: .continuous)
        ZStack {
            // 厚度：同样大的一块深色板，往右下错开
            shape
                .fill(LinearGradient(colors: [Color(white: 0.22), Color(white: 0.05)], startPoint: .top, endPoint: .bottom))
                .offset(x: width * 0.035, y: width * 0.055)
            // 正面
            ZStack {
                Color(white: 0.14)
                RemoteImage(url: url, maxPixel: width * 3)
                    .frame(width: width, height: h)
                // 左上一道高光（玻璃面的光泽）
                LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.06), .clear],
                               startPoint: .topLeading, endPoint: UnitPoint(x: 0.6, y: 0.55))
                    .blendMode(.screen)
            }
            .frame(width: width, height: h)
            .clipShape(shape)
            // 斜边：左上亮、右下暗
            .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.6), .white.opacity(0.08), .black.opacity(0.35)],
                                                       startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 2))
        }
        .frame(width: width, height: h)
        .compositingGroup()
        // 设计轮 2：两层影子——贴着的一层窄而实（左边那张压在中间那张上，叠的先后一眼看得出），
        // 外面一层宽而柔（浮起来的高度）；以前只有一层宽的，叠在一起的边上糊成一片
        .shadow(color: .black.opacity(0.32), radius: 3, x: 0, y: 2)
        .shadow(color: .black.opacity(0.45), radius: 16, x: 0, y: 14)
    }
}

// MARK: - 下面那排大卡

/// 一张大卡：整幅画面，底下一条磨砂的条（小海报、片名、一行灰字、「查看」）
/// 精选电影的大竖卡（用户要求「整个精选电影区使用大卡片设计」，照 Apple TV「What We're Watching」）：3 : 4，
/// 无字的竖版画面铺满（Apple TV 竖版主视觉 → TMDB 纯净海报：AppModel.featuredArt），下段压暗；
/// 左下字标（没有字标写片名，卡宽的 17% 高）+ 一行「电影 · 年份 · 类型」。不放简介（用户要求：简介只出现在详情页）。
/// 圆角 24、细边；在排里不放大、不压暗（用户要求），按下去是 PressableStyle 的那一下
struct FeaturedBigCard: View {
    let art: URL?
    let logo: URL?
    let title: String
    let line: String
    let width: CGFloat

    var body: some View {
        let h = (width * 4 / 3).rounded()
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        let pad: CGFloat = width >= 330 ? 20 : 16
        // 画面用 Color.clear 撑出卡的大小再盖上去：fill 的图不会把这一层撑大，字和渐暗都贴着卡的边。
        // 用户要求「内部四周向内的渐进式模糊」：画面先裁成 3 : 4、四边往里渐进式地糊（ImageEffect.bigCard，后台算一次、缓存），
        // 中间清楚；糊过的底边上字标和一行字看得清，压暗跟着淡一点
        Color.clear
            .frame(width: width, height: h)
            .overlay { RemoteImage(url: art, maxPixel: width * 3, placeholder: .clear, effect: .bigCard) }
            .overlay {
                LinearGradient(stops: [.init(color: .black.opacity(0), location: 0.45),
                                       .init(color: .black.opacity(0.4), location: 0.74),
                                       .init(color: .black.opacity(0.72), location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 10) {
                    LogoImage(url: logo, height: (width * 0.17).rounded(), alignment: .bottomLeading,
                              fallback: title, maxWidth: width - pad * 2)
                    if !line.isEmpty {
                        Text(line)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(DSInk.secondary)
                            .lineLimit(1)
                    }
                }
                // 字压在固定大小的画面上：字号最大到 xxxLarge（和别的大卡一样封顶）
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .padding(pad)
            }
            .background(DSFill.placeholder)
            .clipShape(shape)
            .overlay(shape.strokeBorder(DSFill.hairline, lineWidth: 1))
            .contentShape(shape)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel([title, line].filter { !$0.isEmpty }.joined(separator: "，"))
    }
}

struct FeaturedCollectionCard: View {
    let art: URL?
    let cover: URL?
    let title: String
    let subtitle: String
    let width: CGFloat

    var body: some View {
        let h = (width * 0.8).rounded()
        let shape = RoundedRectangle(cornerRadius: DSRadius.feature, style: .continuous)
        ZStack(alignment: .bottom) {
            DSFill.placeholder
            RemoteImage(url: art, maxPixel: width * 3, placeholder: .clear)
                .frame(width: width, height: h)
            HStack(spacing: 14) {
                DSThumb(url: cover, width: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(DSInk.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                DSViewPill()
            }
            // 底条压在固定高的卡上：字号最大到 xxxLarge（和分集卡一样封顶），不盖掉大半张画面
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(width: width)
            // 磨砂条的上沿渐进式地糊起来（用户要求不留硬边界线）：底比条往上多伸一截，那一截由清楚慢慢糊到满
            .background { FeaturedBarBackdrop().padding(.top, -FeaturedBarBackdrop.rise) }
            .environment(\.colorScheme, .dark)
        }
        .frame(width: width, height: h)
        .clipShape(shape)
        .overlay(shape.strokeBorder(DSFill.hairline, lineWidth: 1))
        .contentShape(shape)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([title, subtitle].filter { !$0.isEmpty }.joined(separator: "，"))
    }
}

/// 精选卡底条的底：磨砂 + 一层淡黑（和以前同一种材质、同一层黑），只是上沿不再是一道横在画面上的硬线——
/// 两层都按同一条渐变淡掉（DSProgressiveBar 的做法），最上面全透明，往下 36% 处才是满的；片名和灰字都压在满的那一段里
private struct FeaturedBarBackdrop: View {
    /// 比条本身往上多伸多少（淡出去的那一截）
    static let rise: CGFloat = 24

    var body: some View {
        let fade = LinearGradient(stops: [
            .init(color: .clear, location: 0),
            .init(color: .black, location: 0.36),
            .init(color: .black, location: 1),
        ], startPoint: .top, endPoint: .bottom)
        ZStack {
            Rectangle().fill(.ultraThinMaterial).mask(fade)
            Rectangle().fill(Color.black.opacity(0.3)).mask(fade)
        }
        .allowsHitTesting(false)
    }
}
