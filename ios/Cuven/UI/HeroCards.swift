import SwiftUI

// MARK: - 首页大图：卡片态
//
// 用在「矮而宽」的紧凑宽度屏上（iPhone Duo 折起时的外屏：比别的 iPhone 宽、矮，系统栏在侧边那一列）：
// 一张张竖版海报卡并排，左右露出邻卡，卡下一排圆点（iOS 页码控件样式），不自动轮播。
// 何时用由主页按可用空间的宽高比决定（见 HomeView），不认设备型号。

struct HeroCards: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let items: [HeroItem]
    let width: CGFloat
    /// 卡片高度（不含下面那排圆点）
    let cardHeight: CGFloat
    @State private var current: String?

    var body: some View {
        let gap: CGFloat = 26, spacing: CGFloat = 12
        let calm = reduceMotion
        let cardW = max(200, width - gap * 2)
        let cardH = max(300, cardHeight)
        VStack(spacing: 16) {
            if items.isEmpty {
                RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Theme.surface)
                    .frame(width: cardW, height: cardH)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: spacing) {
                        ForEach(items) { it in
                            ZoomLink(route: .movie(it.video), slot: "herocard") {
                                HeroCard(item: it, width: cardW, height: cardH)
                            }
                            .accessibilityIdentifier("hero-card")
                            .id(it.id)
                            // 翻卡时两侧的卡略缩、略暗（Apple TV 卡片轮播的手感）
                            .scrollTransition(.interactive, axis: .horizontal) { content, phase in
                                content
                                    .scaleEffect(phase.isIdentity || calm ? 1 : 0.94)
                                    .opacity(phase.isIdentity ? 1 : 0.75)
                            }
                        }
                    }
                    .scrollTargetLayout()
                }
                .contentMargins(.horizontal, gap, for: .scrollContent)
                .scrollTargetBehavior(.viewAligned)
                .scrollPosition(id: $current)
                .frame(height: cardH)

                if items.count > 1 {
                    PageDots(ids: items.map(\.id), current: $current)
                }
            }
        }
        .frame(width: width, alignment: .top)
    }
}

struct HeroCard: View {
    @Environment(AppModel.self) private var model
    let item: HeroItem
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        let m = model.meta(item.video)
        ZStack(alignment: .bottom) {
            Color.clear
                .overlay { RemoteImage(url: URL(string: item.hero.poster ?? item.hero.background ?? ""), maxPixel: 1100) }
                .clipped()
            LinearGradient(stops: [
                .init(color: .clear, location: 0.45),
                .init(color: .black.opacity(0.6), location: 0.75),
                .init(color: .black.opacity(0.85), location: 1),
            ], startPoint: .top, endPoint: .bottom)
            LogoImage(url: URL(string: item.hero.logo ?? "") ?? TMDBImage.url(m?.logo, "w500"), height: 58,
                      fallback: model.title(item.video))
                .padding(.horizontal, 24)
                .padding(.bottom, 26)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.45), radius: 18, y: 10)
    }
}

/// iOS 页码控件样式的圆点胶囊：当前那颗纯白、略大，其余半透明；点哪颗翻到哪张
struct PageDots: View {
    let ids: [String]
    @Binding var current: String?

    var body: some View {
        let cur = current ?? ids.first
        HStack(spacing: 9) {
            ForEach(ids, id: \.self) { id in
                Circle()
                    .fill(id == cur ? Color.white : Color.white.opacity(0.5))
                    .frame(width: id == cur ? 8 : 7, height: id == cur ? 8 : 7)
                    .contentShape(Rectangle().inset(by: -6))
                    .onTapGesture { withAnimation(.snappy) { current = id } }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .glassEffect(.regular, in: Capsule())
        .animation(.snappy, value: current)
    }
}
