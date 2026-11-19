import CoreGraphics
import Foundation
import Metal
import simd

/// The control cards' material (full resolution, premultiplied, into an RGBA16F target).
///
/// Every card is one instance of a rounded-rect quad with its own parameters — frame, corner radius, press state,
/// emphasis (how glossy / how much it reflects), lit state and opacity — so each card renders its own material
/// in one instanced draw. Press and idle-dim states are animated here, on the render clock, so the surface
/// responds in step with the SwiftUI symbols drawn above it without any per-frame SwiftUI updates.
@MainActor
final class ReflectiveSurfaceRenderer {
    private struct CardState {
        var card: LightingCard
        var press: Float = 0
        var pressTarget: Float = 0
    }

    private let shaders: MetalShaderLibrary
    private var cards: [String: CardState] = [:]
    private var order: [String] = []
    private(set) var instances: [GPUCardInstance] = []
    private var opacity: Float = 1
    var opacityTarget: Float = 1
    /// Something changed or is still animating
    private(set) var isAnimating = true

    init(shaders: MetalShaderLibrary) {
        self.shaders = shaders
    }

    func setCard(_ card: LightingCard) {
        if var s = cards[card.id] {
            guard s.card != card else { return }
            s.card = card
            cards[card.id] = s
        } else {
            guard order.count < GPULayout.maxCards else { return }
            cards[card.id] = CardState(card: card)
            order.append(card.id)
        }
        isAnimating = true
    }

    func removeCard(id: String) {
        guard cards.removeValue(forKey: id) != nil else { return }
        order.removeAll { $0 == id }
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

    /// Advance the animations and rebuild the instance list
    func step(dt: Double) {
        let kPress = Float(1 - exp(-dt / 0.06))
        let kOpacity = Float(1 - exp(-dt / 0.15))
        var moving = false
        opacity += (opacityTarget - opacity) * kOpacity
        if abs(opacityTarget - opacity) < 0.002 { opacity = opacityTarget } else { moving = true }

        var list: [GPUCardInstance] = []
        list.reserveCapacity(order.count)
        for id in order {
            guard var s = cards[id] else { continue }
            s.press += (s.pressTarget - s.press) * kPress
            if abs(s.pressTarget - s.press) < 0.002 { s.press = s.pressTarget } else { moving = true }
            cards[id] = s
            let f = s.card.frame
            guard f.width > 1, f.height > 1 else { continue }
            let gloss = 0.55 + 0.35 * min(max(s.card.emphasis, 0), 1)
            list.append(GPUCardInstance(
                rect: SIMD4(Float(f.minX), Float(f.minY), Float(f.width), Float(f.height)),
                shape: SIMD4(Float(s.card.cornerRadius), s.press, s.card.emphasis, s.card.isLit ? 1 : 0),
                tint: SIMD4(opacity, gloss, 0, 0)))
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
        guard let pipeline = shaders.surface, !instances.isEmpty else { return }
        var u = uniforms
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
