import SwiftUI
import UIKit

// MARK: - 面板最上面那一条：照 MacBook 的 Touch Bar 做（用户要求「可滑动与点击无缝展开设计」）
//
// 一条深色按键，按键的面由 CuvenLighting 用 Metal 画（画面的光映在上面），SwiftUI 画符号、管点按和拖动。几种样子：
//   · 播放那一排（默认）：关闭 | 后退 10 秒、播放 / 暂停、前进 10 秒 | 进度条 | ‹ + 收起的控制条（音量、亮度、锁定，
//     放不下就少几颗）；
//   · 控制条：点「‹」或者在这一条上往左滑 → ⊗ | 字幕、音轨 | 亮度、音量 | 小窗口、全屏、锁定屏幕；⊗ 或往右滑收回；
//   · 亮度 / 音量：点一下，这颗键长成一整条滑杆（⊗ 收起）；按住往左右拖，直接调、松手收回（和 Touch Bar 一样）；
//   · 进度条：在上面拖直接跳（松手才跳过去）；点一下长成整条，拖得更准；
//   · 字幕 / 音轨：长成一排选项，选中的是白底黑字。
// 「无缝」：所有按键在同一个形变组里（渲染器 ReflectiveSurfaceRenderer），换样子时留下来的键用弹簧挪到新位置、
// 长成新的大小，走掉的键融进留下的那些里，新来的从走掉的那片里长出来；符号同时淡入淡出、Magic Replace。
// 锁定屏幕：这一页的方向锁在按下时的方向，转动设备不跟着转（亮起来）；全屏：退出半折的版面回到系统播放器全屏，
// 方向回到原来的规则；小窗口：画中画，播放器收起回到 App。

/// Touch Bar 上的每一颗键
enum TouchBarKey: String, Hashable {
    case close, back, play, forward, scrub, chevron
    case subtitles, audio, brightness, volume, pip, fullscreen, lock
}

struct TouchBarItem: Identifiable, Equatable {
    let id: TouchBarKey
    var width: CGFloat
    /// 左边离上一颗多远（同一组 6 点，组和组之间 14 点）
    var gap: CGFloat
}

enum TouchBarLayout {
    static let gap: CGFloat = 6
    static let groupGap: CGFloat = 14
    static let radius: CGFloat = 14

    /// 按键的标准宽度（按高算）
    static func unit(height h: CGFloat) -> CGFloat { min(70, max(48, (h * 0.95).rounded())) }

    static func items(mode: TouchBarMode, width W: CGFloat, height h: CGFloat) -> [TouchBarItem] {
        let g = gap, G = groupGap
        let chevron: CGFloat = 26
        let minScrub: CGFloat = 130
        // 窄的时候（书本姿态的一页）键收窄一点：播放那一排的进度条至少留 130 点
        let u = max(44, min(unit(height: h), ((W - 3 * G - 2 * g - chevron - minScrub) / 3.85).rounded(.down)))
        let closeWidth = (u * 0.85).rounded()
        func item(_ k: TouchBarKey, _ w: CGFloat, _ gap: CGFloat) -> TouchBarItem {
            TouchBarItem(id: k, width: max(1, w.rounded(.down)), gap: gap)
        }
        switch mode {
        case .media:
            // 关闭 | 三颗 | 进度条（剩下的都给它）| ‹ + 收起的控制条（音量、亮度、锁定；进度条不够 130 点就少放几颗）
            let base = closeWidth + G + (3 * u + 2 * g) + G + G + chevron
            let strip: [TouchBarKey] = [.volume, .brightness, .lock]
            var k = strip.count
            var scrub = W - base - CGFloat(k) * (g + u)
            while k > 0, scrub < minScrub {
                k -= 1
                scrub = W - base - CGFloat(k) * (g + u)
            }
            var out = [item(.close, closeWidth, 0), item(.back, u, G), item(.play, u, g), item(.forward, u, g),
                       item(.scrub, max(96, scrub), G), item(.chevron, chevron, G)]
            for key in strip.prefix(k) { out.append(item(key, u, g)) }
            return out
        case .strip:
            // ⊗ | 字幕、音轨 | 亮度、音量 | 小窗口、全屏、锁定：一样宽，铺满
            let w = max(40, (W - 3 * G - 4 * g) / 8)
            return [item(.close, w, 0),
                    item(.subtitles, w, G), item(.audio, w, g),
                    item(.brightness, w, G), item(.volume, w, g),
                    item(.pip, w, G), item(.fullscreen, w, g), item(.lock, w, g)]
        case .slider(let s):
            return [item(.close, closeWidth, 0), item(s == .brightness ? .brightness : .volume, W - closeWidth - G, G)]
        case .scrub:
            return [item(.close, closeWidth, 0), item(.scrub, W - closeWidth - G, G)]
        case .choices(let c):
            return [item(.close, closeWidth, 0), item(c == .subtitles ? .subtitles : .audio, W - closeWidth - G, G)]
        }
    }
}

struct PlayerTouchBar: View {
    let model: CuvenPlayerViewModel
    let height: CGFloat
    /// 键自己的拖动（进度条、滑杆）进行中：这一条的左右滑不算
    @State private var keyDragging = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let items = TouchBarLayout.items(mode: model.bar, width: geo.size.width, height: height)
            HStack(spacing: 0) {
                ForEach(items) { it in
                    key(it.id, barWidth: geo.size.width)
                        .frame(width: it.width, height: height)
                        .litCard("bar-\(it.id.rawValue)", emphasis: emphasis(it.id),
                                 lit: it.id == .lock && model.orientationLocked,
                                 radius: TouchBarLayout.radius, group: "bar")
                        .padding(.leading, it.gap)
                        .transition(.opacity)
                }
            }
            .frame(width: geo.size.width, height: height, alignment: .leading)
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.42, dampingFraction: 0.86), value: model.bar)
            .contentShape(Rectangle())
            // 往左滑展开控制条，往右滑收回（键自己在拖的时候不算）
            .simultaneousGesture(
                DragGesture(minimumDistance: 24)
                    .onEnded { v in
                        guard !keyDragging, abs(v.translation.width) > abs(v.translation.height) * 1.5 else { return }
                        if v.translation.width < -40, model.bar == .media {
                            model.openBar(.strip)
                        } else if v.translation.width > 40, model.bar == .strip {
                            model.closeBar()
                        }
                    }
            )
        }
        .frame(height: height)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player-touchbar")
    }

    private func emphasis(_ k: TouchBarKey) -> Float {
        switch k {
        case .play: 1
        case .back, .forward: 0.6
        case .scrub: 0.3
        default: 0.4
        }
    }

    @ViewBuilder
    private func key(_ k: TouchBarKey, barWidth: CGFloat) -> some View {
        let bar = model.bar
        switch k {
        case .close:
            Button {
                if bar == .media { model.onClose?() } else { model.closeBar() }
            } label: {
                PlayerIcon(bar == .media ? "xmark" : "xmark.circle.fill", size: bar == .media ? 21 : 24,
                           color: bar == .media ? .white : .white.opacity(0.85))
                    .contentTransition(.symbolEffect(.replace.magic(fallback: .replace)))
            }
            .buttonStyle(LitTileStyle(id: "bar-close", radius: TouchBarLayout.radius))
            .accessibilityLabel(bar == .media ? "关闭" : "收起")
            .accessibilityIdentifier("player-close")
        case .back:
            Button { model.skip(-10) } label: { PlayerIcon("gobackward.10", size: 22, weight: .medium) }
                .buttonStyle(LitTileStyle(id: "bar-back", radius: TouchBarLayout.radius))
                .accessibilityLabel("后退 10 秒")
                .accessibilityIdentifier("player-back")
        case .play:
            Button { model.togglePlay() } label: {
                PlayerIcon(model.playing ? "pause.fill" : "play.fill", size: 24, weight: .bold)
                    .contentTransition(.symbolEffect(.replace.magic(fallback: .replace)))
                    .animation(.spring(response: 0.36, dampingFraction: 0.86), value: model.playing)
            }
            .buttonStyle(LitTileStyle(id: "bar-play", radius: TouchBarLayout.radius))
            .accessibilityLabel(model.playing ? "暂停" : "播放")
            .accessibilityIdentifier("player-play")
        case .forward:
            Button { model.skip(10) } label: { PlayerIcon("goforward.10", size: 22, weight: .medium) }
                .buttonStyle(LitTileStyle(id: "bar-forward", radius: TouchBarLayout.radius))
                .accessibilityLabel("前进 10 秒")
                .accessibilityIdentifier("player-forward")
        case .scrub:
            TouchBarScrubber(model: model, expanded: bar == .scrub) { keyDragging = $0 }
        case .chevron:
            Button { model.openBar(.strip) } label: { PlayerIcon("chevron.left", size: 17, weight: .semibold) }
                .buttonStyle(LitTileStyle(id: "bar-chevron", radius: TouchBarLayout.radius))
                .accessibilityLabel("更多控制")
                .accessibilityHint("展开字幕、音轨、亮度、音量、小窗口、全屏和锁定")
                .accessibilityIdentifier("player-more")
        case .subtitles:
            if bar == .choices(.subtitles) {
                TouchBarChoices(model: model, kind: .subtitles)
            } else {
                Button { model.openBar(.choices(.subtitles)) } label: { PlayerIcon("captions.bubble", size: 21) }
                    .buttonStyle(LitTileStyle(id: "bar-subtitles", radius: TouchBarLayout.radius))
                    .accessibilityLabel("字幕")
                    .accessibilityIdentifier("player-subtitles")
            }
        case .audio:
            if bar == .choices(.audio) {
                TouchBarChoices(model: model, kind: .audio)
            } else {
                Button { model.openBar(.choices(.audio)) } label: { PlayerIcon("waveform", size: 21) }
                    .buttonStyle(LitTileStyle(id: "bar-audio", radius: TouchBarLayout.radius))
                    .accessibilityLabel("音轨")
                    .accessibilityIdentifier("player-audio")
            }
        case .brightness:
            TouchBarLevel(model: model, kind: .brightness, barWidth: barWidth) { keyDragging = $0 }
        case .volume:
            TouchBarLevel(model: model, kind: .volume, barWidth: barWidth) { keyDragging = $0 }
        case .pip:
            Button { model.startPiP() } label: {
                PlayerIcon("pip.enter", size: 21, color: model.pipPossible ? .white : .white.opacity(0.35))
            }
            .buttonStyle(LitTileStyle(id: "bar-pip", radius: TouchBarLayout.radius))
            .disabled(!model.pipPossible)
            .accessibilityLabel("小窗口")
            .accessibilityHint("画中画，回到主屏幕接着看")
            .accessibilityIdentifier("player-pip")
        case .fullscreen:
            Button {
                Haptics.light()
                model.goFullscreen()
            } label: {
                PlayerIcon("arrow.up.left.and.arrow.down.right", size: 20,
                           color: model.fold != nil ? .white : .white.opacity(0.35))
            }
            .buttonStyle(LitTileStyle(id: "bar-fullscreen", radius: TouchBarLayout.radius))
            .disabled(model.fold == nil)
            .accessibilityLabel("全屏")
            .accessibilityHint("退出半折的版面，回到全屏播放")
            .accessibilityIdentifier("player-fullscreen")
        case .lock:
            Button { model.toggleOrientationLock() } label: {
                PlayerIcon(model.orientationLocked ? "lock.rotation" : "lock.rotation.open", size: 21, weight: .medium,
                           color: model.orientationLocked ? .black : .white)
                    .contentTransition(.symbolEffect(.replace.magic(fallback: .replace)))
                    .animation(.spring(response: 0.36, dampingFraction: 0.86), value: model.orientationLocked)
            }
            .buttonStyle(LitTileStyle(id: "bar-lock", lit: model.orientationLocked, radius: TouchBarLayout.radius))
            .accessibilityLabel(model.orientationLocked ? "解锁屏幕方向" : "锁定屏幕方向")
            .accessibilityIdentifier("player-lock")
        }
    }
}

// MARK: 进度条

/// 收起时是一小段（当前时间 · 进度 · 总时长），展开成整条（时间大一点、显示剩余）。拖着走、松手才跳过去；
/// 收起时点一下展开，展开时点哪儿跳到哪儿
private struct TouchBarScrubber: View {
    let model: CuvenPlayerViewModel
    let expanded: Bool
    let onDragging: (Bool) -> Void
    @State private var track: CGRect = .zero
    @State private var started = false
    @State private var moved = false
    @Environment(\.lightingHost) private var host
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let duration = model.duration
        let at = model.scrub ?? model.position
        let fraction = duration > 0 ? min(1, max(0, at / duration)) : 0
        let dragging = model.scrub != nil
        HStack(spacing: expanded ? 16 : 10) {
            Text(duration > 0 ? Format.clock(at) : "--:--")
                .font(.system(size: expanded ? 15 : 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.white)
                .fixedSize()
            GeometryReader { geo in
                let w = geo.size.width
                let knob: CGFloat = dragging ? 20 : (expanded ? 14 : 10)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.24)).frame(height: expanded ? 5 : 3)
                    Capsule().fill(PlayerPalette.progress).frame(width: max(3, w * fraction), height: expanded ? 5 : 3)
                    Circle()
                        .fill(Color.white)
                        .frame(width: knob, height: knob)
                        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                        .offset(x: w * fraction - knob / 2)
                }
                .frame(width: w, height: geo.size.height)
                .animation(dragging || reduceMotion ? nil : .linear(duration: 0.25), value: fraction)
                .animation(.spring(response: 0.25, dampingFraction: 0.85), value: dragging)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("touchbar-scrub")) } action: { track = $0 }
            }
            Text(duration > 0 ? (expanded ? "-" + Format.clock(max(0, duration - at)) : Format.clock(duration)) : "--:--")
                .font(.system(size: expanded ? 15 : 12, weight: .medium).monospacedDigit())
                .foregroundStyle(DSInk.secondary)
                .fixedSize()
        }
        .padding(.horizontal, expanded ? 20 : 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .coordinateSpace(.named("touchbar-scrub"))
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    if !started {
                        started = true
                        moved = false
                        onDragging(true)
                        host?.setPressed(true, id: "bar-scrub")
                    }
                    if abs(v.translation.width) > 4 { moved = true }
                    guard moved, duration > 0, track.width > 1 else { return }
                    if model.scrub == nil { Haptics.selection() }
                    let f = min(1, max(0, (v.location.x - track.minX) / track.width))
                    model.scrub = Double(f) * duration
                    model.poke()
                }
                .onEnded { v in
                    host?.setPressed(false, id: "bar-scrub")
                    if moved {
                        if let s = model.scrub { model.seek(to: s) }
                    } else if expanded, duration > 0, track.width > 1 {
                        let f = min(1, max(0, (v.location.x - track.minX) / track.width))
                        model.seek(to: Double(f) * duration)
                    } else if !expanded {
                        model.openBar(.scrub)
                    }
                    model.scrub = nil
                    model.poke()
                    started = false
                    moved = false
                    // 让这一条的「左右滑」先看到「键在拖」，下一轮再放开
                    DispatchQueue.main.async { onDragging(false) }
                }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("播放进度")
        .accessibilityValue(duration > 0 ? "已播放 \(PlaybackClock.spoken(at))，共 \(PlaybackClock.spoken(duration))" : "")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: model.skip(10)
            case .decrement: model.skip(-10)
            @unknown default: break
            }
        }
        .accessibilityIdentifier("player-timeline")
    }
}

// MARK: 亮度 / 音量

/// 收起时是一颗键（符号随大小变）；点一下长成整条滑杆，按住左右拖直接调、松手收回
private struct TouchBarLevel: View {
    let model: CuvenPlayerViewModel
    let kind: TouchBarMode.Slider
    let barWidth: CGFloat
    let onDragging: (Bool) -> Void
    @State private var start: Double?
    @State private var startedExpanded = false
    @State private var slid = false
    @State private var track: CGRect = .zero
    @Environment(\.lightingHost) private var host

    private var expanded: Bool { model.bar == .slider(kind) }
    private var value: Double { kind == .brightness ? model.brightness : model.volume }
    private var cardID: String { kind == .brightness ? "bar-brightness" : "bar-volume" }
    private var symbol: String { kind == .brightness ? "sun.max.fill" : "speaker.wave.3.fill" }

    private func set(_ v: Double) {
        if kind == .brightness { model.setBrightness(v) } else { model.setVolume(v) }
    }

    var body: some View {
        ZStack {
            if expanded {
                HStack(spacing: 14) {
                    Image(systemName: symbol, variableValue: value)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 30)
                    GeometryReader { geo in
                        let w = geo.size.width
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.22)).frame(height: 6)
                            Capsule().fill(Color.white).frame(width: max(6, w * value), height: 6)
                            Circle()
                                .fill(Color.white)
                                .frame(width: 22, height: 22)
                                .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                                .offset(x: w * value - 11)
                        }
                        .frame(width: w, height: geo.size.height)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("touchbar-level")) } action: { track = $0 }
                    }
                    Text("\(Int((value * 100).rounded()))")
                        .font(.system(size: 14, weight: .semibold).monospacedDigit())
                        .foregroundStyle(DSInk.secondary)
                        .frame(width: 34, alignment: .trailing)
                }
                .padding(.horizontal, 18)
                .transition(.opacity)
            } else {
                Image(systemName: symbol, variableValue: value)
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(.white)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .coordinateSpace(.named("touchbar-level"))
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    if start == nil {
                        start = value
                        startedExpanded = expanded
                        slid = false
                        onDragging(true)
                        host?.setPressed(true, id: cardID)
                    }
                    if startedExpanded {
                        // 展开着：手指在哪儿就是多少
                        guard track.width > 1 else { return }
                        set(Double((v.location.x - track.minX) / track.width))
                    } else if slid || abs(v.translation.width) > 6 {
                        // 收起的键上按住拖：长成滑杆、跟着手指的移动调（松手收回）
                        if !slid {
                            slid = true
                            model.openBar(.slider(kind))
                        }
                        set((start ?? value) + Double(v.translation.width / max(barWidth * 0.7, 1)))
                    }
                    model.poke()
                }
                .onEnded { v in
                    host?.setPressed(false, id: cardID)
                    if startedExpanded {
                        if track.width > 1 { set(Double((v.location.x - track.minX) / track.width)) }
                    } else if slid {
                        model.closeBar()
                    } else {
                        model.openBar(.slider(kind))
                    }
                    start = nil
                    slid = false
                    model.poke()
                    DispatchQueue.main.async { onDragging(false) }
                }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(kind == .brightness ? "亮度" : "音量")
        .accessibilityValue("\(Int((value * 100).rounded()))%")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: set(value + 0.1)
            case .decrement: set(value - 0.1)
            @unknown default: break
            }
        }
        .accessibilityAction(named: expanded ? "收起" : "展开滑杆") {
            if expanded { model.closeBar() } else { model.openBar(.slider(kind)) }
        }
        .accessibilityIdentifier(kind == .brightness ? "player-brightness" : "player-volume")
    }
}

// MARK: 字幕 / 音轨的选项

/// 一排选项（参照 Touch Bar 的输入建议那一组）：选中的是白底黑字；多了可以左右滑
private struct TouchBarChoices: View {
    let model: CuvenPlayerViewModel
    let kind: TouchBarMode.Choice

    var body: some View {
        let names = kind == .subtitles ? ["关"] + model.subtitleNames : model.audioNames
        let picked = kind == .subtitles ? model.subtitlePick + 1 : model.audioPick
        HStack(spacing: 12) {
            Image(systemName: kind == .subtitles ? "captions.bubble.fill" : "waveform")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .padding(.leading, 16)
                .accessibilityHidden(true)
            if names.isEmpty {
                Text(kind == .subtitles ? "这一集没有字幕" : "这一集只有一条音轨")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(DSInk.secondary)
                Spacer(minLength: 0)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(names.indices, id: \.self) { i in
                            let on = i == picked
                            Button {
                                Haptics.selection()
                                if kind == .subtitles { model.selectSubtitle(i - 1) } else { model.selectAudio(i) }
                                model.poke()
                            } label: {
                                Text(names[i])
                                    .font(.system(size: 16, weight: on ? .semibold : .medium))
                                    .foregroundStyle(on ? Color.black : Color.white)
                                    .lineLimit(1)
                                    .padding(.horizontal, 16)
                                    .frame(maxHeight: .infinity)
                                    .background {
                                        Capsule().fill(on ? Color.white : Color.white.opacity(0.1))
                                    }
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(PressableStyle(scale: 0.95))
                            .padding(.vertical, 9)
                            .accessibilityAddTraits(on ? .isSelected : [])
                        }
                    }
                    .padding(.trailing, 10)
                    .animation(.spring(response: 0.3, dampingFraction: 0.86), value: picked)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(kind == .subtitles ? "字幕" : "音轨")
        .accessibilityIdentifier(kind == .subtitles ? "player-subtitle-choices" : "player-audio-choices")
    }
}

/// Cuven 的小字标（和登录页、加载画面同一套：圆体，「Cuven」中等粗、「max」特粗而大）
struct CuvenBrandMark: View {
    var body: some View {
        VStack(spacing: -3) {
            Text("Cuven")
                .font(.system(size: 9, weight: .medium, design: .rounded))
            Text("max")
                .font(.system(size: 16, weight: .heavy, design: .rounded))
                .tracking(-0.7)
        }
        .foregroundStyle(.white)
        .fixedSize()
        .accessibilityHidden(true)
    }
}
