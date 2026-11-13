import SwiftUI

// MARK: - 详情页的几张弹层（照网页版 web/index.html 的 openFullCastSheet / openActorSheet / tvEpDescSheet）
//
// 网页版的弹层是同一个壳（.sheet）：顶上小拉把，标题 17 粗体居中，下面是内容，最底下一颗胶囊「取消」
// （读的弹层写「关闭」）。这里用系统的 sheet + 拉把，壳里的字号、间距、颜色照网页版。
//   · 演员阵容：「演员阵容 · N 位」，一行一位（52 的圆头像、名字、「饰 …」、›），点一行换成那位演员的弹层
//   · 演员：140 的圆头像、名字（22 粗体）、「饰 …」，两颗大按钮「在资料库中搜索」「在 TMDB 查看」
//   · 分集「更多」：「第 1 集 · 45 分钟」、集名（20 粗体），下面整段简介（能滚），底下「关闭」

/// 网页版 .sheet 的壳：内容 + 底部胶囊（14 上下、白 6% 底、发丝描边、16 半粗）
struct WebSheetBody<Content: View>: View {
    var title: String? = nil
    var closeLabel = "取消"
    @ViewBuilder var content: () -> Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            if let title {
                Text(title)
                    .font(.system(size: 17, weight: .bold))
                    .tracking(-0.17)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.top, 26)
                    .padding(.bottom, 24)
            }
            content()
            Button { dismiss() } label: {
                Text(closeLabel)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.white.opacity(0.06), in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
                    .contentShape(Capsule())
            }
            .buttonStyle(PressableStyle(scale: 0.97))
            .padding(.top, 12)
            .accessibilityIdentifier("sheet-cancel")
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
        .environment(\.colorScheme, .dark)
    }
}

/// 网页版 .sheet-btn：44 的图标块（圆角 12、白 8% 底）、标题 16 半粗、说明 13 号 40% 白；整颗圆角 16、白 4% 底、发丝描边
struct WebSheetButton: View {
    let symbol: String
    let tint: Color
    let label: String
    let note: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: symbol)
                    .font(.system(size: 22))
                    .foregroundStyle(tint)
                    .frame(width: 44, height: 44)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                    Text(note).font(.system(size: 13)).foregroundStyle(.white.opacity(0.4)).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 12)
            .padding(.trailing, 24)
            .padding(.vertical, 12)
            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(PressableStyle(scale: 0.96))
        .padding(.bottom, 12)
    }
}

// MARK: - 演员阵容（网页版 openFullCastSheet）

struct CastSheet: View {
    let people: [CastMember]
    /// 点了某一行：同一张弹层换成那位演员（网页版也是换掉弹层里的内容，不是再叠一张）
    @State private var actor: CastMember?

    var body: some View {
        Group {
            if let actor {
                ActorPanel(member: actor)
                    .transition(.opacity)
            } else {
                WebSheetBody(title: "演员阵容 · \(people.count) 位") {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(people.enumerated()), id: \.offset) { _, m in
                                Button {
                                    Haptics.light()
                                    withAnimation(.snappy) { actor = m }
                                } label: {
                                    CastRow(member: m)
                                }
                                .buttonStyle(CastRowStyle())
                                .accessibilityIdentifier("cast-row")
                            }
                        }
                        .padding(.top, 4)
                        .padding(.bottom, 8)
                    }
                    .scrollIndicators(.hidden)
                    // 网页版 .cast-full-list：左右各往外放 8（行自己有 12 的内边距，头像和标题左沿差 4）
                    .padding(.horizontal, -8)
                }
            }
        }
        .presentationDetents([.fraction(0.72), .large])
    }
}

/// 一行：52 的圆头像、名字（16 半粗）、「饰 …」（13 号 65% 白）、右边 ›（40% 白）
struct CastRow: View {
    let member: CastMember

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Color(red: 58 / 255, green: 58 / 255, blue: 60 / 255)
                if member.profileURL == nil {
                    LinearGradient(colors: [Color(red: 44 / 255, green: 44 / 255, blue: 46 / 255), Color(red: 26 / 255, green: 26 / 255, blue: 28 / 255)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Text(CastSheetText.initial(member.name))
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white.opacity(0.55))
                } else {
                    RemoteImage(url: member.profileURL, maxPixel: 160, placeholder: .clear)
                }
            }
            .frame(width: 52, height: 52)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5))

            VStack(alignment: .leading, spacing: 2) {
                Text(member.name)
                    .font(.system(size: 16, weight: .semibold))
                    .tracking(-0.16)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let ch = member.character, !ch.isEmpty {
                    Text("饰 " + ch)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.4))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// 按下去：一层白 10% 的底、略缩（网页版 .cast-row:active）
struct CastRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.white.opacity(configuration.isPressed ? 0.1 : 0), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - 演员（网页版 openActorSheet）

/// 从横排头像直接点进来时用的那一张（弹层里只有这位演员）
struct ActorSheet: View {
    let member: CastMember

    var body: some View {
        ActorPanel(member: member)
            .presentationDetents([.height(540), .large])
    }
}

/// 140 的圆头像（没有照片是人像符号）、名字 22 粗体、「饰 …」15 号；下面「在资料库中搜索」「在 TMDB 查看」
struct ActorPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    let member: CastMember

    var body: some View {
        WebSheetBody {
            VStack(spacing: 14) {
                ZStack {
                    Color(red: 44 / 255, green: 44 / 255, blue: 46 / 255)
                    if let u = CastSheetText.largePhoto(member) {
                        RemoteImage(url: u, maxPixel: 500, placeholder: .clear)
                    } else {
                        Image(systemName: "person.fill")
                            .font(.system(size: 56))
                            .foregroundStyle(.white.opacity(0.65))
                    }
                }
                .frame(width: 140, height: 140)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.55), radius: 20, y: 16)

                VStack(spacing: 6) {
                    Text(member.name.isEmpty ? "未知演员" : member.name)
                        .font(.system(size: 22, weight: .bold))
                        .tracking(-0.22)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                    if let ch = member.character, !ch.isEmpty {
                        Text("饰 " + ch)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white.opacity(0.65))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                    }
                }
                .padding(.horizontal, 8)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 30)
            .padding(.bottom, 20)

            WebSheetButton(symbol: "magnifyingglass", tint: Color(red: 10 / 255, green: 132 / 255, blue: 1),
                           label: "在资料库中搜索", note: "查找该演员在你库中的作品") {
                let name = member.name
                dismiss()
                guard !name.isEmpty else { return }
                // 网页版：关掉弹层和详情、打开搜索、把名字填进搜索框。这里换到「搜索」标签并填上（详情页留在原来那个标签里）
                model.searchRequest = name
            }
            .accessibilityIdentifier("actor-search")
            WebSheetButton(symbol: "arrow.up.right.square", tint: Color(red: 48 / 255, green: 209 / 255, blue: 88 / 255),
                           label: "在 TMDB 查看", note: "演员档案 · 传记 · 完整作品年表") {
                if let u = CastSheetText.tmdbPage(member) { openURL(u) }
                dismiss()
            }
            .accessibilityIdentifier("actor-tmdb")
        }
    }
}

// MARK: - 分集「更多」（网页版 tvEpDescSheet：这是一张读的弹层，底下写「关闭」）

struct EpisodeSheetItem: Identifiable {
    let id = UUID()
    /// 「第 1 集 · 45 分钟」
    let kicker: String
    let title: String
    let overview: String
}

struct EpisodeSheet: View {
    let item: EpisodeSheetItem

    var body: some View {
        WebSheetBody(closeLabel: "关闭") {
            VStack(spacing: 0) {
                if !item.kicker.isEmpty {
                    Text(item.kicker)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.4))
                        .multilineTextAlignment(.center)
                        .padding(.bottom, 6)
                }
                Text(item.title)
                    .font(.system(size: 20, weight: .bold))
                    .tracking(-0.32)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 14)
                // 网页版 .ep-sheet-body：15.5 号、行高 1.62、65% 白，自己限高能滚（不把弹层顶出屏幕）
                ScrollView {
                    Text(item.overview)
                        .font(.system(size: 15.5))
                        .lineSpacing(7)
                        .foregroundStyle(.white.opacity(0.65))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .scrollIndicators(.hidden)
                .frame(maxHeight: 460)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 30)
        }
        .presentationDetents([.fraction(0.55), .large])
    }
}

// MARK: - 小工具

enum CastSheetText {
    /// 名字的头一个字（网页版 no-photo-initial）
    static func initial(_ name: String) -> String {
        let n = name.trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? "?" : String(n.prefix(1)).uppercased()
    }

    /// 演员弹层用大一号的照片（网页版 w500）
    static func largePhoto(_ m: CastMember) -> URL? {
        guard let p = m.profilePath, !p.isEmpty else { return nil }
        if p.hasPrefix("http") || p.hasPrefix("demo:") { return URL(string: p) }
        return URL(string: "https://image.tmdb.org/t/p/w500" + p)
    }

    /// TMDB 的演员页；没有编号就按名字搜
    static func tmdbPage(_ m: CastMember) -> URL? {
        if let id = m.id { return URL(string: "https://www.themoviedb.org/person/\(id)") }
        var c = URLComponents(string: "https://www.themoviedb.org/search")
        c?.queryItems = [URLQueryItem(name: "query", value: m.name)]
        return c?.url
    }
}

/// 横排头像点进演员弹层（.sheet(item:) 要一个能区分的值）
struct ActorPick: Identifiable {
    let id = UUID()
    let member: CastMember
}
