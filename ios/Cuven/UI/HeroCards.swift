import SwiftUI

// MARK: - 首页大图：卡片态
//
// 用在「矮而宽」的紧凑宽度屏上（iPhone Duo 折起时的外屏：比别的 iPhone 宽、矮，系统栏在侧边那一列）：
// App Store「Today」/「新作快报」那种卡：一张张并排，右边露出下一张，卡下一排圆点（iOS 页码控件样式），不自动轮播。
// 卡上：类型（小字）、字标、一句简介；最下面一条毛玻璃带：小海报、片名与信息、「播放」胶囊。
// 何时用由主页按可用空间的宽高比决定（见 HomeView），不认设备型号。

struct HeroCards: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let items: [HeroItem]
    let width: CGFloat
    /// 卡片高度（不含下面那排圆点）
    let cardHeight: CGFloat
    @State private var current: String?

    var body: some View {
        let gap: CGFloat = Theme.gutter, spacing: CGFloat = 12
        let calm = reduceMotion
        let cardW = max(200, width - gap * 2)
        let cardH = max(300, cardHeight)
        VStack(spacing: 16) {
            if items.isEmpty {
                RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Theme.surface)
                    .frame(width: cardW, height: cardH)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: spacing) {
                        ForEach(items) { it in
                            ZoomLink(route: .movie(it.video), slot: "herocard") {
                                HeroCard(item: it, width: cardW, height: cardH)
                            }
                            .accessibilityIdentifier("hero-card")
                            // 「播放」胶囊叠在卡片上（不嵌在链接里）：对准最下面那条毛玻璃带的右端
                            .overlay(alignment: .bottomTrailing) {
                                PlayPill(video: it.video, onArt: true)
                                    .frame(height: HeroCard.band)
                                    .padding(.trailing, 18)
                            }
                            .id(it.id)
                            // 翻卡时两侧的卡略缩、略暗（Apple TV 卡片轮播的手感）
                            .scrollTransition(.interactive, axis: .horizontal) { content, phase in
                                content
                                    .scaleEffect(phase.isIdentity || calm ? 1 : 0.94)
                                    .opacity(phase.isIdentity ? 1 : 0.75)
                            }
                        }
                    }
                    .scrollTargetLayout()
                }
                .contentMargins(.horizontal, gap, for: .scrollContent)
                .scrollTargetBehavior(.viewAligned)
                .scrollPosition(id: $current)
                .frame(height: cardH)

                if items.count > 1 {
                    PageDots(ids: items.map(\.id), current: $current)
                }
            }
        }
        .frame(width: width, alignment: .top)
    }
}

struct HeroCard: View {
    @Environment(AppModel.self) private var model
    let item: HeroItem
    let width: CGFloat
    let height: CGFloat
    /// 最下面那条毛玻璃带的高度（「播放」胶囊按它对齐）
    static let band: CGFloat = 84

    var body: some View {
        let m = model.meta(item.video)
        let title = model.title(item.video)
        ZStack(alignment: .bottom) {
            Color.clear
                .overlay { RemoteImage(url: URL(string: item.hero.poster ?? item.hero.background ?? ""), maxPixel: 1100) }
                .clipped()
            LinearGradient(stops: [
                .init(color: .clear, location: 0.3),
                .init(color: .black.opacity(0.5), location: 0.62),
                .init(color: .black.opacity(0.78), location: 1),
            ], startPoint: .top, endPoint: .bottom)

            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 7) {
                    if let eyebrow = eyebrow(m) {
                        Text(eyebrow)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.72))
                    }
                    LogoImage(url: URL(string: item.hero.logo ?? "") ?? TMDBImage.url(m?.logo, "w500"), height: 50,
                              alignment: .leading, fallback: title)
                        .frame(maxWidth: width * 0.78, alignment: .leading)
                    if let line = tagline(m) {
                        Text(line)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white.opacity(0.86))
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)

                HStack(spacing: 12) {
                    RemoteImage(url: TMDBImage.url(m?.poster ?? m?.posterClean, "w185"), maxPixel: 200)
                        .frame(width: 38, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(info(m))
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 96)          // 右边留给叠在上面的「播放」胶囊
                }
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity)
                .frame(height: Self.band)
                .background(.ultraThinMaterial)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.45), radius: 18, y: 10)
    }

    /// 卡片最上面那行小字：类型
    private func eyebrow(_ m: Meta?) -> String? {
        guard let g = m?.genres, !g.isEmpty else { return nil }
        return g.prefix(2).joined(separator: " · ")
    }

    /// 一句简介：简介的第一句（太短就整段），最多两行
    private func tagline(_ m: Meta?) -> String? {
        guard let o = m?.overview?.trimmingCharacters(in: .whitespacesAndNewlines), !o.isEmpty else { return nil }
        let stops: Set<Character> = ["。", "！", "？", ".", "!", "?"]
        if let i = o.firstIndex(where: { stops.contains($0) }), o.distance(from: o.startIndex, to: i) >= 8 {
            return String(o[...i])
        }
        return o
    }

    private func info(_ m: Meta?) -> String {
        var parts: [String] = []
        if let y = model.year(item.video) { parts.append(String(y)) }
        let rt = Format.runtime(m?.runtime)
        if !rt.isEmpty { parts.append(rt) }
        if let r = m?.rating, r > 0 { parts.append(String(format: "★ %.1f", r)) }
        return parts.isEmpty ? "电影" : parts.joined(separator: " · ")
    }
}

/// 页码：玻璃胶囊里一排圆点，当前那颗是纯白的短胶囊，其余半透明；点哪颗翻到哪张
struct PageDots: View {
    let ids: [String]
    @Binding var current: String?

    var body: some View {
        let cur = current ?? ids.first
        HStack(spacing: 9) {
            ForEach(ids, id: \.self) { id in
                // 当前这一页是一颗短胶囊（Games「首页」的页码），其余是圆点
                Capsule()
                    .fill(id == cur ? Color.white : Color.white.opacity(0.5))
                    .frame(width: id == cur ? 20 : 7, height: 7)
                    .contentShape(Rectangle().inset(by: -6))
                    .onTapGesture { withAnimation(.snappy) { current = id } }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .glassEffect(.regular, in: Capsule())
        .animation(.snappy, value: current)
    }
}
