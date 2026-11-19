import AVKit
import MediaPlayer
import SwiftUI
import UIKit

// MARK: - 面板上的每一块（PlayerPanelGrid 摆位置，桌面时排成行、书本时排成列）
//
// ① 关闭 | 剧集信息卡（Cuven 字标 + 片名 + 第几集 + ›，点开是影院光影设置）| 画中画 | 锁定
// ④ 播放速度 | 亮度 | 音量 | 音频与字幕 | 下一集（剧集后面还有才有）| 全屏（半折时才有）
// 亮度、音量点开时第四排融成一条滑杆（书本时是竖的），「×」收起。

struct PlayerCloseTile: View {
    let model: CuvenPlayerViewModel

    var body: some View {
        Button(action: { model.onClose?() }) {
            PlayerIcon("xmark", size: 22)
        }
        .buttonStyle(LitTileStyle(id: "close"))
        .litCard("close", emphasis: 0.4)
        .accessibilityLabel("关闭")
        .accessibilityIdentifier("player-close")
        .playerLockable(model.locked)
    }
}

struct PlayerPiPTile: View {
    let model: CuvenPlayerViewModel

    var body: some View {
        Button(action: { model.startPiP() }) {
            PlayerIcon("pip.enter", size: 22, color: model.pipPossible ? .white : .white.opacity(0.35))
        }
        .buttonStyle(LitTileStyle(id: "pip"))
        .litCard("pip", emphasis: 0.4)
        .disabled(!model.pipPossible)
        .accessibilityLabel("画中画")
        .accessibilityIdentifier("player-pip")
        .playerLockable(model.locked)
    }
}

/// 锁着时这一块亮起来（白底黑锁），一眼看得出现在点不动
struct PlayerLockTile: View {
    let model: CuvenPlayerViewModel

    var body: some View {
        Button(action: { model.toggleLock() }) {
            PlayerIcon(model.locked ? "lock.fill" : "lock.open", size: 21, weight: .medium,
                       color: model.locked ? .black : .white)
                .contentTransition(.symbolEffect(.replace.magic(fallback: .replace)))
                .animation(.spring(response: 0.36, dampingFraction: 0.86), value: model.locked)
        }
        .buttonStyle(LitTileStyle(id: "lock", lit: model.locked))
        .litCard("lock", emphasis: 0.4, lit: model.locked)
        .accessibilityLabel(model.locked ? "解锁控制" : "锁定控制")
        .accessibilityIdentifier("player-lock")
    }
}

/// 剧集信息卡：Cuven 字标 + 片名 + 第几集 + 一个淡淡的「›」。点开是影院光影的设置（精简版，下面的面板就是预览）。
/// 桌面时横着排（字标在左），书本时这一块是竖长的一条，字标、片名、集数从上往下排；两种之间用同一套视图换排法，
/// 字和符号跟着卡片一起形变过去
struct PlayerTitleCard: View {
    let model: CuvenPlayerViewModel
    var vertical = false
    @State private var showsLighting = false

    var body: some View {
        let layout = vertical ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
                              : AnyLayout(HStackLayout(spacing: 14))
        Button {
            model.poke()
            showsLighting = true
        } label: {
            layout {
                CuvenBrandMark()
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.title)
                        .font(vertical ? Font.subheadline.weight(.semibold) : Font.headline)
                        .foregroundStyle(.white)
                        .lineLimit(vertical ? 4 : 1)
                    if let s = model.subtitle, !s.isEmpty {
                        Text(s)
                            .font(vertical ? Font.footnote : Font.subheadline)
                            .foregroundStyle(DSInk.secondary)
                            .lineLimit(vertical ? 3 : 1)
                    }
                }
                .minimumScaleFactor(0.85)
                Spacer(minLength: 0)
                Image(systemName: vertical ? "chevron.down" : "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DSInk.tertiary)
                    .contentTransition(.symbolEffect(.replace.magic(fallback: .replace)))
            }
            .padding(.horizontal, vertical ? 12 : 16)
            .padding(.vertical, vertical ? 14 : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: vertical ? .topLeading : .leading)
        }
        .buttonStyle(LitTileStyle(id: "title"))
        .popover(isPresented: $showsLighting) {
            ScrollView {
                CinematicLightingView(compact: true)
                    .padding(20)
            }
            .frame(minWidth: 320, idealWidth: 380, maxWidth: 420, minHeight: 320, idealHeight: 460)
            .background(Color(white: 0.08))
            .presentationCompactAdaptation(.popover)
            .preferredColorScheme(.dark)
        }
        .onChange(of: showsLighting) { _, open in model.setSettingsOpen(open) }
        .litCard("title", emphasis: 0.35)
        .playerLockable(model.locked)
        .accessibilityElement(children: .combine)
        .accessibilityLabel([model.title, model.subtitle].compactMap { $0 }.joined(separator: "，"))
        .accessibilityHint("打开影院光影设置")
        .accessibilityIdentifier("player-title")
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

/// 第四排的一块（播放速度 / 亮度 / 音量 / 音频与字幕 / 下一集 / 全屏）。亮度、音量那一条展开时这几块收起，
/// 卡面在渲染器里融成一条（同一个形变组「tools」），符号淡出
struct PlayerToolTile: View {
    let model: CuvenPlayerViewModel
    let tile: PlayerTile

    var body: some View {
        content
            .litCard(tile.rawValue, emphasis: 0.35, group: "tools", active: model.tray == nil)
            .accessibilityIdentifier("player-\(tile.rawValue)")
            .playerLockable(model.locked)
    }

    @ViewBuilder private var content: some View {
        switch tile {
        case .speed:
            Menu {
                Picker("播放速度", selection: Binding(get: { model.rate }, set: { model.setRate($0) })) {
                    ForEach(CuvenPlayerViewModel.rates, id: \.self) { r in
                        Text(Self.rateLabel(r)).tag(r)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                PlayerIcon("gauge.with.dots.needle.67percent", size: 21)
            }
            .menuStyle(.button)
            .buttonStyle(LitTileStyle(id: "speed"))
            .accessibilityLabel("播放速度")
            .accessibilityValue(Self.rateLabel(model.rate))
        case .brightness:
            Button(action: { model.toggleTray(.brightness) }) {
                PlayerIcon("sun.max", size: 21)
            }
            .buttonStyle(LitTileStyle(id: "brightness"))
            .accessibilityLabel("亮度")
        case .volume:
            Button(action: { model.toggleTray(.volume) }) {
                PlayerIcon("speaker.wave.2", size: 21)
            }
            .buttonStyle(LitTileStyle(id: "volume"))
            .accessibilityLabel("音量")
        case .tracks:
            Menu {
                if model.audioNames.count > 1 {
                    Picker("音频", selection: Binding(get: { model.audioPick }, set: { model.selectAudio($0) })) {
                        ForEach(model.audioNames.indices, id: \.self) { i in
                            Text(model.audioNames[i]).tag(i)
                        }
                    }
                    .pickerStyle(.inline)
                }
                Picker("字幕", selection: Binding(get: { model.subtitlePick }, set: { model.selectSubtitle($0) })) {
                    Text("关").tag(-1)
                    ForEach(model.subtitleNames.indices, id: \.self) { i in
                        Text(model.subtitleNames[i]).tag(i)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                PlayerIcon("captions.bubble", size: 21)
            }
            .menuStyle(.button)
            .buttonStyle(LitTileStyle(id: "tracks"))
            .accessibilityLabel("音频与字幕")
        case .next:
            Button(action: {
                Haptics.light()
                model.onNext?()
            }) {
                PlayerIcon("forward.end", size: 21)
            }
            .buttonStyle(LitTileStyle(id: "next"))
            .accessibilityLabel("下一集")
        case .fullscreen:
            Button(action: {
                Haptics.light()
                model.goFullscreen()
            }) {
                PlayerIcon("arrow.up.left.and.arrow.down.right", size: 20)
            }
            .buttonStyle(LitTileStyle(id: "fullscreen"))
            .accessibilityLabel("全屏")
        default:
            EmptyView()
        }
    }

    /// 第四排有哪些（沿折痕的顺序）
    static func tools(for model: CuvenPlayerViewModel) -> [PlayerTile] {
        var t: [PlayerTile] = [.speed, .brightness, .volume, .tracks]
        if model.hasNext { t.append(.next) }
        if model.fold != nil { t.append(.fullscreen) }
        return t
    }

    /// 0.5×、0.75×、1×（正常）、1.25×……
    static func rateLabel(_ r: Float) -> String {
        r == 1 ? "1×（正常）" : String(format: "%g×", Double(r))
    }
}

/// 第四排展开成一条：亮度（屏幕亮度）/ 音量（系统音量，和侧边的音量键同一个）。书本时这一排是竖的一列，滑杆也竖过来
/// （往上是大）
struct PlayerTray: View {
    let model: CuvenPlayerViewModel
    let kind: CuvenPlayerViewModel.Tray
    var vertical = false

    var body: some View {
        let layout = vertical ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 16))
        layout {
            if vertical { close }
            Image(systemName: kind == .brightness ? "sun.max.fill" : "speaker.wave.2.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
            PanelSlider(kind: kind, model: model, vertical: vertical)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel(kind == .brightness ? "亮度" : "音量")
            if !vertical { close }
        }
        .padding(vertical ? EdgeInsets(top: 6, leading: 0, bottom: 20, trailing: 0)
                          : EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 6))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .litCard("tray", emphasis: 0.3, group: "tools", active: model.tray != nil)
    }

    private var close: some View {
        Button(action: { model.toggleTray(kind) }) {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.9))
        .accessibilityLabel("收起")
        .accessibilityIdentifier("player-tray-close")
    }
}

/// 亮度 / 音量的滑杆（UIKit 的，横竖都行）：亮度是一根 UISlider，音量是系统的 MPVolumeView（和音量键同一个）。
/// 竖着时整根转 90°（在 UIKit 里转，点按、拖动跟着转），往上是大
struct PanelSlider: UIViewRepresentable {
    let kind: CuvenPlayerViewModel.Tray
    let model: CuvenPlayerViewModel
    var vertical = false

    func makeUIView(context: Context) -> RotatingSliderHost {
        let inner: UIView
        switch kind {
        case .brightness:
            let s = UISlider()
            s.minimumValue = 0
            s.maximumValue = 1
            s.value = Float(model.brightness)
            s.minimumTrackTintColor = .white
            s.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.24)
            s.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
            inner = s
        case .volume:
            let v = MPVolumeView(frame: .zero)
            v.tintColor = .white
            inner = v
        }
        return RotatingSliderHost(content: inner)
    }

    func updateUIView(_ v: RotatingSliderHost, context: Context) {
        context.coordinator.model = model
        v.vertical = vertical
        if let s = v.content as? UISlider, !s.isTracking {
            s.value = Float(model.brightness)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    @MainActor
    final class Coordinator: NSObject {
        var model: CuvenPlayerViewModel
        init(model: CuvenPlayerViewModel) { self.model = model }

        @objc func changed(_ s: UISlider) {
            model.setBrightness(Double(s.value))
            model.poke()
        }
    }
}

/// 装滑杆的那一层：竖着时把里面的滑杆转 -90°、长边沿着这一层的高
final class RotatingSliderHost: UIView {
    let content: UIView
    var vertical = false {
        didSet { if vertical != oldValue { setNeedsLayout() } }
    }

    init(content: UIView) {
        self.content = content
        super.init(frame: .zero)
        addSubview(content)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let thickness: CGFloat = 34
        content.transform = .identity
        if vertical {
            content.bounds = CGRect(x: 0, y: 0, width: bounds.height, height: min(thickness, bounds.width))
            content.center = CGPoint(x: bounds.midX, y: bounds.midY)
            content.transform = CGAffineTransform(rotationAngle: -.pi / 2)
        } else {
            content.bounds = CGRect(x: 0, y: 0, width: bounds.width, height: min(thickness, bounds.height))
            content.center = CGPoint(x: bounds.midX, y: bounds.midY)
        }
    }
}
