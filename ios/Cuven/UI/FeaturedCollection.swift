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
// 整条带往上滚时海报比字慢一点（视差）；横滑的大卡停在左边线上（不放大、不压暗别的卡：用户早先的要求）。
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
            rowHeading
                .padding(.top, metrics.wide ? 34 : 26)
            DSShelf(metrics: metrics) { cards() }
                .padding(.top, metrics.titleGap)
        }
    }

    /// 「为您的口味量身定制的内容 ›」+ 灰字「向左滑动查看更多」（参考图：粗体大一号的标题，下面一行灰字）
    @ViewBuilder
    private var rowHeading: some View {
        let label = VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(rowTitle)
                    .font(metrics.wide ? .title.bold() : .title2.bold())
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if rowRoute != nil {
                    Image(systemName: "chevron.forward")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.white.opacity(0.55))
                }
                Spacer(minLength: 0)
            }
            Text("向左滑动查看更多")
                .font(.headline)
                .foregroundStyle(.white.opacity(0.5))
        }
        .padding(.horizontal, metrics.margin)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        if let rowRoute {
            NavigationLink(value: rowRoute) { label.contentShape(Rectangle()) }
                .buttonStyle(.plain)
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
    /// 主色的色相、饱和度：排在最前那张海报的平均色；取到之前是灰，取到了慢慢染上
    @State private var hue: Double = 0
    @State private var sat: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 排在最前那部的海报（带的颜色从它取）
    private var lead: URL? { covers.first.flatMap { $0 } }

    static func posterWidth(_ m: DSMetrics) -> CGFloat { min(150, max(92, (m.width * 0.27).rounded())) }

    /// 大标题的底边离这一块顶上多远（合集页滚过它，才把标题接到导航栏里）
    static func titleBottom(_ m: DSMetrics) -> CGFloat {
        22 + PosterFan.height(posterWidth(m)) + 22 + (m.wide ? 52 : 43)
    }

    var body: some View {
        let posterW = Self.posterWidth(metrics)
        let lag: CGFloat = reduceMotion ? 0 : 0.08
        VStack(alignment: .leading, spacing: 0) {
            if !covers.isEmpty {
                PosterFan(covers: Array(covers.prefix(3)), width: posterW)
                    .frame(maxWidth: .infinity)
                    .frame(height: PosterFan.height(posterW))
                    .padding(.top, 22)
                    // 整条带往上滚时海报比字慢一点（视差）
                    .visualEffect { c, proxy in
                        let y = proxy.frame(in: .scrollView(axis: .vertical)).minY
                        return c.offset(y: max(-28, min(28, -y * lag)))
                    }
            }
            Text(title)
                .font(.system(size: metrics.wide ? 44 : 36, weight: .heavy))
                .foregroundStyle(.white)
                .padding(.top, 22)
                .accessibilityAddTraits(.isHeader)
            Text(blurb)
                .font(.title3)
                .foregroundStyle(.white.opacity(0.62))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 560, alignment: .leading)
                .padding(.top, 10)
        }
        .padding(.horizontal, metrics.margin)
        .padding(.bottom, 34)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { backdrop }
        .task(id: lead) { await loadTint() }
    }

    private func tone(_ brightness: Double) -> Color { Color(hue: hue, saturation: sat, brightness: brightness) }

    /// 底色，铺到侧边那一列底下
    @ViewBuilder private var backdrop: some View {
        if page {
            // 合集页：最顶上一片主色（往上一直铺到状态栏、导航栏底下，下拉露出来的也是它），往下沉到黑
            VStack(spacing: 0) {
                tone(0.74).frame(height: 800)
                LinearGradient(stops: [
                    .init(color: tone(0.74), location: 0),
                    .init(color: tone(0.34), location: 0.62),
                    .init(color: tone(0.34).opacity(0), location: 1),
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
        let ns = Double(min(page ? 0.72 : 0.68, max(0.36, s * 1.1)))
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
        // 右边那张低、上下不对称：整扇往上挪一点，在框里居中
        .offset(y: -width * 0.15)
        .frame(width: width * 2.9)
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
        .shadow(color: .black.opacity(0.45), radius: 16, x: 0, y: 14)
    }
}

// MARK: - 下面那排大卡

/// 一张大卡：整幅画面，底下一条磨砂的条（小海报、片名、一行灰字、「查看」）
struct FeaturedCollectionCard: View {
    let art: URL?
    let cover: URL?
    let title: String
    let subtitle: String
    let width: CGFloat

    var body: some View {
        let h = (width * 0.8).rounded()
        let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
        ZStack(alignment: .bottom) {
            Color(white: 0.12)
            RemoteImage(url: art, maxPixel: width * 3)
                .frame(width: width, height: h)
            HStack(spacing: 14) {
                RemoteImage(url: cover, maxPixel: 200)
                    .frame(width: 44, height: 66)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.white.opacity(0.15), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.62))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Text("查看")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .frame(minHeight: 32)
                    .background(Capsule().fill(Color.white.opacity(0.18)))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(width: width)
            .background(.ultraThinMaterial)
            .background(Color.black.opacity(0.3))
            .environment(\.colorScheme, .dark)
        }
        .frame(width: width, height: h)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        .contentShape(shape)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([title, subtitle].filter { !$0.isEmpty }.joined(separator: "，"))
    }
}
