import Foundation
import Metal

/// Specular highlights of the tracked light sources on every card (half resolution, additive RGBA16F).
/// Reads the light list straight from the GPU buffer cuven_selectLights wrote this frame — no CPU round trip.
@MainActor
final class SpecularHighlightRenderer {
    private let shaders: MetalShaderLibrary

    init(shaders: MetalShaderLibrary) {
        self.shaders = shaders
    }

    func encode(commandBuffer: any MTLCommandBuffer, target: any MTLTexture, uniforms: GPUFrameUniforms,
                instances: [GPUCardInstance], scene: any MTLBuffer, enabled: Bool) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = "specular highlights"
        defer { encoder.endEncoding() }
        guard enabled, let pipeline = shaders.specular, !instances.isEmpty else { return }
        var u = uniforms
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&u, length: MemoryLayout<GPUFrameUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&u, length: MemoryLayout<GPUFrameUniforms>.stride, index: 0)
        instances.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            encoder.setVertexBytes(base, length: bytes.count, index: 1)
            encoder.setFragmentBytes(base, length: bytes.count, index: 1)
        }
        encoder.setFragmentBuffer(scene, offset: 0, index: 2)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: instances.count)
    }
}
