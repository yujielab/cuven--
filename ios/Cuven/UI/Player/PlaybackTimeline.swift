import SwiftUI

// MARK: - 进度条（参照图第三行）：红色进度、可拖的圆点、当前时间 / 总时长
//
// 拖动时圆点放大（18 → 26 点），时间跟着手指走，松手才跳过去（不在拖的路上一直 seek）；
// 旁白：「播放进度」，值是「已播放 x，共 y」，上下扫动前进 / 后退 10 秒。

enum PlayerPalette {
    /// 参照图的红色进度条
    static let progress = Color(red: 0.898, green: 0.035, blue: 0.078)
    static let track = Color.white.opacity(0.28)
}

struct PlaybackTimeline: View {
    let model: CuvenPlayerViewModel

    var body: some View {
        let duration = model.duration
        let at = model.scrub ?? model.position
        let fraction = duration > 0 ? min(1, max(0, at / duration)) : 0
        let dragging = model.scrub != nil
        HStack(spacing: 20) {
            GeometryReader { geo in
                let w = geo.size.width
                let knob: CGFloat = dragging ? 26 : 18
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(PlayerPalette.track)
                        .frame(height: 4)
                    Capsule()
                        .fill(PlayerPalette.progress)
                        .frame(width: max(4, w * fraction), height: 4)
                    Circle()
                        .fill(PlayerPalette.progress)
                        .frame(width: knob, height: knob)
                        .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                        .offset(x: w * fraction - knob / 2)
                        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: dragging)
                }
                .frame(width: w, height: geo.size.height)
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
            Text(duration > 0 ? "\(Self.clock(at)) / \(Self.clock(duration))" : "--:-- / --:--")
                .font(.system(size: 15, weight: .medium).monospacedDigit())
                .foregroundStyle(.white)
                .fixedSize()
        }
        .padding(.leading, 24)
        .padding(.trailing, 22)
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
