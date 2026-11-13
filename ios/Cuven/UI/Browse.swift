import SwiftUI

// MARK: - App Store 式的版块（搜索页「为你推荐」「浏览」、卡片上的胶囊钮）

/// App Store「取得」那种胶囊钮，在这里是「播放 / 继续」：点了直接播放，不进详情。
/// 列表里：浅灰底、蓝字；叠在画面上（onArt）：半透明白底、白字
struct PlayPill: View {
    @Environment(AppModel.self) private var model
    let video: Video
    var onArt = false

    var body: some View {
        let resume = model.playback.resumePosition(video.path) != nil
        Button {
            let m = model.meta(video)
            PlayerCoordinator.shared.play(PlayRequest(path: video.path, name: video.name, title: model.title(video),
                                                      subtitle: model.year(video).map { String($0) },
                                                      artwork: m?.backdrop ?? m?.poster), model: model)
        } label: {
            Text(resume ? "继续" : "播放")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(onArt ? Color.white : Theme.accent)
                .frame(minWidth: 44)
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background(Color.white.opacity(onArt ? 0.24 : 0.12), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle(scale: 0.92))
        .accessibilityLabel(resume ? "继续播放" : "播放")
        .accessibilityIdentifier("play-pill")
    }
}

// MARK: - 搜索页的格子（Apple TV「搜索」：三列竖版格子，画面铺满，左下角大字）

struct BrowseTile: Identifiable {
    let id: String
    let title: String
    let route: Route
    let art: String?
}

extension AppModel {
    /// 先是几个清单（最新加入、剧集、想看），再是片库里片子最多的类型。
    /// 每格的画面：这一类里评分最高、还没被前面的格子用过的那部的无字海报
    var browseTiles: [BrowseTile] {
        var used = Set<String>()
        func pick(_ candidates: [Video]) -> String? {
            let ranked = candidates.sorted { (meta($0)?.rating ?? 0) > (meta($1)?.rating ?? 0) }
            for v in ranked {
                guard let m = meta(v), let a = m.posterClean ?? m.poster, !used.contains(a) else { continue }
                used.insert(a)
                return a
            }
            return nil
        }
        var out: [BrowseTile] = []
        if !movies.isEmpty {
            out.append(BrowseTile(id: "shelf:newest", title: "最新加入", route: .shelf(.newest), art: pick(Array(movies.prefix(12)))))
        }
        if let s = series.first(where: { seriesMetas[$0.path]?.hasArt == true }), let m = seriesMetas[s.path] {
            let a = m.posterClean ?? m.poster
            if let a { used.insert(a) }
            out.append(BrowseTile(id: "shelf:series", title: "剧集", route: .shelf(.series), art: a))
        }
        if let first = watchlist.items.first {
            let m = first.kind == .movie ? video(path: first.key).flatMap { meta($0) } : seriesMetas[first.key]
            let a = m?.posterClean ?? m?.poster
            if let a { used.insert(a) }
            out.append(BrowseTile(id: "shelf:watchlist", title: "想看", route: .shelf(.watchlist), art: a))
        }
        for g in genres.prefix(18) {
            out.append(BrowseTile(id: "genre:" + g.name, title: g.name, route: .shelf(.genre(g.name)), art: pick(movies(inGenre: g.name))))
        }
        return out
    }
}

/// 一格：画面铺满（没有画面就是一块渐变），下半截压暗，左下角大字
struct ArtTile: View {
    let tile: BrowseTile
    let index: Int

    var body: some View {
        Color.clear
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .overlay {
                ZStack(alignment: .bottomLeading) {
                    LinearGradient(colors: TileStyle.colors(index), startPoint: .topLeading, endPoint: .bottomTrailing)
                    if tile.art != nil {
                        RemoteImage(url: TMDBImage.url(tile.art, "w342"), maxPixel: 520, placeholder: .clear)
                    }
                    LinearGradient(stops: [
                        .init(color: .clear, location: 0.42),
                        .init(color: .black.opacity(0.7), location: 1),
                    ], startPoint: .top, endPoint: .bottom)
                    Text(tile.title)
                        .font(.system(size: 21, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                        .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                        .padding(.horizontal, 11)
                        .padding(.bottom, 10)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// 三列（宽屏上按宽度多排几列）的格子；点进去是那一类的整页清单（缩放转场）
struct BrowseGrid: View {
    let tiles: [BrowseTile]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100, maximum: 170), spacing: 12)], spacing: 12) {
            ForEach(Array(tiles.enumerated()), id: \.element.id) { i, t in
                ZoomLink(route: t.route, slot: "browse") { ArtTile(tile: t, index: i) }
                    .accessibilityIdentifier(t.id.hasPrefix("genre:") ? "genre-tile" : "browse-tile")
            }
        }
        .padding(.horizontal, Theme.gutter)
    }
}

/// 没有画面时垫底的渐变
enum TileStyle {
    private static let palette: [[Color]] = [
        [Color(red: 0.38, green: 0.56, blue: 0.96), Color(red: 0.24, green: 0.40, blue: 0.86)],
        [Color(red: 0.96, green: 0.63, blue: 0.36), Color(red: 0.88, green: 0.45, blue: 0.24)],
        [Color(red: 0.42, green: 0.76, blue: 0.46), Color(red: 0.24, green: 0.60, blue: 0.34)],
        [Color(red: 0.62, green: 0.50, blue: 0.96), Color(red: 0.45, green: 0.33, blue: 0.86)],
        [Color(red: 0.96, green: 0.46, blue: 0.56), Color(red: 0.82, green: 0.30, blue: 0.42)],
        [Color(red: 0.26, green: 0.70, blue: 0.76), Color(red: 0.14, green: 0.52, blue: 0.62)],
    ]

    static func colors(_ i: Int) -> [Color] { palette[i % palette.count] }
}
