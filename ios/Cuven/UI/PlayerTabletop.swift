import SwiftUI
import UIKit
import AVKit
import AVFoundation

// MARK: - 半折（桌面形态）的播放器：上面画面、下面控制面板
//
// 用户要求：「添加类似 Netflix 在 iPhone Duo 半折的上视频下控制面板的设计」（附截图：内屏竖拿、半折立在桌上），
// 之后又要求按参照图做一个原生的、卡片被画面打光的播放器（Cuven Native Dynamic Reflective Player）。
// iPhone Duo 展开竖拿再半折，像一台小笔记本立在桌上，内屏被横着的折痕分成上下两块：
//   · 上面那块放画面（按比例放进去，不裁不拉），远一点也看得清；
//   · 下面那块是控制面板（UI/Player/：CuvenPlayerView、PlayerControlPanel、PlayerToolbar、PlaybackTimeline），
//     卡片的面由 CuvenLighting 框架用 Metal 画，画面里的光实时映在卡片上（docs/ios-lighting.md）。
//
// 折痕在哪：iOS 27.1 的 GeometryProxy.reservedRegions(kind: .division)——只有半折时才有「生效」的那一块，frame 已经含着
// 系统要求留出的边距（D10、D11）。横着的（宽 > 高）是桌面形态：上画面、下控制；竖着的（横拿半折，像一本书）是书本形态：
// 右页画面、左页控制，同一套卡片转成一列一列的（参照 Netflix：控制跟着姿态动，始终够得着）。平着展开、折起、
// 别的 iPhone / iPad 一律照旧用系统播放器。版面跟着折痕排、不看铰链角度（D12）；铰链角度用来算画面映在面板上的样子。
// 合上或摊平时折痕不再生效，面板淡出、系统播放器的控件回来（D3：两种版面同一个播放状态）。
//
// 画面：系统播放器自己的画面铺满整屏、会横跨折痕，所以半折时这里另挂一层 AVPlayerLayer 接这个 AVPlayer，
// 同时系统播放器那一层放开播放器（vc.player = nil）——同一时间只有一层画面在显示，HDR / 杜比视界的显示不会乱
// （用户真机反馈过曝）；画面层中途接上时原地精确跳一下重新接上。收起时把播放器还给系统播放器。
// 退到后台时面板这一层自动进画中画。
//
// 「全屏」：这一次半折里回到系统播放器（画面铺满、系统控件）；合上 / 摊平以后再半折，又是上下两块。
// 「锁定」：除了这颗锁，面板上的按钮都变暗、点不动（放在桌上看的时候不会碰到）；再点锁解开。
// 「画中画」：面板这一层画面进画中画，播放器收起回到 App；点画中画里的「还原」再弹回来（PlayerCoordinator）。

/// 折痕：横着的（桌面）或竖着的（书本）
enum TabletopFold {
    /// 半折时折痕在屏里的位置（含系统要求留的边距）；没有：nil。横着的 → 桌面，竖着的 → 书本
    static func detect(in proxy: GeometryProxy) -> CGRect? {
        if #available(iOS 27.1, *) {
            // 只取生效的（半折时才有）：平着展开时那一块还在，但不生效、宽或高是 0
            guard let f = proxy.reservedRegions(kind: .division).first?.frame else { return nil }
            let size = proxy.size
            if f.width > f.height, f.minY > 0, f.maxY < size.height { return f }
            if f.height > f.width, f.minX > 0, f.maxX < size.width { return f }
            return nil
        }
        return nil
    }

    /// 截图用（DEBUG 的 -CuvenTabletop）：模拟器折不了，把折痕固定在正中——竖着的屏是横着的折痕（桌面），
    /// 横着的屏是竖着的折痕（书本），两边各留 28 点
    static func preview(_ size: CGSize) -> CGRect? {
        if size.height > size.width {
            return CGRect(x: 0, y: (size.height / 2 - 28).rounded(), width: size.width, height: 56)
        }
        return CGRect(x: (size.width / 2 - 28).rounded(), y: 0, width: 56, height: size.height)
    }
}

// MARK: - 挂进系统播放器

/// CuvenPlayerViewController 里挂的那一层：平时完全透明、不接点按；半折（横着的折痕）时整层变成上下两块，
/// 同时收起系统播放器自己的控件
@MainActor
final class TabletopPlayerHost {
    let model = CuvenPlayerViewModel()
    private var host: UIHostingController<TabletopPlayerLayer>?

    func install(in vc: AVPlayerViewController, onActiveChange: @escaping (Bool) -> Void) {
        let h = UIHostingController(rootView: TabletopPlayerLayer(model: model))
        h.view.backgroundColor = .clear
        h.view.isUserInteractionEnabled = false
        vc.addChild(h)
        h.view.frame = vc.view.bounds
        h.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        vc.view.addSubview(h.view)
        h.didMove(toParent: vc)
        host = h
        model.onClose = { [weak vc] in vc?.dismiss(animated: true) }
        model.automaticPictureInPicture = true
        model.onActiveChange = { [weak vc, weak h, weak model = self.model] on in
            h?.view.isUserInteractionEnabled = on
            vc?.showsPlaybackControls = !on
            // 同一时间只有一层画面接着播放器（用户真机反馈：半折时画面过曝）——半折时交给面板这一层，
            // 系统播放器那一层先放开；收起时还回去，再原地精确跳一下让它重新接上
            if let vc, let p = model?.player {
                vc.player = on ? nil : p
                if !on { PlayerVideoSurface.resync(p) }
            }
            onActiveChange(on)
        }
        // 面板的画中画：开始时收起播放器回到 App，「还原」时弹回来，关掉画中画时收拾干净
        model.onPiPWillStart = { PlayerCoordinator.shared.panelPictureInPictureWillStart() }
        model.onPiPDidStop = { PlayerCoordinator.shared.panelPictureInPictureDidStop() }
        model.onPiPRestore = { completion in PlayerCoordinator.shared.panelPictureInPictureRestore(completion) }
    }

    /// 系统播放器自己也往这一层里加东西：每次排版都把面板放回最上面
    func keepOnTop() {
        guard let v = host?.view, let s = v.superview, s.subviews.last !== v else { return }
        s.bringSubviewToFront(v)
    }

    /// 开始放一集（剧集接下一集也是）：信息卡、「下一集」跟着换
    func show(_ req: PlayRequest) {
        model.title = req.title
        model.subtitle = req.subtitle
        model.artwork = req.artwork
        model.hasNext = !req.queue.isEmpty
    }
}

// MARK: - 版面

/// 盖在系统播放器上的整层：量折痕，半折时换成 CuvenPlayerView（画面在上、面板在下）
struct TabletopPlayerLayer: View {
    let model: CuvenPlayerViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { full in
            let fold = model.preview ? TabletopFold.preview(full.size) : TabletopFold.detect(in: full)
            ZStack {
                if model.active, let f = model.fold {
                    // 横着的折痕：画面在上、控制在下；竖着的：画面在右页、控制在左页（卡片转成一列一列的）。换姿态时卡片形变过去
                    CuvenPlayerView(model: model, player: model.player, layout: f.width > f.height ? .tabletop(f) : .book(f))
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }
            }
            .frame(width: full.size.width, height: full.size.height)
            .onChange(of: fold, initial: true) { _, f in model.setFold(f) }
        }
        .ignoresSafeArea()
        // 半折 / 摊平时整层淡入淡出，带一点弹簧（「减弱动态效果」时直接换：I9）
        .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.88), value: model.active)
    }
}

// MARK: - 截图用（DEBUG）

#if DEBUG
/// UI 测试 / 截图：演示数据加上 -CuvenTabletop YES，启动后弹一个假的播放页，折痕固定在屏正中（模拟器折不了）。
/// 不接播放器（演示数据本来就放不了），画面是黑的；卡片照常由 Metal 画（没有画面的光，只有材质）
@MainActor
enum TabletopPreview {
    static func presentIfRequested() {
        guard DemoData.enabled, UserDefaults.standard.bool(forKey: "CuvenTabletop") else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let m = CuvenPlayerViewModel()
            m.preview = true
            m.title = "灯火人间"
            m.subtitle = "第 2 集 · 别回头"
            m.artwork = "demo://backdrop/41"
            m.hasNext = true
            // 不锁方向（不用 VideoHostingController）：iPad 竖着是桌面（横着的折痕），横过来是书本（竖着的折痕）
            let vc = UIHostingController(rootView: TabletopPlayerLayer(model: m))
            vc.view.backgroundColor = .black
            vc.modalPresentationStyle = .fullScreen
            m.onClose = { [weak vc] in vc?.dismiss(animated: true) }
            UIApplication.topViewController()?.present(vc, animated: true)
        }
    }
}
#endif
