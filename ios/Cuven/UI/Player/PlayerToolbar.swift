import AVKit
import MediaPlayer
import SwiftUI
import UIKit

// MARK: - 面板的第一行和第四行（参照图）
//
// 第一行：关闭 | 剧集信息卡（Cuven 字标 + 片名 + 第几集 + ›，点开是影院光影设置）| 画中画 | 锁定
// 第四行：截取画面 | 播放速度 | 亮度 | 音量 | 音频与字幕 | 下一集（剧集后面还有才有）| 全屏（半折时才有）
// 亮度、音量点开时第四行展开成一条滑杆，右边「×」收起。

struct PlayerTopBar: View {
    let model: CuvenPlayerViewModel
    let height: CGFloat

    var body: some View {
        GeometryReader { geo in
            let g = PlayerPanelStyle.gap
            // 参照图：三颗小块各占（行宽 − 三个间隔）的 16%，信息卡占剩下的
            let unit = ((geo.size.width - g * 3) * 0.162).rounded()
            HStack(spacing: g) {
                Button(action: { model.onClose?() }) {
                    PlayerIcon("xmark", size: 22)
                }
                .buttonStyle(LitTileStyle(id: "close"))
                .litCard("close", emphasis: 0.4)
                .frame(width: unit)
                .accessibilityLabel("关闭")
                .accessibilityIdentifier("player-close")
                .playerLockable(model.locked)

                PlayerTitleCard(model: model, height: height)
                    .litCard("title", emphasis: 0.35)
                    .playerLockable(model.locked)

                Button(action: { model.startPiP() }) {
                    PlayerIcon("pip.enter", size: 22, color: model.pipPossible ? .white : .white.opacity(0.35))
                }
                .buttonStyle(LitTileStyle(id: "pip"))
                .litCard("pip", emphasis: 0.4)
                .frame(width: unit)
                .disabled(!model.pipPossible)
                .accessibilityLabel("画中画")
                .accessibilityIdentifier("player-pip")
                .playerLockable(model.locked)

                // 锁着时这一块亮起来（白底黑锁），一眼看得出现在点不动
                Button(action: { model.toggleLock() }) {
                    PlayerIcon(model.locked ? "lock.fill" : "lock.open", size: 21, weight: .medium,
                               color: model.locked ? .black : .white)
                }
                .buttonStyle(LitTileStyle(id: "lock", lit: model.locked))
                .litCard("lock", emphasis: 0.4, lit: model.locked)
                .frame(width: unit)
                .accessibilityLabel(model.locked ? "解锁控制" : "锁定控制")
                .accessibilityIdentifier("player-lock")
            }
        }
    }
}

/// 剧集信息卡：Cuven 字标 + 片名 + 第几集 + 一个淡淡的「›」。点开是影院光影的设置（精简版，下面的面板就是预览）
struct PlayerTitleCard: View {
    let model: CuvenPlayerViewModel
    let height: CGFloat
    @State private var showsLighting = false

    var body: some View {
        Button {
            model.poke()
            showsLighting = true
        } label: {
            HStack(spacing: 14) {
                CuvenBrandMark()
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.title)
                        .font(.headline)
                        .foregroundStyle(.white)
                    if let s = model.subtitle, !s.isEmpty {
                        Text(s)
                            .font(.subheadline)
                            .foregroundStyle(DSInk.secondary)
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DSInk.tertiary)
            }
            .padding(.horizontal, 16)
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

struct PlayerBottomBar: View {
    let model: CuvenPlayerViewModel

    var body: some View {
        HStack(spacing: PlayerPanelStyle.gap) {
            Button(action: capture) {
                if model.capturing {
                    ProgressView().tint(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    PlayerIcon("scissors", size: 20)
                }
            }
            .buttonStyle(LitTileStyle(id: "clip"))
            .litCard("clip", emphasis: 0.35)
            .accessibilityLabel("截取画面")
            .accessibilityIdentifier("player-clip")

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
            .litCard("speed", emphasis: 0.35)
            .accessibilityLabel("播放速度")
            .accessibilityValue(Self.rateLabel(model.rate))
            .accessibilityIdentifier("player-speed")

            Button(action: { model.toggleTray(.brightness) }) {
                PlayerIcon("sun.max", size: 21)
            }
            .buttonStyle(LitTileStyle(id: "brightness"))
            .litCard("brightness", emphasis: 0.35)
            .accessibilityLabel("亮度")
            .accessibilityIdentifier("player-brightness")

            Button(action: { model.toggleTray(.volume) }) {
                PlayerIcon("speaker.wave.2", size: 21)
            }
            .buttonStyle(LitTileStyle(id: "volume"))
            .litCard("volume", emphasis: 0.35)
            .accessibilityLabel("音量")
            .accessibilityIdentifier("player-volume")

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
            .litCard("tracks", emphasis: 0.35)
            .accessibilityLabel("音频与字幕")
            .accessibilityIdentifier("player-tracks")

            if model.hasNext {
                Button(action: {
                    Haptics.light()
                    model.onNext?()
                }) {
                    PlayerIcon("forward.end", size: 21)
                }
                .buttonStyle(LitTileStyle(id: "next"))
                .litCard("next", emphasis: 0.35)
                .accessibilityLabel("下一集")
                .accessibilityIdentifier("player-next")
            }

            if model.fold != nil {
                Button(action: {
                    Haptics.light()
                    model.goFullscreen()
                }) {
                    PlayerIcon("arrow.up.left.and.arrow.down.right", size: 20)
                }
                .buttonStyle(LitTileStyle(id: "fullscreen"))
                .litCard("fullscreen", emphasis: 0.35)
                .accessibilityLabel("全屏")
                .accessibilityIdentifier("player-fullscreen")
            }
        }
    }

    private func capture() {
        model.poke()
        Task { @MainActor in
            guard let image = await model.captureFrame() else {
                Haptics.error()
                return
            }
            SharePresenter.present(image)
        }
    }

    /// 0.5×、0.75×、1×（正常）、1.25×……
    static func rateLabel(_ r: Float) -> String {
        r == 1 ? "1×（正常）" : String(format: "%g×", Double(r))
    }
}

/// 第四行展开成一条：亮度（屏幕亮度）/ 音量（系统音量，和侧边的音量键同一个）
struct PlayerTray: View {
    let model: CuvenPlayerViewModel
    let kind: CuvenPlayerViewModel.Tray

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: kind == .brightness ? "sun.max.fill" : "speaker.wave.2.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 24)
                .accessibilityHidden(true)
            switch kind {
            case .brightness:
                Slider(value: Binding(get: { model.brightness }, set: { model.setBrightness($0) }), in: 0...1)
                    .tint(.white)
                    .accessibilityLabel("亮度")
            case .volume:
                SystemVolumeSlider()
                    .frame(height: 34)
                    .accessibilityLabel("音量")
            }
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
        .padding(.leading, 20)
        .padding(.trailing, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .litCard("tray", emphasis: 0.3)
        .transition(.opacity)
    }
}

/// 系统音量：只有滑杆（画中画在第一行）
struct SystemVolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let v = MPVolumeView(frame: .zero)
        v.tintColor = .white
        return v
    }

    func updateUIView(_ v: MPVolumeView, context: Context) {}
}

/// 截下来的画面交给系统分享面板（存到照片、隔空投送、信息……）
@MainActor
enum SharePresenter {
    static func present(_ image: UIImage) {
        guard let top = UIApplication.topViewController() else { return }
        let sheet = UIActivityViewController(activityItems: [image], applicationActivities: nil)
        if let pop = sheet.popoverPresentationController {
            pop.sourceView = top.view
            pop.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.maxY - 80, width: 1, height: 1)
        }
        top.present(sheet, animated: true)
    }
}
