import SwiftUI
import AVFoundation

@main
struct CuvenApp: App {
    @State private var model = AppModel()
    @State private var account = AccountStore()

    init() {
        // 播放走系统的「影视」音频会话：静音键不影响声音，画中画 / 锁屏后继续放
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        URLCache.shared = URLCache(memoryCapacity: 16 << 20, diskCapacity: 256 << 20)
        Perf.startWatchdog()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(account)
                .preferredColorScheme(.dark)
                .tint(.white)
        }
    }
}

enum AppTab: Hashable { case home, library, account, search }

/// 系统标签栏：主页 / 资料库，搜索单独一颗（搜索标签）。账户与设置在主页 / 资料库右上角的头像里。
///
/// iPhone Duo（按 Apple 的 Designing for iPhone Duo）：一律用系统的标签栏、导航栏与工具栏，不自己画。
/// 用 iOS 27.1 SDK 编译后，折起时（外屏）和展开横拿时系统把它们竖着放到侧边那一列：
/// 灵动岛、状态栏、工具栏（返回在最上）、标签栏自上而下；展开竖拿时恢复成横向的顶栏 / 底栏。
/// 内容只按安全区与尺寸类别排版，不认设备型号。
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(AccountStore.self) private var account
    @Environment(\.horizontalSizeClass) private var hsc
    @Environment(\.verticalSizeClass) private var vsc
    @State private var tab: AppTab = .home

    var body: some View {
        TabView(selection: $tab) {
            Tab("主页", systemImage: "house.fill", value: AppTab.home) { HomeView() }
            Tab("资料库", systemImage: "square.stack.fill", value: AppTab.library) { LibraryView() }
            // 网页版导航胶囊里的头像：账户与设置
            Tab("账户", systemImage: "person.crop.circle.fill", value: AppTab.account) { AccountView(asTab: true) }
            Tab(value: AppTab.search, role: .search) { SearchView() }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .onChange(of: tab) { _, _ in Haptics.selection() }
        .environment(\.openAccount, { tab = .account })
        .fullScreenCover(isPresented: .constant(account.loginRequired && !account.isLoggedIn)) {
            LoginView()
                .environment(model)
                .environment(account)
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
