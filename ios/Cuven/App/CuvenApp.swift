import SwiftUI
import AVFoundation

@main
struct CuvenApp: App {
    @State private var model = AppModel()

    init() {
        // 播放走系统的「影视」音频会话：静音键不影响声音，画中画 / 锁屏后继续放
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        URLCache.shared = URLCache(memoryCapacity: 16 << 20, diskCapacity: 256 << 20)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .tint(.white)
        }
    }
}

enum AppTab: Hashable { case home, library, me, search }

/// 底部是系统的 Liquid Glass 标签栏：主页 / 资料库 / 我的，搜索单独一颗（iOS 26 的搜索标签）。
/// iPhone Duo 上换成自己的竖向导航（见 Duo.swift）：折起竖拿是右缘那一列里的窄胶囊，展开 / 横拿是左侧导航条
struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var tab: AppTab = .home

    var body: some View {
        GeometryReader { g in
            let duo = Duo.mode(window: g.size)
            let realColumn = g.safeAreaInsets.trailing
            // 强制成折起形态、设备本身又没有右侧那一列（模拟器）：补一列黑边，模拟外屏
            let fakeColumn: CGFloat = (duo == .folded && Duo.forced != nil && realColumn < 20) ? Duo.foldedColumn : 0
            ZStack(alignment: .topLeading) {
                Color.black
                tabs
                    .padding(.trailing, fakeColumn)
                    .safeAreaInset(edge: .leading, spacing: 0) {
                        if duo == .rail { Color.clear.frame(width: Duo.railWidth) }
                    }
                if duo == .folded {
                    let col = max(realColumn, fakeColumn)
                    DuoNav(tab: $tab, mode: .folded)
                        .position(x: col >= 56 ? g.size.width - col / 2 : g.size.width - 12 - 27, y: g.size.height * 0.55)
                } else if duo == .rail {
                    DuoNav(tab: $tab, mode: .rail)
                        .position(x: g.safeAreaInsets.leading + Duo.railWidth / 2, y: g.size.height / 2)
                }
            }
            .environment(\.duoMode, duo)
        }
        .ignoresSafeArea()
        .onAppear { model.start() }
    }

    private var tabs: some View {
        TabView(selection: $tab) {
            Tab("主页", systemImage: "house.fill", value: AppTab.home) { HomeView().duoHidesTabBar() }
            Tab("资料库", systemImage: "square.stack.fill", value: AppTab.library) { LibraryView().duoHidesTabBar() }
            Tab("我的", systemImage: "person.crop.circle", value: AppTab.me) { ProfileView().duoHidesTabBar() }
            Tab(value: AppTab.search, role: .search) { SearchView().duoHidesTabBar() }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .onChange(of: tab) { _, _ in Haptics.selection() }
    }
}
