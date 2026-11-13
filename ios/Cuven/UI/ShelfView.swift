import SwiftUI

// MARK: - 首页分区标题「›」进去的整页清单（Apple TV「Must-See Hits」那种：竖版小海报 + 片名 + 一行说明 + 「…」）

struct ShelfView: View {
    @Environment(AppModel.self) private var model
    let shelf: Shelf

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                switch shelf {
                case .newest:
                    ForEach(model.movies) { v in movieRow(v) }
                case .picks:
                    ForEach(model.todayPicks) { v in movieRow(v) }
                case .series:
                    ForEach(model.series) { s in seriesRow(s) }
                case .watchlist:
                    if model.watchlist.items.isEmpty {
                        ContentUnavailableView("想看还是空的", systemImage: "plus.circle",
                                               description: Text("在详情页或首页大图上点「+」，片子就会出现在这里。"))
                            .padding(.top, 60)
                    }
                    ForEach(model.watchlist.items, id: \.key) { w in
                        if w.kind == .movie, let v = model.video(path: w.key) {
                            movieRow(v)
                        } else if w.kind == .series, let s = model.series.first(where: { $0.path == w.key }) {
                            seriesRow(s)
                        }
                    }
                case .genre(let g):
                    // 搜索页「浏览」里的一类：先电影（最新入库的在前），再剧集
                    ForEach(model.movies(inGenre: g)) { v in movieRow(v) }
                    ForEach(model.series(inGenre: g)) { s in seriesRow(s) }
                }
            }
            .padding(.bottom, 30)
        }
        .scrollIndicators(.hidden)
        .background(Theme.bg)
        .navigationTitle(shelf.title)
        .navigationBarTitleDisplayMode(.large)
    }

    private func movieRow(_ v: Video) -> some View {
        let m = model.meta(v)
        let sub = [model.year(v).map { "\($0) 年" }, m?.genres?.prefix(2).joined(separator: " · ")]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return ShelfRow(image: TMDBImage.url(m?.poster ?? m?.posterClean, "w185"), title: model.title(v),
                        subtitle: sub.isEmpty ? "电影" : sub, slot: "shelf-\(shelf.key)", route: .movie(v)) {
            Button("播放", systemImage: "play.fill") {
                PlayerCoordinator.shared.play(PlayRequest(path: v.path, name: v.name, title: model.title(v),
                                                          subtitle: model.year(v).map { String($0) },
                                                          artwork: m?.backdrop ?? m?.poster), model: model)
            }
            WatchlistMenuButton(key: v.path, kind: .movie)
        }
    }

    private func seriesRow(_ s: Series) -> some View {
        let m = model.seriesMetas[s.path]
        let sub = [s.year.map { "\($0) 年" }, s.seasonLabel, s.countLabel].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return ShelfRow(image: TMDBImage.url(m?.poster ?? m?.posterClean, "w185"), title: m?.title ?? s.name,
                        subtitle: sub.isEmpty ? "剧集" : sub, slot: "shelf-\(shelf.key)", route: .series(s)) {
            WatchlistMenuButton(key: s.path, kind: .series)
        }
    }

}

/// 清单里的一行：点整行进详情（缩放转场），行尾「…」是操作菜单；发丝线从文字那一列起头
struct ShelfRow<Actions: View>: View {
    let image: URL?
    let title: String
    let subtitle: String
    let slot: String
    let route: Route
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(spacing: 14) {
            ZoomLink(route: route, slot: slot) {
                HStack(spacing: 14) {
                    RemoteImage(url: image, maxPixel: 240)
                        .frame(width: 64, height: 96)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white).lineLimit(2)
                        Text(subtitle).font(.system(size: 14)).foregroundStyle(Theme.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            Menu {
                actions()
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("更多操作")
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: 0.5).padding(.leading, Theme.gutter + 64 + 14)
        }
    }
}
