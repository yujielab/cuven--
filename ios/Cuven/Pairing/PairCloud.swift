import SwiftUI
import MetalKit
import Accelerate

// MARK: - 粒子云（显示的那一边，GPU）
//
// 照着 Apple 配对时那团粒子云的样子（录屏量出来的：球壳边上密、外面一圈雾、8 秒一折一松、慢慢转），但码是我们自己的（PairCodec）。
// 几万个粒子全在显存里，每帧一步朗之万（PairShaders.metal 的 pair_step）：分布始终是码对应的 ρ，相机读得出；
// 再加一项沿等密度线的流动，丝在「流」但不改分布。和网页版（web/pair.js）同一套参数。

final class PairCloudRenderer: NSObject, MTKViewDelegate {
    private struct StepParams { var eps: Float; var swirl: Float; var frame: Float; var ext: Float; var n: UInt32 }
    private struct DrawParams { var rot: Float; var scale: Float; var size: Float; var ext: Float; var breath: Float
                                var aspect: SIMD2<Float>; var light: SIMD3<Float>; var deep: SIMD3<Float> }

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let step: MTLComputePipelineState
    private let draw: MTLRenderPipelineState
    private let n: Int
    private let G = 192
    private var particles: MTLBuffer
    private var field: MTLTexture?
    private var frame: Int = 0
    private let t0 = CACurrentMediaTime()
    var dark: Bool

    init?(particles count: Int = 50_000, dark: Bool = true, pixelFormat: MTLPixelFormat = .bgra8Unorm) {
        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue(), let lib = dev.makeDefaultLibrary(),
              let fs = lib.makeFunction(name: "pair_step"), let st = try? dev.makeComputePipelineState(function: fs),
              let buf = dev.makeBuffer(length: count * MemoryLayout<SIMD2<Float>>.stride, options: .storageModeShared) else { return nil }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: "pair_vertex")
        d.fragmentFunction = lib.makeFunction(name: "pair_fragment")
        d.colorAttachments[0].pixelFormat = pixelFormat
        d.colorAttachments[0].isBlendingEnabled = true
        d.colorAttachments[0].rgbBlendOperation = .add
        d.colorAttachments[0].alphaBlendOperation = .add
        d.colorAttachments[0].sourceRGBBlendFactor = .one
        d.colorAttachments[0].sourceAlphaBlendFactor = .one
        d.colorAttachments[0].destinationRGBBlendFactor = dark ? .one : .oneMinusSourceAlpha
        d.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let rp = try? dev.makeRenderPipelineState(descriptor: d) else { return nil }
        device = dev; queue = q; step = st; draw = rp; n = count; particles = buf; self.dark = dark
        super.init()
    }

    /// 换一团码：算密度网格 → 场纹理（ρ/ρmax、∇log ρ）→ 粒子按 ρ 撒好（不用等它流到位）
    func setCode(id: UInt32, secret: UInt32, spec: PairSpec) {
        let b = PairCodec.cellSigns(id: id, secret: secret, spec: spec)
        let rho = PairCodec.densityGrid(b, size: G, spec: spec)
        let maxv = rho.max() ?? 1
        let cell = Float(2 * PairCodec.ext / Double(G))
        var tex = [Float](repeating: 0, count: G * G * 4)
        func lr(_ i: Int, _ j: Int) -> Float { log(max(rho[min(G - 1, max(0, j)) * G + min(G - 1, max(0, i))], 1e-6)) }
        for j in 0..<G {
            for i in 0..<G {
                let k = (j * G + i) * 4
                tex[k] = rho[j * G + i] / maxv
                tex[k + 1] = (lr(i + 1, j) - lr(i - 1, j)) / (2 * cell)
                tex[k + 2] = (lr(i, j + 1) - lr(i, j - 1)) / (2 * cell)
                tex[k + 3] = 0
            }
        }
        // 16 位浮点纹理：所有 GPU 都能线性过滤（32 位的老机型不行）
        let half = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: G, height: G, mipmapped: false)
        half.usage = .shaderRead
        guard let t = device.makeTexture(descriptor: half) else { return }
        var h16 = [UInt16](repeating: 0, count: tex.count)
        tex.withUnsafeBufferPointer { src in
            h16.withUnsafeMutableBufferPointer { dst in
                var s = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: src.baseAddress!), height: 1, width: vImagePixelCount(src.count), rowBytes: src.count * 4)
                var d = vImage_Buffer(data: dst.baseAddress!, height: 1, width: vImagePixelCount(dst.count), rowBytes: dst.count * 2)
                vImageConvert_PlanarFtoPlanar16F(&s, &d, vImage_Flags(kvImageNoFlags))
            }
        }
        h16.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, G, G), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: G * 8) }
        field = t
        // 逆累积分布撒点
        var cdf = [Double](repeating: 0, count: rho.count); var acc = 0.0
        for i in 0..<rho.count { acc += Double(rho[i]); cdf[i] = acc }
        let p = particles.contents().bindMemory(to: SIMD2<Float>.self, capacity: n)
        var rng = SystemRandomNumberGenerator()
        for i in 0..<n {
            let u = Double.random(in: 0..<acc, using: &rng)
            var lo = 0, hi = rho.count - 1
            while lo < hi { let mid = (lo + hi) / 2; if cdf[mid] < u { lo = mid + 1 } else { hi = mid } }
            let x = -Float(PairCodec.ext) + (Float(lo % G) + Float.random(in: 0..<1, using: &rng)) * cell
            let y = -Float(PairCodec.ext) + (Float(lo / G) + Float.random(in: 0..<1, using: &rng)) * cell
            p[i] = SIMD2(x, y)
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let rpd = view.currentRenderPassDescriptor, let drawable = view.currentDrawable else { return }
        let t = Float(CACurrentMediaTime() - t0)
        encode(target: rpd, size: view.drawableSize, time: t, scale: Float(view.contentScaleFactor))
        if let cb = lastCB { cb.present(drawable); cb.commit() }
    }

    private var lastCB: MTLCommandBuffer?

    /// 一帧：朗之万一步 + 画点（drawable 或者离屏纹理）
    @discardableResult
    func encode(target rpd: MTLRenderPassDescriptor, size: CGSize, time t: Float, scale: Float, commit: Bool = false) -> MTLCommandBuffer? {
        guard let field, let cb = queue.makeCommandBuffer() else { lastCB = nil; return nil }
        let breath = 0.5 + 0.5 * cos(t * 2 * .pi / 8)                          // 8 秒一次：丝聚拢、散开
        if let ce = cb.makeComputeCommandEncoder() {
            var sp = StepParams(eps: 1.6e-5, swirl: 18 + 22 * breath, frame: Float(frame % 100_000) * 0.618, ext: Float(PairCodec.ext), n: UInt32(n))
            frame += 1
            ce.setComputePipelineState(step)
            ce.setBuffer(particles, offset: 0, index: 0)
            ce.setBytes(&sp, length: MemoryLayout<StepParams>.stride, index: 1)
            ce.setTexture(field, index: 0)
            ce.dispatchThreads(MTLSize(width: n, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
            ce.endEncoding()
        }
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        if let re = cb.makeRenderCommandEncoder(descriptor: rpd) {
            let w = Float(size.width), h = Float(size.height)
            var dp = DrawParams(rot: t * 0.06, scale: 0.60, size: max(1.4, 1.3 * scale) * (min(w, h) / 600 + 0.6), ext: Float(PairCodec.ext),
                                breath: 0.85 + 0.15 * breath, aspect: SIMD2(min(1, h / max(w, 1)), min(1, w / max(h, 1))),
                                light: dark ? SIMD3(0.16, 0.42, 0.85) : SIMD3(0.47, 0.75, 0.96),
                                deep: dark ? SIMD3(0.35, 0.65, 1.0) : SIMD3(0.12, 0.43, 0.90))
            re.setRenderPipelineState(draw)
            re.setVertexBuffer(particles, offset: 0, index: 0)
            re.setVertexBytes(&dp, length: MemoryLayout<DrawParams>.stride, index: 1)
            re.setVertexTexture(field, index: 0)
            re.setFragmentBytes(&dp, length: MemoryLayout<DrawParams>.stride, index: 1)
            re.drawPrimitives(type: .point, vertexStart: 0, vertexCount: n)
            re.endEncoding()
        }
        lastCB = cb
        if commit { cb.commit() }
        return cb
    }

    /// 离屏画一帧（自检用）：先空跑几步，再画到 side × side 的纹理上，读回 BGRA 像素（预乘过的、透明底）
    func renderOffscreen(side: Int, warmup: Int = 30, time: Float = 2) -> [UInt8]? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: side, height: side, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: d) else { return nil }
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = tex
        rpd.colorAttachments[0].storeAction = .store
        var last: MTLCommandBuffer?
        for i in 0..<warmup { last = encode(target: rpd, size: CGSize(width: side, height: side), time: time + Float(i) / 60, scale: 1, commit: true) }
        last?.waitUntilCompleted()
        var px = [UInt8](repeating: 0, count: side * side * 4)
        px.withUnsafeMutableBytes { tex.getBytes($0.baseAddress!, bytesPerRow: side * 4, from: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0) }
        return px
    }
}

/// SwiftUI 里的粒子云：给码就显示，不给码不画
struct PairCloudView: UIViewRepresentable {
    let id: UInt32?
    let secret: UInt32?
    var dark = true

    final class Coordinator { var renderer: PairCloudRenderer?; var code: (UInt32, UInt32)? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MTKView {
        let v = MTKView()
        v.isOpaque = false
        v.backgroundColor = .clear
        v.colorPixelFormat = .bgra8Unorm
        v.preferredFramesPerSecond = 60
        v.framebufferOnly = true
        if let r = PairCloudRenderer(dark: dark) {
            v.device = r.device
            v.delegate = r
            context.coordinator.renderer = r
        }
        update(v, context.coordinator)
        return v
    }

    func updateUIView(_ v: MTKView, context: Context) { update(v, context.coordinator) }

    private func update(_ v: MTKView, _ c: Coordinator) {
        guard let id, let secret, let spec = PairSpec.shared, let r = c.renderer else { v.isPaused = true; return }
        if c.code?.0 != id || c.code?.1 != secret {
            c.code = (id, secret)
            r.setCode(id: id, secret: secret, spec: spec)
        }
        v.isPaused = false
    }
}
