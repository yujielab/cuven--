import AVFoundation
import CuvenLighting
import SwiftUI
import UIKit

// MARK: - 控制面板：四排卡片 + 底下那一层 Metal 光影
//
// 卡片的位置由 PlayerPanelGrid 按「离折痕多远」排：桌面时是四行，书本时转成四列（参照 Netflix 在 iPhone Duo 上
// 「跟着你动」的控制）；换姿态时每一块从旧位置形变过去。
//
// 卡片的「面」由 CuvenLighting 的 MetalRenderer 画（深色半透明材质、画面投来的光、镜面反射、高光、边缘光，
// 卡片之间的黑底上还有一点从画面那边漏下来的光），SwiftUI 只画上面的 SF Symbols、文字和点按区。
// 每块卡片用 .litCard(...) 把自己在面板里的位置和形状报给渲染器（只在排版变了时报，不是每帧）；
// 按下 / 松开由 LitTileStyle 报给渲染器，卡面和符号一起缩到 0.97、卡面略亮。
// 光影的样子跟着影院光影的设置走（标准 / 影院 / 沉浸 + 微调），切换时渲染器在约 0.6 秒里平滑过渡。
// 没有 Metal（或着色器没编过）时退回 SwiftUI 画的深灰卡片，样子和交互都一样。
//
// 闲置（放着、5 秒没碰）：符号、文字和卡面（玻璃）一起淡出，画面映在面板上的光一直在、更新慢一些（省电）；
// 碰一下面板，卡面从 92% 长回原大、符号淡入，高光跟着回来——版面本身不动。

/// 面板里的尺寸
enum PlayerPanelStyle {
    /// 块与块之间（参照图量的约 8.6 点）
    static let gap: CGFloat = 8
    /// 圆角（参照图）；很小的块按短边收一点
    static let radius: CGFloat = 19
    static let fallbackTile = Color(white: 0.13)
    static let fallbackPressed = Color(white: 0.2)
    static let fallbackEdge = Color.white.opacity(0.07)
}

/// 实验室 / 设置页预览才用：模拟的折叠角度（度）；nil：用铰链读数或版面默认的角度
struct PlayerLightingOptions: Equatable {
    var simulatedFold: Double?
}

// MARK: 和渲染器之间

/// SwiftUI 这边握着的渲染器把手：卡片、模式、几何、播放器先记在这里，渲染器（重新）建起来时一次交过去
@MainActor
final class LightingHost {
    nonisolated static let space = "cuven-lighting-surface"

    /// 这台设备能用 Metal 光影（着色器都编好了）
    let isAvailable: Bool = MetalRenderer.shaderFailures.isEmpty
    private(set) var renderer: MetalRenderer?
    private var cards: [String: LightingCard] = [:]
    private var pressed: Set<String> = []
    private var mode = CinematicReflectionMode()
    private var geometry: LightingGeometry?
    private weak var player: AVPlayer?
    private var opacity: Float = 1
    private var idle = false
    private var simulatedFold: Double?
    private var hardwareFold: Double?
    private var sourceRange: LightingSourceRange = .unknown
    private var still: CGImage?
    var onDiagnostics: ((LightingDiagnostics) -> Void)? {
        didSet { renderer?.onDiagnostics = onDiagnostics }
    }
    var onPalette: ((SampledPalette) -> Void)? {
        didSet { renderer?.onPalette = onPalette }
    }

    func makeView() -> UIView {
        if renderer == nil, let r = MetalRenderer.make() {
            renderer = r
            r.mode = mode
            if let geometry { r.geometry = geometry }
            r.player = player
            r.sourceRange = sourceRange
            r.setStillImage(still)
            r.isIdle = idle
            r.onDiagnostics = onDiagnostics
            r.onPalette = onPalette
            r.setSurfaceOpacity(opacity)
            applyFold(r)
            for c in cards.values { r.setCard(c) }
            for id in pressed { r.setPressed(true, id: id) }
        }
        return renderer?.view ?? UIView()
    }

    func dismantle() {
        renderer?.stop()
        renderer = nil
    }

    func setCard(_ card: LightingCard) {
        cards[card.id] = card
        renderer?.setCard(card)
    }

    func removeCard(id: String) {
        cards.removeValue(forKey: id)
        pressed.remove(id)
        renderer?.removeCard(id: id)
    }

    func setPressed(_ on: Bool, id: String) {
        if on { pressed.insert(id) } else { pressed.remove(id) }
        renderer?.setPressed(on, id: id)
    }

    func update(mode: CinematicReflectionMode) {
        self.mode = mode
        renderer?.mode = mode
    }

    func update(geometry: LightingGeometry) {
        self.geometry = geometry
        renderer?.geometry = geometry
    }

    func attach(player: AVPlayer?) {
        self.player = player
        renderer?.player = player
    }

    /// HDR / 杜比视界：不取画面的帧，光影读剧照
    func setSourceRange(_ range: LightingSourceRange) {
        sourceRange = range
        renderer?.sourceRange = range
    }

    /// 这一集的剧照：取不了画面的帧时（HDR、片源还没认出来）光影读它
    func setStill(_ image: CGImage?) {
        still = image
        renderer?.setStillImage(image)
    }

    /// 闲置：卡片（玻璃）收拢、淡出，只留画面映在面板上的环境光；高光安静一点、更新慢一点
    func setIdle(_ on: Bool) {
        idle = on
        opacity = on ? 0 : 1
        renderer?.isIdle = on
        renderer?.setSurfaceOpacity(opacity)
    }

    func setFold(simulated: Double?, hardware: Double?) {
        simulatedFold = simulated
        hardwareFold = hardware
        if let renderer { applyFold(renderer) }
    }

    private func applyFold(_ r: MetalRenderer) {
        r.spatial.useSimulatedFold = simulatedFold != nil
        if let simulatedFold { r.spatial.simulatedFoldDegrees = simulatedFold }
        r.spatial.updateHardwareFold(hardwareFold)
    }
}

private struct LightingHostKey: EnvironmentKey {
    static let defaultValue: LightingHost? = nil
}

extension EnvironmentValues {
    var lightingHost: LightingHost? {
        get { self[LightingHostKey.self] }
        set { self[LightingHostKey.self] = newValue }
    }
}

/// 挂在面板最底下的 MTKView
struct LightingSurface: UIViewRepresentable {
    let host: LightingHost

    func makeCoordinator() -> LightingHost { host }

    func makeUIView(context: Context) -> UIView { host.makeView() }

    func updateUIView(_ uiView: UIView, context: Context) {}

    static func dismantleUIView(_ uiView: UIView, coordinator: LightingHost) {
        coordinator.dismantle()
    }
}

// MARK: 卡片

/// 把这一块报给渲染器当一张卡（位置、圆角、强调程度、是否亮着）；没有 Metal 时自己画一块深灰底
struct LitCardModifier: ViewModifier {
    let id: String
    var emphasis: Float = 0.5
    var lit = false
    var radius: CGFloat = PlayerPanelStyle.radius
    /// 同一组的卡片互相形变（第四行的工具 ↔ 亮度 / 音量那一条）
    var group: String?
    /// 状态一变就离场 / 进场（不等 SwiftUI 的淡出做完：卡片的形变要和符号同时开始）
    var active = true
    @Environment(\.lightingHost) private var host
    @State private var frame: CGRect = .zero

    func body(content: Content) -> some View {
        content
            .background {
                if host?.isAvailable != true {
                    PlayerFallbackTile(pressed: false, lit: lit, radius: radius)
                }
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(LightingHost.space)) } action: { frame = $0 }
            .onChange(of: active ? LightingCard(id: id, frame: frame, cornerRadius: radius, emphasis: emphasis, isLit: lit,
                                                morphGroup: group) : nil,
                      initial: true) { _, card in
                if let card { host?.setCard(card) } else { host?.removeCard(id: id) }
            }
            .onDisappear { host?.removeCard(id: id) }
    }
}

extension View {
    func litCard(_ id: String, emphasis: Float = 0.5, lit: Bool = false, radius: CGFloat = PlayerPanelStyle.radius,
                 group: String? = nil, active: Bool = true) -> some View {
        modifier(LitCardModifier(id: id, emphasis: emphasis, lit: lit, radius: radius, group: group, active: active))
    }

    /// 锁定时：变暗、点不动
    func playerLockable(_ locked: Bool) -> some View {
        self
            .opacity(locked ? 0.3 : 1)
            .allowsHitTesting(!locked)
            .disabled(locked)
            .animation(.snappy(duration: 0.26), value: locked)
    }
}

/// 没有 Metal 时的卡面：深灰圆角块 + 一圈很淡的边
struct PlayerFallbackTile: View {
    var pressed: Bool
    var lit = false
    var radius: CGFloat = PlayerPanelStyle.radius

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        shape
            .fill(lit ? Color.white : (pressed ? PlayerPanelStyle.fallbackPressed : PlayerPanelStyle.fallbackTile))
            .overlay(shape.strokeBorder(PlayerPanelStyle.fallbackEdge, lineWidth: 1))
    }
}

/// 整块都是按钮（点得到的范围就是那一块：I4）；按下去符号和卡面一起缩到 0.97（「减弱动态效果」时不缩：I9）
struct LitTileStyle: ButtonStyle {
    let id: String
    var lit = false
    var radius: CGFloat = PlayerPanelStyle.radius
    @Environment(\.lightingHost) private var host
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                if host?.isAvailable != true {
                    PlayerFallbackTile(pressed: configuration.isPressed, lit: lit, radius: radius)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(.spring(response: 0.24, dampingFraction: 0.82), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, pressed in
                host?.setPressed(pressed, id: id)
            }
    }
}

/// 卡片上的符号
struct PlayerIcon: View {
    let name: String
    let size: CGFloat
    var weight: Font.Weight = .regular
    var color: Color = .white

    init(_ name: String, size: CGFloat, weight: Font.Weight = .regular, color: Color = .white) {
        self.name = name
        self.size = size
        self.weight = weight
        self.color = color
    }

    var body: some View {
        Image(systemName: name)
            .font(.system(size: size, weight: weight))
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
    }
}

// MARK: 面板

struct PlayerControlPanel: View {
    let model: CuvenPlayerViewModel
    let player: AVPlayer?
    let geometry: LightingGeometry
    /// 卡片区在整片控制面里的边距（光铺满整片，卡片排在里面）
    var content = EdgeInsets()
    /// 折痕在面板的哪一边（桌面：上边；书本：旁边）——格子跟着转
    var foldEdge: PanelFoldEdge = .top
    var options = PlayerLightingOptions()
    var onDiagnostics: ((LightingDiagnostics) -> Void)?
    var onPalette: ((SampledPalette) -> Void)?
    @State private var host = LightingHost()
    @State private var settings = CinematicLightingSettings.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let inner = CGSize(width: max(0, geo.size.width - content.leading - content.trailing),
                               height: max(0, geo.size.height - content.top - content.bottom))
            let grid = PlayerPanelGrid(size: inner, foldEdge: foldEdge, tools: PlayerToolTile.tools(for: model))
            let columns = grid.isColumns
            let shown = model.controlsVisible
            ZStack(alignment: .topLeading) {
                if host.isAvailable {
                    LightingSurface(host: host)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                } else {
                    Color.black
                }
                ZStack(alignment: .topLeading) {
                    place(grid, .close) { PlayerCloseTile(model: model) }
                    place(grid, .title) { PlayerTitleCard(model: model, vertical: columns) }
                    place(grid, .pip) { PlayerPiPTile(model: model) }
                    place(grid, .lock) { PlayerLockTile(model: model) }
                    place(grid, .back) { PlayerTransportTile(model: model, kind: .back) }
                    place(grid, .play) { PlayerTransportTile(model: model, kind: .play) }
                    place(grid, .forward) { PlayerTransportTile(model: model, kind: .forward) }
                    place(grid, .timeline) {
                        PlaybackTimeline(model: model, vertical: columns)
                            .litCard("timeline", emphasis: 0.25)
                            .playerLockable(model.locked)
                    }
                    // 第四排和亮度 / 音量那一条互相形变：卡片在渲染器里融成一条、再分开，符号淡入淡出
                    if model.tray == nil {
                        ForEach(PlayerToolTile.tools(for: model), id: \.self) { t in
                            // 只淡入淡出：卡面的收拢、融合在渲染器里做（缩放会以整片面板为中心，块会跑偏）
                            place(grid, t) { PlayerToolTile(model: model, tile: t) }
                                .transition(.opacity)
                        }
                    }
                    if let kind = model.tray {
                        place(grid, .tray) {
                            PlayerTray(model: model, kind: kind, vertical: columns)
                                .playerLockable(model.locked)
                        }
                        .id(kind)
                        .transition(.opacity)
                    }
                }
                .frame(width: inner.width, height: inner.height, alignment: .topLeading)
                .animation(.spring(response: 0.42, dampingFraction: 0.88), value: model.tray)
                .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.86), value: grid)
                .padding(content)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                // 符号和文字：淡出时略往下沉，回来时从下面一点淡入、升回原位（卡面由渲染器收拢、淡出）
                .opacity(shown ? 1 : 0)
                .offset(y: shown || reduceMotion ? 0 : 6)
                .allowsHitTesting(shown)
                // 闲置时第一下点按只叫回控制，不触发下面的按钮
                if !shown {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { model.poke() }
                        .accessibilityLabel("显示播放控制")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityIdentifier("player-wake")
                }
            }
            .coordinateSpace(.named(LightingHost.space))
        }
        .environment(\.lightingHost, host)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.42, dampingFraction: 0.9), value: model.controlsVisible)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player-panel")
        .onAppear {
            host.onDiagnostics = onDiagnostics
            host.onPalette = onPalette
        }
        .onChange(of: geometry, initial: true) { _, g in host.update(geometry: g) }
        .onChange(of: settings.mode, initial: true) { _, m in host.update(mode: m) }
        .onChange(of: FoldKey(simulated: options.simulatedFold, hardware: model.hardwareFold), initial: true) { _, k in
            host.setFold(simulated: k.simulated, hardware: k.hardware)
        }
        .onChange(of: model.sourceRange, initial: true) { _, r in host.setSourceRange(r) }
        .onChange(of: player.map(ObjectIdentifier.init), initial: true) { _, _ in host.attach(player: player) }
        .onChange(of: model.controlsVisible, initial: true) { _, visible in host.setIdle(!visible) }
        .task(id: model.artwork) {
            // 剧照小一点就够（光影只取 256 × 144）
            // 剧照的地址可能是 TMDB 的相对路径（「/xxx.jpg」）、完整地址或演示数据的 demo://
            guard let url = TMDBImage.url(model.artwork, "w300") else { host.setStill(nil); return }
            let image = await ImagePipeline.shared.image(url, maxPixel: 480)
            guard !Task.isCancelled else { return }
            host.setStill(image?.cgImage)
        }
    }

    /// 把一块放到格子给它的位置上（格子里没有这一块就不放）
    @ViewBuilder
    private func place<V: View>(_ grid: PlayerPanelGrid, _ tile: PlayerTile, @ViewBuilder _ view: () -> V) -> some View {
        if let r = grid.frame(tile) {
            view()
                .frame(width: r.width, height: r.height)
                .position(x: r.midX, y: r.midY)
        }
    }

    private struct FoldKey: Equatable {
        var simulated: Double?
        var hardware: Double?
    }
}

// MARK: 第二排：后退 10 秒 | 播放 / 暂停 | 前进 10 秒（三块一样大的方块，参照图；中间那块反射最强）

struct PlayerTransportTile: View {
    enum Kind { case back, play, forward }

    let model: CuvenPlayerViewModel
    let kind: Kind

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            Button(action: action) {
                switch kind {
                case .back:
                    PlayerIcon("gobackward.10", size: min(40, (side * 0.32).rounded()), weight: .light)
                case .forward:
                    PlayerIcon("goforward.10", size: min(40, (side * 0.32).rounded()), weight: .light)
                case .play:
                    PlayerIcon(model.playing ? "pause.fill" : "play.fill", size: min(46, (side * 0.36).rounded()), weight: .bold)
                        .contentTransition(.symbolEffect(.replace.magic(fallback: .replace)))
                        .animation(.spring(response: 0.36, dampingFraction: 0.86), value: model.playing)
                }
            }
            .buttonStyle(LitTileStyle(id: id))
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .litCard(id, emphasis: kind == .play ? 1 : 0.6)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
        .playerLockable(model.locked)
    }

    private var id: String {
        switch kind {
        case .back: "back"
        case .play: "play"
        case .forward: "forward"
        }
    }

    private var identifier: String { "player-\(id)" }

    private var label: String {
        switch kind {
        case .back: "后退 10 秒"
        case .play: model.playing ? "暂停" : "播放"
        case .forward: "前进 10 秒"
        }
    }

    private func action() {
        switch kind {
        case .back: model.skip(-10)
        case .play: model.togglePlay()
        case .forward: model.skip(10)
        }
    }
}
