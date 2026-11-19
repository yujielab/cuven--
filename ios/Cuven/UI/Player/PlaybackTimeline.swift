import SwiftUI

// MARK: - 进度条：细、轻，Cuven 蓝的已播放部分，中性灰的剩余部分，一颗小圆点，左边当前时间、右边总时长
//
// 播放时进度每 0.25 秒更新一次，中间用线性动画补平，看起来是连续走的；拖动时圆点从 14 点放大到 22 点，
// 时间跟着手指走，松手才跳过去（不在拖的路上一直 seek）。整条只占一行，点按区是整行的高度。
// 旁白：「播放进度」，值是「已播放 x，共 y」，上下扫动前进 / 后退 10 秒。

enum PlayerPalette {
    /// 已播放：Cuven 的蓝（Theme.accent）
    static let progress = Theme.accent
    static let track = Color.white.opacity(0.24)
}

struct PlaybackTimeline: View {
    let model: CuvenPlayerViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let duration = model.duration
        let at = model.scrub ?? model.position
        let fraction = duration > 0 ? min(1, max(0, at / duration)) : 0
        let dragging = model.scrub != nil
        HStack(spacing: 14) {
            Text(duration > 0 ? Self.clock(at) : "--:--")
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(.white)
                .fixedSize()
            GeometryReader { geo in
                let w = geo.size.width
                let knob: CGFloat = dragging ? 22 : 14
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(PlayerPalette.track)
                        .frame(height: 3)
                    Capsule()
                        .fill(PlayerPalette.progress)
                        .frame(width: max(3, w * fraction), height: 3)
                    Circle()
                        .fill(Color.white)
                        .frame(width: knob, height: knob)
                        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                        .offset(x: w * fraction - knob / 2)
                }
                .frame(width: w, height: geo.size.height)
                // 播放中的进度在两次更新之间线性补平；拖动时跟手、不加动画
                .animation(dragging || reduceMotion ? nil : .linear(duration: 0.25), value: fraction)
                .animation(.spring(response: 0.25, dampingFraction: 0.85), value: dragging)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            guard duration > 0, w > 0 else { return }
                            if model.scrub == nil { Haptics.selection() }
                            model.scrub = Double(min(1, max(0, v.location.x / w))) * duration
                            model.poke()
                        }
                        .onEnded { _ in
                            if let s = model.scrub { model.seek(to: s) }
                            model.scrub = nil
                            model.poke()
                        }
                )
            }
            Text(duration > 0 ? Self.clock(duration) : "--:--")
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(DSInk.secondary)
                .fixedSize()
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("播放进度")
        .accessibilityValue(duration > 0 ? "已播放 \(Self.spoken(at))，共 \(Self.spoken(duration))" : "")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: model.skip(10)
            case .decrement: model.skip(-10)
            @unknown default: break
            }
        }
        .accessibilityIdentifier("player-timeline")
    }

    static func clock(_ s: Double) -> String {
        let t = Int(max(0, s).rounded(.down))
        let h = t / 3600, m = t / 60 % 60, sec = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    static func spoken(_ s: Double) -> String {
        let t = Int(max(0, s).rounded(.down))
        let h = t / 3600, m = t / 60 % 60, sec = t % 60
        return (h > 0 ? "\(h) 小时 " : "") + "\(m) 分 \(sec) 秒"
    }
}
