import SwiftUI

// MARK: - 动效：向 Apple TV 靠拢
//
// · 缩放转场：点海报 / 卡片 / 大图，详情页从那张卡上放大出来；返回时缩回原处（也能下滑 / 捏合手势退出）。
// · 按压回弹：卡片按下去略缩、松手弹回。
// · 下拉拉伸：顶在最上面的大图，下拉时往上撑大。

/// 推进到详情页的目标。同一部片可能同时出现在好几排（今日推荐、最新加入、某一年……），
/// 按「哪一排」区分来源，缩放才会从点的那一张卡上出来
struct ZoomTarget: Hashable {
    let route: Route
    let slot: String
}

private struct ZoomNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    var zoomNamespace: Namespace.ID? {
        get { self[ZoomNamespaceKey.self] }
        set { self[ZoomNamespaceKey.self] = newValue }
    }
}

/// 每个标签页的导航栈：带缩放转场的命名空间，登记两种推进目标
struct ZoomStack<Content: View>: View {
    @Namespace private var ns
    @ViewBuilder var content: () -> Content

    var body: some View {
        NavigationStack {
            content()
                .navigationDestination(for: Route.self) { RouteView(route: $0) }
                .navigationDestination(for: ZoomTarget.self) { t in
                    RouteView(route: t.route).navigationTransition(.zoom(sourceID: t, in: ns))
                }
        }
        .environment(\.zoomNamespace, ns)
    }
}

/// 卡片链接：缩放转场推进详情 + 按压回弹
struct ZoomLink<Label: View>: View {
    @Environment(\.zoomNamespace) private var ns
    let route: Route
    let slot: String
    var press = true
    @ViewBuilder var label: () -> Label

    var body: some View {
        let target = ZoomTarget(route: route, slot: slot)
        if let ns {
            NavigationLink(value: target) { label() }
                .buttonStyle(PressableStyle(scale: press ? 0.96 : 1))
                .matchedTransitionSource(id: target, in: ns)
        } else {
            NavigationLink(value: route) { label() }
                .buttonStyle(PressableStyle(scale: press ? 0.96 : 1))
        }
    }
}

/// 按下去略缩、略暗，松手带一点弹性回来（Apple TV 卡片的手感）
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.96

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .brightness(configuration.isPressed ? -0.06 : 0)
            .animation(.spring(response: 0.28, dampingFraction: 0.68), value: configuration.isPressed)
    }
}

extension View {
    /// 顶在滚动视图最上面的大图：下拉时以底边为准往上撑大，填满拉出来的空隙
    func stretchy() -> some View {
        visualEffect { content, proxy in
            let minY = proxy.frame(in: .scrollView(axis: .vertical)).minY
            let h = max(1, proxy.size.height)
            let pull = max(0, minY)
            return content.scaleEffect(1 + pull / h, anchor: .bottom)
        }
    }
}

// MARK: - 长按菜单（Apple TV：长按海报弹出「播放 / 想看」，预览是那张卡本身）
//
// 不放「分享」：每张海报都挂一个分享项，无障碍快照（XCUITest 也靠它）在首页要走一两百个，主线程被拖住几十秒；分享在详情页的工具栏里

struct MovieMenu: ViewModifier {
    @Environment(AppModel.self) private var model
    let video: Video

    func body(content: Content) -> some View {
        content.contextMenu {
            Button(model.playback.resumePosition(video.path) != nil ? "继续播放" : "播放", systemImage: "play.fill") {
                let m = model.meta(video)
                PlayerCoordinator.shared.play(PlayRequest(path: video.path, name: video.name, title: model.title(video),
                                                          subtitle: model.year(video).map { String($0) },
                                                          artwork: m?.backdrop ?? m?.poster), model: model)
            }
            WatchlistMenuButton(key: video.path, kind: .movie)
        }
    }
}

struct SeriesMenu: ViewModifier {
    @Environment(AppModel.self) private var model
    let series: Series

    func body(content: Content) -> some View {
        content.contextMenu {
            WatchlistMenuButton(key: series.path, kind: .series)
        }
    }
}

/// 菜单里的「加入想看 / 从想看移除」
struct WatchlistMenuButton: View {
    @Environment(AppModel.self) private var model
    let key: String
    let kind: WatchItem.Kind

    var body: some View {
        let on = model.watchlist.contains(key)
        Button(on ? "从想看移除" : "加入想看", systemImage: on ? "minus.circle" : "plus.circle") {
            withAnimation(.snappy) { model.watchlist.toggle(key, kind: kind) }
            Haptics.light()
        }
    }
}

extension View {
    func movieMenu(_ v: Video) -> some View { modifier(MovieMenu(video: v)) }
    func seriesMenu(_ s: Series) -> some View { modifier(SeriesMenu(series: s)) }
}
