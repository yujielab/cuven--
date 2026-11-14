import SwiftUI

// MARK: - 某一年（首页「2026 ›」进来）
//
// 系统大标题「2026 年」、副标题「N 部影片」（C13；iOS 26 的 navigationSubtitle），下面一张海报网格（T23）：
// 电影和剧集一起，最新入库的在前；卡上只有画面（纯净画面 + 字标），卡下不写字（T20、F80）。
// 「播放 / 想看」在长按菜单里（C21、C43、C45）。

struct YearView: View {
    @Environment(AppModel.self) private var model
    let year: Int

    var body: some View {
        let entries = model.homeYear(year)
        let movies = entries.filter { if case .movie = $0 { return true } else { return false } }.count
        GeometryReader { geo in
            let metrics = DSMetrics(width: geo.size.width)
            ScrollView {
                if entries.isEmpty {
                    ContentUnavailableView("这一年还没有影片", systemImage: "film",
                                           description: Text("片库里加入这一年的电影或剧集后，会出现在这里。"))
                        .padding(.top, 60)
                } else {
                    EntryGrid(entries: entries, metrics: metrics, slot: "year-\(year)", movieID: "year-movie", seriesID: "year-series")
                        .padding(.top, 8)
                        .padding(.bottom, 40)
                }
            }
            .scrollIndicators(.hidden)
        }
        .background(Theme.bg)
        .navigationTitle(Text(verbatim: "\(year) 年"))
        .navigationSubtitle(Self.subtitle(movies: movies, series: entries.count - movies))
        .navigationBarTitleDisplayMode(.large)
    }

    /// 「12 部影片」；有剧集时「12 部电影、2 部剧集」
    static func subtitle(movies: Int, series: Int) -> String {
        if movies == 0 && series == 0 { return "" }
        if series == 0 { return "\(movies) 部影片" }
        if movies == 0 { return "\(series) 部剧集" }
        return "\(movies) 部电影、\(series) 部剧集"
    }
}
