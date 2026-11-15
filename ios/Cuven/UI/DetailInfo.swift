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
        // 设计轮 2（并行·detail）：同一个明度 0.46，黄、绿、青比蓝、紫、红亮三四倍——黄绿的页面上，
        // 卡里的简介（浅色字压在 10% 白的卡上）和头部那一行灰字只有 3.3–3.6 : 1。按相对亮度封顶（≤ 0.10）：
        // 亮的色相压深一点（黄 0.46 → 0.36、绿 → 0.40），蓝、紫、红、橙本来就够深、不变；钉住的条按同一个比例
        let baseB = min(0.46, Self.brightnessCap(hue: h, saturation: sat))
        return DetailPalette(base: Color(hue: Double(h), saturation: Double(sat), brightness: Double(baseB)),
                             deep: Color(hue: Double(h), saturation: Double(sat * 0.85), brightness: 0.09),
                             ink2: Color(hue: Double(h), saturation: 0.26, brightness: 0.98),
                             badge: Color(hue: Double(h), saturation: 0.3, brightness: 1),
                             bar: Color(hue: Double(h), saturation: Double(sat), brightness: Double(min(0.52, baseB * 1.13))))
    }

    /// 这个色相、饱和度下，相对亮度不超过 target 的最大明度（HSB 里三个通道都和明度成正比，线性亮度约是明度的 2.2 次方）
    private static func brightnessCap(hue h: CGFloat, saturation s: CGFloat, luminance target: CGFloat = 0.10) -> CGFloat {
        var r: CGFloat = 0, g: CGFloat = 0, bl: CGFloat = 0, a: CGFloat = 0
        guard UIColor(hue: h, saturation: s, brightness: 1, alpha: 1).getRed(&r, green: &g, blue: &bl, alpha: &a) else { return 1 }
        func linear(_ c: CGFloat) -> CGFloat { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let full = 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(bl)
        guard full > target else { return 1 }
        return pow(target / full, 1 / 2.2)
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

/// 详情页、演员页的卡都是这一种面（设计轮 2（并行·detail）：以前演员页的两张卡各是圆角 30 / 26、底 10% / 8%、边 12% / 没有；
/// 卡里的字离边 24、22、18 三种，分隔线 20）。卡边、卡里的分隔线、钉住那一条的底线、小海报的细边是同一种亮度
enum DetailSurface {
    static let radius: CGFloat = 34
    static let fill = Color.white.opacity(0.1)
    /// 卡边、分隔线、底线、小海报的一圈细边
    static let line = Color.white.opacity(0.14)
    /// 卡里的字离左右两边（分隔线也从这儿起）
    static let inset: CGFloat = 20
}

/// 圆角 34 的半透明卡（参考图）
struct DetailCard<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DetailSurface.radius, style: .continuous)
        let still = reduceMotion
        VStack(spacing: 0) { content() }
            .background(shape.fill(DetailSurface.fill))
            .clipShape(shape)
            .overlay(shape.strokeBorder(DetailSurface.line, lineWidth: 1))
            // 滑进屏幕时从 97% 长到原大、淡入（参考图的手感）；「减弱动态效果」时只淡入、不缩放
            // （F59；系统不会替 scrollTransition 关掉缩放，以前这里的注释说会）
            .scrollTransition(.animated(.smooth(duration: 0.35))) { c, phase in
                c.opacity(phase.isIdentity ? 1 : 0.55).scaleEffect(phase.isIdentity || still ? 1 : 0.97)
            }
    }
}

/// 卡里两行之间的细线：右边缩进 20；左边和这一行的字对齐（前面有图标、海报的行，线从字那儿起，像 iOS 的列表）
struct DetailCardDivider: View {
    var leading: CGFloat = DetailSurface.inset

    var body: some View {
        Rectangle()
            .fill(DetailSurface.line)
            .frame(height: 0.5)
            .padding(.leading, leading)
            .padding(.trailing, DetailSurface.inset)
    }
}

/// 一组的标题：粗体大字，可以带「›」点进去。设计轮 1：和「剧集」「预告片」「剧照」「演员」同一个部件（DSSectionLabel），
/// 一页上不再两种标题交替出现
struct DetailGroupTitle: View {
    let title: String
    var route: Route? = nil

    var body: some View {
        if let route {
            NavigationLink(value: route) {
                label(chevron: true)
                    // 点得到的高度够 44（F74；Title 2 一行只有 28），版面上收回去，和别的组名一样高（同 DetailLinkHeader）
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle(scale: 0.98))
            .padding(.vertical, -10)
        } else {
            label(chevron: false)
        }
    }

    private func label(chevron: Bool) -> some View {
        DSSectionLabel(title: title, chevron: chevron)
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
                // 五行简介：松一点的行距（F21：三行以上不用紧行距）
                Text(overview)
                    .font(.dsReading)
                    .foregroundStyle(palette.ink2)
                    .lineLimit(5)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // 设计轮 2：字离边 24 → 20，和下面的分隔线、「导演」一行、别的卡同一条线（以前线在 20、字在 24，差 4 点）
                    .padding(.horizontal, DetailSurface.inset)
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
                .padding(.horizontal, DetailSurface.inset)
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

    /// 行里左边那一列（徽章、符号）的左边距和宽、到字的间距；行间的线从字那儿起（10 + 56 + 12）
    private static let leadPad: CGFloat = 10
    private static let leadW: CGFloat = 56
    private static let leadGap: CGFloat = 12

    var body: some View {
        DetailCard {
            ForEach(Array(facts.enumerated()), id: \.element.id) { i, f in
                if i > 0 { DetailCardDivider(leading: Self.leadPad + Self.leadW + Self.leadGap) }
                row(f)
            }
            if let link {
                if !facts.isEmpty { DetailCardDivider() }
                Link(destination: link) {
                    HStack(spacing: 8) {
                        Text("在 TMDB 中查看")
                        Image(systemName: "arrow.up.right")
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    // 点按区还是 44 点（F74）
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(DetailRowPress())
                .accessibilityIdentifier("detail-tmdb")
            }
        }
    }

    /// 一条事实。用户要求整张卡矮一半（约 527 → 265 点）：左边一列 84 → 56 点、大号评分 / 徽章 / 符号小一号；
    /// 主字和副字接成一行（「2026 年 · 第 1 季」「1080p · H.264」，文件名这种长的从中间省略），每行至少 34 点；
    /// 评分那一行是两行小字：星星 +「TMDB 评分」，下面「高于片库里 91% 的剧集」
    private func row(_ f: DetailFact) -> some View {
        HStack(spacing: Self.leadGap) {
            lead(f.lead)
                .frame(width: Self.leadW)
            Group {
                if case .rating(let r) = f.lead {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            DetailStars(value: r / 2, size: 12)
                            Text(f.text)
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(palette.ink2)
                        }
                        if let sub = f.sub, !sub.isEmpty {
                            Text(sub)
                                .font(.footnote)
                                .foregroundStyle(palette.ink2.opacity(0.8))
                        }
                    }
                    .lineLimit(1)
                } else {
                    Text([f.text, f.sub ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.subheadline)
                        .foregroundStyle(palette.ink2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            // 年份、片长、大小、百分比用等宽数字：一列行里的数字宽窄一致
            .monospacedDigit()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, Self.leadPad)
        .padding(.trailing, DetailSurface.inset)
        .padding(.vertical, 7)
        .frame(minHeight: 34)
        // 旁白（设计轮 2）：以前把左边那一列也念进去——「8.0，TMDB 评分…」「4K，4K · 杜比视界」「日历，2024 年上映」；
        // 现在评分念成一句「TMDB 评分 8.0 分，高于…」，徽章、符号是装饰（和右边的字重复），不念
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spoken(f))
    }

    static func spoken(_ f: DetailFact) -> String {
        var parts: [String] = [f.text]
        if case .rating(let r) = f.lead { parts = [f.text + " " + String(format: "%.1f", r) + " 分"] }
        if let sub = f.sub, !sub.isEmpty { parts.append(sub) }
        return parts.joined(separator: "，")
    }

    @ViewBuilder
    private func lead(_ l: DetailFact.Lead) -> some View {
        switch l {
        case .rating(let r):
            Text(String(format: "%.1f", r))
                .font(.system(size: 24, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
        case .badge(let code):
            Text(code)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(palette.badge)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 5)
                .frame(minWidth: 32, minHeight: 20)
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(palette.badge, lineWidth: 1.5))
        case .symbol(let s):
            Image(systemName: s)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
        }
    }
}

/// 五颗星（满分 5，半颗也画）
struct DetailStars: View {
    let value: Double
    var size: CGFloat = 17

    var body: some View {
        let v = (min(5, max(0, value)) * 2).rounded() / 2
        HStack(spacing: 3) {
            ForEach(0..<5, id: \.self) { i in
                let d = v - Double(i)
                Image(systemName: d >= 1 ? "star.fill" : (d >= 0.5 ? "star.leadinghalf.filled" : "star"))
            }
        }
        .font(.system(size: size, weight: .semibold))
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
                // 行间的线从片名那儿起（20 + 海报 52 + 16），不从海报底下穿过去（App Store 列表的样子）
                if i > 0 { DetailCardDivider(leading: DetailSurface.inset + 52 + 16) }
                NavigationLink(value: item.route) {
                    HStack(spacing: 16) {
                        RemoteImage(url: item.art, maxPixel: 240)
                            .frame(width: 52, height: 78)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(DetailSurface.line, lineWidth: 0.5))
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
                    .padding(.horizontal, DetailSurface.inset)
                    .padding(.vertical, 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(DetailRowPress())
                // 旁白念片名和「2024，爱情」，不再把只是样子的「查看」也念一遍（点的是整行）
                .accessibilityLabel(DetailText.spoken(DetailText.line([item.title, item.subtitle])))
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
                // 设计轮 2：小海报按 2:3 整张放（以前裁成 40×40 的方块，海报上的字切掉半截），圆角跟着小一号
                RemoteImage(url: thumb, maxPixel: 180)
                    .frame(width: 30, height: 45)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(DetailSurface.line, lineWidth: 0.5))
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.headline)
                .foregroundStyle(.white)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            Button(action: onPlay) {
                Text(playTitle.count > 4 ? "播放" : playTitle)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22)
                    .frame(minHeight: 40)
                    .glassEffect(.regular.tint(palette.base.opacity(0.35)).interactive(), in: Capsule())
                    // 看得见的胶囊 40 高，点得到的 44（F74）
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(playDisabled)
            .opacity(playDisabled ? 0.5 : 1)
            // 胶囊上只写「播放」，旁白念整句（「继续看第 3 集」）
            .accessibilityLabel(playTitle)
            .accessibilityIdentifier("detail-pinned-play")
        }
        // 条高是定的：特大字号时字封顶在 xxxLarge，不冲出条（系统的导航栏也这样）
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .padding(.leading, leading)
        .padding(.trailing, trailing)
        .frame(height: 60)
        .padding(.top, topInset)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity)
        .background {
            // 设计轮 2：带这一页颜色的磨砂（以前是一块实色）——底下滚过去的卡隐约透上来，条浮在内容上面、不像贴了一块色板；
            // 色压得够厚（86%），白字照样清楚。底线和卡边同一种亮度（10% → 14%），影子轻一点
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay { palette.bar.opacity(0.86) }
                .overlay(alignment: .bottom) {
                    Rectangle().fill(DetailSurface.line).frame(height: 0.5)
                }
                .shadow(color: .black.opacity(0.2), radius: 10, y: 3)
                .environment(\.colorScheme, .dark)
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

// MARK: - 剧照（设计轮 2（并行·stills）：照用户给的参考图——apple.com HomePod mini 的「近看」那一块）

/// 剧照浏览台（用户给的参考图）：标题「剧照」下面一整块铺满窗口宽的画面（连同 iPhone Duo 侧边那一列：F6），
/// 折起 4 : 3（Duo 折起约 466 × 350 点），展开也按 4 : 3、最多屏高的 60%；画面按 fill 铺满、底下一层淡暗，控件都留在安全区里（F7）。
/// · 总览：第一张剧照，底部一排 Liquid Glass 胶囊「⊕ 第 N 幕」（浮在画面上的控件：F40），横着滑、从侧边那一列底下过；
/// · 点一颗胶囊：画面原地换成那一张（交叉淡入、新的一张从 104% 落回原大；减弱动态效果时只淡入：F59），右上一颗玻璃 ✕ 回到总览；
///   底部一张磨砂说明卡（粗体「第 N 幕。」接一句平实的说明，旁白念成一句）；两侧 ‹ › 的圆心落在内容区的边上、外面那一半被切掉
///   （参考图），底边和说明卡齐平，一张一张换，到头的那一颗收起。画面有一截被顶上那条盖住或出了屏时，先把整块滚到可见区正中；
/// · 这时点画面：全屏看完整的大图（DetailStillsViewer，从这块画面上放大出来、收回到这块画面上：F57）
struct DetailStillsExplorer: View {
    let stills: [URL?]
    /// 片名（说明卡里那一句）
    let title: String
    let metrics: DSMetrics

    /// nil = 总览；有值 = 正在看第几张
    @State private var focus: Int?
    /// 全屏大图从第几张开始
    @State private var pick: DetailStillPick?
    /// 这块画面此刻有没有一截被顶上钉住的那条盖住、或者出了屏
    @State private var offStage = false
    /// 选了一张（胶囊、‹ ›）：一下选择触感；在大图里左右翻、回到总览不算（F41）
    @State private var picks = 0
    @Namespace private var zoomNS
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let stageID = "stills-stage"
    /// 解码的上限和全屏大图同一个数：内存里是同一张，点开大图不再解码一遍（TMDB 的 w1280 本来就不到这么大）
    private static let pixel: CGFloat = 2400

    private var fullWidth: CGFloat { metrics.width + metrics.leadingInset + metrics.trailingInset }
    /// 画面多高：4 : 3；展开时最多屏高的 60%（展开横拿只有六百多点高，上下文还要看得到）
    private var stageHeight: CGFloat {
        let byWidth = (fullWidth * 0.75).rounded()
        guard metrics.wide, metrics.height > 0 else { return byWidth }
        return max(240, min(byWidth, (metrics.height * 0.6).rounded()))
    }
    /// ✕、胶囊、说明卡离画面上下边
    private var edge: CGFloat { metrics.wide ? 24 : 16 }
    /// 换画面、换控件：DSMotion.appear 的弹簧；减弱动态效果时短淡入
    private var change: Animation { DSMotion.adapt(DSMotion.appear, reduce: reduceMotion) }
    private var imageTransition: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(insertion: .opacity.combined(with: .scale(scale: 1.04)), removal: .opacity)
    }
    private var controlsTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 10))
    }

    var body: some View {
        let m = metrics
        let shown = min(focus ?? 0, max(0, stills.count - 1))
        ScrollViewReader { proxy in
            ZStack(alignment: .bottom) {
                art(shown)
                if let i = focus {
                    focusControls(i)
                        .transition(controlsTransition)
                } else {
                    pills(proxy)
                        .transition(controlsTransition)
                }
            }
            .frame(width: fullWidth, height: stageHeight)
            .overlay(alignment: .topTrailing) {
                if focus != nil {
                    closeButton
                        .padding(.top, edge)
                        .padding(.trailing, m.margin + m.trailingInset)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.8)))
                }
            }
            .id(Self.stageID)
            .onGeometryChange(for: Bool.self) { p in
                // 上沿离屏顶不到屏高的 22%（顶上钉住的那条约 70–140 点高），或者下沿出了屏
                let f = p.frame(in: .scrollView(axis: .vertical))
                return m.height > 0 && (f.minY < m.height * 0.22 || f.maxY > m.height)
            } action: { offStage = $0 }
            // 画面铺到两侧安全区底下（侧边那一列）；这一块在页面里仍只占内容区那么宽
            .padding(.leading, -m.leadingInset)
            .padding(.trailing, -m.trailingInset)
        }
        .sensoryFeedback(.selection, trigger: picks)
        .task(id: focus) { await prefetch(around: focus ?? 0) }
        .fullScreenCover(item: $pick) { p in
            DetailStillsViewer(stills: stills, index: p.index) { i in follow(i) }
                .navigationTransition(.zoom(sourceID: Self.stageID, in: zoomNS))
        }
    }

    // MARK: 画面

    /// 画面：fill 铺满、裁在块的边上，底下一层淡暗（DSMediaCardStyle.shade：控件压在上面也分得开）；
    /// 换一张时交叉淡入，新的一张从 104% 落回原大。看某一张时整块是一颗钮：点它全屏看完整的大图
    private func art(_ i: Int) -> some View {
        let open = focus != nil
        let url: URL? = stills.indices.contains(i) ? stills[i] : nil
        return Button {
            pick = DetailStillPick(index: i)
        } label: {
            DSFill.placeholder
                .overlay {
                    ZStack {
                        RemoteImage(url: url, maxPixel: Self.pixel, placeholder: .clear)
                            .id(i)
                            .transition(imageTransition)
                    }
                }
                .overlay {
                    LinearGradient(stops: DSMediaCardStyle.shade, startPoint: .top, endPoint: .bottom)
                }
                .clipped()
                .contentShape(Rectangle())
        }
        // 按下去略暗一点（整块铺满的画面不缩放）
        .buttonStyle(PressableStyle(scale: 1))
        .disabled(!open)
        .matchedTransitionSource(id: Self.stageID, in: zoomNS)
        .accessibilityLabel("第 \(i + 1) 幕")
        .accessibilityHint("全屏查看完整大图")
        .accessibilityHidden(!open)
    }

    // MARK: 总览：一排胶囊

    /// 底部一排玻璃胶囊（参考图「⊕ Touch controls」）：横着滑，第一颗停在左边线上（内容边距 = 边距 + 那一侧的安全区），
    /// 滑过去时从侧边那一列底下过（和 dsBleedRow 同一个规矩：这一块本来就铺满了窗口宽，不用再往外撑）
    private func pills(_ proxy: ScrollViewProxy) -> some View {
        let m = metrics
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: m.wide ? 14 : 12) {
                ForEach(stills.indices, id: \.self) { i in
                    pill(i) { select(i, proxy: proxy) }
                }
            }
            // 玻璃按下去会鼓起来一点：上下留出这点空，不被滚动区切掉
            .padding(.vertical, 6)
            .scrollTargetLayout()
        }
        .contentMargins(.leading, m.margin + m.leadingInset, for: .scrollContent)
        .contentMargins(.trailing, m.margin + m.trailingInset, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
        .scrollClipDisabled()
        .padding(.bottom, edge - 6)
    }

    /// 一颗胶囊：⊕ +「第 N 幕」，折起 50、展开 56 点高（F74：至少 44）；Liquid Glass（浮在画面上的控件：F40），
    /// 按下去是玻璃自带的回弹，不再叠一层缩放（动效规范）
    private func pill(_ i: Int, action: @escaping () -> Void) -> some View {
        let wide = metrics.wide
        let labelFont: Font = wide ? .title3.weight(.semibold) : .headline
        return Button(action: action) {
            HStack(spacing: wide ? 12 : 10) {
                Image(systemName: "plus.circle")
                    .font(.title2)
                    .accessibilityHidden(true)
                Text("第 \(i + 1) 幕")
                    .font(labelFont)
                    .monospacedDigit()
            }
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.leading, wide ? 16 : 14)
            .padding(.trailing, wide ? 26 : 22)
            .frame(minHeight: wide ? 56 : 50)
            .glassEffect(.regular.interactive(), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityLabel("第 \(i + 1) 幕")
        .accessibilityHint("查看这张剧照")
        .accessibilityIdentifier("still-card")
    }

    // MARK: 看某一张：✕、说明卡、‹ ›

    /// ✕：右上一颗玻璃圆（折起 44、展开 48 点），在安全区里，回到总览（关闭的角色、标准的 xmark：C14）
    private var closeButton: some View {
        let d: CGFloat = metrics.wide ? 48 : 44
        return Button(role: .close) { close() } label: {
            Image(systemName: "xmark")
                .font(.system(size: (d * 0.38).rounded(), weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: d, height: d)
                .glassEffect(.regular.interactive(), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("关闭")
        .accessibilityIdentifier("stills-close")
    }

    /// 底部一张磨砂说明卡，两侧 ‹ ›：整组在安全区里，‹ › 外面那一半被安全区的边切掉（参考图里被屏幕边切掉的那样）
    private func focusControls(_ i: Int) -> some View {
        let m = metrics
        let d: CGFloat = m.wide ? 64 : 56
        // 说明卡让出 ‹ › 露出来的那一半，再空一点；展开时最宽 600（一行不至于太长）
        let inset = d / 2 + (m.wide ? 12 : 10)
        let cardMax: CGFloat = m.wide ? 600 : .infinity
        return ZStack(alignment: .bottom) {
            captionCard(i)
                .frame(maxWidth: cardMax)
                .padding(.horizontal, inset)
            HStack(alignment: .bottom, spacing: 0) {
                if i > 0 { paddle(forward: false, d: d) }
                Spacer(minLength: 0)
                if i < stills.count - 1 { paddle(forward: true, d: d) }
            }
        }
        .frame(width: m.width)
        .clipped()
        .padding(.leading, m.leadingInset)
        .padding(.trailing, m.trailingInset)
        .padding(.bottom, edge)
    }

    /// 说明卡（参考图那张磨砂圆角卡）：一段话——粗体「第 N 幕。」接一句平实的说明（数据里没有每张剧照的说明，不编剧情）。
    /// 画面上的字垫一层常规磨砂（深色），压在哪张剧照上都看得清（F34、F37）；圆角 24；旁白念成一句；
    /// 不接点按：点到它等于点画面（看大图）
    private func captionCard(_ i: Int) -> some View {
        Text(Self.caption(index: i, count: stills.count, title: title, wide: metrics.wide))
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, metrics.wide ? 24 : 20)
            .padding(.vertical, metrics.wide ? 20 : 16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .environment(\.colorScheme, .dark)
            .contentTransition(.opacity)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .allowsHitTesting(false)
            .accessibilityElement(children: .combine)
    }

    /// 「第 2 幕。《片名》的第 2 张剧照，共 12 张。轻点画面查看完整大图。」：一个 Text（不拼 Text + Text），
    /// 开头粗体白字，后面常规、次一级的白（DSInk.secondary）
    static func caption(index i: Int, count: Int, title: String, wide: Bool) -> AttributedString {
        let base: Font = wide ? .title3 : .body
        var lead = AttributedString("第 \(i + 1) 幕。")
        lead.font = base.weight(.semibold)
        lead.foregroundColor = Color.white
        let name = title.isEmpty ? "这部影片" : "《\(title)》"
        var rest = AttributedString("\(name)的第 \(i + 1) 张剧照，共 \(count) 张。轻点画面查看完整大图。")
        rest.font = base
        rest.foregroundColor = DSInk.secondary
        lead.append(rest)
        return lead
    }

    /// ‹ ›：玻璃圆（折起 56、展开 64 点），圆心落在内容区的边上、外面那一半被切掉（参考图）；
    /// 符号在露出来的那一半正中，点得到的范围从边上往里 44 点（F74）
    private func paddle(forward: Bool, d: CGFloat) -> some View {
        Button { step(forward ? 1 : -1) } label: {
            Image(systemName: forward ? "chevron.forward" : "chevron.backward")
                .font(.system(size: (d * 0.34).rounded(), weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: d / 2, height: d)
                .background(alignment: forward ? .leading : .trailing) {
                    Color.clear
                        .frame(width: d, height: d)
                        .glassEffect(.regular.interactive(), in: Circle())
                }
                .frame(width: max(44, d / 2), height: d, alignment: forward ? .trailing : .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(forward ? "下一张" : "上一张")
        .transition(.opacity)
    }

    // MARK: 动作

    /// 点一颗胶囊：原地换成那一张；画面有一截被盖住或出了屏，先把整块滚到可见区正中（✕ 和说明卡都看得见）
    private func select(_ i: Int, proxy: ScrollViewProxy) {
        picks += 1
        withAnimation(change) { focus = i }
        guard offStage else { return }
        withAnimation(DSMotion.adapt(DSMotion.hero, reduce: reduceMotion)) {
            proxy.scrollTo(Self.stageID, anchor: .center)
        }
    }

    /// ‹ ›：前一张 / 后一张
    private func step(_ delta: Int) {
        guard let i = focus, stills.indices.contains(i + delta) else { return }
        picks += 1
        withAnimation(change) { focus = i + delta }
    }

    /// ✕：回到总览（第一张 + 一排胶囊）
    private func close() {
        withAnimation(change) { focus = nil }
    }

    /// 大图里左右翻到哪一张，这里跟着换（不带动画、不给触感）：收回时缩回到同一张上
    private func follow(_ i: Int) {
        guard focus != nil, focus != i, stills.indices.contains(i) else { return }
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { focus = i }
    }

    /// 先把左右两张解码好放进内存：‹ ›、胶囊换过去时直接是它，不先闪一下底色
    private func prefetch(around i: Int) async {
        for j in [i + 1, i - 1, i + 2] where stills.indices.contains(j) {
            guard !Task.isCancelled, let url = stills[j] else { continue }
            _ = await ImagePipeline.shared.image(url, maxPixel: Self.pixel)
        }
    }
}

/// 剧照的大图：黑底，一张一屏、左右滑换下一张（底下页码点），标题是「第 N 幕」；
/// 右上系统的关闭钮（C14、C53），也能下滑或捏合收回到浏览台的画面上（F57）；翻到哪一张，浏览台跟着换
struct DetailStillsViewer: View {
    let stills: [URL?]
    @State var index: Int
    /// 翻到了第几张（浏览台跟着换，收回时缩回到同一张上）
    var onIndex: (Int) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TabView(selection: $index) {
                ForEach(Array(stills.enumerated()), id: \.offset) { i, url in
                    RemoteImage(url: url, maxPixel: 2400, contentMode: .fit, placeholder: .clear)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .tag(i)
                        .accessibilityLabel("第 \(i + 1) 幕")
                }
            }
            .tabViewStyle(.page(indexDisplayMode: stills.count > 1 ? .always : .never))
            .background(Color.black)
            .ignoresSafeArea()
            .navigationTitle("第 \(index + 1) 幕")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .close) { dismiss() }
                        .accessibilityIdentifier("stills-close")
                }
            }
            .onChange(of: index) { _, i in onIndex(i) }
        }
        .environment(\.colorScheme, .dark)
    }
}
