import XCTest

/// 全部影片（AllFilmsView）：演示数据里直接推进这一页（-CuvenAllFilmsPreview YES），截「可立即播放」的头几节、往下滑，
/// 再切到「可申请」截一遍（.github/workflows/ios-dissolve.yml，截图名以 films- 开头）
final class AllFilmsTests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    func testAllFilms() {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-CuvenDemo", "YES", "-CuvenAllFilmsPreview", "YES"]
        app.launch()
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

    private func snap(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}
