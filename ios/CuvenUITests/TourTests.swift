import XCTest

/// 在模拟器里把主要页面走一遍、每一步截一张图（预览工作流把截图从结果包里导出来）。
/// 连的是生产接口：片库、元数据、海报都是真的。
final class TourTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
    }

    func testTour() {
        sleep(3)
        snap("01-launch")

        // 片库与元数据到了，首页会出现「最新加入」
        XCTAssertTrue(app.staticTexts["最新加入"].waitForExistence(timeout: 90), "首页没有出现「最新加入」")
        sleep(8)
        snap("02-home")

        app.swipeUp(); sleep(3); snap("03-home-1")
        app.swipeUp(); sleep(3); snap("04-home-2")
        app.swipeUp(); sleep(3); snap("05-home-3")

        // 剧集卡 → 剧集详情
        let series = app.buttons["series-card"].firstMatch
        if series.waitForExistence(timeout: 5) {
            series.tap()
            sleep(6)
            snap("06-series-detail")
            app.swipeUp(); sleep(3); snap("07-series-episodes")
            back()
        }

        // 回到顶上：大图的「详情」→ 电影详情
        app.swipeDown(); app.swipeDown(); app.swipeDown(); app.swipeDown()
        sleep(2)
        let detail = app.buttons["hero-detail"].firstMatch
        if detail.waitForExistence(timeout: 10) {
            detail.tap()
        } else if app.buttons["newest-poster"].firstMatch.waitForExistence(timeout: 5) {
            app.buttons["newest-poster"].firstMatch.tap()
        }
        let play = app.buttons["detail-play"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 20), "电影详情页没有播放钮")
        sleep(5)
        snap("08-movie-detail")
        app.swipeUp(); sleep(3); snap("09-movie-detail-2")
        app.swipeDown(); sleep(1)

        // 播放：系统播放器
        if play.exists {
            play.tap()
            sleep(15)
            snap("10-player")
            for label in ["关闭", "Close", "完成", "Done"] where app.buttons[label].exists {
                app.buttons[label].tap(); break
            }
            if app.otherElements["AVPlayerView"].exists || !app.tabBars.firstMatch.exists {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                sleep(1)
                for label in ["关闭", "Close", "完成", "Done"] where app.buttons[label].exists {
                    app.buttons[label].tap(); break
                }
            }
            sleep(3)
        }
        back()

        // 资料库 / 搜索
        tapTab(["资料库"])
        sleep(6)
        snap("11-library")
        tapTab(["搜索", "Search"])
        sleep(2)
        let field = app.searchFields.firstMatch
        if field.waitForExistence(timeout: 5) {
            field.tap()
            field.typeText("沙丘")
            sleep(3)
            snap("12-search")
        }
        tapTab(["我的"])
        sleep(2)
        snap("13-me")
    }

    private func back() {
        let nav = app.navigationBars.buttons.firstMatch
        if nav.exists { nav.tap() } else { app.swipeRight() }
        sleep(2)
    }

    private func tapTab(_ names: [String]) {
        for n in names {
            let b = app.tabBars.buttons[n]
            if b.exists { b.tap(); return }
            let any = app.buttons[n]
            if any.exists { any.tap(); return }
        }
    }

    private func snap(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}
