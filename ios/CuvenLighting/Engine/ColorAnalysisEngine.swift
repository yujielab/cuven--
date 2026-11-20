import Foundation
import Metal
import simd

/// GPU analysis of the video: light map, scene statistics, temporal smoothing, blur levels, light sources.
///
/// Per lighting tick (30 Hz by default), all on the GPU, in one command buffer with the rest of the frame:
///   1. cuven_sampleVideo      frame texture → raw 64 × 36 light map (linear, bright-weighted)
///   2. cuven_analyzeScene     16 × 9 cell colours, scene-change value, frame averages
///   3. cuven_temporalBlend    raw + previous smoothed → smoothed (ping-pong; adaptive time constant)
///   4. cuven_gaussianBlur ×4  smoothed → near (σ 1.5) → far (σ 4.5)
///   5. cuven_selectLights     smoothed → up to four tracked light sources
/// The only CPU↔GPU traffic is a 2.3 KB shared buffer the lab reads a few times a second for its colour swatches.
@MainActor
final class ColorAnalysisEngine {
    private let shaders: MetalShaderLibrary
    private let pool: TexturePool
    private(set) var raw: (any MTLTexture)?
    private var smoothed: [any MTLTexture] = []
    private var smoothedIndex = 0
    private var blurScratch: (any MTLTexture)?
    private(set) var near: (any MTLTexture)?
    private(set) var far: (any MTLTexture)?
    /// cells[0…143] this frame, [144…287] previous (shared: the lab reads it back)
    let cells: any MTLBuffer
    /// CuvenSceneState (shared: GPU-written, CPU-read for the lab)
    let scene: any MTLBuffer
    /// Has analysed at least one frame since the last reset
    private(set) var hasData = false

    var smoothedMap: (any MTLTexture)? { smoothed.isEmpty ? nil : smoothed[smoothedIndex] }

    init?(shaders: MetalShaderLibrary, pool: TexturePool) {
        self.shaders = shaders
        self.pool = pool
        let device = shaders.device
        guard let cells = device.makeBuffer(length: GPULayout.cellsBytes, options: .storageModeShared),
              let scene = device.makeBuffer(length: GPULayout.sceneStateBytes, options: .storageModeShared) else { return nil }
        cells.label = "lighting cells"
        scene.label = "lighting scene"
        self.cells = cells
        self.scene = scene
        let w = GPULayout.lightmapWidth, h = GPULayout.lightmapHeight
        // renderTarget: a pooled texture is cleared once with an empty render pass before first use
        let usage: MTLTextureUsage = [.shaderRead, .shaderWrite, .renderTarget]
        let f = MetalShaderLibrary.offscreenFormat
        raw = pool.make(width: w, height: h, format: f, usage: usage, label: "lightmap raw")
        smoothed = [
            pool.make(width: w, height: h, format: f, usage: usage, label: "lightmap smoothed A"),
            pool.make(width: w, height: h, format: f, usage: usage, label: "lightmap smoothed B"),
        ].compactMap { $0 }
        blurScratch = pool.make(width: w, height: h, format: f, usage: usage, label: "lightmap blur scratch")
        near = pool.make(width: w, height: h, format: f, usage: usage, label: "lightmap near")
        far = pool.make(width: w, height: h, format: f, usage: usage, label: "lightmap far")
        guard raw != nil, smoothed.count == 2, blurScratch != nil, near != nil, far != nil else { return nil }
        reset()
    }

    /// Back to black: a new source fades its light in from nothing
    func reset() {
        memset(cells.contents(), 0, cells.length)
        memset(scene.contents(), 0, scene.length)
        hasData = false
        needsClear = true
    }

    private var needsClear = true

    /// Encode the whole analysis for one video frame
    func encode(frame: any MTLTexture, into commandBuffer: any MTLCommandBuffer, uniforms: GPUFrameUniforms) {
        guard let sample = shaders.sampleVideo, let analyze = shaders.analyzeScene, let temporal = shaders.temporalBlend,
              let blur = shaders.gaussianBlur, let select = shaders.selectLights,
              let raw, let scratch = blurScratch, let near, let far, smoothed.count == 2 else { return }
        if needsClear { clearMaps(commandBuffer) }

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.label = "lighting analysis"
        var u = uniforms
        let mapGrid = MTLSize(width: GPULayout.lightmapWidth, height: GPULayout.lightmapHeight, depth: 1)

        // 1. video → raw light map
        encoder.setComputePipelineState(sample)
        encoder.setTexture(frame, index: 0)
        encoder.setTexture(raw, index: 1)
        dispatch(encoder, sample, grid: mapGrid)

        // 2. scene statistics (one threadgroup, one thread per cell)
        encoder.setComputePipelineState(analyze)
        encoder.setTexture(raw, index: 0)
        encoder.setBuffer(cells, offset: 0, index: 0)
        encoder.setBuffer(scene, offset: 0, index: 1)
        encoder.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: 16, height: 9, depth: 1))

        // 3. temporal smoothing (ping-pong)
        let previous = smoothed[smoothedIndex]
        smoothedIndex ^= 1
        let current = smoothed[smoothedIndex]
        encoder.setComputePipelineState(temporal)
        encoder.setTexture(raw, index: 0)
        encoder.setTexture(previous, index: 1)
        encoder.setTexture(current, index: 2)
        encoder.setBuffer(scene, offset: 0, index: 1)
        encoder.setBytes(&u, length: MemoryLayout<GPUFrameUniforms>.stride, index: 2)
        dispatch(encoder, temporal, grid: mapGrid)

        // 4. blur: smoothed → near; near → far
        blurPass(encoder, blur, source: current, scratch: scratch, output: near, sigma: 1.5, grid: mapGrid)
        blurPass(encoder, blur, source: near, scratch: scratch, output: far, sigma: 4.5, grid: mapGrid)

        // 5. light sources from the smoothed map
        encoder.setComputePipelineState(select)
        encoder.setTexture(current, index: 0)
        encoder.setBuffer(scene, offset: 0, index: 1)
        encoder.setBytes(&u, length: MemoryLayout<GPUFrameUniforms>.stride, index: 2)
        encoder.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: 16, height: 9, depth: 1))
        encoder.endEncoding()
        hasData = true
    }

    private func blurPass(_ encoder: any MTLComputeCommandEncoder, _ pipeline: any MTLComputePipelineState,
                          source: any MTLTexture, scratch: any MTLTexture, output: any MTLTexture, sigma: Float, grid: MTLSize) {
        encoder.setComputePipelineState(pipeline)
        var horizontal = SIMD4<Float>(1, 0, sigma, 0)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(scratch, index: 1)
        encoder.setBytes(&horizontal, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        dispatch(encoder, pipeline, grid: grid)
        var vertical = SIMD4<Float>(0, 1, sigma, 0)
        encoder.setTexture(scratch, index: 0)
        encoder.setTexture(output, index: 1)
        encoder.setBytes(&vertical, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        dispatch(encoder, pipeline, grid: grid)
    }

    /// The pooled textures may hold another session's light: clear them once on the GPU
    private func clearMaps(_ commandBuffer: any MTLCommandBuffer) {
        for t in [raw, near, far, blurScratch].compactMap({ $0 }) + smoothed {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = t
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            pass.colorAttachments[0].storeAction = .store
            commandBuffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
        }
        needsClear = false
    }

    /// What the analysis saw, for the lab (CPU read of shared memory; called from a completion handler)
    nonisolated static func palette(cells: UnsafeRawPointer, scene: UnsafeRawPointer) -> SampledPalette {
        let c = cells.bindMemory(to: SIMD4<Float>.self, capacity: 288)
        let s = scene.bindMemory(to: SIMD4<Float>.self, capacity: 10)
        let cellColors = (0..<GPULayout.cellCount).map { c[$0] }
        var lights: [SampledLight] = []
        for i in 0..<GPULayout.maxLights {
            let position = s[2 + i * 2]
            let color = s[3 + i * 2]
            guard color.w > 0.01 else { continue }
            lights.append(SampledLight(position: SIMD2(position.x, position.y), radius: position.z, intensity: position.w,
                                       color: SIMD3(color.x, color.y, color.z), presence: color.w))
        }
        return SampledPalette(cells: cellColors, average: s[0], sceneChange: s[1].x, lights: lights)
    }

    func release() {
        for t in [raw, near, far, blurScratch] { pool.recycle(t) }
        for t in smoothed { pool.recycle(t) }
        raw = nil
        near = nil
        far = nil
        blurScratch = nil
        smoothed = []
    }
}

/// Dispatch a 2D grid with threadgroups sized for the pipeline (non-uniform threadgroups: Apple GPUs)
@MainActor
func dispatch(_ encoder: any MTLComputeCommandEncoder, _ pipeline: any MTLComputePipelineState, grid: MTLSize) {
    let w = pipeline.threadExecutionWidth
    let h = max(1, pipeline.maxTotalThreadsPerThreadgroup / w)
    encoder.dispatchThreads(grid, threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
}
