import CuvenLighting
import Foundation
import SwiftUI

// MARK: - 影院光影（Cinematic Reflection Mode）的设置：存在本机，所有播放器共用
//
// 模式（标准 / 影院 / 沉浸）+ 五个微调（反射强度、环境光、镜面高光、边缘光、反射柔化）+ 三个开关
//（空间响应、自适应光影、预览光影）。改了立即生效：正在放的播放器在约 0.6 秒里平滑过渡到新的样子。
// 以前的「画面光影」开关（player_lighting）关着的，迁移成「标准」；以前的强度换算成反射强度。

@MainActor
@Observable
final class CinematicLightingSettings {
    static let shared = CinematicLightingSettings()

    private(set) var mode: CinematicReflectionMode
    /// 设置页里放一段测试画面实时预览（耗电，默认开着、只在设置页可见时跑）
    private(set) var previewLighting: Bool

    private static let modeKey = "cinematic_reflection_mode_v1"
    private static let previewKey = "cinematic_preview_lighting"
    private static let legacyEnabledKey = "player_lighting"
    private static let legacyIntensityKey = "player_lighting_intensity"

    private init() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: Self.modeKey), let m = try? JSONDecoder().decode(CinematicReflectionMode.self, from: data) {
            mode = m
        } else {
            var m = CinematicReflectionMode()
            if d.object(forKey: Self.legacyEnabledKey) as? Bool == false { m.preset = .standard }
            if let old = d.object(forKey: Self.legacyIntensityKey) as? Double { m.reflectionIntensity = Float(min(max(old / 0.85, 0), 1.5)) }
            mode = m
        }
        previewLighting = d.object(forKey: Self.previewKey) as? Bool ?? true
    }

    func update(_ change: (inout CinematicReflectionMode) -> Void) {
        var m = mode
        change(&m)
        guard m != mode else { return }
        mode = m
        if let data = try? JSONEncoder().encode(m) {
            UserDefaults.standard.set(data, forKey: Self.modeKey)
        }
    }

    func setPreset(_ preset: LightingPreset) {
        guard preset != mode.preset else { return }
        Haptics.selection()
        update { $0.preset = preset }
    }

    func setPreviewLighting(_ on: Bool) {
        previewLighting = on
        UserDefaults.standard.set(on, forKey: Self.previewKey)
    }

    /// 微调回到预设的样子（模式和开关不动）
    func resetTuning() {
        update { m in
            let fresh = CinematicReflectionMode(preset: m.preset)
            m.reflectionIntensity = fresh.reflectionIntensity
            m.ambientLight = fresh.ambientLight
            m.specularHighlight = fresh.specularHighlight
            m.edgeGlow = fresh.edgeGlow
            m.reflectionBlur = fresh.reflectionBlur
        }
    }
}

extension LightingPreset {
    var title: String {
        switch self {
        case .standard: return "标准"
        case .cinematic: return "影院"
        case .immersive: return "沉浸"
        }
    }

    var symbol: String {
        switch self {
        case .standard: return "rectangle.on.rectangle"
        case .cinematic: return "film"
        case .immersive: return "sparkles"
        }
    }

    var summary: String {
        switch self {
        case .standard: return "干净的深色控制面板，不随画面变化，最省电。"
        case .cinematic: return "画面里的光柔和地映在控制卡片上，带一点镜面反射和方向高光。推荐。"
        case .immersive: return "更细的光源分析、更明显的局部反射、两层高光与边缘光，跟着设备姿态变化。"
        }
    }
}
