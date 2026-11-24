import XCTest

/// 详情页字标的粒子转场（用户要求：往下滚，头部的大字标化成细粒子，沿一条往右鼓的弧线飞上去、在顶上那条的左上角拼回小字标；
/// 滚动停下就停在这一帧，往回滚原路拼回大字标）。演示数据（-CuvenDemo YES）：演示片的字标是本地画的彩色透明字标
/// （红字蓝边的主字标、上面一枚小厂牌、下面一行黄色副标题，DemoData.renderLogo），粒子的颜色和拼回来的先后在截图里看得出来。
/// 从首页头图的「详情」进一部电影，一小步一小步往上拖（慢拖、停住再松手，不留惯性：停在哪就是哪一帧），
/// 进度从 0 到 1 截 detail-logo-00…12；再一步步往回拖，截 detail-logo-back-0…3（3 回到最上面，大字标拼好）。
/// 滚了多少按简介卡（拿不到就是「播放」）在窗口里的上沿量，拖动被滚动视图吃掉的那一截每拖一次重新估
final class DetailLogoTests: XCTestCase {
    /// 量滚动用的锚点，按先后取第一个找得到的
    private static let anchors = ["about-synopsis", "detail-play"]

    private var anchorID: String?
    private var anchorY0: CGFloat = 0
    /// 拖的距离比页面实际滚的多出来的那一截（滚动视图先要认出这是拖动）
    private var slop: CGFloat = 8
    /// 量不到锚点时，按要求的距离记着页面大概滚到了哪
    private var assumed: CGFloat = 0

    override func setUp() { continueAfterFailure = true }

    func testLogoParticleFrames() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-CuvenDemo", "YES"]
        app.launch()
        guard openMovieDetail(app) else {
            XCTFail("没进到电影详情")
            return
        }
        // 画面和字标定下来、字标模糊淡入、字标管线（判明暗、反白）走完
        sleep(3)

        let window = app.windows.firstMatch.frame
        let top = barBottom(app)
        // 进度从 0 走到 1 要滚多远：和 DetailScaffold 的 pinAt 同一个估法（头部九成屏高，减去字块离底、按钮、顶上那条和系统栏）
        let range = max(240, (window.height * 0.9).rounded() - 32 - 52 - 66 - top)
        if let a = anchor(app, among: Self.anchors) {
            anchorID = a.id
            anchorY0 = a.y
        }
        print("LOGO window \(Int(window.width))x\(Int(window.height)) bar \(Int(top)) range \(Int(range)) anchor \(anchorID ?? "none") y0 \(Int(anchorY0))")

        // 往下滚：0 … 1 分 12 步；最后一步多滚一截（估的 range 差一点也不要紧），确定落定在条里
        for k in 0...12 {
            let target = k == 12 ? range + 48 : (range * CGFloat(k) / 12).rounded()
            if k > 0 { move(app, to: target) }
            usleep(600_000)
            let now = offset(app)
            print("LOGO frame \(k) target \(Int(target)) offset \(now.map { String(Int($0)) } ?? "?") p≈\(String(format: "%.2f", Double((now ?? assumed) / range)))")
            snap(String(format: "detail-logo-%02d", k))
        }
        report(app, "end")

        // 往回滚：原路倒回去，最后回到最上面（大字标重新拼好）
        let back: [CGFloat] = [0.75, 0.5, 0.25, 0]
        for (i, f) in back.enumerated() {
            move(app, to: (range * f).rounded(), toTop: f == 0)
            usleep(600_000)
            let now = offset(app)
            print("LOGO back \(i) offset \(now.map { String(Int($0)) } ?? "?")")
            snap("detail-logo-back-\(i)")
        }
        XCTAssertTrue(app.buttons["detail-play"].exists, "滚回最上面以后详情页不在了")
    }

    // MARK: 进详情

    /// 首页头图上此刻在屏上的那一页的「详情」（一次快照找，不逐个问元素）；没有就从首页那排电影卡进
    private func openMovieDetail(_ app: XCUIApplication) -> Bool {
        let play = app.buttons["detail-play"].firstMatch
        for _ in 0..<8 {
            if let f = app.onScreenFrames(["hero-detail"]).first {
                app.tap(at: CGPoint(x: f.midX, y: f.midY))
                if play.waitForExistence(timeout: 10) { return true }
            }
            sleep(2)
        }
        if app.revealAndTap(["movie-card"], swipes: 4) != nil, play.waitForExistence(timeout: 10) { return true }
        return false
    }

    // MARK: 滚动

    /// 系统栏压住的那一截（状态栏 + 导航栏，到导航栏的下沿：和 DetailScaffold 的 barBottom 一样是安全区的上边）；
    /// 量不到就按刘海屏的状态栏加一条导航栏算
    private func barBottom(_ app: XCUIApplication) -> CGFloat {
        guard let root = app.timedSnapshot() else { return 100 }
        var stack: [XCUIElementSnapshot] = [root]
        while let s = stack.popLast() {
            if s.elementType == .navigationBar, s.frame.height > 1, s.frame.maxY >= 40, s.frame.maxY <= 200 { return s.frame.maxY }
            stack.append(contentsOf: s.children)
        }
        return 100
    }

    /// 一次快照里找 ids 里的元素，按 ids 的先后给第一个找得到的（标识、上沿）
    private func anchor(_ app: XCUIApplication, among ids: [String]) -> (id: String, y: CGFloat)? {
        guard let root = app.timedSnapshot() else { return nil }
        var hits: [String: CGFloat] = [:]
        var stack: [XCUIElementSnapshot] = [root]
        while let s = stack.popLast() {
            let id = s.identifier
            if ids.contains(id), hits[id] == nil, s.frame.width > 1, s.frame.height > 1 { hits[id] = s.frame.minY }
            stack.append(contentsOf: s.children)
        }
        for id in ids {
            if let y = hits[id] { return (id, y) }
        }
        return nil
    }

    /// 页面滚了多少（正数：往下滚了）；量不到是 nil
    private func offset(_ app: XCUIApplication) -> CGFloat? {
        guard let anchorID, let a = anchor(app, among: [anchorID]) else { return nil }
        return anchorY0 - a.y
    }

    /// 滚到 target（离最上面多少点）：按量到的差慢慢拖，最多补两次。
    /// toTop：回到最上面那一步最多多拖 4 点——拖过头只是回弹；不往下甩（在最上面往下甩会把详情页拖回首页）
    private func move(_ app: XCUIApplication, to target: CGFloat, toTop: Bool = false) {
        for _ in 0..<3 {
            let now = offset(app) ?? assumed
            let need = target - now
            if abs(need) < 5 { return }
            let extra = toTop && need < 0 ? min(slop, 4) : slop
            let request = need + (need > 0 ? extra : -extra)
            drag(app, by: -request)
            guard let after = offset(app) else {
                assumed = now + need
                return
            }
            let moved = abs(after - now)
            if moved > 4 {
                // 这次被吃掉的那一截，和以前的估计平均一下
                slop = min(30, max(0, (slop + max(0, abs(request) - moved)) / 2))
            }
            assumed = after
        }
    }

    /// 慢慢拖 dy 点（负数往上拖 = 页面往下走），停住再松手：不留惯性，页面停在哪就是哪一帧。
    /// 往上拖从屏幕下半段起手，往下拖从中间偏上起手（让开钉在顶上的那条：点到它会一下回到最上面）
    private func drag(_ app: XCUIApplication, by dy: CGFloat) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.42, dy: dy < 0 ? 0.72 : 0.34))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: dy)),
                    withVelocity: .slow, thenHoldForDuration: 0.4)
        usleep(500_000)
    }

    // MARK: 记录

    /// 打进测试日志（工作流 grep「LOGO 」）：顶上那条里的小字标、播放钮在不在、在哪
    private func report(_ app: XCUIApplication, _ tag: String) {
        let ids = ["detail-pinned-logo", "detail-pinned-play"]
        guard let root = app.timedSnapshot() else { return }
        var found: [String] = []
        var stack: [XCUIElementSnapshot] = [root]
        while let s = stack.popLast() {
            if ids.contains(s.identifier) { found.append("\(s.identifier) \(s.frame)") }
            stack.append(contentsOf: s.children)
        }
        print("LOGO \(tag): \(found.isEmpty ? "no pinned logo / play" : found.joined(separator: ", "))")
    }

    private func snap(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}
