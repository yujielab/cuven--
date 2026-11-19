import CoreGraphics
import Foundation
import Metal
import UIKit

/// Why the lighting is running below its preset's full quality (shown in the diagnostics)
public enum LightingAdaptation: String, Sendable, Equatable {
    case none
    case background
    case thermalCritical
    case thermalSerious
    case lowPowerMode
    case lowBattery
    case olderGPU
    case heavySource
    case overBudget
}

/// Picks the quality level the lighting runs at, once a second, from:
///   · thermal state (critical always freezes the lighting, even with adaptive lighting off — safety first);
///   · Low Power Mode, and battery below 20 % while unplugged;
///   · GPU capability (Apple GPU family: immersive detail is reduced on GPUs before Apple 7 / A14);
///   · video resolution (sources above 4K wide cost the decoder's scaler more on older GPUs);
///   · the measured frame budget: lighting GPU time above 5 ms for three checks in a row → reduced,
///     back to high once it drops under 2.5 ms (hysteresis, so it does not flap).
/// The analysis never waits on playback and playback never waits on the analysis: a lower level only means fewer,
/// smaller samples.
@MainActor
public final class AdaptiveLightingController {
    public private(set) var quality: LightingQuality = .high
    public private(set) var adaptation: LightingAdaptation = .none
    /// 0: before Apple 7, 1: Apple 7–8, 2: Apple 9 and later
    public let gpuTier: Int

    private var lastCheck: CFTimeInterval = 0
    private var overBudgetStreak = 0
    private var overBudget = false

    init(device: any MTLDevice) {
        if device.supportsFamily(.apple9) {
            gpuTier = 2
        } else if device.supportsFamily(.apple7) {
            gpuTier = 1
        } else {
            gpuTier = 0
        }
        UIDevice.current.isBatteryMonitoringEnabled = true
    }

    /// Re-evaluate (at most once a second unless forced). Returns true when the level changed.
    @discardableResult
    func update(now: CFTimeInterval, foreground: Bool, mode: CinematicReflectionMode, gpuMilliseconds: Double,
                sourceSize: CGSize, force: Bool = false) -> Bool {
        guard force || now - lastCheck >= 1 else { return false }
        lastCheck = now

        if gpuMilliseconds > 5 { overBudgetStreak += 1 } else { overBudgetStreak = 0 }
        if overBudgetStreak >= 3 { overBudget = true }
        if gpuMilliseconds > 0, gpuMilliseconds < 2.5 { overBudget = false }

        let info = ProcessInfo.processInfo
        let device = UIDevice.current
        let next: (LightingQuality, LightingAdaptation)
        if !foreground {
            next = (.suspended, .background)
        } else if info.thermalState == .critical {
            next = (.minimal, .thermalCritical)
        } else if !mode.adaptiveLighting || !mode.preset.usesVideoLight {
            next = (.high, .none)
        } else if info.thermalState == .serious {
            next = (.reduced, .thermalSerious)
        } else if info.isLowPowerModeEnabled {
            next = (.reduced, .lowPowerMode)
        } else if device.batteryState == .unplugged, device.batteryLevel >= 0, device.batteryLevel < 0.2 {
            next = (.reduced, .lowBattery)
        } else if mode.preset == .immersive, gpuTier == 0 {
            next = (.reduced, .olderGPU)
        } else if max(sourceSize.width, sourceSize.height) > 3900, gpuTier < 2 {
            next = (.reduced, .heavySource)
        } else if overBudget {
            next = (.reduced, .overBudget)
        } else {
            next = (.high, .none)
        }
        let changed = next.0 != quality
        quality = next.0
        adaptation = next.1
        return changed
    }

    func setBackground() {
        quality = .suspended
        adaptation = .background
    }

    func resetClock() {
        lastCheck = 0
    }
}
