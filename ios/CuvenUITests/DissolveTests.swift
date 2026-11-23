import XCTest

/// 清除缓存的动画（CacheDissolveSheet）：一打开就是那一屏（-CuvenDissolvePreview YES，演示数据，不清真的缓存），
/// 空闲时一张，点「清除」后每隔约半秒一张，看卡化成光点、流成光纤、汇进进度胶囊那一点的光（.github/workflows/ios-dissolve.yml）
final class DissolveTests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    func testDissolveFrames() {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-CuvenDemo", "YES", "-CuvenDissolvePreview", "YES"]
        app.launch()
        let go = app.buttons["cache-dissolve-clear"].firstMatch
        XCTAssertTrue(go.waitForExistence(timeout: 20), "清除缓存那一屏没出来")
        sleep(2)
        snap("dissolve-00-idle")
        go.tap()
        let t0 = Date()
        var i = 1
        while Date().timeIntervalSince(t0) < 7.6 {
            usleep(420_000)
            snap(String(format: "dissolve-%02d-%.1fs", i, Date().timeIntervalSince(t0)))
            i += 1
        }
        sleep(2)
        snap("dissolve-99-after")
    }

    private func snap(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}
