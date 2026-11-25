import SwiftUI
import UIKit

// MARK: - 详情页的信息区：照用户给的参考图（Apple「游戏」App 的详情页）
//
// · 整页染上画面的颜色：头部画面底边取出来的主色（DetailPalette），头部字下面那一截是它，往下慢慢沉到同色相的深色；
// · 一组一行粗体标题 + 一张圆角 34 的半透明卡（10% 白、14% 白的细边），卡里的次要字是带这个颜色的浅色；
// · 「简介」卡：四行简介（点开看全文，从卡上放大出来）、分隔线、「导演」一行（小号首字圆章 + 灰字「导演」+ 白字名字）；
// · 「影片详细信息」：用户要求只留上映时间、时长、流量能效（高 / 中 / 低）、推荐等级（高 / 中 / 低），不跳 TMDB；
//   版式照用户给的天气 App 参考图——一块块正方形的方块（见下面 DetailStatsGrid）；
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
/// 卡里的字离边 24、22、18 三种，分隔线 20）。卡边、卡里的分隔线、小海报的细边是同一种亮度（钉住那一条没有底线：渐进式模糊淡出去）
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
                // 用户要求简介卡「宽度高度和设计优雅精致」：字 Body → Callout（17 → 16 点，仍是松行距：F21 三行以上不用紧行距），
                // 五行 → 四行，上下留白收一点——卡矮了约四分之一，字那一栏一行能多放一两个字；点开看全文
                Text(overview)
                    .font(.callout.leading(.loose))
                    .foregroundStyle(palette.ink2)
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // 设计轮 2：字离边 24 → 20，和下面的分隔线、「导演」一行、别的卡同一条线（以前线在 20、字在 24，差 4 点）
                    .padding(.horizontal, DetailSurface.inset)
                    .padding(.top, 18)
                    .padding(.bottom, director == nil ? 18 : 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(DetailRowPress())
            .matchedTransitionSource(id: "synopsis", in: ns)
            .accessibilityLabel("简介：" + overview)
            .accessibilityHint("打开简介")
            .accessibilityIdentifier("about-synopsis")
            if let director, !director.isEmpty {
                DetailCardDivider()
                // 「导演」一行收小（用户要求精致）：首字圆章 58 → 38 点，「导演」Callout → Footnote，名字 Title 3 → Headline，上下 18 → 12
                HStack(spacing: 12) {
                    Text(String(director.prefix(1)))
                        .font(.system(size: 17, weight: .heavy, design: .rounded))
                        .foregroundStyle(palette.badge)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(palette.badge.opacity(0.16)))
                        .overlay(Circle().strokeBorder(palette.badge.opacity(0.5), lineWidth: 1))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("导演")
                            .font(.footnote)
                            .foregroundStyle(palette.ink2)
                        Text(director)
                            .font(.headline)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, DetailSurface.inset)
                .padding(.vertical, 12)
                .accessibilityElement(children: .combine)
            }
        }
        .sheet(item: $open) { c in
            DetailAboutSheet(card: c)
                .navigationTransition(.zoom(sourceID: "synopsis", in: ns))
        }
    }
}

// MARK: - 影片详细信息：天气 App 那种方块
//
// 用户要求「更新详情设计」，给的参考图是天气 App 的「降水 / 能见度 / 湿度 / 气压」那几块。内容还是用户定的四样
// （上映时间、时长、流量能效（高 / 中 / 低）、推荐等级（高 / 中 / 低），不跳 TMDB），版式换成一块块正方形：
// · 一块一样东西：左上一枚小符号 + 灰字标题；
// · 上映、时长两块：大号的数（单位和数一样大，像「19 公里」）、下面一行小标题（「2026 年」「2 小时 25 分钟」），
//   最底下一句平实的话（「3 个月前上映。」「现在开始看，约 23:05 看完。」——每分钟跟着现在的时间走）；
// · 流量能效、推荐等级两块是刻度盘（像「气压」）：一圈 270° 的刻度，低在左下、高在右下，白色的指针停在这一部的位置
//   （第一次出现时从「低」那一头转过去；减弱动态效果时直接停好），圆心里是大号的「高 / 中 / 低」和一行小字；
//   刻度三等分正好是三档：能效按每小时下载量的对数排（4 GB、12 GB 两条线落在三分之一处），推荐按 TMDB 评分（6、7.5 两条线）；
// · 正方形、圆角 24、和别的卡同一种面（10% 白、14% 白的细边）；窄屏一行两块，宽屏（展开的 Duo、iPad）一行四块。

/// 四块的数据（哪样没有就少一块）
struct DetailStats {
    struct Release {
        /// 有完整的年月日
        var date: Date?
        var year: Int?
        /// 「上映」「首播」
        var verb: String
        /// 剧集：「第 1 季」
        var season: String?
    }

    struct Runtime {
        var minutes: Int
        /// 剧集：每一集
        var perEpisode: Bool
    }

    struct Efficiency {
        var level: DetailFacts.Level
        /// 每小时大约下载多少 GB
        var gbPerHour: Double
    }

    var release: Release?
    var runtime: Runtime?
    var efficiency: Efficiency?
    /// TMDB 评分
    var rating: Double?

    var isEmpty: Bool { release == nil && runtime == nil && efficiency == nil && rating == nil }
}

/// 「影片详细信息」那几块
struct DetailStatsGrid: View {
    let stats: DetailStats
    let palette: DetailPalette
    /// 宽的屏一行四块
    let wide: Bool
    /// 方块与方块之间（左右、上下一样）：详情页传全局卡距（折起 18 起、展开 24 起）进来，和页上别的卡一样松；
    /// 以前写死 12，方块挤成一面墙（用户要求「保持一定的留白，整个界面看上去不会拥挤」）
    var spacing: CGFloat = 12

    private enum Tile: String, Identifiable {
        case release, runtime, efficiency, rating
        var id: String { rawValue }
    }

    /// 有哪几块（顺序是用户定的：上映、时长、流量能效、推荐等级）
    private var tiles: [Tile] {
        var out: [Tile] = []
        if stats.release != nil { out.append(.release) }
        if stats.runtime != nil { out.append(.runtime) }
        if stats.efficiency != nil { out.append(.efficiency) }
        if stats.rating != nil { out.append(.rating) }
        return out
    }

    var body: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: spacing, alignment: .top), count: wide ? 4 : 2)
        LazyVGrid(columns: columns, alignment: .leading, spacing: spacing) {
            ForEach(tiles) { t in
                tile(t)
            }
        }
    }

    @ViewBuilder
    private func tile(_ t: Tile) -> some View {
        switch t {
        case .release:
            if let r = stats.release { DetailReleaseTile(release: r, palette: palette) }
        case .runtime:
            if let r = stats.runtime { DetailRuntimeTile(runtime: r, palette: palette) }
        case .efficiency:
            if let e = stats.efficiency {
                DetailGaugeTile(symbol: "arrow.down.circle.fill", title: "流量能效", level: e.level,
                                caption: DetailFacts.perHourCaption(e.gbPerHour),
                                position: DetailFacts.efficiencyPosition(e.gbPerHour), palette: palette,
                                spoken: "流量能效\(e.level.rawValue)，\(DetailFacts.perHourText(e.gbPerHour).replacingOccurrences(of: "/", with: "每"))")
            }
        case .rating:
            if let r = stats.rating, let lv = DetailFacts.recommendation(r) {
                let score = String(format: "%.1f", r)
                DetailGaugeTile(symbol: "star.fill", title: "推荐等级", level: lv, caption: "\(score) 分",
                                position: DetailFacts.ratingPosition(r), palette: palette,
                                spoken: "推荐等级\(lv.rawValue)，评分 \(score) 分")
            }
        }
    }
}

/// 一块方块的面：正方形、圆角 22、左上一枚小符号 + 灰字标题（Footnote 半粗），下面是内容。
/// 用户要求「优化间距和大小」（截图里大号的数顶到两边、刻度盘中间的小字压到刻度上）：字都小一号，留白照天气 App
struct DetailStatTileChrome<Content: View>: View {
    let symbol: String
    let title: String
    let palette: DetailPalette
    @ViewBuilder var content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 5) {
                        Image(systemName: symbol)
                        Text(title)
                    }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(palette.ink2.opacity(0.72))
                    .lineLimit(1)
                    content()
                }
                .padding(.horizontal, 16)
                .padding(.top, 15)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .background(shape.fill(DetailSurface.fill))
            .overlay(shape.strokeBorder(DetailSurface.line, lineWidth: 1))
            .clipShape(shape)
            // 方块是定死的正方形：字放大也不冲出去（放到 xLarge 为止，再大的数按比例收）
            .dynamicTypeSize(...DynamicTypeSize.xLarge)
    }
}

/// 文字方块里的大号数值（单位和数一样大，像天气的「19 公里」）、小标题、最底下一句话
private struct DetailStatText: View {
    let value: String
    let sub: String?
    let note: String?
    /// 大号的数：30 点（以前 36，「7 月 29 日」「145 分钟」顶到方块两边）
    @ScaledMetric(relativeTo: .largeTitle) private var valueSize: CGFloat = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value)
                .font(.system(size: valueSize, weight: .regular))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.top, 7)
            if let sub, !sub.isEmpty {
                // 小标题 Headline、白 85%（以前 Title 3 半粗，「2 小时 25 分钟」和上面的数一样抢眼）
                Text(sub)
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .padding(.top, 1)
            }
            Spacer(minLength: 6)
            if let note, !note.isEmpty {
                Text(note)
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .lineSpacing(1)
                    .lineLimit(3)
                    .minimumScaleFactor(0.85)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// 「上映」（剧集「首播」）：大号「7 月 29 日」，下面「2026 年」（剧集再带「第 1 季」），最底下「3 个月前上映。」
struct DetailReleaseTile: View {
    let release: DetailStats.Release
    let palette: DetailPalette

    var body: some View {
        let cal = Calendar(identifier: .gregorian)
        let parts: (value: String, sub: String?) = {
            if let d = release.date {
                let c = cal.dateComponents([.year, .month, .day], from: d)
                let year = c.year.map { "\($0) 年" }
                // 大号的数里用细空格（U+2009）：照样隔开数字和汉字，不像普通空格那样把「7 月 29 日」拉散
                return ("\(c.month ?? 0)\u{2009}月\u{2009}\(c.day ?? 0)\u{2009}日", [year, release.season].compactMap { $0 }.joined(separator: " · "))
            }
            return (release.year.map { "\($0)\u{2009}年" } ?? "", release.season)
        }()
        let note = DetailFacts.releaseNote(release)
        let when: String = [parts.sub ?? "", parts.value].filter { !$0.isEmpty }.joined(separator: " ")
        let spoken: String = [release.verb, when, note ?? ""].filter { !$0.isEmpty }.joined(separator: "，")
        DetailStatTileChrome(symbol: "calendar", title: release.verb, palette: palette) {
            DetailStatText(value: parts.value, sub: parts.sub, note: note)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }
}

/// 「时长」：大号「145 分钟」，下面「2 小时 25 分钟」（剧集是「每集」），最底下「现在开始看，约 23:05 看完。」（每分钟跟着走）
struct DetailRuntimeTile: View {
    let runtime: DetailStats.Runtime
    let palette: DetailPalette

    var body: some View {
        let sub: String? = runtime.perEpisode ? "每集" : (runtime.minutes >= 60 ? Format.runtime(runtime.minutes) : nil)
        TimelineView(.everyMinute) { context in
            let end = context.date.addingTimeInterval(TimeInterval(runtime.minutes * 60))
            let time = end.formatted(date: .omitted, time: .shortened)
            // 在逗号后面断行（以前自己折，「约」和时间被拆在两行：截图「约 / 凌晨 2:05 看完」）
            let note = (runtime.perEpisode ? "现在开始看这一集，" : "现在开始看，") + "\n约 \(time) 看完。"
            let length: String = runtime.perEpisode ? "每集 " + Format.runtime(runtime.minutes) : Format.runtime(runtime.minutes)
            DetailStatTileChrome(symbol: "clock.fill", title: runtime.perEpisode ? "每集时长" : "时长", palette: palette) {
                DetailStatText(value: "\(runtime.minutes)\u{2009}分钟", sub: sub, note: note)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("时长，" + length + "，" + note.replacingOccurrences(of: "\n", with: ""))
        }
    }
}

/// 刻度盘方块（像天气的「气压」）：一圈 270° 的刻度、低在左下高在右下，白色指针停在 position（0…1），
/// 圆心里大号的「高 / 中 / 低」和一行小字
struct DetailGaugeTile: View {
    let symbol: String
    let title: String
    let level: DetailFacts.Level
    let caption: String
    let position: Double
    let palette: DetailPalette
    let spoken: String
    @ScaledMetric(relativeTo: .title2) private var levelSize: CGFloat = 24

    var body: some View {
        DetailStatTileChrome(symbol: symbol, title: title, palette: palette) {
            DetailGauge(position: position, palette: palette) {
                // 圆心：「高 / 中 / 低」24 点半粗（以前 Title 28 点）、下面一行 Caption 2 的小字（以前 Caption、还带「约」「分」，
                // 比刻度圈里面还宽，压到了刻度上：用户截图）
                VStack(spacing: 2) {
                    Text(level.rawValue)
                        .font(.system(size: levelSize, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(caption)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(palette.ink2.opacity(0.85))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
            }
            .padding(.top, 10)
            .padding(.horizontal, 2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }
}

/// 刻度盘：41 道刻度排成 270° 的弧，指针附近的几道亮一点；「低」「高」写在两头下面
struct DetailGauge<Center: View>: View {
    let position: Double
    let palette: DetailPalette
    @ViewBuilder var center: () -> Center
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let p = min(1, max(0, position))
        GeometryReader { geo in
            let d = min(geo.size.width, geo.size.height)
            let r = d / 2
            ZStack {
                Canvas { ctx, size in
                    let c = CGPoint(x: size.width / 2, y: size.height / 2)
                    let n = 41
                    for i in 0..<n {
                        let t = Double(i) / Double(n - 1)
                        let a = Angle.degrees(135 + 270 * t).radians
                        let near = abs(t - p) < 0.07
                        let inner = r - (near ? 11 : 9)
                        var path = Path()
                        path.move(to: CGPoint(x: c.x + cos(a) * inner, y: c.y + sin(a) * inner))
                        path.addLine(to: CGPoint(x: c.x + cos(a) * (r - 1), y: c.y + sin(a) * (r - 1)))
                        ctx.stroke(path, with: .color(.white.opacity(near ? 0.55 : 0.2)),
                                   style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    }
                }
                // 指针：一根白色的短棒，比刻度长一点、往外探出一点
                Capsule()
                    .fill(.white)
                    .frame(width: 4, height: 15)
                    .shadow(color: .black.opacity(0.3), radius: 2)
                    .offset(y: -2)
                    // 整块和刻度盘一样大：绕刻度盘的圆心转
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .rotationEffect(.degrees(270 * (shown || reduceMotion ? p : 0) - 135))
                center()
                    .padding(.horizontal, r * 0.32)
                HStack {
                    Text("低")
                    Spacer(minLength: 0)
                    Text("高")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(palette.ink2.opacity(0.72))
                .padding(.horizontal, r * 0.32)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .offset(y: 2)
            }
            .frame(width: d, height: d)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            guard !shown else { return }
            if reduceMotion { shown = true; return }
            withAnimation(.spring(response: 0.9, dampingFraction: 0.82).delay(0.15)) { shown = true }
        }
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
        // 折起时一行一部：上下 11 → 14，海报上下不贴着卡边和细线（展开的 18 不变）
        .padding(.vertical, pillBelow ? 18 : 14)
        .contentShape(Rectangle())
    }

    /// 「查看」：小一号（30 高、左右 14；以前 34 高、左右 18），只是样子——点的是整行。
    /// 白底蓝字（用户要求全局同类型的按钮都是白底蓝字）
    private var pill: some View {
        Text("查看")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 14)
            .frame(minHeight: 30)
            .background(Capsule().fill(Color.white))
            .accessibilityHidden(true)
    }
}

// MARK: - 钉在顶上的条

/// 往上滚过头部以后钉在顶上：海报、片名、「播放」胶囊（参考图的「取得」）
struct DetailPinnedBar: View {
    let title: String
    let thumb: URL?
    /// 这一部的字标（用户要求：条的左边有字标就只放字标；没有字标才是小海报 + 片名）
    var logo: URL? = nil
    let playTitle: String
    let playDisabled: Bool
    let palette: DetailPalette
    let topInset: CGFloat
    let leading: CGFloat
    let trailing: CGFloat
    let onPlay: () -> Void
    /// 字标粒子转场（用户要求：往下滚，头部大字标化成粒子飞进这一条左上角重新拼好）：处理好的那张字标图（和头部 LogoImage、粒子层同一张）
    var logoImage: UIImage? = nil
    /// 左上那一格：头部字标显示宽高的 42%（同比例；左边距和头部字标一样）
    var logoSlot: CGSize = .zero
    /// 滚动进度 0…1：条的底色、字标、「播放」胶囊都跟着它走；nil 是没有字标转场（整条由外面滑下来、淡入，和以前一样）
    var progress: Double? = nil
    /// 那一格在窗口里的框（粒子的落点；和这里画的字标同一个框，p 到 1 时从粒子层换手看不出来）
    var onLogoSlot: (CGRect) -> Void = { _ in }
    /// 没有粒子层接手（「减弱动态效果」、设备画不了、框还没量到、粒子层还没说画得出来或画布出错：DetailLogoMotion.handoff）：
    /// 条里的字标跟着进度和头部字标交叉淡入淡出，不等到 1 才冒出来——粒子层哪一步没过，这一枚都不会在半路上缺着
    var crossFade = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // 滚动驱动的字标格：有进度、有字标图、格子有大小；不然照以前的样子
        let driven = progress != nil && logoImage != nil && logoSlot.width > 0 && logoSlot.height > 0
        let p = progress ?? 1
        HStack(spacing: 14) {
            if driven, let logoImage {
                dockedLogo(logoImage, p: p)
            } else if let logo {
                // 字标（用户要求）：30 点高、靠左，最宽 200；深色字标照样自动反白（LogoImage）。取不到就写片名
                LogoImage(url: logo, height: 30, alignment: .leading, fallback: title, maxWidth: 200)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(title)
                    .accessibilityAddTraits(.isHeader)
            } else {
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
            }
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
            // 有字标转场时「继续播放」胶囊在 0.9–1.0 这一段跟着字标一起淡入（用户要求）
            .opacity((playDisabled ? 0.5 : 1) * (progress == nil ? 1 : Self.ramp(p, from: 0.9, to: 1)))
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
        .background(alignment: .top) {
            // 渐进式模糊（用户要求：顶部的条不许有硬边界线）：带这一页颜色的磨砂从上往下淡掉，条底下再多淡出 40 点，
            // 没有底线、没有影子。条本身那一段颜色压得够厚（86%），白字和「播放」照样清楚
            let barH = topInset + 66
            DSProgressiveBar(tint: palette.bar, tintOpacity: 0.86, solid: barH / (barH + 40))
                .frame(height: barH + 40)
                // 有字标转场：底色跟着滚动进度慢慢铺上来（用户要求），粒子往左上角聚的时候条已经在了
                .opacity(progress == nil ? 1 : Self.ramp(p, from: 0.55, to: 1))
        }
    }

    /// 条里的字标（用户要求：头部字标的 42%、同比例、同左边距）。只画一张、画法和 LogoImage 一样（允许 HDR、同一个影子）：
    /// 粒子层落定前最后一帧画的小字标就是 HDR（能显示的屏上）+ 这个影子，p 到 1 换成这一枚时一模一样，不跳（用户要求）。
    /// 平常到 p = 1 才出现（之前是粒子层在画它）；没有粒子层时跟着进度和头部字标交叉淡入淡出。旁白念片名，还是标题
    private func dockedLogo(_ image: UIImage, p: Double) -> some View {
        Image(uiImage: image)
            .resizable()
            .allowedDynamicRange(.high)
            .frame(width: logoSlot.width, height: logoSlot.height)
            .shadow(color: .black.opacity(0.55), radius: 12, y: 4)
            .opacity(reduceMotion || crossFade ? p : (p >= 1 ? 1 : 0))
            // 量这一格在窗口里的框：粒子的落点就是它
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { onLogoSlot($0) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("detail-pinned-logo")
    }

    /// p 在 a…b 之间从 0 平滑升到 1（smoothstep），外面是 0 / 1
    private static func ramp(_ p: Double, from a: Double, to b: Double) -> Double {
        let t = min(1, max(0, (p - a) / (b - a)))
        return t * t * (3 - 2 * t)
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

    /// 「2026-07-29」→ 那一天（公历，当地正午：不会因为时区换到前一天）
    static func day(_ s: String?) -> Date? {
        guard let s, s.count >= 10 else { return nil }
        let p = s.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard p.count == 3, p[0] > 1800 else { return nil }
        return Calendar(identifier: .gregorian).date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: 12))
    }

    /// 上映那一块最底下的一句：「今天上映。」「还有 12 天上映。」「3 个月前上映。」「2 年前上映。」（剧集是「首播」）
    static func releaseNote(_ r: DetailStats.Release, now: Date = Date()) -> String? {
        let cal = Calendar(identifier: .gregorian)
        let verb = r.verb
        if let date = r.date {
            let days = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: date)).day ?? 0
            switch days {
            case 0: return "今天\(verb)。"
            case 1: return "明天\(verb)。"
            case -1: return "昨天\(verb)。"
            case 2..<45: return "还有 \(days) 天\(verb)。"
            case 45...: return "大约 \(Int((Double(days) / 30.4).rounded())) 个月后\(verb)。"
            case -44 ... -2: return "\(-days) 天前\(verb)。"
            case -364 ... -45: return "\(Int((Double(-days) / 30.4).rounded())) 个月前\(verb)。"
            default: return "\(-days / 365) 年前\(verb)。"
            }
        }
        guard let y = r.year else { return nil }
        let thisYear = cal.component(.year, from: now)
        switch y - thisYear {
        case 0: return "今年\(verb)。"
        case 1: return "明年\(verb)。"
        case -1: return "去年\(verb)。"
        case let d where d > 1: return "\(d) 年后\(verb)。"
        default: return "\(thisYear - y) 年前\(verb)。"
        }
    }

    /// 流量能效：放这一部每小时大约要下载多少——片源原样直通、不转码，就是文件大小 ÷ 片长。越省越高：
    /// 每小时 4 GB 以内（约 9 Mbps 以下）高，4–12 GB 中（4K 网络版多在这里），12 GB 以上低（4K 原盘）
    static func efficiency(bytes: Int64?, minutes: Int?) -> DetailStats.Efficiency? {
        guard let b = bytes, b > 0, let m = minutes, m > 0 else { return nil }
        let perHour = Double(b) / 1e9 / (Double(m) / 60)
        let level: Level = perHour <= 4 ? .high : perHour <= 12 ? .mid : .low
        return DetailStats.Efficiency(level: level, gbPerHour: perHour)
    }

    /// 「约 11.3 GB/小时」（1 GB 以下写 MB）：旁白念的
    static func perHourText(_ gb: Double) -> String {
        "约 " + perHourCaption(gb)
    }

    /// 刻度盘圆心下的那行小字：「11.3 GB/小时」（不带「约」，放得进刻度圈里面）
    static func perHourCaption(_ gb: Double) -> String {
        gb < 1 ? "\(Int((gb * 1000).rounded())) MB/小时" : String(format: "%.1f GB/小时", gb)
    }

    /// 能效刻度盘上的位置（0 低 … 1 高）：按每小时下载量的对数排，12 GB、4 GB 两条线正好在三分之一、三分之二处（36 GB 以上到头）
    static func efficiencyPosition(_ gb: Double) -> Double {
        guard gb > 0 else { return 1 }
        return min(1, max(0, log(36 / gb) / log(27)))
    }

    /// 推荐刻度盘上的位置：TMDB 4.5 分以下到头，6 分、7.5 分两条线在三分之一、三分之二处，9 分以上到顶
    static func ratingPosition(_ r: Double) -> Double {
        min(1, max(0, (r - 4.5) / 4.5))
    }

    /// 推荐等级：TMDB 评分 7.5 以上高（和主页「严苛品质区」同一条线）、6 以上中、再低是低
    static func recommendation(_ rating: Double?) -> Level? {
        guard let r = rating, r > 0 else { return nil }
        return r >= PremiumBar.minRating ? .high : r >= 6 ? .mid : .low
    }
}

// MARK: - 剧照（用户要求：和预告片合成一组、同一横排，用间距分开；卡和预告片卡完全一样）

/// 一张剧照卡：就是预告片卡那一种（`DSMediaCard`：16:9、大圆角，画面下段渐进式模糊 + 一层淡暗，
/// 模糊上压「第 3 幕」和「▣ 剧照」（不写张数：用户要求全局去掉计数），右下「•••」），一排里高矮、圆角、字都和预告片一样；整张卡点开看大图
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
        SoftNavigationStack {
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
