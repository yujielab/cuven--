import SwiftUI
import UIKit

// MARK: - 主页（按 Apple HIG 重做；规则编号见 docs/ios-design.md 与 docs/hig/*.md）
//
// 和 Apple TV 的主页一样只有两样东西：最上面一张铺满的轮播头图（S15–S17），下面一排排海报（T23、S8）。
// 头图几乎占满一屏，连同 iPhone Duo 侧边那一列一起平铺（画面在系统栏底下过去，不做镜像模糊：F6、S19），
// 左上一行白色大字「Home」、右上一枚头像（点开账户与设置），页码点浮在画面底部。
// 下面的顺序：继续观看（有才有）→ 精选电影 → 今年 → 去年（电影和剧集一起，最新入库的在前）→ 精选剧集 → 四个大类（用户要求：动画片区、
// 动作片区、喜剧片区、严苛品质区）。卡上只有画面：无字主视觉 + 官方字标，或本来就印着片名的海报，卡下不写字（T20、F80）。
// 分区之间只靠留白（F3、F12、F38）。折起的外屏、展开的竖拿 / 横拿是同一套部件，只按可用宽度长大（S1、D2、F9）。

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(AccountStore.self) private var account
    /// 头像左边那颗「光学扫描」（用户要求）：扫另一台设备上的粒子云，让它登录这个账户
    @State private var pairScanning = false
    /// 这一栈推进去的页（分享来的链接打开详情页时往里推）
    @State private var path = NavigationPath()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        let _ = Perf.count("home")
        ZoomStack(path: $path) {
            GeometryReader { geo in
                let insets = geo.safeAreaInsets
                // 内容区的宽（不算侧边那一列）：边距、卡宽、排间距都从它算（F9、D4、S3、S5、S6）；
                // 安全区也带上：横着的一排一直铺到侧边那一列底下
                let m = DSMetrics(width: geo.size.width, leadingInset: insets.leading, trailingInset: insets.trailing, height: geo.size.height)
                let fullWidth = geo.size.width + insets.leading + insets.trailing
                let fullHeight = geo.size.height + insets.top + insets.bottom
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        hero(m, fullWidth: fullWidth, fullHeight: fullHeight, insets: insets)
                        shelves(m, fullHeight: fullHeight)
                            // 宽度写死成内容区的宽：哪个孩子再宽（结尾的字标卡一排几千点）也撑不开这一列，
                            // 居中的东西（字标、按钮、精选区的立体海报）不会跑到屏幕外面去
                            .frame(width: m.width, alignment: .leading)
                            .padding(.top, m.wide ? 36 : 28)
                            // 货架留在安全区里（卡往右滑出去时从侧边那一列底下过去）
                            .padding(.leading, insets.leading)
                            .padding(.trailing, insets.trailing)
                    }
                    .padding(.bottom, m.shelfGap)
                }
                .scrollIndicators(.hidden)
                .background(Theme.bg)
                // 头图从屏幕最上沿、连同侧边那一列一起铺满（F6、S19）
                .ignoresSafeArea(edges: [.top, .horizontal])
                .settledRefreshable { await model.refreshAll() }
            }
            .background(Theme.bg)
            .toolbar(.hidden, for: .navigationBar)
        }
        .sheet(isPresented: $pairScanning) { PairScanSheet().environment(account).environment(\.colorScheme, .light) }
        // 分享来的链接（cuven://movie/…）：推进那一部的详情页
        .onChange(of: model.openRequest) { _, r in
            guard let r else { return }
            model.openRequest = nil
            path.append(r)
        }
        // 头图每 6 小时换一轮（AppModel.resolveHeroes）：从后台回来时跨过了整点，就换上这一轮的
        .onChange(of: scenePhase) { _, p in
            if p == .active { Task { await model.heroSlotCheck() } }
        }
    }

    // MARK: 头图

    /// 头图（S15）：竖着的屏约 86% 屏高、用竖版全屏图（下面露出下一排的标题，告诉人还能往下滑：S8）；
    /// 横着的屏 94% 屏高、用横版背景。宽度是整个窗口（含侧边那一列），字留在安全区里
    @ViewBuilder
    private func hero(_ m: DSMetrics, fullWidth: CGFloat, fullHeight: CGFloat, insets: EdgeInsets) -> some View {
        let tall = fullHeight > fullWidth
        // iPad（用户要求定制）：头图不再占满一整屏，竖拿约六成、横拿约七成半，下面那一排的标题露出来（Apple TV App 在 iPad 上的比例）
        let pad = UIDevice.current.userInterfaceIdiom == .pad
        let ratio: CGFloat = pad ? (tall ? 0.62 : 0.74) : (tall ? 0.86 : 0.94)
        // 设计复查：有标签栏的 iPhone 竖拿（下边距 > 60）时，86% 让下一排的标题一大半压在标签栏底下；
        // 最多到「屏高 − 下边距 − 72」（28 间距 + 28 标题 + 16 留白），标题整行露在标签栏上面。折起的 Duo、iPad 不变
        let height = ((!pad && tall && insets.bottom > 60) ? min(fullHeight * ratio, fullHeight - insets.bottom - 72) : fullHeight * ratio).rounded()
        let pages = heroPages
        ZStack(alignment: .topLeading) {
            if !pages.isEmpty {
                DSHeroCarousel(pages: pages, metrics: m, height: height, fullWidth: fullWidth,
                               leadingInset: insets.leading, trailingInset: insets.trailing)
            } else if (model.movies.isEmpty || !model.heroResolved) && !loadFailed {
                // 还在载入 / 还在挑头图：先占住头图的位置，不留白屏（C66），也不先放一张不合格的（设计轮 2：和卡的占位同一种灰）
                LinearGradient(colors: [DSFill.placeholder, Theme.bg], startPoint: .top, endPoint: .bottom)
                    .frame(width: fullWidth, height: height)
                    .accessibilityHidden(true)
            } else {
                // 和下面「主页」那一行的上边距同一个下限（24），占的高度跟着一起变
                Color.clear.frame(width: fullWidth, height: max(insets.top, 24) + 64)
            }
            // 最上面一行：左边白字「主页」（Apple TV 主页那样的大标题，压在画面上、跟着头图一起滚走：C13、F34；
            // 发行前从英文「Home」改成中文，和标签栏的「主页」一致），右边光学扫描。
            // 账户与设置不在这里了：用户要求照 Netflix，头像是导航的最后一格（标签栏「我的」）
            HStack(alignment: .center, spacing: 12) {
                Text("主页")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.35), radius: 10, y: 2)
                    .allowsHitTesting(false)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 12)
                // 光学扫描在「主页」右边（iPhone Duo 上也是：挪到侧边那一列里试过，用户要求放回来）
                if canScan { scanButton }
            }
            // 没有状态栏留的安全区时（iPhone Duo 折起，状态栏在侧边那一列）至少离上沿 24 + 8：
            // 以前是 12 + 8，大标题贴着屏幕顶（用户要求「保持一定的留白，整个界面看上去不会拥挤」）
            .padding(.top, max(insets.top, 24) + 8)
            .padding(.leading, insets.leading + m.margin)
            .padding(.trailing, insets.trailing + m.margin)
            .frame(width: fullWidth)
        }
        .frame(width: fullWidth, alignment: .topLeading)
        // 占位 → 头图淡过去（以前灰的占位一下子换成黑底，画面再从黑里出来）；只是淡入淡出，「减弱动态效果」下也合适
        .animation(DSMotion.fade, value: pages.isEmpty)
    }

    /// 能扫：配对的解码器在（PairSpec），登录了、不是演示数据（和账户页「扫描登录其他设备」同一个条件）
    private var canScan: Bool {
        PairSpec.shared != nil && (account.session.map { $0.method != "demo" } ?? false)
    }

    /// 光学扫描（用户要求「在头像旁边添加 + 光学扫描按钮」）：和头像一样大的一颗 Liquid Glass 圆钮，
    /// 点开就是账户页里那张扫描（将图案放在圆圈中 → 看是哪台设备 → 面容 ID 批准）
    private var scanButton: some View {
        Button {
            // 和别的玻璃钮一样，点下去有一下轻的触感
            Haptics.light()
            pairScanning = true
        } label: {
            // 图标（用户要求 Apple 风格、克制简洁）：取景框四个角 + 中间一个小圆（镜头），见 ScanGlyph
            ScanGlyph()
                .stroke(.white, style: StrokeStyle(lineWidth: 1.9, lineCap: .round, lineJoin: .round))
                .frame(width: 23, height: 23)
                .frame(width: 46, height: 46)
                .glassEffect(.regular.interactive(), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("光学扫描")
        .accessibilityHint("扫描另一台设备上的粒子云，让它登录你的账户")
        .accessibilityIdentifier("home-pair-scan")
    }

    /// 头图的每一页（T30–T32）：只放拿到了无字背景 + 字标的，最多 5 部（AppModel.resolveHeroes 挑）。
    /// 横着的屏用无字的横图，竖着的屏用竖版无字图（没有就把横图居中裁）。看了一半的直接「继续播放」，不再问（S17、F85）
    private var heroPages: [DSHeroPage] {
        model.heroPicks.map { p in
            let v = p.video
            return DSHeroPage(id: p.id,
                              wideArt: p.wide,
                              tallArt: p.tall ?? p.wide,
                              logo: p.logo,
                              title: model.title(v),
                              meta: heroMeta(p),
                              playTitle: model.playback.resumePosition(v.path) != nil ? "继续播放" : "播放",
                              play: { playHero(p) },
                              detail: .movie(v),
                              trailerHLS: model.heroTrailers[p.id])
        }
    }

    /// 「电影 · 2026 · 科幻」：一行、短、平实（F84、S15）
    private func heroMeta(_ p: HeroPick) -> String {
        let kind = (p.hero?.type ?? "Movie").lowercased().hasPrefix("show") ? "剧集" : "电影"
        let year = (p.hero?.year ?? model.year(p.video)).map { String($0) }
        let genre = model.meta(p.video)?.genres?.first
        return [kind, year, genre].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func playHero(_ p: HeroPick) {
        let v = p.video
        PlayerCoordinator.shared.play(PlayRequest(path: v.path, name: v.name, title: model.title(v),
                                                  subtitle: model.year(v).map { String($0) },
                                                  artwork: p.wide), model: model)
    }

    private var loadFailed: Bool {
        if case .failed = model.phase { return true }
        return false
    }

    // MARK: 货架

    /// 今年和去年（「2026」「2025」）
    private var homeYears: [Int] {
        let y = Calendar.current.component(.year, from: Date())
        return [y, y - 1]
    }

    /// 货架那一列。片库到了，占位淡出、真货架淡入（以前是一下子换掉）；只是淡入淡出，「减弱动态效果」下也合适。
    /// 外面套一层 VStack 只为挂这个动画：里面始终只有一块，版面不变
    private func shelves(_ m: DSMetrics, fullHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            shelfContent(m, fullHeight: fullHeight)
        }
        .animation(DSMotion.fade, value: model.movies.isEmpty)
    }

    /// 顺序：继续观看 → 精选电影 → 今年 → 探索片段合集 → 去年（预告片卡）→ 编辑推荐 → 精选剧集 → 四个大类 → 结尾（两排字标卡 + 查看全部影片）
    /// （docs/ios-design.md「主页」；F1：最要紧的在上）
    @ViewBuilder
    private func shelfContent(_ m: DSMetrics, fullHeight: CGFloat) -> some View {
        if model.movies.isEmpty {
            switch model.phase {
            case .failed(let msg):
                // 连不上：说清楚哪里不对、该怎么办（F87）；按钮是动词（F85）
                ContentUnavailableView {
                    Label("无法连接服务器", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(msg)
                } actions: {
                    Button("重试") { Task { await model.refreshAll() } }
                        .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, minHeight: 300)
            default:
                // 载入中：先出和真货架同样大小的占位（C66）
                VStack(alignment: .leading, spacing: m.shelfGap) {
                    SkeletonRow(metrics: m)
                    SkeletonRow(metrics: m)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: m.shelfGap) {
                continueWatching(m)
                // 精选电影紧跟在继续观看下面（用户要求：从编辑推荐上面挪上来）
                featuredShelf(m)
                // 今年那一排下面是「探索片段合集」（用户要求：2026 年份下；ClipCollections.swift），再是去年
                let years = homeYears
                yearShelf(years[0], m)
                ClipCollectionsShelf(metrics: m)
                ForEach(years.dropFirst(), id: \.self) { y in yearShelf(y, m) }
                editorsPickBlock(m, fullHeight: fullHeight)
                featuredSeriesShelf(m)
                // 主页不放「可申请」那一排（用户要求移除）：可申请的在「全部影片 › 可申请」和搜索里
                ForEach(HomeCategory.allCases) { c in categoryShelf(c, m) }
                finale(m)
            }
        }
    }

    /// 继续观看（T22）：16:9 画面 + 字标 + 进度条（F36）；点一下直接接着放（S17、C89）
    @ViewBuilder
    private func continueWatching(_ m: DSMetrics) -> some View {
        let entries = model.playback.continueWatching
        if !entries.isEmpty {
            DSSection(title: "继续观看", metrics: m) {
                DSShelf(metrics: m) {
                    ForEach(entries) { e in
                        let art = continueArt(e)
                        Button { resume(e) } label: {
                            DSWideLockup(art: art.url, title: e.title, subtitle: remainingLabel(e),
                                         progress: e.fraction, metrics: m, logo: art.logo)
                                .downloadBadge(e.seriesPath == nil ? e.path : nil, inset: 10)
                        }
                        .buttonStyle(PressableStyle())
                        .accessibilityIdentifier("continue-card")
                    }
                }
            }
        }
    }

    /// 某一年（今年 / 去年）：电影和剧集一起，最新入库的在前；标题「2026 ›」进年份页（F86、T25）
    @ViewBuilder
    private func yearShelf(_ y: Int, _ m: DSMetrics) -> some View {
        // 用户要求：没有字标的不在这两排出现（年份页「2026 ›」里照样有）
        let items = Array(model.homeYear(y).filter { model.hasLogo($0) }.prefix(24))
        if !items.isEmpty {
            // 用户要求（只改年份这两排），照游戏 App「Arcade 名人堂」：上面预告片，下面小海报 + 字标 + 片名
            YearTrailerRow(year: y, items: items, metrics: m)
        }
    }

    /// 编辑推荐（用户要求，照游戏 App「重磅更新」）：预告片铺满做底 + 「编辑推荐」+ 底部取色面板（海报、字标、简介）
    @ViewBuilder
    private func editorsPickBlock(_ m: DSMetrics, fullHeight: CGFloat) -> some View {
        if let v = model.editorsPick() {
            EditorsPick(video: v, metrics: m, fullHeight: fullHeight)
        }
    }

    /// 主页结尾（用户要求，照 Apple TV+ 那一页的结尾）：两排反向慢慢走的 16:9 字标卡、「查看全部影片 ›」+ 暂停；
    /// 手机上原先再加的「立即观看」用户要求去掉了（截图里是不该出现的按钮），手机和展开一样到这一行就完
    @ViewBuilder
    private func finale(_ m: DSMetrics) -> some View {
        let tiles = model.finaleTiles(limit: 20)
        if tiles.count >= 8 {
            HomeFinale(tiles: tiles, metrics: m)
                .padding(.top, 8)
        }
    }

    /// 精选电影：评分高的在前。用户要求「整个精选电影区使用大卡片设计」（参考图：Apple TV「What We're Watching」）：
    /// 不再是立体海报封面 + 大标题 + 说明 + 一排带底栏的卡，整个区就是分区标题「精选电影 ›」（点进合集页）+ 一排 3 : 4 的大竖卡
    @ViewBuilder
    private func featuredShelf(_ m: DSMetrics) -> some View {
        let items = model.featuredMovies(limit: 10)
        if !items.isEmpty {
            DSSection(title: Shelf.featured.title, metrics: m, route: .shelf(.featured)) {
                DSShelf(metrics: m) {
                    ForEach(items, id: \.path) { v in featuredCard(v, m) }
                }
            }
        }
    }

    /// 一张大竖卡：无字的竖版画面 + 字标 + 「电影 · 年份 · 类型」（不放简介：简介只在详情页）；
    /// 点开是详情（从这张卡上放大出来），长按是播放 / 想看（C21）
    private func featuredCard(_ v: Video, _ m: DSMetrics) -> some View {
        let w = m.bigCardWidth
        let art = model.featuredArt(v, width: w)
        let genres = model.meta(v)?.genres ?? []
        let line = DetailText.line(["电影", model.year(v).map { String($0) }, genres.first, genres.dropFirst().first])
        return ZoomLink(route: .movie(v), slot: "featured") {
            FeaturedBigCard(art: art?.url, logo: art?.logo, title: model.title(v), line: line, width: w)
                .downloadBadge(v.path, inset: 14, size: 26)
        }
        .accessibilityIdentifier("featured-card")
        .movieMenu(v)
    }

    /// 精选剧集：片库里评分最高的剧（一部剧只出一次）。折起、展开都是同一个样子（用户要求：展开时也是和折起一样的可滑动列表，
    /// 不再是两张一排的 2×2 网格）：立体海报 + 大标题 + 说明，下面一排横着滑的大卡
    @ViewBuilder
    private func featuredSeriesShelf(_ m: DSMetrics) -> some View {
        let items = model.featuredSeries(limit: 10)
        if items.count >= 3 {
            FeaturedCollection(title: Shelf.featuredSeries.title, blurb: Shelf.featuredSeries.blurb ?? "",
                               rowTitle: "一集接一集停不下来", rowRoute: .shelf(.featuredSeries),
                               covers: items.prefix(3).map { s in
                                   let sm = model.seriesMetas[s.path]
                                   return TMDBImage.url(sm?.poster ?? sm?.posterClean, "w500")
                               }, metrics: m) {
                ForEach(items, id: \.path) { s in featuredSeriesCard(s, m) }
            }
        }
    }

    private func featuredSeriesCard(_ s: Series, _ m: DSMetrics) -> some View {
        let w = m.featureCardWidth
        let sm = model.seriesMetas[s.path]
        return ZoomLink(route: .series(s), slot: "featured-tv") {
            FeaturedCollectionCard(art: model.seriesWideArt(s).url, cover: TMDBImage.url(sm?.poster ?? sm?.posterClean, "w342"),
                                   title: sm?.title ?? s.name,
                                   subtitle: DetailText.line(["Cuven 独占", sm?.genres?.first]), width: w)
        }
        .accessibilityIdentifier("featured-series-card")
        .seriesMenu(s)
    }

    /// 四个大类之一：电影和剧集一起（动画、动作、喜剧新的在前，严苛品质区评分高的在前）；标题「›」进这一类的全部。
    /// 展开时海报比别处大 10%（用户要求，只在展开时）；按 fit 排，最后露出下一张一截（DSMetrics.categoryPosterWidth）
    @ViewBuilder
    private func categoryShelf(_ c: HomeCategory, _ m: DSMetrics) -> some View {
        let items = model.categoryEntries(c, limit: 20)
        let w = m.categoryPosterWidth
        if !items.isEmpty {
            DSSection(title: c.title, metrics: m, route: .shelf(.category(c))) {
                DSShelf(metrics: m) {
                    ForEach(items) { e in posterCard(e, m, width: w, slot: "cat-\(c.rawValue)") }
                }
            }
        }
    }

    /// 一张海报卡：纯净画面 + 字标（AppModel.posterArt / seriesPosterArt 定先后），长按是播放 / 想看（C21）
    @ViewBuilder
    private func posterCard(_ e: HomeEntry, _ m: DSMetrics, width w: CGFloat, slot: String) -> some View {
        switch e {
        case .movie(let v):
            let art = model.posterArt(v, width: w)
            ZoomLink(route: .movie(v), slot: slot) {
                DSPosterLockup(art: art.url, title: model.title(v), subtitle: model.year(v).map { String($0) },
                               metrics: m, width: w, logo: art.logo)
                    // 这一部在下载 / 下好了：海报右上角一颗下载角标（用户要求）
                    .downloadBadge(v.path)
            }
            .accessibilityIdentifier("movie-card")
            .movieMenu(v)
        case .series(let s):
            let art = model.seriesPosterArt(s, width: w)
            ZoomLink(route: .series(s), slot: slot) {
                DSPosterLockup(art: art.url, title: model.seriesMetas[s.path]?.title ?? s.name, subtitle: s.seasonLabel,
                               metrics: m, width: w, logo: art.logo)
            }
            .accessibilityIdentifier("series-card")
            .seriesMenu(s)
            .task { await model.ensureSeriesMeta(s) }
        }
    }

    /// 继续观看的画面、剩余时间、接着放：和半折面板下面那块同一套（PlayerPanelData、PlayerCoordinator.resume）
    private func continueArt(_ e: WatchEntry) -> (url: URL?, logo: URL?) {
        PlayerPanelData.continueArt(e, model: model)
    }

    private func remainingLabel(_ e: WatchEntry) -> String {
        PlayerPanelData.remainingLabel(e)
    }

    private func resume(_ e: WatchEntry) {
        PlayerCoordinator.shared.resume(e, model: model)
    }
}

// MARK: - 导航目标

struct RouteView: View {
    let route: Route
    var body: some View {
        switch route {
        case .folder(let f): FolderView(folder: f)
        case .movie(let v): MovieDetailView(video: v)
        case .series(let s): SeriesDetailView(series: s)
        case .year(let y): YearView(year: y)
        // 全部影片：按年份、电影 / 剧集、可立即播放 / 可申请分开的那一页（用户要求；AllFilmsView.swift）
        case .shelf(let s): if s == .all { AllFilmsView() } else { ShelfView(shelf: s) }
        case .person(let m): ActorPage(member: m)
        case .catalog(let t): CatalogDetailView(title: t)
        // 全部影片下面「电影 ›」「剧集 ›」进来的分类页（用户要求；版式照专区：FilmCategoryPage.swift）
        case .filmCategory(let c): FilmCategoryPage(category: c)
        // 全部影片里某一年的「电影 ›」「剧集 ›」：同一种分类页，只看这一年的
        case .filmYear(let c, let y): FilmCategoryPage(category: c, year: y)
        }
    }
}
