import SwiftUI

// MARK: - 首页大图：卡片态（和网页版 iPhone Duo 折起时一样）
//
// 用在「矮而宽」的紧凑宽度屏上（iPhone Duo 折起时的外屏：比别的 iPhone 宽、矮，系统栏在侧边那一列）：
// 一张张竖版卡居中排开，两边各露出邻卡一截（网页版 hero-row：卡 324×557、圆角 28），卡上只有画面和居中的字标；
// 卡下一排页码，不自动轮播。何时用由主页按可用空间的宽高比决定（见 HomeView），不认设备型号。

struct HeroCards: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let items: [HeroItem]
    let width: CGFloat
    /// 卡片高度（不含下面那排页码）
    let cardHeight: CGFloat
    @State private var current: String?

    var body: some View {
        let calm = reduceMotion
        let cardW = min(max(220, width * 0.85), 360)
        let side = (width - cardW) / 2
        let cardH = min(max(300, cardHeight), cardW * 557 / 324)
        VStack(spacing: 20) {
            if items.isEmpty {
                RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Theme.surface)
                    .frame(width: cardW, height: cardH)
                    .frame(maxWidth: .infinity)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 11) {
                        ForEach(items) { it in
                            ZoomLink(route: .movie(it.video), slot: "herocard") {
                                HeroCard(item: it, width: cardW, height: cardH)
                            }
                            .accessibilityIdentifier("hero-card")
                            .id(it.id)
                            .scrollTransition(.interactive, axis: .horizontal) { content, phase in
                                content
                                    .scaleEffect(phase.isIdentity || calm ? 1 : 0.94)
                                    .opacity(phase.isIdentity ? 1 : 0.7)
                            }
                        }
                    }
                    .scrollTargetLayout()
                }
                .contentMargins(.horizontal, side, for: .scrollContent)
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

/// 一张卡：竖版画面铺满（圆角 28），下半截渐暗，字标居中压在约三分之二高的地方
struct HeroCard: View {
    @Environment(AppModel.self) private var model
    let item: HeroItem
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        let m = model.meta(item.video)
        ZStack {
            Color.clear
                .overlay { RemoteImage(url: URL(string: item.hero.poster ?? item.hero.background ?? ""), maxPixel: 1100) }
                .clipped()
            LinearGradient(stops: [
                .init(color: .clear, location: 0.45),
                .init(color: .black.opacity(0.55), location: 0.78),
                .init(color: .black.opacity(0.8), location: 1),
            ], startPoint: .top, endPoint: .bottom)
            LogoImage(url: URL(string: item.hero.logo ?? "") ?? TMDBImage.url(m?.logo, "w500"), height: 76,
                      fallback: model.title(item.video))
                .frame(maxWidth: min(252, width * 0.78))
                .position(x: width / 2, y: height * 0.68)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
    }
}

/// 页码：玻璃胶囊里一排圆点，当前那颗是纯白的短胶囊，其余半透明；点哪颗翻到哪张
struct PageDots: View {
    let ids: [String]
    @Binding var current: String?

    var body: some View {
        let cur = current ?? ids.first
        HStack(spacing: 9) {
            ForEach(ids, id: \.self) { id in
                // 当前这一页是一颗短胶囊（Games「首页」的页码），其余是圆点
                Capsule()
                    .fill(id == cur ? Color.white : Color.white.opacity(0.5))
                    .frame(width: id == cur ? 20 : 7, height: 7)
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
