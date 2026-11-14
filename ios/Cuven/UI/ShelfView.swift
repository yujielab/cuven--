import SwiftUI

// MARK: - 整页清单（主页分区标题「›」进来的，账户里的「继续观看」「想看」，搜索里的某一类）
//
// 系统大标题（C13）+ 一张海报网格（T23）：电影和剧集一起，卡上只有画面（纯净画面 + 字标），卡下不写字（T20、F80）；
// 「播放 / 想看」在长按菜单里（C21、C43、C45）。

struct ShelfView: View {
    @Environment(AppModel.self) private var model
    let shelf: Shelf

    var body: some View {
        let entries = self.entries
        GeometryReader { geo in
            let insets = geo.safeAreaInsets
            let metrics = DSMetrics(width: geo.size.width, leadingInset: insets.leading, trailingInset: insets.trailing)
            ScrollView {
                if entries.isEmpty {
                    emptyState.padding(.top, 60)
                } else {
                    EntryGrid(entries: entries, metrics: metrics, slot: "shelf-" + shelf.key,
                              movieID: "shelf-movie", seriesID: "shelf-series")
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
        .navigationTitle(shelf.title)
        .navigationBarTitleDisplayMode(.large)
    }

    private var entries: [HomeEntry] {
        switch shelf {
        case .newest:
            return model.movies.map { .movie($0) }
        case .picks:
            return model.todayPicks.map { .movie($0) }
        case .series:
            return model.series.map { .series($0) }
        case .watchlist:
            return model.watchlist.items.compactMap { w -> HomeEntry? in
                if w.kind == .movie, let v = model.video(path: w.key) { return .movie(v) }
                if w.kind == .series, let s = model.series.first(where: { $0.path == w.key }) { return .series(s) }
                return nil
            }
        case .continueWatching:
            var seen = Set<String>()
            return model.playback.continueWatching.compactMap { e -> HomeEntry? in
                if let sp = e.seriesPath, let s = model.series.first(where: { $0.path == sp }) {
                    return seen.insert("s:" + s.path).inserted ? .series(s) : nil
                }
                if let v = model.video(path: e.path) { return seen.insert("m:" + v.path).inserted ? .movie(v) : nil }
                return nil
            }
        case .genre(let g):
            // 某一类：先电影（最新入库的在前），再剧集
            return model.movies(inGenre: g).map { .movie($0) } + model.series(inGenre: g).map { .series($0) }
        case .category(let c):
            return model.categoryEntries(c)
        case .featured:
            return model.featuredMovies().map { .movie($0) }
        }
    }

    /// 空的时候告诉人下一步（F88）
    @ViewBuilder private var emptyState: some View {
        switch shelf {
        case .watchlist:
            ContentUnavailableView("想看还是空的", systemImage: "plus.circle",
                                   description: Text("长按海报，选「加入想看」，片子就会出现在这里。"))
        case .continueWatching:
            ContentUnavailableView("还没有看到一半的", systemImage: "play.circle",
                                   description: Text("看过 30 秒以上、还没看完的电影和剧集会出现在这里。"))
        default:
            ContentUnavailableView("这里还没有影片", systemImage: "film",
                                   description: Text("片库里有了这一类的电影或剧集，会出现在这里。"))
        }
    }
}
