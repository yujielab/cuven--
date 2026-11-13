import SwiftUI

// MARK: - 首页分区标题「›」进去的整页清单（Apple TV「Must-See Hits」那种：竖版小海报 + 片名 + 一行说明 + 「…」）

struct ShelfView: View {
    @Environment(AppModel.self) private var model
    let shelf: Shelf

    var body: some View {
        if shelf == .picks {
            PicksChartView()
        } else {
            list
        }
    }

    private var list: some View {
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
                case .continueWatching:
                    let entries = model.playback.continueWatching
                    if entries.isEmpty {
                        ContentUnavailableView("还没有看到一半的", systemImage: "play.circle",
                                               description: Text("看过 30 秒以上、还没看完的电影和剧集会出现在这里。"))
                            .padding(.top, 60)
                    }
                    ForEach(entries) { e in
                        if let sp = e.seriesPath, let s = model.series.first(where: { $0.path == sp }) {
                            seriesRow(s)
                        } else if let v = model.video(path: e.path) {
                            movieRow(v)
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


// MARK: - 今日推荐整页：排行（Games App「热门排行榜」）

/// 头部是三张海报斜着叠成的拼贴 + 大标题；下面两列名次卡。滚过头部，标题才进导航栏
struct PicksChartView: View {
    @Environment(AppModel.self) private var model
    @State private var showTitle = false

    var body: some View {
        let picks = model.todayPicks
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ChartHeader(posters: picks.prefix(3).compactMap { v in model.meta(v).flatMap { $0.poster ?? $0.posterClean } },
                                title: "今日推荐", subtitle: "每天上午、下午、晚上各换一批", topInset: geo.safeAreaInsets.top)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                        ForEach(Array(picks.enumerated()), id: \.element.id) { i, v in
                            RankTile(rank: i + 1, video: v)
                        }
                    }
                    .padding(.horizontal, Theme.gutter)
                }
                .padding(.bottom, 30)
            }
            .scrollIndicators(.hidden)
            .background(Theme.bg)
            .ignoresSafeArea(edges: .top)
            .onScrollGeometryChange(for: Bool.self) { g in g.contentOffset.y > 240 } action: { _, v in
                withAnimation(.easeOut(duration: 0.2)) { showTitle = v }
            }
        }
        .background(Theme.bg)
        .navigationTitle(showTitle ? "今日推荐" : "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
    }
}

/// 排行页头图：灰色渐变底上三张海报扇形叠着（Games「热门排行榜」那三枚立体图标），左下大标题
struct ChartHeader: View {
    let posters: [String]
    let title: String
    let subtitle: String
    let topInset: CGFloat

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [Color(white: 0.34), Color(white: 0.13), Theme.bg], startPoint: .top, endPoint: .bottom)
            ZStack {
                ForEach(Array(posters.prefix(3).enumerated()), id: \.offset) { i, p in
                    let angle: Double = [-9, 2, 11][i]
                    let dx: CGFloat = [-92, 0, 92][i]
                    let dy: CGFloat = [-4, 14, 32][i]
                    RemoteImage(url: TMDBImage.url(p, "w342"), maxPixel: 420)
                        .frame(width: 112, height: 168)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.2), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.5), radius: 14, y: 10)
                        .rotationEffect(.degrees(angle))
                        .offset(x: dx, y: dy)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, topInset + 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 36, weight: .heavy)).foregroundStyle(.white)
                Text(subtitle).font(.system(size: 15)).foregroundStyle(Theme.secondary)
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.bottom, 12)
        }
        .frame(height: topInset + 330)
        .clipped()
    }
}

/// 名次卡（Games「热玩游戏排行」）：底色取自海报，左上大号名次数字（同色、浅一些），海报斜着压在数字右边；
/// 下面片名、类型与年份，左下「播放」胶囊（叠在卡片上，不嵌在链接里）。点卡片其余地方进详情
struct RankTile: View {
    @Environment(AppModel.self) private var model
    let rank: Int
    let video: Video
    @State private var tint: Color = Theme.surface2

    var body: some View {
        let m = model.meta(video)
        let poster = TMDBImage.url(m?.poster ?? m?.posterClean, "w342")
        ZStack(alignment: .bottomLeading) {
            ZoomLink(route: .movie(video), slot: "chart") {
                VStack(alignment: .leading, spacing: 0) {
                    ZStack(alignment: .topLeading) {
                        Text("\(rank)")
                            .font(.system(size: rank >= 10 ? 86 : 104, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white.opacity(0.3))
                            .offset(y: -8)
                        RemoteImage(url: poster, maxPixel: 360)
                            .frame(width: 80, height: 120)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
                            .shadow(color: .black.opacity(0.45), radius: 10, y: 8)
                            .rotationEffect(.degrees(-4))
                            .padding(.leading, rank >= 10 ? 64 : 48)
                            .padding(.top, 36)
                    }
                    .frame(height: 168, alignment: .topLeading)
                    Spacer(minLength: 4)
                    Text(model.title(video))
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    Text(subtitle(m))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(1)
                        .padding(.top, 2)
                    Color.clear.frame(height: 46)          // 「播放」胶囊的位置
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .frame(height: 300)
                .background(LinearGradient(colors: [tint, tint.opacity(0.78)], startPoint: .top, endPoint: .bottom))
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
            }
            .accessibilityIdentifier("rank-tile")
            .movieMenu(video)
            PlayPill(video: video, onArt: true)
                .padding(14)
        }
        .task(id: video.path) {
            guard let u = poster, let c = await ArtTint.color(for: u, ceiling: 0.62) else { return }
            withAnimation(.easeOut(duration: 0.3)) { tint = c }
        }
    }

    private func subtitle(_ m: Meta?) -> String {
        [m?.genres?.first, model.year(video).map { String($0) }].compactMap { $0 }.joined(separator: " · ")
    }
}
