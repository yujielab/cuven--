import SwiftUI
import UIKit

// MARK: - 详情页的信息区：照用户给的参考图（Apple「游戏」App 的详情页）
//
// · 整页染上画面的颜色：头部画面底边取出来的主色（DetailPalette），头部字下面那一截是它，往下慢慢沉到同色相的深色；
// · 一组一行粗体标题 + 一张圆角 34 的半透明卡（10% 白、14% 白的细边），卡里的次要字是带这个颜色的浅色；
// · 「简介」卡：几行简介（点开看全文，从卡上放大出来）、分隔线、「导演」一行（大号首字圆章 + 灰字「导演」+ 白字名字）；
// · 「影片详细信息」卡：左边一列是大号评分 / 描边徽章（4K、GB、ZH…）/ 大符号，右边一行带颜色的字，行间细线，
//   最底下居中一行「在 TMDB 中查看 ↗」；
// · 「更多××电影 ›」卡：同类型的几部，一行一部（海报、片名、年份 · 类型、右边「查看」胶囊），整行点进详情；
// · 往上滚过头部，顶上钉住一条同色的条：海报、片名、「播放」胶囊（参考图里的「取得」）。
// 动效：钉住的条从上面滑下来（弹簧），卡滑进屏幕时从 97% 长到原大、淡入。

/// 整页的颜色（都从头部画面底边的主色来；还没取到色时是中性灰）
struct DetailPalette: Equatable {
    /// 头部字下面那一截、页顶
    var base: Color
    /// 页底
    var deep: Color
    /// 卡里的次要字：带一点颜色的浅色
    var ink2: Color
    /// 描边徽章
    var badge: Color
    /// 顶上钉住的那一条
    var bar: Color

    static let neutral = DetailPalette(base: Color(white: 0.2), deep: Color(white: 0.05),
                                       ink2: Color.white.opacity(0.66), badge: Color.white.opacity(0.78),
                                       bar: Color(white: 0.23))

    static func from(_ edge: UIColor?) -> DetailPalette {
        guard let edge else { return .neutral }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard edge.getHue(&h, saturation: &s, brightness: &b, alpha: &a), s > 0.12 else { return .neutral }
        let sat = min(0.78, max(0.38, s * 1.15))
        return DetailPalette(base: Color(hue: Double(h), saturation: Double(sat), brightness: 0.46),
                             deep: Color(hue: Double(h), saturation: Double(sat * 0.85), brightness: 0.09),
                             ink2: Color(hue: Double(h), saturation: 0.26, brightness: 0.98),
                             badge: Color(hue: Double(h), saturation: 0.3, brightness: 1),
                             bar: Color(hue: Double(h), saturation: Double(sat), brightness: 0.52))
    }

    /// 头部画面化进去的那个颜色（UIKit 版，给 DetailHeroBackdrop）
    static func baseColor(_ edge: UIColor?) -> Color { from(edge).base }
}

/// 「影片详细信息」里的一行
struct DetailFact: Identifiable {
    enum Lead {
        /// 大号评分（右边是星星）
        case rating(Double)
        /// 描边徽章：「4K」「GB」「ZH」
        case badge(String)
        /// 大符号
        case symbol(String)
    }

    let id: String
    let lead: Lead
    let text: String
    var sub: String? = nil
}

/// 「更多××」那一张卡里的一部
struct DetailRelatedItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let art: URL?
    let route: Route
}

/// 「更多××」：标题（点进全部）+ 几部
struct DetailRelated {
    let title: String
    let route: Route?
    let items: [DetailRelatedItem]
}

// MARK: - 卡

/// 圆角 34 的半透明卡（参考图）
struct DetailCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 34, style: .continuous)
        VStack(spacing: 0) { content() }
            .background(shape.fill(Color.white.opacity(0.1)))
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
            // 滑进屏幕时从 97% 长到原大、淡入（参考图的手感；「减弱动态效果」时系统会关掉）
            .scrollTransition(.animated(.smooth(duration: 0.35))) { c, phase in
                c.opacity(phase.isIdentity ? 1 : 0.55).scaleEffect(phase.isIdentity ? 1 : 0.97)
            }
    }
}

/// 卡里两行之间的细线（左右各缩进 20）
struct DetailCardDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.14))
            .frame(height: 0.5)
            .padding(.horizontal, 20)
    }
}

/// 一组的标题：粗体大字，可以带「›」点进去
struct DetailGroupTitle: View {
    let title: String
    var route: Route? = nil

    var body: some View {
        if let route {
            NavigationLink(value: route) { label(chevron: true) }
                .buttonStyle(.plain)
        } else {
            label(chevron: false)
        }
    }

    private func label(chevron: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.title2.bold())
                .foregroundStyle(.white)
                .lineLimit(1)
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - 简介卡

/// 几行简介（点开看全文）+ 分隔线 + 「导演」一行（参考图第三张：说明 + 开发者）
struct DetailDescriptionCard: View {
    let title: String
    let genres: [String]
    let overview: String
    /// 「导演」那一行：nil 就不画
    let director: String?
    let palette: DetailPalette
    @Namespace private var ns
    @State private var open: DetailAboutCard?

    var body: some View {
        let card = DetailAboutCard.synopsis(title: title, genres: genres, overview: overview)
        DetailCard {
            Button {
                Haptics.light()
                open = card
            } label: {
                Text(overview)
                    .font(.body)
                    .foregroundStyle(palette.ink2)
                    .lineLimit(5)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.top, 22)
                    .padding(.bottom, director == nil ? 22 : 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(DetailRowPress())
            .matchedTransitionSource(id: "synopsis", in: ns)
            .accessibilityLabel("简介：" + overview)
            .accessibilityHint("打开简介")
            .accessibilityIdentifier("about-synopsis")
            if let director, !director.isEmpty {
                DetailCardDivider()
                HStack(spacing: 18) {
                    Text(String(director.prefix(1)))
                        .font(.system(size: 26, weight: .heavy, design: .rounded))
                        .foregroundStyle(palette.badge)
                        .frame(width: 58, height: 58)
                        .background(Circle().fill(palette.badge.opacity(0.16)))
                        .overlay(Circle().strokeBorder(palette.badge.opacity(0.5), lineWidth: 1.5))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("导演")
                            .font(.callout)
                            .foregroundStyle(palette.ink2)
                        Text(director)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
                .accessibilityElement(children: .combine)
            }
        }
        .sheet(item: $open) { c in
            DetailAboutSheet(card: c)
                .navigationTransition(.zoom(sourceID: "synopsis", in: ns))
        }
    }
}

// MARK: - 影片详细信息卡

struct DetailFactsCard: View {
    let facts: [DetailFact]
    /// 「在 TMDB 中查看 ↗」
    let link: URL?
    let palette: DetailPalette

    var body: some View {
        DetailCard {
            ForEach(Array(facts.enumerated()), id: \.element.id) { i, f in
                if i > 0 { DetailCardDivider() }
                row(f)
            }
            if let link {
                if !facts.isEmpty { DetailCardDivider() }
                Link(destination: link) {
                    HStack(spacing: 8) {
                        Text("在 TMDB 中查看")
                        Image(systemName: "arrow.up.right")
                    }
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 60)
                    .contentShape(Rectangle())
                }
                .buttonStyle(DetailRowPress())
                .accessibilityIdentifier("detail-tmdb")
            }
        }
    }

    private func row(_ f: DetailFact) -> some View {
        HStack(spacing: 18) {
            lead(f.lead)
                .frame(width: 84)
            VStack(alignment: .leading, spacing: 4) {
                if case .rating(let r) = f.lead {
                    DetailStars(value: r / 2)
                }
                Text(f.text)
                    .font(.title3)
                    .foregroundStyle(palette.ink2)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let sub = f.sub, !sub.isEmpty {
                    Text(sub)
                        .font(.callout)
                        .foregroundStyle(palette.ink2.opacity(0.8))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 12)
        .padding(.trailing, 20)
        .padding(.vertical, 14)
        .frame(minHeight: 78)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func lead(_ l: DetailFact.Lead) -> some View {
        switch l {
        case .rating(let r):
            Text(String(format: "%.1f", r))
                .font(.system(size: 38, weight: .bold))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
        case .badge(let code):
            Text(code)
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(palette.badge)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 7)
                .frame(minWidth: 46, minHeight: 30)
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(palette.badge, lineWidth: 2.5))
        case .symbol(let s):
            Image(systemName: s)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white)
        }
    }
}

/// 五颗星（满分 5，半颗也画）
struct DetailStars: View {
    let value: Double

    var body: some View {
        let v = (min(5, max(0, value)) * 2).rounded() / 2
        HStack(spacing: 3) {
            ForEach(0..<5, id: \.self) { i in
                let d = v - Double(i)
                Image(systemName: d >= 1 ? "star.fill" : (d >= 0.5 ? "star.leadinghalf.filled" : "star"))
            }
        }
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(.white)
        .accessibilityHidden(true)
    }
}

// MARK: - 更多××

struct DetailRelatedCard: View {
    let related: DetailRelated
    let palette: DetailPalette

    var body: some View {
        DetailCard {
            ForEach(Array(related.items.enumerated()), id: \.element.id) { i, item in
                if i > 0 { DetailCardDivider() }
                NavigationLink(value: item.route) {
                    HStack(spacing: 16) {
                        RemoteImage(url: item.art, maxPixel: 240)
                            .frame(width: 52, height: 78)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title)
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            if !item.subtitle.isEmpty {
                                Text(item.subtitle)
                                    .font(.callout)
                                    .foregroundStyle(palette.ink2)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 8)
                        Text("查看")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18)
                            .frame(minHeight: 34)
                            .background(Capsule().fill(Color.white.opacity(0.16)))
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(DetailRowPress())
                .accessibilityIdentifier("related-card")
            }
        }
    }
}

// MARK: - 钉在顶上的条

/// 往上滚过头部以后钉在顶上：海报、片名、「播放」胶囊（参考图的「取得」）
struct DetailPinnedBar: View {
    let title: String
    let thumb: URL?
    let playTitle: String
    let playDisabled: Bool
    let palette: DetailPalette
    let topInset: CGFloat
    let leading: CGFloat
    let trailing: CGFloat
    let onPlay: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            if let thumb {
                RemoteImage(url: thumb, maxPixel: 180)
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.headline)
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button(action: onPlay) {
                Text(playTitle.count > 4 ? "播放" : playTitle)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22)
                    .frame(minHeight: 40)
                    .glassEffect(.regular.tint(palette.base.opacity(0.35)).interactive(), in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(playDisabled)
            .opacity(playDisabled ? 0.5 : 1)
            .accessibilityIdentifier("detail-pinned-play")
        }
        .padding(.leading, leading)
        .padding(.trailing, trailing)
        .frame(height: 60)
        .padding(.top, topInset)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity)
        .background {
            palette.bar
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Color.white.opacity(0.1)).frame(height: 0.5)
                }
                .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        }
    }
}

/// 整行可点的按下效果：底上一层淡白
struct DetailRowPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.white.opacity(configuration.isPressed ? 0.08 : 0))
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - 文字

enum DetailFacts {
    /// 类型 → 符号（参考图里「角色扮演」那一行左边的大图标）
    static func genreSymbol(_ g: String?) -> String {
        switch g ?? "" {
        case "动作": return "bolt.fill"
        case "冒险": return "map.fill"
        case "动画": return "paintpalette.fill"
        case "喜剧": return "face.smiling.inverse"
        case "犯罪": return "magnifyingglass"
        case "纪录": return "video.fill"
        case "剧情": return "theatermasks.fill"
        case "家庭": return "figure.2.and.child.holdinghands"
        case "奇幻": return "wand.and.stars"
        case "历史": return "building.columns.fill"
        case "恐怖": return "moon.fill"
        case "音乐": return "music.note"
        case "悬疑": return "questionmark.circle.fill"
        case "爱情": return "heart.fill"
        case "科幻": return "sparkles"
        case "惊悚": return "exclamationmark.triangle.fill"
        case "战争": return "shield.lefthalf.filled"
        case "西部": return "sun.dust.fill"
        case "电视电影": return "tv.fill"
        default: return "film.fill"
        }
    }

    /// 文件大小的单位做徽章：「58.3 GB」→「GB」
    static func sizeBadge(_ size: String) -> String {
        size.split(separator: " ").last.map(String.init)?.uppercased() ?? "GB"
    }

    /// 语言 → 两个字母的徽章（参考图「ZH」）
    static func languageBadge(_ lang: String) -> String {
        let l = lang.lowercased()
        if l.contains("国") || l.contains("中") || l.contains("粤") || l.contains("zh") || l.contains("chi") { return "ZH" }
        if l.contains("英") || l.contains("en") { return "EN" }
        if l.contains("日") || l.contains("ja") { return "JA" }
        if l.contains("韩") || l.contains("ko") { return "KO" }
        if l.contains("法") || l.contains("fr") { return "FR" }
        if l.contains("西") || l.contains("es") { return "ES" }
        if l.contains("德") || l.contains("de") { return "DE" }
        return String(lang.prefix(2)).uppercased()
    }

    /// 评分那一行的字：「TMDB 评分」，在片库里排得靠前时补一句
    static func ratingText(percentile: Int?, pool: String) -> (String, String?) {
        if let p = percentile, p >= 50 { return ("TMDB 评分", "高于片库里 \(p)% 的\(pool)") }
        return ("TMDB 评分", "满分 10 分")
    }
}
