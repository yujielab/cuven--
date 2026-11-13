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

        // 回到顶上：大图里「此刻在屏上」的那张的「详情」→ 电影详情（大图会自动翻页，不能拿第一张）
        app.swipeDown(); app.swipeDown(); app.swipeDown(); app.swipeDown()
        sleep(2)
        let heroDetail = app.buttons.matching(identifier: "hero-detail").allElementsBoundByIndex.first { $0.isHittable }
        if let heroDetail {
            heroDetail.tap()
        } else {
            let poster = app.buttons.matching(identifier: "newest-poster").allElementsBoundByIndex.first { $0.isHittable }
            poster?.tap()
        }
        let play = app.buttons["detail-play"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 20), "电影详情页没有播放钮")
        sleep(5)
        snap("08-movie-detail")
        app.swipeUp(); sleep(3); snap("09-movie-detail-2")
        app.swipeDown(); sleep(2)

        // 播放：系统播放器
        if play.exists && play.isHittable {
            play.tap()
            sleep(15)
            snap("10-player")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            sleep(1)
            for label in ["关闭", "Close", "完成", "Done"] where app.buttons[label].exists {
                app.buttons[label].tap(); break
            }
            sleep(3)
            snap("10b-after-player")
        }
        back()

        // 资料库 → 剧集 / 我的 / 搜索（搜索放最后：键盘会盖住标签栏）
        tapTab(["资料库"])
        sleep(6)
        snap("11-library")
        let seg = app.segmentedControls.buttons["剧集"]
        if seg.exists { seg.tap(); sleep(6); snap("11b-library-series") }
        tapTab(["我的"])
        sleep(2)
        snap("12-me")
        tapTab(["搜索", "Search"])
        sleep(2)
        let field = app.searchFields.firstMatch
        if field.waitForExistence(timeout: 5) {
            field.tap()
            field.typeText("沙丘")
            sleep(3)
            snap("13-search")
        }
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
