import SwiftUI

// MARK: - 演员个人页（照用户给的参考图：Apple Music 的艺人页）
//
// · 最上面一大张人像（TMDB 的照片，铺满窗口宽、连同 iPhone Duo 侧边那一列），下段渐进式模糊，化进从照片取的底色，整页是这个颜色；
// · 名字居中、大号特粗，压在模糊上；下面三颗：ⓘ（简介弹层）、白色大圆 ▶（放这位在片库里最新的一部电影）、
//   🔍（换到搜索、在资料库里搜这位）；
// · 一张卡：片库里最新的那一部（海报、上映日期、片名、「饰 角色」），右边一颗 ＋ 加入想看（再点是 ✓ 移出）；
// · 「库中作品」：电影一排、剧集一排（海报 + 片名 + 演的谁），点进详情（从卡上放大出来）；
// · 「关于」：简介前五行，点开是简介弹层（大照片、名字、来自、出生、类型、关于全文：参考图的「關於」页）。
// 导航栏里先不写字，滚过名字才接上；右上分享（TMDB 的演员页）。所有出现都是模糊淡入，按下去略缩、松手回弹。

struct ActorPage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let member: CastMember
    @State private var info: PersonInfo?
    /// 照片底边的平均色：整页跟着染（DetailPalette）
    @State private var edge: UIColor?
    @State private var showBio = false
    @State private var nameInBar = false
    @State private var appeared = false

    private var name: String {
        let n = info?.name ?? member.name
        return n.isEmpty ? "未知演员" : n
    }

    var body: some View {
        GeometryReader { geo in
            let insets = geo.safeAreaInsets
            let m = DSMetrics(width: geo.size.width, leadingInset: insets.leading, trailingInset: insets.trailing, height: geo.size.height)
            let fullW = geo.size.width + insets.leading + insets.trailing
            let fullH = geo.size.height + insets.top + insets.bottom
            let photoH = ActorText.photoHeight(width: fullW, height: fullH)
            let works = model.works(of: member, info: info)
            let palette = DetailPalette.from(edge)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    hero(m, works: works, width: fullW, height: photoH, palette: palette)
                    VStack(alignment: .leading, spacing: m.shelfGap) {
                        if let latest = works.first {
                            latestCard(latest, m, palette: palette)
                        }
                        let movies = works.filter { if case .movie = $0.entry { return true } else { return false } }
                        let shows = works.filter { if case .series = $0.entry { return true } else { return false } }
                        if !movies.isEmpty { worksShelf("库中的电影", movies, m) }
                        if !shows.isEmpty { worksShelf("库中的剧集", shows, m) }
                        if works.isEmpty {
                            Text(info == nil ? "正在载入…" : "片库中暂无此演员的作品。")
                                .font(.callout)
                                .foregroundStyle(palette.ink2)
                                .padding(.horizontal, m.margin)
                                .transition(.dsBlurFade)
                        }
                        aboutCard(m, palette: palette)
                    }
                    .padding(.top, 26)
                    .padding(.bottom, 44)
                    .padding(.leading, insets.leading)
                    .padding(.trailing, insets.trailing)
                    .animation(.spring(response: 0.5, dampingFraction: 0.88), value: works.count)
                }
                .background(alignment: .top) {
                    // 整页的颜色：照片下面从照片的主色开始，往下慢慢沉到同色相的深色
                    // 从照片底边接上（照片底边已经化成 palette.base），接缝处同一个颜色，不起一道线
                    VStack(spacing: 0) {
                        Color.clear.frame(height: photoH)
                        LinearGradient(colors: [palette.base, palette.deep], startPoint: .top, endPoint: .bottom)
                            .frame(height: max(900, fullH * 1.6))
                    }
                }
            }
            .scrollIndicators(.hidden)
            .background(palette.deep)
            .ignoresSafeArea(edges: [.top, .horizontal])
            .onScrollGeometryChange(for: Bool.self) { g in
                g.contentOffset.y + g.contentInsets.top > photoH - 120
            } action: { _, v in
                withAnimation(.easeOut(duration: 0.2)) { nameInBar = v }
            }
            .animation(.easeInOut(duration: 0.6), value: edge)
        }
        .navigationTitle(nameInBar ? name : "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            if let url = CastSheetText.tmdbPage(member) {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: url, subject: Text(name)) {
                        Label("分享", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("actor-share")
                }
            }
        }
        .sheet(isPresented: $showBio) {
            ActorBioSheet(member: member, info: info, palette: DetailPalette.from(edge))
        }
        .task(id: member.id) { info = await model.person(member) }
        .task(id: ActorText.photo(member, info: info)) { edge = await ActorText.edgeColor(ActorText.photo(member, info: info)) }
        .onAppear {
            let anim: Animation = reduceMotion ? Animation.easeOut(duration: 0.2)
                : Animation.spring(response: 0.6, dampingFraction: 0.82).delay(0.08)
            withAnimation(anim) { appeared = true }
        }
    }

    // MARK: 照片 + 一排：ⓘ · 名字 · 🔍

    private func hero(_ m: DSMetrics, works: [ActorWork], width: CGFloat, height: CGFloat, palette: DetailPalette) -> some View {
        let photo = ActorText.photo(member, info: info)
        return ZStack(alignment: .bottom) {
            ZStack {
                palette.base
                Text(CastSheetText.initial(member.name))
                    .font(.system(size: width * 0.3, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white.opacity(0.18))
                if photo != nil {
                    // 人像是 2:3：按宽铺满、从顶上开始裁（脸在上面），下段渐进式模糊
                    RemoteImage(url: photo, maxPixel: width * 3, placeholder: .clear, effect: .bottomBlur)
                        .frame(width: width, height: width * 1.5)
                        .frame(width: width, height: height, alignment: .top)
                        .clipped()
                }
                // 化进底色：照片下面四成慢慢沉到页面的颜色
                LinearGradient(stops: [.init(color: palette.base.opacity(0), location: 0.55),
                                       .init(color: palette.base.opacity(0.65), location: 0.82),
                                       .init(color: palette.base, location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
            .frame(width: width, height: height)
            .clipped()
            .accessibilityHidden(true)

            // 用户要求：名字包进一颗 Liquid Glass 胶囊，放在原来中间那颗白色播放钮的位置（照片上不再另写一行大字，
            // 播放钮拿掉：最新的那一部就在下面那张卡里，点进去播放）。三样同一种玻璃、同样 56 点高，排成一排
            GlassEffectContainer(spacing: 14) {
                HStack(spacing: m.wide ? 22 : 14) {
                    ActorCircleButton(symbol: "info", size: 56, label: "简介", id: "actor-info") { showBio = true }
                    ActorNameCapsule(name: name, wide: m.wide)
                    ActorCircleButton(symbol: "magnifyingglass", size: 56, label: "在资料库中搜索", id: "actor-search") {
                        let n = name
                        guard !n.isEmpty else { return }
                        model.searchRequest = n
                    }
                }
            }
            .padding(.horizontal, m.margin)
            .padding(.bottom, 26)
            // 「减弱动态效果」时只淡入（F59；以前只把弹簧换成短曲线，照样从 94% 放大、从模糊里出来）
            .scaleEffect(appeared || reduceMotion ? 1 : 0.94)
            .opacity(appeared ? 1 : 0)
            .blur(radius: appeared || reduceMotion ? 0 : 8)
        }
        .frame(width: width, height: height)
    }

    // MARK: 最新的那一部（参考图「Rise Without A Sound - Single」那张卡）

    private func latestCard(_ w: ActorWork, _ m: DSMetrics, palette: DetailPalette) -> some View {
        let item = ActorText.item(w, model: model)
        let saved = model.watchlist.contains(item.key)
        return ZStack(alignment: .trailing) {
            ZoomLink(route: item.route, slot: "actor-latest") {
                HStack(spacing: 16) {
                    RemoteImage(url: item.thumb, maxPixel: 300)
                        .frame(width: 76, height: 114)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(DetailSurface.line, lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.28), radius: 6, y: 3)
                    VStack(alignment: .leading, spacing: 4) {
                        if let d = ActorText.longDate(w.date) {
                            Text(d)
                                .font(.subheadline)
                                .foregroundStyle(palette.ink2)
                        }
                        Text(item.title)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                        Text(item.line)
                            .font(.subheadline)
                            .foregroundStyle(palette.ink2)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 56)
                }
                .padding(16)
                // 设计轮 2（并行·detail）：和详情页的卡同一种面（圆角 30 → 34、细边 12% → 14%：DetailSurface）
                .background(RoundedRectangle(cornerRadius: DetailSurface.radius, style: .continuous).fill(DetailSurface.fill))
                .overlay(RoundedRectangle(cornerRadius: DetailSurface.radius, style: .continuous).strokeBorder(DetailSurface.line, lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: DetailSurface.radius, style: .continuous))
            }
            .accessibilityIdentifier("actor-latest")
            Button {
                model.watchlist.toggle(item.key, kind: item.kind)
            } label: {
                Image(systemName: saved ? "checkmark" : "plus")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(Color.white.opacity(0.18)))
                    .contentShape(Circle())
            }
            .buttonStyle(PressableStyle(scale: 0.9))
            .sensoryFeedback(.selection, trigger: saved)
            .padding(.trailing, 18)
            .accessibilityLabel(saved ? "从想看中移除" : "加入想看")
            .accessibilityIdentifier("actor-watchlist")
        }
        .frame(maxWidth: 720)
        .padding(.horizontal, m.margin)
        .animation(.snappy(duration: 0.25), value: saved)
    }

    // MARK: 库中作品

    private func worksShelf(_ title: String, _ list: [ActorWork], _ m: DSMetrics) -> some View {
        DSSection(title: title, metrics: m) {
            DSShelf(metrics: m) {
                ForEach(list) { w in
                    let item = ActorText.item(w, model: model, width: m.posterWidth)
                    ZoomLink(route: item.route, slot: "actor-\(title)") {
                        ActorWorkCard(poster: item.poster, logo: item.logo, title: item.title, role: w.character, width: m.posterWidth)
                    }
                    .accessibilityIdentifier("actor-work")
                }
            }
        }
    }

    // MARK: 关于

    @ViewBuilder
    private func aboutCard(_ m: DSMetrics, palette: DetailPalette) -> some View {
        if let bio = info?.biography, !bio.isEmpty {
            // 标题到卡和详情页的组一样（titleGap + 4：折起 16、展开 20；以前 14）
            VStack(alignment: .leading, spacing: m.titleGap + 4) {
                Text("关于")
                    .font(.dsSectionTitle)
                    .foregroundStyle(.white)
                    .accessibilityAddTraits(.isHeader)
                Button { showBio = true } label: {
                    VStack(alignment: .leading, spacing: 10) {
                        // 五行简介：松一点的行距（F21）
                        Text(bio)
                            .font(.dsReading)
                            .foregroundStyle(.white.opacity(0.88))
                            .lineLimit(5)
                            .multilineTextAlignment(.leading)
                        Text("更多")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DetailSurface.inset)
                    // 设计轮 2：和详情页的「简介」卡同一种面（圆角 26 → 34、底 8% → 10%、加 14% 的细边）
                    .background(RoundedRectangle(cornerRadius: DetailSurface.radius, style: .continuous).fill(DetailSurface.fill))
                    .overlay(RoundedRectangle(cornerRadius: DetailSurface.radius, style: .continuous).strokeBorder(DetailSurface.line, lineWidth: 1))
                    .contentShape(RoundedRectangle(cornerRadius: DetailSurface.radius, style: .continuous))
                }
                .buttonStyle(PressableStyle(scale: 0.98))
                .accessibilityHint("打开简介")
                .accessibilityIdentifier("actor-about")
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, m.margin)
            .transition(.dsBlurFade)
        }
    }
}

/// 照片下面那三颗里两边的小圆钮：玻璃圆、按下去略缩回弹、点一下轻触感
struct ActorCircleButton: View {
    let symbol: String
    let size: CGFloat
    let label: String
    let id: String
    let action: () -> Void
    @State private var taps = 0

    var body: some View {
        Button {
            taps += 1
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(.white)
                .symbolEffect(.bounce, value: taps)
                .frame(width: size, height: size)
                .glassEffect(.regular.interactive(), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle(scale: 0.9))
        .sensoryFeedback(.impact(weight: .light), trigger: taps)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }
}

/// 演员名：一颗 Liquid Glass 胶囊（用户要求，取代中间那颗白色播放钮），和两边的圆钮一样 56 点高、同一种玻璃。
/// 名字一行写下（粗体，折起 22 点、展开 26 点），太长就缩小（最小七成），胶囊跟着名字宽、最宽不挤掉两边的钮。
/// 只是名字、不是按钮：旁白念成这一页的标题
struct ActorNameCapsule: View {
    let name: String
    let wide: Bool

    var body: some View {
        Text(name)
            .font(.system(size: wide ? 26 : 22, weight: .bold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, wide ? 28 : 22)
            .frame(minWidth: 56, minHeight: 56)
            .glassEffect(.regular, in: Capsule())
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("actor-name")
    }
}

/// 库中作品的一张：2:3 海报（无字画面时下沿压字标，和主页的海报卡一样：DSPosterLogo），下面片名和「饰 谁」
struct ActorWorkCard: View {
    let poster: URL?
    var logo: URL? = nil
    let title: String
    let role: String?
    let width: CGFloat

    var body: some View {
        let h = (width * 1.5).rounded()
        VStack(alignment: .leading, spacing: 8) {
            RemoteImage(url: poster, maxPixel: width * 3)
                .frame(width: width, height: h)
                .overlay {
                    if let logo { DSPosterLogo(logo: logo, size: CGSize(width: width, height: h), title: title) }
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                if let role, !role.isEmpty {
                    Text("饰 " + role)
                        .font(.footnote)
                        .foregroundStyle(DSInk.secondary)
                }
            }
            .lineLimit(1)
        }
        .frame(width: width, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 简介弹层（参考图「關於」页：大照片、名字、来自、出生、类型、关于全文）

struct ActorBioSheet: View {
    let member: CastMember
    let info: PersonInfo?
    let palette: DetailPalette
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let name = (info?.name).flatMap { $0.isEmpty ? nil : $0 } ?? (member.name.isEmpty ? "未知演员" : member.name)
        let photo = ActorText.photo(member, info: info)
        SoftNavigationStack {
            GeometryReader { geo in
                let insets = geo.safeAreaInsets
                // 照片铺满整张弹层宽（连同 Duo 侧边那一列），字留在安全区里
                let w = geo.size.width + insets.leading + insets.trailing
                let photoH = (min(w, 700) * 1.05).rounded()
                let lead = insets.leading + 24
                let trail = insets.trailing + 24
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ZStack(alignment: .bottomLeading) {
                            ZStack {
                                palette.base
                                if photo != nil {
                                    RemoteImage(url: photo, maxPixel: w * 3, placeholder: .clear, effect: .bottomBlur)
                                        .frame(width: w, height: w * 1.5)
                                        .frame(width: w, height: photoH, alignment: .top)
                                        .clipped()
                                }
                                LinearGradient(stops: [.init(color: palette.base.opacity(0), location: 0.5),
                                                       .init(color: palette.base, location: 1)],
                                               startPoint: .top, endPoint: .bottom)
                            }
                            .frame(width: w, height: photoH)
                            .clipped()
                            .accessibilityHidden(true)
                            Text(name)
                                .font(.system(size: 40, weight: .heavy))
                                .foregroundStyle(.white)
                                .lineLimit(2)
                                .minimumScaleFactor(0.7)
                                .padding(.leading, lead)
                                .padding(.trailing, trail)
                                .padding(.bottom, 18)
                                .accessibilityAddTraits(.isHeader)
                        }
                        facts
                            .padding(.leading, lead)
                            .padding(.trailing, trail)
                            .padding(.top, 6)
                        if let bio = info?.biography, !bio.isEmpty {
                            Text("关于")
                                .font(.dsSectionTitle)
                                .foregroundStyle(.white)
                                .padding(.leading, lead)
                                .padding(.trailing, trail)
                                .padding(.top, 34)
                                .accessibilityAddTraits(.isHeader)
                            Text(bio)
                                .font(.title3)
                                .foregroundStyle(.white.opacity(0.9))
                                .lineSpacing(5)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.leading, lead)
                                .padding(.trailing, trail)
                                .padding(.top, 12)
                        } else if info != nil {
                            // TMDB 上中文、英文简介都是空的：说一声，不留一块空白
                            Text("暂无简介。")
                                .font(.callout)
                                .foregroundStyle(palette.ink2.opacity(0.75))
                                .padding(.leading, lead)
                                .padding(.trailing, trail)
                                .padding(.top, 30)
                        }
                    }
                    .frame(width: w, alignment: .leading)
                    .padding(.bottom, 44)
                    // 照片下面从 palette.base 接上，往下沉到深色：接缝处同一个颜色
                    .background(alignment: .top) {
                        VStack(spacing: 0) {
                            palette.base.frame(height: photoH)
                            LinearGradient(colors: [palette.base, palette.deep], startPoint: .top, endPoint: .bottom)
                                .frame(height: max(700, geo.size.height))
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .background(palette.deep)
                .ignoresSafeArea(edges: [.top, .horizontal])
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .close) { dismiss() }
                        .accessibilityIdentifier("actor-bio-close")
                }
            }
        }
        .presentationDetents([.large])
        .presentationCornerRadius(34)
    }

    /// 来自 / 出生（两列）、类型（参考图）；没有的那一格不画
    private var facts: some View {
        var rows: [(String, String)] = []
        if let p = info?.placeOfBirth, !p.isEmpty { rows.append(("来自", p)) }
        if let d = ActorText.longDate(info?.birthday) { rows.append(("出生", d)) }
        if let d = ActorText.longDate(info?.deathday) { rows.append(("逝世", d)) }
        if let k = ActorText.department(info?.knownFor) { rows.append(("类型", k)) }
        return LazyVGrid(columns: [GridItem(.flexible(), alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)],
                         alignment: .leading, spacing: 18) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                VStack(alignment: .leading, spacing: 4) {
                    Text(r.0)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(palette.ink2.opacity(0.8))
                    Text(r.1)
                        .font(.title3)
                        .foregroundStyle(.white)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

// MARK: - 小工具

enum ActorText {
    /// 照片区的高：人像按宽铺满，竖着的屏约宽的 1.25 倍高，最多窗口高的 72%（横着的屏也不会只剩一张脸）
    static func photoHeight(width: CGFloat, height: CGFloat) -> CGFloat {
        min(width * 1.25, max(380, height * 0.72)).rounded()
    }

    /// 大照片：先用 TMDB 的原图（Worker 给的 profile_path），没有就用演员表里的
    static func photo(_ m: CastMember, info: PersonInfo?) -> URL? {
        let p = (info?.profilePath).flatMap { $0.isEmpty ? nil : $0 } ?? m.profilePath
        guard let p, !p.isEmpty else { return nil }
        if p.hasPrefix("demo:") { return URL(string: p) }
        // TMDB 的一律换成原图：不光是路径，Worker 常给整条地址、还带着 w185 这样的小尺寸——以前整条地址原样用，
        // 185 像素的头像铺满整页宽（放大七倍多）糊成色块（用户截图）。h632 也不够（放大三倍多）；按显示尺寸降采样解码，不吃内存
        if p.hasPrefix("/") || p.contains("image.tmdb.org") { return TMDBImage.url(p, "original") }
        return URL(string: p)
    }

    /// 照片底边那一截的平均色（整页跟着染）
    static func edgeColor(_ url: URL?) async -> UIColor? {
        guard let url, let img = await ImagePipeline.shared.image(url, maxPixel: 96), let cg = img.cgImage else { return nil }
        return ImageEffects.averageColor(cg, bottom: 0.3)
    }

    /// 「1981-03-27」→「1981年3月27日」；只有年份就是「1981 年」
    static func longDate(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        let p = s.split(separator: "-").compactMap { Int($0) }
        if p.count >= 3 { return "\(p[0])年\(p[1])月\(p[2])日" }
        if let y = p.first { return "\(y) 年" }
        return nil
    }

    /// TMDB 的部门名换成中文
    static func department(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        let map = ["Acting": "表演", "Directing": "导演", "Writing": "编剧", "Production": "制作", "Sound": "声音",
                   "Camera": "摄影", "Editing": "剪辑", "Art": "美术", "Costume & Make-Up": "服装与化妆",
                   "Visual Effects": "视觉效果", "Crew": "幕后", "Lighting": "灯光", "Creator": "创作"]
        return map[s] ?? s
    }

    /// 一部作品在卡上要的东西：去哪、海报（和主页海报卡同一个挑法：无字画面 + 字标，没有字标才是印着片名的海报）、
    /// 字标、小图（最新那张卡上 76 点的小海报：印着片名的那张，字标压上去太小）、片名、一行字、想看用的键和类型。
    /// 用户截图：「库中的电影」里的卡用的是无字的画，却没压字标——认不出是哪一部
    @MainActor static func item(_ w: ActorWork, model: AppModel, width: CGFloat = 0)
        -> (route: Route, poster: URL?, logo: URL?, thumb: URL?, title: String, line: String, key: String, kind: WatchItem.Kind) {
        switch w.entry {
        case .movie(let v):
            let mm = model.meta(v)
            let kind = DetailText.line(["电影", mm?.genres?.first])
            let line = w.character.flatMap { $0.isEmpty ? nil : "饰 " + $0 } ?? kind
            let art = model.posterArt(v, width: width)
            return (.movie(v), art.url, art.logo, model.thumbArt(v), model.title(v), line, v.path, .movie)
        case .series(let s):
            let sm = model.seriesMetas[s.path]
            let kind = DetailText.line(["剧集", sm?.genres?.first])
            let line = w.character.flatMap { $0.isEmpty ? nil : "饰 " + $0 } ?? kind
            let art = model.seriesPosterArt(s, width: width)
            return (.series(s), art.url, art.logo, TMDBImage.url(sm?.poster ?? sm?.posterClean, "w342"),
                    sm?.title ?? s.name, line, s.path, .series)
        }
    }
}
