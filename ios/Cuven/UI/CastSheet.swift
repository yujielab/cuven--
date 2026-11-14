import SwiftUI

// MARK: - 演员弹层（规则编号见 docs/ios-design.md：C 是组件、F 是基础、T 是 tvOS）
//
// 一张 .medium / .large 的系统弹层（C50），带拉把（C51），能下滑关掉（C52），右上一颗 xmark（C14、C55）。
// 里面是一个导航栈：名单一行一位（小圆照片 + 名字 + 角色，系统的「›」：C29、C31），点一位就在弹层里推进去，
// 不再叠第二张弹层（C56）；从详情页那排圆形照片点进来的，直接停在那一位上，左上角还能返回名单。
// 用系统的 List 和弹层底色，不自绘底板、描边和胶囊按钮（F51、C17）。

/// 演员弹层从哪儿开始：nil 是名单；点了某一位就直接推到那一位（还能返回名单：C56）
struct CastSheetRequest: Identifiable {
    let id = UUID()
    let start: CastMember?
}

struct CastSheet: View {
    let people: [CastMember]
    @State private var path: [CastMember]
    @Environment(\.dismiss) private var dismiss

    init(people: [CastMember], start: CastMember? = nil) {
        self.people = people
        _path = State(initialValue: start.map { [$0] } ?? [])
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                ForEach(Array(people.enumerated()), id: \.offset) { _, m in
                    NavigationLink(value: m) { CastRow(member: m) }
                        .accessibilityIdentifier("cast-row")
                }
            }
            .listStyle(.plain)
            // C12：短标题
            .navigationTitle("演员")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { closeButton }
            .navigationDestination(for: CastMember.self) { m in
                // 推进来的页面自己的 dismiss 只会退回名单；关整张弹层用这里的
                ActorPanel(member: m, close: { dismiss() })
                    .toolbar { closeButton }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    /// 关掉整张弹层：系统的 xmark（C14）；推进去以后也在——左边是返回，右边是它
    private var closeButton: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button { dismiss() } label: {
                Label("关闭", systemImage: "xmark")
            }
            .accessibilityIdentifier("sheet-cancel")
        }
    }
}

/// 名单里的一行（C29：前面一张小图，后面简短的字）：44 的圆形照片、名字（Body）、「饰 …」（Subheadline、次要色：F18）
struct CastRow: View {
    let member: CastMember

    var body: some View {
        HStack(spacing: 14) {
            CastPhoto(member: member, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(member.name.isEmpty ? "未知演员" : member.name)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let ch = member.character, !ch.isEmpty {
                    Text("饰 " + ch)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// 圆形照片（T21 monogram：照片优先，没有照片才是名字的头一个字）。只是图，旁白读旁边的名字
struct CastPhoto: View {
    let member: CastMember
    let size: CGFloat
    /// 演员页用大一号的照片（w500）
    var large = false

    var body: some View {
        let url = large ? CastSheetText.largePhoto(member) : member.profileURL
        ZStack {
            Color(uiColor: .systemGray5)
            Text(CastSheetText.initial(member.name))
                .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
            if url != nil {
                RemoteImage(url: url, maxPixel: size * 3, placeholder: .clear)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}

// MARK: - 一位演员（在弹层里推进来的那一页）

/// 大圆照片、名字、角色；下面两件事：在资料库里搜这位、去 TMDB 看（C29、C37：动词开头）。
/// 名字已经写在页面上，导航栏不再重复标题（C12）
struct ActorPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let member: CastMember
    /// 关掉整张弹层
    let close: () -> Void

    var body: some View {
        List {
            Section {
                VStack(spacing: 10) {
                    CastPhoto(member: member, size: 120, large: true)
                    Text(member.name.isEmpty ? "未知演员" : member.name)
                        .font(.title2.bold())
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.center)
                    if let ch = member.character, !ch.isEmpty {
                        Text("饰 " + ch)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
                .accessibilityElement(children: .combine)
            }
            Section {
                Button {
                    let name = member.name
                    close()
                    guard !name.isEmpty else { return }
                    // 换到「搜索」标签并把名字填进去（详情页留在原来那个标签里）
                    model.searchRequest = name
                } label: {
                    Label("在资料库中搜索", systemImage: "magnifyingglass")
                }
                .accessibilityIdentifier("actor-search")
                Button {
                    if let u = CastSheetText.tmdbPage(member) { openURL(u) }
                } label: {
                    Label("在 TMDB 查看", systemImage: "arrow.up.right.square")
                }
                .accessibilityIdentifier("actor-tmdb")
            }
        }
        .listStyle(.insetGrouped)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 小工具

enum CastSheetText {
    /// 名字的头一个字（没有照片时的 monogram）
    static func initial(_ name: String) -> String {
        let n = name.trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? "?" : String(n.prefix(1)).uppercased()
    }

    /// 演员页用大一号的照片（w500）
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
