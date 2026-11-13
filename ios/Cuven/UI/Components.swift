import SwiftUI

enum Theme {
    static let bg = Color.black
    static let surface = Color(white: 0.11)
    static let surface2 = Color(white: 0.16)
    static let secondary = Color.white.opacity(0.62)
    static let tertiary = Color.white.opacity(0.38)
    static let hairline = Color.white.opacity(0.12)
    static let accent = Color(red: 0.04, green: 0.52, blue: 1.0)
    static let cardRadius: CGFloat = 14
    static let gutter: CGFloat = 20
}

// MARK: - 分区标题

struct SectionHeader: View {
    let title: String
    var count: Int? = nil
    /// 标题下面一行灰字（App Store 的分区标题：「Arcade 名人堂 ›」下面「知名角色等你来相遇」）
    var subtitle: String? = nil
    /// 有的话：标题后面带「›」，整行点进去看全部（Apple TV 的分区标题）
    var route: Route? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        let row = VStack(alignment: .leading, spacing: 3) {
            titleRow
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, Theme.gutter)
        if let route {
            NavigationLink(value: route) { row.contentShape(Rectangle()) }
                .buttonStyle(PressableStyle(scale: 0.98))
                .accessibilityIdentifier("section-\(title)")
        } else {
            row
        }
    }

    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).font(.system(size: 22, weight: .bold)).foregroundStyle(.white)
            if route != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 17, weight: .heavy))
                    .foregroundStyle(Theme.secondary)
            }
            if let count { Text("\(count)").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.tertiary).padding(.leading, 2) }
            Spacer()
            if let action {
                Button(action: action) {
                    HStack(spacing: 2) {
                        Text("全部")
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                    }
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// 「想看」：圆形玻璃钮，「+」加进片单、「✓」已在片单里（符号切换带动画）
struct WatchlistButton: View {
    @Environment(AppModel.self) private var model
    let key: String
    let kind: WatchItem.Kind
    var size: CGFloat = 50

    var body: some View {
        let on = model.watchlist.contains(key)
        Button {
            withAnimation(.snappy) { model.watchlist.toggle(key, kind: kind) }
            Haptics.light()
        } label: {
            Image(systemName: on ? "checkmark" : "plus")
                .font(.system(size: size * 0.38, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size, height: size)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityLabel(on ? "从想看移除" : "加入想看")
        .accessibilityIdentifier("watchlist-button")
    }
}

// MARK: - 竖版海报卡

struct PosterCard: View {
    @Environment(AppModel.self) private var model
    let video: Video
    var width: CGFloat = 128

    var body: some View {
        let _ = Perf.count("poster")
        let m = model.meta(video)
        VStack(alignment: .leading, spacing: 7) {
            RemoteImage(url: TMDBImage.url(m?.poster ?? m?.posterClean, "w342"), maxPixel: width * 3)
                .frame(width: width, height: width * 1.5)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
                .overlay(alignment: .bottom) { progressOverlay }
            VStack(alignment: .leading, spacing: 2) {
                Text(model.title(video))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let y = model.year(video) {
                    Text(String(y)).font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                }
            }
            .frame(width: width, alignment: .leading)
        }
    }

    @ViewBuilder private var progressOverlay: some View {
        if let e = model.playback.entry(video.path), e.fraction > 0.01 {
            ProgressCapsule(fraction: e.fraction).padding(.horizontal, 8).padding(.bottom, 8)
        }
    }
}

/// 剧集的竖版海报卡（「想看」那一排里和电影海报卡并排）
struct SeriesPosterCard: View {
    @Environment(AppModel.self) private var model
    let series: Series
    var width: CGFloat = 128

    var body: some View {
        let m = model.seriesMetas[series.path]
        VStack(alignment: .leading, spacing: 7) {
            RemoteImage(url: TMDBImage.url(m?.poster ?? m?.posterClean, "w342"), maxPixel: width * 3)
                .frame(width: width, height: width * 1.5)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
            VStack(alignment: .leading, spacing: 2) {
                Text(m?.title ?? series.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(series.seasonLabel ?? "剧集").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
            }
            .frame(width: width, alignment: .leading)
        }
    }
}

struct ProgressCapsule: View {
    let fraction: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.28))
                Capsule().fill(Color.white).frame(width: max(4, geo.size.width * fraction))
            }
        }
        .frame(height: 4)
    }
}

// MARK: - 今日推荐：大号描边名次 + 海报压在数字右缘

struct RankCard: View {
    @Environment(AppModel.self) private var model
    let rank: Int
    let video: Video

    var body: some View {
        let m = model.meta(video)
        let posterW: CGFloat = 116
        ZStack(alignment: .bottomLeading) {
            OutlinedNumber(text: String(rank), size: rank >= 10 ? 112 : 132)
                .offset(x: -4, y: 18)
            RemoteImage(url: TMDBImage.url(m?.poster ?? m?.posterClean, "w342"), maxPixel: posterW * 3)
                .frame(width: posterW, height: posterW * 1.5)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.5), radius: 10, x: -6, y: 4)
                .padding(.leading, rank >= 10 ? 74 : 56)
        }
        .frame(width: (rank >= 10 ? 74 : 56) + posterW, height: posterW * 1.5, alignment: .bottomLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("第 \(rank) 名，\(model.title(video))")
    }
}

/// 描边数字：八个方向各偏一点画成白边，中间填黑
struct OutlinedNumber: View {
    let text: String
    let size: CGFloat
    var body: some View {
        let font = Font.system(size: size, weight: .heavy, design: .rounded)
        ZStack {
            ForEach(0..<8, id: \.self) { i in
                let a = Double(i) * .pi / 4
                Text(text).font(font).foregroundStyle(Color.white.opacity(0.9))
                    .offset(x: cos(a) * 1.6, y: sin(a) * 1.6)
            }
            Text(text).font(font).foregroundStyle(Theme.bg)
        }
        .fixedSize()
    }
}

// MARK: - 继续观看：横版卡 + 进度

struct ContinueCard: View {
    let entry: WatchEntry
    var width: CGFloat = 250

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomLeading) {
                RemoteImage(url: TMDBImage.url(entry.artwork, "w780"), maxPixel: width * 3)
                    .frame(width: width, height: width * 9 / 16)
                    .clipped()
                LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
                HStack(spacing: 6) {
                    Image(systemName: "play.fill").font(.system(size: 11, weight: .bold))
                    Text("还剩 \(Format.clock(entry.remaining))").font(.system(size: 12, weight: .semibold)).monospacedDigit()
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.bottom, 16)
                ProgressCapsule(fraction: entry.fraction).padding(.horizontal, 10).padding(.bottom, 7)
            }
            .frame(width: width, height: width * 9 / 16)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                Text([entry.subtitle, Format.relative(entry.updated)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 12)).foregroundStyle(Theme.tertiary).lineLimit(1)
            }
            .frame(width: width, alignment: .leading)
        }
    }
}

// MARK: - 剧集卡：整张剧照 + 下半幅压暗 + 官方字标（统一 60 高，深色字标反白）+ 底栏

struct SeriesCard: View {
    @Environment(AppModel.self) private var model
    let series: Series
    var width: CGFloat

    var body: some View {
        let m = model.seriesMetas[series.path]
        let height = width * 13 / 15
        ZStack(alignment: .bottom) {
            RemoteImage(url: TMDBImage.url(m?.backdrop ?? m?.posterClean ?? m?.poster, "w780"), maxPixel: width * 3)
                .frame(width: width, height: height)
                .clipped()
            LinearGradient(stops: [
                .init(color: .clear, location: 0.28),
                .init(color: .black.opacity(0.55), location: 0.55),
                .init(color: .black.opacity(0.88), location: 1),
            ], startPoint: .top, endPoint: .bottom)
            VStack(spacing: 0) {
                Text(series.countLabel)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.bottom, 6)
                LogoImage(url: TMDBImage.url(m?.logo, "w500"), height: 60, fallback: m?.title ?? series.name)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 14)
                HStack(spacing: 10) {
                    RemoteImage(url: TMDBImage.url(m?.stills?.first?.thumb ?? m?.poster, "w342"), maxPixel: 200)
                        .frame(width: 58, height: 34)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    Text(series.en ?? m?.en ?? series.name)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text("详情")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .glassEffect(.regular, in: Capsule())
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(.ultraThinMaterial.opacity(0.6))
                .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
        .task { await model.ensureSeriesMeta(series) }
    }
}

// MARK: - 规格徽标（只在详情页）

struct SpecBadge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
    }
}

/// 横向滑动的一排
struct Rail<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: () -> Content
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: spacing) { content() }
                .scrollTargetLayout()
                .padding(.horizontal, Theme.gutter)
        }
        .scrollTargetBehavior(.viewAligned)
    }
}

/// 加载中的骨架条
struct SkeletonRow: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RoundedRectangle(cornerRadius: 6).fill(Theme.surface).frame(width: 120, height: 22).padding(.horizontal, Theme.gutter)
            HStack(spacing: 12) {
                ForEach(0..<4, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 12).fill(Theme.surface).frame(width: 128, height: 192)
                }
            }
            .padding(.horizontal, Theme.gutter)
        }
        .redacted(reason: .placeholder)
    }
}

/// 自动换行的一排（规格徽标等）：一行放不下就折到下一行，不会把整列撑得比屏幕宽
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > maxW { y += lineH + lineSpacing; x = 0; lineH = 0 }
            x += s.width + spacing
            lineH = max(lineH, s.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, maxW), height: y + lineH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { y += lineH + lineSpacing; x = bounds.minX; lineH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            lineH = max(lineH, s.height)
        }
    }
}

/// 白色玻璃的主按钮（播放）：字一律黑色 —— 白底白字看不见
struct PrimaryLabel: View {
    let title: String
    let systemImage: String
    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 17, weight: .bold))
            .foregroundStyle(.black)
    }
}
