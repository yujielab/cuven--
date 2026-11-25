import XCTest

/// 「请求添加」改成上滑发送的胶囊（用户要求：参考视频，上滑或按下「请求添加」→ 粒子箭头飞上去、屏上「正在发往请求中心」
/// → 打勾、「已添加至请求中心」等您进一步操作并显示时间）。演示数据 + -CuvenRequestPreview YES 推进一部可请求添加的剧集
/// （长夜将明，默认第 2 季，RequestViews.swift 最下面）。XCUITest 拖到一半停不住、也拍不了，所以分三段截：
///  1. 静止的胶囊（send-00-ready）→ 往上拖一小段就松手：应弹回原位、不提交（send-01-returned）
///  2. 点一下胶囊（用户说「按下」也算）→ 尽量密地连拍约 3 秒（send-1x-<毫秒>：正在发送、打勾、波纹、屏幕边缘的光）
///     → 终态（send-20-settled）→ 点「好」回到详情页（send-21-back：这一季已加入，没有胶囊是对的）
///  3. 换到第 1 季，整段往上拖过提交距离、停一下再松手（上滑提交那条路）→ 连拍（send-3x-<毫秒>）→ 终态（send-40-settled）
///     → 点「前往请求中心」（send-41-center）
/// 截图名以 send- 开头（.github/workflows/ios-dissolve.yml）。哪一步找不到就记一笔、跳过依赖它的那几步，不卡住整个测试
final class RequestSendTests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    private static let capsuleID = "request-send-capsule"

    func testSwipeToSend() {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-CuvenDemo", "YES", "-CuvenRequestPreview", "YES"]
        app.launch()

        var capsuleID = Self.capsuleID
        if !element(app, capsuleID).waitForExistence(timeout: 25) {
            XCTFail("详情页上没有上滑发送的胶囊（request-send-capsule）")
            // 退一步用原来那颗「请求添加」，至少还能截到按下去以后那一屏
            guard element(app, "request-add").exists else {
                snap("send-00-missing")
                return
            }
            print("SEND capsule missing, falling back to request-add")
            capsuleID = "request-add"
        }
        let id = capsuleID
        _ = app.bringIntoBand(where: { $0.identifier == id })
        // 等详情页载入完、胶囊底下那团青紫的光亮起来
        sleep(2)
        snap("send-00-ready")

        // 1. 没到提交距离就松手：手指只走不到半个胶囊高（橡皮筋阻尼下胶囊走得更少），慢慢拖，不带甩出去的速度；
        //    规格里弹回去是 160–220 毫秒，等 0.6 秒再截
        let cap1 = element(app, capsuleID)
        if cap1.exists {
            let f = cap1.frame
            print("SEND capsule \(f) label=\(cap1.label)")
            let start = point(f, in: app)
            start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -max(18, f.height * 0.4))),
                       withVelocity: .slow, thenHoldForDuration: 0.05)
            usleep(600_000)
            snap("send-01-returned")
            if overlay(app).exists {
                XCTFail("没拖到提交距离就松手，却发出去了（request-send-overlay 出来了）")
                dismiss(app)
            }
        }

        // 2. 点一下（用户要求「上滑或按下」都能申请）：先把点哪儿算好，连拍时不再查元素（每查一次都要拍整棵树）
        let cap2 = element(app, capsuleID)
        if cap2.exists {
            let at = point(cap2.frame, in: app)
            burst("send-1x", seconds: 3.0) { at.tap() }
            // 终态：成功以后约 0.7–0.85 秒波纹收住，屏幕圆角边缘的光慢慢由紫转青（参考视频 5.6 秒以后）
            sleep(1)
            snap("send-20-settled")
            report(app, "tap")
            let done = element(app, "request-send-done")
            if done.waitForExistence(timeout: 4) {
                tap(done, in: app)
                sleep(2)
            } else {
                XCTFail("点了胶囊以后没有「好」（request-send-done）")
            }
            snap("send-21-back")
            // 这一季已经在请求中心里：照旧是「已加入请求中心」那颗按钮，没有胶囊
            print("SEND back: capsule \(element(app, capsuleID).exists ? "still there" : "gone (already in the basket, expected)")")
        } else {
            print("SEND tap: capsule gone before the tap")
        }

        // 3. 上滑提交那条路：第 2 季刚加进去了，换到第 1 季，胶囊回来以后整段往上拖（超过 1.5 个胶囊高的行程），
        //    在上面停一下（到了提交距离：轻震、「松手即可申请」），再松手
        guard let chip = app.bringIntoBand(where: { $0.identifier == "request-season-1" }) else {
            print("SEND swipe: no request-season-1 chip")
            return
        }
        chip.tap()
        sleep(1)
        guard element(app, capsuleID).waitForExistence(timeout: 5) else {
            print("SEND swipe: capsule did not come back for season 1")
            snap("send-30-no-capsule")
            return
        }
        _ = app.bringIntoBand(where: { $0.identifier == id })
        sleep(1)
        snap("send-30-season1")
        let cap3 = element(app, capsuleID)
        guard cap3.exists else { return }
        let g = cap3.frame
        let from = point(g, in: app)
        burst("send-3x", seconds: 3.0) {
            from.press(forDuration: 0.12, thenDragTo: from.withOffset(CGVector(dx: 0, dy: -max(110, g.height * 2.4))),
                       withVelocity: .slow, thenHoldForDuration: 0.5)
        }
        sleep(1)
        snap("send-40-settled")
        report(app, "swipe")
        // 「前往请求中心」：收起这一屏、切到请求中心
        let center = element(app, "request-send-open-center")
        if center.waitForExistence(timeout: 4) {
            tap(center, in: app)
            sleep(2)
            snap("send-41-center")
        } else {
            XCTFail("上滑提交以后没有「前往请求中心」（request-send-open-center）")
        }
    }

    // MARK: -

    /// 做一个手势，然后尽量密地连拍 seconds 秒：截图先攒着，拍完再一起存（存附件也费时间）。
    /// 名字里的毫秒从手势调用返回那一刻算（XCTest 在手势前后都要等 App 空闲，手势本身用了多久打进日志）
    private func burst(_ prefix: String, seconds: Double, gesture: () -> Void) {
        let g0 = Date()
        gesture()
        let t0 = Date()
        print("SEND \(prefix) gesture took \(Int(t0.timeIntervalSince(g0) * 1000)) ms")
        var frames: [(ms: Int, shot: XCUIScreenshot)] = []
        while frames.count < 40 {
            let a = Date().timeIntervalSince(t0)
            if a > seconds { break }
            let shot = XCUIScreen.main.screenshot()
            let b = Date().timeIntervalSince(t0)
            // 截图在这次调用中间某一刻拍下：取前后两端的中点
            frames.append((ms: Int((a + b) * 500), shot: shot))
        }
        print("SEND \(prefix) frames: \(frames.map { $0.ms })")
        for f in frames { attach(f.shot, String(format: "%@-%05ld", prefix, f.ms)) }
    }

    /// 发往请求中心那一屏在不在、两颗按钮在不在（日志里 grep「SEND 」）
    private func report(_ app: XCUIApplication, _ path: String) {
        let o = overlay(app).exists
        let done = element(app, "request-send-done").exists
        let center = element(app, "request-send-open-center").exists
        print("SEND \(path): overlay=\(o) done=\(done) open-center=\(center)")
        // 根上的标识不一定读得到（整屏的画布），三个都找不到才算没出来
        if !o && !done && !center { XCTFail("\(path) 以后没出现发往请求中心那一屏（request-send-overlay）") }
    }

    private func overlay(_ app: XCUIApplication) -> XCUIElement {
        element(app, "request-send-overlay")
    }

    /// 关掉发往请求中心那一屏（按「好」）
    private func dismiss(_ app: XCUIApplication) {
        let done = element(app, "request-send-done")
        if done.waitForExistence(timeout: 4) {
            tap(done, in: app)
            sleep(2)
        }
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// 元素框正中在窗口里的那一点（拖、点都从这里起，不经过 isHittable：胶囊底下的光一直在动）
    private func point(_ f: CGRect, in app: XCUIApplication) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: f.midX, dy: f.midY))
    }

    /// 在屏上就点正中，否则交给 XCTest 自己点
    private func tap(_ e: XCUIElement, in app: XCUIApplication) {
        if e.isOnScreen(in: app) { e.tapCenter() } else { e.tap() }
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
