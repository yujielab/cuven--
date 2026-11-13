import XCTest

/// iPhone Duo 的几种形态，用演示数据（-CuvenDemo YES：片名、海报、字标都是本地合成的，截图里没有真实片库）。
/// 模拟器里没有 Duo，用 -CuvenDuo 强制形态：folded = 折起竖拿（补一列 84pt 的黑边模拟外屏右侧那一列），rail = 侧边导航条。
final class DuoTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    private func launch(_ duo: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-CuvenDemo", "YES", "-CuvenDuo", duo]
        app.launch()
        return app
    }

    func testFoldedPortrait() {
        XCUIDevice.shared.orientation = .portrait
        let app = launch("folded")
        XCTAssertTrue(app.buttons["duo-nav-主页"].waitForExistence(timeout: 20), "折起竖拿：右缘没有竖向导航胶囊")
        let bar = app.tabBars.firstMatch
        XCTAssertFalse(bar.exists && bar.isHittable, "折起竖拿：系统标签栏应当收起")
        sleep(3)
        snap("duo-folded-01-home")
        app.swipeUp(); sleep(2); snap("duo-folded-02-rows")
        app.swipeUp(); sleep(2); snap("duo-folded-03-rows")
        app.swipeDown(); app.swipeDown(); app.swipeDown(); sleep(2)

        let card = app.buttons["hero-card"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5), "折起竖拿：首页大图不是卡片态")
        if card.exists {
            card.tap(); sleep(3); snap("duo-folded-04-detail")
            app.swipeUp(); sleep(2); snap("duo-folded-05-detail-2")
            back(app)
        }
        app.buttons["duo-nav-资料库"].tap(); sleep(3); snap("duo-folded-06-library")
        app.buttons["duo-nav-我的"].tap(); sleep(2); snap("duo-folded-07-me")
        app.buttons["duo-nav-搜索"].tap(); sleep(2)
        let field = app.searchFields.firstMatch
        if field.waitForExistence(timeout: 5) {
            field.tap()
            field.typeText("夜")
            sleep(2)
        }
        snap("duo-folded-08-search")
    }

    func testRailLandscape() {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = launch("rail")
        XCTAssertTrue(app.buttons["duo-nav-主页"].waitForExistence(timeout: 20), "横拿：左侧没有导航条")
        sleep(3)
        snap("duo-rail-01-home")
        app.swipeUp(); sleep(2); snap("duo-rail-02-rows")
        app.buttons["duo-nav-资料库"].tap(); sleep(3); snap("duo-rail-03-library")
        let seg = app.segmentedControls.buttons["剧集"]
        if seg.exists {
            seg.tap(); sleep(2)
            let first = app.scrollViews.firstMatch.buttons.element(boundBy: 0)
            if first.exists { first.tap(); sleep(3); snap("duo-rail-04-series-detail"); back(app) }
        }
        XCUIDevice.shared.orientation = .portrait
    }

    private func back(_ app: XCUIApplication) {
        let nav = app.navigationBars.buttons.firstMatch
        if nav.exists { nav.tap() } else { app.swipeRight() }
        sleep(2)
    }

    private func snap(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}
