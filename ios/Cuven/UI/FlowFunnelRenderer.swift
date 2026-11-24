import MetalKit
import SwiftUI
import UIKit

// MARK: - 「Luminous Data Flow」漏斗：共享状态 + Metal 那一半（着色器在 FlowFunnel.metal）
//
// 卡上的数字、百分比、漏斗的形状、颜色、能量波、进度条都读同一份插值后的状态（FlowFunnelEngine.sample）：
// 数据一变，每个量各自用一条临界阻尼的弹簧从「现在的样子」走到新的值（中途再变就从当时的位置接着走，不跳、不闪、不重来）。
// 粒子是按时间直接算出来的，切分类、数据变了都不会重新开始。

/// 临界阻尼弹簧（解析解）：任意时刻都能取到位置和速度，随时换目标
struct FlowSpring {
    private var x0: Double
    private var v0: Double = 0
    private var t0: CFTimeInterval = 0
    private(set) var target: Double
    let omega: Double

    init(_ value: Double, omega: Double) {
        x0 = value
        target = value
        self.omega = omega
    }

    func value(_ t: CFTimeInterval) -> Double {
        let dt = max(0, t - t0)
        let c1 = x0 - target, c2 = v0 + omega * c1
        return target + (c1 + c2 * dt) * exp(-omega * dt)
    }

    private func velocity(_ t: CFTimeInterval) -> Double {
        let dt = max(0, t - t0)
        let c1 = x0 - target, c2 = v0 + omega * c1
        return (c2 - omega * (c1 + c2 * dt)) * exp(-omega * dt)
    }

    /// 换目标：从这一刻的位置和速度接着走
    mutating func retarget(_ value: Double, at t: CFTimeInterval) {
        guard value != target else { return }
        x0 = self.value(t)
        v0 = velocity(t)
        t0 = t
        target = value
    }

    /// 直接到位（第一次有数据时：不要从 0 长出来）
    mutating func snap(_ value: Double, at t: CFTimeInterval) {
        x0 = value
        v0 = 0
        t0 = t
        target = value
    }
}

/// 一类数据的颜色：左边主色 → 右边副色（设计说明里的配色）
struct FlowPalette: Equatable {
    var primary: SIMD3<Double>
    var secondary: SIMD3<Double>

    /// 全部：深红 → 暖金
    static let all = FlowPalette(primary: SIMD3(0.86, 0.12, 0.30), secondary: SIMD3(1.0, 0.74, 0.32))
    /// 电影：琥珀 → 香槟金
    static let movie = FlowPalette(primary: SIMD3(1.0, 0.52, 0.10), secondary: SIMD3(0.98, 0.86, 0.60))
    /// 剧集：电光紫 → 薰衣草
    static let tv = FlowPalette(primary: SIMD3(0.52, 0.22, 1.0), secondary: SIMD3(0.80, 0.70, 1.0))
}

/// SwiftUI 和渲染器之间共享的状态（都在主线程上动）
final class FlowFunnelEngine {
    struct Sample {
        var counts: [Double]       // 四段的数量（插值中的，可能是小数）
        var heights: SIMD4<Float>  // 四段的半高（0…1）
        var primary: SIMD3<Double>
        var secondary: SIMD3<Double>
        var progress: Double       // 0…1
        var wave: Double           // 能量波强度 0…1
        var appear: Double         // 0…1
    }

    /// 数字、几何：650–900 毫秒走完（ω≈8）；颜色 500–800 毫秒（ω≈9）；能量波渐入渐出慢一点
    private var counts = (0..<4).map { _ in FlowSpring(0, omega: 8) }
    private var colors = (0..<6).map { _ in FlowSpring(0, omega: 9) }
    private var progressS = FlowSpring(0, omega: 6)
    private var waveS = FlowSpring(0, omega: 3)
    private var appearS = FlowSpring(0, omega: 5)
    private var hasData = false
    var reduceMotion = false
    /// 画布看得见的时候才画（滚出屏幕、切走标签都停）
    var visible = true

    func update(counts new: [Int], palette: FlowPalette, progress: Double, transferring: Bool, now: CFTimeInterval = CACurrentMediaTime()) {
        let vals = (0..<4).map { Double($0 < new.count ? new[$0] : 0) }
        let cols = [palette.primary.x, palette.primary.y, palette.primary.z, palette.secondary.x, palette.secondary.y, palette.secondary.z]
        if !hasData || reduceMotion {
            for i in 0..<4 { counts[i].snap(vals[i], at: now) }
            for i in 0..<6 { colors[i].snap(cols[i], at: now) }
            progressS.snap(progress, at: now)
            hasData = true
        } else {
            for i in 0..<4 { counts[i].retarget(vals[i], at: now) }
            for i in 0..<6 { colors[i].retarget(cols[i], at: now) }
            progressS.retarget(progress, at: now)
        }
        waveS.retarget(transferring ? 1 : 0, at: now)
        appearS.retarget(1, at: now)
    }

    func sample(_ now: CFTimeInterval = CACurrentMediaTime()) -> Sample {
        let c = counts.map { max(0, $0.value(now)) }
        let top = max(c[0], 1)
        // 每一段的高度 ∝ 这一段的数量（占第一段的比例）；最窄也留一点，光还能流过去
        func h(_ v: Double) -> Float { Float(0.16 + 0.84 * min(1, max(0, v / top))) }
        let heights = SIMD4<Float>(h(c[0]), h(c[1]), h(c[2]), h(c[3]))
        let col = colors.map { min(1, max(0, $0.value(now))) }
        return Sample(counts: c, heights: heights,
                      primary: SIMD3(col[0], col[1], col[2]), secondary: SIMD3(col[3], col[4], col[5]),
                      progress: min(1, max(0, progressS.value(now))), wave: min(1, max(0, waveS.value(now))),
                      appear: min(1, max(0, appearS.value(now))))
    }

    /// 能量波这一刻在哪儿：每 3.2 秒一趟，2.6 秒横穿（匀速，前后都在画面外一点，起步和收尾都是柔的）
    static func wavePosition(_ t: Double) -> Double {
        let p = t.truncatingRemainder(dividingBy: 3.2)
        return p < 2.6 ? -0.12 + 1.26 * (p / 2.6) : 1.3
    }
}

final class FlowFunnelRenderer: NSObject, MTKViewDelegate {
    private struct Uniforms {
        var size: SIMD4<Float>
        var heights: SIMD4<Float>
        var c0: SIMD4<Float>
        var c1: SIMD4<Float>
        var wave: SIMD4<Float>
        var extra: SIMD4<Float>
    }

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipe: MTLRenderPipelineState
    private let engine: FlowFunnelEngine
    private let t0 = CACurrentMediaTime()
    /// 卡片的底色（和 SwiftUI 那边的卡一样）
    static let background: Float = 0.043

    init?(engine: FlowFunnelEngine) {
        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue(), let lib = dev.makeDefaultLibrary(),
              let vf = lib.makeFunction(name: "ff_vertex"), let ff = lib.makeFunction(name: "ff_fragment") else { return nil }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = vf
        d.fragmentFunction = ff
        d.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let p = try? dev.makeRenderPipelineState(descriptor: d) else { return nil }
        device = dev
        queue = q
        pipe = p
        self.engine = engine
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard engine.visible, let drawable = view.currentDrawable, let rpd = view.currentRenderPassDescriptor,
              let cb = queue.makeCommandBuffer() else { return }
        let now = CACurrentMediaTime()
        let s = engine.sample(now)
        let t = now - t0
        let scale = Float(view.contentScaleFactor)
        let reduce = engine.reduceMotion
        let w = Float(view.drawableSize.width), h = Float(view.drawableSize.height)
        var U = Uniforms(
            size: SIMD4(w, h, 3.6 * scale, scale),
            heights: s.heights,
            c0: SIMD4(Float(s.primary.x), Float(s.primary.y), Float(s.primary.z), 1),
            c1: SIMD4(Float(s.secondary.x), Float(s.secondary.y), Float(s.secondary.z), 1),
            wave: SIMD4(Float(FlowFunnelEngine.wavePosition(t)), Float(reduce ? s.wave * 0.4 : s.wave), Float(t), reduce ? 0.35 : 1),
            extra: SIMD4(Float(s.appear), reduce ? 1 : 0, Self.background, Float(s.progress))
        )
        rpd.colorAttachments[0].loadAction = .dontCare
        if let e = cb.makeRenderCommandEncoder(descriptor: rpd) {
            e.setRenderPipelineState(pipe)
            e.setFragmentBytes(&U, length: MemoryLayout<Uniforms>.stride, index: 0)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            e.endEncoding()
        }
        cb.present(drawable)
        cb.commit()
    }
}

/// SwiftUI 里的那块 Metal 画布（漏斗那一块；字都在 SwiftUI 那边）
struct FlowFunnelCanvas: UIViewRepresentable {
    let engine: FlowFunnelEngine
    var active: Bool

    final class Coordinator { var renderer: FlowFunnelRenderer? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MTKView {
        let v = MTKView()
        v.colorPixelFormat = .bgra8Unorm
        v.framebufferOnly = true
        // 旧机型（改进兼容性那一档）30 帧就够顺，省电省发热
        v.preferredFramesPerSecond = Compat.legacyDevice ? 30 : 60
        v.isOpaque = true
        let bg = Double(FlowFunnelRenderer.background)
        v.backgroundColor = UIColor(white: bg, alpha: 1)
        v.clearColor = MTLClearColor(red: bg, green: bg, blue: bg, alpha: 1)
        v.contentScaleFactor = min(UIScreen.main.scale, 2)
        if let r = FlowFunnelRenderer(engine: engine) {
            v.device = r.device
            v.delegate = r
            context.coordinator.renderer = r
        } else {
            v.isPaused = true
        }
        v.isPaused = !active
        return v
    }

    func updateUIView(_ v: MTKView, context: Context) {
        if context.coordinator.renderer != nil { v.isPaused = !active }
        engine.visible = active
    }

    static func dismantleUIView(_ v: MTKView, coordinator: Coordinator) {
        v.isPaused = true
        v.delegate = nil
        coordinator.renderer = nil
    }
}
