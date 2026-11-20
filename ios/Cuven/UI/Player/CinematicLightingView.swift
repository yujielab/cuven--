import CuvenLighting
import SwiftUI

// MARK: - 影院光影的三种模式（标准 / 影院 / 沉浸）
//
// 用户要求「固定参数，移除设置项，允许调整的只是三种模式」：微调、开关、账户页的「影院光影」「光影实验室」两行都拿掉了，
// 参数固定在 CinematicReflectionMode 里。播放时在半折面板 Touch Bar 的「光效」上换模式；这三块卡只在光影实验室
//（Debug 构建、UI 测试截图用）里用。

struct LightingModePicker: View {
    @State private var settings = CinematicLightingSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
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
                        .frame(maxWidth: .infinity, minHeight: 66)
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
            Text(settings.mode.preset.summary)
                .font(.footnote)
                .foregroundStyle(DSInk.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .animation(.easeInOut(duration: 0.2), value: settings.mode.preset)
        }
        .foregroundStyle(.white)
    }
}
