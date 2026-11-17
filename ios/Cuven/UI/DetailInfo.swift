import SwiftUI
import UIKit

// MARK: - 详情页的信息区：照用户给的参考图（Apple「游戏」App 的详情页）
//
// · 整页染上画面的颜色：头部画面底边取出来的主色（DetailPalette），头部字下面那一截是它，往下慢慢沉到同色相的深色；
// · 一组一行粗体标题 + 一张圆角 34 的半透明卡（10% 白、14% 白的细边），卡里的次要字是带这个颜色的浅色；
// · 「简介」卡：几行简介（点开看全文，从卡上放大出来）、分隔线、「导演」一行（大号首字圆章 + 灰字「导演」+ 白字名字）；
// · 「影片详细信息」卡：用户要求只留上映时间、时长、流量能效（高 / 中 / 低）、推荐等级（高 / 中 / 低），不跳 TMDB；
//   左边一列是符号或描边徽章（「高」「中」「低」），右边一行带颜色的字，行间细线；
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
    /// 旁白念什么（左边那一列是「高 / 中 / 低」这种右边字里没有的值时，要念进去）
    var spoken: String? = nil
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

/// 用户要求只留四行：上映时间、时长、流量能效（高 / 中 / 低）、推荐等级（高 / 中 / 低），不再跳到 TMDB
/// （以前还有评分星星、类型、画面、声音、文件，最底下「在 TMDB 中查看 ↗」）
struct DetailFactsCard: View {
    let facts: [DetailFact]
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
        if let s = f.spoken { return s }
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

/// 「更多××电影 ›」那张卡（用户要求改善视觉效果、高度宽度和设计）：
/// · 窄屏（iPhone、折起的 Duo）：一列三行。海报 46 × 69（以前 52 × 78），片名 Headline、最多两行（以前 Title 3 一行，
///   「Spider-Man…」「铁血战士：…」被截掉），下面一行「2021 · 动作 · ★ 8.2」，右边一颗小一号的「查看」（30 高）；一行约 90 点（以前约 106）。
/// · 宽屏（展开的 Duo、iPad）：三部并排成一行（中间一条细竖线），「查看」放在字下面——整张卡从三行矮成一行，不再横着空出一大片。
/// 整行（整格）点进详情；海报带一层细边和柔影
struct DetailRelatedCard: View {
    let related: DetailRelated
    let palette: DetailPalette
    var wide = false

    private static let compactPoster = CGSize(width: 46, height: 69)
    private static let widePoster = CGSize(width: 56, height: 84)
    private static let gap: CGFloat = 14

    var body: some View {
        DetailCard {
            if wide {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(related.items.enumerated()), id: \.element.id) { i, item in
                        if i > 0 {
                            Rectangle().fill(DetailSurface.line).frame(width: 0.5).padding(.vertical, 20)
                        }
                        link(item) { tile(item, poster: Self.widePoster, pillBelow: true) }
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else {
                ForEach(Array(related.items.enumerated()), id: \.element.id) { i, item in
                    // 行间的线从片名那儿起，不从海报底下穿过去（App Store 列表的样子）
                    if i > 0 { DetailCardDivider(leading: DetailSurface.inset + Self.compactPoster.width + Self.gap) }
                    link(item) { tile(item, poster: Self.compactPoster, pillBelow: false) }
                }
            }
        }
    }

    private func link<L: View>(_ item: DetailRelatedItem, @ViewBuilder label: () -> L) -> some View {
        NavigationLink(value: item.route) { label() }
            .buttonStyle(DetailRowPress())
            // 旁白念片名和「2024，爱情」，不再把只是样子的「查看」也念一遍（点的是整行）
            .accessibilityLabel(DetailText.spoken(DetailText.line([item.title, item.subtitle])))
            .accessibilityIdentifier("related-card")
    }

    private func tile(_ item: DetailRelatedItem, poster: CGSize, pillBelow: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: (poster.width * 0.19).rounded(), style: .continuous)
        return HStack(alignment: pillBelow ? .top : .center, spacing: Self.gap) {
            RemoteImage(url: item.art, maxPixel: 240)
                .frame(width: poster.width, height: poster.height)
                .clipShape(shape)
                .overlay(shape.strokeBorder(DetailSurface.line, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.28), radius: 5, y: 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(palette.ink2)
                        .lineLimit(1)
                }
                if pillBelow { pill.padding(.top, 8) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !pillBelow { pill }
        }
        .padding(.horizontal, pillBelow ? 18 : DetailSurface.inset)
        .padding(.vertical, pillBelow ? 18 : 11)
        .contentShape(Rectangle())
    }

    /// 「查看」：小一号（30 高、左右 14；以前 34 高、左右 18），只是样子——点的是整行
    private var pill: some View {
        Text("查看")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(minHeight: 30)
            .background(Capsule().fill(Color.white.opacity(0.16)))
            .accessibilityHidden(true)
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

    // MARK: 用户要求的四行：上映时间、时长、流量能效、推荐等级

    enum Level: String {
        case high = "高", mid = "中", low = "低"
    }

    /// 上映时间：有完整日期写到哪一天（「2026 年 7 月 29 日上映」），没有就写年份
    static func releaseText(_ date: String?, year: Int?, verb: String = "上映") -> String? {
        if let d = date, d.count >= 10 {
            let p = d.prefix(10).split(separator: "-").compactMap { Int($0) }
            if p.count == 3, p[0] > 1800 { return "\(p[0]) 年 \(p[1]) 月 \(p[2]) 日\(verb)" }
        }
        return year.map { "\($0) 年\(verb)" }
    }

    /// 流量能效：放这一部每小时大约要下载多少——片源原样直通、不转码，就是文件大小 ÷ 片长。越省越高：
    /// 每小时 4 GB 以内（约 9 Mbps 以下）高，4–12 GB 中（4K 网络版多在这里），12 GB 以上低（4K 原盘）
    static func efficiency(bytes: Int64?, minutes: Int?) -> (level: Level, perHour: String)? {
        guard let b = bytes, b > 0, let m = minutes, m > 0 else { return nil }
        let perHour = Double(b) / 1e9 / (Double(m) / 60)
        let level: Level = perHour <= 4 ? .high : perHour <= 12 ? .mid : .low
        let shown = perHour < 1 ? "约 \(Int((perHour * 1000).rounded())) MB / 小时" : String(format: "约 %.1f GB / 小时", perHour)
        return (level, shown)
    }

    /// 推荐等级：TMDB 评分 7.5 以上高（和主页「严苛品质区」同一条线）、6 以上中、再低是低
    static func recommendation(_ rating: Double?) -> Level? {
        guard let r = rating, r > 0 else { return nil }
        return r >= PremiumBar.minRating ? .high : r >= 6 ? .mid : .low
    }

    /// 评分那一行的字：「TMDB 评分」，在片库里排得靠前时补一句
    static func ratingText(percentile: Int?, pool: String) -> (String, String?) {
        if let p = percentile, p >= 50 { return ("TMDB 评分", "高于片库里 \(p)% 的\(pool)") }
        return ("TMDB 评分", "满分 10 分")
    }
}

// MARK: - 剧照（用户要求：和预告片合成一组、同一横排，用间距分开；卡和预告片卡完全一样）

/// 一张剧照卡：就是预告片卡那一种（`DSMediaCard`：16:9、大圆角，画面下段渐进式模糊 + 一层淡暗，
/// 模糊上压「第 3 幕」和「▣ 12 张剧照」，右下「•••」），一排里高矮、圆角、字都和预告片一样；整张卡点开看大图
struct DetailStillCard: View {
    let art: URL?
    let title: String
    let detail: String
    let metrics: DSMetrics
    let action: () -> Void

    var body: some View {
        DSMediaCard(art: art, title: title, detail: detail, glyph: "photo.on.rectangle",
                    metrics: metrics, identifier: "still-card", action: action) {
            Button("查看大图", systemImage: "arrow.up.left.and.arrow.down.right", action: action)
        }
    }
}

/// 剧照的大图：黑底，一张一屏、左右滑换下一张（底下页码点），标题是「第 N 幕」；
/// 右上系统的关闭钮（C14、C53），也能下滑或捏合收回到那张卡（F57）
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
