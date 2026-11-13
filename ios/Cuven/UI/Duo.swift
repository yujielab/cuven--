import SwiftUI
import UIKit

// MARK: - iPhone Duo（折叠屏）
//
// 与网页版同一套规矩：
//   · 折起竖拿（外屏 466 宽，右侧一整列安全区约 84pt，状态栏竖着排在那一列的右上角）：
//     底部标签栏换成贴右缘、挂在那一列里的一枚竖向玻璃胶囊 —— 主页 / 资料库 / 搜索 / 我的，只有图标，内容不让位；
//     首页大图是卡片态：卡落在左边那块、左右露出邻卡，卡下一排圆点（iOS 页码控件样式），不自动轮播。
//   · 展开（内屏短边 669），以及折起横拿：左侧竖排导航条，内容整体让出这一条。
// 认 Duo 看屏幕本身：别的 iPhone 短边最多 440pt。
// 模拟器里没有 Duo：启动参数 `-CuvenDuo folded|rail|off` 强制某种形态（folded 且没有右侧那一列时补一列黑边，模拟外屏）。

enum DuoMode: String {
    case off, folded, rail
}

enum Duo {
    static let railWidth: CGFloat = 88
    static let foldedColumn: CGFloat = 84

    static var forced: DuoMode? {
        guard let s = UserDefaults.standard.string(forKey: "CuvenDuo") else { return nil }
        return DuoMode(rawValue: s)
    }

    @MainActor
    static func mode(window: CGSize) -> DuoMode {
        let landscape = window.width > window.height
        if let f = forced { return f == .folded && landscape ? .rail : f }
        guard UIDevice.current.userInterfaceIdiom == .phone else { return .off }
        let short = min(window.width, window.height)
        guard short > 440 else { return .off }
        if short >= 600 { return .rail }              // 展开的内屏：不论横竖都用侧边导航条
        return landscape ? .rail : .folded
    }
}

private struct DuoModeKey: EnvironmentKey {
    static let defaultValue: DuoMode = .off
}

extension EnvironmentValues {
    var duoMode: DuoMode {
        get { self[DuoModeKey.self] }
        set { self[DuoModeKey.self] = newValue }
    }
}

/// Duo 下系统标签栏收起，换成自己的竖向导航（各页根视图与推进去的页面都挂一下）
struct DuoHidesTabBar: ViewModifier {
    @Environment(\.duoMode) private var duo
    func body(content: Content) -> some View {
        content.toolbar(duo == .off ? .automatic : .hidden, for: .tabBar)
    }
}

extension View {
    func duoHidesTabBar() -> some View { modifier(DuoHidesTabBar()) }
}

// MARK: - 竖向导航：折起是一枚只有图标的窄胶囊，侧边导航条带文字

struct DuoNav: View {
    @Binding var tab: AppTab
    let mode: DuoMode

    private var items: [(AppTab, String, String)] {
        [(.home, "house.fill", "主页"), (.library, "square.stack.fill", "资料库"),
         (.search, "magnifyingglass", "搜索"), (.me, "person.crop.circle.fill", "我的")]
    }

    var body: some View {
        let rail = mode == .rail
        VStack(spacing: rail ? 8 : 4) {
            ForEach(items, id: \.0) { item in
                let on = tab == item.0
                Button {
                    if !on { tab = item.0; Haptics.selection() }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: item.1).font(.system(size: rail ? 20 : 19, weight: .semibold))
                        if rail { Text(item.2).font(.system(size: 10, weight: .semibold)) }
                    }
                    .foregroundStyle(on ? Color.white : Color.white.opacity(0.55))
                    .frame(width: rail ? 62 : 44, height: rail ? 56 : 44)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: rail ? 16 : 22, style: .continuous)
                                .fill(Color.white.opacity(0.17))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.2)
                .accessibilityIdentifier("duo-nav-\(item.2)")
            }
        }
        .padding(rail ? 8 : 5)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: rail ? 26 : 27, style: .continuous))
        .animation(.snappy(duration: 0.25), value: tab)
    }
}

// MARK: - 折起竖拿的首页大图：卡片态

struct HeroCards: View {
    @Environment(AppModel.self) private var model
    let items: [HeroItem]
    let width: CGFloat
    let height: CGFloat
    let topInset: CGFloat
    @State private var current: String?

    var body: some View {
        let gap: CGFloat = 26, spacing: CGFloat = 12
        let cardW = max(200, width - gap * 2)
        let cardH = max(320, height - topInset - 10 - 30 - 16 - 30)
        VStack(spacing: 16) {
            if items.isEmpty {
                RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Theme.surface)
                    .frame(width: cardW, height: cardH)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: spacing) {
                        ForEach(items) { it in
                            NavigationLink(value: Route.movie(it.video)) {
                                HeroCard(item: it, width: cardW, height: cardH)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("hero-card")
                            .id(it.id)
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
        .padding(.top, topInset + 10)
        .frame(width: width, height: height, alignment: .top)
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
