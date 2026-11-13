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
        // 「更多操作」：播放钮旁边那颗玻璃圆钮，弹出和网页版一样的弹层（播放 / 复制直链 / 取消）
        let more = app.buttons["detail-more"].firstMatch
        if more.waitForExistence(timeout: 3) {
            more.tap(); sleep(2)
            snap("duo-03b-detail-more")
            let cancel = app.buttons["sheet-cancel"].firstMatch
            if cancel.waitForExistence(timeout: 3) { cancel.tap() } else { app.swipeDown() }
            sleep(1)
        } else {
            XCTFail("详情页没有「更多操作」钮")
        }
        // 演员阵容 · 查看全部 ›：整页名单（在简介下面，先找它，再往下滑）
        if let castLink = reveal(app, app.buttons.matching(identifier: "cast-link"), swipes: 2) {
            castLink.tap(); sleep(2)
            snap("duo-04b-cast")
            back(app)
        } else {
            XCTFail("详情页没有「演员与职员 ›」")
        }
        app.swipeUp(); sleep(2); snap("duo-04-detail-info")
        app.swipeUp(); sleep(2); snap("duo-04c-detail-tech")
        back(app)
        // 主页往下：今日推荐、最新加入（横版卡）、Cuven TV（高卡）、按年份（年份条 + 剧集卡 + 竖版卡）
        app.swipeUp(); sleep(2); snap("duo-08-home-rows")
        app.swipeUp(); sleep(2); snap("duo-08b-home-tv")
        app.swipeUp(); sleep(2); snap("duo-08c-home-year")
        app.swipeUp(); sleep(2); snap("duo-08d-home-year-2")
        app.swipeDown(); app.swipeDown(); app.swipeDown(); app.swipeDown(); app.swipeDown(); sleep(1)

        tab(app, "资料库"); sleep(3)
        report(app, "library")
        snap("duo-05-library")

        // 剧集详情：横排的分集大卡（资料库的标题「你的电影 ⌃⌄」是个菜单，换成剧集）
        if switchLibrary(app, to: "剧集") {
            snap("duo-05a-library-series")
            let s1 = app.buttons["library-series"].firstMatch
            if s1.waitForExistence(timeout: 5) {
                s1.tap(); sleep(3)
                snap("duo-05b-series")
                app.swipeUp(); sleep(2)
                snap("duo-05c-series-episodes")
                // 季切换：「第 1 季 ⌃⌄」点开是季的菜单，选第 2 季
                let seasonMenu = app.buttons["season-menu"].firstMatch
                if seasonMenu.waitForExistence(timeout: 3) {
                    seasonMenu.tap(); sleep(1)
                    snap("duo-05d-season-menu")
                    let s2 = app.buttons["第 2 季"].firstMatch
                    if s2.waitForExistence(timeout: 3) {
                        s2.tap(); sleep(2)
                        snap("duo-05e-season-2")
                    } else {
                        print("DUO season menu: item not exposed")
                        app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.1)).tap(); sleep(1)
                    }
                }
                back(app)
            }
            switchLibrary(app, to: "电影")
        }

        // 账户与设置：网页版导航胶囊里的头像，这里是「账户」标签
        tab(app, "账户"); sleep(2)
        snap("duo-06-account")

        tab(app, "搜索"); sleep(2)
        snap("duo-07a-search-home")          // 为你推荐 + 浏览
        // 浏览：点一格类型，进那一类的整页清单
        if let tile = reveal(app, app.buttons.matching(identifier: "genre-tile")) {
            tile.tap(); sleep(2)
            snap("duo-07b-genre")
            back(app)
        } else {
            XCTFail("搜索页没有「浏览」的类型格子")
        }
        app.swipeDown(); sleep(1)
        let field = app.searchFields.firstMatch
        if field.waitForExistence(timeout: 5) {
            field.tap()
            field.typeText("夜")
            sleep(2)
        }
        snap("duo-07-search")

        // 先收起键盘、退出搜索：键盘盖住了侧边那一列底下的标签栏
        app.swipeDown(); sleep(1)
        for label in ["关闭", "Close", "取消", "Cancel"] {
            let b = app.buttons[label].firstMatch
            if b.exists && b.isHittable { b.tap(); sleep(1); break }
        }

        // 长按海报：菜单（播放 / 想看），预览是那张卡（放在最后：菜单没收起也不影响别的步骤）
        tab(app, "主页"); sleep(2)
        if let poster = reveal(app, app.buttons.matching(identifier: "newest-poster")) {
            poster.press(forDuration: 1.2); sleep(2)
            snap("duo-10-menu")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.06)).tap(); sleep(1)
        }
    }

    func testLandscape() {
        // 先竖着启动、再转横：冷启动时直接横着启动，模拟器上偶尔起不来
        XCUIDevice.shared.orientation = .portrait
        let app = launch()
        sleep(4)
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(3)
        if !rotated(app) { XCUIDevice.shared.orientation = .landscapeRight; sleep(3) }
        report(app, "landscape")
        // 折起时外屏在模拟器里可能不跟着转：没转就不截（免得把竖屏图标成横屏）
        guard rotated(app) else {
            print("DUO landscape: did not rotate (window and screenshot stay portrait)")
            XCUIDevice.shared.orientation = .portrait
            return
        }
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

    private func rotated(_ app: XCUIApplication) -> Bool {
        let w = app.windows.firstMatch.frame.size
        let shot = XCUIScreen.main.screenshot().image.size
        return w.width > w.height || shot.width > shot.height
    }

    /// 资料库的标题「你的电影 ⌃⌄」是个菜单：点开选「剧集」/「电影」
    @discardableResult
    private func switchLibrary(_ app: XCUIApplication, to kind: String) -> Bool {
        let menu = app.buttons["library-kind"].firstMatch
        guard menu.waitForExistence(timeout: 5) else { return false }
        menu.tap(); sleep(1)
        let item = app.buttons[kind].firstMatch
        guard item.waitForExistence(timeout: 3) else { return false }
        item.tap(); sleep(2)
        return true
    }

    /// 标签：竖在侧边时不算 tabBars，直接按名字找按钮（少问一次）
    private func tab(_ app: XCUIApplication, _ name: String) {
        let b = app.buttons[name].firstMatch
        if b.waitForExistence(timeout: 5) { b.tap() }
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

    /// 往上滑，直到第一个匹配项在屏上点得到（懒加载的排要滑到才会生成）。只看第一个：每问一次元素就是一次快照
    private func reveal(_ app: XCUIApplication, _ q: XCUIElementQuery, swipes: Int = 6) -> XCUIElement? {
        for i in 0...swipes {
            let e = q.firstMatch
            if e.exists && e.isHittable { return e }
            if i < swipes { app.swipeUp(); sleep(1) }
        }
        return nil
    }

    /// 第一个真正在屏上的匹配项（切到别的标签后，上一页的同名按钮还留在层级里，只是看不见）
    private func visible(_ q: XCUIElementQuery) -> XCUIElement {
        _ = q.firstMatch.waitForExistence(timeout: 5)
        return q.allElementsBoundByIndex.first { $0.isHittable } ?? q.firstMatch
    }
}
