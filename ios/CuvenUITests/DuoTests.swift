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
        // 再点一下当前那一格：回到资料库的根页面
        let tile = app.buttons["library-movie"].firstMatch
        if tile.waitForExistence(timeout: 5) {
            tile.tap()
            XCTAssertTrue(app.buttons["detail-play"].waitForExistence(timeout: 5), "资料库：没进到电影详情页")
            app.buttons["duo-nav-资料库"].tap(); sleep(2)
            XCTAssertFalse(app.buttons["detail-play"].exists, "再点一下「资料库」应当回到资料库的根页面")
            XCTAssertTrue(app.buttons["library-movie"].firstMatch.waitForExistence(timeout: 3), "回到根页面后没有海报网格")
        }
        app.buttons["duo-nav-我的"].tap(); sleep(2); snap("duo-folded-07-me")
        app.buttons["duo-nav-搜索"].tap(); sleep(2)
        let field = app.searchFields.firstMatch
        if field.waitForExistence(timeout: 5) {
            field.tap()
            field.typeText("夜")
            sleep(2)
        }
        snap("duo-folded-08-search")
        // 键盘起来时导航胶囊整枚挪到键盘上面
        let kb = app.keyboards.firstMatch
        let me = app.buttons["duo-nav-我的"]
        if kb.exists && me.exists {
            XCTAssertLessThanOrEqual(me.frame.maxY, kb.frame.minY + 1, "键盘盖住了导航胶囊")
        }
    }

    func testRailLandscape() {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = launch("rail")
        XCTAssertTrue(app.buttons["duo-nav-主页"].waitForExistence(timeout: 20), "横拿：左侧没有导航条")
        sleep(3)
        snap("duo-rail-01-home")
        app.swipeUp(); sleep(2); snap("duo-rail-02-rows")
        app.buttons["duo-nav-资料库"].tap(); sleep(3); snap("duo-rail-03-library")
        assertClearOfRail(app, app.buttons["library-movie"].firstMatch)
        let seg = app.segmentedControls.buttons["剧集"]
        if seg.waitForExistence(timeout: 5) {
            seg.tap()
            let first = app.buttons["library-series"].firstMatch
            if first.waitForExistence(timeout: 5) {
                first.tap(); sleep(3); snap("duo-rail-04-series-detail"); back(app)
            } else {
                XCTFail("资料库：切到剧集后没有剧集")
            }
        }
        XCUIDevice.shared.orientation = .portrait
    }

    /// 展开的内屏（竖拿也是侧边导航条）：用强制 rail 的竖屏模拟
    func testRailPortrait() {
        XCUIDevice.shared.orientation = .portrait
        let app = launch("rail")
        XCTAssertTrue(app.buttons["duo-nav-主页"].waitForExistence(timeout: 20), "展开：左侧没有导航条")
        sleep(3)
        snap("duo-railp-01-home")
        app.swipeUp(); sleep(2); snap("duo-railp-02-rows")
        app.buttons["duo-nav-资料库"].tap(); sleep(3); snap("duo-railp-03-library")
        assertClearOfRail(app, app.buttons["library-movie"].firstMatch)
    }

    /// 内容整体让出导航条：第一列海报的左缘在导航条右缘的右边
    private func assertClearOfRail(_ app: XCUIApplication, _ el: XCUIElement) {
        let nav = app.buttons["duo-nav-主页"]
        guard el.waitForExistence(timeout: 5), nav.exists else { return XCTFail("没找到海报或导航条") }
        XCTAssertGreaterThanOrEqual(el.frame.minX, nav.frame.maxX + 8, "内容压到了侧边导航条底下")
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
