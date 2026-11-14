import SwiftUI

// MARK: - 资料库、搜索、年份页、文件夹页、整页清单共用的部件（资料库本身见 LibraryShowcase.swift）
//
// 依据（编号见 docs/ios-design.md）：
// · 只用系统的标准网格与列表（T23、C20、C29），不做花样版式；
// · 每排张数、边距、卡间距都跟设计系统 DSMetrics（S3、S5、S6），折起和展开是同一套设计长大（S1、D2）；
// · 字一律用系统文字样式，层级靠字重和 .secondary（F15、F18）；不画描边、不垫底板，分组只靠留白（F3、F12）；
// · 点开是系统的推入 / 缩放转场（F53），更多操作在长按菜单里（C21、C43）。

// MARK: 海报网格

/// 海报网格（T23、C20：标准网格；S6：每排张数跟 DSMetrics——折起 3、展开竖拿 4、展开横拿 6）。
/// 网格不在横排里，没有左侧基准线，也就没有「焦点」那一张：卡下的字一直显示（T20 的「聚焦才出字」只用在横排）
struct LibraryGrid: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    let videos: [Video]
    let metrics: DSMetrics
    /// 缩放转场的来源（同一部片可能也在别的排里，各算各的）
    var slot = "grid"
    var identifier = "grid-movie"

    /// 每排几张：与 DSMetrics.posterWidth 同一组分档（S6）；大字号时少放一张，字才放得下（S4）
    static func columns(_ m: DSMetrics, large: Bool) -> Int {
        let n = m.width < 500 ? 3 : (m.width < 800 ? 4 : 6)
        return large ? max(2, n - 1) : n
    }

    var body: some View {
        let n = Self.columns(metrics, large: typeSize.isAccessibilitySize)
        let w = max(40, metrics.cardWidth(columns: n))
        // 行距：T24 网格的竖向间距至少 100，按 S5 缩到当前宽度，至少 24（卡下还有两行字）
        let rowGap = max(24, (metrics.width * 100 / 1920).rounded())
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(w), spacing: metrics.gutter, alignment: .top), count: n),
                  alignment: .leading, spacing: rowGap) {
            ForEach(videos) { v in
                // 画面：Apple TV 优先（带片名的海报，或无字的竖版主视觉 + 字标），TMDB 兜底
                let art = model.posterArt(v, width: w)
                ZoomLink(route: .movie(v), slot: slot) {
                    LibraryGridCard(art: art.url,
                                    title: model.title(v),
                                    subtitle: model.year(v).map { String($0) },
                                    width: w,
                                    progress: model.playback.entry(v.path)?.fraction,
                                    logo: art.logo)
                }
                .accessibilityIdentifier(identifier)
                .movieMenu(v)
            }
        }
        .padding(.horizontal, metrics.margin)
    }
}

/// 网格里的一张：海报（2:3、圆角 12，和 DSPosterLockup 同一个样子），下面片名与一行灰字（F18）。
/// 看了一半的，海报底部一条细进度（F36：用形状表达，不只靠颜色）。
/// logo：画面是 Apple TV 无字的竖版主视觉时压在下面的字标（DSPosterLogo）
struct LibraryGridCard: View {
    let art: URL?
    let title: String
    var subtitle: String? = nil
    let width: CGFloat
    var progress: Double? = nil
    var logo: URL? = nil

    var body: some View {
        let h = (width * 1.5).rounded()
        VStack(alignment: .leading, spacing: 8) {
            Color(white: 0.12)
                .overlay { RemoteImage(url: art, maxPixel: width * 3, placeholder: .clear) }
                .frame(width: width, height: h)
                .overlay {
                    if let logo { DSPosterLogo(logo: logo, size: CGSize(width: width, height: h), title: title) }
                }
                .overlay(alignment: .bottom) {
                    if let p = progress, p > 0.01 {
                        LibraryProgressBar(fraction: p)
                            .padding(.horizontal, 8)
                            .padding(.bottom, 8)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(subtitle ?? " ")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: width, alignment: .leading)
        }
        .frame(width: width, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([title, subtitle].compactMap { $0 }.joined(separator: "，"))
    }
}

/// 看到哪儿：一条细胶囊（F36）
private struct LibraryProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.3))
                Capsule().fill(.white).frame(width: max(4, g.size.width * min(1, fraction)))
            }
        }
        .frame(height: 4)
    }
}

// MARK: 列表

/// 列表的一行（C29：前面一张小图，后面简短的字）：竖版小海报、片名（Headline）、一行灰字（Subheadline、.secondary：F18）。
/// 放在 List 的 NavigationLink 里，行尾的「›」由系统画（C31）；排行榜的名次在最前面（App Store 排行的写法）
struct LibraryRow: View {
    let art: URL?
    let title: String
    var subtitle: String = ""
    var rank: Int? = nil

    var body: some View {
        HStack(spacing: 14) {
            if let rank {
                Text(verbatim: String(rank))
                    .font(.headline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 22)
            }
            Color(white: 0.12)
                .overlay { RemoteImage(url: art, maxPixel: 200, placeholder: .clear) }
                .frame(width: 46, height: 69)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// 列表里的一部电影：点整行进详情（系统推入：F53），行尾系统的「›」（C31），长按「播放 / 想看」（C21、C43）
struct LibraryMovieRow: View {
    @Environment(AppModel.self) private var model
    let video: Video
    /// 不给就是「2026 · 科幻 · 冒险」
    var subtitle: String? = nil
    var rank: Int? = nil
    var identifier = "list-movie"

    /// 「科幻 · 冒险」：最多两个类型（F84：短）
    static func genres(_ m: Meta?) -> String? {
        let g = (m?.genres ?? []).prefix(2).joined(separator: " · ")
        return g.isEmpty ? nil : g
    }

    var body: some View {
        let m = model.meta(video)
        let line = subtitle ?? [model.year(video).map { String($0) }, Self.genres(m)].compactMap { $0 }.joined(separator: " · ")
        NavigationLink(value: Route.movie(video)) {
            // 小图：Apple TV 优先、TMDB 兜底（行里已经写着片名，不压字标）
            LibraryRow(art: model.thumbArt(video), title: model.title(video),
                       subtitle: line.isEmpty ? "电影" : line, rank: rank)
        }
        .accessibilityIdentifier(identifier)
        .movieMenu(video)
    }
}

/// 列表里的一部剧：第二季起片名后面带「第 n 季」；灰字是年份、类型与集数；长按「想看」
struct LibrarySeriesRow: View {
    @Environment(AppModel.self) private var model
    let series: Series
    var subtitle: String? = nil
    var showYear = true
    var identifier = "list-series"

    static func name(_ s: Series, meta: Meta?) -> String {
        let base = meta?.title.flatMap { $0.isEmpty ? nil : $0 } ?? s.name
        if let n = s.season, n > 1 { return base + " 第 \(n) 季" }
        return base
    }

    var body: some View {
        let m = model.seriesMetas[series.path]
        let line = subtitle ?? [showYear ? series.year : nil, m?.genres?.first, series.countLabel]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        NavigationLink(value: Route.series(series)) {
            LibraryRow(art: TMDBImage.url(m?.poster ?? m?.posterClean, "w185"), title: Self.name(series, meta: m),
                       subtitle: line.isEmpty ? "剧集" : line)
        }
        .accessibilityIdentifier(identifier)
        .seriesMenu(series)
        .task { await model.ensureSeriesMeta(series) }
    }
}

/// 「2 小时前」「昨天」这类相对时间；入库时间是 ISO 8601（有的带毫秒）
enum Relative {
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let plain = ISO8601DateFormatter()

    static func date(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        return fractional.date(from: s) ?? plain.date(from: s)
    }

    static func string(_ d: Date) -> String {
        d.formatted(.relative(presentation: .named))
    }
}

// MARK: - 搜索
//
// 系统大标题与系统搜索栏，提示「电影、剧集、年份」（C13、F90、C62：提示写清能搜什么，边输边出结果）。
// 没输入：「最近添加」海报网格（C61：搜索页先给能浏览的东西）。
// 输入了：按类型分区，每区一排同样的卡——剧集是 16:9 卡、电影是竖版海报（C63：最相关的那一类在上，区内按相关度）；
// 去掉了结果数一行和自绘的大宽卡（F3、F38）。

struct SearchView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""

    var body: some View {
        ZoomStack {
            GeometryReader { geo in
                // 系统栏竖在侧边（iPhone Duo 折起时 / 展开横拿时）：搜索框不挂在底部的标签栏上，得在标题下面一直显示
                let sideBars = abs(geo.safeAreaInsets.leading - geo.safeAreaInsets.trailing) > 30
                content(DSMetrics(width: geo.size.width))
                    .searchable(text: $query, placement: sideBars ? .navigationBarDrawer(displayMode: .always) : .automatic,
                                prompt: "电影、剧集、年份")
            }
            .background(Theme.bg)
            .navigationTitle("搜索")
            // C13：顶层页用大标题，往上滚收成小标题
            .navigationBarTitleDisplayMode(.large)
        }
        // 详情页演员弹层「在资料库中搜索」：把名字填进搜索框
        .onChange(of: model.searchRequest, initial: true) { _, q in
            guard let q else { return }
            query = q
            model.searchRequest = nil
        }
    }

    private func content(_ metrics: DSMetrics) -> some View {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return ScrollView {
            if q.isEmpty {
                landing(metrics)
            } else {
                results(q, metrics)
            }
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.immediately)
        .background(Theme.bg)
    }

    /// 没输入：最近入库的 12 部（每排 3 / 4 / 6 张都正好排满）
    @ViewBuilder private func landing(_ metrics: DSMetrics) -> some View {
        let recent = Array(model.movies.sorted { $0.addedKey > $1.addedKey }.prefix(12))
        if recent.isEmpty {
            // F88：空的时候告诉人下一步
            ContentUnavailableView("搜索电影、剧集", systemImage: "magnifyingglass",
                                   description: Text("输入片名或年份，结果会随着输入出现。"))
                .padding(.top, 60)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                DSShelfTitle(title: "最近添加", metrics: metrics)
                LibraryGrid(videos: recent, metrics: metrics, slot: "search-recent", identifier: "search-movie")
                    .padding(.top, 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
    }

    @ViewBuilder private func results(_ q: String, _ metrics: DSMetrics) -> some View {
        let hits = model.search(q)
        if hits.isEmpty {
            // F87、F88：不怪人，说怎么办
            ContentUnavailableView("没有找到「\(q)」", systemImage: "magnifyingglass",
                                   description: Text("试试别的片名，或输入年份，比如 2026。"))
                .padding(.top, 60)
        } else {
            let movies = hits.compactMap { h -> Video? in if case .movie(let v) = h.kind { return v } else { return nil } }
            let shows = hits.compactMap { h -> Series? in if case .series(let s) = h.kind { return s } else { return nil } }
            // 分区之间只靠留白（F3）：看得见的间距 = DSMetrics.shelfGap（DSShelf 自己上下各留 14 给焦点放大）
            VStack(alignment: .leading, spacing: max(16, metrics.shelfGap - 14)) {
                // C63：最相关的那一条属于哪一类，哪一类在上
                if Self.isSeries(hits[0]) {
                    showsSection(shows, metrics)
                    moviesSection(movies, metrics)
                } else {
                    moviesSection(movies, metrics)
                    showsSection(shows, metrics)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
    }

    private static func isSeries(_ h: AppModel.SearchHit) -> Bool {
        if case .series = h.kind { return true }
        return false
    }

    /// 电影：竖版海报一排（DSPosterLockup：停在左侧基准线上的那张放大、片名浮出：T20、S7–S9）
    @ViewBuilder private func moviesSection(_ list: [Video], _ metrics: DSMetrics) -> some View {
        if !list.isEmpty {
            DSSection(title: "电影", metrics: metrics) {
                DSShelf(metrics: metrics) {
                    ForEach(list) { v in
                        // 画面：Apple TV 优先（海报，或竖版主视觉 + 字标），TMDB 兜底
                        let art = model.posterArt(v, width: metrics.posterWidth)
                        ZoomLink(route: .movie(v), slot: "search-movie") {
                            DSPosterLockup(art: art.url,
                                           title: model.title(v),
                                           subtitle: model.year(v).map { String($0) },
                                           metrics: metrics,
                                           logo: art.logo)
                        }
                        .accessibilityIdentifier("search-movie")
                        .movieMenu(v)
                    }
                }
            }
        }
    }

    /// 剧集：16:9 卡一排（DSWideLockup：剧名与集数一直显示）
    @ViewBuilder private func showsSection(_ list: [Series], _ metrics: DSMetrics) -> some View {
        if !list.isEmpty {
            DSSection(title: "剧集", metrics: metrics) {
                DSShelf(metrics: metrics) {
                    ForEach(list) { s in
                        let meta = model.seriesMetas[s.path]
                        ZoomLink(route: .series(s), slot: "search-series") {
                            DSWideLockup(art: TMDBImage.url(meta?.backdrop ?? meta?.posterClean ?? meta?.poster, "w780"),
                                         title: LibrarySeriesRow.name(s, meta: meta),
                                         subtitle: s.countLabel,
                                         metrics: metrics)
                        }
                        .accessibilityIdentifier("search-series")
                        .seriesMenu(s)
                        .task { await model.ensureSeriesMeta(s) }
                    }
                }
            }
        }
    }
}

// MARK: - 我的

extension Bundle {
    var appVersion: String {
        let v = infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v)（\(b)）"
    }
}
