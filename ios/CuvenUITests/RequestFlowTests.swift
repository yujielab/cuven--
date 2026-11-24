import XCTest

/// 请求中心最上面那张「Luminous Data Flow」卡（RequestFlowCard / FlowFunnel.metal）：演示数据里一批 16 部正在传，
/// 打开「请求」标签后约每半秒一张（看光点流动、能量波、进度条），再切「电影」「剧集」看颜色和漏斗形状一起变过去，
/// 最后滚到「待确认」按「确认请求」（.github/workflows/ios-dissolve.yml，截图名以 flow- 开头）
final class RequestFlowTests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    func testFlowFrames() {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-CuvenDemo", "YES"]
        app.launch()
        let tab = app.tabBars.buttons["请求"].firstMatch
        if tab.waitForExistence(timeout: 20) {
            tab.tap()
        } else if app.buttons["请求"].firstMatch.waitForExistence(timeout: 5) {
            app.buttons["请求"].firstMatch.tap()
        }
        let card = app.descendants(matching: .any)["request-flow-card"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 15), "请求中心最上面那张卡没出来")
        sleep(1)
        let t0 = Date()
        var i = 1
        while Date().timeIntervalSince(t0) < 3.2 {
            snap(String(format: "flow-%02d-all-t%02d", i, Int(Date().timeIntervalSince(t0) * 10)))
            usleep(380_000)
            i += 1
        }
        for (name, id) in [("movie", "flow-tab-movie"), ("tv", "flow-tab-tv"), ("all", "flow-tab-all")] {
            let b = app.buttons[id].firstMatch
            guard b.waitForExistence(timeout: 4) else { continue }
            b.tap()
            usleep(250_000)
            snap(String(format: "flow-%02d-%@-a", i, name)); i += 1
            usleep(700_000)
            snap(String(format: "flow-%02d-%@-b", i, name)); i += 1
        }
        let confirm = app.buttons["basket-confirm"].firstMatch
        for _ in 0..<3 where !confirm.isHittable { app.swipeUp(); usleep(500_000) }
        snap(String(format: "flow-%02d-basket", i)); i += 1
        if confirm.exists && confirm.isHittable {
            confirm.tap()
            sleep(2)
            snap(String(format: "flow-%02d-confirmed", i)); i += 1
        }
    }

    private func snap(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}
