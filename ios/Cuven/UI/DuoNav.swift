import SwiftUI
import UIKit

// MARK: - iPhone Duo「侧边一列」形态里的导航：照 Netflix 的那一枚竖向胶囊
//
// 用户要求「把我的应用导航栏样式也改的和 Netflix 一样」，圈出的目标是 Netflix 侧边那一列底下的一枚竖向胶囊
// （主页 / 片段 / 搜索 / 头像，搜索就在胶囊里，头像是最后一格）。我们的五格：主页 / 资料库（片段图标）/ 请求 / 搜索 / 头像
// （用户选的：「请求」保留为一格；上面那组投屏 / 下载 / 通知按钮不要）。
// 量 Netflix 截图（折起竖拿，3 倍图）：
//   · 胶囊宽 60、离后缘 18、离底 18（中线离后缘 48，和状态栏同一条线）；身子是深色（比系统标签栏暗得多），
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
        content
            .toolbar(column ? .hidden : .automatic, for: .tabBar)
            .background { TabBarGuard(hidden: column) }
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

        /// 排到下一轮再看：SwiftUI 这一轮自己也在改标签栏，等它改完
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
/// 点一格就切过去（触感由 RootView 的 onChange 统一给）；再点一下当前那一格，这一格回到根页面（系统标签栏自带这个行为，自己画的要自己做）
struct DuoNav: View {
    @Binding var tab: AppTab
    /// 再点一下当前那一格：回到这一格的根页面
    var reselect: (AppTab) -> Void
    /// 每格多高（DuoNavLayer 按那一列的高给：放得下就 58）
    var pitch: CGFloat = DuoNav.pitch
    @Namespace private var ns
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AccountStore.self) private var account

    /// 胶囊宽 60、每格 58，离后缘、离底各 18（Netflix 截图量的）
    static let width: CGFloat = 60
    static let pitch: CGFloat = 58
    /// 矮的横屏往下压到这里为止（点得到的范围仍超过 44：C33）
    static let minPitch: CGFloat = 46
    static let margin: CGFloat = 18

    /// 第一格、最后一格的中心离胶囊两头多远（58 的时候是 36）
    static func endPad(_ p: CGFloat) -> CGFloat { (p * 36 / 58).rounded() }

    /// 整枚胶囊的高
    static func height(pitch p: CGFloat) -> CGFloat { endPad(p) * 2 + p * CGFloat(items.count - 1) }

    enum Glyph {
        case symbol(String)
        /// Netflix「片段」那种：一块竖屏里一个播放键，后面再叠一块
        case clips
        /// 自己的头像（原色、圆角方块）
        case avatar
    }

    struct Item: Identifiable {
        let tab: AppTab
        let glyph: Glyph
        let label: String
        let id: String
    }

    static let items: [Item] = [
        Item(tab: .home, glyph: .symbol("house"), label: "主页", id: "nav-home"),
        Item(tab: .library, glyph: .clips, label: "资料库", id: "nav-library"),
        Item(tab: .requests, glyph: .symbol("tray.and.arrow.down"), label: "请求", id: "nav-requests"),
        Item(tab: .search, glyph: .symbol("magnifyingglass"), label: "搜索", id: "nav-search"),
        Item(tab: .account, glyph: .avatar, label: "我的", id: "nav-account"),
    ]

    var body: some View {
        let p = pitch
        let e = Self.endPad(p)
        VStack(spacing: 0) {
            ForEach(Self.items) { item in
                itemButton(item, pitch: p)
            }
        }
        .padding(.vertical, e - p / 2)
        .frame(width: Self.width, height: Self.height(pitch: p))
        // 深色的身子：Netflix 那枚比系统标签栏暗得多（量到约是底下画面 × 0.4，画面照样透得过来），
        // 可最外一圈边是亮的、带着旁边海报的颜色（用户指出的：目标图里胶囊左边缘泛着旁边画面的蓝紫、往下一点泛红）——
        // 那是 Liquid Glass 的边在折射、反射周围的画面。所以玻璃本身不染色（整块压黑会把这圈边也压掉），
        // 只在里面垫一层黑，把那圈边留给玻璃。
        // 用户要求「明显化侧面导航栏的反射光线」：边留宽一点（离边 3.5 点、柔边 2），玻璃用 .clear（更通透、边上的折射更强，
        // 身子靠里面那层黑照样是暗的），再沿边描一道很细的高光（左上亮、右下弱一点，像光从左上照过来打在玻璃边上）
        .background {
            Capsule()
                .fill(DuoNavInk.body)
                .padding(3.5)
                .blur(radius: 2)
                .allowsHitTesting(false)
        }
        .overlay {
            Capsule()
                .strokeBorder(DuoNavInk.rim, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .glassEffect(.clear.interactive(), in: Capsule())
        // 选中的那块在格子之间滑过去；「减弱动态效果」打开时直接换过去，不带弹性（F59）
        .animation(reduceMotion ? nil : .snappy(duration: 0.32), value: tab)
    }

    private func itemButton(_ item: Item, pitch p: CGFloat) -> some View {
        let on = tab == item.tab
        // 选中垫的那块：44 × 56（离胶囊两边 8，比格子矮 2）
        let pillW = Self.width - 16
        let pillH = min(56, p - 2)
        return Button {
            if on { reselect(item.tab); Haptics.light() } else { tab = item.tab }
        } label: {
            glyph(item.glyph, on: on)
                .frame(width: Self.width, height: p)
                .background {
                    if on {
                        Capsule()
                            .fill(DuoNavInk.selection)
                            .frame(width: pillW, height: pillH)
                            .matchedGeometryEffect(id: "duo-nav-selection", in: ns)
                    }
                }
                .overlay {
                    if item.tab == .requests { badge }
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
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(ink)
        case .clips:
            ClipsGlyph()
                .stroke(ink, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .overlay { ClipsGlyph.Play().fill(ink) }
                .frame(width: 18, height: 24)
        case .avatar:
            // 头像一直是原色（Netflix 那颗没选中也不压暗）；还没有头像就是线条的人像
            if let img = AvatarCache.shared.avatar(for: account.session?.username) {
                Image(uiImage: img)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(width: 24, height: 24)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            } else {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(ink)
            }
        }
    }

    /// 请求那一格的角标：进行中的请求 + 请求中心里还没确认的（和系统标签栏上的一样）
    private var badgeCount: Int { RequestStore.shared.activeCount + RequestBasket.shared.items.count }

    @ViewBuilder
    private var badge: some View {
        let n = badgeCount
        if n > 0 {
            Text(n > 99 ? "99+" : "\(n)")
                .font(.system(size: 11, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 4.5)
                .frame(minWidth: 17, minHeight: 17)
                .background(Capsule().fill(DuoNavInk.badge))
                .offset(x: 11, y: -10)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
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
                let x = onLeading ? strip / 2 : full.size.width - strip / 2
                let room = full.size.height - DuoNav.margin - Self.statusReserve
                let fit = room / (CGFloat(DuoNav.items.count - 1) + 2 * 36 / 58)
                let pitch = min(DuoNav.pitch, max(DuoNav.minPitch, fit.rounded(.down)))
                let h = DuoNav.height(pitch: pitch)
                let y = full.size.height - DuoNav.margin - h / 2
                DuoNav(tab: $tab, reselect: reselect, pitch: pitch)
                    .position(x: x, y: y)
                    // 记下这条线（DuoRail）：列在前缘时记负数，只认后缘的
                    .onChange(of: onLeading ? -strip : strip, initial: true) { _, v in
                        let rail: CGFloat? = v > 0 ? v / 2 : nil
                        guard DuoRail.shared.fromTrailing != rail else { return }
                        DuoRail.shared.fromTrailing = rail
                        Perf.log("duo rail \(Int(abs(v))) pt column on the \(v > 0 ? "trailing" : "leading") edge")
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
