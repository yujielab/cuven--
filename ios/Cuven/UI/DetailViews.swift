import SwiftUI

// MARK: - 某一年（首页「2026 ›」进来）
//
// 系统大标题「2026 年」、副标题「N 部影片」（C13；iOS 26 的 navigationSubtitle），下面一张系统列表（C29、C31）：
// 一行一部——前面竖版小海报，片名与一行灰字，行尾系统的「›」进详情（系统推入：F53）。
// 「播放 / 想看」在长按菜单里（C21、C43、C45），不再有行尾「…」、自绘的底部弹层和提示条。
// 电影和剧集都有时才分两节、带节标题（只有一类时标题是多余的字：F84）。

struct YearView: View {
    @Environment(AppModel.self) private var model
    let year: Int

    var body: some View {
        let movies = model.movies(inYear: year).sorted { model.title($0).localizedCompare(model.title($1)) == .orderedAscending }
        let series = model.seriesInYear(year)
        List {
            if !movies.isEmpty && !series.isEmpty {
                Section { movieRows(movies) } header: { header("电影") }
                Section { seriesRows(series) } header: { header("剧集") }
            } else {
                movieRows(movies)
                seriesRows(series)
            }
        }
        .listStyle(.plain)
        .overlay {
            if movies.isEmpty && series.isEmpty {
                ContentUnavailableView("这一年还没有影片", systemImage: "film",
                                       description: Text("片库里加入这一年的电影或剧集后，会出现在这里。"))
            }
        }
        .navigationTitle(Text(verbatim: "\(year) 年"))
        .navigationSubtitle(Self.subtitle(movies: movies.count, series: series.count))
        .navigationBarTitleDisplayMode(.large)
    }

    /// 「12 部影片」；有剧集时「12 部电影、2 部剧集」
    static func subtitle(movies: Int, series: Int) -> String {
        if movies == 0 && series == 0 { return "" }
        if series == 0 { return "\(movies) 部影片" }
        if movies == 0 { return "\(series) 部剧集" }
        return "\(movies) 部电影、\(series) 部剧集"
    }

    /// 同一年，灰字里不再重复年份：电影写类型，剧集写类型与集数
    private func movieRows(_ list: [Video]) -> some View {
        ForEach(list) { v in
            LibraryMovieRow(video: v, subtitle: LibraryMovieRow.genres(model.meta(v)) ?? "电影", identifier: "year-movie")
        }
    }

    private func seriesRows(_ list: [Series]) -> some View {
        ForEach(list) { s in
            LibrarySeriesRow(series: s, showYear: false, identifier: "year-series")
        }
    }

    /// 节标题：Title 3 半粗（F15、F19），不全大写（F86）
    private func header(_ title: String) -> some View {
        Text(title)
            .font(.title3.weight(.semibold))
            .foregroundStyle(.primary)
            .textCase(nil)
            .accessibilityAddTraits(.isHeader)
    }
}
