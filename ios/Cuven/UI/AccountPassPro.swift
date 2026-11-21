import SwiftUI

// MARK: - 账户页「Cuven Pass Pro」一组（用户要求：在设置中允许启用 Cuven Pass Pro 服务）
//
// 卡片里的项目（和账户页别的组同一个样子：AccountGroup / AccountRow）：
// · Cuven Pass Pro：开关（绿色）。开了以后影片经 Cuven 的加速节点传输（PassPro.swift）
// · 加速节点：开着时才有——「已连接 · 延迟 38 毫秒」/「正在检测…」/「暂时不可用，正在使用普通线路」；点一下重新检测
// · 测速对比：普通线路和 Pass Pro 各测一次，写「普通线路 23 Mbps · Pass Pro 61 Mbps」，快的那个是白字

struct PassProGroup: View {
    @State private var pass = PassPro.shared

    var body: some View {
        AccountGroup(title: "Cuven Pass Pro") {
            AccountRow(icon: "bolt.fill", title: "Cuven Pass Pro") {
                Toggle("Cuven Pass Pro", isOn: Binding(get: { pass.enabled }, set: { pass.setEnabled($0) }))
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
                        if pass.state == .checking {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: statusSymbol)
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(statusColor)
                                .accessibilityHidden(true)
                        }
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
                AccountRow(icon: "speedometer", title: "测速对比", subtitle: speedLine) {
                    if pass.testing {
                        ProgressView().controlSize(.small)
                    } else {
                        AccountValue("测速")
                    }
                }
            }
            .buttonStyle(AccountRowPress())
            .disabled(pass.testing || DemoData.enabled)
            .accessibilityIdentifier("account-pass-speed")
        }
        .sensoryFeedback(.selection, trigger: pass.enabled)
        .sensoryFeedback(.success, trigger: pass.speed?.at)
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
    private var speedLine: String? {
        if DemoData.enabled { return "演示数据不测速" }
        if pass.testing { return "正在测速，大约需要十几秒…" }
        guard let s = pass.speed else { return nil }
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
