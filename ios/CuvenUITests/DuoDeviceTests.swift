import XCTest

/// 在「iPhone Duo」模拟器（iOS 27.1+ 运行时）上跑，演示数据（-CuvenDemo YES：片名、海报、字标都是本地合成的，不用登录）。
/// 不强制任何形态：看系统把标签栏 / 工具栏 / 返回钮放在哪，内容铺到哪。截图以 duo- 开头，会公开到 refs/ci/ios-preview-demo，
/// 所以这里只截演示数据和登录页（登录页盖住整个屏幕，后面的片库露不出来）。
final class DuoDeviceTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    private func launch(demo: Bool = true, welcome: Bool = false, privacy: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        if demo { app.launchArguments += ["-CuvenDemo", "YES"] }
        if welcome { app.launchArguments += ["-CuvenWelcome", "YES"] }
        if privacy { app.launchArguments += ["-CuvenPrivacy", "YES"] }
        app.launch()
        return app
    }

    /// 隐私同意闸门（网页版 #pgSheet）：登录后没同意过就盖上。演示数据默认不出，这里用 -CuvenPrivacy YES 强制。
    /// 弹层本身只有文案与合成内容；勾满三项，「同意并继续」以后应当到主页（通知权限挪到账户页的开关里）
    func testPrivacyGate() {
        XCUIDevice.shared.orientation = .portrait
        let app = launch(privacy: true)
        let agree = app.buttons["pg-agree"].firstMatch
        XCTAssertTrue(agree.waitForExistence(timeout: 15), "隐私同意闸门没出现")
        sleep(2)                                   // 弹层推上来、标题与要点依次升上来
        report(app, "privacy")
        snap("duo-00c-privacy")
        XCTAssertFalse(agree.isEnabled, "三项都没勾，「同意并继续」不该能点")

        // 展开完整说明，再往下滚到「您的选择」
        let disclose = app.buttons["pg-disclose"].firstMatch
        if disclose.waitForExistence(timeout: 3) { disclose.tap(); sleep(1) }
        app.swipeUp(); sleep(1)
        snap("duo-00d-privacy-2")
        for id in ["pg-privacy", "pg-cross", "pg-age"] {
            if let row = reveal(app, id, swipes: 6) { row.tap(); usleep(300_000) } else { print("DUO privacy: \(id) not found") }
        }
        snap("duo-00e-privacy-done")
        if agree.isEnabled {
            agree.tap()
            sleep(2)
            XCTAssertFalse(app.buttons["pg-agree"].exists, "点了「同意并继续」闸门还在")
            XCTAssertTrue(navButton(app, "主页").waitForExistence(timeout: 10), "同意以后没到主页")
        } else {
            print("DUO privacy: agree still disabled (hint: \(app.staticTexts["pg-hint"].firstMatch.label))")
        }
    }

    /// 欢迎页（网页版 #wc-root）：已登录时打开 App 先盖这一屏。演示数据默认不出，这里用 -CuvenWelcome YES 强制。
    /// 只截欢迎页本身（演示账户名、没有头像时的剪影），点「确认并继续」以后不截（后面是片库）
    func testWelcome() {
        XCUIDevice.shared.orientation = .portrait
        let app = launch(welcome: true)
        let cta = app.buttons["welcome-continue"].firstMatch
        XCTAssertTrue(cta.waitForExistence(timeout: 15), "欢迎页没出现")
        sleep(3)                                   // 问候语两行依次模糊淡入（0.2 / 0.55 秒起，各 1 秒）
        report(app, "welcome")
        snap("duo-00-welcome")
        cta.tap()
        sleep(2)
        XCTAssertFalse(app.buttons["welcome-continue"].exists, "点了「确认并继续」欢迎页还在")
        XCTAssertTrue(navButton(app, "主页").waitForExistence(timeout: 10), "欢迎页之后没到主页")
    }

    func testPortrait() {
        XCUIDevice.shared.orientation = .portrait
        let app = launch()
        sleep(4)
        report(app, "home")
        snap("duo-01-home")
        // 下拉刷新：在最上面拉一下、松手，转圈要自己收起、整页回到原位。以前刷新瞬间做完（演示数据）时转圈卡住不走、
        // 整页被顶下去一截，之后 XCUITest 每一步都要等两分钟 App 空闲（整个测试跑了 43 分钟）
        let avatarBefore = app.onScreenFrames(skipBars: false) { $0.identifier == "home-account" }.first
        app.swipeDown(); sleep(4)
        let avatarAfter = app.onScreenFrames(skipBars: false) { $0.identifier == "home-account" }.first
        snap("duo-01b-home-refreshed")
        if let b = avatarBefore, let a = avatarAfter {
            print("DUO refresh: avatar y \(Int(b.minY)) -> \(Int(a.minY))")
            if abs(a.minY - b.minY) >= 20 {
                XCTFail("下拉刷新以后整页没回原位（转圈卡住了）")
                // 卡住了就重开 App，别让后面每一步都等两分钟
                app.terminate(); app.launch(); sleep(4)
            }
        } else {
            print("DUO refresh: avatar not found")
        }
        app.swipeUp(); sleep(2); snap("duo-02-home-rows")
        // 年份卡（今年那一排）：只放剧照（用户要求，不放预告片）；点一下进详情（从卡上放大出来）
        if let card = reveal(app, "movie-card", swipes: 2) {
            sleep(1)
            snap("duo-02i-year-card")
            card.tap()
            if app.buttons["detail-play"].waitForExistence(timeout: 8) { back(app) } else { XCTFail("点年份卡没进详情页") }
            sleep(1)
        } else {
            print("DUO year card: none")
        }
        // 精选电影 / 精选剧集：今年 / 去年下面，照游戏 App 合集页的一整块（立体海报 + 大标题 + 一排带底栏的大卡）
        if reveal(app, "featured-card", swipes: 5) != nil {
            sleep(2)
            snap("duo-02c-home-featured")
        } else {
            print("DUO featured card: none")
        }
        // 编辑推荐（照游戏 App「重磅更新」）：预告片铺满做底、「编辑推荐」、底部取色面板（海报、字标、一行简介、「查看」胶囊）
        if reveal(app, "editors-pick", swipes: 4) != nil {
            sleep(2)
            snap("duo-02h-editors-pick")
        } else {
            print("DUO editors pick: none")
        }
        if reveal(app, "featured-series-card", swipes: 4) != nil {
            sleep(2)
            snap("duo-02e-home-featured-tv")
            // 合集页（照游戏 App 的合集页）：那一排的标题「一集接一集停不下来 ›」点进去
            let heading = app.buttons["section-一集接一集停不下来"].firstMatch
            if heading.isOnScreen(in: app) {
                heading.tap(); sleep(3)
                snap("duo-02f-collection")
                app.swipeUp(); sleep(2)
                snap("duo-02g-collection-cards")
                back(app)
            } else {
                print("DUO collection heading: not on screen")
            }
        } else {
            print("DUO featured series card: none")
        }
        // 回到顶上：看到「Home」那一行的头像就停（多拉一下会触发下拉刷新）
        app.scrollHomeToTop(maxSwipes: 12)

        // 详情：头图上此刻在屏上的那一页的「详情」（详情页从头图上放大出来）；返回是系统的返回钮（折起时在侧边那一列最上面）
        // 一次快照找在屏上的那一个，点它正中（逐个问 5 页头图的「详情」在主页上会「Timed out while evaluating UI query」）
        if let target = reveal(app, "hero-detail", swipes: 0) ?? reveal(app, "movie-card", swipes: 4) { target.tap() }
        XCTAssertTrue(app.buttons["detail-play"].waitForExistence(timeout: 8), "没进到电影详情")
        sleep(2)
        report(app, "detail")
        snap("duo-03-detail")
        // 「…」：播放钮旁边的系统菜单（从头播放 / 复制直链 / 分享）；点菜单外面收起
        let more = app.buttons["detail-more"].firstMatch
        if more.waitForExistence(timeout: 3) {
            more.tap(); sleep(2)
            snap("duo-03b-detail-more")
            XCTAssertTrue(app.buttons["detail-copy"].firstMatch.exists, "「…」菜单里没有「复制直链」")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.06)).tap()
            sleep(1)
        } else {
            XCTFail("详情页没有「…」菜单")
        }
        // 简介：一排卡（简介、评分、影片规格）；点简介卡弹出从卡上放大出来的系统弹层，右上关闭
        // 先挪到屏幕中间再点：以前卡的正中压在钉在顶上的标题条底下，点下去是「回到顶上」，弹层没出来，
        // 后面「关闭」找不到就往下甩，在页面最上面这一甩把详情页拖回了主页——后面的预告片、演员全找不到
        if let about = app.bringIntoBand(where: { $0.identifier == "about-synopsis" }) {
            sleep(1)
            snap("duo-03d-about")
            about.tap(); sleep(2)
            snap("duo-03e-about-sheet")
            let close = app.buttons["about-close"].firstMatch
            if close.waitForExistence(timeout: 4) { close.tap() } else { print("DUO about sheet: did not open") }
            sleep(1)
        } else {
            print("DUO about card: none")
        }
        // 预告片与剧照：同一横排，先预告片、再剧照（16:9 卡，字压在底部的渐进式模糊上，右下一颗「•••」）；点剧照全屏看大图。
        // 剧照在这一排右边、屏幕外：横着往左滑出来。以前往上滑着找剧照，把「演员 ›」滑过了头，测试报「详情页没有『演员 ›』」
        if let media = app.bringIntoBand(where: { $0.identifier == "trailer-card" || $0.identifier == "still-card" }) {
            sleep(2)
            snap("duo-03c-detail-trailers")
            var still = reveal(app, "still-card", swipes: 0)
            for _ in 0..<4 where still == nil {
                media.press(forDuration: 0.05, thenDragTo: media.withOffset(CGVector(dx: -240, dy: 0)))
                sleep(1)
                still = reveal(app, "still-card", swipes: 0)
            }
            if let still {
                sleep(1)
                snap("duo-03f-detail-stills")
                still.tap(); sleep(2)
                snap("duo-03g-stills-viewer")
                let close = app.buttons["stills-close"].firstMatch
                if close.waitForExistence(timeout: 4) { close.tap() } else { print("DUO stills viewer: no close button") }
                sleep(2)
            } else {
                print("DUO still card: none")
            }
        } else {
            print("DUO trailer / still card: none")
        }
        // 演员 ›：一张半屏 / 全屏的系统弹层，一行一位；点一行，弹层收起、推进那位演员的个人页（照 Apple Music 艺人页）：
        // 大照片 + 名字 + ⓘ ▶ 🔍、最新一部、库中作品；ⓘ 是简介弹层（来自、出生、类型、关于）
        // 一次快照找到它在哪、差多少拖多少（不往下甩：在详情页最上面往下甩会把整页拖回主页）
        if let castLink = app.bringIntoBand(where: { $0.identifier == "cast-link" }) {
            castLink.tap(); sleep(2)
            snap("duo-04b-cast")
            let row = app.buttons["cast-row"].firstMatch
            if row.waitForExistence(timeout: 3) {
                row.tap(); sleep(3)
                snap("duo-04e-actor")
                // 侧边一列的形态里系统标签栏一直藏着：以前演员页没挂 duoHidesTabBar，一进来系统标签栏就回来了，
                // 回到详情页也不再藏，和侧边导航叠成两份（用户截图）
                report(app, "actor")
                XCTAssertFalse(app.tabBars.firstMatch.exists, "演员页上系统标签栏又出来了（和侧边导航叠成两份）")
                app.swipeUp(); sleep(2)
                snap("duo-04f-actor-works")
                // ⓘ：一次快照找在屏上的那颗（演员页上逐个问元素、问 isHittable 会「Timed out while evaluating UI query」）
                var info = reveal(app, "actor-info", swipes: 0)
                if info == nil { app.swipeDown(); sleep(1); info = reveal(app, "actor-info", swipes: 0) }
                if let info {
                    info.tap(); sleep(2)
                    snap("duo-04g-actor-bio")
                    let close = app.buttons["actor-bio-close"].firstMatch
                    if close.waitForExistence(timeout: 3) { close.tap() } else { app.swipeDown() }
                    sleep(1)
                } else {
                    print("DUO actor info: not on screen")
                }
                back(app)
                report(app, "detail-after-actor")
                XCTAssertFalse(app.tabBars.firstMatch.exists, "从演员页回到详情页，系统标签栏又出来了（和侧边导航叠成两份）")
            } else {
                print("DUO cast sheet: no rows")
                closeSheet(app)
            }
        } else {
            XCTFail("详情页没有「演员 ›」")
        }
        app.swipeUp(); sleep(2); snap("duo-04-detail-info")
        app.swipeUp(); sleep(2); snap("duo-04c-detail-tech")
        back(app)
        // 探索片段合集（今年那一排下面一排 9:16 竖卡）：点开是刷视频式的影片浏览，上下滑换一部
        app.scrollHomeToTop(maxSwipes: 12)
        if let clip = reveal(app, swipes: 6, where: { $0.identifier.hasPrefix("clip-collection-") }) {
            sleep(2)
            snap("duo-08j-clip-collections")
            // 侧边那一列的中线：主页侧边导航（和系统的时间、信号、返回钮同一条线）
            let railX = app.onScreenFrames(skipBars: false) { $0.identifier.hasPrefix("nav-") }.first?.midX
            clip.tap(); sleep(4)
            snap("duo-08k-clip-feed")
            // 刷视频页的关闭钮要对着同一条线（用户截图：以前偏外约 6 点，没和状态栏对齐）
            let closeX = app.onScreenFrames(skipBars: false) { $0.identifier == "clip-feed-close" }.first?.midX
            print("DUO clip feed rail: nav \(railX.map { "\($0)" } ?? "none") close \(closeX.map { "\($0)" } ?? "none")")
            if let railX, let closeX {
                XCTAssertEqual(closeX, railX, accuracy: 2, "刷视频页的关闭钮没对着侧边那一列的中线")
            }
            app.swipeUp(); sleep(4)
            snap("duo-08l-clip-feed-2")
            if let close = reveal(app, "clip-feed-close", swipes: 0) { close.tap() } else { app.swipeDown() }
            sleep(2)
        } else {
            print("DUO clip collections: none")
        }
        app.scrollHomeToTop(maxSwipes: 12)
        // 主页往下：继续观看（有才有）、今年、去年（电影和剧集的海报）、四个大类——卡上只有画面，分区之间只靠留白
        app.swipeUp(); sleep(2); snap("duo-08-home-rows")
        app.swipeUp(); sleep(2); snap("duo-08b-home-tv")
        app.swipeUp(); sleep(2); snap("duo-08c-home-year")
        app.swipeUp(); sleep(2); snap("duo-08d-home-year-2")
        // 四个大类（动画片区、动作片区、喜剧片区、严苛品质区）在精选和编辑推荐下面
        app.swipeUp(); sleep(2); snap("duo-08e-home-categories")
        // 主页结尾（照游戏 App「Arcade」页的结尾）：两行慢慢走的海报墙、Cuven 字标、「查看所有影片」→ 全部影片
        if let all = reveal(app, "home-show-all", swipes: 12) {
            sleep(2)
            snap("duo-08h-home-finale")
            all.tap(); sleep(2)
            snap("duo-08i-all")
            back(app)
        } else {
            print("DUO home finale: none")
        }
        // 回到顶上：看到「Home」那一行的头像就停（多拉一下会触发下拉刷新）
        app.scrollHomeToTop(maxSwipes: 30)

        // 「文件夹」一排在搜索页（没输入时）：点进文件夹页（大标题、子文件夹一排、海报网格）
        tab(app, "搜索"); sleep(2)
        if let folder = reveal(app, "folder-card", swipes: 2) {
            snap("duo-08e-search-folders")
            folder.tap(); sleep(2)
            snap("duo-08f-folder")
            app.swipeUp(); sleep(1)
            snap("duo-08g-folder-2")
            back(app)
        } else {
            print("DUO folder card: not found")
        }
        tab(app, "主页"); sleep(1)

        // 资料库：展映（网页版同一套）——一部有预告片的电影一章：满屏画幅（一行信息 + 字标）→ 收成 16:9，
        // 下面的介绍面板：简介、评分、导演与主演、播放 / 影片详情、一排剧照，章与章之间一道细线（底下不留一大块黑）
        tab(app, "资料库"); sleep(3)
        report(app, "library")
        snap("duo-05-library")
        app.swipeUp(); sleep(2); snap("duo-05f-library-shrink")
        app.swipeUp(); sleep(2); snap("duo-05g-library-intro")
        app.swipeUp(); sleep(2); snap("duo-05i-library-next")
        app.swipeDown(); sleep(1); app.swipeDown(); sleep(2)
        if let d = reveal(app, "library-movie", swipes: 2) {
            d.tap(); sleep(2)
            XCTAssertTrue(app.buttons["detail-play"].waitForExistence(timeout: 8), "资料库「详情」没进到详情页")
            snap("duo-05h-library-detail")
            back(app)
        } else {
            XCTFail("资料库没有「详情」")
        }

        // 剧集详情：主页上第一张在屏上的剧集卡（今年 / 去年那两排、四个大类里的剧集，或者精选剧集的大卡；资料库只放电影）。
        // 一次快照看全部匹配项：年份那两排一屏只露一张多，第一张剧集卡常在屏幕右边外面，只看它的话怎么往上滑都找不到
        tab(app, "主页"); sleep(2)
        app.scrollHomeToTop(maxSwipes: 30)
        if app.revealAndTap(["series-card", "featured-series-card"], swipes: 8) != nil {
            if !app.buttons["series-play"].waitForExistence(timeout: 8) { print("DUO series detail: no series-play") }
            sleep(2)
            snap("duo-05b-series")
            app.swipeUp(); sleep(2)
            snap("duo-05c-series-episodes")
            // 长按分集卡：系统菜单，预览里是这一集的剧照、集名和整段简介；点菜单外面收起
            if let ep = reveal(app, "episode-card", swipes: 1) {
                ep.press(forDuration: 1.2); sleep(2)
                snap("duo-05f-episode-more")
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.06)).tap(); sleep(1)
            } else {
                print("DUO episode card: none")
            }
            // 季切换：「剧集」标题右边「第 1 季 ⌃⌄」点开是季的菜单，选第 2 季
            if let seasonMenu = reveal(app, "season-menu", swipes: 1) {
                seasonMenu.tap(); sleep(1)
                snap("duo-05d-season-menu")
                let s2 = app.buttons["第 2 季"].firstMatch
                if s2.waitForExistence(timeout: 3) {
                    s2.tap(); sleep(2)
                    snap("duo-05e-season-2")
                } else {
                    print("DUO season menu: item not exposed")
                    app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.1)).tap(); sleep(1)
                }
            }
            back(app)
        } else {
            XCTFail("主页上找不到剧集卡")
        }
        app.scrollHomeToTop(maxSwipes: 12)

        // 年份页：主页分区标题「2026 ›」进去——系统列表，一行一部（小海报、片名、一行灰字、›）；长按一行是系统菜单（播放 / 想看）
        tab(app, "主页"); sleep(2)
        if let title = reveal(app, swipes: 8, where: { $0.identifier.range(of: "^section-[0-9]{4}$", options: .regularExpression) != nil }) {
            title.tap(); sleep(2)
            snap("duo-09-year")
            let row = app.buttons.matching(NSPredicate(format: "identifier IN {'year-movie', 'year-series'}")).firstMatch
            if row.waitForExistence(timeout: 3) {
                row.press(forDuration: 1.2); sleep(2)
                snap("duo-09b-year-menu")
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.06)).tap(); sleep(1)
            } else {
                print("DUO year page: no rows")
            }
            back(app)
        } else {
            XCTFail("主页没有年份分区")
        }
        app.scrollHomeToTop(maxSwipes: 12)

        // 账户与设置：主页标题那一行右边的头像（从侧边导航里分出来了）
        snap("duo-02d-home-avatar")
        let avatar = app.buttons["home-account"].firstMatch
        if avatar.waitForExistence(timeout: 5) {
            avatar.tap(); sleep(2)
            snap("duo-06-account")
            // 网络速度：滑块下面「自动调整」那一行（演示数据不测速，只按网络类型估）；开一下看结果，再关回去（停在现在的数上）
            if let auto = reveal(app, "account-network-auto", swipes: 4) {
                sleep(1)
                snap("duo-06b-account-network")
                auto.tap(); sleep(3)
                snap("duo-06c-account-network-auto")
                auto.tap(); sleep(1)
            } else {
                print("DUO network auto: none")
            }
            // 首选音轨：系统弹出菜单（自动 / 自然 / 国语 / 粤语 / 英语 / 日语 / 韩语）；点菜单外面收起
            if let audio = reveal(app, swipes: 3, where: { $0.elementType == .button && $0.label == "首选音轨" }) {
                audio.tap(); sleep(2)
                snap("duo-06d-audio-menu")
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.06)).tap(); sleep(1)
            } else {
                print("DUO audio menu: none")
            }
            // 在线字幕服务的状态：「首选字幕」下面那一行（演示数据：合成的「正常 · 今天还能下载 96 / 100 条」）
            if app.bringIntoBand(where: { $0.identifier == "account-subs-status" }) != nil {
                sleep(1)
                snap("duo-06e-subs-status")
            } else {
                print("DUO subs status: none")
            }
            let done = app.buttons["account-done"].firstMatch
            if done.waitForExistence(timeout: 3) { done.tap() } else { app.swipeDown() }
            sleep(1)
        } else {
            XCTFail("主页右上没有头像")
        }

        tab(app, "搜索"); sleep(2)
        snap("duo-07a-search-home")          // 最近添加：海报网格
        app.swipeDown(); sleep(1)
        let field = app.searchFields.firstMatch
        if field.waitForExistence(timeout: 5) {
            field.tap()
            field.typeText("夜")
            sleep(2)
        }
        snap("duo-07-search")

        // 先收起键盘、退出搜索：键盘盖住了侧边那一列底下的标签栏
        app.swipeDown(); sleep(1)
        for label in ["关闭", "Close", "取消", "Cancel"] {
            let b = app.buttons[label].firstMatch
            if b.exists && b.isHittable { b.tap(); sleep(1); break }
        }

        // 长按海报：菜单（播放 / 想看），预览是那张卡（放在最后：菜单没收起也不影响别的步骤）
        tab(app, "主页"); sleep(2)
        if let poster = reveal(app, "featured-card") {
            poster.press(forDuration: 1.2); sleep(2)
            snap("duo-10-menu")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.06)).tap(); sleep(1)
        }
    }

    func testLandscape() {
        // 先竖着启动、再转横：冷启动时直接横着启动，模拟器上偶尔起不来
        XCUIDevice.shared.orientation = .portrait
        let app = launch()
        sleep(4)
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(3)
        if !rotated(app) { XCUIDevice.shared.orientation = .landscapeRight; sleep(3) }
        report(app, "landscape")
        // 折起时外屏在模拟器里可能不跟着转：没转就不截（免得把竖屏图标成横屏）
        guard rotated(app) else {
            print("DUO landscape: did not rotate (window and screenshot stay portrait)")
            XCUIDevice.shared.orientation = .portrait
            return
        }
        snap("duo-11-landscape-home")
        tab(app, "资料库"); sleep(3)
        snap("duo-12-landscape-library")
        XCUIDevice.shared.orientation = .portrait
    }

    /// 没登录：整屏登录页（只在确认登录页出现时才截图，免得截到后面的真实片库）
    func testLoginScreen() {
        XCUIDevice.shared.orientation = .portrait
        let app = launch(demo: false)
        let subtitle = app.staticTexts["使用你的 Cuven 账户登录 Cuven max。"]
        XCTAssertTrue(subtitle.waitForExistence(timeout: 20), "没登录时应当先出现登录页")
        // 截图前再确认一次登录页还盖着（登录页不透明，后面的片库露不出来）
        if subtitle.exists && app.textFields.count > 0 {
            sleep(2)
            if subtitle.exists { snap("duo-21-login") }
        }

        // 连得上账户服务、读得懂它的回答：输一个不存在的用户名（只读查询，不写任何东西），应当提示「新用户」
        let cont = app.buttons["Continue"].firstMatch          // 模拟器第一次弹键盘时的「滑动输入」提示
        if cont.exists { cont.tap(); sleep(1) }
        let field = app.textFields["login-user"].exists ? app.textFields["login-user"] : app.textFields.firstMatch
        if field.exists {
            field.tap()
            field.typeText("cuvenciprobe\(Int(Date().timeIntervalSince1970) % 100000)")
            let newUser = app.staticTexts["新用户 — 将建立您的账户"]
            XCTAssertTrue(newUser.waitForExistence(timeout: 20), "账户服务查不到或读不懂（应当提示新用户）")
            if subtitle.exists { snap("duo-22-login-lookup") }
        }
    }

    private func rotated(_ app: XCUIApplication) -> Bool {
        let w = app.windows.firstMatch.frame.size
        let shot = XCUIScreen.main.screenshot().image.size
        return w.width > w.height || shot.width > shot.height
    }

    /// 关掉弹层：点右上角系统的 xmark（标识 sheet-cancel），找不到就往下滑
    private func closeSheet(_ app: XCUIApplication) {
        if let cancel = reveal(app, "sheet-cancel", swipes: 0) { cancel.tap() } else { app.swipeDown() }
        sleep(1)
    }

    /// 导航里的一格：按名字（label）找。折起时是 App 自己画在侧边那一列的导航（DuoNav，标识是 nav-*），
    /// 展开竖拿时是系统标签栏；两种都按 label 认，取第一个点得到的（收起的系统标签栏若还在层级里，点不到，跳过）
    private func navButton(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@", name)).firstMatch
    }

    private func tab(_ app: XCUIApplication, _ name: String) {
        // 一次快照找在屏上的那一格（收起的系统标签栏还留在层级里，只是点不到）；找不到再按 label 点第一个
        if app.tapTab(named: name) { return }
        let q = app.buttons.matching(NSPredicate(format: "label == %@", name))
        guard q.firstMatch.waitForExistence(timeout: 5) else { return }
        q.firstMatch.tap()
    }

    /// 系统返回钮：竖在侧边时不在 navigationBars 里，按它的标识找
    private func back(_ app: XCUIApplication) {
        let sys = app.buttons["BackButton"].firstMatch
        let nav = sys.exists ? sys : app.navigationBars.buttons.firstMatch
        print("DUO back \(nav.exists ? "\(nav.frame)" : "none")")
        if nav.exists { nav.tap() } else { app.swipeRight() }
        sleep(2)
    }

    /// 打进测试日志（工作流 grep「DUO 」）：窗口多大、系统标签栏在哪
    private func report(_ app: XCUIApplication, _ tag: String) {
        let w = app.windows.firstMatch.frame
        let bar = app.tabBars.firstMatch
        let barInfo = bar.exists ? "tabBar \(bar.frame)" : "tabBar none"
        let shot = XCUIScreen.main.screenshot().image.size
        print("DUO \(tag) window \(Int(w.width))x\(Int(w.height)) screenshot \(Int(shot.width))x\(Int(shot.height)) \(barInfo)")
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    /// 每张截图带上时刻（UTC）打进日志：和 App 诊断日志（启动时刻 + 秒数）对得上，慢在哪一步一看就知道
    private func snap(_ name: String) {
        print("DUO snap \(name) \(Self.clock.string(from: Date()))")
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    /// 往上滑，直到 match 选中的元素有一个在屏上（懒加载的排要滑到才会生成），给出它正中的点（点按、长按都用它）。
    /// 一次快照看全部匹配项、不问 isHittable：逐个问元素每次都要重拍整棵树，主页上会「Timed out while evaluating UI query」，
    /// 只看第一个又会漏掉一排里在屏幕右边外面的那张
    private func reveal(_ app: XCUIApplication, swipes: Int = 6, where match: (XCUIElementSnapshot) -> Bool) -> XCUICoordinate? {
        for i in 0...swipes {
            if let f = app.onScreenFrames(where: match).first {
                return app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: f.midX, dy: f.midY))
            }
            if i < swipes { app.swipeUp(); sleep(1) }
        }
        return nil
    }

    private func reveal(_ app: XCUIApplication, _ id: String, swipes: Int = 6) -> XCUICoordinate? {
        reveal(app, swipes: swipes) { $0.identifier == id }
    }
}
