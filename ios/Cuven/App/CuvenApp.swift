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

    init() {
        // 播放走系统的「影视」音频会话：静音键不影响声音，画中画 / 锁屏后继续放
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        URLCache.shared = URLCache(memoryCapacity: 16 << 20, diskCapacity: 256 << 20)
        Perf.startWatchdog()
        // 设置里不再有「触感」开关（系统「声音与触感」里已经有：C95）。以前在 App 里关掉过的，
        // 清掉那一项，Haptics.enabled 回到默认的开（系统里关了触感，系统自己会让它不震）
        UserDefaults.standard.removeObject(forKey: "haptics")
        // 账户在这里建：登录状态（钥匙串里 30 天内的会话）一出来就决定要不要欢迎页，第一帧就盖上，不闪主页
        let acc = AccountStore()
        _account = State(initialValue: acc)
        _welcome = State(initialValue: WelcomeGate.shouldShow(acc))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .overlay { if privacy { PrivacyGateView { privacy = false } } }
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
    }
}

enum AppTab: Hashable { case home, library, account, search }

/// 系统标签栏：主页 / 资料库 / 账户，搜索单独一颗（搜索标签：横在底下时 iOS 26 把它拆出来）。
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
                HomeView().duoHidesTabBar().id(roots[.home, default: 0])
            }
            Tab("资料库", systemImage: "square.stack.fill", value: AppTab.library) {
                LibraryView().duoHidesTabBar().id(roots[.library, default: 0])
            }
            // 网页版导航胶囊里的头像：账户与设置
            Tab("账户", systemImage: "person.crop.circle.fill", value: AppTab.account) {
                AccountView(asTab: true).duoHidesTabBar().id(roots[.account, default: 0])
            }
            Tab(value: AppTab.search, role: .search) {
                SearchView().duoHidesTabBar().id(roots[.search, default: 0])
            }
        }
        .environment(\.duoColumn, column)
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
        .onAppear { if !account.loginRequired || account.isLoggedIn { model.start() } }
        .onChange(of: account.isLoggedIn) { _, now in if now { model.start() } }
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
