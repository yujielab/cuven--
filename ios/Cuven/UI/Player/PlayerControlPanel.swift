import AVFoundation
import CuvenLighting
import SwiftUI
import UIKit

// MARK: - 控制面板：最上面一条液态玻璃的 Touch Bar + 最底下的卡片区，底下一层 Metal 光影
//
// 照用户的设计图：Touch Bar（PlayerToolbar.swift）是一排液态玻璃胶囊，左右滑，长按 → 形变 → 滑动选择或调整 → 松开 → 还原；
// 卡片区（PlayerInfoDeck.swift：InSight / 继续观看 / 推荐，只左右滑）贴在面板最底下，最高 200 点。桌面、书本两种姿态同一个排法。
//
// 底下那层由 CuvenLighting 的 MetalRenderer 画：画面里的光按位置和颜色投到面板上，隔着折痕映过来的画面，四边羽化；
// 液态玻璃把这层光透出来。下面的 LightingHost / LitCardModifier / LitTileStyle 是给 Metal 画的卡面用的（实验室、以后的样式），
// 现在的面板不报卡片。
//
// 闲置（放着、5 秒没碰）：Touch Bar 和卡片区一起淡出，面板上画面的光一直在、更新慢一些（省电）；碰一下就回来。

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
            // Touch Bar：胶囊高 = 面板高的 13%（46…56 点），整条铺满面板的宽（两头的胶囊伸出屏外，左右滑）；
            // 下面那块贴在最底下，最高 PlayerDeckLayout.maxHeight，太矮就不放
            let pill = min(56, max(46, (inner.height * 0.13).rounded()))
            let barHeight = PlayerTouchBar.height(pill: pill)
            let deckHeight = min(PlayerDeckLayout.maxHeight, inner.height - barHeight - 20)
            let shown = model.controlsVisible
            ZStack(alignment: .topLeading) {
                if host.isAvailable {
                    LightingSurface(host: host)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                } else {
                    Color.black
                }
                // 系统音量要经过一个 MPVolumeView 设（声音那颗的滑杆）；它在屏上时系统的音量提示也不弹
                HiddenVolumeView()
                    .frame(width: 2, height: 2)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                VStack(spacing: 0) {
                    PlayerTouchBar(model: model, pillHeight: pill,
                                   insets: EdgeInsets(top: 0, leading: content.leading, bottom: 0, trailing: content.trailing))
                        .padding(.top, content.top)
                    Spacer(minLength: 20)
                    if deckHeight >= PlayerDeckLayout.tabHeight {
                        PlayerInfoDeck(model: model, height: deckHeight)
                            .frame(height: deckHeight, alignment: .bottom)
                            .padding(.leading, content.leading)
                            .padding(.trailing, content.trailing)
                    }
                }
                .padding(.bottom, content.bottom)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                // 符号、文字、玻璃：淡出时略往下沉，回来时从下面一点淡入、升回原位（键面由渲染器收拢、淡出）
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
            // 剧照的地址可能是 TMDB 的相对路径（「/xxx.jpg」）、完整地址或演示数据的 demo://；小一点就够（光影只取 256 × 144）
            guard let url = TMDBImage.url(model.artwork, "w300") else { host.setStill(nil); return }
            let image = await ImagePipeline.shared.image(url, maxPixel: 480)
            guard !Task.isCancelled else { return }
            host.setStill(image?.cgImage)
        }
    }

    private struct FoldKey: Equatable {
        var simulated: Double?
        var hardware: Double?
    }
}
