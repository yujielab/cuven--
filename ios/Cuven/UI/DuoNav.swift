import SwiftUI
import UIKit

// MARK: - iPhone Duo「侧边一列」形态里的导航：照 Netflix 的那一枚竖向胶囊
//
// 用户要求「把我的应用导航栏样式也改的和 Netflix 一样」，圈出的目标是 Netflix 侧边那一列底下的一枚竖向胶囊
// （主页 / 片段 / 搜索 / 头像，搜索就在胶囊里，头像是最后一格）。我们的五格：主页 / 资料库（片段图标）/ 请求 / 搜索 / 头像
// （用户选的：「请求」保留为一格；上面那组投屏 / 下载 / 通知按钮不要）。
// 量 Netflix 截图（折起竖拿，3 倍图）：
//   · 胶囊宽 60、离后缘 18、离底 18（中线离后缘 48，和状态栏同一条线）；用户后来要「稍微小一点点」：现在宽 56、每格 54，
//     中线对着状态栏的中线（真机量的 48.5）；身子是深色（比系统标签栏暗得多），
//     最外一圈边留给玻璃：边上反射、折射着旁边海报的颜色（用户指出的）；
//   · 每格 58 点（第一格、最后一格的中心离胶囊两头 36）；矮的横屏按那一列的高往下压，最小 46；
//   · 图标是白色线条（约 22 点、2 点粗），没选中的白色 45%；头像 24 点、圆角 7，一直是原色；
//   · 选中那一格垫一块平的、亮一点的竖胶囊（44 × 56，离胶囊两边 8），没有玻璃边，在格子之间滑过去。
// 系统标签栏在这几种形态里也会竖着进侧边那一列（D5、D6），可它的样子（48 宽、实心图标、带边的选中块）和 Netflix 不一样，
// 所以只在这几种形态下收起系统标签栏，换成这里自己画的（对 D7「别改系统的摆放」的有意偏离，见 docs/ios-design.md「iPhone Duo」）。
// 展开竖拿、别的 iPhone、iPad 照旧用系统标签栏。
// 认「侧边一列」：iOS 27.1 起看系统说的竖栏在哪一边（toolbarVerticalEdge），再加窗口大小、左右安全区一边宽一边窄，
// 三样有一样对上就算（以前只看窗口大小，用户真机截图里出来的还是系统标签栏，自己画的那枚没出来）。

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

    /// iPhone Duo 折起（外屏，横竖都算）：短边超过 440 点（别的 iPhone 都到不了）、不到 600 点（展开是 600 以上）
    @MainActor
    static func isFolded(window: CGSize) -> Bool {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return false }
        let short = min(window.width, window.height)
        return short > 440 && short < 600
    }

    /// 左右安全区一边宽（侧边那一列：状态栏、竖着的栏）一边几乎没有：iPhone 横拿两边一样宽，不算。
    /// 收起系统标签栏以后那一列还有状态栏，安全区照样一边宽（约 84–97 点），不会来回跳
    @MainActor
    static func hasSideColumn(leading: CGFloat, trailing: CGFloat) -> Bool {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return false }
        return max(leading, trailing) >= 40 && min(leading, trailing) < 20
    }

    /// 第一次排版之前先按窗口场景估一个大小（排完按真实的更正），免得第一帧先露出系统标签栏再换掉
    @MainActor
    static var initialWindowSize: CGSize {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        return scene?.coordinateSpace.bounds.size ?? .zero
    }
}

/// 侧边那一列的中线离窗口边多远：系统的时间、信号、返回钮和 DuoNav 都对着这条线（CI 截图量过：折起竖拿离右边 48.5 点）。
/// DuoNavLayer 排版时把它量到的记在这里。全屏盖上来的页面（刷视频页）要对着同一条线摆自己的钮：
/// 那一层自己读到的右侧安全区只有 84 点，按它居中离右边 42 点，比状态栏偏外约 6 点（用户截图：控件没和状态栏对齐）
@MainActor @Observable
final class DuoRail {
    static let shared = DuoRail()
    /// 中线离后缘多远；还没量过、或者那一列在前缘时是 nil
    var fromTrailing: CGFloat?
}

private struct DuoColumnKey: EnvironmentKey {
    static let defaultValue = false
}

private struct DuoBottomBarKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// 现在是不是「侧边一列」的形态（系统标签栏收起，用 DuoNav）
    var duoColumn: Bool {
        get { self[DuoColumnKey.self] }
        set { self[DuoColumnKey.self] = newValue }
    }

    /// 别的 iPhone 形态（展开竖拿、普通 iPhone）：系统标签栏也收起，底下用横着的那枚 DuoNav（用户要求和 iPhone Duo 的设计一致）
    var duoBottomBar: Bool {
        get { self[DuoBottomBarKey.self] }
        set { self[DuoBottomBarKey.self] = newValue }
    }
}

/// 「侧边一列」的形态里收起系统标签栏。各标签页的根视图和推进去的每一页都要挂：推进去的页面不挂，系统会把栏带回来
struct DuoHidesTabBar: ViewModifier {
    @Environment(\.duoColumn) private var column
    @Environment(\.duoBottomBar) private var bottomBar

    func body(content: Content) -> some View {
        // 底下那枚横着的胶囊顶替系统标签栏的时候也收起（用户要求 iPhone 上都和 iPhone Duo 的设计一致）
        let hide = column || bottomBar
        content
            .toolbar(hide ? .hidden : .automatic, for: .tabBar)
            .background { TabBarGuard(hidden: hide) }
    }
}

/// UIKit 那一层再按一下：「侧边一列」的形态里系统标签栏一律藏住。只靠 SwiftUI 的 .toolbar(.hidden, for: .tabBar)，
/// 系统会把它带回来，和侧边导航叠成两份（用户截图：展开横拿，详情页右下角两套导航错开叠着）——
/// 推进去的页面没挂上面那个修饰（以前详情页里点演员推进的演员页就没挂），回来以后它不再自己藏；转屏、展开 / 合上换了窗口大小也可能。
/// 所以每一页出现、转完屏、形态一变，都看一眼 UITabBarController：该藏没藏就藏；不是这几种形态却藏着，就放出来
/// （这个 App 只在这几种形态里藏系统标签栏）
private struct TabBarGuard: UIViewControllerRepresentable {
    let hidden: Bool

    func makeUIViewController(context: Context) -> Probe { Probe() }

    func updateUIViewController(_ vc: Probe, context: Context) {
        vc.hidden = hidden
        vc.apply()
    }

    final class Probe: UIViewController {
        var hidden = false

        override func loadView() {
            let v = UIView()
            v.isUserInteractionEnabled = false
            v.accessibilityElementsHidden = true
            view = v
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            apply()
        }

        override func viewWillTransition(to size: CGSize, with coordinator: any UIViewControllerTransitionCoordinator) {
            super.viewWillTransition(to: size, with: coordinator)
            coordinator.animate(alongsideTransition: nil) { [weak self] _ in
                Task { @MainActor [weak self] in self?.apply() }
            }
        }

        /// 排到下一轮再看：SwiftUI 这一轮自己也在改标签栏，等它改完（这个 App 只在用自己画的导航时藏系统标签栏）
        func apply() {
            Task { @MainActor [weak self] in
                guard let self, self.viewIfLoaded?.window != nil, let tabs = self.tabBarController else { return }
                if tabs.isTabBarHidden != self.hidden {
                    tabs.setTabBarHidden(self.hidden, animated: false)
                    Perf.log("tab bar \(self.hidden ? "hidden" : "shown") by the guard")
                }
            }
        }
    }
}

extension View {
    func duoHidesTabBar() -> some View { modifier(DuoHidesTabBar()) }
}

// MARK: - 导航本身

/// 竖向玻璃导航（照 Netflix）：一枚胶囊里 主页 / 资料库 / 请求 / 搜索 / 头像，只有图标。
/// 点一格就切过去（触感由 RootView 统一给：.sensoryFeedback，只那一下）；再点一下当前那一格，这一格回到根页面（系统标签栏自带这个行为，自己画的要自己做）
struct DuoNav: View {
    @Binding var tab: AppTab
    /// 再点一下当前那一格：回到这一格的根页面
    var reselect: (AppTab) -> Void
    /// 每格多高（DuoNavLayer 按那一列的高给：放得下就 58）
    var pitch: CGFloat = DuoNav.pitch
    /// 内容在胶囊的哪一边（胶囊在后缘时内容在前缘）：环境反光从这一边打过来
    var contentLeading = true
    /// 竖着（侧边那一列）还是横着（别的 iPhone 形态，压在页面底下）
    var axis: Axis = .vertical
    @Namespace private var ns
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AccountStore.self) private var account

    /// 胶囊宽 56、每格 54，离底 18（Netflix 截图量的是 60 / 58；用户要求「导航栏可以稍微小一点点」）
    static let width: CGFloat = 56
    static let pitch: CGFloat = 54
    /// 矮的横屏往下压到这里为止（点得到的范围仍有 44：C33）
    static let minPitch: CGFloat = 44
    static let margin: CGFloat = 18

    /// 第一格、最后一格的中心离胶囊两头多远（每格 54 的时候是 34；比例照 Netflix 的 36 / 58）
    static func endPad(_ p: CGFloat) -> CGFloat { (p * 36 / 58).rounded() }

    /// 整枚胶囊的高
    static func height(pitch p: CGFloat) -> CGFloat { endPad(p) * 2 + p * CGFloat(items.count - 1) }

    enum Glyph {
        case symbol(String)
        /// Netflix「片段」那种：一块竖屏里一个播放键，后面再叠一块
        case clips
        /// 自己的头像（原色、圆角方块）
        case avatar
        /// 请求中心：一张圆角竖卡，中间一个「+」（请求添加一部片）
        case request
        /// 主页：圆顶的房子，里面靠下一道短横（照用户给的参考）
        case home
    }

    struct Item: Identifiable {
        let tab: AppTab
        let glyph: Glyph
        let label: String
        let id: String
    }

    static let items: [Item] = [
        Item(tab: .home, glyph: .home, label: "主页", id: "nav-home"),
        Item(tab: .library, glyph: .clips, label: "探索", id: "nav-library"),
        Item(tab: .requests, glyph: .request, label: "请求", id: "nav-requests"),
        Item(tab: .search, glyph: .symbol("magnifyingglass"), label: "搜索", id: "nav-search"),
        Item(tab: .account, glyph: .avatar, label: "我的", id: "nav-account"),
    ]

    var body: some View {
        let p = pitch
        let e = Self.endPad(p)
        let h = Self.height(pitch: p)
        let vertical = axis == .vertical
        let stack = vertical ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
        stack {
            ForEach(Self.items) { item in
                itemButton(item, pitch: p)
            }
        }
        .padding(vertical ? Edge.Set.vertical : Edge.Set.horizontal, e - p / 2)
        .frame(width: vertical ? Self.width : h, height: vertical ? h : Self.width)
        // 深色的身子：Netflix 那枚比系统标签栏暗得多（量到约是底下画面 × 0.4，画面照样透得过来），
        // 可最外一圈边是亮的、带着旁边海报的颜色（用户指出的：目标图里胶囊左边缘泛着旁边画面的蓝紫、往下一点泛红）——
        // 那是 Liquid Glass 的边在折射、反射周围的画面。所以玻璃本身不染色（整块压黑会把这圈边也压掉），
        // 只在里面垫一层黑，把那圈边留给玻璃。
        // 用户要求「明显化侧面导航栏的反射光线」：边留宽一点（离边 3.5 点、柔边 2），玻璃用 .clear（更通透、边上的折射更强，
        // 身子靠里面那层黑照样是暗的），再沿边描一道很细的高光（左上亮、右下弱一点，像光从左上照过来打在玻璃边上）
        .background {
            ZStack {
                Capsule()
                    .fill(DuoNavInk.body)
                    .padding(3.5)
                    .blur(radius: 2)
                // 环境反光（用户要求「边缘应该反射蓝色区域中的各种主要颜色混合渐变光线」）：里面一层柔光。
                // 只有竖着的要：侧边那一列底下是黑的，玻璃折射不到旁边的画面，得自己取色；
                // 横着的压在页面上面，画面就在玻璃后面，玻璃自己在 GPU 上折射、反射它（不用取色，不占主线程）
                if vertical { NavAmbientGlow(layer: .inner, height: h, contentLeading: contentLeading) }
            }
            .allowsHitTesting(false)
        }
        .overlay {
            ZStack {
                Capsule()
                    .strokeBorder(DuoNavInk.rim, lineWidth: 1)
                // 边上一道反光
                if vertical { NavAmbientGlow(layer: .rim, height: h, contentLeading: contentLeading) }
            }
            .allowsHitTesting(false)
        }
        .glassEffect(.clear.interactive(), in: Capsule())
        // 选中的那块在格子之间滑过去；「减弱动态效果」打开时不滑、不弹，原地短短地淡过去（F59，DSMotion.adapt 的规矩；
        // 以前是一下子跳过去）
        .animation(DSMotion.adapt(Animation.snappy(duration: 0.32), reduce: reduceMotion), value: tab)
    }

    private func itemButton(_ item: Item, pitch p: CGFloat) -> some View {
        let on = tab == item.tab
        let vertical = axis == .vertical
        // 选中垫的那块：横跨 40（离胶囊两边 8），顺着 52（比格子短 2）；横着的胶囊里转过来
        let across = Self.width - 16
        let along = min(52, p - 2)
        let pillW = vertical ? across : along
        let pillH = vertical ? along : across
        return Button {
            if on { reselect(item.tab); Haptics.light() } else { tab = item.tab }
        } label: {
            glyph(item.glyph, on: on)
                .frame(width: vertical ? Self.width : p, height: vertical ? p : Self.width)
                .background {
                    if on {
                        Capsule()
                            .fill(DuoNavInk.selection)
                            .frame(width: pillW, height: pillH)
                            // 「减弱动态效果」时每格各用各的 id：不配对就不滑，旧的淡出、新的淡入
                            .matchedGeometryEffect(id: reduceMotion ? item.id : "duo-nav-selection", in: ns)
                    }
                }
                .overlay {
                    if item.tab == .requests { DuoNavBadge(count: badgeCount) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.9))
        .accessibilityLabel(item.label)
        .accessibilityValue(item.tab == .requests && badgeCount > 0 ? "\(badgeCount) 项进行中" : "")
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier(item.id)
    }

    @ViewBuilder
    private func glyph(_ g: Glyph, on: Bool) -> some View {
        // 没选中的白色 45%（Netflix）；选中的纯白
        let ink = on ? Color.white : DuoNavInk.idle
        switch g {
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(ink)
        case .clips:
            ClipsGlyph()
                .stroke(ink, style: StrokeStyle(lineWidth: 1.9, lineCap: .round, lineJoin: .round))
                .overlay { ClipsGlyph.Play().fill(ink) }
                .frame(width: 17, height: 22.5)
        case .request:
            RequestGlyph()
                .stroke(ink, style: StrokeStyle(lineWidth: 1.9, lineCap: .round, lineJoin: .round))
                .frame(width: 23, height: 23)
        case .home:
            HomeGlyph()
                .stroke(ink, style: StrokeStyle(lineWidth: 1.9, lineCap: .round, lineJoin: .round))
                .frame(width: 23, height: 23)
        case .avatar:
            // 头像一直是原色（Netflix 那颗没选中也不压暗）；还没有头像就是线条的人像
            if let img = AvatarCache.shared.avatar(for: account.session?.username) {
                Image(uiImage: img)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(width: 22, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 6.5, style: .continuous))
            } else {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(ink)
            }
        }
    }

    /// 请求那一格的角标：进行中的请求 + 请求中心里还没确认的（和系统标签栏上的一样）
    private var badgeCount: Int { RequestStore.shared.activeCount + RequestBasket.shared.items.count }
}

/// 请求那一格的角标。以前有了就冒出来、没了就消失、数字直接跳：现在冒出来 / 收回去带一点缩放（像系统标签栏的角标），
/// 数字变的时候滚过去；「减弱动态效果」打开时只淡入淡出（F59）
private struct DuoNavBadge: View {
    let count: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if count > 0 {
                Text(count > 99 ? "99+" : "\(count)")
                    .font(.system(size: 11, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                    .padding(.horizontal, 4.5)
                    .frame(minWidth: 17, minHeight: 17)
                    .background(Capsule().fill(DuoNavInk.badge))
                    .transition(reduceMotion ? AnyTransition.opacity : AnyTransition.opacity.combined(with: .scale(scale: 0.5)))
            }
        }
        .animation(DSMotion.adapt(DSMotion.snap, reduce: reduceMotion), value: count)
        .offset(x: 10, y: -9)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private enum DuoNavInk {
    /// 胶囊身子的深色：垫在玻璃里面的一层黑（离边 2 点，边留给玻璃去反射周围画面的颜色）。
    /// 普通玻璃压在黑底上量到约 31，Netflix 那枚是 12：× 0.4
    static let body = Color.black.opacity(0.62)
    /// 边上那道高光：左上最亮，中段几乎看不见，右下再亮一点
    static let rim = LinearGradient(stops: [
        .init(color: .white.opacity(0.5), location: 0),
        .init(color: .white.opacity(0.12), location: 0.3),
        .init(color: .white.opacity(0.06), location: 0.6),
        .init(color: .white.opacity(0.28), location: 1),
    ], startPoint: .topLeading, endPoint: .bottomTrailing)
    /// 选中垫的那块：平的、亮一点
    static let selection = Color.white.opacity(0.1)
    static let idle = Color.white.opacity(0.45)
    static let badge = Color(red: 1, green: 0.23, blue: 0.19)
}

/// 「片段」图标（Netflix 第二格那种）：前面一块竖屏（圆角），后面错开叠一块（只画露出来的右边和底边）。设计框 18 × 24
struct ClipsGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 18, sy = rect.height / 24
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy) }
        var p = Path()
        // 前面那块：(0,0)–(13,19)，圆角 3
        p.addRoundedRect(in: CGRect(origin: pt(0, 0), size: CGSize(width: 13 * sx, height: 19 * sy)),
                         cornerSize: CGSize(width: 3 * sx, height: 3 * sy), style: .continuous)
        // 后面那块 (5,5)–(18,24) 露出来的部分：上沿右段 → 右边 → 底边 → 左边下段
        p.move(to: pt(13, 5))
        p.addLine(to: pt(15, 5))
        p.addQuadCurve(to: pt(18, 8), control: pt(18, 5))
        p.addLine(to: pt(18, 21))
        p.addQuadCurve(to: pt(15, 24), control: pt(18, 24))
        p.addLine(to: pt(8, 24))
        p.addQuadCurve(to: pt(5, 21), control: pt(5, 24))
        p.addLine(to: pt(5, 19))
        return p
    }

    /// 前面那块里的播放键（实心）
    struct Play: Shape {
        func path(in rect: CGRect) -> Path {
            let sx = rect.width / 18, sy = rect.height / 24
            var p = Path()
            p.move(to: CGPoint(x: rect.minX + 4.8 * sx, y: rect.minY + 6.4 * sy))
            p.addLine(to: CGPoint(x: rect.minX + 9.6 * sx, y: rect.minY + 9.5 * sy))
            p.addLine(to: CGPoint(x: rect.minX + 4.8 * sx, y: rect.minY + 12.6 * sy))
            p.closeSubpath()
            return p
        }
    }
}

// MARK: - 图标（用户要求「Apple 风格，克制、优雅、简洁、大方」）
//
// 主页、片段、请求、光学扫描同一套：线条约 2 点、圆头圆角，设计框 24 × 24，只用最少的笔画说清是什么。

/// 主页：圆顶的房子，里面靠下一道短横——照用户给的参考（不画烟囱、不画门）。
/// 屋脊、屋檐（屋顶和墙接上的两个角，用户圈出来要圆角）、墙脚都是圆角
struct HomeGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        let ox = rect.midX - 12 * s, oy = rect.midY - 12 * s
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * s, y: oy + y * s) }
        var p = Path()
        // 从左屋檐圆角的上端起，沿屋顶到屋脊（圆）、右屋檐（圆）、右墙、墙脚（圆）、左墙，回到左屋檐（圆）
        p.move(to: pt(5.12, 9.30))
        p.addLine(to: pt(10.6, 4.2))
        p.addQuadCurve(to: pt(13.4, 4.2), control: pt(12, 3.0))
        p.addLine(to: pt(18.88, 9.30))
        p.addQuadCurve(to: pt(20.4, 12.6), control: pt(20.4, 10.6))
        p.addLine(to: pt(20.4, 18))
        p.addQuadCurve(to: pt(17.4, 21), control: pt(20.4, 21))
        p.addLine(to: pt(6.6, 21))
        p.addQuadCurve(to: pt(3.6, 18), control: pt(3.6, 21))
        p.addLine(to: pt(3.6, 12.6))
        p.addQuadCurve(to: pt(5.12, 9.30), control: pt(3.6, 10.6))
        p.closeSubpath()
        p.move(to: pt(9.4, 16.4))
        p.addLine(to: pt(14.6, 16.4))
        return p
    }
}

/// 请求中心：一张圆角竖卡，中间一个「+」——请求添加一部片（和「片段」那几张竖卡是一家）
struct RequestGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        let ox = rect.midX - 12 * s, oy = rect.midY - 12 * s
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * s, y: oy + y * s) }
        var p = Path()
        // 圆角大一点（用户圈出来要更圆）：14 × 18 的卡、圆角 5
        p.addRoundedRect(in: CGRect(origin: pt(5, 3), size: CGSize(width: 14 * s, height: 18 * s)),
                         cornerSize: CGSize(width: 5 * s, height: 5 * s), style: .continuous)
        p.move(to: pt(9.2, 12))
        p.addLine(to: pt(14.8, 12))
        p.move(to: pt(12, 9.2))
        p.addLine(to: pt(12, 14.8))
        return p
    }
}

/// 光学扫描：取景框的四个角，中间一个小圆（镜头）。以前中间是一团粒子，太碎
struct ScanGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        let ox = rect.midX - 12 * s, oy = rect.midY - 12 * s
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * s, y: oy + y * s) }
        var p = Path()
        p.move(to: pt(2.8, 8.6)); p.addLine(to: pt(2.8, 5.8)); p.addQuadCurve(to: pt(5.8, 2.8), control: pt(2.8, 2.8)); p.addLine(to: pt(8.6, 2.8))
        p.move(to: pt(15.4, 2.8)); p.addLine(to: pt(18.2, 2.8)); p.addQuadCurve(to: pt(21.2, 5.8), control: pt(21.2, 2.8)); p.addLine(to: pt(21.2, 8.6))
        p.move(to: pt(21.2, 15.4)); p.addLine(to: pt(21.2, 18.2)); p.addQuadCurve(to: pt(18.2, 21.2), control: pt(21.2, 21.2)); p.addLine(to: pt(15.4, 21.2))
        p.move(to: pt(8.6, 21.2)); p.addLine(to: pt(5.8, 21.2)); p.addQuadCurve(to: pt(2.8, 18.2), control: pt(2.8, 21.2)); p.addLine(to: pt(2.8, 15.4))
        p.addEllipse(in: CGRect(x: ox + 8.6 * s, y: oy + 8.6 * s, width: 6.8 * s, height: 6.8 * s))
        return p
    }
}

/// 系统标签栏（别的 iPhone、iPad、展开竖拿的 Duo）上「主页」「请求」两格用同一套图标：画成模板图（跟着标签栏的颜色走）
@MainActor
enum NavGlyphImage {
    static let home: UIImage = template(HomeGlyph())
    static let request: UIImage = template(RequestGlyph())
    /// 「探索」：和侧边那一列同一个「片段」图标（设计复查：以前系统标签栏上是实心的 square.stack.fill，和别的线条图标不是一家）
    static let clips: UIImage = clipsImage()

    /// 片段图标：外框按 template 的线条规矩描边，里面的播放键实心；画在 26 × 26 里正中那块 17 × 22.5（和侧边胶囊里一样的比例）
    private static func clipsImage() -> UIImage {
        let size: CGFloat = 26
        let r = CGRect(x: 4.5, y: 1.75, width: 17, height: 22.5)
        let img = UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { ctx in
            let c = ctx.cgContext
            c.addPath(ClipsGlyph().path(in: r).cgPath)
            c.setLineWidth(1.9)
            c.setLineCap(.round)
            c.setLineJoin(.round)
            c.setStrokeColor(UIColor.black.cgColor)
            c.strokePath()
            c.addPath(ClipsGlyph.Play().path(in: r).cgPath)
            c.setFillColor(UIColor.black.cgColor)
            c.fillPath()
        }
        return img.withRenderingMode(.alwaysTemplate)
    }

    private static func template<S: Shape>(_ shape: S) -> UIImage {
        let size: CGFloat = 26
        let img = UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { ctx in
            let c = ctx.cgContext
            c.addPath(shape.path(in: CGRect(x: 0, y: 0, width: size, height: size)).cgPath)
            c.setLineWidth(1.9)
            c.setLineCap(.round)
            c.setLineJoin(.round)
            c.setStrokeColor(UIColor.black.cgColor)
            c.strokePath()
        }
        return img.withRenderingMode(.alwaysTemplate)
    }
}

/// 胶囊的环境反光（两层：里面一层柔光、边上一道反光）。只有这一小块读 NavAmbient 的颜色：
/// 颜色每一帧都在往新取到的颜色上走，胶囊的按钮、角标不跟着重画
private struct NavAmbientGlow: View {
    enum Layer { case inner, rim }
    let layer: Layer
    let height: CGFloat
    let contentLeading: Bool

    var body: some View {
        // NavAmbient 从胶囊靠内容那一边外面取的颜色，从上到下一串；取样的那一条比胶囊上下各长 NavAmbient.overhang，
        // 渐变也一样往外伸，颜色和旁边对得上
        let stops = NavAmbient.shared.stops
        let ext = NavAmbient.overhang / max(1, height)
        let top = UnitPoint(x: 0.5, y: -ext), bottom = UnitPoint(x: 0.5, y: 1 + ext)
        let lit = contentLeading ? UnitPoint.leading : UnitPoint.trailing
        if stops.count >= 2 {
            switch layer {
            case .inner:
                // 靠内容那一边亮，往中间淡掉（像旁边画面的光打进玻璃里）
                // 以前再糊 5 点（blur）：颜色一变整层就要重新糊一遍，滑的时候每帧都在糊，是卡的大头。
                // 遮罩本来就是从亮边到中线的软渐变，三段式的渐变（亮、半亮、无）看上去和糊过的一样软，省掉那一层滤镜
                Capsule()
                    .fill(LinearGradient(colors: stops, startPoint: top, endPoint: bottom))
                    .mask(LinearGradient(stops: [
                        .init(color: .white, location: 0),
                        .init(color: .white.opacity(0.45), location: 0.22),
                        .init(color: .white.opacity(0), location: 0.5),
                    ], startPoint: lit, endPoint: contentLeading ? .trailing : .leading))
                    .opacity(0.6)
            case .rim:
                // 旁边画面的主要颜色从上到下混成一条渐变，靠内容那一边最亮，绕到另一边淡掉
                Capsule()
                    .strokeBorder(LinearGradient(colors: stops, startPoint: top, endPoint: bottom), lineWidth: 1.8)
                    .mask(LinearGradient(colors: [.white, .white, .white.opacity(0)], startPoint: lit,
                                         endPoint: contentLeading ? UnitPoint(x: 0.75, y: 0.5) : UnitPoint(x: 0.25, y: 0.5)))
            }
        }
    }
}

/// 侧边胶囊的环境反光（用户要求「黄色边缘位置应该反射蓝色区域中的各种主要颜色混合渐变光线」）：
/// 胶囊挨着的那片画面（海报、剧照）不在胶囊正后面——后面是侧边那一列的黑——玻璃自己折射不到，所以自己取色：
/// 把胶囊靠内容那一边外面 64 点宽、上下各长 overhang 的一条，用 drawHierarchy 缩成 4 × 16 像素画下来，
/// 每一行取平均 → 从上到下 8 个颜色；颜色提一点饱和、亮度，黑的地方不发光（透明）。
///
/// 用户反馈「现在有延时」，以前慢在三处，这一版都改了：
/// · 以前用 Timer：它只在默认的 run loop 模式里走，手指按着滑的时候（tracking 模式）根本不取样，松手才追上来。
///   现在是显示链，加在 .common 模式里，滑着也照样取；
/// · 以前一秒四次，每次还和上一次各混一半，再叠 0.45 秒的动画：颜色落后半秒到一秒。现在画面在变的时候一秒 12 次
///   （一次取样太贵就降到 8、5 次；30 次的时候用户反馈「有点卡」），停下来以后一秒两次只看看变没变；
/// · 两次取样之间不跳：显示出来的颜色以 30 帧往最新取到的颜色上走（时间常数 90 毫秒），差不到 1/255 不重画，走到了就不再动；
/// · 反光那两层不再加模糊滤镜（颜色一变就要重新糊一遍）：遮罩本身就是软渐变。
/// 只在胶囊出现、App 在前台时取
@MainActor
@Observable
final class NavAmbient {
    static let shared = NavAmbient()
    /// 取样那一条比胶囊上下各长多少（渐变也往外伸这么多）
    static let overhang: CGFloat = 48

    /// 从上到下的反光颜色（空的：还没取到，不画反光）
    private(set) var stops: [Color] = []

    /// 胶囊在窗口里的位置、内容在它哪一边（DuoNavLayer 给）
    @ObservationIgnored var capsule: CGRect = .zero
    @ObservationIgnored var contentLeading = true
    @ObservationIgnored private var link: CADisplayLink?
    @ObservationIgnored private var users = 0
    /// 最新取到的颜色、眼下显示的颜色（0…1 的 RGB）
    @ObservationIgnored private var target: [SIMD4<Double>] = []
    @ObservationIgnored private var shown: [SIMD4<Double>] = []
    @ObservationIgnored private var lastSample: CFTimeInterval = 0
    @ObservationIgnored private var lastTick: CFTimeInterval = 0
    /// 画面在变：这个时刻之前都按快的节奏取
    @ObservationIgnored private var hotUntil: CFTimeInterval = 0
    /// 一次取样平均花多久（秒）：太贵就放慢
    @ObservationIgnored private var cost: Double = 0.003
    @ObservationIgnored private var fast: Bool?
    /// 上一次真的交给画面的颜色：差得够多（1/255 左右）才再交一次，不为看不出来的变化重画
    @ObservationIgnored private var published: [SIMD4<Double>] = []

    private static let cols = 4, rows = 16, outStops = 8

    func start() {
        users += 1
        guard link == nil else { return }
        let proxy = NavAmbientTick()
        proxy.owner = self
        let l = CADisplayLink(target: proxy, selector: #selector(NavAmbientTick.tick(_:)))
        // .common：手指按着滑的时候也走（Timer 在默认模式里，滑动时停）
        l.add(to: .main, forMode: .common)
        link = l
        fast = nil
        pace(fast: true)
        lastSample = 0
        lastTick = 0
    }

    func stop() {
        users = max(0, users - 1)
        guard users == 0 else { return }
        link?.invalidate()
        link = nil
    }

    /// 显示链的帧率：画面在变、颜色还在走的时候 30（渐变的颜色慢慢流过去，30 帧看不出和 60 帧的差别；
    /// 以前 60，ProMotion 上每帧都在重画反光），停下来降到 5 左右
    private func pace(fast on: Bool) {
        guard fast != on, let link else { return }
        fast = on
        link.preferredFrameRateRange = on
            ? CAFrameRateRange(minimum: 24, maximum: 30, preferred: 30)
            : CAFrameRateRange(minimum: 4, maximum: 8, preferred: 5)
    }

    fileprivate func tick(_: CADisplayLink) {
        let now = CACurrentMediaTime()
        let dt = lastTick == 0 ? 1.0 / 60 : min(0.1, max(0.001, now - lastTick))
        lastTick = now
        let hot = now < hotUntil
        // 画面在变：一秒 12 次（一次取样平均超过 4 毫秒降到 8 次，超过 8 毫秒降到 5 次）；停着：一秒 2 次只看变没变。
        // 以前一秒 30 次：每次都要整窗截一张，滑的时候主线程隔一帧就被占几毫秒，看着一顿一顿的（用户真机反馈「有点卡」）。
        // 两次取样之间颜色照样每帧往新颜色上走（ease），流过去的样子不变
        var gap: Double = hot ? (cost > 0.008 ? 0.2 : cost > 0.004 ? 0.125 : 0.083) : 0.5
        // 手指按着滑、松手后还在减速（run loop 在 tracking 模式）：一秒最多 8 次（和一次取样稍贵时同一档）。
        // 滑的时候主线程每一帧都很紧，整窗截一张最容易把那一帧挤掉（卡顿）；颜色照样每帧往新取到的上走，停下来马上回到一秒 12 次
        if hot, RunLoop.current.currentMode == RunLoop.Mode.tracking { gap = max(gap, 0.125) }
        if now - lastSample >= gap {
            lastSample = now
            sample(now: now)
        }
        let moving = ease(dt: dt)
        pace(fast: hot || moving)
    }

    /// 显示的颜色往最新取到的颜色上走一帧；还没走到返回 true
    private func ease(dt: Double) -> Bool {
        guard !target.isEmpty else { return false }
        var moving = false
        if shown.count != target.count {
            shown = target
        } else {
            // 时间常数 90 毫秒（取样间隔拉长了，走得稍慢一点，正好接上下一次取样，不停顿）
            let k = 1 - exp(-dt / 0.09)
            shown = zip(shown, target).map { (s, t) -> SIMD4<Double> in
                let d = t - s
                if max(abs(d.x), max(abs(d.y), abs(d.z))) > 0.004 { moving = true; return s + d * k }
                return t
            }
        }
        // 和上次交出去的差不到 1/255 左右：不重画
        if published.count == shown.count {
            let delta = zip(published, shown).map { (a, b) -> Double in
                let d = b - a
                return max(abs(d.x), max(abs(d.y), abs(d.z)))
            }.max() ?? 0
            if delta < 0.004 { return moving }
        }
        published = shown
        stops = shown.map(Self.glow)
        return moving
    }

    private func sample(now: CFTimeInterval) {
        guard UIApplication.shared.applicationState == .active, capsule.width > 1,
              let win = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .flatMap(\.windows).first(where: \.isKeyWindow), !Self.covered(win) else { return }
        let w: CGFloat = 64
        let r = CGRect(x: contentLeading ? capsule.minX - 2 - w : capsule.maxX + 2, y: capsule.minY - Self.overhang,
                       width: w, height: capsule.height + Self.overhang * 2).intersection(win.bounds)
        guard r.width > 4, r.height > 16 else { return }
        let cols = Self.cols, rows = Self.rows
        let began = CACurrentMediaTime()
        var px = [UInt8](repeating: 0, count: cols * rows * 4)
        let ok: Bool = px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: cols, height: rows, bitsPerComponent: 8, bytesPerRow: cols * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            // UIKit 的坐标是 y 往下：先翻过来，再把这一条缩进 cols × rows
            ctx.translateBy(x: 0, y: CGFloat(rows))
            ctx.scaleBy(x: 1, y: -1)
            ctx.scaleBy(x: CGFloat(cols) / r.width, y: CGFloat(rows) / r.height)
            ctx.translateBy(x: -r.minX, y: -r.minY)
            UIGraphicsPushContext(ctx)
            let done = win.drawHierarchy(in: win.bounds, afterScreenUpdates: false)
            UIGraphicsPopContext()
            return done
        }
        cost = cost * 0.8 + (CACurrentMediaTime() - began) * 0.2
        guard ok else { return }
        // 每一行取平均（0…1），两行并一个
        var rowsAvg: [SIMD4<Double>] = []
        for y in 0..<rows {
            var acc = SIMD4<Double>(0, 0, 0, 0)
            for x in 0..<cols {
                let i = (y * cols + x) * 4
                acc += SIMD4(Double(px[i]), Double(px[i + 1]), Double(px[i + 2]), 0) / 255
            }
            rowsAvg.append(acc / Double(cols))
        }
        let per = rows / Self.outStops
        var fresh: [SIMD4<Double>] = []
        for k in 0..<Self.outStops {
            var acc = SIMD4<Double>(0, 0, 0, 0)
            for j in 0..<per { acc += rowsAvg[k * per + j] }
            fresh.append(acc / Double(per))
        }
        // 和上一次取到的比：变了（滑动、换页、预告片在放）就接下来 0.6 秒都按快的节奏取
        if target.count == fresh.count {
            let change = zip(target, fresh).map { (a, b) -> Double in
                let d = b - a
                return max(abs(d.x), max(abs(d.y), abs(d.z)))
            }.max() ?? 0
            if change > 0.012 { hotUntil = now + 0.6 }
        } else {
            hotUntil = now + 0.6
        }
        target = fresh
    }

    /// 有全屏盖上来的页面（播放器、预告片、刷视频页）已经整个挡住 App：胶囊看不见，不取样。
    /// 以前播放时照样整窗截图（画面一直在变，一秒 12 次，截的还是视频层），播放器跟着卡顿。进出的动画里照常取
    private static func covered(_ win: UIWindow) -> Bool {
        var vc = win.rootViewController?.presentedViewController
        while let p = vc {
            if p.modalPresentationStyle == .fullScreen, !p.isBeingPresented, !p.isBeingDismissed { return true }
            vc = p.presentedViewController
        }
        return false
    }

    /// 一段画面的平均色 → 反光的颜色：饱和度 × 1.35、亮度提一点；暗的地方（亮度低于 0.08）不发光
    private static func glow(_ c: SIMD4<Double>) -> Color {
        let ui = UIColor(red: c.x, green: c.y, blue: c.z, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let alpha = min(1, max(0, (b - 0.08) / 0.25))
        return Color(hue: Double(h), saturation: Double(min(1, s * 1.35)), brightness: Double(min(1, b * 1.25 + 0.1)))
            .opacity(Double(alpha) * 0.95)
    }
}

/// 显示链的目标：弱引用 NavAmbient（显示链强引用它的目标）
@MainActor
private final class NavAmbientTick: NSObject {
    weak var owner: NavAmbient?

    @objc func tick(_ link: CADisplayLink) {
        guard let owner else {
            link.invalidate()
            return
        }
        owner.tick(link)
    }
}

/// 别的 iPhone 形态（展开竖拿、普通 iPhone）：横着的那枚 DuoNav 压在页面底下正中（用户要求「更新导航栏和 iPhone Duo 设计一致，
/// 并拥有光线反射」）。同一套：深色的身子、白色的高光边、选中垫一块、线条图标、头像、角标；
/// 反光交给 Liquid Glass 自己：画面就在这枚胶囊后面，玻璃在 GPU 上折射、反射它，不取色、不占主线程。
/// 离底：有 Home 指示条的屏离底 24（比安全区高 10），没有的离底 14。页面底下留出这一截（DuoBottomInset），最后一排滚得上来。
/// 键盘起来时不跟着挪：和系统标签栏一样被键盘盖住
struct DuoBottomNavLayer: View {
    @Binding var tab: AppTab
    var reselect: (AppTab) -> Void

    /// 横着的每格多宽（放得下就 64；窄屏往下压，最小 DuoNav.minPitch）
    static func pitch(width: CGFloat) -> CGFloat {
        let room = width - 2 * 24
        let fit = room / (CGFloat(DuoNav.items.count - 1) + 2 * 36 / 58)
        return min(64, max(DuoNav.minPitch, fit.rounded(.down)))
    }

    /// 胶囊底边离屏幕底多远
    static func bottomGap(safeBottom: CGFloat) -> CGFloat { max(safeBottom - 10, 14) }

    var body: some View {
        GeometryReader { safe in
            let sf = safe.frame(in: .global)
            GeometryReader { full in
                let ff = full.frame(in: .global)
                let bottom = max(0, ff.maxY - sf.maxY)
                let p = Self.pitch(width: full.size.width)
                DuoNav(tab: $tab, reselect: reselect, pitch: p, axis: .horizontal)
                    .position(x: full.size.width / 2,
                              y: full.size.height - Self.bottomGap(safeBottom: bottom) - DuoNav.width / 2)
            }
            .ignoresSafeArea()
        }
        .ignoresSafeArea(.keyboard)
    }
}

/// 底下那枚横着的胶囊顶替了系统标签栏：页面底下留出它的高度（56 + 8），最后一排滚得上来、不被胶囊盖住
/// （系统标签栏收起以后页面的安全区只剩 Home 指示条那一截）。只在用它的时候留
struct DuoBottomInset: ViewModifier {
    let on: Bool

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            if on { Color.clear.frame(height: DuoNav.width + 8).allowsHitTesting(false) }
        }
    }
}

/// 把 DuoNav 摆进侧边那一列：哪边的安全区宽就放哪边（系统说了竖栏在哪边就听系统的；没有像样的一列时贴右缘，按 64 点宽的一条摆），
/// 中线对着那一列的中线（状态栏的中线），离底 18。键盘起来时不跟着挪：和系统标签栏一样被键盘盖住。
/// 那一列矮（折起横拿）时每格往下压：胶囊顶上要给状态栏留出约 200 点。
///
/// 外面一层守着安全区（不算键盘），里面一层铺满整屏；两层在窗口里的框一比，就是四边的安全区
/// （加了 .ignoresSafeArea() 的那一层自己读到的安全区是 0，所以要这样量）
struct DuoNavLayer: View {
    @Binding var tab: AppTab
    /// 系统说的竖栏在哪一边（iOS 27.1 起才有；nil：按安全区哪边宽认）
    var edge: HorizontalEdge? = nil
    var reselect: (AppTab) -> Void

    /// 状态栏（连灵动岛、实时活动）在那一列顶上大约占多高
    private static let statusReserve: CGFloat = 200
    /// 状态栏那一列的中线离屏边多远：真机截图量的是 48.5（时间、电量圈、实时活动都对着它；Netflix 那一列也是 48）。
    /// 用户截图（红线）：以前按侧边安全区的一半摆，真机上那一列安全区是 84、一半是 42，胶囊比状态栏偏外 6 点；
    /// 模拟器上是 97、一半正好 48.5，所以那时候看着是对的。现在至少对着 48.5，那一列更宽时再按它的一半
    static let statusAxis: CGFloat = 48.5

    /// 一列多高时胶囊每格多高、整枚多高、顶在哪（详情页的弧形菜单钮要摆在状态栏和胶囊之间，同一套算法）
    static func capsule(columnHeight H: CGFloat) -> (pitch: CGFloat, height: CGFloat, top: CGFloat) {
        let room = H - DuoNav.margin - statusReserve
        let fit = room / (CGFloat(DuoNav.items.count - 1) + 2 * 36 / 58)
        let pitch = min(DuoNav.pitch, max(DuoNav.minPitch, fit.rounded(.down)))
        let h = DuoNav.height(pitch: pitch)
        return (pitch, h, H - DuoNav.margin - h)
    }

    var body: some View {
        GeometryReader { safe in
            let sf = safe.frame(in: .global)
            GeometryReader { full in
                let ff = full.frame(in: .global)
                let lead = max(0, sf.minX - ff.minX)
                let trail = max(0, ff.maxX - sf.maxX)
                let onLeading = edge.map { $0 == .leading } ?? (lead > trail && lead >= 44)
                let column = onLeading ? lead : trail
                let strip = column >= 44 ? column : 64
                let rail = max(strip / 2, Self.statusAxis)
                let x = onLeading ? rail : full.size.width - rail
                let cap = Self.capsule(columnHeight: full.size.height)
                let pitch = cap.pitch, h = cap.height
                let y = cap.top + h / 2
                DuoNav(tab: $tab, reselect: reselect, pitch: pitch, contentLeading: !onLeading)
                    .position(x: x, y: y)
                    // 环境反光要知道胶囊在窗口里的哪儿、内容在哪一边（NavAmbient 在这一条外面取色）
                    .onChange(of: CGRect(x: ff.minX + x - DuoNav.width / 2, y: ff.minY + y - h / 2, width: DuoNav.width, height: h),
                              initial: true) { _, r in
                        NavAmbient.shared.capsule = r
                        NavAmbient.shared.contentLeading = !onLeading
                    }
                    .onAppear { NavAmbient.shared.start() }
                    .onDisappear { NavAmbient.shared.stop() }
                    // 记下这条线（DuoRail：刷视频页的关闭钮、页码点也对着它）：列在前缘时记负数，只认后缘的
                    .onChange(of: onLeading ? -rail : rail, initial: true) { _, v in
                        let r: CGFloat? = v > 0 ? v : nil
                        guard DuoRail.shared.fromTrailing != r else { return }
                        DuoRail.shared.fromTrailing = r
                        Perf.log("duo rail \(abs(v)) pt from the \(v > 0 ? "trailing" : "leading") edge (column \(Int(strip)) pt)")
                    }
            }
            .ignoresSafeArea()
        }
        .ignoresSafeArea(.keyboard)
    }
}

/// iOS 27.1 起系统直接说竖栏在哪一边（toolbarVerticalEdge；没有竖栏的设备、场合是 nil）：认「侧边一列」最准的一样
@available(iOS 27.1, *)
struct VerticalBarProbe: View {
    @Environment(\.toolbarVerticalEdge) private var edge
    let report: (HorizontalEdge?) -> Void

    var body: some View {
        Color.clear
            .onChange(of: edge, initial: true) { _, e in report(e) }
    }
}
