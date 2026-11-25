import SwiftUI

// MARK: - 全部影片（主页结尾「查看全部影片 ›」、搜索没结果时「浏览所有影片」）
//
// 用户要求：「设计查看全部影片页面，全面放开片库；按照主页年份分类从 2026 年 → 2020 年，电视剧和电影分开，
// 可以申请和可以立即播放的分开，样式可以和主页中的年份分类一致，可以微调和优化布局」。
//
// 版式（干净、克制）：
// · 大标题「全部影片」，下面一枚分段控件：「可立即播放」（片库里的，按下去就放）/「可申请」（影片库索引里有、片库里还没有的，
//   点开是「请求添加」的详情页）。两边各是一整页，互不混在一起
// · 往下按年份一节一节：2026、2025 … 2020（今年往前数七年）。每一节的标题和主页年份那两排同一个样子（大一级的「2026 ›」，
//   点进年份页）。用户要求哪里都不写有几部：标题下面不再有「128 部电影 · 54 部剧集」那行灰字
// · 每一节里电影一排、剧集一排（小标题「电影」「剧集」，不带数字），没有的那排不出、两排都没有的年份整节不出
// · 可立即播放：卡和主页年份那两排同一张（YearTrailerCard：上面剧照，下面小海报 + 字标 + 片名 + 一行灰字）；
//   全面放开：主页那两排只放有字标的，这里片库里这一年的全部都放（没字标的就是片名），剧集还没取到资料的先取
// · 可申请（用户要求「布局和 UI 和可立即播放的一致，2026 至 2020 年影片库里的全部」）：同一张横卡，剧照、字标按 TMDB 编号
//   一排一次取（CatalogArt）；右边那颗胶囊是请求的状态（申请 / 已加入 / 已请求 42% / 已就绪），请求进行中剧照底边一道进度线；
//   长按电影可以直接放进请求中心。一打开页面就用 /app/years 一次问完七年 × 电影 / 剧集的第一页（tj 2.8；老版本一年一年问），
//   本机存着上次的，再打开先有画面再更新；一排滑到头再取下一页（滤掉别的年份之后不到 8 张就自己接着翻，翻到第 8 页为止）
// 一节就是一个懒加载的块：几百部片也只建看得到的那几排。
// · 分段控件下面一行「电影 ›」「剧集 ›」（用户要求「添加打开分类按钮，电视剧和电影分开，UI 和布局参考专区」）：跟着上面选的那一边，
//   打开可立即播放 / 可申请的全部电影或全部剧集（FilmCategoryPage：专区那样的一页，顶上换成三张横滑的大卡）

struct AllFilmsView: View {
    @Environment(AppModel.self) private var model

    enum Mode: String, CaseIterable, Identifiable {
        case playable, requestable
        var id: String { rawValue }
        var title: String { self == .playable ? "可立即播放" : "可申请" }
    }

    @State private var mode: Mode = .playable
    private var catalog: CatalogYears { CatalogYears.shared }

    /// 今年往前数七年（2026 → 2020）
    private var years: [Int] {
        let y = Calendar.current.component(.year, from: Date())
        return Array((y - 6...y).reversed())
    }

    var body: some View {
        GeometryReader { geo in
            let insets = geo.safeAreaInsets
            let m = DSMetrics(width: geo.size.width, leadingInset: insets.leading, trailingInset: insets.trailing, height: geo.size.height)
            ScrollView {
                // 用户要求「保持一定的留白，整个界面看上去不会拥挤」：分段控件那一块不放进年份的懒加载列表里，
                // 它到第一年是一道排距（shelfGap）；年与年之间再宽 8 点，一年一节读得出来
                VStack(alignment: .leading, spacing: m.shelfGap) {
                    picker(m)
                    LazyVStack(alignment: .leading, spacing: m.shelfGap + 8, pinnedViews: []) {
                        ForEach(years, id: \.self) { y in
                            switch mode {
                            case .playable: PlayableYear(year: y, metrics: m)
                            case .requestable: RequestableYear(year: y, metrics: m, catalog: catalog)
                            }
                        }
                        .id(mode)
                    }
                }
                .padding(.top, m.pageTop)
                .padding(.bottom, m.pageBottom)
                .padding(.leading, insets.leading)
                .padding(.trailing, insets.trailing)
                .animation(.smooth(duration: 0.3), value: mode)
            }
            .scrollIndicators(.hidden)
            .ignoresSafeArea(edges: .horizontal)
        }
        .background(Theme.bg)
        // 一打开就去问可申请的那几年（不等切过去）：切过去时已经是全的
        .task {
            _ = CatalogArt.shared     // 本机存的剧照、字标先读进来
            await catalog.prefetch(years: years)
        }
        // 可申请里整节不出的那几年（两格都没问成，或者问到了、滤掉之后一张都看不到）：节里什么都没有，挂不了重问
        // （挂一层空的上去，节与节之间就多一道空）。第一轮问完、切到「可申请」时在这里替它们问；出了的那几节各自问（滑到了才问）
        .task(id: "\(mode.rawValue)-\(catalog.prefetching)") {
            guard mode == .requestable, !catalog.prefetching else { return }
            let owned = model.ownedMovieIDs, shows = model.ownedSeasons
            let hidden = years.flatMap { y -> [CatalogYears.Key] in
                let ks = [CatalogYears.Key(year: y, src: "movie"), CatalogYears.Key(year: y, src: "tv")]
                // 和 RequestableYear 出不出同一个判断：两格都问过了、两排都一张看不到
                let gone = ks.allSatisfy { k in
                    let p = catalog.page(k)
                    return (p.started || p.failed) && !p.items.contains { !model.owns($0, movies: owned, shows: shows) }
                }
                return gone ? ks : []
            }
            await catalog.ensure(hidden: hidden)
        }
        .navigationTitle("全部影片")
        .navigationBarTitleDisplayMode(.large)
        .sensoryFeedback(.selection, trigger: mode)
    }

    /// 两边分开：可立即播放 / 可申请（系统的分段控件，iOS 26 上是一枚玻璃）；
    /// 下面一行「电影 ›」「剧集 ›」打开这一边的分类页（用户要求：电视剧和电影分开）
    private func picker(_ m: DSMetrics) -> some View {
        // 分段控件到下面那两颗胶囊：和分区标题到那一排同一个距离（以前 10，贴着）
        VStack(alignment: .leading, spacing: m.titleGap) {
            Picker("显示", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: m.wide ? 420 : .infinity)
            .accessibilityIdentifier("all-films-mode")
            HStack(spacing: 10) {
                categoryButton("电影", series: false, id: "all-films-open-movie")
                categoryButton("剧集", series: true, id: "all-films-open-series")
            }
        }
        .padding(.horizontal, m.margin)
    }

    /// 打开分类页的一颗：描边的胶囊（主页结尾「查看全部影片 ›」那一种，小一号、边淡一点：克制，不和分段控件抢），
    /// 看上去 36 高，点按区上下各多 4 点（44：F74）
    private func categoryButton(_ title: String, series: Bool, id: String) -> some View {
        NavigationLink(value: Route.filmCategory(FilmCategory(playable: mode == .playable, series: series))) {
            HStack(spacing: 4) {
                Text(title)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 16)
            .frame(minHeight: 36)
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.4), lineWidth: 1))
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        // 旁白名就是看得见的那个字（语音控制说「点按 电影」对得上），是哪一边的放进提示里
        .accessibilityLabel(title)
        .accessibilityHint("打开\(mode.title)的全部\(title)")
        .accessibilityIdentifier(id)
    }
}

// MARK: - 年份那一节的标题（和主页年份那两排同一个部件，点进年份页）

private struct YearHeader: View {
    let year: Int
    let metrics: DSMetrics
    var link = true

    var body: some View {
        // 只有年份（用户要求不写有几部电影、几部剧集）
        let label = DSSectionLabel(title: String(year), chevron: link, showcase: true, wide: metrics.wide)
            .padding(.horizontal, metrics.margin)
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
        if link {
            NavigationLink(value: Route.year(year)) { label }
                .buttonStyle(PressableStyle(scale: 0.98))
                .accessibilityIdentifier("all-films-\(year)")
        } else {
            label
        }
    }
}

/// 一节里的小标题：「电影」「剧集」（用户要求不带数字）
private struct KindLabel: View {
    let title: String
    let metrics: DSMetrics

    var body: some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, metrics.margin)
    }
}

// MARK: - 可立即播放：片库里这一年的全部

private struct PlayableYear: View {
    @Environment(AppModel.self) private var model
    let year: Int
    let metrics: DSMetrics

    var body: some View {
        let movies = model.movies(inYear: year).sorted { $0.addedKey > $1.addedKey }
        let shows = model.seriesInYear(year).sorted { ($0.added ?? "") > ($1.added ?? "") }
        if !movies.isEmpty || !shows.isEmpty {
            VStack(alignment: .leading, spacing: metrics.titleGap + 6) {
                YearHeader(year: year, metrics: metrics)
                // 「电影」那一排的底到「剧集」那个小标题隔开一段（subsectionGap）：以前和年份标题到「电影」一样近，
                // 「剧集」读着像是挂在电影那一排底下的
                VStack(alignment: .leading, spacing: metrics.subsectionGap) {
                    if !movies.isEmpty {
                        VStack(alignment: .leading, spacing: metrics.titleGap) {
                            KindLabel(title: "电影", metrics: metrics)
                            DSShelf(metrics: metrics) {
                                ForEach(movies, id: \.path) { v in movieCard(v) }
                            }
                        }
                    }
                    if !shows.isEmpty {
                        VStack(alignment: .leading, spacing: metrics.titleGap) {
                            KindLabel(title: "剧集", metrics: metrics)
                            DSShelf(metrics: metrics) {
                                ForEach(shows, id: \.path) { s in seriesCard(s) }
                            }
                        }
                    }
                }
            }
        }
    }

    private func movieCard(_ v: Video) -> some View {
        let sub = DetailText.line([model.year(v).map { String($0) }, model.meta(v)?.genres?.first])
        return ZoomLink(route: .movie(v), slot: "all-\(year)") {
            YearTrailerCard(still: TMDBImage.url(model.backgroundArtString(v), "w1280"),
                            cover: model.thumbArt(v), logo: model.wideLockupArt(v).logo,
                            title: model.title(v), subtitle: sub, width: metrics.trailerCardWidth)
                .downloadBadge(v.path, inset: 10)
        }
        .accessibilityIdentifier("all-films-movie")
        .movieMenu(v)
    }

    private func seriesCard(_ s: Series) -> some View {
        let sm = model.seriesMetas[s.path]
        let art = model.seriesWideArt(s)
        let sub = DetailText.line([s.seasonLabel, sm?.genres?.first])
        return ZoomLink(route: .series(s), slot: "all-\(year)") {
            YearTrailerCard(still: art.url, cover: TMDBImage.url(sm?.poster ?? sm?.posterClean, "w185"), logo: art.logo,
                            title: sm?.title ?? s.name, subtitle: sub, width: metrics.trailerCardWidth)
        }
        .accessibilityIdentifier("all-films-series")
        .seriesMenu(s)
        // 全面放开：主页只放取到资料的剧，这里没取到的也放，滑到了再取
        .task { await model.ensureSeriesMeta(s) }
    }
}

// MARK: - 可申请：影片库索引里这一年有、片库里没有的

/// 每一年、电影 / 剧集各一份：已经取到的几页，滑到头再取下一页。
/// 全 App 一份：再打开「全部影片」直接是上次的（5 分钟内不重问；本机还存着上次的第一页，冷启动也是先有再更新）
@MainActor
@Observable
final class CatalogYears {
    static let shared = CatalogYears()
    /// 一排看得到的不到这么多张、又没翻完：自己接着往后翻（不等滑到头）
    static let enough = 8
    /// 自己接着翻（不是用户滑到头）最多翻到第几页：不认年份的老版本是在本机从所有年份里滤，冷门的年份几百页也凑不齐 8 张，
    /// 这一节每出现一次就再翻几页，不设上限就一直往深里翻。刷新（从第一页重来）之后重新算
    static let autoDepth = 8

    struct Key: Hashable { var year: Int; var src: String }
    struct Page {
        var items: [CatalogItem] = []
        /// 接着用 /app/catalog 问哪一页（/app/years 的 next：1 = 第一页没给全，再问一次第一页、按 uid 去重）
        var next = 1
        /// 影片库说一共几部、几页（0 = 不知道）
        var total = 0
        var pages = 0
        /// 影片库按年份给了、这里滤掉的别的年份（按 uid 记）：论坛分区的年份对得上影片库就给，它的总数里也算着这些
        var off: Set<String> = []
        /// 总数是按年份数的（服务器认年份：有 /app/years 的版本）。老版本可能不认年份，总数是所有年份的，不能用；
        /// 认年份的也要影片库只给这一年上映的才准（见 count）
        var counted = false
        var done = false
        var loading = false
        var failed = false
        /// 问过第一页了（问成没问成都算；/app/years 一次问完，或者一年一年问）
        var started = false
        /// 用户往后翻过（滑到这一排的头又取了一页）：刷新时不换掉这一排（一换，看着的那几张就没了）。
        /// 自己接着翻的（看得到的不到 8 张）不算：那样的一排刷新照换（不然再也不刷新），换完不到 8 张再自己翻
        var paged = false
    }

    private(set) var pages: [Key: Page] = [:]
    /// 第一轮在问（/app/years 或一年一年问第一页）
    private(set) var prefetching = false

    @ObservationIgnored private var etag: String?
    @ObservationIgnored private var fetchedAt: Date?
    /// 请求添加 Worker 没有 /app/years（老版本）：只认 /app/years 的 404，不从回来的条目里猜
    /// （影片库按年份给的本来就夹着别的年份的：论坛分区的年份对得上就给）
    @ObservationIgnored private var noYears = false
    @ObservationIgnored private var restored = false

    private init() {}

    func page(_ k: Key) -> Page { pages[k] ?? Page() }

    private static var file: URL {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("cuven", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("catalog-years.v1.json")
    }
    private static let etagKey = "cuven_catalog_years_etag"

    /// 打开「全部影片」就问（不等切到「可申请」）：tj 2.8 的 /app/years 一次问完几年 × 电影 / 剧集的第一页；
    /// 老版本没有这个接口：每一年、每一类各问第一页（同时最多 4 个）
    func prefetch(years: [Int]) async {
        guard !prefetching, let lo = years.min(), let hi = years.max() else { return }
        if let fetchedAt, Date().timeIntervalSince(fetchedAt) < 300 { return }
        prefetching = true
        defer { prefetching = false }
        if DemoData.enabled {
            for y in years { for s in ["movie", "tv"] { pages[Key(year: y, src: s)] = Self.demo(Key(year: y, src: s)) } }
            fetchedAt = Date()
            return
        }
        restore(years)
        if !noYears {
            do {
                let r = try await RequestAPI.years(from: lo, to: hi, per: 24, etag: pages.isEmpty ? nil : etag)
                if r.old {
                    // 只有 /app/years 回 404 才算老版本（没有这个接口）：这个进程里往后都一年一年问
                    noYears = true
                } else {
                    if let p = r.page {
                        apply(p, years: years, live: true)
                        // 有一格没问成的不存（存了下次冷启动那一格是空的）：本机留着上一份完整的，ETag 也留上一份的（两个对得上）
                        let partial = p.years.values.contains { cells in cells.values.contains { $0.failed } }
                        if !partial, let data = r.data {
                            let url = Self.file
                            Task.detached(priority: .utility) { try? data.write(to: url, options: .atomic) }
                            UserDefaults.standard.set(r.etag, forKey: Self.etagKey)
                        }
                    }
                    etag = r.etag
                    // 有一格没问成（{error: 1}）：不记时刻，下次打开再问（这一节出现时也会各自从第一页重问）
                    if !anyFailed(years) { fetchedAt = Date() }
                    return
                }
            } catch {
                // 离开了页面（任务被取消）不是网络不好：什么都不动（不改成一年一年问、不记时刻）
                if Self.cancelled(error) { return }
                // 网络不好：一年一年问（每一格各自出错、各自重试）
            }
        }
        guard !Task.isCancelled else { return }
        // 一年一年问（老版本、网络不好）：每一格都从第一页重问、问到了才换掉 —— 再打开（过了 5 分钟）也是一次刷新，
        // 新收录的、数目变了的都跟上；往后翻过的、正在取的不打断
        let keys = years.flatMap { y in ["movie", "tv"].map { Key(year: y, src: $0) } }.filter { !page($0).paged && !page($0).loading }
        await each(keys) { await self.fetch($0, fresh: true, user: false) }
        // 离开了页面：不记时刻。有一格没问成：下次打开（或滑到那一节）再问，不等 5 分钟
        guard !Task.isCancelled else { return }
        if !anyFailed(years) { fetchedAt = Date() }
    }

    /// 每一格各问各的，同时最多 4 个
    private func each(_ keys: [Key], _ run: @escaping @Sendable (Key) async -> Void) async {
        await withTaskGroup(of: Void.self) { g in
            var i = 0
            func add() {
                guard i < keys.count else { return }
                let k = keys[i]
                i += 1
                g.addTask { await run(k) }
            }
            for _ in 0..<4 { add() }
            while await g.next() != nil { add() }
        }
    }

    private func anyFailed(_ years: [Int]) -> Bool {
        years.contains { y in ["movie", "tv"].contains { page(Key(year: y, src: $0)).failed } }
    }

    /// 上次 /app/years 的回包（冷启动先有画面，再拿 ETag 问一次：没变就是 304）
    private func restore(_ years: [Int]) {
        guard !restored else { return }
        restored = true
        guard pages.isEmpty, let data = try? Data(contentsOf: Self.file),
              let p = try? JSONDecoder().decode(RequestAPI.YearsPage.self, from: data) else { return }
        etag = UserDefaults.standard.string(forKey: Self.etagKey)
        apply(p, years: years, live: false)
    }

    /// live = false：本机存的上次的回包，里面的请求进度可能是好几天前的，不并进 RequestStore（会把请求中心的盖回去）
    private func apply(_ p: RequestAPI.YearsPage, years: [Int], live: Bool) {
        for y in years {
            for s in ["movie", "tv"] {
                let k = Key(year: y, src: s)
                guard let cell = p.years[y]?[s] else { continue }
                if live { for i in cell.items { if let r = i.req { RequestStore.shared.merge(r) } } }
                let old = page(k)
                // 正在取的不动（它回来时接在现在的上面）；往后翻过的那一排也不打断
                if old.loading || old.paged { continue }
                if cell.failed {
                    // 影片库这一格没答上：有上次的就留着，只标一下没问成；没有的空着，从第一页重问（滑到这一节、第一轮问完都会问）
                    var n = old
                    n.started = true
                    n.failed = true
                    if n.items.isEmpty { n.next = 1; n.done = false }
                    pages[k] = n
                    continue
                }
                var n = Page()
                n.items = cell.items.filter { Self.fits($0, y, loose: true) }
                n.off = Set(cell.items.filter { !Self.fits($0, y, loose: true) }.map(\.uid))
                n.total = cell.total
                n.pages = cell.pages
                n.counted = true
                n.started = true
                if let next = cell.next {
                    // 0 = 第一页给全了、没有第二页；1 = 第一页没给全（影片库一页 42 部，一格最多 40）：再问一次第一页、去重接上；2 = 接着第二页
                    n.done = next == 0
                    n.next = max(1, next)
                } else {
                    // 没带 next 的（2.8 之前的测试版）：第一页当给全了
                    n.done = cell.items.isEmpty || cell.page >= cell.pages
                    n.next = 2
                }
                pages[k] = n
            }
        }
    }

    /// 这一节出现时、第一轮问完时：没问过、没问成的问（还没往后翻过的从第一页重问；翻过的接着翻）；
    /// 问过了的：滤掉别的年份、片库里有的之后看得到的不到 8 张，又没翻完 —— 自己接着翻（一次最多 4 页，翻到第 autoDepth 页为止），不等滑到头
    func ensure(_ k: Key, visible: Int) async {
        let p = page(k)
        if !p.started || p.failed {
            await fetch(k, fresh: !p.paged, user: false)
        } else if visible < Self.enough && !p.done {
            await fetch(k, fresh: false, user: false)
        }
    }

    /// 整节不出的那几年（AllFilmsView 替它们问）：同 ensure，两排看得到的都是 0 张
    func ensure(hidden keys: [Key]) async {
        await each(keys) { await self.ensure($0, visible: 0) }
    }

    /// 滑到这一排最后几张：取下一页（同一格同时只取一次）。user = 这一排够长、最后几张是用户滑出来的
    /// （短的一排一出来最后几张就在屏幕上，那是自己接着翻，不算用户翻过）
    func loadMore(_ k: Key, user: Bool) async {
        await fetch(k, fresh: false, user: user)
    }

    /// 问 /app/catalog。fresh：从第一页重问，问到了才换掉这一排（第一次问、没问成重问、老版本刷新）；
    /// 否则从 next 接着翻、按 uid 去重接上。一次最多翻 4 页：滤掉别的年份之后新添的不到 8 部就接着翻。
    /// user：用户滑到头才取的，记下 paged（刷新时不换掉这一排）；自己接着翻的不记，翻到第 autoDepth 页为止。
    /// 每一页回来都重新读一次这一格、接在现在的上面写回去（不拿出门前的那份写回去）
    private func fetch(_ k: Key, fresh: Bool, user: Bool) async {
        let start = page(k)
        // 自己接着翻：不是从第一页重问、不是用户滑到头、这一排也没被用户翻过（翻过的没问成重问照接着翻）
        let auto = !fresh && !user && !start.paged
        guard !start.loading, !(fresh && start.paged), fresh || !start.done, !auto || start.next <= Self.autoDepth else { return }
        pages[k, default: Page()].loading = true
        // 有 /app/years 的版本认年份：没有年份的条目是这一年分区里的，留着；老版本可能不认年份，留着会每一年都出一次
        let loose = !noYears
        var next = fresh ? 1 : start.next
        var fetched = 0, added = 0, failed = false
        while true {
            let r: RequestAPI.CatalogPage
            do {
                r = try await RequestAPI.catalogPage(src: k.src, sort: "new", own: "hide", page: next, year: k.year)
            } catch {
                // 离开页面（任务被取消）不算没问成
                failed = !Self.cancelled(error)
                break
            }
            next += 1
            for i in r.items { if let s = i.req { RequestStore.shared.merge(s) } }
            var cur = page(k)
            if fresh && fetched == 0 { cur.items = []; cur.off = []; cur.next = 1 }
            var have = Set(cur.items.map(\.uid))
            for i in r.items {
                guard have.insert(i.uid).inserted else { continue }
                if Self.fits(i, k.year, loose: loose) {
                    cur.items.append(i)
                    added += 1
                } else {
                    cur.off.insert(i.uid)
                }
            }
            fetched += 1
            cur.next = max(cur.next, next)
            if user { cur.paged = true }
            if r.pages > 0 || r.total > 0 {
                cur.total = r.total
                cur.pages = r.pages
                cur.counted = loose
            }
            cur.done = r.items.isEmpty || (r.pages > 0 && next > r.pages)
            cur.started = true
            cur.failed = false
            pages[k] = cur                      // loading 还是 true：这一次还没完
            if cur.done || fetched >= 4 || added >= Self.enough || Task.isCancelled || (auto && next > Self.autoDepth) { break }
        }
        var end = page(k)
        end.loading = false
        if failed && fetched == 0 {
            // 一页都没问到：这一排原样留着（本机存的、上次的都不擦掉），标一下没问成，下次再问
            end.started = true
            end.failed = true
        }
        pages[k] = end
    }

    /// 这一条算不算这一年的：影片库按年份给的里面有别的年份的（论坛分区的年份对得上就给），只留这一年的
    private static func fits(_ i: CatalogItem, _ year: Int, loose: Bool) -> Bool {
        i.year.isEmpty ? loose : Int(i.year.prefix(4)) == year
    }

    /// 任务被取消（离开了页面）：URLSession 回 cancelled（分类页的 CatalogFeed 也用）
    static func cancelled(_ e: any Error) -> Bool {
        Task.isCancelled || e is CancellationError || (e as? URLError)?.code == .cancelled
    }

    /// 演示数据（UI 测试用）：分类页「可申请」也用这几条（CatalogFeed）
    static func demo(_ k: Key) -> Page {
        let names = k.src == "movie" ? ["潮汐之间", "风的形状", "远航者", "无名之城", "第二个夏天"] : ["夜航", "回声镇", "长街"]
        var p = Page()
        p.items = names.enumerated().map { i, n in
            CatalogItem(demo: 7000 + k.year % 100 * 10 + i + (k.src == "tv" ? 500 : 0), src: k.src, title: n,
                        year: String(k.year), poster: "demo://poster/\(9 + (i + k.year) % 6)")
        }
        p.total = names.count
        p.pages = 1
        p.next = 2
        p.done = true
        p.started = true
        return p
    }
}

private struct RequestableYear: View {
    @Environment(AppModel.self) private var model
    let year: Int
    let metrics: DSMetrics
    let catalog: CatalogYears

    var body: some View {
        let mk = CatalogYears.Key(year: year, src: "movie"), tk = CatalogYears.Key(year: year, src: "tv")
        let mp = catalog.page(mk), tp = catalog.page(tk)
        let owned = model.ownedMovieIDs, shows = model.ownedSeasons
        let movies = mp.items.filter { !model.owns($0, movies: owned, shows: shows) }
        let series = tp.items.filter { !model.owns($0, movies: owned, shows: shows) }
        let settled = (mp.started || mp.failed) && (tp.started || tp.failed)
        let vm = movies.count, vt = series.count
        // 两排都没有的整节不出（不留空的一层：LazyVStack 每一层之间都隔一道空）。整节不出的那几年由 AllFilmsView 替它们重问
        if !movies.isEmpty || !series.isEmpty || !settled {
            VStack(alignment: .leading, spacing: metrics.titleGap + 6) {
                YearHeader(year: year, metrics: metrics, link: false)
                // 和可立即播放一样：电影、剧集两排之间隔开一段（不出的那一排不占这一段）
                VStack(alignment: .leading, spacing: metrics.subsectionGap) {
                    row("电影", key: mk, page: mp, items: movies)
                    row("剧集", key: tk, page: tp, items: series)
                }
            }
            // 第一轮（/app/years）没给到、没问成的（网络不好、老版本）：滑到这一节、或者第一轮问完了再问一次（从第一页）；
            // 问到了、可滤掉别的年份和片库里有的之后不到 8 张：接着往后翻（一次最多 4 页，有上限），不等滑到头
            .task(id: "\(year)-\(catalog.prefetching)") {
                guard !catalog.prefetching else { return }
                let c = catalog
                async let a: Void = c.ensure(mk, visible: vm)
                async let b: Void = c.ensure(tk, visible: vt)
                _ = await (a, b)
            }
        }
    }


    @ViewBuilder
    private func row(_ title: String, key: CatalogYears.Key, page p: CatalogYears.Page, items: [CatalogItem]) -> some View {
        let w = metrics.trailerCardWidth
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: metrics.titleGap) {
                KindLabel(title: title, metrics: metrics)
                DSShelf(metrics: metrics) {
                    ForEach(items, id: \.uid) { it in
                        RequestableCard(item: it, width: w, slot: "all-request-\(year)")
                            // 滑到这一排最后几张：取下一页。不到 8 张的一排一出来最后几张就在屏幕上：那是自己接着翻（有上限），不算用户翻过
                            .onAppear {
                                if items.suffix(3).contains(where: { $0.uid == it.uid }), !catalog.page(key).done {
                                    let user = items.count >= CatalogYears.enough
                                    Task { await catalog.loadMore(key, user: user) }
                                }
                            }
                    }
                    if p.loading { SkeletonTrailerCard(width: w) }
                }
            }
        } else if !p.started {
            VStack(alignment: .leading, spacing: metrics.titleGap) {
                KindLabel(title: title, metrics: metrics)
                DSShelf(metrics: metrics) {
                    ForEach(0..<3, id: \.self) { _ in SkeletonTrailerCard(width: w) }
                }
            }
            .accessibilityHidden(true)
        }
    }
}

/// 可申请的一张横卡：和可立即播放的同一张（剧照、小海报、字标、片名、一行灰字），右边那颗胶囊是请求的状态
private struct RequestableCard: View {
    let item: CatalogItem
    let width: CGFloat
    let slot: String

    var body: some View {
        let art = CatalogArt.shared.art(item)
        let state = CatalogRequestState(item)
        ZoomLink(route: .catalog(item.catalogTitle), slot: slot) {
            YearTrailerCard(still: TMDBImage.url(art?.backdrop, "w1280"), cover: TMDBImage.url(item.poster, "w185"),
                            logo: TMDBImage.url(art?.logo, "w500"), title: item.title,
                            subtitle: CatalogRequestState.line(item, art: art), width: width,
                            fallback: TMDBImage.url(item.poster, "w185"), badge: state.badge, progress: state.progress)
        }
        .accessibilityIdentifier("all-films-request")
        .onAppear { CatalogArt.shared.want(item) }
        .contextMenu { CatalogRequestMenu(item: item, state: state) }
    }
}

/// 可申请那一部现在的请求状态：这里的横卡、分类页（FilmCategoryPage）的大卡同一条规矩
@MainActor
struct CatalogRequestState {
    /// 请求的进度；取消了的当没请求过（和详情页一样）
    let status: RequestStatus?
    /// 放进了请求中心就是「已加入」：上一次取消了、没能添加的也一样（长按放进去的正是这两种）
    let queued: Bool

    init(_ item: CatalogItem) {
        let raw = RequestStore.shared.anyStatus(src: item.src, id: item.id) ?? item.req
        status = raw?.state == .cancelled ? nil : raw
        queued = RequestBasket.shared.containsAny(src: item.src, id: item.id)
    }

    /// 进行中、已就绪的照写；其余（没请求过、取消了、没能添加）放进了请求中心就是「已加入」
    var badge: YearCardBadge {
        if let s = status, s.state == .done { return YearCardBadge(text: "已就绪", tone: .plain) }
        if let s = status, s.state == .active { return YearCardBadge(text: s.stage == "release" ? "发行审批" : "已请求 \(s.pct)%", tone: .plain) }
        if queued { return YearCardBadge(text: "已加入", tone: .plain) }
        if status?.state == .failed { return YearCardBadge(text: "未能添加", tone: .alert) }
        return YearCardBadge(text: "申请", tone: .accent)
    }

    /// 请求进行中：剧照底边那道细进度
    var progress: Double? {
        status.flatMap { $0.state == .active ? Double($0.pct) / 100 : nil }
    }

    /// 卡上那一行灰字：年份 · 类型（类型还没取到时有评分写评分）
    static func line(_ item: CatalogItem, art: CatalogArt.Art?) -> String {
        DetailText.line([String(item.year.prefix(4)), art?.genre ?? (item.vote ?? 0 >= 1 ? String(format: "★ %.1f", item.vote ?? 0) : nil)])
    }
}

/// 可申请那一部的长按菜单：电影直接放进 / 拿出请求中心（剧集要先在详情页挑季，这里只给「去请求中心」）。
/// state 里取消了的已经当没有
struct CatalogRequestMenu: View {
    let item: CatalogItem
    let state: CatalogRequestState

    var body: some View {
        let basket = RequestBasket.shared
        let st = state.status
        if item.src != "tv" && (st == nil || st?.state == .failed) {
            if basket.contains(item.catalogTitle, season: 0) {
                Button("从请求中心拿掉", systemImage: "minus.circle") {
                    if let i = basket.items.first(where: { $0.kind == .movie && $0.id == item.id }) { basket.remove(i) }
                    Haptics.selection()
                }
            } else {
                Button("加入请求中心", systemImage: "plus.circle") {
                    switch basket.add(item.catalogTitle, season: 0) {
                    case .added, .already: Haptics.success()
                    case .full: Haptics.error()
                    }
                }
                .disabled(basket.items.count >= RequestBasket.limit)
            }
        }
        if state.queued || st != nil {
            Button("前往请求中心", systemImage: "arrow.down.circle") { basket.openCenter = true }
        }
    }
}

/// 还没取到时的横卡（和 YearTrailerCard 一样大：16:9 + 下面那一行）
private struct SkeletonTrailerCard: View {
    let width: CGFloat

    var body: some View {
        let h = (width * 9 / 16).rounded()
        let compact = width < 300
        // 和 YearTrailerCard 一样：剧照到下面那一行 12（那边从 10 改成 12，这里跟着改，加载完卡不跳）
        VStack(alignment: .leading, spacing: 12) {
            RoundedRectangle(cornerRadius: DSRadius.card(width), style: .continuous)
                .fill(DSFill.placeholder)
                .frame(width: width, height: h)
            HStack(spacing: compact ? 10 : 12) {
                RoundedRectangle(cornerRadius: DSRadius.thumb(compact ? 40 : 48), style: .continuous)
                    .fill(DSFill.placeholder)
                    .frame(width: compact ? 40 : 48, height: ((compact ? 40 : 48) * 1.5).rounded())
                VStack(alignment: .leading, spacing: 6) {
                    Capsule().fill(DSFill.placeholder).frame(width: width * 0.36, height: 12)
                    Capsule().fill(DSFill.placeholder).frame(width: width * 0.22, height: 10)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(width: width, alignment: .leading)
        .accessibilityHidden(true)
    }
}

// MARK: - 截图用：演示数据里直接推进「全部影片」（-CuvenAllFilmsPreview YES）

enum AllFilmsPreview {
    static func presentIfRequested(_ model: AppModel) {
        guard DemoData.enabled, UserDefaults.standard.bool(forKey: "CuvenAllFilmsPreview") else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1500))
            model.openRequest = .shelf(.all)
        }
    }
}
