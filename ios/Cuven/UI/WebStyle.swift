import SwiftUI

// MARK: - 还留着的几个小部件
//
// 主页按 HIG 重做以后，分区玻璃胶囊、年份玻璃条、横版 / 竖版旧卡、「Cuven TV」高卡都删了（F3、F38、F80），
// 主页改用 Design.swift 的货架与卡；「品质保证」章也不再用（F80）。这里只剩主页「最新加入」的「新」。

/// 「新」角标：上次打开以后才入库的片子，只标在主页「最新加入」那一排。
/// 强调色只给状态（F32），而且有字、不只靠颜色（F36）；一枚小胶囊、系统文字样式（F15），不加描边和投影（F3）
struct FreshBadge: View {
    var body: some View {
        Text("新")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Theme.accent, in: Capsule())
            .accessibilityLabel("新片")
            .accessibilityIdentifier("fresh-badge")
    }
}
