import XCTest

/// 在「iPhone Duo」模拟器（iOS 27.1+ 运行时）上跑，演示数据（-CuvenDemo YES：片名、海报、字标都是本地合成的，不用登录）。
/// 不强制任何形态：看系统把标签栏 / 工具栏 / 返回钮放在哪，内容铺到哪。截图以 duo- 开头，会公开到 refs/ci/ios-preview-demo，
/// 所以这里只截演示数据和登录页（登录页盖住整个屏幕，后面的片库露不出来）。
final class DuoDeviceTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    private func launch(demo: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        if demo { app.launchArguments += ["-CuvenDemo", "YES"] }
        app.launch()
        return app
    }

    func testPortrait() {
        XCUIDevice.shared.orientation = .portrait
        let app = launch()
        sleep(4)
        report(app, "home")
        snap("duo-01-home")
        app.swipeUp(); sleep(2); snap("duo-02-home-rows")
        app.swipeDown(); app.swipeDown(); sleep(1)

        // 详情：系统的返回钮（折起时在侧边那一列最上面）
        let card = app.buttons["hero-card"].firstMatch
        let poster = app.buttons["newest-poster"].firstMatch
        if card.waitForExistence(timeout: 5) { card.tap() } else if poster.exists { poster.tap() }
        XCTAssertTrue(app.buttons["detail-play"].waitForExistence(timeout: 8), "没进到电影详情")
        sleep(2)
        report(app, "detail")
        snap("duo-03-detail")
        app.swipeUp(); sleep(2); snap("duo-04-detail-info")
        back(app)

        tab(app, "资料库"); sleep(3)
        report(app, "library")
        snap("duo-05-library")

        // 剧集详情：横排的分集大卡
        let seg = app.segmentedControls.buttons["剧集"]
        if seg.waitForExistence(timeout: 5) {
            seg.tap(); sleep(2)
            let s1 = app.buttons["library-series"].firstMatch
            if s1.waitForExistence(timeout: 5) {
                s1.tap(); sleep(3)
                snap("duo-05b-series")
                app.swipeUp(); sleep(2)
                snap("duo-05c-series-episodes")
                back(app)
            }
            app.segmentedControls.buttons["电影"].tap(); sleep(1)
        }

        let acct = visible(app.buttons.matching(identifier: "account-button"))
        if acct.waitForExistence(timeout: 5) {
            acct.tap(); sleep(2)
            snap("duo-06-account")
            let done = app.buttons["account-done"].firstMatch
            if done.waitForExistence(timeout: 3) { done.tap() } else { app.swipeDown() }
            sleep(1)
        } else {
            XCTFail("资料库右上角没有头像（账户与设置）")
        }

        tab(app, "搜索"); sleep(2)
        let field = app.searchFields.firstMatch
        if field.waitForExistence(timeout: 5) {
            field.tap()
            field.typeText("夜")
            sleep(2)
        }
        snap("duo-07-search")
    }

    func testLandscape() {
        // 先竖着启动、再转横：冷启动时直接横着启动，模拟器上偶尔起不来
        XCUIDevice.shared.orientation = .portrait
        let app = launch()
        sleep(4)
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(3)
        report(app, "landscape")
        snap("duo-11-landscape-home")
        tab(app, "资料库"); sleep(3)
        snap("duo-12-landscape-library")
        XCUIDevice.shared.orientation = .portrait
    }

    /// 没登录：整屏登录页（只在确认登录页出现时才截图，免得截到后面的真实片库）
    func testLoginScreen() {
        XCUIDevice.shared.orientation = .portrait
        let app = launch(demo: false)
        let subtitle = app.staticTexts["使用你的 Cuven 账户登录 Cuven max。"]
        XCTAssertTrue(subtitle.waitForExistence(timeout: 20), "没登录时应当先出现登录页")
        // 截图前再确认一次登录页还盖着（登录页不透明，后面的片库露不出来）
        if subtitle.exists && app.textFields.count > 0 {
            sleep(2)
            if subtitle.exists { snap("duo-21-login") }
        }

        // 连得上账户服务、读得懂它的回答：输一个不存在的用户名（只读查询，不写任何东西），应当提示「新用户」
        let cont = app.buttons["Continue"].firstMatch          // 模拟器第一次弹键盘时的「滑动输入」提示
        if cont.exists { cont.tap(); sleep(1) }
        let field = app.textFields["login-user"].exists ? app.textFields["login-user"] : app.textFields.firstMatch
        if field.exists {
            field.tap()
            field.typeText("cuvenciprobe\(Int(Date().timeIntervalSince1970) % 100000)")
            let newUser = app.staticTexts["新用户 — 将建立您的账户"]
            XCTAssertTrue(newUser.waitForExistence(timeout: 20), "账户服务查不到或读不懂（应当提示新用户）")
            if subtitle.exists { snap("duo-22-login-lookup") }
        }
    }

    private func tab(_ app: XCUIApplication, _ name: String) {
        let b = app.tabBars.buttons[name].firstMatch
        if b.exists { b.tap(); return }
        let any = app.buttons[name].firstMatch
        if any.exists { any.tap() }
    }

    /// 系统返回钮：竖在侧边时不在 navigationBars 里，按它的标识找
    private func back(_ app: XCUIApplication) {
        let sys = app.buttons["BackButton"].firstMatch
        let nav = sys.exists ? sys : app.navigationBars.buttons.firstMatch
        print("DUO back \(nav.exists ? "\(nav.frame)" : "none")")
        if nav.exists { nav.tap() } else { app.swipeRight() }
        sleep(2)
    }

    /// 打进测试日志（工作流 grep「DUO 」）：窗口多大、系统标签栏在哪
    private func report(_ app: XCUIApplication, _ tag: String) {
        let w = app.windows.firstMatch.frame
        let bar = app.tabBars.firstMatch
        let barInfo = bar.exists ? "tabBar \(bar.frame)" : "tabBar none"
        let shot = XCUIScreen.main.screenshot().image.size
        print("DUO \(tag) window \(Int(w.width))x\(Int(w.height)) screenshot \(Int(shot.width))x\(Int(shot.height)) \(barInfo)")
    }

    private func snap(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    /// 第一个真正在屏上的匹配项（切到别的标签后，上一页的同名按钮还留在层级里，只是看不见）
    private func visible(_ q: XCUIElementQuery) -> XCUIElement {
        _ = q.firstMatch.waitForExistence(timeout: 5)
        return q.allElementsBoundByIndex.first { $0.isHittable } ?? q.firstMatch
    }
}
