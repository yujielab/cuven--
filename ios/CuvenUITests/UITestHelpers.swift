import XCTest

extension XCUIElement {
    /// 在屏上：框落在窗口里。不问 isHittable——懒加载的一排里没摆好的元素算不出点按点，
    /// 问一下 XCTest 就直接记一次失败（「Failed to determine hittability」），还会把这个测试停在那里
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

extension XCUIApplication {
    /// 正中落在窗口里的元素框，按层级顺序（大致从上到下、一排里从左到右）。
    /// 只拍一次快照：逐个问元素的 frame，每问一次 XCTest 都要重拍整棵树（主页元素多，一次就要好几秒）。
    /// skipBars：落在标签栏底下的不算（点下去点到的是标签栏）
    func onScreenFrames(skipBars: Bool = true, where match: (XCUIElementSnapshot) -> Bool) -> [CGRect] {
        guard let root = try? snapshot() else { return [] }
        var window = CGRect.null, bars: [CGRect] = [], hits: [CGRect] = []
        // 先序遍历（子节点倒着压栈，出栈就是层级顺序）
        var stack: [XCUIElementSnapshot] = [root]
        while let s = stack.popLast() {
            if s.elementType == .window, window.isNull { window = s.frame }
            if s.elementType == .tabBar { bars.append(s.frame) }
            if match(s) { hits.append(s.frame) }
            stack.append(contentsOf: s.children.reversed())
        }
        if window.isNull { window = root.frame }
        return hits.filter { f in
            let c = CGPoint(x: f.midX, y: f.midY)
            return f.width > 1 && f.height > 1 && window.contains(c) && !(skipBars && bars.contains { $0.contains(c) })
        }
    }

    func onScreenFrames(_ ids: Set<String>) -> [CGRect] {
        onScreenFrames { ids.contains($0.identifier) }
    }

    /// 点窗口里的一个点（不经过 isHittable）
    func tap(at p: CGPoint) {
        coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: p.x, dy: p.y)).tap()
    }

    /// 往上滑，直到 ids 里有一个元素在屏上，点它正中。看的是全部匹配项，不只第一个：
    /// 一排里第一张剧集卡可能在屏幕右边外面，只看它的话怎么往上滑都找不到
    @discardableResult
    func revealAndTap(_ ids: Set<String>, swipes: Int) -> CGRect? {
        for i in 0...swipes {
            if let f = onScreenFrames(ids).first {
                tap(at: CGPoint(x: f.midX, y: f.midY))
                return f
            }
            if i < swipes { swipeUp(); sleep(2) }
        }
        return nil
    }

    /// 回到主页最上面：看到「Home」那一行的头像就停（多拉一下会触发下拉刷新）
    func scrollHomeToTop(maxSwipes: Int = 16) {
        for _ in 0..<maxSwipes {
            // iPad 的标签栏在最上面，头像可能落在它的框里：这里不跳过标签栏底下的
            if !onScreenFrames(skipBars: false, where: { $0.identifier == "home-account" }).isEmpty { break }
            swipeDown()
        }
        sleep(1)
    }

    /// 导航里按名字（label）的一格：系统标签栏、侧边栏、Duo 侧边那一列都按 label 认，点在屏上的那个
    @discardableResult
    func tapTab(named name: String) -> Bool {
        guard let f = onScreenFrames(skipBars: false, where: { $0.elementType == .button && $0.label == name }).first else { return false }
        tap(at: CGPoint(x: f.midX, y: f.midY))
        return true
    }
}
