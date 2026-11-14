import SwiftUI

// MARK: - 还留着的几个小部件
//
// 主页按 HIG 重做以后，分区玻璃胶囊、年份玻璃条、横版 / 竖版旧卡、「Cuven TV」高卡都删了（F3、F38、F80），
// 主页改用 Design.swift 的货架与卡。这里只剩详情页还在用的「品质保证」章，和主页「最新加入」的「新」。

/// 「品质保证」小章（网页版 .cuven-seal：11 号 800 粗，rgba(10,10,12,.52) + 模糊，1px 白 18% 描边，高 28）。
/// note：前面带「Cuven」（详情页头部那一行，12.5 号、左右 12）。主页已不用（F80）；详情页不用了以后可以删
struct QualitySeal: View {
    var note = false
    var size: CGFloat = 11
    var hPad: CGFloat = 10

    var body: some View {
        HStack(spacing: size * 0.32) {
            if note { Text("Cuven").font(.system(size: size, weight: .heavy)) }
            Text("品质保证").font(.system(size: size * 0.94, weight: .bold))
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.5), radius: 1.5, y: 1)
        .padding(.horizontal, hPad)
        .frame(height: 28)
        .background(.ultraThinMaterial, in: Capsule())
        .background(Color(red: 10 / 255, green: 10 / 255, blue: 12 / 255).opacity(0.52), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 7, y: 4)
        .environment(\.colorScheme, .dark)
        .fixedSize()
    }
}

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
