import SwiftUI

// MARK: - 全部影片（主页结尾「查看全部影片 ›」、搜索没结果时「浏览所有影片」）
//
// 用户要求：「设计查看全部影片页面，全面放开片库；按照主页年份分类从 2026 年 → 2020 年，电视剧和电影分开，
// 可以申请和可以立即播放的分开，样式可以和主页中的年份分类一致，可以微调和优化布局」。
//
// 版式（干净、克制）：
// · 大标题「全部影片」，下面一枚分段控件：「可立即播放」（片库里的，按下去就放）/「可申请」（影片库索引里有、片库里还没有的，
//   点开是「请求添加」的详情页）。两边各是一整页，互不混在一起
// · 往下按年份一节一节：2026、2025 … 2020（今年往前数七年）。每一节的标题和主页年份那两排同一个样子（大一级的「2026 ›」+ 一行灰字，
//   点进年份页），灰字写这一年有几部电影、几部剧集
// · 每一节里电影一排、剧集一排（小标题「电影 · 12」「剧集 · 5」），没有的那排不出、两排都没有的年份整节不出
// · 可立即播放：卡和主页年份那两排同一张（YearTrailerCard：上面剧照，下面小海报 + 字标 + 片名 + 一行灰字）；
//   全面放开：主页那两排只放有字标的，这里片库里这一年的全部都放（没字标的就是片名），剧集还没取到资料的先取
// · 可申请（用户要求「布局和 UI 和可立即播放的一致，2026 至 2020 年影片库里的全部」）：同一张横卡，剧照、字标按 TMDB 编号
//   一排一次取（CatalogArt）；右边那颗胶囊是请求的状态（申请 / 已加入 / 已请求 42% / 已就绪），请求进行中剧照底边一道进度线；
//   长按电影可以直接放进请求中心。一打开页面就用 /app/years 一次问完七年 × 电影 / 剧集的第一页（tj 2.8；老版本一年一年问），
//   本机存着上次的，再打开先有画面再更新；一排滑到头再取下一页
// 一节就是一个懒加载的块：几百部片也只建看得到的那几排。

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
                LazyVStack(alignment: .leading, spacing: m.shelfGap + 8, pinnedViews: []) {
                    picker(m)
                    ForEach(years, id: \.self) { y in
                        switch mode {
                        case .playable: PlayableYear(year: y, metrics: m)
                        case .requestable: RequestableYear(year: y, metrics: m, catalog: catalog)
                        }
                    }
                    .id(mode)
                }
                .padding(.top, 4)
                .padding(.bottom, 48)
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
        .navigationTitle("全部影片")
        .navigationBarTitleDisplayMode(.large)
        .sensoryFeedback(.selection, trigger: mode)
    }

    /// 两边分开：可立即播放 / 可申请（系统的分段控件，iOS 26 上是一枚玻璃）
    private func picker(_ m: DSMetrics) -> some View {
        Picker("显示", selection: $mode) {
            ForEach(Mode.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: m.wide ? 420 : .infinity)
        .padding(.horizontal, m.margin)
        .accessibilityIdentifier("all-films-mode")
    }
}

// MARK: - 年份那一节的标题（和主页年份那两排同一个部件，点进年份页）

private struct YearHeader: View {
    let year: Int
    let subtitle: String
    let metrics: DSMetrics
    var link = true

    var body: some View {
        let label = DSSectionLabel(title: String(year), subtitle: subtitle, chevron: link, showcase: true, wide: metrics.wide)
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

/// 一节里的小标题：「电影 · 12」
private struct KindLabel: View {
    let title: String
    let count: Int?
    let metrics: DSMetrics

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.white)
            if let count {
                Text("\(count)")
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(DSInk.tertiary)
            }
        }
        .padding(.horizontal, metrics.margin)
        .accessibilityElement(children: .combine)
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
                YearHeader(year: year, subtitle: Self.line(movies.count, shows.count), metrics: metrics)
                if !movies.isEmpty {
                    VStack(alignment: .leading, spacing: metrics.titleGap) {
                        KindLabel(title: "电影", count: movies.count, metrics: metrics)
                        DSShelf(metrics: metrics) {
                            ForEach(movies, id: \.path) { v in movieCard(v) }
                        }
                    }
                }
                if !shows.isEmpty {
                    VStack(alignment: .leading, spacing: metrics.titleGap) {
                        KindLabel(title: "剧集", count: shows.count, metrics: metrics)
                        DSShelf(metrics: metrics) {
                            ForEach(shows, id: \.path) { s in seriesCard(s) }
                        }
                    }
                }
            }
        }
    }

    static func line(_ m: Int, _ s: Int) -> String {
        [m > 0 ? "\(m) 部电影" : nil, s > 0 ? "\(s) 部剧集" : nil].compactMap { $0 }.joined(separator: " · ")
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

    struct Key: Hashable { var year: Int; var src: String }
    struct Page {
        var items: [CatalogItem] = []
        var next = 1
        /// 影片库说一共几部（老版本的请求添加 Worker 不认年份：0 = 不知道）
        var total = 0
        var pages = 0
        var done = false
        var loading = false
        var failed = false
        /// 问过第一页了（/app/years 一次问完，或者一年一年问）
        var started = false
    }

    private(set) var pages: [Key: Page] = [:]
    /// 第一轮在问（/app/years 或一年一年问第一页）
    private(set) var prefetching = false

    @ObservationIgnored private var etag: String?
    @ObservationIgnored private var fetchedAt: Date?
    /// 请求添加 Worker 还是老版本（没有 /app/years、不认年份）
    @ObservationIgnored private var oldServer = false
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
        if !oldServer {
            do {
                let r = try await RequestAPI.years(from: lo, to: hi, per: 24, etag: pages.isEmpty ? nil : etag)
                if r.old {
                    oldServer = true
                } else {
                    if let p = r.page { apply(p, years: years, replace: true) }
                    if let data = r.data {
                        let url = Self.file
                        Task.detached(priority: .utility) { try? data.write(to: url, options: .atomic) }
                    }
                    etag = r.etag
                    UserDefaults.standard.set(r.etag, forKey: Self.etagKey)
                    fetchedAt = Date()
                    return
                }
            } catch {
                // 网络不好：一年一年问（每一格各自出错、各自重试）
            }
        }
        let keys = years.flatMap { y in ["movie", "tv"].map { Key(year: y, src: $0) } }.filter { !page($0).started || page($0).failed }
        await withTaskGroup(of: Void.self) { g in
            var i = 0
            func add() {
                guard i < keys.count else { return }
                let k = keys[i]
                i += 1
                g.addTask { await self.loadMore(k, first: true) }
            }
            for _ in 0..<4 { add() }
            while await g.next() != nil { add() }
        }
        // 有一格没问成：下次打开（或滑到那一节）再问，不等 5 分钟
        if !keys.contains(where: { page($0).failed }) { fetchedAt = Date() }
    }

    /// 上次 /app/years 的回包（冷启动先有画面，再拿 ETag 问一次：没变就是 304）
    private func restore(_ years: [Int]) {
        guard !restored else { return }
        restored = true
        guard pages.isEmpty, let data = try? Data(contentsOf: Self.file),
              let p = try? JSONDecoder().decode(RequestAPI.YearsPage.self, from: data) else { return }
        etag = UserDefaults.standard.string(forKey: Self.etagKey)
        apply(p, years: years, replace: false)
    }

    private func apply(_ p: RequestAPI.YearsPage, years: [Int], replace: Bool) {
        for y in years {
            for s in ["movie", "tv"] {
                let k = Key(year: y, src: s)
                guard let cell = p.years[y]?[s] else { continue }
                let old = page(k)
                // 已经往后翻过页的那一排不打断（等下次打开再换）
                if old.next > 2 && !replace { continue }
                if old.next > 2 && old.items.count > cell.items.count { continue }
                var n = Page()
                n.items = cell.items.filter { Int($0.year.prefix(4)) == y || $0.year.isEmpty }
                n.total = cell.total
                n.pages = cell.pages
                n.next = 2
                n.started = true
                n.failed = cell.failed
                n.done = !cell.failed && (cell.items.isEmpty || cell.page >= cell.pages)
                pages[k] = n
                for i in cell.items { if let r = i.req { RequestStore.shared.merge(r) } }
            }
        }
    }

    /// 取下一页（同一份同时只取一次）。服务器还是老版本、不认年份：按年份在这里过滤，取到够一排为止（最多翻 4 页）
    func loadMore(_ k: Key, first: Bool = false) async {
        var p = page(k)
        guard !p.loading, !p.done else { return }
        if first && p.started && !p.failed { return }
        p.loading = true
        p.failed = false
        pages[k] = p
        var got: [CatalogItem] = []
        var tries = 0
        repeat {
            do {
                let r = try await RequestAPI.catalogPage(src: k.src, sort: "new", own: "hide", page: p.next, year: k.year)
                p.next += 1
                let mine = r.items.filter { Int($0.year.prefix(4)) == k.year }
                // 回来的都是这一年的：服务器认年份，总数、页数可信
                if !r.items.isEmpty && mine.count == r.items.count {
                    p.total = r.total
                    p.pages = r.pages
                } else if !r.items.isEmpty {
                    oldServer = true
                }
                got += mine
                for i in r.items { if let s = i.req { RequestStore.shared.merge(s) } }
                if r.items.isEmpty || (r.pages > 0 && p.next > r.pages) { p.done = true; break }
            } catch {
                p.failed = true
                break
            }
            tries += 1
        } while oldServer && got.count < 8 && tries < 4 && !p.done
        let seen = Set(p.items.map(\.uid))
        p.items += got.filter { !seen.contains($0.uid) }
        p.started = true
        p.loading = false
        pages[k] = p
    }

    private static func demo(_ k: Key) -> Page {
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
        Group {
            if !movies.isEmpty || !series.isEmpty || !settled {
                VStack(alignment: .leading, spacing: metrics.titleGap + 6) {
                    YearHeader(year: year, subtitle: settled ? Self.line(mp, tp, movies.count, series.count) : "正在查询…",
                               metrics: metrics, link: false)
                    row("电影", key: mk, page: mp, items: movies)
                    row("剧集", key: tk, page: tp, items: series)
                }
            }
        }
        // 第一轮（/app/years）没给到这一格的（网络不好、老版本）：滑到这一节、或者第一轮问完了再问一次
        .task(id: "\(year)-\(catalog.prefetching)") {
            guard !catalog.prefetching else { return }
            async let a: Void = catalog.loadMore(mk, first: true)
            async let b: Void = catalog.loadMore(tk, first: true)
            _ = await (a, b)
        }
    }

    /// 「128 部电影 · 54 部剧集」：影片库给了总数就用总数，没给（老版本）就是这里已经有的
    static func line(_ mp: CatalogYears.Page, _ tp: CatalogYears.Page, _ m: Int, _ s: Int) -> String {
        let mc = mp.total > 0 ? max(mp.total, m) : m, sc = tp.total > 0 ? max(tp.total, s) : s
        let parts = [mc > 0 ? "\(mc) 部电影" : nil, sc > 0 ? "\(sc) 部剧集" : nil].compactMap { $0 }
        return parts.isEmpty ? "片库里还没有、可以申请添加的" : parts.joined(separator: " · ") + " 可申请"
    }

    @ViewBuilder
    private func row(_ title: String, key: CatalogYears.Key, page p: CatalogYears.Page, items: [CatalogItem]) -> some View {
        let w = metrics.trailerCardWidth
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: metrics.titleGap) {
                KindLabel(title: title, count: p.total > 0 ? max(p.total, items.count) : items.count, metrics: metrics)
                DSShelf(metrics: metrics) {
                    ForEach(items, id: \.uid) { it in
                        RequestableCard(item: it, width: w, slot: "all-request-\(year)")
                            // 滑到这一排最后几张：取下一页
                            .onAppear {
                                if items.suffix(3).contains(where: { $0.uid == it.uid }), !catalog.page(key).done {
                                    Task { await catalog.loadMore(key) }
                                }
                            }
                    }
                    if p.loading { SkeletonTrailerCard(width: w) }
                }
            }
        } else if !p.started {
            VStack(alignment: .leading, spacing: metrics.titleGap) {
                KindLabel(title: title, count: nil, metrics: metrics)
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
        let st = RequestStore.shared.anyStatus(src: item.src, id: item.id) ?? item.req
        let queued = st == nil && RequestBasket.shared.containsAny(src: item.src, id: item.id)
        let sub = DetailText.line([String(item.year.prefix(4)), art?.genre ?? (item.vote ?? 0 >= 1 ? String(format: "★ %.1f", item.vote ?? 0) : nil)])
        ZoomLink(route: .catalog(item.catalogTitle), slot: slot) {
            YearTrailerCard(still: TMDBImage.url(art?.backdrop, "w1280"), cover: TMDBImage.url(item.poster, "w185"),
                            logo: TMDBImage.url(art?.logo, "w500"), title: item.title, subtitle: sub, width: width,
                            fallback: TMDBImage.url(item.poster, "w185"), badge: Self.badge(st, queued: queued),
                            progress: st.flatMap { $0.state == .active ? Double($0.pct) / 100 : nil })
        }
        .accessibilityIdentifier("all-films-request")
        .onAppear { CatalogArt.shared.want(item) }
        .contextMenu { menu(st, queued: queued) }
    }

    static func badge(_ s: RequestStatus?, queued: Bool) -> YearCardBadge {
        if let s {
            switch s.state {
            case .done: return YearCardBadge(text: "已就绪", tone: .plain)
            case .failed: return YearCardBadge(text: "未能添加", tone: .alert)
            case .active: return YearCardBadge(text: s.stage == "release" ? "发行审批" : "已请求 \(s.pct)%", tone: .plain)
            case .cancelled: break
            }
        }
        return queued ? YearCardBadge(text: "已加入", tone: .plain) : YearCardBadge(text: "申请", tone: .accent)
    }

    /// 长按：电影直接放进 / 拿出请求中心（剧集要先在详情页挑季，这里只给「去请求中心」）
    @ViewBuilder
    private func menu(_ st: RequestStatus?, queued: Bool) -> some View {
        let basket = RequestBasket.shared
        if item.src != "tv" && (st == nil || st?.state == .cancelled || st?.state == .failed) {
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
        if queued || st != nil {
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
        VStack(alignment: .leading, spacing: 10) {
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
