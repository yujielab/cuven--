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
        guard let root = timedSnapshot() else { return [] }
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

    /// 拍一次整棵树的快照，慢了、失败了打进日志（工作流 grep「SNAP 」）：以前快照失败时 try? 一声不吭地当成「没找到」，
    /// 日志里只看得到「详情页没有『演员 ›』」，看不出是元素真不在，还是快照超时了
    func timedSnapshot() -> XCUIElementSnapshot? {
        let t0 = Date()
        do {
            let root = try snapshot()
            let dt = Date().timeIntervalSince(t0)
            if dt > 5 { print("SNAP slow: \(String(format: "%.1f", dt)) s") }
            return root
        } catch {
            print("SNAP failed after \(String(format: "%.1f", Date().timeIntervalSince(t0))) s: \(error.localizedDescription)")
            return nil
        }
    }

    /// 把 match 选中的元素挪进屏幕中间那一段（上面让开状态栏和钉在顶上的标题条，下面让开 Home 指示条），
    /// 给出它在这一段里露出来那部分的正中（点按、长按都用它）。
    /// 一次快照里找：整页一列（不是懒加载）的页面上，屏幕外的元素也在树里、有位置，差多少就慢慢拖多少——
    /// 不甩：甩出去的惯性停不准；也不往下甩：在详情页最上面往下甩，会把从卡上放大出来的详情页拖回去（以前就这样退回了主页）。
    /// 只露出一截、正中压在钉住的标题条底下的也不算：点下去点到的是标题条（回到顶上），不是它。
    /// 树里还没有的（懒加载还没生成），往上拖一段再找
    func bringIntoBand(maxDrags: Int = 6, where match: (XCUIElementSnapshot) -> Bool) -> XCUICoordinate? {
        for _ in 0...maxDrags {
            guard let root = timedSnapshot() else { sleep(1); continue }
            var window = CGRect.null
            var hits: [CGRect] = []
            var stack: [XCUIElementSnapshot] = [root]
            while let s = stack.popLast() {
                if s.elementType == .window, window.isNull { window = s.frame }
                if match(s), s.frame.width > 1, s.frame.height > 1 { hits.append(s.frame) }
                stack.append(contentsOf: s.children.reversed())
            }
            if window.isNull { window = root.frame }
            let band = CGRect(x: window.minX, y: window.minY + 150, width: window.width, height: max(120, window.height - 240))
            // 横着的一排里可能有几张：取正中横着在屏上的那张
            guard let f = hits.first(where: { $0.midX > window.minX && $0.midX < window.maxX }) ?? hits.first else {
                drag(by: -band.height * 0.6)
                continue
            }
            let seen = f.intersection(band)
            if !seen.isNull, seen.height >= min(44, f.height * 0.6), f.midX > window.minX, f.midX < window.maxX {
                return coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: f.midX, dy: seen.midY))
            }
            // 把它的上沿挪到这一段上沿往下 24 点：在下面就往上拖，在上面就往下拖（一次最多拖这一段的八成）
            let dy = (band.minY + 24) - f.minY
            drag(by: max(-band.height * 0.8, min(band.height * 0.8, dy)))
        }
        return nil
    }

    /// 慢慢拖 dy 点（正数往下、负数往上），停一下再松手：不留惯性，页面挪多少是多少
    func drag(by dy: CGFloat) {
        let from = coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: dy < 0 ? 0.75 : 0.3))
        from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: 0, dy: dy)),
                   withVelocity: .slow, thenHoldForDuration: 0.3)
        sleep(1)
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
