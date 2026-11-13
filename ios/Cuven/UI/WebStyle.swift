import SwiftUI

// MARK: - 和网页版一致的小部件（尺寸、字号、颜色都照 web/index.html 在 iPhone Duo 上量出来的值）

/// 分区标题：一枚玻璃胶囊（网页版 .section-header 里那颗：22 粗体白字，rgba(28,28,30,.5) + 模糊，1px 白 10% 描边，内边距 8×18）
struct SectionChip: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 22, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .background(Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255).opacity(0.5), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
            .environment(\.colorScheme, .dark)
    }
}

/// 「品质保证」小章（网页版 .cuven-seal：11 号 800 粗，rgba(10,10,12,.52) + 模糊，1px 白 18% 描边，高 28）。
/// note：前面带「Cuven」（详情页头部那一行，12.5 号、左右 12）
struct QualitySeal: View {
    var note = false
    var size: CGFloat = 11
    var hPad: CGFloat = 10

    var body: some View {
        HStack(spacing: size * 0.32) {
            if note { Text("Cuven").font(.system(size: size, weight: .heavy)) }
            Text("品质保证").font(.system(size: size * 0.94, weight: .bold))
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.5), radius: 1.5, y: 1)
        .padding(.horizontal, hPad)
        .frame(height: 28)
        .background(.ultraThinMaterial, in: Capsule())
        .background(Color(red: 10 / 255, green: 10 / 255, blue: 12 / 255).opacity(0.52), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 7, y: 4)
        .environment(\.colorScheme, .dark)
        .fixedSize()
    }
}

/// 年份那一条（网页版 .year-pill：一整条玻璃胶囊，左边年份，右边蓝色「查看电影和剧集 ›」）
struct YearBar: View {
    let year: Int

    var body: some View {
        NavigationLink(value: Route.year(year)) {
            HStack(spacing: 10) {
                Text(String(year))
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Color(red: 245 / 255, green: 245 / 255, blue: 247 / 255))
                    .padding(.leading, 20)
                Spacer(minLength: 8)
                HStack(spacing: 4) {
                    Text("查看电影和剧集")
                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold))
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.95))
                .padding(.horizontal, 14)
                .frame(height: 36)
                .background(Theme.accent, in: Capsule())
                .shadow(color: Theme.accent.opacity(0.45), radius: 10, y: 3)
                .padding(.trailing, 8)
            }
            .frame(height: 52)
            .background(.ultraThinMaterial, in: Capsule())
            .background(Color.white.opacity(0.06), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
            .environment(\.colorScheme, .dark)
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle(scale: 0.98))
        .accessibilityIdentifier("year-bar-\(year)")
    }
}

/// 网页版「最新加入」那种横版卡：16:9 剧照（圆角 14），左下角片名压在渐暗上；卡下一行灰字（「今天」「3 天前」）
struct LandscapeCard: View {
    @Environment(AppModel.self) private var model
    let video: Video
    let width: CGFloat

    var body: some View {
        let m = model.meta(video)
        VStack(alignment: .leading, spacing: 13) {
            ZStack(alignment: .bottomLeading) {
                Color.clear
                    .overlay { RemoteImage(url: TMDBImage.url(m?.backdrop ?? m?.posterClean ?? m?.poster, "w780"), maxPixel: width * 3) }
                    .clipped()
                LinearGradient(stops: [
                    .init(color: .clear, location: 0.45),
                    .init(color: .black.opacity(0.72), location: 1),
                ], startPoint: .top, endPoint: .bottom)
                Text(model.title(video))
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
                if let e = model.playback.entry(video.path), e.fraction > 0.01 {
                    ProgressCapsule(fraction: e.fraction)
                        .frame(width: 70)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.trailing, 14)
                        .padding(.bottom, 18)
                }
            }
            .frame(width: width, height: width * 224 / 399)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
            Text(addedLabel)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
                .lineLimit(1)
        }
        .frame(width: width, alignment: .leading)
    }

    /// 「今天」「昨天」「3 天前」「2 周前」（和网页版一样按入库时间算）
    private var addedLabel: String {
        guard let d = Relative.date(video.added) else { return model.year(video).map { String($0) } ?? " " }
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: d),
                                                    to: Calendar.current.startOfDay(for: Date())).day ?? 0
        switch days {
        case ..<1: return "今天"
        case 1: return "昨天"
        case 2..<7: return "\(days) 天前"
        case 7..<30: return "\(days / 7) 周前"
        case 30..<365: return "\(days / 30) 个月前"
        default: return "\(days / 365) 年前"
        }
    }
}

/// 网页版年份那一排的竖版卡（191 宽，圆角 14）：海报，下面片名与年份
struct PortraitCard: View {
    @Environment(AppModel.self) private var model
    let video: Video
    var width: CGFloat = 191

    var body: some View {
        let m = model.meta(video)
        VStack(alignment: .leading, spacing: 8) {
            RemoteImage(url: TMDBImage.url(m?.poster ?? m?.posterClean, "w342"), maxPixel: width * 3)
                .frame(width: width, height: width * 1.5)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
                .overlay(alignment: .bottom) {
                    if let e = model.playback.entry(video.path), e.fraction > 0.01 {
                        ProgressCapsule(fraction: e.fraction).padding(.horizontal, 10).padding(.bottom, 10)
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(model.title(video))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(m?.genres?.prefix(2).joined(separator: " · ") ?? (model.year(video).map { String($0) } ?? " "))
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
            }
        }
        .frame(width: width, alignment: .leading)
    }
}

/// 网页版「Cuven TV」那一大块：一张张竖着的高卡（两边露出邻卡），剧集字标压在卡的下部，下面「查看剧集 ›」；卡下一排页码
struct TVHeroRail: View {
    @Environment(AppModel.self) private var model
    let series: [Series]
    let width: CGFloat
    @State private var current: String?

    var body: some View {
        let side: CGFloat = max(40, width * 68 / 466)
        let cardW = max(220, width - side * 2)
        let cardH = cardW * 600 / 330
        VStack(spacing: 18) {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(series) { s in
                        ZoomLink(route: .series(s), slot: "tvhero") {
                            TVHeroCard(series: s, width: cardW, height: cardH)
                        }
                        .accessibilityIdentifier("series-card")
                        .seriesMenu(s)
                        .id(s.id)
                        .scrollTransition(.interactive, axis: .horizontal) { c, phase in
                            c.scaleEffect(phase.isIdentity ? 1 : 0.95).opacity(phase.isIdentity ? 1 : 0.7)
                        }
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, side, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $current)
            .frame(height: cardH)
            if series.count > 1 {
                PageDots(ids: series.map(\.id), current: $current)
            }
        }
    }
}

struct TVHeroCard: View {
    @Environment(AppModel.self) private var model
    let series: Series
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        let m = model.seriesMetas[series.path]
        ZStack(alignment: .bottom) {
            Color.clear
                .overlay { RemoteImage(url: TMDBImage.url(m?.posterClean ?? m?.poster ?? m?.backdrop, "w780"), maxPixel: width * 3) }
                .clipped()
            LinearGradient(stops: [
                .init(color: .clear, location: 0.5),
                .init(color: .black.opacity(0.55), location: 0.75),
                .init(color: .black.opacity(0.85), location: 1),
            ], startPoint: .top, endPoint: .bottom)
            VStack(spacing: 16) {
                LogoImage(url: TMDBImage.url(m?.logo, "w500"), height: 60, fallback: m?.title ?? series.name)
                    .frame(maxWidth: width * 0.8)
                HStack(spacing: 4) {
                    Text("查看剧集")
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold))
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 30)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
        .task { await model.ensureSeriesMeta(series) }
    }
}
