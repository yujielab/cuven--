import XCTest

extension XCUIElement {
    /// 在屏上：框落在窗口里。不问 isHittable——懒加载的一排里没摆好的元素算不出点按点，
    /// 问一下 XCTest 就直接记一次失败（「Failed to determine hittability」）
    func isOnScreen(in app: XCUIApplication) -> Bool {
        guard exists else { return false }
        let f = frame
        guard f.width > 1, f.height > 1 else { return false }
        return app.windows.firstMatch.frame.contains(CGPoint(x: f.midX, y: f.midY))
    }

    /// 点框的正中（同样不经过 isHittable）
    func tapCenter() {
        coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }
}
