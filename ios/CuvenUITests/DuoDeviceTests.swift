import XCTest

/// 在「iPhone Duo」模拟器（iOS 27.1+ 运行时）上跑，演示数据（-CuvenDemo YES：片名、海报、字标都是本地合成的，不用登录）。
/// 不强制任何形态：看系统把标签栏 / 工具栏 / 返回钮放在哪，内容铺到哪。截图以 duo- 开头，会公开到 refs/ci/ios-preview-demo，
/// 所以这里只截演示数据和登录页（登录页盖住整个屏幕，后面的片库露不出来）。
final class DuoDeviceTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    private func launch(demo: Bool = true, welcome: Bool = false, privacy: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        if demo { app.launchArguments += ["-CuvenDemo", "YES"] }
        if welcome { app.launchArguments += ["-CuvenWelcome", "YES"] }
        if privacy { app.launchArguments += ["-CuvenPrivacy", "YES"] }
        app.launch()
        return app
    }

    /// 隐私同意闸门（网页版 #pgSheet）：登录后没同意过就盖上。演示数据默认不出，这里用 -CuvenPrivacy YES 强制。
    /// 弹层本身只有文案与合成内容；勾满三项、开通知（系统权限弹窗点「允许」，没弹就算了），「同意并进入」以后应当到主页
    func testPrivacyGate() {
        XCUIDevice.shared.orientation = .portrait
        let app = launch(privacy: true)
        let agree = app.buttons["pg-agree"].firstMatch
        XCTAssertTrue(agree.waitForExistence(timeout: 15), "隐私同意闸门没出现")
        sleep(2)                                   // 弹层推上来、标题与要点依次升上来
        report(app, "privacy")
        snap("duo-00c-privacy")
        XCTAssertFalse(agree.isEnabled, "三项都没勾，「同意并继续」不该能点")

        // 展开完整说明，再往下滚到「您的选择」
        let disclose = app.buttons["pg-disclose"].firstMatch
        if disclose.waitForExistence(timeout: 3) { disclose.tap(); sleep(1) }
        app.swipeUp(); sleep(1)
        snap("duo-00d-privacy-2")
        for id in ["pg-privacy", "pg-cross", "pg-age"] {
            if let row = reveal(app, app.buttons.matching(identifier: id), swipes: 3) { row.tap(); usleep(300_000) } else { print("DUO privacy: \(id) not found") }
        }
        snap("duo-00e-privacy-done")
        if agree.isEnabled {
            agree.tap()
            sleep(2)
            XCTAssertFalse(app.buttons["pg-agree"].exists, "点了「同意并继续」闸门还在")
            XCTAssertTrue(app.buttons["主页"].firstMatch.waitForExistence(timeout: 10), "同意以后没到主页")
        } else {
            print("DUO privacy: agree still disabled (hint: \(app.staticTexts["pg-hint"].firstMatch.label))")
        }
    }

    /// 欢迎页（网页版 #wc-root）：已登录时打开 App 先盖这一屏。演示数据默认不出，这里用 -CuvenWelcome YES 强制。
    /// 只截欢迎页本身（演示账户名、没有头像时的剪影），点「确认并继续」以后不截（后面是片库）
    func testWelcome() {
        XCUIDevice.shared.orientation = .portrait
        let app = launch(welcome: true)
        let cta = app.buttons["welcome-continue"].firstMatch
        XCTAssertTrue(cta.waitForExistence(timeout: 15), "欢迎页没出现")
        sleep(3)                                   // 问候语两行依次模糊淡入（0.2 / 0.55 秒起，各 1 秒）
        report(app, "welcome")
        snap("duo-00-welcome")
        cta.tap()
        sleep(2)
        XCTAssertFalse(app.buttons["welcome-continue"].exists, "点了「确认并继续」欢迎页还在")
        XCTAssertTrue(app.buttons["主页"].firstMatch.waitForExistence(timeout: 10), "欢迎页之后没到主页")
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
        // 和网页版一样是一张弹层（「演员阵容 · N 位」，一行一位）；点一行换成那位演员（「在资料库中搜索」「在 TMDB 查看」）
        if let castLink = reveal(app, app.buttons.matching(identifier: "cast-link"), swipes: 2) {
            castLink.tap(); sleep(2)
            snap("duo-04b-cast")
            let row = app.buttons["cast-row"].firstMatch
            if row.waitForExistence(timeout: 3) {
                row.tap(); sleep(2)
                snap("duo-04e-actor")
            } else {
                print("DUO cast sheet: no rows")
            }
            closeSheet(app)
        } else {
            XCTFail("详情页没有「演员阵容 · 查看全部 ›」")
        }
        app.swipeUp(); sleep(2); snap("duo-04-detail-info")
        app.swipeUp(); sleep(2); snap("duo-04c-detail-tech")
        back(app)
        // 主页往下：今日推荐、最新加入（横版卡）、Cuven TV（高卡）、按年份（年份条 + 剧集卡 + 竖版卡）
        app.swipeUp(); sleep(2); snap("duo-08-home-rows")
        app.swipeUp(); sleep(2); snap("duo-08b-home-tv")
        app.swipeUp(); sleep(2); snap("duo-08c-home-year")
        app.swipeUp(); sleep(2); snap("duo-08d-home-year-2")
        // 「继续观看」只有一张时右边垫一张「没有更多了」（演示数据里正好一张）
        print("DUO continue end card: \(app.staticTexts["没有更多了"].exists ? "shown" : "not found")")
        // 首页最后一段「文件夹」：点进文件夹页（子文件夹一排 + 按年份分组的瀑布流）
        if let folder = reveal(app, app.buttons.matching(identifier: "folder-card"), swipes: 8) {
            snap("duo-08e-home-folders")
            folder.tap(); sleep(2)
            snap("duo-08f-folder")
            app.swipeUp(); sleep(1)
            snap("duo-08g-folder-2")
            back(app)
        } else {
            print("DUO folder card: not found")
        }
        for _ in 0..<14 { app.swipeDown() }
        sleep(1)

        // 资料库：和网页版一样的展映——一部片一章，满屏画幅 → 收成 16:9、介绍面板压上来 → 剧照
        tab(app, "资料库"); sleep(3)
        report(app, "library")
        snap("duo-05-library")
        app.swipeUp(); sleep(2); snap("duo-05f-library-shrink")
        app.swipeUp(); sleep(2); snap("duo-05g-library-intro")
        if let d = reveal(app, app.buttons.matching(identifier: "library-movie"), swipes: 2) {
            d.tap(); sleep(2)
            XCTAssertTrue(app.buttons["detail-play"].waitForExistence(timeout: 8), "资料库「影片详情」没进到详情页")
            snap("duo-05h-library-detail")
            back(app)
        } else {
            XCTFail("资料库没有「影片详情」")
        }

        // 剧集详情：主页「Cuven TV」那一排的高卡（资料库和网页版一样只放电影）
        tab(app, "主页"); sleep(2)
        if let s1 = reveal(app, app.buttons.matching(identifier: "series-card"), swipes: 4) {
            s1.tap(); sleep(3)
            snap("duo-05b-series")
            app.swipeUp(); sleep(2)
            snap("duo-05c-series-episodes")
            // 分集简介超过三行：第三行末尾的「更多」，点开是整段简介的弹层（底下「关闭」）
            let epMore = app.buttons["episode-more"].firstMatch
            if epMore.waitForExistence(timeout: 2) {
                epMore.tap(); sleep(2)
                snap("duo-05f-episode-more")
                closeSheet(app)
            } else {
                print("DUO episode more: none")
            }
            // 季切换：分集标题右边「第 1 季 ›」点开是季的菜单，选第 2 季
            if let seasonMenu = reveal(app, app.buttons.matching(identifier: "season-menu"), swipes: 1) {
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
        } else {
            XCTFail("主页没有剧集高卡")
        }
        for _ in 0..<6 { app.swipeDown() }
        sleep(1)

        // 年份页：主页「2026 · 查看电影和剧集 ›」进去，一行一部；行尾「…」是和详情页同一张弹层
        tab(app, "主页"); sleep(2)
        if let bar = reveal(app, app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'year-bar-'")), swipes: 6) {
            bar.tap(); sleep(2)
            snap("duo-09-year")
            let more = app.buttons["year-more"].firstMatch
            if more.waitForExistence(timeout: 3) {
                more.tap(); sleep(2)
                snap("duo-09b-year-more")
                let cancel = app.buttons["sheet-cancel"].firstMatch
                if cancel.waitForExistence(timeout: 3) { cancel.tap() } else { app.swipeDown() }
                sleep(1)
            }
            back(app)
        } else {
            XCTFail("主页没有年份条")
        }
        for _ in 0..<8 { app.swipeDown() }
        sleep(1)

        // 账户与设置：网页版导航胶囊里的头像，这里是「账户」标签
        tab(app, "账户"); sleep(2)
        snap("duo-06-account")

        tab(app, "搜索"); sleep(2)
        snap("duo-07a-search-home")          // 最近添加：两列竖版海报
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

    /// 关掉网页版式的弹层：点底部那颗胶囊（「取消」/「关闭」），找不到就往下滑
    private func closeSheet(_ app: XCUIApplication) {
        let cancel = app.buttons["sheet-cancel"].firstMatch
        if cancel.waitForExistence(timeout: 3) && cancel.isHittable { cancel.tap() } else { app.swipeDown() }
        sleep(1)
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
