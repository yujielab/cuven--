import XCTest

/// 全部影片（AllFilmsView）：演示数据里直接推进这一页（-CuvenAllFilmsPreview YES），截「可立即播放」的头几节、往下滑，
/// 再切到「可申请」截一遍；再截分类页（「电影 ›」「剧集 ›」点进去的那几页）（.github/workflows/ios-dissolve.yml，截图名以 films- 开头）
final class AllFilmsTests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    func testAllFilms() {
        let app = launch()
        let mode = app.segmentedControls["all-films-mode"].firstMatch
        XCTAssertTrue(mode.waitForExistence(timeout: 20), "全部影片没打开")
        sleep(2)
        snap("films-1-playable-top")
        app.swipeUp(); sleep(1)
        snap("films-2-playable-scrolled")
        app.swipeUp(); sleep(1)
        snap("films-3-playable-more")
        for _ in 0..<3 { app.swipeDown() }
        sleep(1)
        let req = mode.buttons["可申请"].firstMatch
        if req.waitForExistence(timeout: 4) { req.tap() }
        sleep(2)
        snap("films-4-requestable-top")
        app.swipeUp(); sleep(1)
        snap("films-5-requestable-scrolled")
    }

    /// 分类页（用户要求：「可立即播放」「可申请」下面加打开分类的按钮，电影和剧集分开，版式照专区；专区的立体海报换成三张可以横着滑的大卡）。
    /// 重开一次 App，和上面那段互不影响：「可立即播放」点「电影 ›」截一张，顶上的大卡往左滑一张再截，往上滑到下面的大卡列表截一张；
    /// 返回，切到「可申请」点「剧集 ›」截一张。哪一步找不到就记一笔、跳过后面依赖它的截图，不卡住整个测试
    func testCategoryPages() {
        let app = launch()
        let mode = app.segmentedControls["all-films-mode"].firstMatch
        XCTAssertTrue(mode.waitForExistence(timeout: 20), "全部影片没打开")
        sleep(1)
        if openCategory(app, "all-films-kind-movie-") {
            if !headerCard(app).waitForExistence(timeout: 8) { XCTFail("可立即播放 · 电影：顶上没有大卡（category-header-card）") }
            sleep(2)                              // 推进来的过渡、剧照读进来
            snap("films-6-cat-playable-movie")
            swipeHeader(app)
            snap("films-7-cat-header-swiped")
            app.swipeUp(); sleep(1)
            snap("films-8-cat-list")
            back(app)
        }
        // 回到全部影片：分段控件还在原处，切到「可申请」，按钮跟着换成可申请的电影 / 剧集
        if mode.waitForExistence(timeout: 6) {
            let req = mode.buttons["可申请"].firstMatch
            if req.waitForExistence(timeout: 4) { req.tap() }
            sleep(1)
        } else {
            print("FILMS back: all-films-mode not found")
        }
        if openCategory(app, "all-films-kind-series-") {
            if !headerCard(app).waitForExistence(timeout: 10) { XCTFail("可申请 · 剧集：顶上没有大卡（category-header-card）") }
            sleep(3)                              // 可申请那一页先出骨架卡，剧照按编号取（演示数据是本地合成的）
            snap("films-9-cat-requestable-series")
        }
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-CuvenDemo", "YES", "-CuvenAllFilmsPreview", "YES"]
        app.launch()
        return app
    }

    /// 分段控件下面那颗「电影 ›」/「剧集 ›」：在屏上就点正中（不经过 isHittable），找不到记一笔、返回 false
    /// 打开分类页：每一年的「电影 ›」「剧集 ›」小标题（id 是 all-films-kind-movie-<年> 这样的，取最上面那一年的）
    private func openCategory(_ app: XCUIApplication, _ id: String) -> Bool {
        let b = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", id)).firstMatch
        guard b.waitForExistence(timeout: 8) else {
            XCTFail("全部影片没有 \(id)")
            return false
        }
        if b.isOnScreen(in: app) { b.tapCenter() } else { b.tap() }
        sleep(2)                                  // 推进分类页（放大过渡）
        return true
    }

    private func headerCard(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "category-header-card").firstMatch
    }

    /// 顶上三张大卡的框（一次快照，按层级顺序：第一张在前）。不滤屏幕外的：滑过去以后第一张就在左边外面了
    private func headerFrames(_ app: XCUIApplication) -> [CGRect] {
        guard let root = app.timedSnapshot() else { return [] }
        var hits: [CGRect] = []
        var stack: [XCUIElementSnapshot] = [root]
        while let s = stack.popLast() {
            if s.identifier == "category-header-card", s.frame.width > 1, s.frame.height > 1 { hits.append(s.frame) }
            stack.append(contentsOf: s.children.reversed())
        }
        return hits
    }

    /// 顶上的大卡往左滑一张：按住第一张靠右的地方往左拖（按框算坐标，不问 isHittable）。
    /// 卡排比窗口宽（手机上一张约占八成宽，下一张露出一截）时，第一张应当跟着往左挪；宽屏上三张都放得下，滑了也不动
    private func swipeHeader(_ app: XCUIApplication) {
        let win = app.windows.firstMatch.frame
        let before = headerFrames(app)
        guard let f = before.first else {
            print("FILMS header: no card")
            return
        }
        let seen = f.intersection(win)
        let y = seen.isNull ? f.midY : seen.midY
        let x0 = min(f.minX + f.width * 0.8, win.maxX - 12)
        let x1 = max(f.minX + f.width * 0.05, win.minX + 12)
        let origin = app.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: x0, dy: y))
            .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: x1, dy: y)), withVelocity: .fast, thenHoldForDuration: 0)
        sleep(1)                                  // 停到对齐的那一张
        let after = headerFrames(app)
        print("FILMS header x \(before.map { Int($0.minX) }) -> \(after.map { Int($0.minX) }) window \(Int(win.width))")
        if let last = before.last, last.maxX > win.maxX + 1, let a = after.first {
            XCTAssertLessThan(a.minX, f.minX - 20, "顶上的大卡没跟着往左滑")
        }
    }

    /// 系统返回钮（标识 BackButton；Duo 上竖在侧边时不在 navigationBars 里），都没有就从左边缘往右拖
    private func back(_ app: XCUIApplication) {
        let sys = app.buttons["BackButton"].firstMatch
        let nav = sys.exists ? sys : app.navigationBars.buttons.firstMatch
        print("FILMS back \(nav.exists ? "\(nav.frame)" : "none")")
        if nav.exists, nav.isOnScreen(in: app) {
            nav.tapCenter()
        } else {
            let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
            edge.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)))
        }
        sleep(2)
    }

    private func snap(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}
