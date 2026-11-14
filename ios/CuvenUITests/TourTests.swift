import XCTest

/// 在模拟器里把主要页面走一遍、每一步截一张图（预览工作流把截图从结果包里导出来）。
/// 连的是生产接口：片库、元数据、海报都是真的。
final class TourTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication()
        // 没有测试账户（仓库是公开的，不放凭据）：Debug 构建认 -CuvenSkipLogin，跳过登录页
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-CuvenSkipLogin", "YES"]
        app.launch()
    }

    /// 首页的货架出来了：今年 / 去年那两排里有电影海报（卡上只有画面，靠标识认）
    private func homeReady(timeout: TimeInterval) -> Bool {
        let card = app.buttons.matching(identifier: "movie-card").firstMatch
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if card.exists { return true }
            _ = card.waitForExistence(timeout: 2)
        }
        return card.exists
    }

    func testTour() {
        sleep(3)
        snap("01-launch")

        // 片库与元数据到了，首页会出现今年 / 去年的电影海报
        XCTAssertTrue(homeReady(timeout: 90), "首页没有出现电影海报")
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
        let screen = app.windows.firstMatch.frame
        func onScreen(_ e: XCUIElement) -> Bool {
            let f = e.frame
            return f.width > 0 && f.minX >= screen.minX - 1 && f.maxX <= screen.maxX + 1 && f.minY >= screen.minY && f.maxY <= screen.maxY
        }
        // 大图会自动翻页，按钮可能正跨在屏幕边上：往下滑一点，点第一张完整在屏上的电影海报
        app.swipeUp()
        sleep(2)
        if let poster = app.buttons.matching(identifier: "movie-card").allElementsBoundByIndex.first(where: onScreen) {
            poster.tap()
        } else if let heroDetail = app.buttons.matching(identifier: "hero-detail").allElementsBoundByIndex.first(where: onScreen) {
            heroDetail.tap()
        }
        let play = app.buttons["detail-play"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 20), "电影详情页没有播放钮")
        sleep(5)
        snap("08-movie-detail")
        app.swipeUp(); sleep(3); snap("09-movie-detail-2")
        // 预告片在详情页「预告片」一排（有才有），资料库展映里也有静音的那一段，下面资料库那一步看它
        app.swipeDown(); sleep(2)

        // 播放：系统播放器（点了立刻弹出，片源准备好再挂上）。等 30 秒（诊断日志里有准备 / 挂上 / 首帧的耗时和每 5 秒的进度），然后关掉 ——
        // 系统播放器的控件几秒就自己藏起来，查询一慢按钮就不在了：往下滑关；还在的话重开 App（进度已经存了）
        var relaunched = false
        if play.exists {
            play.tap()
            sleep(30)
            snap("10-player")
            app.swipeDown(velocity: .fast)
            if !app.buttons["detail-play"].waitForExistence(timeout: 8) {
                app.terminate()
                app.launch()
                _ = homeReady(timeout: 60)
                relaunched = true
            }
            sleep(2)
            snap("10b-after-player")
        }
        if !relaunched { back() }

        // 资料库（展映）→ 我的 / 搜索（搜索放最后：键盘会盖住标签栏）
        tapTab(["资料库"])
        sleep(6)
        snap("11-library")
        // 展映：第一章在屏幕中间时挂上它的预告片（有的话：右上角出现播放 / 暂停钮），再往上滚到介绍面板
        if app.buttons["showcase-trailer"].waitForExistence(timeout: 12) { print("TOUR library trailer: shown") }
        else { print("TOUR library trailer: none") }
        snap("11a-library-trailer")
        app.swipeUp(); sleep(2)
        app.swipeUp(); sleep(2)
        snap("11b-library-intro")
        tapTab(["账户"])
        sleep(2)
        snap("12-account")
        tapTab(["搜索", "Search"])
        sleep(3)
        snap("12b-search-home")
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

    /// 第一个真正在屏上的匹配项（切到别的标签后，上一页的同名按钮还留在层级里，只是看不见）
    private func visible(_ q: XCUIElementQuery) -> XCUIElement {
        _ = q.firstMatch.waitForExistence(timeout: 5)
        return q.allElementsBoundByIndex.first { $0.isOnScreen(in: app) } ?? q.firstMatch
    }
}
