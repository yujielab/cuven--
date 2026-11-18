import SwiftUI

// MARK: - 某一年（首页「2026 ›」进来）
//
// 系统大标题「2026 年」，下面一张海报网格（T23）。不写「N 部影片」这类计数（用户要求全局去掉影片计数）：
// 电影和剧集一起，最新入库的在前；卡上只有画面（纯净画面 + 字标），卡下不写字（T20、F80）。
// 「播放 / 想看」在长按菜单里（C21、C43、C45）。

struct YearView: View {
    @Environment(AppModel.self) private var model
    let year: Int

    var body: some View {
        let entries = model.homeYear(year)
        GeometryReader { geo in
            let insets = geo.safeAreaInsets
            let metrics = DSMetrics(width: geo.size.width, leadingInset: insets.leading, trailingInset: insets.trailing, height: geo.size.height)
            ScrollView {
                if entries.isEmpty {
                    ContentUnavailableView("暂无影片", systemImage: "film",
                                           description: Text("这一年的电影和剧集会显示在这里。"))
                        .padding(.top, 60)
                } else {
                    EntryGrid(entries: entries, metrics: metrics, slot: "year-\(year)", movieID: "year-movie", seriesID: "year-series")
                        .padding(.top, 8)
                        .padding(.bottom, 40)
                        .padding(.leading, insets.leading)
                        .padding(.trailing, insets.trailing)
                }
            }
            .scrollIndicators(.hidden)
            // 整页铺满（连同侧边那一列），网格留在安全区里
            .ignoresSafeArea(edges: .horizontal)
        }
        .background(Theme.bg)
        .navigationTitle(Text(verbatim: "\(year) 年"))
        .navigationBarTitleDisplayMode(.large)
    }
}
