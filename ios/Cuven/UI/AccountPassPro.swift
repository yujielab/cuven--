import SwiftUI

// MARK: - 账户页「Cuven Pass Pro」那几行（用户要求：在设置中允许启用 Cuven Pass Pro 服务；后来要求并进「网络」那张卡）
//
// 放在「网络」卡里网络速度、自动调整下面（NetworkSpeedCard），三行（AccountRow）：
// · Cuven Pass Pro：开关（绿色）。开了以后影片经 Cuven 的加速节点传输（PassPro.swift）
// · 加速节点：开着时才有——「已连接 · 延迟 38 毫秒」/「正在检测…」/「暂时不可用，正在使用普通线路」；点一下重新检测
// · 测速对比：普通线路和 Pass Pro 各测一次，写「普通线路 23 Mbps · Pass Pro 61 Mbps」，快的那个是白字
// 不说 Worker / VPS 这些技术词（发行版文案规则）。

struct PassProRows: View {
    @State private var pass = PassPro.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // 一个 VStack 包起来（不用 Group：Group 上的触感修饰会落到每一行上，各响一次）
        VStack(spacing: 0) {
            AccountRow(icon: "bolt.fill", title: "Cuven Pass Pro", subtitle: "影片经加速节点传输") {
                Toggle("Cuven Pass Pro", isOn: enabledBinding)
                    .labelsHidden()
                    .tint(.green)
                    .accessibilityIdentifier("account-pass-pro")
            }
            if pass.enabled {
                AccountDivider()
                Button {
                    Task { await pass.check() }
                } label: {
                    AccountRow(icon: "antenna.radiowaves.left.and.right", title: "加速节点", subtitle: statusLine) {
                        PassProStatusMark(state: pass.state, symbol: statusSymbol, color: statusColor)
                    }
                }
                .buttonStyle(AccountRowPress())
                .accessibilityHint("重新检测加速节点")
                .accessibilityIdentifier("account-pass-status")
            }
            AccountDivider()
            Button {
                Task { await pass.compare() }
            } label: {
                // 说明最多三行：行尾换成胶囊以后字那一列窄了一点，折起的 Duo 上「普通线路 … · Pass Pro …（快 …%）」不被截断
                AccountRow(icon: "speedometer", title: "测速对比", subtitle: speedLine, subtitleLines: 3) {
                    PassProTestPill(busy: pass.testing)
                }
            }
            .buttonStyle(AccountRowPress())
            .disabled(pass.testing || DemoData.enabled)
            .accessibilityIdentifier("account-pass-speed")
        }
        .sensoryFeedback(.selection, trigger: pass.enabled)
        .sensoryFeedback(.success, trigger: pass.speed?.at)
    }

    /// 开关：「加速节点」那一行跟着淡入 / 收走，卡和下面几组一起慢慢让开——以前一拨开关，卡一下子跳高一行
    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { pass.enabled },
            set: { on in
                withAnimation(DSMotion.adapt(DSMotion.snap, reduce: reduceMotion)) { pass.setEnabled(on) }
            })
    }

    private var statusLine: String {
        switch pass.state {
        case .off: return "未开启"
        case .checking: return "正在检测…"
        case .ready(let rtt): return "已连接 · 延迟 \(rtt) 毫秒"
        case .down: return "暂时不可用，正在使用普通线路"
        }
    }

    private var statusSymbol: String {
        if case .ready = pass.state { return "checkmark.circle.fill" }
        return "exclamationmark.triangle.fill"
    }

    private var statusColor: Color {
        if case .ready = pass.state { return Color(red: 0.19, green: 0.82, blue: 0.35) }
        return Color(red: 1.0, green: 0.62, blue: 0.04)
    }

    /// 「普通线路 23 Mbps · Pass Pro 61 Mbps」：哪个快一眼看得出（快的那个排前面写「更快」）
    private var speedLine: String {
        if DemoData.enabled { return "演示数据不测速" }
        if pass.testing { return "正在测速，大约需要十几秒…" }
        guard let s = pass.speed else { return "比较普通线路和 Pass Pro 的速度" }
        let d = s.direct.map(Self.mbps) ?? "无法测速"
        let p = s.pass.map(Self.mbps) ?? "暂时不可用"
        var line = "普通线路 \(d) · Pass Pro \(p)"
        if let a = s.direct, let b = s.pass, a > 0, b > 0 {
            let r = b / a
            if r >= 1.15 { line += "（快 \(Int(((r - 1) * 100).rounded()))%）" }
            else if r <= 0.87 { line += "（普通线路更快）" }
        }
        return line
    }

    private static func mbps(_ v: Double) -> String {
        v < 10 ? String(format: "%.1f Mbps", v) : "\(Int(v.rounded())) Mbps"
    }
}

/// 「加速节点」行尾：转圈和结果的符号互相淡入淡出（以前检测完一下子换掉）；转圈是白的，和这一页别的转圈一样
private struct PassProStatusMark: View {
    let state: PassPro.State
    let symbol: String
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var markTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.8))
    }

    /// 刚拨开开关、检测还没开始的那一瞬（.off）也算在检测：不先闪一下橙色的三角
    private var busy: Bool { state == .checking || state == .off }

    var body: some View {
        ZStack {
            if busy {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
                    .transition(.opacity)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(color)
                    .contentTransition(.symbolEffect(.replace))
                    .transition(markTransition)
                    .accessibilityHidden(true)
            }
        }
        .frame(minWidth: 24, minHeight: 24)
        .animation(DSMotion.adapt(DSMotion.snap, reduce: reduceMotion), value: state)
    }
}

/// 「测速对比」行尾：一颗玻璃小胶囊（和资料卡的「更改」同一个大小），看得出这一行是个动作——
/// 以前是一个灰字「测速」，和「登录方式 密码」那种只读的数值一个样子。只是样子，点的还是整行；测的时候胶囊里转圈、不变窄
private struct PassProTestPill: View {
    let busy: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Text("测速")
                .opacity(busy ? 0 : 1)
            if busy {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
                    .transition(.opacity)
            }
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.white)
        .lineLimit(1)
        .padding(.horizontal, 13)
        .frame(minHeight: 30)
        .glassEffect(.regular, in: Capsule())
        .fixedSize()
        .animation(DSMotion.adapt(DSMotion.snap, reduce: reduceMotion), value: busy)
    }
}
