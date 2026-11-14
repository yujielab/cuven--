import SwiftUI

// MARK: - 整页清单（首页分区标题「›」进来的，账户里的「继续观看」「想看」）
//
// 系统大标题 + 一张系统列表（C13、C29、C31）：前面竖版小海报，片名与一行灰字，行尾系统的「›」进详情（系统推入：F53）；
// 「播放 / 想看」在长按菜单里（C21、C43、C45），行尾不再有「…」。
// 今日推荐也是这张列表，名次在行首（App Store 排行的写法）；不再有斜叠海报的头图、取色的名次大卡和叠在卡上的胶囊钮（F3、F38、F80）。

struct ShelfView: View {
    @Environment(AppModel.self) private var model
    let shelf: Shelf

    var body: some View {
        List {
            switch shelf {
            case .newest:
                ForEach(model.movies) { v in
                    LibraryMovieRow(video: v, identifier: "shelf-movie")
                }
            case .picks:
                ForEach(Array(model.todayPicks.enumerated()), id: \.element.id) { i, v in
                    LibraryMovieRow(video: v, rank: i + 1, identifier: "shelf-movie")
                }
            case .series:
                ForEach(model.series) { s in
                    LibrarySeriesRow(series: s, identifier: "shelf-series")
                }
            case .watchlist:
                ForEach(model.watchlist.items, id: \.key) { w in
                    if w.kind == .movie, let v = model.video(path: w.key) {
                        LibraryMovieRow(video: v, identifier: "shelf-movie")
                    } else if w.kind == .series, let s = model.series.first(where: { $0.path == w.key }) {
                        LibrarySeriesRow(series: s, identifier: "shelf-series")
                    }
                }
            case .continueWatching:
                ForEach(model.playback.continueWatching) { e in
                    if let sp = e.seriesPath, let s = model.series.first(where: { $0.path == sp }) {
                        LibrarySeriesRow(series: s, subtitle: Self.left(e, episode: true), identifier: "shelf-series")
                    } else if let v = model.video(path: e.path) {
                        LibraryMovieRow(video: v, subtitle: Self.left(e, episode: false), identifier: "shelf-movie")
                    }
                }
            case .genre(let g):
                // 某一类：先电影（最新入库的在前），再剧集
                ForEach(model.movies(inGenre: g)) { v in
                    LibraryMovieRow(video: v, identifier: "shelf-movie")
                }
                ForEach(model.series(inGenre: g)) { s in
                    LibrarySeriesRow(series: s, identifier: "shelf-series")
                }
            }
        }
        .listStyle(.plain)
        .overlay { emptyState }
        .navigationTitle(shelf.title)
        .navigationBarTitleDisplayMode(.large)
    }

    /// 继续观看的灰字：「第 3 集 · 还剩 24 分钟」——告诉人看到哪了（F84：短而平实）
    static func left(_ e: WatchEntry, episode: Bool) -> String? {
        var parts: [String] = []
        if episode, let n = e.episode { parts.append("第 \(n) 集") }
        let minutes = Int((e.remaining / 60).rounded())
        if minutes >= 1 { parts.append("还剩 \(minutes) 分钟") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// 空的时候告诉人下一步（F88）
    @ViewBuilder private var emptyState: some View {
        switch shelf {
        case .watchlist where model.watchlist.items.isEmpty:
            ContentUnavailableView("想看还是空的", systemImage: "plus.circle",
                                   description: Text("长按海报，选「加入想看」，片子就会出现在这里。"))
        case .continueWatching where model.playback.continueWatching.isEmpty:
            ContentUnavailableView("还没有看到一半的", systemImage: "play.circle",
                                   description: Text("看过 30 秒以上、还没看完的电影和剧集会出现在这里。"))
        default:
            EmptyView()
        }
    }
}
