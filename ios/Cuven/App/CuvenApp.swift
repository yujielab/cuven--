import SwiftUI
import AVFoundation

@main
struct CuvenApp: App {
    @State private var model = AppModel()
    @State private var account: AccountStore
    /// 欢迎页：只出一次（C75）——第一次以已登录状态打开，或第一次登录成功以后；点「确认并继续」淡出并记下「看过了」
    @State private var welcome: Bool
    /// 隐私同意闸门（网页版 __privacyGate）：欢迎页退场 0.5 秒后、或刚登录完，没同意过就盖上
    @State private var privacy = false
    /// 清除缓存动画的预览（UI 测试 / CI 截图用：-CuvenDemo YES -CuvenDissolvePreview YES 一打开就是那一屏，不清真的缓存）
    @State private var dissolvePreview = DemoData.enabled && UserDefaults.standard.bool(forKey: "CuvenDissolvePreview")

    init() {
        // 播放走系统的「影视」音频会话：静音键不影响声音，画中画 / 锁屏后继续放
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        URLCache.shared = URLCache(memoryCapacity: 16 << 20, diskCapacity: 256 << 20)
        Perf.startWatchdog()
        // 设置里不再有「触感」开关（系统「声音与触感」里已经有：C95）。以前在 App 里关掉过的，
        // 清掉那一项，Haptics.enabled 回到默认的开（系统里关了触感，系统自己会让它不震）
        UserDefaults.standard.removeObject(forKey: "haptics")
        // 网络速度「自动调整」：开始看网络变化（换网络时重测；关着自动调整时只记下现在是什么网络）
        NetworkAuto.shared.start()
        // 账户在这里建：登录状态（钥匙串里 30 天内的会话）一出来就决定要不要欢迎页，第一帧就盖上，不闪主页
        let acc = AccountStore()
        _account = State(initialValue: acc)
        _welcome = State(initialValue: WelcomeGate.shouldShow(acc))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .overlay { if privacy { PrivacyGateView { privacy = false } } }
                .fullScreenCover(isPresented: $dissolvePreview) {
                    CacheDissolveSheet(bytes: 1_240_000_000) { try? await Task.sleep(for: .seconds(1)) }
                }
                // 和网页版一样整屏盖在最上面（片库在底下照常加载）；退场是 0.45 秒的淡出
                .overlay {
                    if welcome {
                        WelcomeView {
                            WelcomeGate.markSeen()
                            withAnimation(.timingCurve(0.32, 0.72, 0, 1, duration: 0.45)) { welcome = false }
                            Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 500_000_000)
                                if PrivacyGate.shouldShow(account) { privacy = true }
                            }
                        }
                        .transition(.opacity)
                    }
                }
                .onAppear { if !welcome && PrivacyGate.shouldShow(account) { privacy = true } }
                // 刚登录成功：第一次就迎接一下（只此一次：C75），没出欢迎页就直接看要不要问隐私同意
                .onChange(of: account.isLoggedIn) { _, now in
                    guard now, !welcome else { return }
                    if WelcomeGate.shouldShow(account) {
                        withAnimation(.easeOut(duration: 0.3)) { welcome = true }
                    } else if PrivacyGate.shouldShow(account) {
                        privacy = true
                    }
                }
                .environment(model)
                .environment(account)
                .preferredColorScheme(.dark)
                .tint(.white)
        }
        // 弱网预先缓存的后台下载：App 不在前台时系统下完一批会叫醒 App，接上会话、收下结果、再排下一批（Precache）
        .backgroundTask(.urlSession(Precache.sessionID)) {
            await Precache.shared.handleBackgroundWake()
        }
        // 请求添加：App 不在前台时系统偶尔叫醒一次，看看进度有没有变，变了发本机通知（RequestStore）
        .backgroundTask(.appRefresh(RequestStore.refreshTask)) {
            await RequestStore.shared.handleBackgroundRefresh()
        }
        // iPad（用户要求，按 Apple 的做法）：接了键盘时 ⌘1–4 切换主页 / 资料库 / 请求 / 搜索，⌘F 搜索；
        // 按住 ⌘ 出来的快捷键表、iPadOS 26 的菜单栏「前往」里都有这几项
        .commands {
            CommandMenu("前往") {
                Button("主页") { AppNav.shared.go(.home) }.keyboardShortcut("1", modifiers: .command)
                Button("资料库") { AppNav.shared.go(.library) }.keyboardShortcut("2", modifiers: .command)
                Button("请求") { AppNav.shared.go(.requests) }.keyboardShortcut("3", modifiers: .command)
                Button("搜索") { AppNav.shared.go(.search) }.keyboardShortcut("4", modifiers: .command)
                Divider()
                Button("查找影片") { AppNav.shared.go(.search) }.keyboardShortcut("f", modifiers: .command)
            }
        }

    }
}

enum AppTab: Hashable { case home, library, requests, search }

/// 系统标签栏：主页 / 资料库 / 请求，搜索单独一颗（搜索标签：横在底下时 iOS 26 把它拆出来）。
/// 账户与设置不是标签：主页标题那一行右边的头像点开（用户要求：头像从侧边导航里分出来）。
///
/// iPhone Duo：导航栏与工具栏一律用系统的（返回在侧边那一列最上面）。标签栏在展开竖拿时也是系统的（横在底下）；
/// 折起（外屏，横竖都算）和展开横拿时，系统把标签栏竖着放进侧边那一列、搜索和别的格挤在一枚胶囊里——
/// 这几种形态下收起系统标签栏，换成 DuoNav（一枚竖向玻璃胶囊 + 单独一颗搜索圆钮，见 DuoNav.swift）。
/// 是不是这几种形态只看窗口大小（DuoLayout.isColumn），不认设备型号、不看安全区。
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(AccountStore.self) private var account
    @Environment(\.horizontalSizeClass) private var hsc
    @Environment(\.verticalSizeClass) private var vsc
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab: AppTab = .home
    /// 窗口大小（连安全区一起）：认 iPhone Duo 的「侧边一列」形态
    @State private var window: CGSize = DuoLayout.initialWindowSize
    /// 自己画的导航里再点一下当前那一格：这一格回到根页面（换一个 id，整页重建）
    @State private var roots: [AppTab: Int] = [:]

    private var showsLogin: Bool { account.loginRequired && !account.isLoggedIn }

    var body: some View {
        let column = DuoLayout.isColumn(window: window)
        TabView(selection: $tab) {
            Tab("主页", systemImage: "house.fill", value: AppTab.home) {
                HomeView().duoHidesTabBar().tint(.white).id(roots[.home, default: 0])
            }
            Tab("资料库", systemImage: "square.stack.fill", value: AppTab.library) {
                LibraryView().duoHidesTabBar().tint(.white).id(roots[.library, default: 0])
            }
            // 请求中心（用户要求）：角标是进行中的请求个数
            Tab("请求", systemImage: "tray.and.arrow.down.fill", value: AppTab.requests) {
                RequestCenterView().duoHidesTabBar().tint(.white).id(roots[.requests, default: 0])
            }
            .badge(RequestStore.shared.activeCount + RequestBasket.shared.items.count)
            Tab(value: AppTab.search, role: .search) {
                SearchView().duoHidesTabBar().tint(.white).id(roots[.search, default: 0])
            }
        }
        .environment(\.duoColumn, column)
        // 换标签：一下选择触感（系统标签栏和侧边那一列自己画的导航都走这里）
        .sensoryFeedback(.selection, trigger: tab)
        // 侧边一列的形态：自己画的导航，搜索单独一颗
        .overlay {
            if column {
                DuoNavLayer(tab: $tab) { roots[$0, default: 0] += 1 }
            }
        }
        // 量整个窗口（连安全区）：折起 / 展开、横竖一变就重新判断
        .background {
            Color.clear
                .ignoresSafeArea()
                .onGeometryChange(for: CGSize.self) { $0.size } action: { window = $0 }
        }
        // 标签栏不在滚动时缩小：HIG 只在标签栏带附件（迷你播放器之类）时这么做（C10）；标签名一字一词（C8）
        .onChange(of: tab) { _, _ in Haptics.selection() }
        .onChange(of: model.searchRequest) { _, q in if q != nil { tab = .search } }
        .modifier(BasketOpensRequests(tab: $tab))
        // iPad：标签栏能展开成侧边栏（iPadOS 26 浮在顶上的那一条）；13 寸横拿这种特别宽的窗口一打开就是侧边栏
        .modifier(PadTabStyle(wide: window.width >= DSMetrics.xlWidth))
        // 分享来的链接（隔空投送的 cuven://movie/…）：切到主页、推进那一部的详情页（DeepLink）
        .onOpenURL { url in
            tab = .home
            model.openLink(url)
        }
        .onChange(of: model.movies.count) { _, _ in model.retryPendingLink() }
        .alert("没有找到这部影片", isPresented: Binding(get: { model.linkMissing }, set: { model.linkMissing = $0 })) {
            Button("好", role: .cancel) {}
        } message: {
            Text("你的片库里没有这部影片。")
        }
        // 没登录：登录层整屏盖在最上面（和网页版的鉴权层一样：冷启动第一帧就盖着，不闪主页；
        // 登录成功淡出 0.2 秒，退出登录时 0.28 秒淡入）。盖着的时候底下的标签页不给读屏念
        .accessibilityHidden(showsLogin)
        .overlay {
            if showsLogin {
                LoginView()
                    .transition(.opacity)
            }
        }
        .background {
            // 诊断：窗口尺寸 / 安全区 / 尺寸类别一变就记一行（看 iPhone Duo 上系统给的空间）
            GeometryReader { g in
                let i = g.safeAreaInsets
                let _ = LayoutLog.note("\(Int(g.size.width))x\(Int(g.size.height)) inset \(Int(i.top))/\(Int(i.leading))/\(Int(i.bottom))/\(Int(i.trailing)) "
                                       + "h=\(hsc.map { "\($0)" } ?? "-") v=\(vsc.map { "\($0)" } ?? "-")")
                Color.clear
            }
        }
        // 登录以后才开始取片库（登录页盖着的时候不在后面下载整个片库）
        .onAppear {
            if !account.loginRequired || account.isLoggedIn { model.start() }
            // 编辑推荐预告片的后台下载：一启动就接上（上次没下完的接着下，App 不在时下完的这时交回来）
            TrailerCache.shared.start()
            // 弱网预先缓存（详情页「预先画面质量处理」「下载」）的后台下载：一样接上
            Precache.shared.boot()
            #if DEBUG
            // UI 测试 / 截图：-CuvenTabletop YES 弹出半折播放面板的演示页（PlayerTabletop.swift）
            TabletopPreview.presentIfRequested()
            // -CuvenPlayerLab YES：打开光影实验室并放测试画面（PlayerLab.swift）
            PlayerLab.presentIfRequested()
            // -CuvenPairLab YES：光学配对自检（编码对照、离屏画一团云再用 GPU 网络解出来；PairViews.swift）
            PairLab.presentIfRequested()
            // -CuvenRequestPreview YES：推进一部「可请求添加」的剧集详情页（RequestViews.swift）
            RequestPreview.presentIfRequested(model)
            // -CuvenAllFilmsPreview YES：推进「全部影片」（AllFilmsView.swift）
            AllFilmsPreview.presentIfRequested(model)
            #endif
        }
        .onChange(of: account.isLoggedIn) { _, now in if now { model.start() } }
        // 头像预先存在本机（用户要求）：一启动、一登录就在后台拉好存上，回到前台再看一眼有没有换（同一张 10 分钟内不重拉）
        .task(id: account.session?.username) { await account.refreshAvatar() }
        // 请求添加的进度：登录了就开始轮询（换账户、退出登录时换掉）
        .task(id: account.session?.username) {
            // 有请求刚发行：刷新片库，详情页的「立即播放」马上找得到这部
            RequestStore.shared.onReleased = { [model] in
                await model.refreshLibrary()
                await model.refreshSeries()
            }
            RequestStore.shared.start(user: account.session?.username)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { @MainActor in await account.refreshAvatar() }
                NetworkAuto.shared.appBecameActive()
                RequestStore.shared.appBecameActive()
            } else if phase == .background {
                RequestStore.shared.scheduleBackgroundRefresh()
            }
        }
    }
}

/// 诊断：只在变化时记一行
@MainActor
enum LayoutLog {
    private static var last = ""
    static func note(_ key: String) {
        guard key != last else { return }
        last = key
        Perf.log("layout " + key)
    }
}

/// 详情页上已经加进请求中心的那部再按一下：切到「请求」去确认；键盘 ⌘1–4 / ⌘F（AppNav）切标签。
/// 单独一个修饰器：RootView 那一长串修饰器再长，编译器就推不动类型了
private struct BasketOpensRequests: ViewModifier {
    @Binding var tab: AppTab

    func body(content: Content) -> some View {
        content
            .onChange(of: RequestBasket.shared.openCenter) { _, go in
                guard go else { return }
                tab = .requests
                RequestBasket.shared.openCenter = false
            }
            .onChange(of: AppNav.shared.serial) { _, _ in
                if let t = AppNav.shared.wanted { tab = t }
            }
    }
}

/// 键盘快捷键（菜单命令）要切的标签：命令在 Scene 上，标签的状态在 RootView 里，经它传过去
@MainActor
@Observable
final class AppNav {
    static let shared = AppNav()
    private(set) var wanted: AppTab?
    /// 每按一次加一（连按同一个也算变了）
    private(set) var serial = 0

    func go(_ t: AppTab) {
        wanted = t
        serial += 1
    }
}

/// iPad 上的标签栏：iPadOS 26 浮在顶上、能展开成侧边栏的那种（sidebarAdaptable）；特别宽的窗口默认就是侧边栏。
/// 只认 iPad：iPhone（含展开的 Duo）照旧是底下的标签栏 / Duo 自己画的侧边导航。
/// 选中的颜色：App 全局是白色，侧边栏却拿它整条填底、字是白的，选中那一行成了一条看不见字的白条（iPad 截图）；
/// 标签栏、侧边栏用系统的蓝（Apple 自己的做法：顶上那一条选中的字、侧边栏选中那一行的底），页面里面每一页自己再设回白色
private struct PadTabStyle: ViewModifier {
    let wide: Bool

    func body(content: Content) -> some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
            content
                .tabViewStyle(.sidebarAdaptable)
                .defaultAdaptableTabBarPlacement(wide ? .sidebar : .tabBar)
                .tint(Color(uiColor: .systemBlue))
        } else {
            content
        }
    }
}
