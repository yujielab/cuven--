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
// · 可申请：卡和主页「可请求添加」那一排同一张（竖版海报 + 片名，带请求进度 / 已加入的小标签）；一节一节滑到了才去问，
//   一排滑到头再取下一页
// 一节就是一个懒加载的块：几百部片也只建看得到的那几排。

struct AllFilmsView: View {
    @Environment(AppModel.self) private var model

    enum Mode: String, CaseIterable, Identifiable {
        case playable, requestable
        var id: String { rawValue }
        var title: String { self == .playable ? "可立即播放" : "可申请" }
    }

    @State private var mode: Mode = .playable
    @State private var catalog = CatalogYears()

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

/// 每一年、电影 / 剧集各一份：已经取到的几页，滑到头再取下一页
@MainActor
@Observable
final class CatalogYears {
    struct Key: Hashable { var year: Int; var src: String }
    struct Page {
        var items: [CatalogItem] = []
        var next = 1
        var done = false
        var loading = false
        var failed = false
    }

    private(set) var pages: [Key: Page] = [:]

    func page(_ k: Key) -> Page { pages[k] ?? Page() }

    /// 取下一页（同一份同时只取一次）；服务器还是老版本、不认 year：按年份在这里过滤，取到够一排为止（最多翻 4 页）
    func loadMore(_ k: Key) async {
        var p = page(k)
        guard !p.loading, !p.done else { return }
        p.loading = true
        p.failed = false
        pages[k] = p
        if DemoData.enabled {
            p.items = Self.demo(k)
            p.done = true
            p.loading = false
            pages[k] = p
            return
        }
        var got: [CatalogItem] = []
        var tries = 0
        repeat {
            do {
                let list = try await RequestAPI.catalog(src: k.src, sort: "new", own: "hide", page: p.next, year: k.year)
                p.next += 1
                if list.isEmpty { p.done = true; break }
                got += list.filter { Int($0.year.prefix(4)) == k.year }
                for i in list { if let r = i.req { RequestStore.shared.merge(r) } }
            } catch {
                p.failed = true
                break
            }
            tries += 1
        } while got.count < 8 && tries < 4 && !p.done
        let seen = Set(p.items.map(\.uid))
        p.items += got.filter { !seen.contains($0.uid) }
        p.loading = false
        pages[k] = p
    }

    private static func demo(_ k: Key) -> [CatalogItem] {
        let names = k.src == "movie" ? ["潮汐之间", "风的形状", "远航者", "无名之城", "第二个夏天"] : ["夜航", "回声镇", "长街"]
        return names.enumerated().map { i, n in
            CatalogItem(demo: 7000 + k.year % 100 * 10 + i + (k.src == "tv" ? 500 : 0), src: k.src, title: n,
                        year: String(k.year), poster: "demo://poster/\(9 + (i + k.year) % 6)")
        }
    }
}

private struct RequestableYear: View {
    @Environment(AppModel.self) private var model
    let year: Int
    let metrics: DSMetrics
    let catalog: CatalogYears

    var body: some View {
        let mk = CatalogYears.Key(year: year, src: "movie"), tk = CatalogYears.Key(year: year, src: "tv")
        let owned = model.ownedMovieIDs, shows = model.ownedSeasons
        let movies = catalog.page(mk).items.filter { !model.owns($0, movies: owned, shows: shows) }
        let series = catalog.page(tk).items.filter { !model.owns($0, movies: owned, shows: shows) }
        let settled = (catalog.page(mk).done || !catalog.page(mk).items.isEmpty || catalog.page(mk).failed)
            && (catalog.page(tk).done || !catalog.page(tk).items.isEmpty || catalog.page(tk).failed)
        Group {
            if !movies.isEmpty || !series.isEmpty || !settled {
                VStack(alignment: .leading, spacing: metrics.titleGap + 6) {
                    YearHeader(year: year, subtitle: settled ? "片库里还没有、可以申请添加的" : "正在查询…", metrics: metrics, link: false)
                    row("电影", key: mk, items: movies)
                    row("剧集", key: tk, items: series)
                }
            }
        }
        // 滑到这一节才去问（两排各取第一页）
        .task(id: year) {
            async let a: Void = catalog.loadMore(mk)
            async let b: Void = catalog.loadMore(tk)
            _ = await (a, b)
        }
    }

    @ViewBuilder
    private func row(_ title: String, key: CatalogYears.Key, items: [CatalogItem]) -> some View {
        let p = catalog.page(key)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: metrics.titleGap) {
                KindLabel(title: title, count: nil, metrics: metrics)
                DSShelf(metrics: metrics) {
                    ForEach(items, id: \.uid) { it in
                        CatalogPosterLink(item: it, metrics: metrics, slot: "all-request-\(year)")
                            // 滑到这一排最后几张：取下一页
                            .onAppear {
                                if it.uid == items.last?.uid, !catalog.page(key).done { Task { await catalog.loadMore(key) } }
                            }
                    }
                    if p.loading {
                        ProgressView()
                            .frame(width: metrics.posterWidth, height: metrics.posterWidth * 1.5)
                    }
                }
            }
        } else if p.loading && p.items.isEmpty {
            VStack(alignment: .leading, spacing: metrics.titleGap) {
                KindLabel(title: title, count: nil, metrics: metrics)
                DSShelf(metrics: metrics) {
                    ForEach(0..<4, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: DSRadius.card(metrics.posterWidth), style: .continuous)
                            .fill(DSFill.placeholder)
                            .frame(width: metrics.posterWidth, height: (metrics.posterWidth * 1.5).rounded())
                    }
                }
            }
            .accessibilityHidden(true)
        }
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
