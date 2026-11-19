import AVFoundation
import CuvenLighting
import SwiftUI
import UIKit

// MARK: - 控制面板：四行卡片 + 底下那一层 Metal 光影
//
// 卡片的「面」由 CuvenLighting 的 MetalRenderer 画（深色半透明材质、画面投来的光、镜面反射、高光、边缘光），
// SwiftUI 只画上面的 SF Symbols、文字和点按区。每块卡片用 .litCard(...) 把自己在面板里的位置报给渲染器
// （只在排版变了时报，不是每帧）；按下 / 松开由 LitTileStyle 报给渲染器，卡面和符号一起缩到 0.97。
// 没有 Metal（或着色器没编过）时退回 SwiftUI 画的深灰圆角块，样子和交互都一样。
// 闲置 5 秒：符号淡出，卡面只暗一点——画面映在卡上的光一直在（「持续的环境反射」）；碰一下面板就回来。

/// 面板里的尺寸
enum PlayerPanelStyle {
    /// 块与块之间（参照图量的约 8.6 点）
    static let gap: CGFloat = 8
    static let radius: CGFloat = 19
    static let fallbackTile = Color(white: 0.13)
    static let fallbackPressed = Color(white: 0.2)
    static let fallbackEdge = Color.white.opacity(0.07)
}

/// 实验室里能调的、正式播放时用默认值的那几样
struct PlayerLightingOptions: Equatable {
    var spatialResponse = true
    /// nil：用铰链读数或版面默认的角度；有值：模拟的折叠角度（度）
    var simulatedFold: Double?
    var reflectivity: Float = 0.6
}

// MARK: 和渲染器之间

/// SwiftUI 这边握着的渲染器把手：卡片、设置、几何、播放器先记在这里，渲染器（重新）建起来时一次交过去
@MainActor
final class LightingHost {
    nonisolated static let space = "cuven-lighting-surface"

    /// 这台设备能用 Metal 光影（着色器都编好了）
    let isAvailable: Bool = MetalRenderer.shaderFailures.isEmpty
    private(set) var renderer: MetalRenderer?
    private var cards: [String: LightingCard] = [:]
    private var pressed: Set<String> = []
    private var settings = LightingSettings()
    private var geometry: LightingGeometry?
    private weak var player: AVPlayer?
    private var opacity: Float = 1
    private var simulatedFold: Double?
    private var hardwareFold: Double?
    var onDiagnostics: ((LightingDiagnostics) -> Void)? {
        didSet { renderer?.onDiagnostics = onDiagnostics }
    }
    var onPalette: ((SampledPalette) -> Void)? {
        didSet { renderer?.onPalette = onPalette }
    }

    func makeView() -> UIView {
        if renderer == nil, let r = MetalRenderer.make() {
            renderer = r
            r.settings = settings
            if let geometry { r.geometry = geometry }
            r.player = player
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

    func update(settings: LightingSettings) {
        self.settings = settings
        renderer?.settings = settings
    }

    func update(geometry: LightingGeometry) {
        self.geometry = geometry
        renderer?.geometry = geometry
    }

    func attach(player: AVPlayer?) {
        self.player = player
        renderer?.player = player
    }

    func setOpacity(_ value: Float) {
        opacity = value
        renderer?.setSurfaceOpacity(value)
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
    @Environment(\.lightingHost) private var host
    @State private var frame: CGRect = .zero

    func body(content: Content) -> some View {
        content
            .background {
                if host?.isAvailable != true {
                    PlayerFallbackTile(pressed: false, lit: lit)
                }
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(LightingHost.space)) } action: { frame = $0 }
            .onChange(of: LightingCard(id: id, frame: frame, cornerRadius: PlayerPanelStyle.radius, emphasis: emphasis, isLit: lit),
                      initial: true) { _, card in
                host?.setCard(card)
            }
            .onDisappear { host?.removeCard(id: id) }
    }
}

extension View {
    func litCard(_ id: String, emphasis: Float = 0.5, lit: Bool = false) -> some View {
        modifier(LitCardModifier(id: id, emphasis: emphasis, lit: lit))
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

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PlayerPanelStyle.radius, style: .continuous)
        shape
            .fill(lit ? Color.white : (pressed ? PlayerPanelStyle.fallbackPressed : PlayerPanelStyle.fallbackTile))
            .overlay(shape.strokeBorder(PlayerPanelStyle.fallbackEdge, lineWidth: 1))
    }
}

/// 整块都是按钮（点得到的范围就是那一块：I4）；按下去符号和卡面一起缩到 0.97（「减弱动态效果」时不缩：I9）
struct LitTileStyle: ButtonStyle {
    let id: String
    var lit = false
    @Environment(\.lightingHost) private var host
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                if host?.isAvailable != true {
                    PlayerFallbackTile(pressed: configuration.isPressed, lit: lit)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: PlayerPanelStyle.radius, style: .continuous))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.72), value: configuration.isPressed)
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
    var options = PlayerLightingOptions()
    var onDiagnostics: ((LightingDiagnostics) -> Void)?
    var onPalette: ((SampledPalette) -> Void)?
    @State private var host = LightingHost()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let g = PlayerPanelStyle.gap
            let avail = max(0, geo.size.height - g * 3)
            // 参照图四行的比例 77 : 142 : 51 : 51；面板很高（iPad）时多出来的都给中间那行大块
            let top = min(92, max(52, avail * 0.24))
            let bar = min(60, max(44, avail * 0.16))
            let mid = max(56, avail - top - bar * 2)
            ZStack(alignment: .top) {
                if host.isAvailable {
                    LightingSurface(host: host)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                } else {
                    Color.black
                }
                VStack(spacing: g) {
                    PlayerTopBar(model: model, height: top)
                        .frame(height: top)
                    PlayerTransport(model: model, height: mid)
                        .frame(height: mid)
                    PlaybackTimeline(model: model)
                        .litCard("timeline", emphasis: 0.3)
                        .frame(height: bar)
                        .playerLockable(model.locked)
                    Group {
                        switch model.tray {
                        case .brightness: PlayerTray(model: model, kind: .brightness)
                        case .volume: PlayerTray(model: model, kind: .volume)
                        case nil: PlayerBottomBar(model: model)
                        }
                    }
                    .frame(height: bar)
                    .playerLockable(model.locked)
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                .opacity(model.controlsVisible ? 1 : 0)
                // 闲置时符号淡出：第一下点按只叫回符号，不触发下面的按钮
                if !model.controlsVisible {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { model.poke() }
                        .accessibilityLabel("显示播放控制")
                        .accessibilityAddTraits(.isButton)
                }
            }
            .coordinateSpace(.named(LightingHost.space))
        }
        .environment(\.lightingHost, host)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: model.controlsVisible)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player-panel")
        .onAppear {
            host.onDiagnostics = onDiagnostics
            host.onPalette = onPalette
        }
        .onChange(of: geometry, initial: true) { _, g in host.update(geometry: g) }
        .onChange(of: settingsKey, initial: true) { _, _ in host.update(settings: settings) }
        .onChange(of: FoldKey(simulated: options.simulatedFold, hardware: model.hardwareFold), initial: true) { _, k in
            host.setFold(simulated: k.simulated, hardware: k.hardware)
        }
        .onChange(of: player.map(ObjectIdentifier.init), initial: true) { _, _ in host.attach(player: player) }
        .onChange(of: model.controlsVisible) { _, visible in host.setOpacity(visible ? 1 : 0.72) }
    }

    private struct FoldKey: Equatable {
        var simulated: Double?
        var hardware: Double?
    }

    private struct SettingsKey: Equatable {
        var enabled: Bool
        var intensity: Double
        var options: PlayerLightingOptions
    }

    private var settingsKey: SettingsKey {
        SettingsKey(enabled: model.lightingEnabled, intensity: model.lightingIntensity, options: options)
    }

    private var settings: LightingSettings {
        var s = LightingSettings()
        s.isEnabled = model.lightingEnabled
        s.intensity = Float(model.lightingIntensity)
        s.reflectivity = options.reflectivity
        s.spatialResponse = options.spatialResponse
        return s
    }
}

// MARK: 第二行：后退 10 秒 | 播放 / 暂停 | 前进 10 秒

struct PlayerTransport: View {
    let model: CuvenPlayerViewModel
    let height: CGFloat

    var body: some View {
        let skip = min(46, max(28, height * 0.3))
        HStack(spacing: PlayerPanelStyle.gap) {
            Button(action: { model.skip(-10) }) {
                PlayerIcon("gobackward.10", size: skip, weight: .light)
            }
            .buttonStyle(LitTileStyle(id: "back"))
            .litCard("back", emphasis: 0.55)
            .accessibilityLabel("后退 10 秒")
            .accessibilityIdentifier("player-back")

            Button(action: { model.togglePlay() }) {
                PlayerIcon(model.playing ? "pause.fill" : "play.fill", size: skip * 1.15, weight: .bold)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(LitTileStyle(id: "play"))
            .litCard("play", emphasis: 1)
            .accessibilityLabel(model.playing ? "暂停" : "播放")
            .accessibilityIdentifier("player-play")

            Button(action: { model.skip(10) }) {
                PlayerIcon("goforward.10", size: skip, weight: .light)
            }
            .buttonStyle(LitTileStyle(id: "forward"))
            .litCard("forward", emphasis: 0.55)
            .accessibilityLabel("前进 10 秒")
            .accessibilityIdentifier("player-forward")
        }
        .playerLockable(model.locked)
    }
}
