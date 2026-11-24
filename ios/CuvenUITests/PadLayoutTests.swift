import XCTest

/// iPad 版面（用户要求给普通 iPad、iPad Pro 11 / 13 寸定制）：演示数据，竖拿、横拿各截主页、往下一屏、资料库、请求、全部影片。
/// 截图名 pad-<竖 p / 横 l>-<页>（.github/workflows/ios-ipad.yml 按机型前面再加 a16 / p11 / p13）
final class PadLayoutTests: XCTestCase {
    override func setUp() { continueAfterFailure = true }
    override func tearDown() { XCUIDevice.shared.orientation = .portrait }

    func testPortrait() { tour(.portrait, "p") }
    func testLandscape() { tour(.landscapeLeft, "l") }

    private func tour(_ o: UIDeviceOrientation, _ tag: String) {
        XCUIDevice.shared.orientation = o
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-CuvenDemo", "YES"]
        app.launch()
        sleep(6)
        snap("pad-\(tag)-1-home")
        app.swipeUp(); sleep(2)
        snap("pad-\(tag)-2-home-down")
        app.swipeUp(); sleep(2)
        snap("pad-\(tag)-3-home-more")
        for (i, name) in [(4, "资料库"), (5, "请求")] {
            if open(app, name) { sleep(3); snap("pad-\(tag)-\(i)-\(name == "请求" ? "requests" : "library")") }
        }
        app.terminate()
        // 全部影片：演示数据里直接推进这一页
        let films = XCUIApplication()
        films.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-CuvenDemo", "YES", "-CuvenAllFilmsPreview", "YES"]
        films.launch()
        let mode = films.segmentedControls["all-films-mode"].firstMatch
        if mode.waitForExistence(timeout: 20) {
            sleep(2)
            snap("pad-\(tag)-6-allfilms")
            // 可申请那一边（和可立即播放同一种横卡）
            let req = mode.buttons["可申请"].firstMatch
            if req.waitForExistence(timeout: 4) {
                req.tap(); sleep(3)
                snap("pad-\(tag)-7-requestable")
                mode.buttons["可立即播放"].firstMatch.tap(); sleep(2)
            }
            // 详情页：横拿时简介和影片详细信息并排两栏
            let card = films.buttons["all-films-movie"].firstMatch
            if card.waitForExistence(timeout: 6) {
                card.tap(); sleep(4)
                snap("pad-\(tag)-8-detail")
                films.swipeUp(); sleep(2)
                snap("pad-\(tag)-9-detail-info")
            }
        }
    }

    /// 标签栏 / 侧边栏里那一项（iPadOS 26 的标签栏在顶上，可能是标签栏的按钮，也可能是侧边栏的一行）
    private func open(_ app: XCUIApplication, _ name: String) -> Bool {
        for q in [app.tabBars.buttons[name], app.buttons[name], app.cells[name], app.staticTexts[name]] {
            let e = q.firstMatch
            if e.waitForExistence(timeout: 3), e.isHittable { e.tap(); return true }
        }
        return false
    }

    private func snap(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}
