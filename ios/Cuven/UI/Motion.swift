import SwiftUI
import UIKit

// MARK: - 动效：向 Apple TV 靠拢
//
// · 缩放转场：点海报 / 卡片 / 大图，详情页从那张卡上放大出来；返回时缩回原处（也能下滑 / 捏合手势退出）。
// · 按压回弹：卡片按下去略缩、松手弹回。
// · 指针悬停：iPad 接了触控板 / 鼠标，指针停在卡上略放大（PointerLift；全宽的大图、一整行的不放大）。
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
    /// 要从外面推页（分享来的链接打开详情页：HomeView）时给一个路径
    var path: Binding<NavigationPath>? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        Group {
            if let path {
                NavigationStack(path: path) { root }
            } else {
                NavigationStack { root }
            }
        }
        .environment(\.zoomNamespace, ns)
    }

    private var root: some View {
        content()
            // iPhone Duo「侧边一列」的形态：推进去的每一页也要收起系统标签栏（不然推进去它又回来了，见 DuoNav.swift）
            .duoHidesTabBar()
            // 每一页顶上导航栏底下的滚动边缘都是柔和的（渐进式模糊，用户要求不许有硬边界线）
            .dsSoftTopEdge()
            .navigationDestination(for: Route.self) { RouteView(route: $0).duoHidesTabBar().dsSoftTopEdge() }
            .navigationDestination(for: ZoomTarget.self) { t in
                RouteView(route: t.route).navigationTransition(.zoom(sourceID: t, in: ns)).duoHidesTabBar().dsSoftTopEdge()
            }
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
                .modifier(PointerLift(on: press))
                .matchedTransitionSource(id: target, in: ns)
        } else {
            NavigationLink(value: route) { label() }
                .buttonStyle(PressableStyle(scale: press ? 0.96 : 1))
                .modifier(PointerLift(on: press))
        }
    }
}

/// iPad 接了触控板 / 鼠标：指针停在卡上，整张卡（连同底下的字）放大一点点、移开缩回，和按压回弹一个手感；没有指针时什么都不做。
/// 不用系统的 .hoverEffect(.lift)：它不知道卡的形状，圆形头像、底下带字的圆角海报都按整个矩形浮起来，影子和高光是直角的。
/// 不按压的（press: false，全宽的大图）也不放大：整块大图跟着指针动太晃。
/// 只放大卡那么大的：量一下自己多大，宽过 480（卡最宽约 460：featureCardWidth）或扁得像一行（宽超过高的 2.2 倍）的不放大——
/// 搜索结果、请求中心那几行、演员页「最新」那一条按压照样回弹，但指针一停整行放大 3%，宽的一行两边各多出近十点，
/// 挤到外面那块底的边上，旁边不跟着放大的按钮、分隔线也对不齐了
private struct PointerLift: ViewModifier {
    let on: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var size: CGSize = .zero

    private var lifts: Bool {
        on && size.width > 0 && size.width <= 480 && size.width <= size.height * 2.2
    }

    func body(content: Content) -> some View {
        // iPhone 不接触控板 / 鼠标，永远停不上指针：什么都不挂。以前每张卡都挂一个量尺寸的观察，
        // 懒加载的一排每滑出一张新卡就多写一次状态、多重算一遍（滑动时的卡顿）；iPad 照旧
        if UIDevice.current.userInterfaceIdiom == .phone {
            content
        } else {
            content
                // 量的是排版的大小，scaleEffect 不改它，放大了也不会来回跳
                .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
                // 「减弱动态效果」打开时不缩放（DSMotion.adapt 的规矩）
                .scaleEffect(lifts && hovering && !reduceMotion ? 1.03 : 1)
                .onHover { h in
                    guard on else { return }
                    withAnimation(DSMotion.press) { hovering = h }
                }
        }
    }
}

/// 全 App 的动效令牌（docs/ios-design.md「动效规范」）：按压、切换、出现 / 消散、大块进出、淡入淡出各一种，
/// 新写的动效都从这里取，同一类东西动起来是同一个手感；「减弱动态效果」打开时换成短淡入（F59）
enum DSMotion {
    /// 按下去略缩略暗、松手带弹性回来（卡片、按钮、标题链接）
    static let press = Animation.spring(response: 0.28, dampingFraction: 0.68)
    /// 小切换：开关、符号替换、选中的那块滑过去
    static let snap = Animation.snappy(duration: 0.26)
    /// 出现 / 消散：从略小、略糊里弹出来
    static let appear = Animation.spring(response: 0.5, dampingFraction: 0.86)
    /// 大块进出：钉住的条、弹层里的整页、名字和主按钮
    static let hero = Animation.spring(response: 0.6, dampingFraction: 0.82)
    /// 颜色和画面的淡入淡出（取色、预告片出画面）
    static let fade = Animation.easeInOut(duration: 0.4)

    /// 「减弱动态效果」打开时：一律换成短淡入，不弹、不缩放
    static func adapt(_ a: Animation, reduce: Bool) -> Animation { reduce ? .easeInOut(duration: 0.2) : a }
}

/// 按下去略缩、略暗，松手带一点弹性回来（Apple TV 卡片的手感）；全 App 的按压反馈都是它（DSMotion.press）
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.96

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .brightness(configuration.isPressed ? -0.06 : 0)
            .animation(DSMotion.press, value: configuration.isPressed)
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
    let video: Video

    func body(content: Content) -> some View {
        content.contextMenu { MovieMenuItems(video: video) }
    }
}

struct SeriesMenu: ViewModifier {
    let series: Series

    func body(content: Content) -> some View {
        content.contextMenu { SeriesMenuItems(series: series) }
    }
}

/// 一部电影的菜单项（长按菜单和列表里的「•••」共用）：播放 / 继续播放、加入想看
struct MovieMenuItems: View {
    @Environment(AppModel.self) private var model
    let video: Video

    var body: some View {
        Button(model.playback.resumePosition(video.path) != nil ? "继续播放" : "播放", systemImage: "play.fill") {
            PlayerCoordinator.shared.play(PlayRequest(path: video.path, name: video.name, title: model.title(video),
                                                      subtitle: model.year(video).map { String($0) },
                                                      artwork: model.backgroundArtString(video)), model: model)
        }
        WatchlistMenuButton(key: video.path, kind: .movie)
    }
}

/// 一部剧的菜单项：加入想看
struct SeriesMenuItems: View {
    let series: Series

    var body: some View {
        WatchlistMenuButton(key: series.path, kind: .series)
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

// MARK: - 下拉刷新

/// 系统的下拉刷新（.refreshable），只多管一件事：转圈至少转 0.8 秒，并且等手松开了才收。
/// 刷新瞬间就做完的时候（演示数据什么也不用做、没网立刻失败），系统会在手还按着、转圈刚出来时就收它，
/// UIRefreshControl 就卡在「刷新中」：转圈一直在、整页被往下顶着一截，再怎么拉也不动
/// （CI 的折叠屏截图里一卡半个小时；XCUITest 也一直等不到 App 空闲，每一步都要等两分钟）
private struct SettledRefresh: ViewModifier {
    let action: () async -> Void
    /// 手还在屏上拖着（滚动阶段 .interacting）
    @State private var dragging = false

    func body(content: Content) -> some View {
        content
            .onScrollPhaseChange { _, phase in dragging = phase == .interacting || phase == .tracking }
            .refreshable {
                let start = ContinuousClock.now
                await action()
                try? await Task.sleep(until: start + .milliseconds(800), clock: .continuous)
                // 手还按着就再等等（最多 5 秒），松了手再收
                var waited = 0
                while dragging && waited < 50 {
                    try? await Task.sleep(for: .milliseconds(100))
                    waited += 1
                }
            }
    }
}

extension View {
    /// 用它代替 .refreshable（见 SettledRefresh）
    func settledRefreshable(_ action: @escaping () async -> Void) -> some View {
        modifier(SettledRefresh(action: action))
    }
}

/// 弹层里的导航栈：和主导航栈一样，顶栏底下的滚动边缘一律柔和（渐进式模糊，用户要求不许有硬边界线）
struct SoftNavigationStack<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        NavigationStack { content().dsSoftTopEdge() }
            .dsSoftTopEdge()
    }
}
