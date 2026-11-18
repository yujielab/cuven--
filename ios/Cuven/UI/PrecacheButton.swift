import SwiftUI

// MARK: - 详情页弱网时的那一行（用户给的草图：左边一颗宽的、右边一颗圆的；圆里的动画照用户给的关键帧）
//
// · 网络不好、或者「网络速度」低于 50%（Precache.suggested）：「播放」换成白色的「预先画面质量处理」；
// · 按下：这一颗不是换掉，是同一颗在变——宽的白胶囊缩成一颗圆形的透明液态玻璃、往右滑到这一行的最右边，
//   左边空出来的地方长出白色的「立即播放」（弹簧，同一个视图连续变形，不是淡出淡入两颗）；
// · 圆里（关键帧）：下载箭头 → 灰圈里虚线圈从底下画出来、箭头淡掉 → 整圈虚线转着（在准备）→ 虚线圈里一颗停止方块（排着队 / 等网络）
//   → 白色实线圈 + 从 12 点钟方向长出来的进度饼（在下：已经下的 ÷ 能下的上限）→ 下完了一个对勾；空间不够 / 出错是感叹号；
// · 点圆钮：一张选项（暂停 / 继续、删除已缓存的内容），旁白念「预先缓存，37%」；
// · 「减弱动态效果」时：不转、变形换成淡入淡出。

/// 预先缓存开不了时的提示（空间不够、演示数据）
struct PrecacheAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// 详情页这一行要的：现在是建议（还没按）还是已经在缓存，缓存到哪儿了，几颗钮的动作
struct DetailPrecache {
    enum Mode: Equatable { case suggest, active }
    var mode: Mode
    var phase: Precache.Phase?
    var progress: Double
    var bytes: Int64
    var onStart: () -> Void
    var onPause: () -> Void
    var onResume: () -> Void
    var onDelete: () -> Void
}

struct PrecachePlayRow: View {
    let precache: DetailPrecache
    let wide: Bool
    let playID: String
    let playDisabled: Bool
    let onPlay: () -> Void
    @State private var showOptions = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var active: Bool { precache.mode == .active }

    var body: some View {
        let minW: CGFloat = wide ? 180 : 0
        HStack(spacing: active ? 12 : 0) {
            if active {
                Button(action: onPlay) {
                    Label("立即播放", systemImage: "play.fill")
                        .lineLimit(1)
                        .frame(minWidth: minW, maxWidth: wide ? nil : .infinity)
                }
                .buttonStyle(.dsPlay)
                .disabled(playDisabled)
                .opacity(playDisabled ? 0.5 : 1)
                .transition(reduceMotion ? .opacity
                            : .asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.9, anchor: .leading)), removal: .opacity))
                .accessibilityIdentifier(playID)
            }
            morphing(minW: minW)
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.25) : .spring(response: 0.55, dampingFraction: 0.82), value: active)
        .confirmationDialog("预先画面质量处理", isPresented: $showOptions, titleVisibility: .visible) {
            if precache.phase == .paused || precache.phase == .noSpace || precache.phase == .failed {
                Button("继续缓存", action: precache.onResume)
            } else if precache.phase != .done {
                Button("暂停缓存", action: precache.onPause)
            }
            Button("删除已缓存的内容", role: .destructive, action: precache.onDelete)
            Button("取消", role: .cancel) {}
        } message: {
            Text(optionsMessage)
        }
    }

    /// 那一颗会变的：建议时是宽的白胶囊「预先画面质量处理」，缓存时是 48 点的圆形透明玻璃（里面是关键帧那几样）
    private func morphing(minW: CGFloat) -> some View {
        Button {
            if active { showOptions = true } else { precache.onStart() }
        } label: {
            ZStack {
                Label("预先画面质量处理", systemImage: "arrow.down.to.line")
                    .font(.headline)
                    .foregroundStyle(.black)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .padding(.horizontal, 20)
                    .opacity(active ? 0 : 1)
                PrecacheGlyph(phase: active ? precache.phase : nil, progress: precache.progress)
                    .opacity(active ? 1 : 0)
            }
            .frame(minWidth: active ? 48 : minW, maxWidth: active ? 48 : (wide ? nil : .infinity), minHeight: 48, maxHeight: 48)
            .background {
                // 白底退掉，底下的透明玻璃露出来（同一颗变形：宽 → 圆）
                Capsule().fill(Color.white).opacity(active ? 0 : 1)
            }
            .glassEffect(.regular.interactive(), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(active ? "预先缓存" : "预先画面质量处理")
        .accessibilityValue(active ? spokenState : "")
        .accessibilityHint(active ? "轻点查看选项" : "先把接下来的画面下载到本机，网络不好也能流畅播放")
        .accessibilityIdentifier(active ? "detail-precache-status" : "detail-precache")
    }

    private var spokenState: String {
        switch precache.phase {
        case .preparing?: return "正在准备"
        case .queued?: return "排队中"
        case .downloading?: return "\(Int((precache.progress * 100).rounded()))%"
        case .paused?: return "已暂停，\(Int((precache.progress * 100).rounded()))%"
        case .done?: return "已完成"
        case .noSpace?: return "储存空间不足"
        case .failed?: return "无法缓存"
        case nil: return ""
        }
    }

    private var optionsMessage: String {
        let size = ByteCountFormatter.string(fromByteCount: precache.bytes, countStyle: .file)
        switch precache.phase {
        case .done?: return "已缓存 \(size)。播放时会接着缓存后面的内容。"
        case .noSpace?: return "iPhone 储存空间不足。已缓存 \(size)。"
        case .paused?: return "已暂停，已缓存 \(size)。"
        case .preparing?, .queued?: return "正在准备，网络好时会同时缓存多部影片。"
        default: return "已缓存 \(Int((precache.progress * 100).rounded()))%（\(size)）。可以先开始播放。"
        }
    }
}

/// 圆钮里的那几样（照关键帧）：下载箭头、灰圈 + 转着的虚线圈、停止方块、白圈 + 进度饼、对勾、感叹号
struct PrecacheGlyph: View {
    /// nil：还没按（只出箭头）
    let phase: Precache.Phase?
    let progress: Double
    /// 刚按下时先停在下载箭头上一会儿（关键帧 1），再画出虚线圈
    @State private var arrived = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Look: Equatable { case arrow, spinner, waiting, progress, done, error }

    private var look: Look {
        switch phase {
        case nil: return .arrow
        case .preparing?: return arrived ? .spinner : .arrow
        case .queued?: return .waiting
        case .downloading?: return progress > 0.004 ? .progress : .spinner
        case .paused?: return .progress
        case .done?: return .done
        case .failed?, .noSpace?: return .error
        }
    }

    var body: some View {
        let l = look
        let ring = l == .progress || l == .done
        let dashed = l == .spinner || l == .waiting
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !dashed || reduceMotion)) { ctx in
            let turn = reduceMotion ? 0 : ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6 * 360
            ZStack {
                // 外圈：准备时一圈淡灰（关键帧 2–5），下载时一圈白色实线（7–8）
                Circle()
                    .stroke(Color.white.opacity(ring ? 0.95 : 0.25), lineWidth: ring ? 2 : 3)
                    .frame(width: 28, height: 28)
                    .opacity(l == .arrow ? 0 : 1)
                // 虚线圈：从底下画出来，画满了转着（2–6）
                Circle()
                    .trim(from: 0, to: dashed ? 1 : 0.2)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 2.4, lineCap: .round, dash: [3, 3.6]))
                    .frame(width: 19, height: 19)
                    .rotationEffect(.degrees(90 + turn))
                    .opacity(dashed ? 1 : 0)
                // 下载箭头（1–3）
                Image(systemName: "arrow.down.to.line")
                    .font(.system(size: 17, weight: .semibold))
                    .scaleEffect(l == .arrow ? 1 : 0.6)
                    .opacity(l == .arrow ? 1 : 0)
                // 停止方块：排着队、在等网络（5–6）
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(Color.white)
                    .frame(width: 7, height: 7)
                    .opacity(l == .waiting ? 1 : 0)
                // 进度饼：从 12 点钟方向顺时针长（7–8）；暂停时淡一点
                PrecachePie(progress: l == .progress ? progress : 0)
                    .fill(Color.white.opacity(phase == .paused ? 0.5 : 1))
                    .frame(width: 20, height: 20)
                    .opacity(l == .progress ? 1 : 0)
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .bold))
                    .opacity(l == .done ? 1 : 0)
                Image(systemName: "exclamationmark")
                    .font(.system(size: 15, weight: .bold))
                    .opacity(l == .error ? 1 : 0)
            }
            .foregroundStyle(.white)
        }
        .frame(width: 32, height: 32)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .easeInOut(duration: 0.4), value: l)
        .animation(.easeInOut(duration: 0.45), value: progress)
        .task(id: phase) {
            guard phase == .preparing, !arrived else { return }
            try? await Task.sleep(nanoseconds: 550_000_000)
            arrived = true
        }
        .accessibilityHidden(true)
    }
}

/// 进度饼：从 12 点钟方向顺时针
struct PrecachePie: Shape {
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let f = min(1, max(0, progress))
        guard f > 0 else { return p }
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2
        p.move(to: c)
        p.addArc(center: c, radius: r, startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * f), clockwise: false)
        p.closeSubpath()
        return p
    }
}
