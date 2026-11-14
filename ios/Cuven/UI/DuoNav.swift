import SwiftUI
import UIKit

// MARK: - iPhone Duo「侧边一列」形态里的导航：胶囊 + 单独一颗搜索
//
// 标签栏横在底下时，iOS 26 会把 role: .search 那一格从胶囊里拎出来，单独放成旁边一颗圆钮。
// 可 iPhone Duo 折起（外屏，横竖都算）和展开横拿时，系统把标签栏竖着放进侧边那一列（D5、D6），
// 搜索就和主页 / 资料库 / 账户挤在同一枚胶囊里，SwiftUI 也没有办法把它拆开。
// 用户要搜索单独一颗，所以只在这几种形态下收起系统标签栏，换成这里自己画的：
//   · 一枚竖向 Liquid Glass 胶囊：主页 / 资料库 / 账户，只有图标；选中那一格垫一块更亮的玻璃，在格子之间滑过去；
//   · 下面隔 12 点，一颗单独的玻璃圆钮：搜索。
// 展开竖拿和别的 iPhone 照旧用系统标签栏（横在底下的那一条本来就把搜索拆开了）。
// 这是对 Designing for iPhone Duo「别改系统的摆放」（D7）的一处有意偏离，见 docs/ios-design.md「iPhone Duo」。

enum DuoLayout {
    /// 「侧边一列」的形态：iPhone Duo（只有它的 iPhone 短边超过 440 点）折起（短边不到 600，横竖都算），或展开横拿。
    /// 只看窗口大小、不看安全区：系统标签栏收起以后安全区可能跟着变，拿它来判断会来回跳
    @MainActor
    static func isColumn(window: CGSize) -> Bool {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return false }
        let short = min(window.width, window.height)
        guard short > 440 else { return false }
        return short < 600 || window.width > window.height
    }

    /// 第一次排版之前先按窗口场景估一个大小（排完按真实的更正），免得第一帧先露出系统标签栏再换掉
    @MainActor
    static var initialWindowSize: CGSize {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        return scene?.coordinateSpace.bounds.size ?? .zero
    }
}

private struct DuoColumnKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// 现在是不是「侧边一列」的形态（系统标签栏收起，用 DuoNav）
    var duoColumn: Bool {
        get { self[DuoColumnKey.self] }
        set { self[DuoColumnKey.self] = newValue }
    }
}

/// 「侧边一列」的形态里收起系统标签栏。各标签页的根视图和推进去的每一页都要挂：推进去的页面不挂，系统会把栏带回来
struct DuoHidesTabBar: ViewModifier {
    @Environment(\.duoColumn) private var column

    func body(content: Content) -> some View {
        content.toolbar(column ? .hidden : .automatic, for: .tabBar)
    }
}

extension View {
    func duoHidesTabBar() -> some View { modifier(DuoHidesTabBar()) }
}

// MARK: - 导航本身

/// 竖向玻璃导航：胶囊里是主页 / 资料库 / 账户，下面单独一颗搜索。
/// 点一格就切过去（触感由 RootView 的 onChange 统一给）；再点一下当前那一格，这一格回到根页面（系统标签栏自带这个行为，自己画的要自己做）
struct DuoNav: View {
    @Binding var tab: AppTab
    /// 再点一下当前那一格：回到这一格的根页面
    var reselect: (AppTab) -> Void
    @Namespace private var ns
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 胶囊宽 52、每格 48 高（点得到的范围都超过 44：C33），上下各留 4
    static let width: CGFloat = 52
    static let itemHeight: CGFloat = 48
    static let inset: CGFloat = 4
    /// 胶囊和搜索圆钮之间
    static let gap: CGFloat = 12
    static let capsuleHeight: CGFloat = itemHeight * CGFloat(items.count) + inset * 2
    /// 整组的高：胶囊 + 间隔 + 圆钮（外面按它摆位置）
    static let height: CGFloat = capsuleHeight + gap + width

    private struct Item: Identifiable {
        let tab: AppTab
        let symbol: String
        let label: String
        let id: String
    }

    private static let items: [Item] = [
        Item(tab: .home, symbol: "house.fill", label: "主页", id: "nav-home"),
        Item(tab: .library, symbol: "square.stack.fill", label: "资料库", id: "nav-library"),
        Item(tab: .account, symbol: "person.crop.circle.fill", label: "账户", id: "nav-account"),
    ]

    var body: some View {
        GlassEffectContainer(spacing: Self.gap) {
            VStack(spacing: Self.gap) {
                VStack(spacing: 0) {
                    ForEach(Self.items) { item in
                        itemButton(item)
                    }
                }
                .padding(.vertical, Self.inset)
                .frame(width: Self.width, height: Self.capsuleHeight)
                .glassEffect(.regular.interactive(), in: Capsule())

                searchButton
            }
        }
        // 选中的那块亮玻璃在格子之间滑过去；「减弱动态效果」打开时直接换过去，不带弹性（F59）
        .animation(reduceMotion ? nil : .snappy(duration: 0.32), value: tab)
    }

    private func itemButton(_ item: Item) -> some View {
        let on = tab == item.tab
        return Button {
            if on { reselect(item.tab); Haptics.light() } else { tab = item.tab }
        } label: {
            Image(systemName: item.symbol)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(on ? Color.white : Color.white.opacity(0.6))
                .frame(width: Self.width, height: Self.itemHeight)
                .background {
                    if on {
                        Capsule()
                            .fill(Color.white.opacity(0.16))
                            .frame(width: Self.width - Self.inset * 2, height: Self.width - Self.inset * 2)
                            .matchedGeometryEffect(id: "duo-nav-selection", in: ns)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.label)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier(item.id)
    }

    /// 搜索：单独一颗玻璃圆钮（和 iOS 26 横着的标签栏里那颗一样，离开胶囊自成一体）
    private var searchButton: some View {
        let on = tab == .search
        return Button {
            if on { reselect(.search); Haptics.light() } else { tab = .search }
        } label: {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(on ? Color.white : Color.white.opacity(0.75))
                .frame(width: Self.width, height: Self.width)
                .background {
                    if on {
                        Circle()
                            .fill(Color.white.opacity(0.16))
                            .padding(Self.inset)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .accessibilityLabel("搜索")
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier("nav-search")
    }
}

/// 把 DuoNav 摆进侧边那一列：哪边的安全区宽就放哪边（没有像样的一列时贴右缘，按 64 点宽的一条摆），
/// 整组贴着底（离底边 = 底部安全区，至少 16 点）。键盘起来时不跟着挪：和系统标签栏一样被键盘盖住。
///
/// 外面一层守着安全区（不算键盘），里面一层铺满整屏；两层在窗口里的框一比，就是四边的安全区
/// （加了 .ignoresSafeArea() 的那一层自己读到的安全区是 0，所以要这样量）
struct DuoNavLayer: View {
    @Binding var tab: AppTab
    var reselect: (AppTab) -> Void

    var body: some View {
        GeometryReader { safe in
            let sf = safe.frame(in: .global)
            GeometryReader { full in
                let ff = full.frame(in: .global)
                let lead = max(0, sf.minX - ff.minX)
                let trail = max(0, ff.maxX - sf.maxX)
                let bottom = max(0, ff.maxY - sf.maxY)
                let onLeading = lead > trail && lead >= 44
                let column = onLeading ? lead : trail
                let strip = column >= 44 ? column : 64
                let x = onLeading ? strip / 2 : full.size.width - strip / 2
                let y = full.size.height - max(bottom, 16) - DuoNav.height / 2
                DuoNav(tab: $tab, reselect: reselect)
                    .position(x: x, y: y)
            }
            .ignoresSafeArea()
        }
        .ignoresSafeArea(.keyboard)
    }
}
