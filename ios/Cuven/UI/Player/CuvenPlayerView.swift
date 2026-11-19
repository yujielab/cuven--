import AVFoundation
import AVKit
import CuvenLighting
import SwiftUI
import UIKit

// MARK: - Cuven 播放器：画面 + 控制面板（面板的卡片由画面打光）
//
// 跟着设备的姿态走（参照 Netflix 在 iPhone Duo 上的播放器：全屏、书本、桌面几种摆法，控制始终够得着），同一套面板：
//   · tabletop(折痕)：半折立在桌上（横着的折痕）——折痕上面是画面，下面是控制面；
//   · book(折痕)：横拿半折像一本书（竖着的折痕）——左页是画面，右页是控制面；
//     这两种按半折的几何算光：画面立在面板旁边，默认 105°，系统报了铰链角度就用真的（光的方向跟着铰链角度变）；
//   · stacked / sideBySide：实验室、设置页预览里竖着 / 横着的普通屏，按半折立着的 115° 模拟。
// 控制面那一块是整片的（满宽、从折痕一直到屏幕底），光铺在整片上、四边都羽化，不会有硬边界；
// 卡片排在里面，留出安全区和 8 点边距。换姿态、转屏时卡片在渲染器里用弹簧从旧位置形变到新位置。
// 画面由 AVPlayerLayer 画（硬件解码、HDR、画中画都是系统的）；同一个 AVPlayer 另由光影引擎取小帧分析。

enum CuvenPlayerLayout: Equatable {
    case tabletop(CGRect)
    case book(CGRect)
    case stacked
    case sideBySide
}

struct CuvenPlayerView: View {
    let model: CuvenPlayerViewModel
    let player: AVPlayer?
    let layout: CuvenPlayerLayout
    var options = PlayerLightingOptions()
    var onDiagnostics: ((LightingDiagnostics) -> Void)?
    var onPalette: ((SampledPalette) -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // 外面一层守着安全区、里面一层铺满：两层的框一比就是四边的安全区（和 DuoNavLayer 同一个量法）
        GeometryReader { safe in
            let sf = safe.frame(in: .global)
            GeometryReader { full in
                let ff = full.frame(in: .global)
                let insets = EdgeInsets(top: max(0, sf.minY - ff.minY), leading: max(0, sf.minX - ff.minX),
                                        bottom: max(0, ff.maxY - sf.maxY), trailing: max(0, ff.maxX - sf.maxX))
                let parts = PlayerLayoutParts(layout: layout, size: full.size, insets: insets)
                ZStack(alignment: .topLeading) {
                    Color.black
                    PlayerVideoSurface(model: model, player: model.visible || model.pipActive ? player : nil)
                        .frame(width: parts.video.width, height: parts.video.height)
                        .offset(x: parts.video.minX, y: parts.video.minY)
                        .accessibilityHidden(true)
                    PlayerControlPanel(model: model, player: player, geometry: parts.lighting, content: parts.content,
                                       options: options, onDiagnostics: onDiagnostics, onPalette: onPalette)
                        .frame(width: parts.panel.width, height: parts.panel.height)
                        .offset(x: parts.panel.minX, y: parts.panel.minY)
                }
                .frame(width: full.size.width, height: full.size.height, alignment: .topLeading)
                .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.88), value: parts)
            }
            .ignoresSafeArea()
        }
        .modifier(HingeAngleReader { model.hardwareFold = $0 })
    }
}

/// 画面、控制面（整片）、卡片区在控制面里的边距、光影的几何（全部是这一层里的点）
struct PlayerLayoutParts: Equatable {
    var video: CGRect
    /// 控制面：整片（光铺满它，四边羽化）
    var panel: CGRect
    /// 卡片区在控制面里的边距（安全区 + 8 点，太宽时两边再收，卡片区最宽 720）
    var content: EdgeInsets
    var lighting: LightingGeometry

    init(layout: CuvenPlayerLayout, size: CGSize, insets: EdgeInsets) {
        let g = PlayerPanelStyle.gap
        let w = size.width, h = size.height
        let hinge: CGPoint
        var away = CGVector(dx: 0, dy: 1)
        let fold: Double
        switch layout {
        case .tabletop(let f):
            video = CGRect(x: 0, y: 0, width: w, height: max(0, f.minY))
            panel = CGRect(x: 0, y: f.maxY, width: w, height: max(0, h - f.maxY))
            content = EdgeInsets(top: g, leading: insets.leading + g, bottom: max(insets.bottom, g) + g, trailing: insets.trailing + g)
            hinge = CGPoint(x: w / 2, y: f.midY)
            fold = 105
        case .book(let f):
            video = CGRect(x: 0, y: 0, width: max(0, f.minX), height: h)
            panel = CGRect(x: f.maxX, y: 0, width: max(0, w - f.maxX), height: h)
            content = EdgeInsets(top: max(insets.top, g) + g, leading: g, bottom: max(insets.bottom, g) + g, trailing: insets.trailing + g)
            hinge = CGPoint(x: f.midX, y: h / 2)
            away = CGVector(dx: 1, dy: 0)
            fold = 105
        case .stacked:
            let usable = h - insets.top - insets.bottom
            let vh = min(w * 9 / 16, usable * 0.42).rounded()
            video = CGRect(x: 0, y: insets.top, width: w, height: vh)
            let gap: CGFloat = 20
            panel = CGRect(x: 0, y: insets.top + vh + gap, width: w, height: max(0, h - insets.top - vh - gap))
            content = EdgeInsets(top: g, leading: insets.leading + g, bottom: max(insets.bottom, g) + g, trailing: insets.trailing + g)
            hinge = CGPoint(x: w / 2, y: insets.top + vh + gap / 2)
            // 实验室 / 设置页预览：模拟半折立着的几何，效果和半折时一致
            fold = 115
        case .sideBySide:
            let usable = w - insets.leading - insets.trailing
            let vw = (usable * 0.58).rounded()
            video = CGRect(x: insets.leading, y: insets.top, width: vw, height: h - insets.top - insets.bottom)
            let gap: CGFloat = 20
            let left = insets.leading + vw + gap
            panel = CGRect(x: left, y: 0, width: max(0, w - left), height: h)
            content = EdgeInsets(top: insets.top + g, leading: g, bottom: max(insets.bottom, g) + g, trailing: insets.trailing + g)
            hinge = CGPoint(x: insets.leading + vw + gap / 2, y: h / 2)
            away = CGVector(dx: 1, dy: 0)
            fold = 115
        }
        // 很宽的控制面上卡片区不超过 720 点，居中
        let contentWidth = panel.width - content.leading - content.trailing
        if contentWidth > 720 {
            let extra = (contentWidth - 720) / 2
            content.leading += extra
            content.trailing += extra
        }
        // 光影引擎在控制面自己的坐标里算：画面和折痕换算到控制面的原点
        lighting = LightingGeometry(videoContainer: video.offsetBy(dx: -panel.minX, dy: -panel.minY),
                                    hingePoint: CGPoint(x: hinge.x - panel.minX, y: hinge.y - panel.minY),
                                    awayFromHinge: away, layoutFoldDegrees: fold)
    }
}

// MARK: 画面（AVPlayerLayer + 画中画）

struct PlayerVideoSurface: UIViewRepresentable {
    let model: CuvenPlayerViewModel
    let player: AVPlayer?

    func makeCoordinator() -> PictureInPictureBridge { PictureInPictureBridge(model: model) }

    func makeUIView(context: Context) -> PlayerLayerUIView {
        let v = PlayerLayerUIView()
        v.playerLayer.player = player
        context.coordinator.attach(to: v.playerLayer)
        if let player { Self.resync(player) }
        return v
    }

    func updateUIView(_ v: PlayerLayerUIView, context: Context) {
        if v.playerLayer.player !== player {
            v.playerLayer.player = player
            if let player { Self.resync(player) }
        }
    }

    /// 这一层画面在播放中途接上（半折、从后台回来）：原地精确跳一下，让解码和显示从关键帧重新走一遍。
    /// HDR / 杜比视界的片子中途换到一个新的画面层上，不重走一遍可能显示得发白、过曝（用户真机反馈：
    /// 重新播放就正常，退到后台再回来又过曝）。刚开始放（2 秒以内）的不跳
    static func resync(_ player: AVPlayer) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard let item = player.currentItem, item.status == .readyToPlay else { return }
            let t = player.currentTime()
            guard t.isValid, t.seconds.isFinite, t.seconds > 2 else { return }
            _ = await player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    static func dismantleUIView(_ v: PlayerLayerUIView, coordinator: PictureInPictureBridge) {
        coordinator.detach()
        v.playerLayer.player = nil
    }
}

final class PlayerLayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isUserInteractionEnabled = false
        playerLayer.videoGravity = .resizeAspect
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// 面板第一行的画中画：用的是面板自己这一层画面。开始 / 结束 / 回到播放器交给 ViewModel（半折时再交给 PlayerCoordinator）
@MainActor
final class PictureInPictureBridge: NSObject, AVPictureInPictureControllerDelegate {
    private weak var model: CuvenPlayerViewModel?
    private var controller: AVPictureInPictureController?
    private var possibleObservation: NSKeyValueObservation?

    init(model: CuvenPlayerViewModel) {
        self.model = model
    }

    func attach(to layer: AVPlayerLayer) {
        guard AVPictureInPictureController.isPictureInPictureSupported(),
              let c = AVPictureInPictureController(playerLayer: layer) else { return }
        c.delegate = self
        // 半折播放：系统播放器那一层这时不接画面，退到后台由这一层自动进画中画
        c.canStartPictureInPictureAutomaticallyFromInline = model?.automaticPictureInPicture ?? false
        controller = c
        model?.pipController = c
        possibleObservation = c.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] c, _ in
            let possible = c.isPictureInPicturePossible
            Task { @MainActor [weak self] in self?.model?.setPiPPossible(possible) }
        }
    }

    func detach() {
        possibleObservation?.invalidate()
        possibleObservation = nil
        model?.setPiPPossible(false)
    }

    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ c: AVPictureInPictureController) {
        Task { @MainActor in self.model?.pipWillStart() }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) {
        Task { @MainActor in self.model?.pipDidStop() }
    }

    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController,
                                                restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        Task { @MainActor in
            if let model = self.model { model.pipRestore(completionHandler) } else { completionHandler(true) }
        }
    }
}

// MARK: 铰链角度

/// iOS 27.1 起系统在有铰链的设备上报铰链角度（SwiftUI onHingeChange）：喂给光影引擎当折叠角度。
/// 别的设备、更早的系统：什么都不做，引擎用版面默认的角度（或实验室里模拟的）
struct HingeAngleReader: ViewModifier {
    let onAngle: (Double?) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            content.onHingeChange { _, context in
                onAngle(context.hinge.map { $0.angle.degrees })
            }
        } else {
            content
        }
    }
}
