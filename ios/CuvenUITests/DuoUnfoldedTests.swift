import XCTest
import UIKit

/// 「iPhone Duo」展开：预览工作流先用 simctl 关掉外屏、打开内屏，再单独跑这一个类（别的时候不跑）。
/// 看系统在内屏上把栏放在哪、内容怎么排。演示数据（-CuvenDemo YES），截图以 duo-3 开头，公开到 refs/ci/ios-preview-demo。
/// 窗口还是外屏那么大（没切过去）就不截图，免得和折起的截图混在一起。
/// 模拟器的 Duo 切不到内屏，所以工作流还在 iPad mini 上跑同一个类（竖拿 744 点宽，和展开竖拿的 669 点同一套「展开」版面）：
/// 那几张以 duo-4 开头，用来核对展开时的卡片大小和间距
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
        // 主页一路往下：年份两排、精选电影、编辑推荐、精选剧集、四个大类、结尾（每一屏都看卡片大小和排距）
        for i in 0..<9 {
            app.swipeUp(); sleep(2)
            snap("duo-32\(Array("abcdefghi")[i])-unfolded-rows")
        }
        app.scrollHomeToTop()

        // 详情（头图上此刻在屏上的「详情」，没有就点主页上一张在屏上的电影卡）。不问 isHittable：
        // iPad 上头图翻页时问它会记一次「Failed to determine hittability」，整个测试就停在这里
        let target = app.onScreenFrames(["hero-detail"]).first ?? app.onScreenFrames(["movie-card"]).first
        if let f = target {
            app.tap(at: CGPoint(x: f.midX, y: f.midY))
            if app.buttons["detail-play"].waitForExistence(timeout: 8) {
                sleep(2)
                report(app, "unfolded detail")
                snap("duo-33-unfolded-detail")
                // 往下一屏：简介、剧照、详细信息卡
                app.swipeUp(); sleep(2)
                snap("duo-33b-unfolded-detail-more")
                app.swipeUp(); sleep(2)
                snap("duo-33c-unfolded-detail-info")
                back(app)
            } else {
                print("DUO unfolded detail: did not open")
            }
        } else {
            print("DUO unfolded detail: nothing to open")
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
            for i in 0..<6 {
                app.swipeUp(); sleep(2)
                snap("duo-37\(Array("abcdef")[i])-unfolded-landscape-rows")
            }
            app.scrollHomeToTop()
        } else {
            print("DUO unfolded landscape: did not rotate")
        }
        XCUIDevice.shared.orientation = .portrait
    }

    /// 半折的播放面板（PlayerTabletop.swift）：上面画面、下面一条 Touch Bar + 液态玻璃的信息区；横过来是书本（右页画面、左页控制）。
    /// 模拟器折不了、演示数据也放不了片，所以用 -CuvenTabletop YES 弹一个假的播放页，折痕固定在屏正中。
    /// 截 duo-38*（iPad 上是 duo-48*）；外屏大小不截
    func testTabletopPanel() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-CuvenDemo", "YES", "-CuvenTabletop", "YES"]
        app.launch()
        let close = app.buttons["player-close"]
        guard close.waitForExistence(timeout: 15) else {
            print("DUO tabletop: panel did not appear")
            return
        }
        sleep(2)
        let size = report(app, "tabletop")
        guard size.width > 500, size.height > size.width else { return }
        snap("duo-38-tabletop")
        // 锁定屏幕方向：那一颗亮起来（白底黑锁）
        if tapID(app, "player-lock") {
            snap("duo-38b-tabletop-locked")
            tapID(app, "player-lock")
        }
        // 亮度：这颗键长成一整条滑杆，⊗ 收起
        if tapID(app, "player-brightness") {
            snap("duo-38c-touchbar-brightness")
            tapID(app, "player-close")
        }
        // ‹：展开整条控制条；字幕展开成一排选项；⊗ 一层层收回
        if tapID(app, "player-more") {
            snap("duo-38f-touchbar-strip")
            if tapID(app, "player-subtitles") {
                snap("duo-38g-touchbar-subtitles")
                tapID(app, "player-close")
            }
            tapID(app, "player-close")
        }
        // 下面那块的几个标签
        for (tab, tag) in [("insight", "h"), ("continueWatching", "i"), ("recommend", "j")] {
            if tapID(app, "deck-tab-\(tab)") { snap("duo-38\(tag)-deck-\(tab)") }
        }
        tapID(app, "deck-tab-about")
        // 书本：横过来，折痕变成竖的——左页控制、右页画面
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(3)
        let wide = report(app, "book")
        if wide.width > wide.height {
            snap("duo-38e-book")
            if tapID(app, "player-more") {
                snap("duo-38d-book-strip")
                tapID(app, "player-close")
            }
        } else {
            print("DUO book: did not rotate")
        }
        XCUIDevice.shared.orientation = .portrait
        sleep(1)
    }

    /// 点屏上标识为 id 的那个元素正中（找不到就记一笔、返回 false）
    @discardableResult
    private func tapID(_ app: XCUIApplication, _ id: String) -> Bool {
        guard let f = app.onScreenFrames([id]).first else {
            print("DUO tabletop: \(id) not on screen")
            return false
        }
        app.tap(at: CGPoint(x: f.midX, y: f.midY))
        sleep(1)
        return true
    }

    /// 光影实验室（PlayerLab.swift）：放内置的测试画面，四段场景各截一张，看卡片上的光跟着画面变（火是暖的、海是冷的、
    /// 夜里只有局部的光、霓虹是分开的几种颜色）；再横过来截一张。截 duo-39*（iPad 上 duo-49*）；外屏大小不截
    func testPlayerLab() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-CuvenDemo", "YES", "-CuvenPlayerLab", "YES"]
        app.launch()
        guard app.staticTexts["lab-ready"].waitForExistence(timeout: 40) else {
            print("DUO lab: test pattern did not start")
            snap("duo-39z-lab-not-ready")
            return
        }
        sleep(2)
        report(app, "lab")
        // 实验室里 windows.firstMatch 有时是一个 0×0 的系统窗口（CI 记到过）：按屏幕大小判断是不是内屏 / iPad
        let screen = inner.screenshot().image.size
        guard min(screen.width, screen.height) > 500 else { return }
        let scenes = ["fire", "ocean", "night", "neon"]
        for (i, name) in scenes.enumerated() {
            labTap(app, "lab-scene-\(i)")
            sleep(1)
            snap("duo-39\(Array("abcd")[i])-lab-\(name)")
        }
        // 三种光影模式，都在火光那一段上看（影院是默认）
        for (preset, tag) in [("standard", "f"), ("immersive", "g")] {
            labTap(app, "lab-scene-0")
            labTap(app, "lighting-preset-\(preset)")
            sleep(1)
            snap("duo-39\(tag)-lab-\(preset)")
        }
        labTap(app, "lighting-preset-cinematic")
        // 闲置：5 秒不碰，符号淡出，卡上的光留着（从海面开始等，截到的时候正好放到霓虹）
        labTap(app, "lab-scene-1")
        sleep(7)
        snap("duo-39h-lab-idle")
        labTap(app, "lab-scene-0")
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(3)
        snap("duo-39e-lab-landscape")
        XCUIDevice.shared.orientation = .portrait
        sleep(1)
    }

    /// 实验室里按标识点元素。这里 windows.firstMatch 是一个 0×0 的系统窗口，按窗口框算「在不在屏上」的
    /// onScreenFrames 什么都找不到（CI 记到过：点击全落空，截到的场景、模式都不对）；交给 XCUITest 自己找、自己滚到可见再点
    private func labTap(_ app: XCUIApplication, _ id: String) {
        let e = app.descendants(matching: .any).matching(identifier: id).firstMatch
        guard e.waitForExistence(timeout: 3) else {
            print("DUO lab: \(id) not found")
            return
        }
        e.tap()
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

    /// 展开竖拿是系统标签栏，展开横拿是 App 自己画在侧边那一列的导航（DuoNav）：都按 label 认，取点得到的那个
    private func tab(_ app: XCUIApplication, _ name: String) {
        if !app.tapTab(named: name) { print("DUO unfolded tab \(name): not on screen") }
    }

    private func back(_ app: XCUIApplication) {
        let sys = app.buttons["BackButton"].firstMatch
        let nav = sys.exists ? sys : app.navigationBars.buttons.firstMatch
        if nav.exists { nav.tap() } else { app.swipeRight() }
        sleep(2)
    }

    /// iPad 上跑的那一遍：截图改成 duo-4 开头，和 Duo 自己的 duo-3 分开
    private func snap(_ name: String) {
        let a = XCTAttachment(screenshot: inner.screenshot())
        a.name = UIDevice.current.userInterfaceIdiom == .pad ? name.replacingOccurrences(of: "duo-3", with: "duo-4") : name
        a.lifetime = .keepAlways
        add(a)
    }
}
