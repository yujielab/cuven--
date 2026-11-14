import SwiftUI
import UIKit

// MARK: - 主页的精选区：照用户给的参考图（Apple「游戏」App 的合集页「先體驗，再付費」）
//
// · 上半截一条染色的带：从排在最前那部的海报取主色，由黑浮上来、再沉回黑；
//   带上三张**立体海报封面**（参考图里的三枚 App 图标换成海报：有厚度的一块、斜着叠成一扇，最左边那张在最上面），
//   下面一行大号粗体标题和一段灰色说明；
// · 下面一排大卡：标题「为您的口味量身定制的内容 ›」+ 灰字「向左滑动查看更多」，
//   每张卡是整幅画面，底下一条磨砂的条：小海报、片名、「Cuven 独占 · 类型」、「查看」胶囊（参考图卡底那一条）。
// 动效：海报第一次出现时从叠在一起的一摞弹开成一扇（一张晚一点），之后各自轻轻浮动（错开节拍）；
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
    @State private var tint = Color(hue: 0.5, saturation: 0.55, brightness: 0.42)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 排在最前那部的海报（带的颜色从它取）
    private var lead: URL? { covers.first.flatMap { $0 } }

    var body: some View {
        let posterW = min(150, max(92, (metrics.width * 0.27).rounded()))
        let lag: CGFloat = reduceMotion ? 0 : 0.08
        VStack(alignment: .leading, spacing: 0) {
            PosterFan(covers: Array(covers.prefix(3)), width: posterW)
                .frame(maxWidth: .infinity)
                .frame(height: posterW * 1.5 + posterW * 0.62)
                .padding(.top, 28)
                // 整条带往上滚时海报比字慢一点（视差）
                .visualEffect { c, proxy in
                    let y = proxy.frame(in: .scrollView(axis: .vertical)).minY
                    return c.offset(y: max(-40, min(40, -y * lag)))
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
        // 由黑浮上来的一条主色、再沉回黑：上下都接得上前后的分区；铺到侧边那一列底下
        .background {
            LinearGradient(stops: [
                .init(color: tint.opacity(0), location: 0),
                .init(color: tint, location: 0.2),
                .init(color: tint.opacity(0.55), location: 0.6),
                .init(color: tint.opacity(0), location: 1),
            ], startPoint: .top, endPoint: .bottom)
            .padding(.leading, -metrics.leadingInset)
            .padding(.trailing, -metrics.trailingInset)
            .allowsHitTesting(false)
        }
        .task(id: lead) { await loadTint() }
    }

    /// 带的颜色：排在最前那张海报的平均色（只取色相，饱和度、亮度落到参考图那种青绿的深浅）
    private func loadTint() async {
        guard let u = lead,
              let img = await ImagePipeline.shared.image(u, maxPixel: 96), let cg = img.cgImage,
              let c = ImageEffects.averageColor(cg, bottom: 1) else { return }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard c.getHue(&h, saturation: &s, brightness: &b, alpha: &a), s > 0.1 else { return }
        let t = Color(hue: Double(h), saturation: Double(min(0.68, max(0.36, s * 1.1))), brightness: 0.42)
        withAnimation(.easeInOut(duration: 0.8)) { tint = t }
    }
}

// MARK: - 立体海报：斜着叠成一扇

/// 三张立体海报：最左边的在最上面、往右一张比一张低一点，各自斜一点（参考图三枚图标的摆法）
struct PosterFan: View {
    let covers: [URL?]
    let width: CGFloat
    @State private var fanned = false
    @State private var float = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 每一张的位置（按海报宽算）、倾斜角、浮动的相位
    private static let layout: [(x: CGFloat, y: CGFloat, angle: Double, tilt: Double)] = [
        (-0.92, -0.20, -9, 16),
        (0, 0.16, -2, 0),
        (0.92, 0.46, 8, -16),
    ]

    var body: some View {
        ZStack {
            ForEach(Array(covers.enumerated()), id: \.offset) { i, url in
                let l = Self.layout[min(i, Self.layout.count - 1)]
                let spread: Bool = fanned || reduceMotion
                let tilt: Double = spread ? l.tilt : 0
                let angle: Double = spread ? l.angle : 0
                let dx: CGFloat = spread ? l.x * width : 0
                let dy: CGFloat = spread ? l.y * width : 0
                // 各自轻轻浮动：上下 5 点、斜一点点，节拍错开
                let bob: CGFloat = (reduceMotion || !float) ? 5 : -5
                let sway: Double = (reduceMotion || !float) ? -0.8 : 0.8
                let floatAnim: Animation? = reduceMotion ? nil
                    : Animation.easeInOut(duration: 2.8 + Double(i) * 0.35).repeatForever(autoreverses: true).delay(Double(i) * 0.45)
                let openAnim: Animation = reduceMotion ? Animation.easeInOut(duration: 0.3)
                    : Animation.spring(response: 0.72, dampingFraction: 0.7).delay(Double(i) * 0.07)
                Poster3D(url: url, width: width)
                    .rotation3DEffect(.degrees(tilt), axis: (x: 0.15, y: 1, z: 0), perspective: 0.55)
                    .rotationEffect(.degrees(angle))
                    .offset(x: dx, y: dy)
                    .offset(y: reduceMotion ? 0 : bob)
                    .rotationEffect(.degrees(reduceMotion ? 0 : sway))
                    .animation(floatAnim, value: float)
                    .scaleEffect(spread ? 1 : 0.86)
                    .opacity(spread ? 1 : 0)
                    .animation(openAnim, value: spread)
                    .zIndex(Double(covers.count - i))
            }
        }
        .frame(width: width * 2.9)
        .onAppear {
            guard !fanned else { return }
            fanned = true
            // 弹开那一下走完再开始浮动：两种动画分开，弹开不会被卷进无限循环里
            guard !reduceMotion else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(900))
                float = true
            }
        }
        .accessibilityHidden(true)
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
