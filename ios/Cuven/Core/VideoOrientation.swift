import SwiftUI
import UIKit

// MARK: - 全屏视频的方向（用户要求）
//
// 用户截图：折起的 iPhone Duo 竖着拿，正片竖着放，画面上下各空着一大片黑边。
// 用户：「除了 iPhone 展开状态下，其他情况或设备上视频锁定横屏显示，只有上下两个方向」——
//   · iPhone 展开（Duo 的内屏；半折时用的也是内屏）：不锁，跟着设备转，竖着拿也能看；
//   · 其他情况（普通 iPhone、Duo 折起的外屏、iPad）：只横着放，左右两个横向都行
//     （手机掉个头，画面跟着翻过来），不竖着放、不倒过来。
// 管两处全屏视频：正片播放器（CuvenPlayerViewController）和全屏预告片（TrailerPlayerView.present）；
// 播放加载画面那一层窗口也照这条报方向，免得它和底下的播放器说的不一样。
// 「展开」只看屏幕：iPhone 上短边不少于 600 点的屏只有 Duo 的内屏（和 DuoLayout 同一个口径，不认型号）；
// 看屏不看窗口：半折时窗口被压矮，屏还是内屏。
// iPad：App 支持分屏和窗口，系统不让这样的 App 锁方向——这里照样报横向，系统认就横着放，不认就照常跟着设备转。

@MainActor
enum VideoOrientation {
    /// 现在是不是 iPhone 展开（用着 Duo 的内屏）
    static func isUnfoldedPhone(_ window: UIWindow?) -> Bool {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return false }
        let scene = window?.windowScene ?? activeScene
        let size = scene?.screen.bounds.size ?? window?.bounds.size ?? .zero
        return min(size.width, size.height) >= 600
    }

    static var activeScene: UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }

    static func mask(unfolded: Bool) -> UIInterfaceOrientationMask {
        unfolded ? .allButUpsideDown : .landscape
    }

    /// 弹出来时先摆成哪个方向（一定在 mask 里，不然 UIKit 直接报错退出）：
    /// 展开时照现在的方向不动；要横屏时，本来就横着就不动（不翻 180°），设备横着拿就跟设备，
    /// 竖着拿或平放先摆成 Home 指示条在右边的那一向（横屏视频的惯例），转过手机来再跟着转到另一向
    static func preferred(unfolded: Bool) -> UIInterfaceOrientation {
        let current = activeScene?.effectiveGeometry.interfaceOrientation ?? .unknown
        if unfolded {
            return current == .unknown || current == .portraitUpsideDown ? .portrait : current
        }
        if current.isLandscape { return current }
        switch UIDevice.current.orientation {
        case .landscapeLeft: return .landscapeRight     // 设备的「左横」是界面的「右横」（两套枚举左右是反的）
        case .landscapeRight: return .landscapeLeft
        default: return .landscapeRight
        }
    }
}

/// 一个全屏视频页自己的方向状态。「展开没有」判断一次记下来，两个方向回调都读它
/// （两头说的不一致，比如弹出时报竖屏、支持的却只有横屏，UIKit 会直接报错退出）；
/// 尺寸一变（转屏、Duo 折起 / 展开）再判断一次，变了就让系统按新的规则重新摆
@MainActor
final class VideoOrientationLock {
    private(set) var unfolded: Bool

    init() { unfolded = VideoOrientation.isUnfoldedPhone(nil) }

    var mask: UIInterfaceOrientationMask { VideoOrientation.mask(unfolded: unfolded) }
    var preferred: UIInterfaceOrientation { VideoOrientation.preferred(unfolded: unfolded) }

    func refresh(_ vc: UIViewController) {
        let now = VideoOrientation.isUnfoldedPhone(vc.view.window)
        guard now != unfolded else { return }
        unfolded = now
        vc.setNeedsUpdateOfSupportedInterfaceOrientations()
    }

    /// 尺寸变化做完以后再判断（这时屏和窗口都是新的了）
    func refresh(_ vc: UIViewController, after coordinator: any UIViewControllerTransitionCoordinator) {
        coordinator.animate(alongsideTransition: nil) { [weak self, weak vc] _ in
            Task { @MainActor [weak self, weak vc] in
                guard let self, let vc else { return }
                self.refresh(vc)
            }
        }
    }
}

/// 全屏视频那一层用的 UIHostingController（全屏预告片、播放加载画面的窗口）：方向和正片播放器一样
final class VideoHostingController<Content: View>: UIHostingController<Content> {
    private lazy var orientation = VideoOrientationLock()

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { orientation.mask }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { orientation.preferred }

    override func viewWillTransition(to size: CGSize, with coordinator: any UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        orientation.refresh(self, after: coordinator)
    }
}
