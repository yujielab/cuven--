import CoreMotion
import Foundation
import UIKit
import simd

/// Where the viewer and the light are, in space, from frame to frame.
///
/// Fold angle — platform independent. Sources, in order:
///   1. simulation (the lab's slider, or tests), when `useSimulatedFold` is on;
///   2. a hardware reading pushed in through `updateHardwareFold(_:)` — the app feeds it from SwiftUI's
///      `onHingeChange` on iOS 27.1 devices that report a hinge; nothing here assumes such an API exists;
///   3. what the layout implies (`LightingGeometry.layoutFoldDegrees`: e.g. ~105° for the half-folded layout).
/// Device attitude — Core Motion device-motion gravity, polled each frame (no callbacks, no queues). The tilt is
/// measured against a slowly adapting baseline, so whatever posture the device rests in is "neutral" and only
/// movement shifts the reflections. Mapped into the current interface orientation's axes.
/// Everything is eased with critically damped smoothing (≈ 0.3 s), so folding or tilting never makes the light jump.
@MainActor
public final class SpatialResponseEngine {
    public struct State: Sendable, Equatable {
        /// Fold angle in radians (π = flat)
        public var foldRadians: Float = .pi
        /// Tilt relative to the resting posture, in screen axes (−1…1)
        public var tilt: SIMD2<Float> = .zero
        /// Light intensity factor from posture (0.85…1.15)
        public var intensity: Float = 1
    }

    public var isEnabled = true {
        didSet { isEnabled ? startMotion() : stopMotion() }
    }
    public var useSimulatedFold = false
    /// Degrees, 30…180
    public var simulatedFoldDegrees: Double = 120
    public private(set) var hardwareFoldDegrees: Double?
    public private(set) var state = State()

    private let motion = CMMotionManager()
    private var running = false
    private var baseline: SIMD3<Double>?
    private var fold: Double = 180
    private var tilt = SIMD2<Double>.zero
    private var foldVelocity: Double = 0

    public init() {}

    /// From the hinge, when the platform reports one (nil when it stops reporting)
    public func updateHardwareFold(_ degrees: Double?) {
        hardwareFoldDegrees = degrees.map { min(max($0, 0), 180) }
    }

    func start() {
        if isEnabled { startMotion() }
    }

    func stop() {
        stopMotion()
    }

    private func startMotion() {
        guard !running, motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 60.0
        motion.startDeviceMotionUpdates()
        running = true
        baseline = nil
    }

    private func stopMotion() {
        guard running else { return }
        motion.stopDeviceMotionUpdates()
        running = false
        baseline = nil
    }

    /// The fold angle the frame should use right now (before smoothing)
    func targetFold(layoutDegrees: Double) -> Double {
        if useSimulatedFold { return simulatedFoldDegrees }
        return hardwareFoldDegrees ?? layoutDegrees
    }

    /// Advance by dt; reads the attitude and eases everything toward its target
    func update(dt: Double, layoutFoldDegrees: Double, orientation: UIInterfaceOrientation) {
        let dt = min(max(dt, 0), 0.1)
        // Fold: critically damped spring, ~0.3 s
        let target = targetFold(layoutDegrees: layoutFoldDegrees)
        let omega = 2.0 * Double.pi / 0.6
        let accel = omega * omega * (target - fold) - 2 * omega * foldVelocity
        foldVelocity += accel * dt
        fold += foldVelocity * dt
        if abs(target - fold) < 0.01 && abs(foldVelocity) < 0.01 { fold = target; foldVelocity = 0 }

        var targetTilt = SIMD2<Double>.zero
        if isEnabled, running, let g = motion.deviceMotion?.gravity {
            let gravity = SIMD3(g.x, g.y, g.z)
            // Baseline drifts toward the current posture over ~3 s: resting pose is neutral
            if let b = baseline {
                baseline = b + (gravity - b) * (1 - exp(-dt / 3.0))
            } else {
                baseline = gravity
            }
            let d = gravity - (baseline ?? gravity)
            let screen: SIMD2<Double>
            switch orientation {
            case .portraitUpsideDown: screen = SIMD2(-d.x, d.y)
            case .landscapeLeft: screen = SIMD2(-d.y, -d.x)
            case .landscapeRight: screen = SIMD2(d.y, d.x)
            default: screen = SIMD2(d.x, -d.y)
            }
            targetTilt = simd_clamp(screen * 2.2, SIMD2(repeating: -1), SIMD2(repeating: 1))
        }
        tilt += (targetTilt - tilt) * (1 - exp(-dt / 0.18))

        state = State(foldRadians: Float(fold * .pi / 180),
                      tilt: SIMD2<Float>(Float(tilt.x), Float(tilt.y)),
                      intensity: Float(1 + 0.15 * max(-1, min(1, tilt.y))))
    }

    var foldDegrees: Double { fold }
}
