import SwiftUI

// MARK: - 面板最底下那一块：InSight / 继续观看 / 推荐（液态玻璃，只左右滑）
//
// 用户要求：「移除简介并将蓝色区域下移做为控制面板的最底位置设计，并限制最大高度（所有内容和子选项页面仅允许横向滑动）」：
//   · 一排胶囊标签（选中的白底黑字，其余液态玻璃），最右边两颗玻璃圆钮：小窗口、关闭；
//   · 下面一排卡，只左右滑（没有往下翻的页）：
//       InSight——这一部的演员（头像、名字、角色）；
//       继续观看——剧集后面还有时打头一张「下一集」，接着是别的看到一半的（画面 + 字标 + 进度 + 剩余），点了接着放；
//       推荐——同类型的片子（画面 + 字标 + 类型 · 年份 + 评分），右上角一颗玻璃圆钮「＋」加进想看（已在想看是「✓」），点卡放它；
//   · 整块贴在面板最底下，高度有上限（PlayerDeckLayout）。没有内容的标签不出。面板闲置时和 Touch Bar 一起淡出。

/// 演员表等（PlayerCoordinator 每开始一集按片库和 TMDB 填一次）
struct PlayerInfo: Equatable {
    var heading = ""
    var overview: String?
    var facts: [String] = []
    var badges: [String] = []
    var cast: [PlayerCastItem] = []
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
    case insight, continueWatching, recommend

    var title: String {
        switch self {
        case .insight: "InSight"
        case .continueWatching: "继续观看"
        case .recommend: "推荐"
        }
    }
}

/// 这一块的尺寸：标签那一排 38 点，下面一排卡最高 150 点（整块最高 200 点）
enum PlayerDeckLayout {
    static let tabHeight: CGFloat = 38
    static let spacing: CGFloat = 12
    static let maxCardHeight: CGFloat = 150
    static var maxHeight: CGFloat { tabHeight + spacing + maxCardHeight }
}

struct PlayerInfoDeck: View {
    let model: CuvenPlayerViewModel
    /// 这一块能用的高（不超过 PlayerDeckLayout.maxHeight）
    let height: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var tabs: [PlayerDeckTab] {
        var t: [PlayerDeckTab] = []
        if !model.info.cast.isEmpty { t.append(.insight) }
        if !model.continueItems.isEmpty || model.hasNext { t.append(.continueWatching) }
        if !model.recommendations.isEmpty { t.append(.recommend) }
        return t
    }

    var body: some View {
        let tabs = self.tabs
        let tab = tabs.contains(model.deckTab) ? model.deckTab : tabs.first
        let cardHeight = min(PlayerDeckLayout.maxCardHeight, height - PlayerDeckLayout.tabHeight - PlayerDeckLayout.spacing)
        VStack(alignment: .leading, spacing: PlayerDeckLayout.spacing) {
            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 10) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(tabs, id: \.self) { t in
                                DeckTabPill(title: t.title, selected: t == tab) { model.selectDeckTab(t) }
                                    .accessibilityIdentifier("deck-tab-\(t.rawValue)")
                            }
                        }
                    }
                    .scrollClipDisabled()
                    DeckCircleButton(symbol: "pip.enter", label: "小窗口", hint: "画中画，回到主屏幕接着看",
                                     id: "player-pip", enabled: model.pipPossible) { model.startPiP() }
                    DeckCircleButton(symbol: "xmark", label: "关闭", hint: nil, id: "player-close", enabled: true) {
                        Haptics.light()
                        model.onClose?()
                    }
                }
                .frame(height: PlayerDeckLayout.tabHeight)
            }
            if let tab, cardHeight >= 90 {
                ZStack(alignment: .topLeading) {
                    switch tab {
                    case .insight:
                        DeckInSight(cast: model.info.cast, height: cardHeight).transition(.deckPage)
                    case .continueWatching:
                        DeckContinue(model: model, height: cardHeight).transition(.deckPage)
                    case .recommend:
                        DeckRecommend(model: model, height: cardHeight).transition(.deckPage)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .frame(height: cardHeight, alignment: .topLeading)
                .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.9), value: tab)
            }
        }
        .frame(maxWidth: .infinity, alignment: .bottomLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player-deck")
    }
}

private extension AnyTransition {
    /// 换标签：新的一排从右边一点淡进来，旧的淡出
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
                .frame(height: PlayerDeckLayout.tabHeight)
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

/// 标签那一排右边的玻璃圆钮（小窗口、关闭）
private struct DeckCircleButton: View {
    let symbol: String
    let label: String
    let hint: String?
    let id: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(enabled ? Color.white : Color.white.opacity(0.35))
                .frame(width: PlayerDeckLayout.tabHeight, height: PlayerDeckLayout.tabHeight)
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle(scale: 0.9))
        .glassEffect(.regular.interactive(), in: Circle())
        .disabled(!enabled)
        .accessibilityLabel(label)
        .accessibilityHint(hint ?? "")
        .accessibilityIdentifier(id)
    }
}

/// 液态玻璃（可以按的那种）；enabled 为假时不加（选中的白胶囊）
private struct DeckGlass<S: Shape>: ViewModifier {
    let enabled: Bool
    let shape: S

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.glassEffect(.regular.interactive(), in: shape)
        } else {
            content
        }
    }
}

// MARK: InSight（演员）

private struct DeckInSight: View {
    let cast: [PlayerCastItem]
    let height: CGFloat

    var body: some View {
        let photo = min(68, max(40, height - 72))
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 12) {
                    ForEach(cast) { c in
                        VStack(spacing: 8) {
                            RemoteImage(url: c.photo, maxPixel: 240, placeholder: Color.white.opacity(0.08))
                                .frame(width: photo, height: photo)
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
                        .padding(.horizontal, 10)
                        .frame(width: 124, height: height)
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .scrollClipDisabled()
    }
}

// MARK: 继续观看（打头一张「下一集」）

private struct DeckContinue: View {
    let model: CuvenPlayerViewModel
    let height: CGFloat

    var body: some View {
        let w = (height * 16 / 9).rounded()
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                if model.hasNext {
                    Button {
                        Haptics.light()
                        model.onNext?()
                    } label: {
                        ShelfCard(item: PlayerShelfItem(id: "next", title: model.title, subtitle: model.nextLabel ?? "下一集",
                                                        art: TMDBImage.url(model.artwork, "w780")),
                                  width: w, badge: "下一集")
                    }
                    .buttonStyle(PressableStyle(scale: 0.97))
                    .accessibilityLabel("下一集，\(model.nextLabel ?? "")")
                    .accessibilityIdentifier("deck-next")
                }
                ForEach(model.continueItems) { item in
                    Button {
                        Haptics.light()
                        model.onPlayItem?(item)
                    } label: {
                        ShelfCard(item: item, width: w)
                    }
                    .buttonStyle(PressableStyle(scale: 0.97))
                    .accessibilityLabel([item.title, item.subtitle].compactMap { $0 }.joined(separator: "，"))
                    .accessibilityHint("接着放")
                }
            }
        }
        .scrollClipDisabled()
    }
}

// MARK: 推荐（右上角 ＋ 加进想看）

private struct DeckRecommend: View {
    let model: CuvenPlayerViewModel
    let height: CGFloat

    var body: some View {
        let w = (height * 16 / 9).rounded()
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(model.recommendations) { item in
                    let saved = item.watchKey.map { model.watchlisted.contains($0) } ?? false
                    Button {
                        Haptics.light()
                        model.onOpenRecommendation?(item)
                    } label: {
                        ShelfCard(item: item, width: w)
                    }
                    .buttonStyle(PressableStyle(scale: 0.97))
                    .overlay(alignment: .topTrailing) {
                        Button {
                            Haptics.success()
                            model.onToggleWatchlist?(item)
                        } label: {
                            Image(systemName: saved ? "checkmark" : "plus")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.white)
                                .contentTransition(.symbolEffect(.replace.magic(fallback: .replace)))
                                .frame(width: 32, height: 32)
                                .contentShape(Circle())
                        }
                        .buttonStyle(PressableStyle(scale: 0.9))
                        .glassEffect(.regular.interactive(), in: Circle())
                        .padding(8)
                        .accessibilityLabel(saved ? "从想看移除" : "加入想看")
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(item.title)
                }
            }
        }
        .scrollClipDisabled()
    }
}

/// 一张 16:9 的卡：画面 + 字标（没有就写片名）+ 进度 / 说明 + 评分；左上角可以有一颗小标（「下一集」）
private struct ShelfCard: View {
    let item: PlayerShelfItem
    let width: CGFloat
    var badge: String?

    var body: some View {
        let h = (width * 9 / 16).rounded()
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        ZStack(alignment: .bottomLeading) {
            RemoteImage(url: item.art, maxPixel: 720)
                .frame(width: width, height: h)
            LinearGradient(stops: [.init(color: .clear, location: 0.3), .init(color: .black.opacity(0.78), location: 1)],
                           startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 6) {
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
                    if let p = item.progress {
                        Image(systemName: "play.fill")
                            .font(.system(size: 10, weight: .bold))
                        Capsule()
                            .fill(.white.opacity(0.3))
                            .frame(width: 40, height: 4)
                            .overlay(alignment: .leading) {
                                Capsule().fill(.white).frame(width: max(4, 40 * p), height: 4)
                            }
                    }
                    if let s = item.subtitle {
                        Text(s)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                    }
                    if let r = item.rating {
                        Text("★ \(r)")
                            .font(.system(size: 11, weight: .bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.6), lineWidth: 1))
                    }
                }
                .foregroundStyle(.white)
            }
            .padding(12)
        }
        .frame(width: width, height: h)
        .overlay(alignment: .topLeading) {
            if let badge {
                Text(badge)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.white))
                    .padding(10)
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(0.14), lineWidth: 0.6))
        .contentShape(shape)
    }
}
