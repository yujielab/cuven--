import SwiftUI

enum Theme {
    static let bg = Color.black
    static let surface = Color(white: 0.11)
    static let surface2 = Color(white: 0.16)
    static let secondary = Color.white.opacity(0.62)
    static let tertiary = Color.white.opacity(0.38)
    static let hairline = Color.white.opacity(0.12)
    static let accent = Color(red: 0.04, green: 0.52, blue: 1.0)
    static let cardRadius: CGFloat = 14
    static let gutter: CGFloat = 23          // 网页版左右留白
}

// 主页按 HIG 重做以后（docs/ios-design.md「主页」），旧的分区标题、海报卡、名次卡（描边大数字 + 品质章）、继续观看卡、
// 「没有更多了」占位卡、剧集拼图 / 小卡 / 大卡、规格徽标、玻璃「想看」圆钮、白色玻璃播放钮的字都删了：
// 主页的卡一律是 Design.swift 的 DSPosterLockup / DSWideLockup，分组只靠留白（F3、F38、F80）

struct ProgressCapsule: View {
    let fraction: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.28))
                Capsule().fill(Color.white).frame(width: max(4, geo.size.width * fraction))
            }
        }
        .frame(height: 4)
    }
}

/// 横向滑动的一排
struct Rail<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: () -> Content
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: spacing) { content() }
                .scrollTargetLayout()
                .padding(.horizontal, Theme.gutter)
        }
        .scrollTargetBehavior(.viewAligned)
    }
}

/// 载入中的占位（C66：先出东西，不留白屏）。传了 metrics 时和真货架同一条左边线、同样的卡宽和间距，
/// 只排一屏放得下的几张，不把版面撑宽（S6）；占位不念给旁白听
struct SkeletonRow: View {
    var metrics: DSMetrics? = nil

    var body: some View {
        let margin = metrics?.margin ?? Theme.gutter
        let gutter = metrics?.gutter ?? 12
        let w = metrics?.posterWidth ?? 128
        let count = metrics.map { max(1, Int(($0.width - 2 * $0.margin + $0.gutter) / (w + $0.gutter))) } ?? 4
        VStack(alignment: .leading, spacing: 20) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Theme.surface)
                .frame(width: 120, height: 20)
            HStack(spacing: gutter) {
                ForEach(0..<count, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Theme.surface)
                        .frame(width: w, height: (w * 1.5).rounded())
                }
            }
        }
        .padding(.horizontal, margin)
        .accessibilityHidden(true)
    }
}

/// 自动换行的一排（规格徽标等）：一行放不下就折到下一行，不会把整列撑得比屏幕宽
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > maxW { y += lineH + lineSpacing; x = 0; lineH = 0 }
            x += s.width + spacing
            lineH = max(lineH, s.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, maxW), height: y + lineH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { y += lineH + lineSpacing; x = bounds.minX; lineH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            lineH = max(lineH, s.height)
        }
    }
}
