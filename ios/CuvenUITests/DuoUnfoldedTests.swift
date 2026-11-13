import XCTest

/// 「iPhone Duo」展开：预览工作流先用 simctl 关掉外屏、打开内屏，再单独跑这一个类（别的时候不跑）。
/// 看系统在内屏上把栏放在哪、内容怎么排。演示数据（-CuvenDemo YES），截图以 duo-3 开头，公开到 refs/ci/ios-preview-demo。
/// 窗口还是外屏那么大（没切过去）就不截图，免得和折起的截图混在一起。
final class DuoUnfoldedTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    func testUnfolded() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-CuvenDemo", "YES"]
        app.launch()
        sleep(4)
        let size = report(app, "unfolded")
        // 内屏上到底显示的是什么（App 的窗口没跟着变大时，看看是镜像、缩放还是黑屏）
        snap("duo-30-unfolded-probe")
        guard size.width > 500 else {
            print("DUO unfolded: the app window stayed at the outer display size")
            return
        }
        snap("duo-31-unfolded-home")
        app.swipeUp(); sleep(2); snap("duo-32-unfolded-rows")
        app.swipeDown(); app.swipeDown(); sleep(1)

        // 详情（大图态点画面、卡片态点卡片，都没有就点「最新加入」的海报）
        if let open = firstHittable(app, ["hero-detail", "hero-card", "newest-poster"]) {
            open.tap()
            if app.buttons["detail-play"].waitForExistence(timeout: 8) {
                sleep(2)
                report(app, "unfolded detail")
                snap("duo-33-unfolded-detail")
                back(app)
            }
        }

        tab(app, "资料库"); sleep(3)
        snap("duo-34-unfolded-library")

        // 展开横拿
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(3)
        let wide = report(app, "unfolded landscape")
        if wide.width > wide.height {
            snap("duo-35-unfolded-landscape-library")
            tab(app, "主页"); sleep(3)
            snap("duo-36-unfolded-landscape-home")
        } else {
            print("DUO unfolded landscape: did not rotate")
        }
        XCUIDevice.shared.orientation = .portrait
    }

    @discardableResult
    private func report(_ app: XCUIApplication, _ tag: String) -> CGSize {
        let w = app.windows.firstMatch.frame.size
        let all = XCUIScreen.screens.map { sc -> String in
            let z = sc.screenshot().image.size
            return "\(Int(z.width))x\(Int(z.height))"
        }
        print("DUO \(tag) window \(Int(w.width))x\(Int(w.height)) screens \(all.joined(separator: ", "))")
        return w
    }

    /// 截内屏：几块屏里面积最大的那块（外屏关了以后，main 不一定指向内屏；电视输出那块是 720x480）
    private var inner: XCUIScreen {
        XCUIScreen.screens.max { a, b in
            let x = a.screenshot().image.size, y = b.screenshot().image.size
            return x.width * x.height < y.width * y.height
        } ?? XCUIScreen.main
    }

    private func firstHittable(_ app: XCUIApplication, _ ids: [String]) -> XCUIElement? {
        for id in ids {
            if let e = app.buttons.matching(identifier: id).allElementsBoundByIndex.first(where: { $0.isHittable }) { return e }
        }
        return nil
    }

    private func tab(_ app: XCUIApplication, _ name: String) {
        let b = app.tabBars.buttons[name].firstMatch
        if b.exists { b.tap(); return }
        let any = app.buttons[name].firstMatch
        if any.exists { any.tap() }
    }

    private func back(_ app: XCUIApplication) {
        let sys = app.buttons["BackButton"].firstMatch
        let nav = sys.exists ? sys : app.navigationBars.buttons.firstMatch
        if nav.exists { nav.tap() } else { app.swipeRight() }
        sleep(2)
    }

    private func snap(_ name: String) {
        let a = XCTAttachment(screenshot: inner.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}
