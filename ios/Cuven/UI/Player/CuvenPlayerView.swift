import AVFoundation
import AVKit
import CuvenLighting
import SwiftUI
import UIKit

// MARK: - Cuven 播放器：画面 + 控制面板（面板的卡片由画面打光）
//
// 三种摆法，同一套面板：
//   · folded(折痕)：iPhone Duo 半折立在桌上——折痕上面是画面，下面是面板（参照 Netflix 在半折时的样子）；
//     光影按半折的几何算：画面立在面板后面，默认 105°，系统报了铰链角度就用真的；
//   · stacked：竖着的普通屏（实验室）——画面在上、面板在下，中间留一道「虚拟折痕」，默认摊平 180°；
//   · sideBySide：横着的屏（实验室）——画面在左、面板在右，折痕竖着。
// 画面由 AVPlayerLayer 画（硬件解码、HDR、画中画都是系统的）；同一个 AVPlayer 另由光影引擎取小帧分析，
// 两者互不影响。面板换摆法、转屏时用弹簧过渡。

enum CuvenPlayerLayout: Equatable {
    case folded(CGRect)
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
                    PlayerControlPanel(model: model, player: player, geometry: parts.lighting, options: options,
                                       onDiagnostics: onDiagnostics, onPalette: onPalette)
                        .frame(width: parts.panel.width, height: parts.panel.height)
                        .offset(x: parts.panel.minX, y: parts.panel.minY)
                }
                .frame(width: full.size.width, height: full.size.height, alignment: .topLeading)
                .animation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.86), value: parts)
            }
            .ignoresSafeArea()
        }
        .modifier(HingeAngleReader { model.hardwareFold = $0 })
    }
}

/// 画面、面板各在哪，光影的几何（全部是这一层里的点）
struct PlayerLayoutParts: Equatable {
    var video: CGRect
    var panel: CGRect
    var lighting: LightingGeometry

    init(layout: CuvenPlayerLayout, size: CGSize, insets: EdgeInsets) {
        let g = PlayerPanelStyle.gap
        let w = size.width, h = size.height
        var hinge: CGPoint
        var away = CGVector(dx: 0, dy: 1)
        var fold: Double
        switch layout {
        case .folded(let f):
            video = CGRect(x: 0, y: 0, width: w, height: max(0, f.minY))
            let top = f.maxY + g
            let bottom = h - max(insets.bottom, g) - g
            panel = CGRect(x: insets.leading + g, y: top, width: w - insets.leading - insets.trailing - g * 2,
                           height: max(0, bottom - top))
            hinge = CGPoint(x: w / 2, y: f.midY)
            fold = 105
        case .stacked:
            let usable = h - insets.top - insets.bottom
            let vh = min(w * 9 / 16, usable * 0.42).rounded()
            video = CGRect(x: 0, y: insets.top, width: w, height: vh)
            let gap: CGFloat = 20
            let top = insets.top + vh + gap
            let bottom = h - max(insets.bottom, g) - g
            panel = CGRect(x: insets.leading + g, y: top, width: w - insets.leading - insets.trailing - g * 2,
                           height: max(0, bottom - top))
            hinge = CGPoint(x: w / 2, y: insets.top + vh + gap / 2)
            fold = 180
        case .sideBySide:
            let usable = w - insets.leading - insets.trailing
            let vw = (usable * 0.58).rounded()
            video = CGRect(x: insets.leading, y: insets.top, width: vw, height: h - insets.top - insets.bottom)
            let gap: CGFloat = 20
            let left = insets.leading + vw + gap
            panel = CGRect(x: left, y: insets.top + g, width: max(0, w - insets.trailing - g - left),
                           height: max(0, h - insets.top - max(insets.bottom, g) - g * 2))
            hinge = CGPoint(x: insets.leading + vw + gap / 2, y: h / 2)
            away = CGVector(dx: 1, dy: 0)
            fold = 180
        }
        // 很宽的屏上面板不超过 720 点，居中
        if panel.width > 720 {
            panel.origin.x += (panel.width - 720) / 2
            panel.size.width = 720
        }
        // 光影引擎在面板自己的坐标里算：画面和折痕换算到面板的原点
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
        return v
    }

    func updateUIView(_ v: PlayerLayerUIView, context: Context) {
        if v.playerLayer.player !== player { v.playerLayer.player = player }
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
        c.canStartPictureInPictureAutomaticallyFromInline = false
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
