import CuvenLighting
import Foundation
import SwiftUI

// MARK: - 影院光影（Cinematic Reflection Mode）的设置：存在本机，所有播放器共用
//
// 只有模式（标准 / 影院 / 沉浸）能改（用户要求「固定参数，移除设置项，允许调整的只是三种模式」）：微调固定在
// CinematicReflectionMode 里（反射强度、环境光、镜面高光、边缘光 150%，反射柔化 200%，空间响应、自适应一直开着）。
// 改模式的地方只有半折面板 Touch Bar 上的「光效」（长按滑动选，点一下换下一种）；改了立即生效，约 0.6 秒平滑过渡。
// 以前存下的整套设置只读出模式；以前的「画面光影」开关（player_lighting）关着的，迁移成「标准」。

@MainActor
@Observable
final class CinematicLightingSettings {
    static let shared = CinematicLightingSettings()

    private(set) var mode: CinematicReflectionMode

    private static let modeKey = "cinematic_reflection_mode_v1"
    private static let legacyEnabledKey = "player_lighting"

    private init() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: Self.modeKey), let m = try? JSONDecoder().decode(CinematicReflectionMode.self, from: data) {
            mode = CinematicReflectionMode(preset: m.preset)
        } else {
            mode = CinematicReflectionMode(preset: d.object(forKey: Self.legacyEnabledKey) as? Bool == false ? .standard : .cinematic)
        }
    }

    func setPreset(_ preset: LightingPreset) {
        guard preset != mode.preset else { return }
        Haptics.selection()
        mode = CinematicReflectionMode(preset: preset)
        if let data = try? JSONEncoder().encode(mode) {
            UserDefaults.standard.set(data, forKey: Self.modeKey)
        }
    }

    /// 下一种（点一下「光效」）：标准 → 影院 → 沉浸 → 标准
    func cyclePreset() {
        let all = LightingPreset.allCases
        let i = all.firstIndex(of: mode.preset) ?? 0
        setPreset(all[(i + 1) % all.count])
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
