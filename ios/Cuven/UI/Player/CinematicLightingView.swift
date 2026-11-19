import AVFoundation
import CuvenLighting
import SwiftUI
import UIKit

// MARK: - 影院光影的设置面板
//
// 两处用到同一个面板：
//   · 播放中：点剧集信息卡（右边那个 ›）弹出精简版（模式 + 微调 + 开关），下面的控制面板就是预览，改了马上看到；
//   · 账户与设置 →「播放」→「影院光影」：完整版，多一块用测试画面跑的实时预览（「预览光影」关掉就不跑）。
// 样子照 Cuven 的极简深色：三块模式卡、细滑杆、百分比读数；「标准」时微调变灰（不起作用）。

struct CinematicLightingView: View {
    var compact = false
    @State private var settings = CinematicLightingSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 18 : 26) {
            modePicker
            Text(settings.mode.preset.summary)
                .font(.footnote)
                .foregroundStyle(DSInk.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .animation(.easeInOut(duration: 0.2), value: settings.mode.preset)

            if !compact && settings.previewLighting {
                CinematicPreview()
                    .frame(height: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(DSFill.hairline, lineWidth: 1))
                    .transition(.opacity)
            }

            tuning
            toggles
        }
        .foregroundStyle(.white)
        .tint(.white)
        .animation(.easeInOut(duration: 0.25), value: settings.previewLighting)
    }

    // MARK: 模式

    private var modePicker: some View {
        HStack(spacing: 10) {
            ForEach(LightingPreset.allCases, id: \.self) { preset in
                let on = settings.mode.preset == preset
                Button {
                    withAnimation(.snappy(duration: 0.26)) { settings.setPreset(preset) }
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: preset.symbol)
                            .font(.system(size: 20, weight: .regular))
                        Text(preset.title)
                            .font(.subheadline.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity, minHeight: compact ? 66 : 78)
                    .foregroundStyle(on ? Color.white : Color.white.opacity(0.6))
                    .background {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.white.opacity(on ? 0.14 : 0.05))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color.white.opacity(on ? 0.5 : 0.08), lineWidth: on ? 1.5 : 1)
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(PressableStyle(scale: 0.96))
                .accessibilityLabel(preset.title)
                .accessibilityAddTraits(on ? .isSelected : [])
                .accessibilityIdentifier("lighting-preset-\(preset.rawValue)")
            }
        }
    }

    // MARK: 微调

    private var tuning: some View {
        let active = settings.mode.preset.usesVideoLight
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("微调")
                    .font(.headline)
                    .foregroundStyle(DSInk.secondary)
                Spacer()
                Button("恢复默认") { settings.resetTuning() }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(DSInk.secondary)
                    .accessibilityIdentifier("lighting-reset")
            }
            slider("反射强度", value: \.reflectionIntensity, range: 0...1.5, id: "intensity")
            slider("环境光", value: \.ambientLight, range: 0...1.5, id: "ambient")
            slider("镜面高光", value: \.specularHighlight, range: 0...1.5, id: "specular")
            slider("边缘光", value: \.edgeGlow, range: 0...1.5, id: "edge")
            slider("反射柔化", value: \.reflectionBlur, range: 0...2, id: "blur")
        }
        .opacity(active ? 1 : 0.35)
        .allowsHitTesting(active)
        .animation(.easeInOut(duration: 0.25), value: active)
    }

    private func slider(_ title: String, value: WritableKeyPath<CinematicReflectionMode, Float>,
                        range: ClosedRange<Float>, id: String) -> some View {
        let binding = Binding<Float>(get: { settings.mode[keyPath: value] },
                                     set: { v in settings.update { $0[keyPath: value] = v } })
        return HStack(spacing: 14) {
            Text(title)
                .font(.subheadline)
                .frame(width: 72, alignment: .leading)
            Slider(value: binding, in: range)
                .accessibilityLabel(title)
                .accessibilityValue("\(Int((binding.wrappedValue * 100).rounded()))%")
                .accessibilityIdentifier("lighting-\(id)")
            Text("\(Int((binding.wrappedValue * 100).rounded()))%")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(DSInk.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }

    // MARK: 开关

    private var toggles: some View {
        VStack(spacing: 14) {
            Toggle(isOn: Binding(get: { settings.mode.spatialResponse }, set: { v in settings.update { $0.spatialResponse = v } })) {
                label("空间响应", "设备转动、折叠角度变化时，反射与高光跟着移动")
            }
            .accessibilityIdentifier("lighting-spatial")
            Toggle(isOn: Binding(get: { settings.mode.adaptiveLighting }, set: { v in settings.update { $0.adaptiveLighting = v } })) {
                label("自适应光影", "设备发热、低电量或画面很大时自动降低分析精度")
            }
            .accessibilityIdentifier("lighting-adaptive")
            if !compact {
                Toggle(isOn: Binding(get: { settings.previewLighting }, set: { settings.setPreviewLighting($0) })) {
                    label("预览光影", "在这里用测试画面实时预览效果")
                }
                .accessibilityIdentifier("lighting-preview")
            }
        }
        .tint(.green)
    }

    private func label(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(detail).font(.caption).foregroundStyle(DSInk.tertiary)
        }
    }
}

// MARK: - 实时预览：测试画面（火光 → 海面 → 夜色 → 霓虹）照在一块缩小的控制面板上

private struct CinematicPreview: View {
    @State private var model = CuvenPlayerViewModel()
    @State private var player: AVPlayer?
    @State private var loopObserver: NSObjectProtocol?

    var body: some View {
        CuvenPlayerView(model: model, player: player, layout: .stacked, options: PlayerLightingOptions(simulatedFold: 115))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .task {
                model.title = "预览"
                model.subtitle = "火光 · 海面 · 夜色 · 霓虹"
                model.keepsControlsVisible = true
                model.activateStandalone()
                guard player == nil, let url = try? await TestPatternVideo.make() else { return }
                let p = AVPlayer(url: url)
                p.isMuted = true
                p.actionAtItemEnd = .none
                loopObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: p.currentItem,
                                                                      queue: .main) { [weak p] _ in
                    p?.seek(to: .zero)
                    p?.play()
                }
                model.player = p
                model.rebind()
                player = p
                p.play()
            }
            .onDisappear {
                player?.pause()
                if let loopObserver { NotificationCenter.default.removeObserver(loopObserver) }
                model.deactivateStandalone()
            }
    }
}

// MARK: - 账户与设置里打开的那一页

@MainActor
enum CinematicLightingPage {
    private static weak var controller: UIViewController?

    static func present() {
        guard controller == nil, let top = UIApplication.topViewController() else { return }
        let vc = UIHostingController(rootView: CinematicLightingPageView())
        vc.view.backgroundColor = .black
        vc.modalPresentationStyle = .pageSheet
        controller = vc
        top.present(vc, animated: true)
    }

    static func dismiss() {
        controller?.dismiss(animated: true)
    }
}

private struct CinematicLightingPageView: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                CinematicLightingView()
                    .padding(20)
            }
            .background(Color.black)
            .navigationTitle("影院光影")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { CinematicLightingPage.dismiss() }
                        .accessibilityIdentifier("lighting-done")
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
