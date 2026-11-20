import Foundation
import Metal

/// The high-quality final path: full-resolution surfaces + upsampled highlights → sRGB drawable, dithered.
/// Lighting itself runs at 64 × 36 (analysis), ¼ resolution (irradiance) and ½ resolution (highlights);
/// only this pass and the card material run at full resolution.
@MainActor
final class LightingCompositor {
    private let shaders: MetalShaderLibrary

    init(shaders: MetalShaderLibrary) {
        self.shaders = shaders
    }

    func encode(commandBuffer: any MTLCommandBuffer, drawable: any MTLTexture, surface: any MTLTexture, specular: any MTLTexture) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let pipeline = shaders.composite, let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = "lighting composite"
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(surface, index: 0)
        encoder.setFragmentTexture(specular, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }
}
