import SwiftUI

// MARK: - 进度条：细、轻，Cuven 蓝的已播放部分，中性灰的剩余部分，一颗小圆点，左边当前时间、右边总时长
// （书本姿态时竖着走：上面当前时间、下面总时长，从上往下播）
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
    /// 书本：竖着走（从上往下），当前时间在上、总时长在下
    var vertical = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let duration = model.duration
        let at = model.scrub ?? model.position
        let fraction = duration > 0 ? min(1, max(0, at / duration)) : 0
        let dragging = model.scrub != nil
        let layout = vertical ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 14))
        layout {
            Text(duration > 0 ? Self.clock(at) : "--:--")
                .font(.system(size: vertical ? 12 : 13, weight: .medium).monospacedDigit())
                .foregroundStyle(.white)
                .fixedSize()
            GeometryReader { geo in
                let len = vertical ? geo.size.height : geo.size.width
                let knob: CGFloat = dragging ? 22 : 14
                let done = max(3, len * fraction)
                let offset = len * fraction - knob / 2
                ZStack(alignment: vertical ? .top : .leading) {
                    Capsule()
                        .fill(PlayerPalette.track)
                        .frame(width: vertical ? 3 : nil, height: vertical ? nil : 3)
                    Capsule()
                        .fill(PlayerPalette.progress)
                        .frame(width: vertical ? 3 : done, height: vertical ? done : 3)
                    Circle()
                        .fill(Color.white)
                        .frame(width: knob, height: knob)
                        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                        .offset(x: vertical ? 0 : offset, y: vertical ? offset : 0)
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: vertical ? .top : .leading)
                // 播放中的进度在两次更新之间线性补平；拖动时跟手、不加动画
                .animation(dragging || reduceMotion ? nil : .linear(duration: 0.25), value: fraction)
                .animation(.spring(response: 0.25, dampingFraction: 0.85), value: dragging)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            guard duration > 0, len > 0 else { return }
                            if model.scrub == nil { Haptics.selection() }
                            let along = vertical ? v.location.y : v.location.x
                            model.scrub = Double(min(1, max(0, along / len))) * duration
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
                .font(.system(size: vertical ? 12 : 13, weight: .medium).monospacedDigit())
                .foregroundStyle(DSInk.secondary)
                .fixedSize()
        }
        .padding(vertical ? EdgeInsets(top: 16, leading: 0, bottom: 16, trailing: 0)
                          : EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
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
