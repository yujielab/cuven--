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

/// 「为你推荐」里的一行：小海报、片名、一行说明，行尾「播放」胶囊；点这一行其余地方进详情（缩放转场）。
/// 胶囊叠在链接上面、不嵌在链接里，两个各管各的
struct PickRow: View {
    @Environment(AppModel.self) private var model
    let video: Video
    let slot: String
    var separator = true

    var body: some View {
        let m = model.meta(video)
        ZStack(alignment: .trailing) {
            ZoomLink(route: .movie(video), slot: slot, press: false) {
                HStack(spacing: 14) {
                    RemoteImage(url: TMDBImage.url(m?.poster ?? m?.posterClean, "w185"), maxPixel: 240)
                        .frame(width: 56, height: 84)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.title(video))
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                        Text(subtitle(m))
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 92)
                }
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .movieMenu(video)
            .accessibilityIdentifier("pick-row")
            PlayPill(video: video)
        }
        .overlay(alignment: .bottom) {
            if separator {
                Rectangle().fill(Theme.hairline).frame(height: 0.5).padding(.leading, 70)
            }
        }
    }

    private func subtitle(_ m: Meta?) -> String {
        let parts = [m?.genres?.prefix(2).joined(separator: " · "), model.year(video).map { String($0) }]
            .compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? "电影" : parts.joined(separator: " · ")
    }
}

/// 横着一页一页翻的清单（App Store「为你推荐」）：每页三行，下一页露出一截
struct PagedRows: View {
    let videos: [Video]
    let width: CGFloat
    let slot: String
    var perPage = 3

    var body: some View {
        let pageW = max(260, width - Theme.gutter * 2 - 28)
        let pages = stride(from: 0, to: videos.count, by: perPage).map { Array(videos[$0..<min($0 + perPage, videos.count)]) }
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 18) {
                ForEach(pages.indices, id: \.self) { p in
                    VStack(spacing: 0) {
                        ForEach(Array(pages[p].enumerated()), id: \.element.id) { i, v in
                            PickRow(video: v, slot: slot, separator: i < pages[p].count - 1)
                        }
                    }
                    .frame(width: pageW, alignment: .top)
                }
            }
            .scrollTargetLayout()
        }
        .contentMargins(.horizontal, Theme.gutter, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
    }
}

// MARK: - 浏览：按类型

/// 一格类型（App Store「浏览」那种彩色方块）：渐变底、右上角一个符号、左下角类型名
struct GenreTile: View {
    let name: String
    let index: Int

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: GenreStyle.colors(index), startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: GenreStyle.symbol(name))
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .shadow(color: .black.opacity(0.22), radius: 6, y: 3)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(14)
            Text(name)
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
        }
        .frame(height: 96)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// 两列的类型格子；点进去是这一类的整页清单
struct GenreGrid: View {
    let genres: [String]

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            ForEach(Array(genres.enumerated()), id: \.element) { i, g in
                ZoomLink(route: .shelf(.genre(g)), slot: "genre") { GenreTile(name: g, index: i) }
                    .accessibilityIdentifier("genre-tile")
            }
        }
        .padding(.horizontal, Theme.gutter)
    }
}

enum GenreStyle {
    private static let palette: [[Color]] = [
        [Color(red: 0.38, green: 0.56, blue: 0.96), Color(red: 0.24, green: 0.40, blue: 0.86)],   // 蓝
        [Color(red: 0.96, green: 0.63, blue: 0.36), Color(red: 0.88, green: 0.45, blue: 0.24)],   // 橙
        [Color(red: 0.42, green: 0.76, blue: 0.46), Color(red: 0.24, green: 0.60, blue: 0.34)],   // 绿
        [Color(red: 0.62, green: 0.50, blue: 0.96), Color(red: 0.45, green: 0.33, blue: 0.86)],   // 紫
        [Color(red: 0.96, green: 0.46, blue: 0.56), Color(red: 0.82, green: 0.30, blue: 0.42)],   // 粉
        [Color(red: 0.26, green: 0.70, blue: 0.76), Color(red: 0.14, green: 0.52, blue: 0.62)],   // 青
        [Color(red: 0.95, green: 0.76, blue: 0.32), Color(red: 0.85, green: 0.58, blue: 0.18)],   // 黄
        [Color(red: 0.52, green: 0.57, blue: 0.67), Color(red: 0.36, green: 0.41, blue: 0.51)],   // 石板
    ]

    static func colors(_ i: Int) -> [Color] { palette[i % palette.count] }

    static func symbol(_ g: String) -> String {
        switch g {
        case "剧情": return "theatermasks.fill"
        case "喜剧": return "face.smiling.inverse"
        case "动作", "动作冒险": return "bolt.fill"
        case "科幻", "Sci-Fi & Fantasy": return "sparkles"
        case "爱情": return "heart.fill"
        case "惊悚": return "eye.fill"
        case "犯罪": return "exclamationmark.shield.fill"
        case "动画": return "paintpalette.fill"
        case "冒险": return "map.fill"
        case "悬疑": return "questionmark.circle.fill"
        case "家庭", "儿童": return "house.fill"
        case "奇幻": return "wand.and.stars"
        case "恐怖": return "moon.fill"
        case "纪录", "纪录片": return "video.fill"
        case "历史": return "building.columns.fill"
        case "战争", "War & Politics": return "shield.fill"
        case "音乐": return "music.note"
        case "西部": return "sun.dust.fill"
        case "电视电影": return "tv.fill"
        default: return "film.fill"
        }
    }
}

/// 「浏览 ›」进来的整页：片库里全部的类型
struct BrowseView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            GenreGrid(genres: model.genres.map { $0.name })
                .padding(.vertical, 12)
                .padding(.bottom, 30)
        }
        .scrollIndicators(.hidden)
        .background(Theme.bg)
        .navigationTitle("浏览")
        .navigationBarTitleDisplayMode(.large)
    }
}
