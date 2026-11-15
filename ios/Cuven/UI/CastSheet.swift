import SwiftUI

// MARK: - 演员弹层（规则编号见 docs/ios-design.md：C 是组件、F 是基础、T 是 tvOS）
//
// 一张 .medium / .large 的系统弹层（C50），带拉把（C51），能下滑关掉（C52），右上一颗 xmark（C14、C55）。
// 名单一行一位（小圆照片 + 名字 + 角色，「›」：C29、C31）；点一位，弹层收起，在详情页这一栈里推进那位演员的
// 个人页（ActorPage：照 Apple Music 艺人页，不叠第二张弹层：C56）。详情页那排圆形照片直接推个人页，不经过名单。
// 用系统的 List 和弹层底色，不自绘底板、描边和胶囊按钮（F51、C17）。

/// 演员弹层从哪儿开始：nil 是名单；点了某一位就直接推到那一位（还能返回名单：C56）
struct CastSheetRequest: Identifiable {
    let id = UUID()
    let start: CastMember?
}

struct CastSheet: View {
    let people: [CastMember]
    /// 点了一位：交给详情页（收起弹层、推进那位演员的个人页）
    let onOpen: (CastMember) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(people.enumerated()), id: \.offset) { _, m in
                    Button { onOpen(m) } label: {
                        HStack {
                            CastRow(member: m)
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.forward")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle(scale: 0.98))
                    .accessibilityIdentifier("cast-row")
                }
            }
            .listStyle(.plain)
            // C12：短标题
            .navigationTitle("演员")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { closeButton }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    /// 关掉整张弹层：系统的 xmark（C14）
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
