import UIKit

// MARK: - 屏幕圆角（点）：全屏的光贴着屏幕边走时用
//
// 用户反馈（iPhone Duo 折起，build 329）：「正在发往请求中心」那一屏左下角的光被一个和屏幕对不上的圆角裁掉，
// 真屏的圆角里面露出一块暗楔；成功以后边上那圈光的圆角也不贴屏幕的角。原因是 iPhone Duo 不在已知机型表里，
// 按短边 14% 估成了约 62 点，比真屏的圆角大。
// 所以先在运行时问屏幕自己：UIScreen 的「_displayCornerRadius」（没公开的键，用键值编码读；这个 App 是侧载的、不上 App Store）。
// 读不到（键没了、值不对）才退回已知机型表、再退回按短边估。「放大显示」时同样的物理圆角折成的点数变小，两条路都按它折。
@MainActor
enum ScreenCorner {
    /// 整屏那一层的圆角（点）。size：那一层的大小（整屏，点）；bottomInset：底部安全区（只在估的时候用：方屏有 Home 键的是 0）
    static func radius(size: CGSize, bottomInset: CGFloat) -> CGFloat {
        let short = min(size.width, size.height)
        guard short > 0 else { return 0 }
        let screen = currentScreen()
        let r: CGFloat
        if let screen, let raw = systemRadius(screen) {
            r = zoomed(raw, screen)
        } else {
            r = estimate(short: short, bottomInset: bottomInset, screen: screen)
        }
        return min(max(0, r), short / 2)
    }

    /// 前台那个窗口场景的屏幕（没有前台的就拿第一个）
    private static func currentScreen() -> UIScreen? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return (scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first)?.screen
    }

    /// 屏幕自己报的圆角：先看它认不认这个方法（不认还硬用键值编码读会直接抛异常闪退），值要是个说得通的正数
    private static func systemRadius(_ screen: UIScreen) -> CGFloat? {
        let key = "_displayCornerRadius"
        guard screen.responds(to: NSSelectorFromString(key)) else { return nil }
        let value = screen.value(forKey: key)
        let r: CGFloat
        if let n = value as? NSNumber {
            r = CGFloat(n.doubleValue)
        } else if let f = value as? CGFloat {
            r = f
        } else {
            return nil
        }
        // 0 是方屏（有 Home 键的）——这也是真值；负数、NaN、比半个短边还大的不认
        let short = min(screen.bounds.width, screen.bounds.height)
        guard r.isFinite, r >= 0, short <= 0 || r <= short / 2 else { return nil }
        return r
    }

    /// 「放大显示」的折算比例（≤ 1，标准显示是 1）：同一块屏点数变少，同样的物理圆角折成的点数按比例变小。
    /// 认得的机型按标准显示下的短边点数算（和表一致）；不认得的按 scale ÷ nativeScale（放大显示时 nativeScale 明显比 scale 大）
    private static func zoom(_ screen: UIScreen) -> CGFloat {
        let short = min(screen.bounds.width, screen.bounds.height)
        if let known = knownPhone(screen), short > 0 {
            return min(1, max(0.7, short / known.short))
        }
        guard screen.nativeScale > 0, screen.scale > 0 else { return 1 }
        let k = screen.scale / screen.nativeScale
        // 标准显示下两者也可能差一点（12 mini 是 3 对 2.88、Plus 机型反过来），差得不多就不算放大
        return k < 0.96 ? max(0.7, k) : 1
    }

    /// 系统报的值要不要再按「放大显示」折：认得的机型拿表上的值对一下，离「折过的」更近就说明系统已经折过，不再折第二次；
    /// 不认得的当作没折（和表一样按标准显示给）
    private static func zoomed(_ raw: CGFloat, _ screen: UIScreen) -> CGFloat {
        let z = zoom(screen)
        guard z < 0.995 else { return raw }
        if let known = knownPhone(screen), abs(raw - known.radius * z) < abs(raw - known.radius) {
            return raw
        }
        return raw * z
    }

    /// 读不到系统的值：iPhone 查已知机型表，查不到的新机型按短边估；圆角屏的 iPad 18 点；有 Home 键的方屏 0
    private static func estimate(short: CGFloat, bottomInset: CGFloat, screen: UIScreen?) -> CGFloat {
        guard bottomInset > 0 else { return 0 }
        switch UIDevice.current.userInterfaceIdiom {
        case .phone:
            if let screen, let known = knownPhone(screen) { return known.radius * zoom(screen) }
            // 宁小勿大：估大了角上露出暗楔（用户截图里的那一块），估小了光只是有一点点藏到屏幕边框底下。
            // 手机短边 402 左右给 48 点；iPhone Duo 这种更宽的也不超过 55
            return min(55, max(39, (short * 0.12).rounded()))
        case .pad:
            return 18
        default:
            return 0
        }
    }

    /// 已知 iPhone 的屏幕圆角：按物理像素（竖拿，短 × 长）认机型。radius：标准显示下的圆角点数；short：标准显示下的短边点数
    private static func knownPhone(_ screen: UIScreen) -> (radius: CGFloat, short: CGFloat)? {
        let px = screen.nativeBounds.size
        let w = Int(min(px.width, px.height).rounded())
        let h = Int(max(px.width, px.height).rounded())
        switch (w, h) {
        case (1125, 2436): return (39, 375)     // X / XS / 11 Pro
        case (1242, 2688): return (39, 414)     // XS Max / 11 Pro Max
        case (828, 1792): return (41.5, 414)    // XR / 11
        case (1080, 2340): return (44, 375)     // 12 mini / 13 mini
        case (1170, 2532): return (47.33, 390)  // 12 / 12 Pro / 13 / 13 Pro / 14 / 16e
        case (1284, 2778): return (53.33, 428)  // 12 Pro Max / 13 Pro Max / 14 Plus
        case (1179, 2556): return (55, 393)     // 14 Pro / 15 / 15 Pro / 16
        case (1290, 2796): return (55, 430)     // 14 Pro Max / 15 Plus / 15 Pro Max / 16 Plus
        case (1206, 2622): return (62, 402)     // 16 Pro
        case (1320, 2868): return (62, 440)     // 16 Pro Max
        default: return nil
        }
    }
}
