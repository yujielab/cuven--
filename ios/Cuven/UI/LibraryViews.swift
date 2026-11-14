import SwiftUI

// MARK: - 资料库、搜索、年份页、文件夹页、整页清单共用的部件（资料库本身见 LibraryShowcase.swift）
//
// 依据（编号见 docs/ios-design.md）：
// · 只用系统的标准网格与列表（T23、C20、C29），不做花样版式；
// · 每排张数、边距、卡间距都跟设计系统 DSMetrics（S3、S5、S6），折起和展开是同一套设计长大（S1、D2）；
// · 字一律用系统文字样式，层级靠字重和 .secondary（F15、F18）；不画描边、不垫底板，分组只靠留白（F3、F12）；
// · 点开是系统的推入 / 缩放转场（F53），更多操作在长按菜单里（C21、C43）。

// MARK: 海报网格

/// 海报网格（T23、C20：标准网格；每行 3 / 4 / 6 张：DSMetrics.gridColumns）。电影和剧集都能放（HomeEntry）。
/// 卡上只有画面（纯净画面 + 字标，或印着片名的海报），卡下不写字（T20、F80）；看了一半的底部一条细进度（F36）
struct EntryGrid: View {
    @Environment(AppModel.self) private var model
    let entries: [HomeEntry]
    let metrics: DSMetrics
    /// 缩放转场的来源（同一部片可能也在别的排里，各算各的）
    var slot = "grid"
    var movieID = "grid-movie"
    var seriesID = "grid-series"

    var body: some View {
        let n = metrics.gridColumns()
        let w = max(40, metrics.gridCardWidth())
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(w), spacing: metrics.gutter, alignment: .top), count: n),
                  alignment: .leading, spacing: metrics.gutter + 6) {
            ForEach(entries) { e in cell(e, width: w) }
        }
        .padding(.horizontal, metrics.margin)
    }

    @ViewBuilder private func cell(_ e: HomeEntry, width w: CGFloat) -> some View {
        switch e {
        case .movie(let v):
            let art = model.posterArt(v, width: w)
            ZoomLink(route: .movie(v), slot: slot) {
                LibraryGridCard(art: art.url, title: model.title(v), subtitle: model.year(v).map { String($0) },
                                width: w, progress: model.playback.entry(v.path)?.fraction, logo: art.logo)
            }
            .accessibilityIdentifier(movieID)
            .movieMenu(v)
        case .series(let s):
            let art = model.seriesPosterArt(s, width: w)
            ZoomLink(route: .series(s), slot: slot) {
                LibraryGridCard(art: art.url, title: model.seriesMetas[s.path]?.title ?? s.name, subtitle: s.seasonLabel,
                                width: w, logo: art.logo)
            }
            .accessibilityIdentifier(seriesID)
            .seriesMenu(s)
            .task { await model.ensureSeriesMeta(s) }
        }
    }
}

/// 只有电影的网格（文件夹页、搜索页的最近添加）
struct LibraryGrid: View {
    let videos: [Video]
    let metrics: DSMetrics
    var slot = "grid"
    var identifier = "grid-movie"

    var body: some View {
        EntryGrid(entries: videos.map { .movie($0) }, metrics: metrics, slot: slot, movieID: identifier)
    }
}

/// 网格里的一张：2:3 海报，圆角 12（和 DSPosterLockup 同一个样子）。logo：画面没有片名时压在下面的字标。
/// 片名和年份只给旁白（F75）
struct LibraryGridCard: View {
    let art: URL?
    let title: String
    var subtitle: String? = nil
    let width: CGFloat
    var progress: Double? = nil
    var logo: URL? = nil

    var body: some View {
        let h = (width * 1.5).rounded()
        Color(white: 0.11)
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
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel([title, subtitle].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "，"))
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
// 没输入：「文件夹」一排（片库根下一级）和「最近添加」海报网格（C61：搜索页先给能浏览的东西）。
// 输入了：按类型分区，每区一排同样的海报（C63：最相关的那一类在上，区内按相关度）；卡上只有画面，卡下不写字（T20）。

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

    /// 没输入：文件夹（片库根下一级，有才有）和最近入库的 12 部（每行 3 / 4 / 6 张都正好排满）
    @ViewBuilder private func landing(_ metrics: DSMetrics) -> some View {
        let recent = Array(model.movies.sorted { $0.addedKey > $1.addedKey }.prefix(12))
        if recent.isEmpty && model.folders.isEmpty {
            // F88：空的时候告诉人下一步
            ContentUnavailableView("搜索电影、剧集", systemImage: "magnifyingglass",
                                   description: Text("输入片名或年份，结果会随着输入出现。"))
                .padding(.top, 60)
        } else {
            VStack(alignment: .leading, spacing: metrics.shelfGap) {
                if !model.folders.isEmpty {
                    DSSection(title: "文件夹", metrics: metrics) {
                        DSShelf(metrics: metrics) {
                            ForEach(model.folders) { f in
                                ZoomLink(route: .folder(f), slot: "search-folder") {
                                    FolderCard(folder: f, width: metrics.posterWidth)
                                }
                                .accessibilityIdentifier("folder-card")
                            }
                        }
                    }
                }
                if !recent.isEmpty {
                    VStack(alignment: .leading, spacing: metrics.titleGap) {
                        DSShelfTitle(title: "最近添加", metrics: metrics)
                        LibraryGrid(videos: recent, metrics: metrics, slot: "search-recent", identifier: "search-movie")
                    }
                }
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
            // 分区之间只靠留白（F3）
            VStack(alignment: .leading, spacing: metrics.shelfGap) {
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

    /// 电影：海报一排（纯净画面 + 字标，卡下不写字：T20）
    @ViewBuilder private func moviesSection(_ list: [Video], _ metrics: DSMetrics) -> some View {
        if !list.isEmpty {
            DSSection(title: "电影", metrics: metrics) {
                DSShelf(metrics: metrics) {
                    ForEach(list) { v in
                        let art = model.posterArt(v, width: metrics.posterWidth)
                        ZoomLink(route: .movie(v), slot: "search-movie") {
                            DSPosterLockup(art: art.url, title: model.title(v), subtitle: model.year(v).map { String($0) },
                                           metrics: metrics, logo: art.logo)
                        }
                        .accessibilityIdentifier("search-movie")
                        .movieMenu(v)
                    }
                }
            }
        }
    }

    /// 剧集：同样的海报一排（纯净海报 + 字标）
    @ViewBuilder private func showsSection(_ list: [Series], _ metrics: DSMetrics) -> some View {
        if !list.isEmpty {
            DSSection(title: "剧集", metrics: metrics) {
                DSShelf(metrics: metrics) {
                    ForEach(list) { s in
                        let art = model.seriesPosterArt(s, width: metrics.posterWidth)
                        ZoomLink(route: .series(s), slot: "search-series") {
                            DSPosterLockup(art: art.url, title: model.seriesMetas[s.path]?.title ?? s.name, subtitle: s.seasonLabel,
                                           metrics: metrics, logo: art.logo)
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
