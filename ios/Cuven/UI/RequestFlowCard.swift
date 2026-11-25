import SwiftUI

// MARK: - 请求中心最上面那张卡：「Luminous Data Flow」（用户要求：影片进入传输时有动画效果和进度条；参照用户发来的录屏和设计说明）
//
// 近黑的卡（圆角 22、1 点细边），三层：
// · 导航：全部 / 电影 / 剧集（选中那个下面一条细线滑过去）
// · 数据：四段（已确认 → 已下载 → 已清洗 → 已入库）的数，下面一行灰的百分比（都是等宽数字，跳的时候不左右晃）；每一段正对着下面漏斗的那一段
// · 可视化：一整块连续的发光漏斗（FlowFunnelCanvas，Metal）。左右两头没有边界：靠近左右边缘时点阵、边线越来越虚、越来越淡，
//   融进卡的底色（用户要求「粒子没有边界，靠近左右边缘时使用模糊淡出」）；以前下面那颗「最大落差」小标签用户要求移除
// 数那一行和漏斗都占满卡里的整个宽度（用户要求：去掉右上角的发光小点 +「传输流 · 24 小时」和漏斗右边的「入库率 · 共 N 部」，
// 让框起来的这块撑满整张卡）；入库率和「近 24 小时」改在读屏的 value 里念，批量到了哪一步看下面的进度条。
// 批量传输时下面多一条发光的进度条（几部、多少 GB、速度、还要多久）；还在凑批时是一排 16 格的「凑批」进度。
// 数字、百分比、漏斗形状、颜色、能量波都读 FlowFunnelEngine 的同一份插值状态：切分类、数据变了，整张卡一起平滑地变过去，
// 不淡出重来；中途再切就从当时的样子接着走。减弱动态效果时：没有能量波，数直接到位。

struct RequestFlowCard: View {
    let requests: [RequestStatus]
    let flow: RequestFlowInfo?
    let flowAt: Date
    let metrics: DSMetrics

    @State private var category: RequestFlowStats.Category = .all
    @State private var engine = FlowFunnelEngine()
    @State private var visible = false
    @Namespace private var tabs
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    private var flowList: [RequestStatus] { RequestFlowStats.inFlow(requests) }
    private var counts: [Int] { RequestFlowStats.counts(flowList, category: category) }
    private var batch: RequestFlowInfo.Batch? { flow?.batch }
    private var transferring: Bool { batch?.stage == "copy" }

    /// 宽屏（iPad、展开的 Duo）：漏斗高一点、四段的数大一号
    private var big: Bool { metrics.wide }
    private var funnelHeight: CGFloat { big ? 150 : 112 }

    var body: some View {
        VStack(alignment: .leading, spacing: big ? 16 : 14) {
            header
            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 0.5)
            // 数和漏斗是一整块：读屏念一句总结（分类按钮、进度条单独念）
            dataAndFunnel
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilitySummary)
                .accessibilityValue(accessibilityRate)
            footer
        }
        .padding(big ? 20 : 16)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(white: Double(FlowFunnelRenderer.background)))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        )
        .onAppear {
            visible = true
            engine.reduceMotion = reduceMotion
            push()
        }
        .onDisappear { visible = false }
        // 滚出屏幕就停（不在看的时候不耗电）
        .onScrollVisibilityChange(threshold: 0.02) { visible = $0 && scenePhase == .active }
        .onChange(of: counts) { _, _ in push() }
        .onChange(of: category) { _, _ in push() }
        .onChange(of: flow) { _, _ in push() }
        .onChange(of: scenePhase) { _, p in visible = p == .active }
        .accessibilityElement(children: .contain)
    }

    private func push() {
        engine.update(counts: counts, palette: category.palette, progress: progress(at: Date()), transferring: transferring)
    }

    // MARK: 导航层

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            ForEach(RequestFlowStats.Category.allCases) { c in
                Button {
                    withAnimation(.smooth(duration: reduceMotion ? 0.01 : 0.3)) { category = c }
                    Haptics.selection()
                } label: {
                    VStack(spacing: 6) {
                        Text(c.title)
                            .font(.subheadline.weight(category == c ? .semibold : .regular))
                            .foregroundStyle(category == c ? Color.white : Color.white.opacity(0.42))
                        ZStack {
                            Capsule().fill(Color.clear).frame(height: 1.5)
                            if category == c {
                                Capsule().fill(Color.white.opacity(0.9)).frame(height: 1.5)
                                    .matchedGeometryEffect(id: "tab", in: tabs)
                            }
                        }
                    }
                    .fixedSize()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(category == c ? .isSelected : [])
                .accessibilityIdentifier("flow-tab-\(c.rawValue)")
            }
            // 右上角那颗发光小点 +「传输流 · 24 小时」/「批量传输中」去掉了（用户要求：这一行只留分类）
        }
    }

    private var accent: Color {
        let p = category.palette.primary
        return Color(red: p.x, green: p.y, blue: p.z)
    }

    // MARK: 数据层 + 漏斗

    /// 跟着插值走的数：每一帧从 engine 取同一份状态（和漏斗的形状、颜色是同一个时刻的值）
    private func live<Content: View>(@ViewBuilder _ content: @escaping (FlowFunnelEngine.Sample) -> Content) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !visible || reduceMotion)) { ctx in
            let _ = ctx.date
            content(engine.sample())
        }
    }

    /// 数一行 + 漏斗一块，左右都撑满卡里的整个宽度（用户要求：去掉右边那块「入库率 · 共 N 部」，让这两样占满整张卡）。
    /// 四列等宽、漏斗也按宽度四等分（FlowFunnel.metal 里每段 0.25），两边同宽，所以每一列仍正对着下面漏斗的那一段
    private var dataAndFunnel: some View {
        VStack(alignment: .leading, spacing: big ? 12 : 10) {
            live { s in
                let c = s.counts
                let top = max(c[0], 0.0001)
                HStack(alignment: .top, spacing: 0) {
                    ForEach(0..<4, id: \.self) { i in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(RequestFlowStats.stageNames[i])
                                .font(.caption2)
                                .foregroundStyle(Color.white.opacity(0.5))
                            Text("\(Int(c[i].rounded()))")
                                .font(.system(size: big ? 22 : 17, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(.white)
                            Text(percent(c[0] > 0.5 ? c[i] / top : 0))
                                .font(.caption2)
                                .monospacedDigit()
                                .foregroundStyle(Color.white.opacity(0.38))
                        }
                        .padding(.leading, i == 0 ? 2 : 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }
            // 不裁圆角：左右两头在着色器里虚化、淡进卡的底色（FlowFunnel.metal），看不到一条边
            FlowFunnelCanvas(engine: engine, active: visible)
                .frame(maxWidth: .infinity)
                .frame(height: funnelHeight)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func percent(_ x: Double) -> String {
        String(format: "%.1f%%", max(0, min(1, x)) * 100)
    }

    // MARK: 进度条（批量传输）/ 凑批

    /// 这一刻传了多少（服务器的数 + 按速度往前推到现在，最多推到 99.5%）
    private func progress(at now: Date) -> Double {
        guard let b = batch, b.total > 0 else { return 0 }
        if b.stage != "copy" { return 1 }
        let moved = b.bytes + b.speed * max(0, now.timeIntervalSince(flowAt))
        return min(0.995, max(0, moved / b.total))
    }

    @ViewBuilder
    private var footer: some View {
        if let b = batch {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                batchProgress(b, now: ctx.date)
            }
        } else if let g = flow?.gate, g.ready > 0 {
            gateProgress(g)
        }
    }

    private func batchProgress(_ b: RequestFlowInfo.Batch, now: Date) -> some View {
        let p = progress(at: now)
        let moved = b.stage == "copy" ? p * b.total : b.total
        let left = b.speed > 0 ? max(0, (b.total - moved) / b.speed) : (b.eta ?? 0)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("批量传输")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                Text(b.mine.isEmpty ? "\(b.items) 部" : "\(b.items) 部 · 其中 \(b.mine.count) 部是你的")
                    .font(.footnote)
                    .foregroundStyle(Color.white.opacity(0.5))
                Spacer(minLength: 8)
                Text(b.stage == "copy" ? String(format: "%.0f%%", p * 100) : (b.stage == "verify" ? "核对中" : "收尾中"))
                    .font(.footnote.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
            }
            FlowProgressBar(progress: b.stage == "copy" ? p : 1, palette: category.palette, live: b.stage == "copy" && !reduceMotion)
                .frame(height: 4)
            HStack {
                Text("\(Self.size(moved)) / \(Self.size(b.total))")
                Spacer(minLength: 8)
                if b.stage == "copy" {
                    Text("\(Self.size(b.speed))/s · \(Self.remaining(left))")
                } else {
                    Text("\(b.filesTotal) 个文件")
                }
            }
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(Color.white.opacity(0.5))
            .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private func gateProgress(_ g: RequestFlowInfo.Gate) -> some View {
        let need = max(1, g.need)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("凑批")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                Text("已清洗 \(g.ready) 部 · 满 \(need) 部开始批量传输")
                    .font(.footnote)
                    .foregroundStyle(Color.white.opacity(0.5))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            HStack(spacing: 3) {
                ForEach(0..<need, id: \.self) { i in
                    Capsule()
                        .fill(i < g.ready ? AnyShapeStyle(accent.mix(with: .white, by: 0.25)) : AnyShapeStyle(Color.white.opacity(0.1)))
                        .frame(height: 4)
                }
            }
            .animation(.smooth(duration: 0.4), value: g.ready)
        }
    }

    static func size(_ b: Double) -> String {
        let s = Format.size(Int64(max(0, b)))
        return s.isEmpty ? "0 MB" : s
    }

    static func remaining(_ s: Double) -> String {
        if s < 60 { return "不到 1 分钟" }
        if s < 3600 { return "约 \(Int((s / 60).rounded())) 分钟" }
        let h = Int(s / 3600), m = Int((s - Double(h) * 3600) / 60)
        return m > 0 ? "约 \(h) 小时 \(m) 分钟" : "约 \(h) 小时"
    }

    private var accessibilitySummary: String {
        let c = counts
        var parts = ["\(category.title)：已确认 \(c[0]) 部，已下载 \(c[1]) 部，已清洗 \(c[2]) 部，已入库 \(c[3]) 部"]
        if let b = batch, b.stage == "copy" { parts.append(String(format: "批量传输 %.0f%%", progress(at: Date()) * 100)) }
        return parts.joined(separator: "。")
    }

    /// 卡上不再单独显示「入库率 · 共 N 部」和「传输流 · 24 小时」（用户要求去掉），读屏还要听得到：放在这一块的 value 里
    private var accessibilityRate: String {
        let c = counts
        return "入库率 \(percent(c[0] > 0 ? Double(c[3]) / Double(c[0]) : 0))，近 24 小时共 \(c[0]) 部"
    }
}

/// 发光的进度条：细轨道 + 一段同色渐变的光（左主色 → 右副色），前端亮一点；传输中有一道很淡的光慢慢扫过已传的那一段
struct FlowProgressBar: View {
    let progress: Double
    let palette: FlowPalette
    var live: Bool

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width * max(0, min(1, progress))
            let c0 = Color(red: palette.primary.x, green: palette.primary.y, blue: palette.primary.z)
            let c1 = Color(red: palette.secondary.x, green: palette.secondary.y, blue: palette.secondary.z)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(colors: [c0, c1], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(w, geo.size.height))
                    .shadow(color: c1.opacity(0.55), radius: 5)
                    .overlay(alignment: .leading) {
                        if live {
                            TimelineView(.animation(minimumInterval: 1.0 / 30)) { ctx in
                                let t = ctx.date.timeIntervalSinceReferenceDate
                                let x = (t.truncatingRemainder(dividingBy: 2.4) / 2.4) * Double(max(w, 1)) - 24
                                LinearGradient(colors: [.clear, .white.opacity(0.55), .clear], startPoint: .leading, endPoint: .trailing)
                                    .frame(width: 48)
                                    .offset(x: x)
                            }
                            .frame(width: max(w, geo.size.height), alignment: .leading)
                            .clipShape(Capsule())
                        }
                    }
                    .animation(.smooth(duration: 0.8), value: w)
            }
        }
        .accessibilityHidden(true)
    }
}
