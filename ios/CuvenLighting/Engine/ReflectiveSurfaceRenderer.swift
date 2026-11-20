import CoreGraphics
import Foundation
import Metal
import simd

/// The control cards' material (full resolution, premultiplied, into an RGBA16F target).
///
/// Every card is one instance of a rounded-rect quad with its own parameters — frame, corner radius, press state,
/// emphasis (how glossy / how much it reflects), lit state and opacity — drawn in one instanced call.
///
/// Seamless morphing: nothing about a card's shape ever jumps. On the render clock (no per-frame SwiftUI updates):
///   · position, size and corner radius follow their targets on a critically damped spring (~0.42 s), so a relayout
///     (posture change, rotation, a row reflowing) morphs the shapes from where they were to where they go;
///   · the lit state (the lock) cross-fades; presses ease in 60 ms;
///   · cards appear by growing from 92 % and fading in, and leave by shrinking and fading out;
///   · cards that share a morph group melt into each other: when one group member goes and another arrives at the
///     same time, the newcomer starts from the union of the leaving shapes and the leaving ones stretch into the
///     newcomer while they fade (the bottom row becoming the brightness bar and back);
///   · idle: every card collapses and fades away completely; only the ambient light on the panel stays.
@MainActor
final class ReflectiveSurfaceRenderer {
    private struct CardState {
        var card: LightingCard
        var rect = SIMD4<Float>.zero
        var velocity = SIMD4<Float>.zero
        var radius: Float = 0
        var radiusVelocity: Float = 0
        var lit: Float = 0
        var press: Float = 0
        var pressTarget: Float = 0
        var presence: Float = 0
        var removing = false
        var placed = false
    }

    private let shaders: MetalShaderLibrary
    private var cards: [String: CardState] = [:]
    private var order: [String] = []
    private(set) var instances: [GPUCardInstance] = []
    private var opacity: Float = 1
    /// 1: cards shown; 0: idle (cards fade away, the ambient light stays)
    var opacityTarget: Float = 1
    /// Something changed or is still animating
    private(set) var isAnimating = true

    /// Shape spring: critically damped, settles in ~0.42 s
    private let omega: Float = 2 * .pi / 0.42

    init(shaders: MetalShaderLibrary) {
        self.shaders = shaders
    }

    func setCard(_ card: LightingCard) {
        if var s = cards[card.id] {
            guard s.card != card || s.removing else { return }
            s.card = card
            s.removing = false
            cards[card.id] = s
        } else {
            guard order.count < GPULayout.maxCards else { return }
            cards[card.id] = CardState(card: card)
            order.append(card.id)
        }
        isAnimating = true
    }

    /// The card leaves with an animation (shrinks and fades, or melts into its morph group)
    func removeCard(id: String) {
        guard var s = cards[id], !s.removing else { return }
        s.removing = true
        cards[id] = s
        isAnimating = true
    }

    func removeAll() {
        cards.removeAll()
        order.removeAll()
        isAnimating = true
    }

    func setPressed(_ pressed: Bool, id: String) {
        guard var s = cards[id] else { return }
        s.pressTarget = pressed ? 1 : 0
        cards[id] = s
        isAnimating = true
    }

    private static func valid(_ f: CGRect) -> Bool { f.width > 1 && f.height > 1 }

    private static func vec(_ f: CGRect) -> SIMD4<Float> {
        SIMD4(Float(f.minX), Float(f.minY), Float(f.width), Float(f.height))
    }

    /// Union of rects stored as x, y, w, h
    private static func union(_ a: SIMD4<Float>?, _ b: SIMD4<Float>) -> SIMD4<Float> {
        guard let a else { return b }
        let minX = min(a.x, b.x), minY = min(a.y, b.y)
        let maxX = max(a.x + a.z, b.x + b.z), maxY = max(a.y + a.w, b.y + b.w)
        return SIMD4(minX, minY, maxX - minX, maxY - minY)
    }

    /// Critically damped spring, sub-stepped so a long frame cannot overshoot
    private func spring(_ x: inout SIMD4<Float>, _ v: inout SIMD4<Float>, to target: SIMD4<Float>, dt: Float) {
        var left = dt
        while left > 0 {
            let h = min(left, 1 / 240)
            let a = omega * omega * (target - x) - 2 * omega * v
            v += a * h
            x += v * h
            left -= h
        }
    }

    private func spring(_ x: inout Float, _ v: inout Float, to target: Float, dt: Float) {
        var left = dt
        while left > 0 {
            let h = min(left, 1 / 240)
            let a = omega * omega * (target - x) - 2 * omega * v
            v += a * h
            x += v * h
            left -= h
        }
    }

    /// Advance the animations and rebuild the instance list
    func step(dt: Double) {
        let fdt = Float(min(max(dt, 0), 0.1))
        let kPress = 1 - exp(-fdt / 0.06)
        let kLit = 1 - exp(-fdt / 0.12)
        let kAppear = 1 - exp(-fdt / 0.16)
        let kOpacity = 1 - exp(-fdt / 0.22)
        var moving = false
        opacity += (opacityTarget - opacity) * kOpacity
        if abs(opacityTarget - opacity) < 0.002 { opacity = opacityTarget } else { moving = true }

        // Morph groups: where the arriving and the leaving members are
        var arriving: [String: SIMD4<Float>] = [:]
        var leaving: [String: SIMD4<Float>] = [:]
        for id in order {
            guard let s = cards[id], let g = s.card.morphGroup else { continue }
            if s.removing {
                if s.placed { leaving[g] = Self.union(leaving[g], s.rect) }
            } else if Self.valid(s.card.frame) {
                arriving[g] = Self.union(arriving[g], Self.vec(s.card.frame))
            }
        }

        var list: [GPUCardInstance] = []
        list.reserveCapacity(order.count)
        var gone: [String] = []
        for id in order {
            guard var s = cards[id] else { continue }
            var target = Self.vec(s.card.frame)
            let hasTarget = Self.valid(s.card.frame)

            if !s.placed {
                if s.removing {
                    gone.append(id)
                    continue
                }
                guard hasTarget else { continue }
                if let g = s.card.morphGroup, let from = leaving[g] {
                    // Melt out of the shapes that are leaving
                    s.rect = from
                    s.presence = 1
                } else {
                    s.rect = target
                    s.presence = 0
                }
                s.radius = Float(s.card.cornerRadius)
                s.lit = s.card.isLit ? 1 : 0
                s.placed = true
            }

            if s.removing {
                if let g = s.card.morphGroup, let into = arriving[g] { target = into } else { target = s.rect }
                s.presence += (0 - s.presence) * kAppear
                if s.presence < 0.01 {
                    gone.append(id)
                    continue
                }
                moving = true
            } else {
                s.presence += (1 - s.presence) * kAppear
                if abs(1 - s.presence) < 0.002 { s.presence = 1 } else { moving = true }
            }

            spring(&s.rect, &s.velocity, to: target, dt: fdt)
            spring(&s.radius, &s.radiusVelocity, to: Float(s.card.cornerRadius), dt: fdt)
            if simd_reduce_max(simd_abs(target - s.rect)) < 0.05, simd_reduce_max(simd_abs(s.velocity)) < 0.5 {
                s.rect = target
                s.velocity = .zero
            } else {
                moving = true
            }
            if abs(s.radius - Float(s.card.cornerRadius)) < 0.05 { s.radius = Float(s.card.cornerRadius) } else { moving = true }
            let litTarget: Float = s.card.isLit ? 1 : 0
            s.lit += (litTarget - s.lit) * kLit
            if abs(litTarget - s.lit) < 0.002 { s.lit = litTarget } else { moving = true }
            s.press += (s.pressTarget - s.press) * kPress
            if abs(s.pressTarget - s.press) < 0.002 { s.press = s.pressTarget } else { moving = true }
            cards[id] = s

            let shown = s.presence * opacity
            guard shown > 0.002, s.rect.z > 1, s.rect.w > 1 else { continue }
            let gloss = 0.55 + 0.35 * min(max(s.card.emphasis, 0), 1)
            let r = min(s.radius, min(s.rect.z, s.rect.w) / 2)
            list.append(GPUCardInstance(
                rect: s.rect,
                shape: SIMD4(r, s.press, s.card.emphasis, s.lit),
                tint: SIMD4(shown, gloss, shown, 0)))
        }
        for id in gone {
            cards.removeValue(forKey: id)
            order.removeAll { $0 == id }
        }
        instances = list
        isAnimating = moving
    }

    func encode(commandBuffer: any MTLCommandBuffer, target: any MTLTexture, uniforms: GPUFrameUniforms,
                irradiance: any MTLTexture, near: any MTLTexture, far: any MTLTexture) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = "card surfaces"
        defer { encoder.endEncoding() }
        var u = uniforms
        // The panel behind the cards: the picture's light, soft and feathered at every edge (Cinematic / Immersive)
        if let backdrop = shaders.backdrop, u.look2.y * u.material.x * u.material.y > 0.0005 {
            encoder.setRenderPipelineState(backdrop)
            encoder.setFragmentBytes(&u, length: MemoryLayout<GPUFrameUniforms>.stride, index: 0)
            encoder.setFragmentTexture(irradiance, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        guard let pipeline = shaders.surface, !instances.isEmpty else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&u, length: MemoryLayout<GPUFrameUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&u, length: MemoryLayout<GPUFrameUniforms>.stride, index: 0)
        instances.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            encoder.setVertexBytes(base, length: bytes.count, index: 1)
            encoder.setFragmentBytes(base, length: bytes.count, index: 1)
        }
        encoder.setFragmentTexture(irradiance, index: 0)
        encoder.setFragmentTexture(near, index: 1)
        encoder.setFragmentTexture(far, index: 2)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: instances.count)
    }
}
