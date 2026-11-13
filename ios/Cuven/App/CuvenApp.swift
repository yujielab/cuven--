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

/// 底部是系统的 Liquid Glass 标签栏：主页 / 资料库 / 我的，搜索单独一颗（iOS 26 的搜索标签）
struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var tab: AppTab = .home

    var body: some View {
        TabView(selection: $tab) {
            Tab("主页", systemImage: "house.fill", value: AppTab.home) { HomeView() }
            Tab("资料库", systemImage: "square.stack.fill", value: AppTab.library) { LibraryView() }
            Tab("我的", systemImage: "person.crop.circle", value: AppTab.me) { ProfileView() }
            Tab(value: AppTab.search, role: .search) { SearchView() }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .onChange(of: tab) { _, _ in Haptics.selection() }
        .onAppear { model.start() }
    }
}
