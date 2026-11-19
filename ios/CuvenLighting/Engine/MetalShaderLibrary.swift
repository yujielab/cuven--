import CoreVideo
import Foundation
import Metal
import os

let lightingLog = Logger(subsystem: "us.cuven.tv", category: "lighting")

/// The Metal device, command queue, the framework's shader library and every pipeline state, built once.
/// Every pipeline is created up front: a shader that fails to compile or link is reported here (and in the lab's
/// diagnostics) instead of surfacing as a black frame later.
@MainActor
public final class MetalShaderLibrary {
    /// One per process; nil when the device has no Metal (never on supported iPhones / iPads)
    public static let shared: MetalShaderLibrary? = MetalShaderLibrary()

    public let device: any MTLDevice
    let queue: any MTLCommandQueue
    let textureCache: CVMetalTextureCache
    /// Pipelines that failed (empty on a healthy build)
    public private(set) var failures: [String] = []

    let sampleVideo: (any MTLComputePipelineState)?
    let analyzeScene: (any MTLComputePipelineState)?
    let selectLights: (any MTLComputePipelineState)?
    let temporalBlend: (any MTLComputePipelineState)?
    let gaussianBlur: (any MTLComputePipelineState)?
    let projectIrradiance: (any MTLComputePipelineState)?
    let surface: (any MTLRenderPipelineState)?
    let backdrop: (any MTLRenderPipelineState)?
    let specular: (any MTLRenderPipelineState)?
    let composite: (any MTLRenderPipelineState)?

    static let offscreenFormat: MTLPixelFormat = .rgba16Float
    static let drawableFormat: MTLPixelFormat = .bgra8Unorm

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            lightingLog.error("no Metal device")
            return nil
        }
        queue.label = "Cuven lighting"
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess, let cache else {
            lightingLog.error("CVMetalTextureCache unavailable")
            return nil
        }
        let library: (any MTLLibrary)?
        do {
            library = try device.makeDefaultLibrary(bundle: Bundle(for: MetalShaderLibrary.self))
        } catch {
            lightingLog.error("shader library: \(error.localizedDescription, privacy: .public)")
            library = nil
        }
        self.device = device
        self.queue = queue
        self.textureCache = cache
        GPULayout.check()

        var failures: [String] = []
        func kernel(_ name: String) -> (any MTLComputePipelineState)? {
            guard let library, let function = library.makeFunction(name: name) else {
                failures.append("\(name): missing")
                return nil
            }
            do {
                return try device.makeComputePipelineState(function: function)
            } catch {
                failures.append("\(name): \(error.localizedDescription)")
                return nil
            }
        }
        func render(_ label: String, vertex: String, fragment: String, format: MTLPixelFormat,
                    blend: (MTLBlendFactor, MTLBlendFactor)?) -> (any MTLRenderPipelineState)? {
            guard let library, let v = library.makeFunction(name: vertex), let f = library.makeFunction(name: fragment) else {
                failures.append("\(label): missing function")
                return nil
            }
            let d = MTLRenderPipelineDescriptor()
            d.label = label
            d.vertexFunction = v
            d.fragmentFunction = f
            let attachment = d.colorAttachments[0]
            attachment?.pixelFormat = format
            if let blend {
                attachment?.isBlendingEnabled = true
                attachment?.rgbBlendOperation = .add
                attachment?.alphaBlendOperation = .add
                attachment?.sourceRGBBlendFactor = blend.0
                attachment?.sourceAlphaBlendFactor = blend.0
                attachment?.destinationRGBBlendFactor = blend.1
                attachment?.destinationAlphaBlendFactor = blend.1
            }
            do {
                return try device.makeRenderPipelineState(descriptor: d)
            } catch {
                failures.append("\(label): \(error.localizedDescription)")
                return nil
            }
        }

        sampleVideo = kernel("cuven_sampleVideo")
        analyzeScene = kernel("cuven_analyzeScene")
        selectLights = kernel("cuven_selectLights")
        temporalBlend = kernel("cuven_temporalBlend")
        gaussianBlur = kernel("cuven_gaussianBlur")
        projectIrradiance = kernel("cuven_projectIrradiance")
        // Premultiplied "over" for the cards; additive for the highlights; the composite overwrites
        surface = render("surface", vertex: "cuven_surfaceVertex", fragment: "cuven_surfaceFragment",
                         format: Self.offscreenFormat, blend: (.one, .oneMinusSourceAlpha))
        backdrop = render("backdrop", vertex: "cuven_compositeVertex", fragment: "cuven_backdropFragment",
                          format: Self.offscreenFormat, blend: (.one, .oneMinusSourceAlpha))
        specular = render("specular", vertex: "cuven_surfaceVertex", fragment: "cuven_specularFragment",
                          format: Self.offscreenFormat, blend: (.one, .one))
        composite = render("composite", vertex: "cuven_compositeVertex", fragment: "cuven_compositeFragment",
                           format: Self.drawableFormat, blend: nil)
        self.failures = failures
        if failures.isEmpty {
            lightingLog.info("lighting pipelines ready on \(device.name, privacy: .public)")
        } else {
            lightingLog.error("lighting pipelines failed: \(failures.joined(separator: "; "), privacy: .public)")
        }
    }

    /// Everything the frame needs compiled and linked
    var isComplete: Bool { failures.isEmpty }
}

/// Reuses textures across resizes and source changes instead of allocating per frame.
/// Keyed by size, format and usage; everything is GPU-private.
@MainActor
final class TexturePool {
    private struct Key: Hashable {
        let width: Int
        let height: Int
        let format: UInt
        let usage: UInt
    }

    private let device: any MTLDevice
    private var free: [Key: [any MTLTexture]] = [:]
    private var live: [ObjectIdentifier: Key] = [:]
    private(set) var allocatedBytes = 0

    init(device: any MTLDevice) {
        self.device = device
    }

    func make(width: Int, height: Int, format: MTLPixelFormat, usage: MTLTextureUsage, label: String) -> (any MTLTexture)? {
        let key = Key(width: max(width, 1), height: max(height, 1), format: format.rawValue, usage: usage.rawValue)
        if var list = free[key], let t = list.popLast() {
            free[key] = list
            live[ObjectIdentifier(t)] = key
            t.label = label
            return t
        }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: key.width, height: key.height, mipmapped: false)
        d.usage = usage
        d.storageMode = .private
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        t.label = label
        live[ObjectIdentifier(t)] = key
        allocatedBytes += t.allocatedSize
        return t
    }

    func recycle(_ texture: (any MTLTexture)?) {
        guard let texture, let key = live.removeValue(forKey: ObjectIdentifier(texture)) else { return }
        free[key, default: []].append(texture)
    }

    /// Drop the spare textures (memory warning, background)
    func purge() {
        for list in free.values {
            for t in list { allocatedBytes -= t.allocatedSize }
        }
        free.removeAll()
    }
}
