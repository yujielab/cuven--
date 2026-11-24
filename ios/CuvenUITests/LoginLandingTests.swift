import XCTest

/// 新登录落地页（LoginLanding：「ideas in motion.」、品牌蓝收束成图标、海报平面从灵动岛下面涌出来）。
/// 用户要求「UI 和动效参考我发的视频和文档」：开场那一秒多按参考的时间点对照，所以一打开就尽量密地连拍
/// （约 0.2、0.6、0.7、0.8、1.0、1.3、1.8、2.5 秒，再补一张约 6 秒），然后截终态、点「使用账号密码登录」、回来、点「使用光学配对登录」。
/// 演示数据 + -CuvenLoginLanding YES 强制出这一层（.github/workflows/ios-dissolve.yml，截图名以 login- 开头）。
/// 哪一步找不到就记一笔、跳过依赖它的那一步，不卡住整个测试
final class LoginLandingTests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    private static let args = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-CuvenDemo", "YES", "-CuvenLoginLanding", "YES"]

    func testLoginLanding() {
        let app = XCUIApplication()
        app.launchArguments += Self.args
        let launchStart = Date()
        app.launch()
        // 名字里的毫秒从 launch() 返回那一刻算：落地页在 launch() 里面就出来了，真实的 t 只会比这个数大（差多少看日志里的 launch 用时）
        let t0 = Date()
        print("LOGIN launch took \(Int(t0.timeIntervalSince(launchStart) * 1000)) ms")

        // 开场：先不查元素（每查一次都要拍整棵树，几百毫秒就过去了），只管连拍；截图先攒着，放完再一起存（存附件也费时间）
        var frames: [(ms: Int, shot: XCUIScreenshot)] = []
        while frames.count < 40 {
            let a = Date().timeIntervalSince(t0)
            if a > 2.9 { break }
            let shot = XCUIScreen.main.screenshot()
            let b = Date().timeIntervalSince(t0)
            // 截图在这次调用中间某一刻拍下：取前后两端的中点
            frames.append((ms: Int((a + b) * 500), shot: shot))
        }
        // 约 6 秒：海报平面一直在流（底下回收、上面补）
        let rest = 6.0 - Date().timeIntervalSince(t0)
        if rest > 0 { usleep(UInt32(rest * 1_000_000)) }
        let late = XCUIScreen.main.screenshot()
        frames.append((ms: Int(Date().timeIntervalSince(t0) * 1000), shot: late))
        print("LOGIN intro frames: \(frames.map { $0.ms })")
        for f in frames { attach(f.shot, String(format: "login-00-%05d", f.ms)) }

        let root = element(app, "login-landing")
        let pair = element(app, "login-pair-button")
        let account = element(app, "login-account-button")
        if !(root.waitForExistence(timeout: 10) || pair.exists) {
            XCTFail("登录落地页没出来（login-landing）")
        }
        snap("login-10-final")

        // 「使用账号密码登录」：原来那一页（LoginScreen）带着它自己的入场动效（约 1.95 秒）
        if account.waitForExistence(timeout: 6) {
            tap(account, in: app)
            sleep(3)
            snap("login-11-account")
            if !element(app, "login-user").exists && !element(app, "login-primary").exists {
                print("LOGIN account: login-user / login-primary not found")
            }
            if !backToLanding(app) {
                // 回不去（没有返回钮、也划不回去）：重开一次，等开场放完
                print("LOGIN back: no way back to the landing, relaunching")
                app.terminate()
                app.launch()
                _ = pair.waitForExistence(timeout: 20)
                sleep(4)
            }
        } else {
            XCTFail("落地页没有 login-account-button")
        }

        // 「使用光学配对登录」：打开粒子云那一屏（PairShowView，演示数据里不画云）
        if pair.waitForExistence(timeout: 8) {
            tap(pair, in: app)
            sleep(2)
            snap("login-12-pair")
            if !element(app, "pair-cloud").exists && !element(app, "pair-show-password").exists {
                print("LOGIN pair: pair-cloud / pair-show-password not found")
            }
        } else {
            XCTFail("落地页没有 login-pair-button")
        }
    }

    // MARK: -

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// 在屏上就点正中（不经过 isHittable：海报平面一直在动），否则交给 XCTest 自己点
    private func tap(_ e: XCUIElement, in app: XCUIApplication) {
        if e.isOnScreen(in: app) { e.tapCenter() } else { e.tap() }
    }

    /// 落地页在最上面：两颗按钮在屏上，账号密码那一页的输入框和主按钮都不在
    private func landingShowing(_ app: XCUIApplication) -> Bool {
        element(app, "login-pair-button").isOnScreen(in: app)
            && !element(app, "login-user").exists && !element(app, "login-primary").exists
    }

    /// 账号密码那一页回到落地页：先找返回 / 关闭（落地页加的、表单自己的、按读屏名字认），最多点三次；
    /// 还没回去就当它是推进来的，从左边缘往右划一下
    private func backToLanding(_ app: XCUIApplication) -> Bool {
        for _ in 0..<3 {
            if landingShowing(app) { return true }
            guard let b = backControl(app) else { break }
            tap(b, in: app)
            sleep(2)
        }
        if landingShowing(app) { return true }
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        from.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)))
        sleep(2)
        return landingShowing(app)
    }

    private func backControl(_ app: XCUIApplication) -> XCUIElement? {
        for id in ["login-landing-back", "login-account-back", "login-account-close", "login-close", "login-back"] {
            let e = element(app, id)
            if e.exists { return e }
        }
        let named = app.buttons.matching(NSPredicate(format: "label IN {'返回', '关闭', 'Back'}")).firstMatch
        return named.exists ? named : nil
    }

    private func snap(_ name: String) {
        attach(XCUIScreen.main.screenshot(), name)
    }

    private func attach(_ shot: XCUIScreenshot, _ name: String) {
        let a = XCTAttachment(screenshot: shot)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}
