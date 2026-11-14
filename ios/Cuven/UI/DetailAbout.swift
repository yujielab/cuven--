import SwiftUI

// MARK: - 详情页「简介」：一排卡（Apple TV 的简介卡；用户要求把简介和影片规格做成卡片）
//
// 简介、评分、影片规格各一张，同一排横着滑，停在左边线上、右边露出下一张一截（S8）；一排里的卡一样高（按最高的那张）。
// 深灰圆角底（内容卡，不用玻璃：F38 玻璃只给功能层），里面三层：大字标题（评分卡前面一颗星）→ 一行灰色小字 →
// 最多四行正文，放不下的末尾渐隐、接一个「更多」（F24：截断了就要能看全）。
// 有更多内容的卡（简介、影片规格）点一下弹出系统的半屏 / 全屏弹层，从这张卡上放大出来、下滑收回（C50、F57）；
// 按下时略缩略暗，和别的卡同一个手感。原来页面最底下那段「信息」并进了影片规格的弹层。

/// 一张卡
struct DetailAboutCard: Identifiable, Hashable {
    let id: String
    /// 大字：片名、「7.5」、「4K · 杜比视界」
    let title: String
    /// 标题前的小图标（评分卡的星）和它的颜色
    var symbol: String? = nil
    var symbolColor: Color = .white
    /// 灰色小字一行：「科幻 · 冒险 · 剧情」「TMDB 评分」「影片规格」
    let caption: String
    /// 正文（卡上最多四行）
    let text: String
    /// 弹层的标题；nil 就是这张卡没有更多内容、不能点
    var sheetTitle: String? = nil
    /// 弹层里几行左灰右白（影片规格）；空的就是整段正文（简介）
    var rows: [DetailInfoRow] = []
}

enum DetailAboutStyle {
    /// 卡的底色：深色页面上的「二级底」（#1C1C1E）
    static let card = Color(white: 0.11)
    static let radius: CGFloat = 14
    /// 评分卡那颗星
    static let star = Color(red: 1.0, green: 0.78, blue: 0.24)
}

/// 「简介」那一排
struct DetailAboutRow: View {
    let cards: [DetailAboutCard]
    let metrics: DSMetrics
    @Namespace private var ns
    @State private var open: DetailAboutCard?

    var body: some View {
        let w = metrics.aboutCardWidth
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: metrics.gutter) {
                ForEach(cards) { c in card(c, width: w) }
            }
            // 一排一样高：先按最高的那张定高，再让每张撑满
            .fixedSize(horizontal: false, vertical: true)
            .scrollTargetLayout()
        }
        // 一直铺到侧边那一列底下，不在安全区边上被切掉（用户要求）
        .dsBleedRow(metrics)
        .scrollTargetBehavior(.viewAligned)
        .scrollClipDisabled()
        .sheet(item: $open) { c in
            DetailAboutSheet(card: c)
                .navigationTransition(.zoom(sourceID: c.id, in: ns))
        }
    }

    @ViewBuilder
    private func card(_ c: DetailAboutCard, width w: CGFloat) -> some View {
        let face = DetailAboutCardFace(card: c, opens: c.sheetTitle != nil)
            .frame(width: w)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(DetailAboutStyle.card, in: RoundedRectangle(cornerRadius: DetailAboutStyle.radius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: DetailAboutStyle.radius, style: .continuous))
        if c.sheetTitle != nil {
            Button {
                Haptics.light()
                open = c
            } label: { face }
            .buttonStyle(PressableStyle(scale: 0.97))
            .matchedTransitionSource(id: c.id, in: ns)
            .accessibilityHint("打开\(c.sheetTitle ?? "")")
            .accessibilityIdentifier("about-\(c.id)")
        } else {
            face
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("about-\(c.id)")
        }
    }
}

/// 卡面：大字标题 → 灰色小字 → 最多四行正文（放不下末尾渐隐接「更多」）
struct DetailAboutCardFace: View {
    let card: DetailAboutCard
    /// 点得开（有弹层）：放不下时才写「更多」
    let opens: Bool
    @State private var fullHeight: CGFloat = 0
    @State private var shownHeight: CGFloat = 0

    var body: some View {
        let clipped = fullHeight > shownHeight + 1
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let s = card.symbol {
                    Image(systemName: s)
                        .foregroundStyle(card.symbolColor)
                        .accessibilityHidden(true)
                }
                Text(card.title)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .font(.title3.weight(.semibold))

            if !card.caption.isEmpty {
                Text(card.caption)
                    .font(.footnote.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.top, 3)
            }

            if !card.text.isEmpty {
                Text(card.text)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in shownHeight = h }
                    .background(alignment: .top) {
                        // 同样宽、不限行数的一份，量出整段多高：比四行高才是真被截断了
                        Text(card.text)
                            .font(.body)
                            .fixedSize(horizontal: false, vertical: true)
                            .hidden()
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in fullHeight = h }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if clipped && opens {
                            HStack(spacing: 0) {
                                LinearGradient(colors: [DetailAboutStyle.card.opacity(0), DetailAboutStyle.card],
                                               startPoint: .leading, endPoint: .trailing)
                                    .frame(width: 32)
                                Text("更多")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .padding(.leading, 2)
                                    .background(DetailAboutStyle.card)
                            }
                            .fixedSize()
                            .accessibilityHidden(true)
                        }
                    }
                    .padding(.top, 16)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 点开一张卡：系统弹层（半屏起，能拉到全屏），右上一颗系统的关闭钮；简介是整段正文，影片规格是几行左灰右白
struct DetailAboutSheet: View {
    let card: DetailAboutCard
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if card.rows.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            header
                            Text(card.text)
                                .font(.body.leading(.loose))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .padding(.top, 18)
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                        .padding(.bottom, 28)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    List {
                        Section {
                            header
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
                        }
                        Section {
                            ForEach(card.rows, id: \.self) { r in
                                LabeledContent(r.label) {
                                    Text(r.value)
                                        .multilineTextAlignment(.trailing)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(card.sheetTitle ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .close) { dismiss() }
                        .accessibilityIdentifier("about-close")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let s = card.symbol {
                    Image(systemName: s).foregroundStyle(card.symbolColor)
                }
                Text(card.title)
                    .foregroundStyle(.primary)
            }
            .font(.title2.bold())
            if !card.caption.isEmpty {
                Text(card.caption)
                    .font(.footnote.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - 影片规格：从文件名读（分辨率、动态范围、视频编码、音频与声道、封装），加上文件大小

struct MediaSpec {
    var container: String?
    var resolution: String?
    var range: String?
    var video: String?
    var audio: String?
    var size: String?

    init(name: String, size: Int64? = nil) {
        func has(_ p: String) -> Bool { name.range(of: p, options: [.regularExpression, .caseInsensitive]) != nil }
        let ext = (name as NSString).pathExtension.uppercased()
        container = ext.isEmpty ? nil : ext

        if has("4320p|[. _-]8K[. _-]") { resolution = "8K" }
        else if has("2160p|[. _-]4K[. _-]|UHD") { resolution = "4K" }
        else if has("1080[pi]") { resolution = "1080p" }
        else if has("720p") { resolution = "720p" }

        if has("DOLBY[. _-]?VISION|[. _-]DV[. _-]|DoVi") { range = "杜比视界" }
        else if has("HDR10\\+|HDR10PLUS") { range = "HDR10+" }
        else if has("HDR10|[. _-]HDR[. _-]") { range = "HDR10" }
        else if has("[. _-]HLG[. _-]") { range = "HLG" }

        var v: String?
        if has("x265|HEVC|H[. ]?265") { v = "HEVC" }
        else if has("x264|AVC|H[. ]?264") { v = "H.264" }
        else if has("[. _-]AV1[. _-]") { v = "AV1" }
        if let c = v, has("10[ ._-]?bit") { v = c + " 10 bit" }
        video = v

        var codec: String?
        if has("TrueHD") { codec = "TrueHD" }
        else if has("DTS[. _-]?X") { codec = "DTS:X" }
        else if has("DTS[. _-]?HD") { codec = "DTS-HD MA" }
        else if has("DTS") { codec = "DTS" }
        else if has("DDP|DD\\+|E-?AC-?3") { codec = "杜比数字+" }
        else if has("[. _-]DD[. _-]?[257][. ][01]|AC-?3") { codec = "杜比数字" }
        else if has("FLAC") { codec = "FLAC" }
        else if has("AAC") { codec = "AAC" }
        else if has("OPUS") { codec = "Opus" }
        let base = [codec, Self.channels(name)].compactMap { $0 }.joined(separator: " ")
        if has("ATMOS") { audio = "杜比全景声" + (base.isEmpty ? "" : "（\(base)）") }
        else { audio = base.isEmpty ? nil : base }

        if let size, size > 0 { self.size = ByteCountFormatter.string(fromByteCount: size, countStyle: .file) }
    }

    /// 声道：「5.1」「7.1」「2.0」（前后不挨着别的数字，免得把 1080、H.264 认成声道）
    private static func channels(_ name: String) -> String? {
        guard let r = name.range(of: "(?<![0-9])[2-9][. ][01](?![0-9])", options: .regularExpression) else { return nil }
        return name[r].replacingOccurrences(of: " ", with: ".")
    }

    /// 卡上的大字：「4K · 杜比视界」；什么都认不出就是 nil
    var headline: String? {
        let s = [resolution, range].compactMap { $0 }.joined(separator: " · ")
        return s.isEmpty ? nil : s
    }

    /// 剧集：目录名里读出来的分辨率 / HDR / 音频（Worker 的 tvSeriesTags）优先，读不到再看第一集的文件名
    static func series(_ s: Series, firstFile: String?) -> MediaSpec {
        var spec = MediaSpec(name: firstFile ?? "")
        if let r = s.res?.uppercased(), !r.isEmpty {
            if r.contains("8K") || r.contains("4320") { spec.resolution = "8K" }
            else if r.contains("4K") || r.contains("2160") || r.contains("UHD") { spec.resolution = "4K" }
            else if r.contains("1080") { spec.resolution = "1080p" }
            else if r.contains("720") { spec.resolution = "720p" }
        }
        if let h = s.hdr?.uppercased(), !h.isEmpty {
            if h.contains("DV") || h.contains("VISION") { spec.range = "杜比视界" }
            else if h.contains("10+") || h.contains("PLUS") { spec.range = "HDR10+" }
            else if h.contains("HLG") { spec.range = "HLG" }
            else { spec.range = "HDR10" }
        }
        if let a = s.audio, !a.isEmpty { spec.audio = a == "Atmos" ? "杜比全景声" : a }
        return spec
    }
}

extension DetailAboutCard {
    /// 简介卡：片名、类型、整段简介（点开看全文）
    static func synopsis(title: String, genres: [String], overview: String) -> DetailAboutCard {
        DetailAboutCard(id: "synopsis", title: title, caption: genres.joined(separator: " · "),
                        text: overview, sheetTitle: "简介")
    }

    /// 评分卡：「★ 7.5」「TMDB 评分」，正文说清满分多少、在片库里排在哪（高过一半以上才说）
    static func rating(_ r: Double, percentile: Int?, pool: String) -> DetailAboutCard {
        var text = "TMDB 观众打分，满分 10 分。"
        if let p = percentile, p >= 50 { text += "高于片库里 \(p)% 的\(pool)。" }
        return DetailAboutCard(id: "rating", title: String(format: "%.1f", r), symbol: "star.fill",
                               symbolColor: DetailAboutStyle.star, caption: "TMDB 评分", text: text)
    }
}
