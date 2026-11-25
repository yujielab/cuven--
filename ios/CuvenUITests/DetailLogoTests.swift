import XCTest
import UIKit

/// 详情页字标的粒子转场（用户要求：往下滚，头部的大字标化成细粒子，沿一条往右鼓的弧线飞上去、在顶上那条的左上角拼回小字标；
/// 滚动停下就停在这一帧，往回滚原路拼回大字标）。演示数据（-CuvenDemo YES）：演示片的字标是本地画的彩色透明字标
/// （红字蓝边的主字标、上面一枚小厂牌、下面一行黄色副标题，DemoData.renderLogo），粒子的颜色和拼回来的先后在截图里看得出来。
/// 每次都进同一部（演示片 0「星际回声」，浅色字标）：CI 之间的截图对得上，也不会碰上深色字标被反成白、浅蓝、淡金的那几部。
/// 进度 0 到 1 要滚多远按 App 自己校准：一小步一小步往上拖到顶上那条的小字标出现（它 p < 1 时旁白藏着，树里没有），
/// 换了机型（iPad、Duo 侧边一列）也落在真的 k/12 上。detail-logo-00 是没滚的那一帧，01…12 慢拖、停住再松手（不留惯性：停在哪就是哪一帧），
/// 12 一定落定在条里（没落定算失败）；再一步步往回拖，截 detail-logo-back-0…3（3 回到最上面，大字标拼好）。
/// 滚了多少按简介卡（拿不到就是「播放」）在窗口里的上沿量，拖动被滚动视图吃掉的那一截每拖一次重新估
final class DetailLogoTests: XCTestCase {
    /// 量滚动用的锚点，按先后取第一个找得到的
    private static let anchors = ["about-synopsis", "detail-play"]
    /// 每次都进这一部（用户要的红蓝粒子夹几点黄）：演示片 0，首页头图的第一页（AppModel.resolveHeroes：演示数据按 heroes 的先后取前五部）。
    /// 深色字标的是 DemoData 里 i % 5 == 2 的那几部（头图第三页就是），管线会把它反白，截图里就没有红蓝黄了
    private static let film = "星际回声"
    /// 顶上那条里的小字标：p = 1（字标落定）才进旁白树（DetailLogoBarHost 的 accessibilityHidden(p < 1)）
    private static let dockedID = "detail-pinned-logo"

    private var anchorID: String?
    private var anchorY0: CGFloat = 0
    /// 拖的距离比页面实际滚的多出来的那一截（滚动视图先要认出这是拖动）
    private var slop: CGFloat = 8
    /// 量不到锚点时，按要求的距离记着页面大概滚到了哪；量得到时是最近一次量到的
    private var assumed: CGFloat = 0
    /// 最近一次快照里顶上那条的小字标在不在（在 = p 已经到 1）
    private var docked = false
    /// 窗口（一次拖多远按它的高封顶，拖不出屏幕）
    private var screen = CGRect(x: 0, y: 0, width: 390, height: 844)

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

        screen = app.windows.firstMatch.frame
        let top = barBottom(app)
        let rest = frames(app, Self.anchors)
        if let id = Self.anchors.first(where: { rest[$0] != nil }), let f = rest[id] {
            anchorID = id
            anchorY0 = f.minY
        }
        let guess = estimatedRange(play: rest["detail-play"], top: top)
        print("LOGO window \(Int(screen.width))x\(Int(screen.height)) bar \(Int(top)) guess \(Int(guess)) anchor \(anchorID ?? "none") y0 \(Int(anchorY0))")

        // 00：还没滚（p = 0，头部的真字标在原位）。在校准之前截，正好是静止的那一帧
        snap("detail-logo-00")

        // 校准：真的终点在 lo（最后一个没落定）和 hi（第一个落定）之间；量不到就退回估计值，照样截图好看出哪里不对
        let cal = calibrate(app, guess: guess)
        XCTAssertNotNil(cal, "一路往下拖，顶上那条的小字标（\(Self.dockedID)）一直没出来：字标没落进条里")
        let range = cal?.range ?? guess
        let dockAt = cal?.dockAt ?? guess + 48
        print("LOGO calibrated range \(Int(range)) dock \(Int(dockAt)) (guess \(Int(guess)))")

        // 往下滚：1 … 12 落在 k/12（0–20% 01–02、20–65% 03–07、65–90% 08–10、90–100% 11–12）；
        // 12 拖到第一个落定的位置再过一点，还没落定就再一小步一小步往上拖
        for k in 1...12 {
            let target = k == 12 ? dockAt + 6 : (range * CGFloat(k) / 12).rounded()
            move(app, to: target)
            if k == 12 { settleDocked(app) }
            usleep(600_000)
            print("LOGO frame \(k) target \(Int(target)) offset \(Int(assumed)) p≈\(String(format: "%.2f", Double(assumed / range))) docked \(docked)")
            snap(String(format: "detail-logo-%02d", k))
        }
        XCTAssertTrue(docked, "最后一帧（detail-logo-12）顶上那条里没有小字标：没滚到 p = 1")
        report(app, "end")

        // 往回滚：原路倒回去，最后回到最上面（大字标重新拼好）
        let steps: [CGFloat] = [0.75, 0.5, 0.25, 0]
        for (i, f) in steps.enumerated() {
            move(app, to: (range * f).rounded(), toTop: f == 0)
            usleep(600_000)
            print("LOGO back \(i) offset \(Int(assumed)) docked \(docked)")
            if i == 0 { XCTAssertFalse(docked, "往回滚到 p ≈ 0.75 以后顶上那条的小字标还在：没有倒回去") }
            snap("detail-logo-back-\(i)")
        }
        XCTAssertTrue(app.buttons["detail-play"].exists, "滚回最上面以后详情页不在了")
    }

    // MARK: 进详情

    /// 进演示片 0 的详情：从首页头图第一页的「详情」进。进去以后核对头部字标念的片名，不是它就退回来重来；
    /// 头图怎么都翻不到它（首页改了）才从首页那排电影卡进（进的是哪一部打进日志）
    private func openMovieDetail(_ app: XCUIApplication) -> Bool {
        let play = app.buttons["detail-play"].firstMatch
        // 冷启动的模拟器上首页头图要一会儿才出来：先等它，别把翻页的那几次机会耗在空首页上
        _ = app.buttons["hero-detail"].firstMatch.waitForExistence(timeout: 20)
        for attempt in 0..<3 {
            guard openFromHero(app) else { break }
            guard play.waitForExistence(timeout: 10) else { continue }
            // 字标格在画面定下来之前是空的：多看几眼再下结论
            var seen = (film: false, labels: "")
            for _ in 0..<3 {
                sleep(1)
                seen = detailHeading(app)
                if seen.film { return true }
            }
            print("LOGO opened \(seen.labels) instead of \(Self.film) (try \(attempt)), going back")
            back(app)
        }
        if app.revealAndTap(["movie-card"], swipes: 4) != nil, play.waitForExistence(timeout: 10) {
            sleep(1)
            print("LOGO fallback movie card: \(detailHeading(app).labels)")
            return true
        }
        return false
    }

    /// 首页头图翻到第一页（演示片 0）再点「详情」。头图没碰过时每 7 秒自己翻一页，快照又要一两秒，直接点会点到半路换上来的那一部：
    /// 先往右翻一下（真的左右拖过，它就不再自己翻：DSHeroCarousel 的 touched；在第一页只是回弹），往右翻一路翻回第一页，
    /// 在屏上的那一页是它了再点
    private func openFromHero(_ app: XCUIApplication) -> Bool {
        var turned = false
        for _ in 0..<10 {
            // 头图还没出来
            guard let page = heroPage(app) else { sleep(2); continue }
            if turned, Self.isFilm(page.title) {
                app.tap(at: CGPoint(x: page.detail.midX, y: page.detail.midY))
                return true
            }
            print("LOGO hero page \"\(page.title)\", flipping back")
            flipHero(app, detail: page.detail)
            turned = true
            sleep(2)
        }
        return false
    }

    /// 此刻在屏上的那一页头图：它的「详情」和它的标题（字标 + 一行信息合成的那个元素：「星际回声，电影 · 2026 · 科幻」，
    /// 在「详情」上面不远）。一次快照里找；左右两页的框在窗口外面，不算
    private func heroPage(_ app: XCUIApplication) -> (title: String, detail: CGRect)? {
        guard let root = app.timedSnapshot() else { return nil }
        var window = CGRect.null
        var details: [CGRect] = []
        var labels: [(text: String, frame: CGRect)] = []
        var stack: [XCUIElementSnapshot] = [root]
        while let s = stack.popLast() {
            if s.elementType == .window, window.isNull { window = s.frame }
            if s.identifier == "hero-detail" {
                details.append(s.frame)
            } else if !s.label.isEmpty, s.elementType != .button, s.frame.width > 1, s.frame.height > 1 {
                labels.append((s.label, s.frame))
            }
            stack.append(contentsOf: s.children)
        }
        if window.isNull { window = root.frame }
        guard let d = details.first(where: { $0.width > 1 && $0.height > 1 && window.contains(CGPoint(x: $0.midX, y: $0.midY)) }) else {
            return nil
        }
        let title = labels
            .filter { l in
                l.frame.maxY <= d.minY + 1 && l.frame.maxY > d.minY - 320
                    && window.contains(CGPoint(x: l.frame.midX, y: l.frame.midY))
            }
            .min { (d.minY - $0.frame.maxY) < (d.minY - $1.frame.maxY) }?.text ?? ""
        return (title, d)
    }

    /// 头图往右翻一页（手指往右拖 = 回上一页；在第一页只是回弹）：从「详情」上面那块画面起手（让开最上面「主页」那一行的头像），
    /// 拖过半屏多、快拖快放
    private func flipHero(_ app: XCUIApplication, detail d: CGRect) {
        let win = app.windows.firstMatch.frame
        let y = max(win.minY + 170, d.minY - 200)
        let x0 = max(d.minX + 8, win.minX + win.width * 0.25)
        let x1 = min(win.maxX - 8, x0 + win.width * 0.6)
        let origin = app.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: x0, dy: y))
            .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: x1, dy: y)), withVelocity: .fast, thenHoldForDuration: 0)
    }

    /// 详情页头部的标题：「播放」上面那一段里的元素（头部字标念的是片名；一行信息也在这里，打日志用）。p = 0 时顶上那条旁白藏着，不会混进来
    private func detailHeading(_ app: XCUIApplication) -> (film: Bool, labels: String) {
        guard let root = app.timedSnapshot() else { return (false, "no snapshot") }
        var play: CGRect?
        var labels: [(text: String, frame: CGRect)] = []
        var stack: [XCUIElementSnapshot] = [root]
        while let s = stack.popLast() {
            if s.identifier == "detail-play", play == nil, s.frame.width > 1, s.frame.height > 1 { play = s.frame }
            if !s.label.isEmpty, s.elementType != .button, s.frame.width > 1, s.frame.height > 1 { labels.append((s.label, s.frame)) }
            stack.append(contentsOf: s.children)
        }
        guard let play else { return (false, "no play button") }
        let near = labels.filter { $0.frame.maxY <= play.minY + 1 && $0.frame.maxY > play.minY - 320 }
        // 详情页头部字标念的就是片名本身（不带一行信息）：只认完全一样的，首页头图那一页（「片名，一行信息」）不会被当成进对了
        return (near.contains { $0.text == Self.film }, near.map { $0.text }.joined(separator: " | "))
    }

    /// 首页头图那一页的标题是不是演示片 0（「片名，一行信息」；一行信息是空的时候只有片名）
    private static func isFilm(_ label: String) -> Bool {
        label == film || label.hasPrefix(film + "，")
    }

    /// 系统返回钮（标识 BackButton；Duo 上竖在侧边时不在 navigationBars 里），都没有就从左边缘往右拖
    private func back(_ app: XCUIApplication) {
        let sys = app.buttons["BackButton"].firstMatch
        let nav = sys.exists ? sys : app.navigationBars.buttons.firstMatch
        if nav.exists, nav.isOnScreen(in: app) {
            nav.tapCenter()
        } else {
            let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
            edge.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)))
        }
        sleep(2)
    }

    // MARK: 进度

    /// 估一个起点（只决定校准从哪开始拖，真的终点靠校准）：和 DetailScaffold 的 pinAt 同一个算法——
    /// 「播放」那一行的上沿滚到顶上那条（系统栏下面 66 点）底下。量得到「播放」就按它没滚时的上沿算（头部高、字块离底都在里面了）；
    /// 量不到按头部高（iPhone 九成屏高；iPad 竖拿 0.66、横拿 0.78）减去字块离底和按钮
    private func estimatedRange(play: CGRect?, top: CGFloat) -> CGFloat {
        if let play { return max(200, (play.minY - top - 66).rounded()) }
        let pad = UIDevice.current.userInterfaceIdiom == .pad
        let tall = screen.height > screen.width
        let heroH = max(420, (screen.height * (pad ? (tall ? 0.66 : 0.78) : (tall ? 0.9 : 0.92))).rounded())
        return max(200, heroH - 32 - 52 - 66 - top)
    }

    /// 校准（用户要的进度 0…1 要落在真的 0…1 上）：先拖到估计的七成五，再 24 点一步往上拖，直到快照里出现顶上那条的小字标；
    /// 再退回去半步看一眼，把终点夹在 12 点以内。range 是夹住的那一段的中间（01…11 按它分），dockAt 是第一个落定的位置（12 拖到它）
    private func calibrate(_ app: XCUIApplication, guess: CGFloat) -> (range: CGFloat, dockAt: CGFloat)? {
        move(app, to: (guess * 0.75).rounded())
        // 估大了：起点就已经落定，往回退到没落定
        var retreats = 0
        while docked && retreats < 10 {
            move(app, to: max(12, assumed - 48))
            retreats += 1
        }
        guard !docked else { return nil }
        var lo = assumed
        var hi: CGFloat?
        for _ in 0..<30 {
            move(app, to: assumed + 24)
            if docked {
                hi = assumed
                break
            }
            // 这一步没拖动（拖动被吃掉）就不更新 lo，下一步照样往上
            lo = max(lo, assumed)
        }
        guard var dockAt = hi else { return nil }
        // 夹得太宽（一步多走了），退回中间看一眼
        if dockAt - lo > 14 {
            move(app, to: ((lo + dockAt) / 2).rounded())
            if docked { dockAt = min(dockAt, assumed) } else { lo = max(lo, assumed) }
            print("LOGO calibrate refine lo \(Int(lo)) hi \(Int(dockAt))")
        }
        return (((lo + dockAt) / 2).rounded(), dockAt)
    }

    /// 最后一帧要真落定（顶上那条里有小字标）：差一点就再往上拖一小步（12 点，最多 15 次）
    private func settleDocked(_ app: XCUIApplication) {
        var n = 0
        while !docked && n < 15 {
            move(app, to: assumed + 12)
            n += 1
        }
        if n > 0 { print("LOGO frame 12 needed \(n) extra step(s), docked \(docked) at \(Int(assumed))") }
    }

    // MARK: 滚动

    /// 系统栏压住的那一截（状态栏 + 导航栏，到导航栏的下沿：和 DetailScaffold 的 barBottom 一样是安全区的上边）；
    /// 量不到就按刘海屏的状态栏加一条导航栏算（只用来估校准的起点）
    private func barBottom(_ app: XCUIApplication) -> CGFloat {
        guard let root = app.timedSnapshot() else { return 100 }
        var stack: [XCUIElementSnapshot] = [root]
        while let s = stack.popLast() {
            if s.elementType == .navigationBar, s.frame.height > 1, s.frame.maxY >= 40, s.frame.maxY <= 200 { return s.frame.maxY }
            stack.append(contentsOf: s.children)
        }
        return 100
    }

    /// 一次快照里 ids 里每个元素的框（同一个标识取第一个有大小的）
    private func frames(_ app: XCUIApplication, _ ids: [String]) -> [String: CGRect] {
        guard let root = app.timedSnapshot() else { return [:] }
        var hits: [String: CGRect] = [:]
        var stack: [XCUIElementSnapshot] = [root]
        while let s = stack.popLast() {
            let id = s.identifier
            if ids.contains(id), hits[id] == nil, s.frame.width > 1, s.frame.height > 1 { hits[id] = s.frame }
            stack.append(contentsOf: s.children)
        }
        return hits
    }

    /// 一次快照：页面滚了多少（正数：往下滚了；量不到锚点是 nil），顺带记下顶上那条的小字标在不在（docked）
    private func offset(_ app: XCUIApplication) -> CGFloat? {
        var ids = [Self.dockedID]
        if let anchorID { ids.append(anchorID) }
        let f = frames(app, ids)
        docked = f[Self.dockedID] != nil
        guard let anchorID, let y = f[anchorID]?.minY else { return nil }
        return anchorY0 - y
    }

    /// 滚到 target（离最上面多少点）：按量到的差慢慢拖，一次最多拖小半屏（拖不出屏幕），最多补几次。
    /// 结束时 assumed 是最后量到的位置、docked 是最后一张快照里的（都在最后一次拖完以后）。
    /// toTop：回到最上面那一步多拖 3 点——拖过头只是回弹到 0（正好是静止的那一帧）；不往下甩（在最上面往下甩会把详情页拖回首页）
    private func move(_ app: XCUIApplication, to target: CGFloat, toTop: Bool = false) {
        var now = offset(app) ?? assumed
        let cap = max(120, screen.height * 0.45)
        for _ in 0..<5 {
            let need = target - now
            let close = toTop ? now <= 0.5 : abs(need) < 5
            if close { return }
            let step = max(-cap, min(cap, need))
            let extra = toTop && step < 0 && step > -cap ? slop + 3 : slop
            let request = step + (step > 0 ? extra : -extra)
            drag(app, by: -request)
            guard let after = offset(app) else {
                assumed = now + step
                now = assumed
                continue
            }
            let moved = abs(after - now)
            if moved > 4 {
                // 这次被吃掉的那一截，和以前的估计平均一下
                slop = min(30, max(0, (slop + max(0, abs(request) - moved)) / 2))
            }
            assumed = after
            now = after
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
        let ids = [Self.dockedID, "detail-pinned-play"]
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
