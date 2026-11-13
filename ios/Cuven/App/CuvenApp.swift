import SwiftUI
import AVFoundation

@main
struct CuvenApp: App {
    @State private var model = AppModel()

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
    /// Duo 的导航里再点一下当前那一格：这一格回到根页面（系统标签栏自带这个行为，自己的导航要自己做）
    @State private var roots: [AppTab: Int] = [:]

    var body: some View {
        // 外面这一层守着安全区（含键盘）：拿它在窗口里的框，算出四边的安全区和键盘高度；
        // 里面那一层铺满整屏放内容 —— 加了 .ignoresSafeArea() 的那一层自己读到的安全区是 0
        GeometryReader { safe in
            let sf = safe.frame(in: .global)
            GeometryReader { g in
                let full = g.frame(in: .global)
                let inset = EdgeInsets(top: max(0, sf.minY - full.minY), leading: max(0, sf.minX - full.minX),
                                       bottom: max(0, full.maxY - sf.maxY), trailing: max(0, full.maxX - sf.maxX))
                layout(size: g.size, inset: inset)
            }
            .ignoresSafeArea()
        }
        .onAppear { model.start() }
    }

    private func layout(size: CGSize, inset: EdgeInsets) -> some View {
        Perf.count("root")
        let duo = Duo.mode(window: size)
        // 强制成折起形态、设备本身又没有右侧那一列（模拟器）：补一列黑边，模拟外屏
        let fakeColumn: CGFloat = (duo == .folded && Duo.forced != nil && inset.trailing < 20) ? Duo.foldedColumn : 0
        let column = max(inset.trailing, fakeColumn)
        // 侧边导航条放在左侧安全区里面（横拿时左边是灵动岛 / 摄像头），内容整体让出这一条
        let railLead = duo == .rail ? inset.leading + Duo.railWidth : 0
        let navH = DuoNav.height(duo)
        // 竖向居中略偏下；键盘起来时整枚挪到键盘上面，放不下就贴着顶
        let lo = inset.top + navH / 2 + 8
        let hi = size.height - inset.bottom - navH / 2 - 10
        let navY = max(lo, min(duo == .folded ? size.height * 0.55 : size.height / 2, hi))
        let navX = duo == .folded
            ? (column >= 56 ? size.width - column / 2 : size.width - 12 - DuoNav.width(duo) / 2)
            : inset.leading + Duo.railWidth / 2
        return ZStack(alignment: .topLeading) {
            Color.black
            tabs
                .padding(.trailing, fakeColumn)
                .padding(.leading, railLead)
            if duo != .off {
                DuoNav(tab: $tab, mode: duo) { roots[$0, default: 0] += 1 }
                    .position(x: navX, y: navY)
                    .animation(.smooth(duration: 0.28), value: navY)
            }
        }
        .environment(\.duoMode, duo)
    }

    private var tabs: some View {
        TabView(selection: $tab) {
            Tab("主页", systemImage: "house.fill", value: AppTab.home) { HomeView().duoHidesTabBar().id(roots[.home, default: 0]) }
            Tab("资料库", systemImage: "square.stack.fill", value: AppTab.library) { LibraryView().duoHidesTabBar().id(roots[.library, default: 0]) }
            Tab("我的", systemImage: "person.crop.circle", value: AppTab.me) { ProfileView().duoHidesTabBar().id(roots[.me, default: 0]) }
            Tab(value: AppTab.search, role: .search) { SearchView().duoHidesTabBar().id(roots[.search, default: 0]) }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .onChange(of: tab) { _, _ in Haptics.selection() }
    }
}
