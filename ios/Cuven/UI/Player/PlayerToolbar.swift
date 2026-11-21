import CuvenLighting
import SwiftUI
import UIKit

// MARK: - 面板最上面那一条：液态玻璃的 Touch Bar（照用户的设计图）
//
// 一排液态玻璃胶囊，左右滑动（这一条比屏宽，两头的胶囊伸出屏外；一开始让中间那颗播放的大胶囊居中）：
//   锁定（圆）| 全屏 | 亮度 | 声音 | 后退 · 播放 / 暂停 · 前进（一颗大胶囊，上面一条可以拖的进度条）| 字幕 | 音轨 | 光效（宽）
// 交互（用户要求）：点按 → 形变 → 点按或滑动选择 → 还原。只用点按展开，不再长按滑动展开（用户要求）。
//   · 点一下亮度 / 声音：这颗胶囊长成一条滑杆；再点滑杆上的某一处（或按住拖）就调到那儿，手指抬起来收回；
//   · 点一下字幕 / 音轨 / 光效：长成一排选项（字幕：关 + 各条字幕；音轨：各条音轨；光效：标准 / 影院 / 沉浸），
//     点某个选项（或按住滑过去，白色的高亮跟着走）就选它，手指抬起来收回；
//   · 形变时这颗按需要长宽（最多是看得见的宽度的 80%），把别的胶囊推开、调暗，整条挪到让它居中；收回时都回去。
// 声音展开时点左边的喇叭是静音 / 取消静音。点别处（面板空的地方、调暗的胶囊）、再点一下同一颗，或者 4 秒没动：不改，收回。
// 一颗胶囊只挂一个手势（pillGesture）。以前是「长按序列 + 点按」和「点开以后的拖」两个手势、靠 GestureMask 切换，
// 外面那个的 .none 连里面那个也关了（GestureMask.none 关的是整棵子视图上的手势），结果点按也展不开。
// 锁定 = 这一页的方向锁在现在的方向（亮起来）；全屏 = 退出半折回到系统播放器全屏、方向回到原来的规则。
// 光影只有这三种模式能换，参数是固定的（CinematicReflectionMode）。
// 进度条：在那条线上按住拖，松手才跳过去。

/// Touch Bar 上的每一颗
enum TouchBarKey: String, Hashable, CaseIterable {
    case lock, fullscreen, brightness, volume, transport, subtitles, audio, effects

    var morphs: Bool {
        switch self {
        case .brightness, .volume, .subtitles, .audio, .effects: true
        default: false
        }
    }
}

/// 一排胶囊在「内容坐标」里的位置（x 从第一颗的左边算起）
struct TouchBarGeometry {
    static let order: [TouchBarKey] = [.lock, .fullscreen, .brightness, .volume, .transport, .subtitles, .audio, .effects]
    static let gap: CGFloat = 8

    private(set) var frames: [TouchBarKey: CGRect] = [:]
    private(set) var contentWidth: CGFloat = 0

    init(height h: CGFloat, morph: TouchBarKey?, morphWidth: CGFloat) {
        var x: CGFloat = 0
        for k in Self.order {
            let w = k == morph ? morphWidth : Self.restWidth(k, height: h)
            frames[k] = CGRect(x: x, y: 0, width: w, height: h)
            x += w + Self.gap
        }
        contentWidth = x - Self.gap
    }

    static func restWidth(_ k: TouchBarKey, height h: CGFloat) -> CGFloat {
        switch k {
        case .lock: h
        case .transport: (h * 4.4).rounded()
        case .effects: (h * 2.2).rounded()
        default: (h * 1.35).rounded()
        }
    }

    /// 一排选项要多宽（按字估：汉字一个字号宽，别的 0.58 个），最多看得见的宽度的 80%
    static func optionsWidth(_ labels: [String], height h: CGFloat, visible W: CGFloat) -> CGFloat {
        let widths = labels.map { max(54, textWidth($0) + 28) }
        let total = 48 + widths.reduce(0, +) + CGFloat(max(0, labels.count - 1)) * 4 + 8
        return min(W * 0.8, max(h * 2.6, total))
    }

    static func textWidth(_ s: String, size: CGFloat = 15) -> CGFloat {
        s.unicodeScalars.reduce(0) { $0 + ($1.value >= 0x2E80 ? size : size * 0.58) }
    }
}

struct PlayerTouchBar: View {
    let model: CuvenPlayerViewModel
    /// 胶囊的高
    let pillHeight: CGFloat
    /// 左右的边距（这一条铺满面板的宽，滑到头时第一颗 / 最后一颗停在边距上）
    var insets = EdgeInsets()

    @State private var settings = CinematicLightingSettings.shared
    /// 停着时整条的位置（nil：还没动过，让播放那颗居中）
    @State private var offset: CGFloat?
    @State private var dragBase: CGFloat = 0
    @State private var dragging = false
    @State private var dragIgnored = false
    /// 正展开着的那一颗
    @State private var morph: TouchBarKey?
    @State private var startValue: Double = 0
    @State private var startIndex = 0
    @State private var pick = 0
    /// 点开着（等着点或滑来选）
    @State private var sticky = false
    /// 点开以后多久没动就收回（每动一下重新算）
    @State private var stickyToken = 0
    /// 点开以后这一下是按在左边的符号上（声音：静音）
    @State private var stickyTouch = false
    @State private var iconPress = false
    @State private var scrubbing = false
    @State private var track: CGRect = .zero
    @GestureState private var pressed: TouchBarKey?
    @Namespace private var pickSpace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 胶囊上面进度条那一条的高
    static let progressZone: CGFloat = 22
    static func height(pill: CGFloat) -> CGFloat { progressZone + 6 + pill }

    private var spring: Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.38, dampingFraction: 0.86)
    }

    var body: some View {
        GeometryReader { geo in
            let W = geo.size.width
            let h = pillHeight
            let rest = TouchBarGeometry(height: h, morph: nil, morphWidth: 0)
            let lay = TouchBarGeometry(height: h, morph: morph, morphWidth: morph.map { morphWidth($0, visible: W) } ?? 0)
            let restOffset = clamp(offset ?? centered(rest, W), content: rest.contentWidth, W)
            // 展开时整条挪到让那一颗居中；收回时回到原来停的地方
            let shown = morph.flatMap { lay.frames[$0] }.map { clamp(W / 2 - $0.midX, content: lay.contentWidth, W) } ?? restOffset
            let top = Self.progressZone + 6
            ZStack(alignment: .topLeading) {
                // 点开着时点这一条上空的地方、调暗的胶囊：不改，收回
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { if sticky { cancel() } }
                if let t = lay.frames[.transport] {
                    progressLine
                        .frame(width: t.width, height: Self.progressZone)
                        .offset(x: t.minX + shown)
                        .opacity(morph == nil ? 1 : 0.3)
                }
                GlassEffectContainer(spacing: 6) {
                    ZStack(alignment: .topLeading) {
                        ForEach(TouchBarGeometry.order, id: \.self) { k in
                            let f = lay.frames[k] ?? .zero
                            pill(k, visible: W, frame: CGRect(x: f.minX + shown, y: top, width: f.width, height: h))
                                .frame(width: f.width, height: h)
                                .glassEffect(glass(k), in: Capsule())
                                .scaleEffect(pressed == k && morph == nil && !reduceMotion ? 0.95 : 1)
                                .offset(x: f.minX + shown, y: top)
                                .opacity(morph != nil && morph != k ? 0.3 : 1)
                                // 展开着时调暗的那些不接点按：点上去只是收回（下面那层接）
                                .allowsHitTesting(morph == nil || morph == k)
                        }
                    }
                }
            }
            .frame(width: W, height: Self.height(pill: h), alignment: .topLeading)
            .coordinateSpace(.named("touchbar"))
            .animation(spring, value: morph)
            .animation(.spring(response: 0.26, dampingFraction: 0.82), value: pressed)
            .contentShape(Rectangle())
            // 左右滑：整条跟着手指走，松手按惯性停下（展开着、拖进度条时不算）
            .simultaneousGesture(
                DragGesture(minimumDistance: 10)
                    .onChanged { v in
                        if !dragging {
                            dragging = true
                            dragBase = restOffset
                            dragIgnored = morph != nil || scrubbing
                        }
                        if morph != nil || scrubbing { dragIgnored = true }
                        guard !dragIgnored else { return }
                        offset = rubberBand(dragBase + v.translation.width, content: rest.contentWidth, W)
                    }
                    .onEnded { v in
                        defer {
                            dragging = false
                            dragIgnored = false
                        }
                        guard !dragIgnored else { return }
                        let target = clamp(dragBase + v.predictedEndTranslation.width, content: rest.contentWidth, W)
                        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.5, dampingFraction: 0.9)) {
                            offset = target
                        }
                        model.poke()
                    }
            )
            // 面板上空的地方点了一下：点开的收回
            .onChange(of: model.barCollapseRequest) { _, _ in if sticky { cancel() } }
        }
        .frame(height: Self.height(pill: pillHeight))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player-touchbar")
    }

    // MARK: 位置

    private func centered(_ g: TouchBarGeometry, _ W: CGFloat) -> CGFloat {
        guard let t = g.frames[.transport] else { return insets.leading }
        return W / 2 - t.midX
    }

    /// 停的位置：放得下就整条居中；放不下时第一颗最多停在左边距、最后一颗最多停在右边距
    private func clamp(_ o: CGFloat, content: CGFloat, _ W: CGFloat) -> CGFloat {
        let avail = W - insets.leading - insets.trailing
        if content <= avail { return insets.leading + (avail - content) / 2 }
        return min(insets.leading, max(W - insets.trailing - content, o))
    }

    /// 拖过头时有阻力
    private func rubberBand(_ o: CGFloat, content: CGFloat, _ W: CGFloat) -> CGFloat {
        let c = clamp(o, content: content, W)
        return c + (o - c) * 0.35
    }

    // MARK: 形变

    private func morphWidth(_ k: TouchBarKey, visible W: CGFloat) -> CGFloat {
        switch k {
        case .brightness, .volume: (W * 0.8).rounded()
        case .subtitles, .audio, .effects: TouchBarGeometry.optionsWidth(labels(k), height: pillHeight, visible: W).rounded()
        default: TouchBarGeometry.restWidth(k, height: pillHeight)
        }
    }

    private func labels(_ k: TouchBarKey) -> [String] {
        switch k {
        case .subtitles: ["关"] + model.subtitleNames
        case .audio: model.audioNames.isEmpty ? ["默认"] : model.audioNames
        case .effects: LightingPreset.allCases.map(\.title)
        default: []
        }
    }

    private func currentIndex(_ k: TouchBarKey) -> Int {
        switch k {
        case .subtitles: model.subtitlePick + 1
        case .audio: max(0, model.audioPick)
        case .effects: LightingPreset.allCases.firstIndex(of: settings.mode.preset) ?? 1
        default: 0
        }
    }

    private func begin(_ k: TouchBarKey, sticky open: Bool = false) {
        if let m = morph, m != k { end(commit: !sticky) }
        sticky = open
        guard morph != k else { return }
        Haptics.light()
        model.setBarMorph(k)
        switch k {
        case .brightness: startValue = model.brightness
        case .volume: startValue = model.volume
        default:
            startIndex = currentIndex(k)
            pick = startIndex
        }
        morph = k
    }

    /// 松开：选项按高亮的那一个选上；收回（commit 为假：不改，直接收回）
    private func end(commit: Bool = true) {
        guard let k = morph else { return }
        if commit, pick != startIndex {
            switch k {
            case .subtitles: model.selectSubtitle(pick - 1)
            case .audio: if model.audioNames.indices.contains(pick) { model.selectAudio(pick) }
            case .effects: settings.setPreset(LightingPreset.allCases[pick])
            default: break
            }
        }
        sticky = false
        stickyTouch = false
        iconPress = false
        morph = nil
        model.setBarMorph(nil)
    }

    private func cancel() { end(commit: false) }

    /// 点一下：展开着不收，等着点或滑来选（4 秒没动就收回）
    private func openSticky(_ k: TouchBarKey) {
        if morph == k, sticky { cancel(); return }
        begin(k, sticky: true)
        armAutoCollapse()
    }

    private func armAutoCollapse() {
        stickyToken += 1
        let token = stickyToken
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            if sticky, stickyToken == token, !stickyTouch { cancel() }
        }
    }

    /// 一颗胶囊的手势（只有这一个，不靠 GestureMask 切换）：
    /// · 没展开：手指没怎么动就抬起来 = 点了一下 → 展开（等着点或滑来选）；滑远了是在左右滑整条，不管
    /// · 展开着：点哪儿 / 滑到哪儿就是哪儿（按手指在展开的那一颗上的位置），抬起来就选上、收回
    /// frame：这一颗在这一条（"touchbar"）里的位置
    private func pillGesture(_ k: TouchBarKey, frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("touchbar"))
            .updating($pressed) { v, state, _ in
                // 按下去略缩一下（展开着的那一颗不缩）；滑远了就不算按着它
                if hypot(v.translation.width, v.translation.height) < 10 { state = k }
            }
            .onChanged { v in
                guard morph == k, sticky else { return }
                if !stickyTouch {
                    stickyTouch = true
                    iconPress = v.startLocation.x - frame.minX < iconZone(k)
                }
                let moved = hypot(v.translation.width, v.translation.height) > 6
                if iconPress, !moved { return }
                iconPress = false
                follow(k, x: v.location.x, frame: frame)
                model.poke()
            }
            .onEnded { v in
                let moved = hypot(v.translation.width, v.translation.height) > 6
                guard morph == k, sticky, stickyTouch else {
                    // 没展开：点了一下就展开；滑远了是在左右滑整条
                    if hypot(v.translation.width, v.translation.height) < 10 { openSticky(k) }
                    return
                }
                if iconPress, !moved {
                    // 按在左边的符号上：声音是静音 / 取消静音，别的是不改、收回
                    if k == .volume { model.toggleMute() }
                    cancel()
                    return
                }
                follow(k, x: v.location.x, frame: frame)
                end()
            }
    }

    /// 左边那个符号占多宽（点它不算选）
    private func iconZone(_ k: TouchBarKey) -> CGFloat {
        k == .brightness || k == .volume ? 50 : 46
    }

    /// 手指在展开的那一颗上的位置 → 滑杆的大小 / 高亮的选项
    private func follow(_ k: TouchBarKey, x: CGFloat, frame: CGRect) {
        switch k {
        case .brightness, .volume:
            // 滑杆从左边 56 点起、到右边 62 点止（见 level）
            let v = Double((x - frame.minX - 56) / max(frame.width - 118, 1))
            if k == .brightness { model.setBrightness(v) } else { model.setVolume(v) }
        default:
            // 选项从左边 48 点起，一样宽、隔 4 点，右边留 6 点（见 options）
            let n = labels(k).count
            guard n > 0 else { return }
            let segment = max(1, (frame.width - 48 - 6 - 4 * CGFloat(n - 1)) / CGFloat(n))
            let rel = x - frame.minX - 48
            let i = min(n - 1, max(0, Int(rel / (segment + 4))))
            if i != pick {
                Haptics.selection()
                pick = i
            }
        }
    }

    // MARK: 胶囊

    private func glass(_ k: TouchBarKey) -> Glass {
        if k == .lock, model.orientationLocked { return .regular.tint(.white.opacity(0.85)).interactive() }
        return .regular.interactive()
    }

    @ViewBuilder
    private func pill(_ k: TouchBarKey, visible W: CGFloat, frame: CGRect) -> some View {
        switch k {
        case .lock:
            Button { model.toggleOrientationLock() } label: {
                PlayerIcon(model.orientationLocked ? "lock.rotation" : "lock.rotation.open", size: 19, weight: .medium,
                           color: model.orientationLocked ? .black : .white)
                    .contentTransition(.symbolEffect(.replace.magic(fallback: .replace)))
            }
            .buttonStyle(PressableStyle(scale: 0.9))
            .accessibilityLabel(model.orientationLocked ? "解锁屏幕方向" : "锁定屏幕方向")
            .accessibilityIdentifier("player-lock")
        case .fullscreen:
            Button {
                Haptics.light()
                model.goFullscreen()
            } label: {
                PlayerIcon("arrow.up.left.and.arrow.down.right", size: 19,
                           color: model.fold != nil ? .white : .white.opacity(0.35))
            }
            .buttonStyle(PressableStyle(scale: 0.9))
            .disabled(model.fold == nil)
            .accessibilityLabel("全屏")
            .accessibilityHint("退出半折的版面，回到全屏播放")
            .accessibilityIdentifier("player-fullscreen")
        case .transport:
            transport
        case .brightness, .volume:
            level(k)
                .contentShape(Capsule())
                .gesture(pillGesture(k, frame: frame))
        case .subtitles, .audio, .effects:
            options(k)
                .contentShape(Capsule())
                .gesture(pillGesture(k, frame: frame))
        }
    }

    /// 后退 · 播放 / 暂停 · 前进
    private var transport: some View {
        HStack(spacing: 0) {
            Button { model.skip(-10) } label: { PlayerIcon("gobackward.10", size: 21, weight: .medium) }
                .buttonStyle(PressableStyle(scale: 0.88))
                .accessibilityLabel("后退 10 秒")
                .accessibilityIdentifier("player-back")
            Button { model.togglePlay() } label: {
                ZStack {
                    Circle().strokeBorder(.white.opacity(0.55), lineWidth: 1.5)
                        .frame(width: pillHeight * 0.74, height: pillHeight * 0.74)
                    Image(systemName: model.playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(.white)
                        .contentTransition(.symbolEffect(.replace.magic(fallback: .replace)))
                        .animation(.spring(response: 0.36, dampingFraction: 0.86), value: model.playing)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle(scale: 0.9))
            .accessibilityLabel(model.playing ? "暂停" : "播放")
            .accessibilityIdentifier("player-play")
            Button { model.skip(10) } label: { PlayerIcon("goforward.10", size: 21, weight: .medium) }
                .buttonStyle(PressableStyle(scale: 0.88))
                .accessibilityLabel("前进 10 秒")
                .accessibilityIdentifier("player-forward")
        }
        .padding(.horizontal, 6)
    }

    /// 播放那颗胶囊上面的进度条：按住拖，松手才跳过去
    private var progressLine: some View {
        let duration = model.duration
        let at = model.scrub ?? model.position
        let fraction = duration > 0 ? min(1, max(0, at / duration)) : 0
        let dragging = model.scrub != nil
        return HStack(spacing: 8) {
            Text(duration > 0 ? Format.clock(at) : "--:--")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.9))
                .fixedSize()
            GeometryReader { g in
                let w = g.size.width
                let knob: CGFloat = dragging ? 16 : 9
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.25)).frame(height: 3)
                    Capsule().fill(PlayerPalette.progress).frame(width: max(3, w * fraction), height: 3)
                    Circle()
                        .fill(Color.white)
                        .frame(width: knob, height: knob)
                        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                        .offset(x: w * fraction - knob / 2)
                }
                .frame(width: w, height: g.size.height)
                .animation(dragging || reduceMotion ? nil : .linear(duration: 0.25), value: fraction)
                .animation(.spring(response: 0.25, dampingFraction: 0.85), value: dragging)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("touchbar")) } action: { track = $0 }
            }
            Text(duration > 0 ? Format.clock(duration) : "--:--")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(DSInk.secondary)
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("touchbar"))
                .onChanged { v in
                    scrubbing = true
                    guard duration > 0, track.width > 1 else { return }
                    if model.scrub == nil { Haptics.selection() }
                    let f = min(1, max(0, (v.location.x - track.minX) / track.width))
                    model.scrub = Double(f) * duration
                    model.poke()
                }
                .onEnded { _ in
                    if let s = model.scrub { model.seek(to: s) }
                    model.scrub = nil
                    model.poke()
                    DispatchQueue.main.async { scrubbing = false }
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

    /// 亮度 / 声音：收起时一个符号（随大小变），展开成一条滑杆
    private func level(_ k: TouchBarKey) -> some View {
        let isBrightness = k == .brightness
        let value = isBrightness ? model.brightness : model.volume
        let symbol = isBrightness ? "sun.max.fill" : (model.muted ? "speaker.slash.fill" : "speaker.wave.3.fill")
        let expanded = morph == k
        return ZStack {
            if expanded {
                HStack(spacing: 12) {
                    Image(systemName: symbol, variableValue: value)
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 26)
                    GeometryReader { g in
                        let w = g.size.width
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.22)).frame(height: 6)
                            Capsule().fill(Color.white).frame(width: max(6, w * value), height: 6)
                        }
                        .frame(width: w, height: g.size.height)
                    }
                    Text("\(Int((value * 100).rounded()))")
                        .font(.system(size: 14, weight: .semibold).monospacedDigit())
                        .foregroundStyle(DSInk.secondary)
                        .frame(width: 32, alignment: .trailing)
                }
                .padding(.horizontal, 18)
                .transition(.opacity)
            } else {
                Image(systemName: symbol, variableValue: value)
                    .font(.system(size: 19, weight: .regular))
                    .contentTransition(.symbolEffect(.replace.magic(fallback: .replace)))
                    .transition(.opacity)
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isBrightness ? "亮度" : (model.muted ? "声音，已静音" : "声音"))
        .accessibilityValue("\(Int((value * 100).rounded()))%")
        .accessibilityHint(isBrightness ? "点按展开，再点按或滑动调整" : "点按展开，再点按或滑动调整音量")
        .accessibilityAdjustableAction { direction in
            let d = direction == .increment ? 0.1 : -0.1
            if isBrightness { model.setBrightness(value + d) } else { model.setVolume(value + d) }
        }
        .accessibilityAction { openSticky(k) }
        .accessibilityActions {
            if !isBrightness {
                Button(model.muted ? "取消静音" : "静音") { model.toggleMute() }
            }
        }
        .accessibilityIdentifier(isBrightness ? "player-brightness" : "player-volume")
    }

    /// 字幕 / 音轨 / 光效：收起时一个符号（光效带名字），展开成一排选项、白色高亮跟着手指走
    private func options(_ k: TouchBarKey) -> some View {
        let names = labels(k)
        let expanded = morph == k
        let symbol: String = switch k {
        case .subtitles: model.subtitlePick >= 0 ? "captions.bubble.fill" : "captions.bubble"
        case .audio: "waveform"
        default: "sparkles"
        }
        let current = currentIndex(k)
        return ZStack {
            if expanded {
                HStack(spacing: 4) {
                    Image(systemName: symbol)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.75))
                        .frame(width: 44)
                    ForEach(names.indices, id: \.self) { i in
                        let on = i == pick
                        Text(names[i])
                            .font(.system(size: 15, weight: on ? .semibold : .medium))
                            .foregroundStyle(on ? Color.black : Color.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .padding(.horizontal, 10)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background {
                                if on {
                                    Capsule().fill(Color.white)
                                        .padding(.vertical, 7)
                                        .matchedGeometryEffect(id: "pick", in: pickSpace)
                                }
                            }
                    }
                }
                .padding(.trailing, 6)
                .animation(.spring(response: 0.28, dampingFraction: 0.82), value: pick)
                .transition(.opacity)
            } else if k == .effects {
                HStack(spacing: 6) {
                    Image(systemName: symbol)
                        .font(.system(size: 16, weight: .semibold))
                    Text(settings.mode.preset.title)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(.white)
                .transition(.opacity)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 19, weight: .regular))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace.magic(fallback: .replace)))
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(k == .subtitles ? "字幕" : k == .audio ? "音轨" : "光效")
        .accessibilityValue(names.indices.contains(current) ? names[current] : "")
        .accessibilityHint(k == .subtitles ? "点按展开，再点按选择字幕"
                           : k == .audio ? "点按展开，再点按选择音轨" : "点按展开，再点按选择光影模式")
        .accessibilityAdjustableAction { direction in
            let n = names.count
            guard n > 0 else { return }
            let i = min(n - 1, max(0, current + (direction == .increment ? 1 : -1)))
            switch k {
            case .subtitles: model.selectSubtitle(i - 1)
            case .audio: model.selectAudio(i)
            case .effects: settings.setPreset(LightingPreset.allCases[i])
            default: break
            }
        }
        .accessibilityAction { openSticky(k) }
        .accessibilityIdentifier(k == .subtitles ? "player-subtitles" : k == .audio ? "player-audio" : "player-effects")
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
