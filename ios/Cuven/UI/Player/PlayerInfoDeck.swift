import SwiftUI

// MARK: - Touch Bar 下面那块：简介 / InSight / 继续观看 / 推荐（液态玻璃）
//
// 用户要求：「参考图 5-6-7 保持液态玻璃设计重新设计 touch bar 下方空间」（参照 Apple TV App 播放器里的信息面板）：
//   · 一排胶囊标签：选中的是白底黑字，其余是液态玻璃（白字）；
//   · 简介：这一集的标题、简介、「类型 · 时长」和规格徽标（4K、杜比视界、杜比全景声……），右边两颗玻璃胶囊
//     「从头开始」「前往节目」（剧集后面还有时再多一颗「下一集」）；窄的时候按钮排到下面；
//   · InSight：这一部的演员（头像、名字、角色）；
//   · 继续观看：别的看到一半的（画面 + 字标 + 进度 + 剩余时间），点了接着放；
//   · 推荐：一次一部，大字标居中、「类型 · 年份」和评分，下面「＋ 想看」「跳过」两颗白胶囊（参照图 7）。
// 没有内容的标签不出（比如本机视频没有演员表）。面板闲置时和 Touch Bar 一起淡出。

/// 简介那一页的内容（PlayerCoordinator 每开始一集按片库和 TMDB 填一次，剧集的分集标题、简介晚一点补上）
struct PlayerInfo: Equatable {
    /// 这一集的标题（剧集：分集标题；电影：片名）
    var heading = ""
    var overview: String?
    /// 「犯罪 · 54 分钟」那一行
    var facts: [String] = []
    /// 规格徽标：4K、杜比视界、HDR、杜比全景声……
    var badges: [String] = []
    var cast: [PlayerCastItem] = []
    /// 片库里找得到这一部（「前往节目」能去）
    var canGoToShow = false
}

struct PlayerCastItem: Equatable, Identifiable {
    var id: String
    var name: String
    var role: String?
    var photo: URL?
}

/// 继续观看、推荐里的一张
struct PlayerShelfItem: Equatable, Identifiable {
    var id: String
    var title: String
    /// 继续观看：「剩余 22 分钟」「第 5 集 · 剩余 43 分钟」；推荐：「剧情 · 2024」
    var subtitle: String?
    var art: URL?
    var logo: URL?
    /// 继续观看的进度 0…1
    var progress: Double?
    /// 推荐：TMDB 评分（「7.8」）
    var rating: String?
    /// 想看里的键（电影：文件路径；剧集：剧集目录）
    var watchKey: String?
}

enum PlayerDeckTab: String, CaseIterable, Hashable {
    case about, insight, continueWatching, recommend

    var title: String {
        switch self {
        case .about: "简介"
        case .insight: "InSight"
        case .continueWatching: "继续观看"
        case .recommend: "推荐"
        }
    }
}

struct PlayerInfoDeck: View {
    let model: CuvenPlayerViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var tabs: [PlayerDeckTab] {
        var t: [PlayerDeckTab] = [.about]
        if !model.info.cast.isEmpty { t.append(.insight) }
        if !model.continueItems.isEmpty { t.append(.continueWatching) }
        if !model.recommendations.isEmpty { t.append(.recommend) }
        return t
    }

    var body: some View {
        let tabs = self.tabs
        let tab = tabs.contains(model.deckTab) ? model.deckTab : .about
        VStack(alignment: .leading, spacing: 14) {
            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 10) {
                    ForEach(tabs, id: \.self) { t in
                        DeckTabPill(title: t.title, selected: t == tab) { model.selectDeckTab(t) }
                            .accessibilityIdentifier("deck-tab-\(t.rawValue)")
                    }
                    Spacer(minLength: 0)
                    DeckLightingButton(model: model)
                }
            }
            ZStack(alignment: .topLeading) {
                switch tab {
                case .about:
                    DeckAbout(model: model).transition(.deckPage)
                case .insight:
                    DeckInSight(cast: model.info.cast).transition(.deckPage)
                case .continueWatching:
                    DeckContinue(model: model).transition(.deckPage)
                case .recommend:
                    DeckRecommend(model: model).transition(.deckPage)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.9), value: tab)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player-deck")
    }
}

private extension AnyTransition {
    /// 换标签：新的一页从右边一点淡进来，旧的淡出
    static var deckPage: AnyTransition {
        .asymmetric(insertion: .opacity.combined(with: .offset(x: 14)), removal: .opacity)
    }
}

/// 标签胶囊：选中白底黑字，其余液态玻璃
private struct DeckTabPill: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(selected ? Color.black : Color.white)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 18)
                .frame(height: 38)
                .background {
                    if selected { Capsule().fill(Color.white) }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle(scale: 0.95))
        .modifier(DeckGlass(enabled: !selected, shape: Capsule()))
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: selected)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 标签那一排最右边的 ✦：影院光影的设置（精简版，下面的面板就是预览）
private struct DeckLightingButton: View {
    let model: CuvenPlayerViewModel
    @State private var open = false

    var body: some View {
        Button {
            Haptics.selection()
            model.poke()
            open = true
        } label: {
            Image(systemName: "sparkles")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle(scale: 0.92))
        .glassEffect(.regular.interactive(), in: Circle())
        .popover(isPresented: $open) {
            ScrollView {
                CinematicLightingView(compact: true)
                    .padding(20)
            }
            .frame(minWidth: 320, idealWidth: 380, maxWidth: 420, minHeight: 320, idealHeight: 460)
            .background(Color(white: 0.08))
            .presentationCompactAdaptation(.popover)
            .preferredColorScheme(.dark)
        }
        .onChange(of: open) { _, o in model.setSettingsOpen(o) }
        .accessibilityLabel("影院光影")
        .accessibilityHint("调整面板上画面的光影")
        .accessibilityIdentifier("deck-lighting")
    }
}

/// 液态玻璃（可以按的那种）；enabled 为假时不加（选中的白胶囊）
private struct DeckGlass<S: Shape>: ViewModifier {
    let enabled: Bool
    let shape: S

    func body(content: Content) -> some View {
        if enabled {
            content.glassEffect(.regular.interactive(), in: shape)
        } else {
            content
        }
    }
}

/// 玻璃胶囊按钮（从头开始、前往节目、下一集）
private struct DeckGlassButton: View {
    let title: String
    let systemImage: String
    var id: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .semibold))
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle(scale: 0.96))
        .glassEffect(.regular.interactive(), in: Capsule())
        .accessibilityIdentifier(id)
    }
}

// MARK: 简介（参照图 5）

private struct DeckAbout: View {
    let model: CuvenPlayerViewModel

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width >= 520
            let info = model.info
            let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 24))
                              : AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
            layout {
                VStack(alignment: .leading, spacing: 8) {
                    Text(info.heading.isEmpty ? model.title : info.heading)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    if let o = info.overview, !o.isEmpty {
                        Text(o)
                            .font(.system(size: 15))
                            .foregroundStyle(.white.opacity(0.9))
                            .lineLimit(wide ? 5 : 3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if wide { Spacer(minLength: 6) }
                    DeckFacts(facts: info.facts, badges: info.badges)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                GlassEffectContainer(spacing: 12) {
                    let buttons = wide ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 10))
                    buttons {
                        DeckGlassButton(title: "从头开始", systemImage: "play.fill", id: "deck-restart") { model.restart() }
                        if model.hasNext {
                            DeckGlassButton(title: "下一集", systemImage: "forward.end.fill", id: "deck-next") {
                                Haptics.light()
                                model.onNext?()
                            }
                        }
                        if info.canGoToShow {
                            DeckGlassButton(title: "前往节目", systemImage: "info.circle", id: "deck-show") {
                                Haptics.light()
                                model.onGoToShow?()
                            }
                        }
                    }
                }
                .frame(width: wide ? min(260, geo.size.width * 0.36) : nil)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
    }
}

/// 「犯罪 · 54 分钟」+ 规格徽标（4K 实心，别的描边，和参照图一样）
private struct DeckFacts: View {
    let facts: [String]
    let badges: [String]

    var body: some View {
        HStack(spacing: 8) {
            if !facts.isEmpty {
                Text(facts.joined(separator: " · "))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            ForEach(badges.prefix(4), id: \.self) { b in
                let solid = b == "4K" || b == "8K"
                Text(b)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(solid ? Color.black : Color.white.opacity(0.75))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background {
                        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
                        if solid {
                            shape.fill(Color.white.opacity(0.72))
                        } else {
                            shape.strokeBorder(Color.white.opacity(0.6), lineWidth: 1.2)
                        }
                    }
                    .fixedSize()
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: InSight（演员）

private struct DeckInSight: View {
    let cast: [PlayerCastItem]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 12) {
                    ForEach(cast) { c in
                        VStack(spacing: 8) {
                            RemoteImage(url: c.photo, maxPixel: 240, placeholder: Color.white.opacity(0.08))
                                .frame(width: 68, height: 68)
                                .clipShape(Circle())
                                .overlay(Circle().strokeBorder(.white.opacity(0.15), lineWidth: 0.5))
                            VStack(spacing: 2) {
                                Text(c.name)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.white)
                                if let r = c.role, !r.isEmpty {
                                    Text(r)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.white.opacity(0.6))
                                }
                            }
                            .lineLimit(1)
                            .multilineTextAlignment(.center)
                        }
                        .padding(.vertical, 14)
                        .padding(.horizontal, 10)
                        .frame(width: 124)
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .scrollClipDisabled()
    }
}

// MARK: 继续观看（参照图 6）

private struct DeckContinue: View {
    let model: CuvenPlayerViewModel

    var body: some View {
        GeometryReader { geo in
            // 卡宽：放得下两张半左右，最宽 280；高按 16:9，不超过这一页的高
            let w = min(280, max(180, (geo.size.width - 28) / 2.4), (geo.size.height - 4) * 16 / 9).rounded()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(model.continueItems) { item in
                        Button {
                            Haptics.light()
                            model.onPlayItem?(item)
                        } label: {
                            ContinueCard(item: item, width: w)
                        }
                        .buttonStyle(PressableStyle(scale: 0.97))
                        .accessibilityLabel([item.title, item.subtitle].compactMap { $0 }.joined(separator: "，"))
                        .accessibilityHint("接着放")
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollClipDisabled()
        }
    }
}

private struct ContinueCard: View {
    let item: PlayerShelfItem
    let width: CGFloat

    var body: some View {
        let h = (width * 9 / 16).rounded()
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        ZStack(alignment: .bottomLeading) {
            RemoteImage(url: item.art, maxPixel: 720)
                .frame(width: width, height: h)
            LinearGradient(stops: [.init(color: .clear, location: 0.35), .init(color: .black.opacity(0.75), location: 1)],
                           startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 8) {
                if let logo = item.logo {
                    LogoImage(url: logo, height: (h * 0.2).rounded(), alignment: .leading, fallback: item.title,
                              maxWidth: (width * 0.55).rounded())
                } else {
                    Text(item.title)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                HStack(spacing: 8) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 11, weight: .bold))
                    if let p = item.progress {
                        Capsule()
                            .fill(.white.opacity(0.3))
                            .frame(width: 44, height: 4)
                            .overlay(alignment: .leading) {
                                Capsule().fill(.white).frame(width: max(4, 44 * p), height: 4)
                            }
                    }
                    if let s = item.subtitle {
                        Text(s)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(.white)
            }
            .padding(12)
        }
        .frame(width: width, height: h)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(0.14), lineWidth: 0.6))
        .contentShape(shape)
    }
}

// MARK: 推荐（参照图 7）：一次一部，「＋ 想看」「跳过」

private struct DeckRecommend: View {
    let model: CuvenPlayerViewModel
    @State private var index = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let items = model.recommendations
        if items.isEmpty {
            EmptyView()
        } else {
            let item = items[index % items.count]
            let saved = item.watchKey.map { model.watchlisted.contains($0) } ?? false
            GeometryReader { geo in
                VStack(spacing: 14) {
                    Spacer(minLength: 0)
                    ZStack {
                        if let logo = item.logo {
                            LogoImage(url: logo, height: min(76, geo.size.height * 0.28).rounded(), fallback: item.title,
                                      maxWidth: (geo.size.width * 0.6).rounded())
                        } else {
                            Text(item.title)
                                .font(.system(size: 34, weight: .heavy))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                        }
                    }
                    .id(item.id)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.94)))
                    HStack(spacing: 10) {
                        if let s = item.subtitle {
                            Text(s)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        if let r = item.rating {
                            Text("★ \(r)")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white.opacity(0.75))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.6), lineWidth: 1.2))
                        }
                    }
                    .lineLimit(1)
                    HStack(spacing: 16) {
                        WhitePill(title: saved ? "已在想看" : "想看", systemImage: saved ? "checkmark" : "plus",
                                  id: "deck-watchlist") {
                            Haptics.success()
                            model.onToggleWatchlist?(item)
                        }
                        WhitePill(title: "跳过", systemImage: nil, id: "deck-skip") {
                            Haptics.selection()
                            model.poke()
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.88)) { index += 1 }
                        }
                    }
                    .frame(maxWidth: 420)
                    Spacer(minLength: 0)
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .accessibilityElement(children: .contain)
        }
    }
}

/// 参照图 7 的白胶囊（黑字）
private struct WhitePill: View {
    let title: String
    let systemImage: String?
    let id: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 18, weight: .bold))
                        .contentTransition(.symbolEffect(.replace.magic(fallback: .replace)))
                }
                Text(title)
                    .font(.system(size: 18, weight: .bold))
                    .contentTransition(.interpolate)
            }
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(Capsule().fill(Color.white))
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle(scale: 0.96))
        .accessibilityIdentifier(id)
    }
}
