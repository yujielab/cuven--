import SwiftUI

// MARK: - 账户页「获取软件更新」（用户要求：网络、兼容性两组各一颗，热更新 Cuven Pass 的服务器和兼容性更好的组件）
//
// 两行是同一件事（RuntimeUpdate：一份运行时配置，加速节点表 + 兼容性组件的参数），各自用自己那一组的话说结果：
// 「网络」那一行说加速节点，「兼容性」那一行说兼容性组件。行尾一颗玻璃小胶囊「获取」（和「测速」同一个样子），取的时候转圈。

struct RuntimeUpdateRow: View {
    enum Scope { case network, compat }
    let scope: Scope
    @State private var updates = RuntimeUpdate.shared

    var body: some View {
        Button {
            Haptics.light()
            Task { await updates.check() }
        } label: {
            AccountRow(icon: "arrow.down.circle", title: "获取软件更新", subtitle: subtitle) {
                RuntimeUpdatePill(busy: updates.phase == .checking)
            }
        }
        .buttonStyle(AccountRowPress())
        .disabled(updates.phase == .checking)
        // 取到了（更新了或已是最新）震一下成功；取不到不震
        .sensoryFeedback(.success, trigger: updates.phase) { _, new in
            switch new {
            case .updated, .current: return true
            default: return false
            }
        }
        .accessibilityHint(scope == .network ? "更新 Cuven Pass 的加速节点" : "更新兼容性组件")
        .accessibilityIdentifier(scope == .network ? "account-update-network" : "account-update-compat")
    }

    private var subtitle: String {
        switch updates.phase {
        case .idle:
            return scope == .network ? "更新 Cuven Pass 加速节点" : "更新兼容性更好的组件"
        case .checking:
            return "正在获取…"
        case .updated(let v):
            return scope == .network
                ? "已更新到第 \(v) 版 · 加速节点 \(updates.passNodes.count) 个"
                : "已更新到第 \(v) 版，下次播放生效"
        case .current(let v):
            return "已是最新（第 \(v) 版）"
        case .failed:
            return "暂时无法获取，请稍后再试"
        }
    }
}

/// 行尾的「获取」：取的时候胶囊里转圈、不变窄（和「测速对比」那颗同一个样子）
private struct RuntimeUpdatePill: View {
    let busy: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Text("获取")
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
        .accessibilityHidden(true)
    }
}
