import MetalKit
import simd
import SwiftUI
import UIKit

// MARK: - 清除缓存的动画：Metal 那一半（着色器在 CacheDissolve.metal）
//
// 时间线（从点「清除」算起，秒；照着录屏一帧一帧量过）：
//   0.00 – 0.75  按钮变成进度胶囊（SwiftUI 那一半）；卡往上飘约一成屏高、稍微再歪一点；平时那点晃动收掉
//   0.50  卡从下沿开始化成一截闪烁的「数据」碎光（溶解前沿 0 → 1，差不多匀速，4.6 秒扫完）；碎光像自由落体那样
//         0.7–0.8 秒落进胶囊，连成一根根带颜色的细光纤
//   0.5 – 1.4  胶囊那儿先有一点点光；1.4 起光纤落到，光越来越亮（5.2 秒到顶，之后一直亮着、轻轻地呼吸）
//   1.4 – 3.3  卡转到侧对着人（只剩一条边）；3.4 – 4.5 转回正面，剩下的整块都是碎光
//   1.5+  环境光慢慢泛起来（左青蓝、中间紫、右玫瑰）；2.8+ 胶囊两边一颗颗彩色光斑；4.2+ 往上散开一片光束
//   5.1   卡化完；5.9 最后一缕落进按钮、数字走到头；6.5 全部收完（CacheDissolveEngine.duration），SwiftUI 那边换成「已清除」
// 「减弱动态效果」打开时：卡不转、不放粒子，只有前沿扫过去、光源亮一下再收。

/// SwiftUI 和渲染器之间共享的状态（都在主线程上动）
final class CacheDissolveEngine {
    static let duration: Double = 6.5
    /// 点「清除」的那一刻（CACurrentMediaTime）；nil = 还在等
    var start: CFTimeInterval?
    /// 进度胶囊正中在画面上的位置（0…1，y 向下）
    var target = CGPoint(x: 0.5, y: 0.88)
    /// 内容区正中在画面上的横向位置（0…1）：iPhone Duo 一边有一列状态栏，安全区不在屏幕正中，卡和光都对着内容区的正中
    var centerX: CGFloat = 0.5
    /// 进度胶囊多大（点）：胶囊那一圈光贴着它的形状
    var capsulePt = CGSize(width: 260, height: 46)
    var reduceMotion = false

    func elapsed(_ now: CFTimeInterval = CACurrentMediaTime()) -> Double {
        guard let start else { return 0 }
        return max(0, now - start)
    }

    /// 0…1：卡上的溶解前沿走到哪儿（录屏里量出来的：0.5 秒起步，开头稍快、之后差不多匀速，4.6 秒扫完整张卡）
    func front(_ now: CFTimeInterval = CACurrentMediaTime()) -> Double {
        guard start != nil else { return 0 }
        return pow(min(1, max(0, (elapsed(now) - 0.5) / 4.6)), 0.85)
    }

    /// 0…1：进度胶囊上的数字。录屏里是匀速走的（0.6 秒起步、5.9 秒到头）—— 等于前沿晚一个落下来的时间，数的是「已经落进按钮的」
    func progress(_ now: CFTimeInterval = CACurrentMediaTime()) -> Double {
        guard start != nil else { return 0 }
        return min(1, max(0, (elapsed(now) - 0.6) / 5.3))
    }
}

final class CacheDissolveRenderer: NSObject, MTKViewDelegate {
    private struct Uniforms {
        var viewProj: simd_float4x4
        var cardModel: simd_float4x4
        var camera: SIMD4<Float>
        var timing: SIMD4<Float>
        var target: SIMD4<Float>
        var screen: SIMD4<Float>
        var params: SIMD4<Float>
        var targetScreen: SIMD4<Float>
        var cardInfo: SIMD4<Float>
        var trail: SIMD4<Float>
        var phase: SIMD4<Float>
    }
    private struct Particle { var pos: SIMD4<Float>; var vel: SIMD4<Float>; var home: SIMD4<Float>; var orig: SIMD4<Float> }
    private struct CardVertex { var pos: SIMD4<Float>; var nrm: SIMD4<Float>; var uv: SIMD4<Float> }

    // 卡：SD 卡的比例（24 × 32），右上角切一刀
    private static let halfW: Float = 0.30, halfH: Float = 0.40, halfT: Float = 0.022, chamfer: Float = 0.085
    private static let eye = SIMD3<Float>(0, 0, 4.2)
    private static let fovY: Float = 38 * .pi / 180

    let device: MTLDevice
    private let engine: CacheDissolveEngine
    private let queue: MTLCommandQueue
    private let update: MTLComputePipelineState
    private let cardPipe: MTLRenderPipelineState
    private let linePipe: MTLRenderPipelineState
    private let trailPipe: MTLRenderPipelineState
    private let brightPipe: MTLRenderPipelineState
    private let blurPipe: MTLRenderPipelineState
    private let compositePipe: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let particles: MTLBuffer
    private let count: Int
    private let cardMesh: MTLBuffer
    private let cardVertexCount: Int
    private let frontTex: MTLTexture
    private let backTex: MTLTexture

    private var cardTex: MTLTexture?
    private var lineTex: MTLTexture?
    private var trailTex: [MTLTexture] = []
    private var trailIndex = 0
    private var brightTex: MTLTexture?
    private var blurTmp: MTLTexture?
    private var bloomA: MTLTexture?
    private var bloomB: MTLTexture?
    private var depthTex: MTLTexture?
    private var size = CGSize.zero
    /// 画布的像素 / 点（MTKView.contentScaleFactor）
    private var scale: Float = 2

    private let t0 = CACurrentMediaTime()
    private var last = CACurrentMediaTime()

    init?(engine: CacheDissolveEngine, sizeLabel: String) {
        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue(), let lib = dev.makeDefaultLibrary(),
              let kernel = lib.makeFunction(name: "cd_update"),
              let update = try? dev.makeComputePipelineState(function: kernel) else { return nil }
        self.device = dev
        self.engine = engine
        self.queue = q
        self.update = update

        func pipe(_ v: String, _ f: String, _ format: MTLPixelFormat, additive: Bool = false, depth: Bool = false) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: v)
            d.fragmentFunction = lib.makeFunction(name: f)
            let ca = d.colorAttachments[0]!
            ca.pixelFormat = format
            if additive {
                ca.isBlendingEnabled = true
                ca.rgbBlendOperation = .add
                ca.alphaBlendOperation = .add
                ca.sourceRGBBlendFactor = .one
                ca.destinationRGBBlendFactor = .one
                ca.sourceAlphaBlendFactor = .one
                ca.destinationAlphaBlendFactor = .one
            }
            if depth { d.depthAttachmentPixelFormat = .depth32Float }
            return try? dev.makeRenderPipelineState(descriptor: d)
        }
        guard let card = pipe("cd_card_vertex", "cd_card_fragment", .rgba16Float, depth: true),
              let line = pipe("cd_line_vertex", "cd_line_fragment", .rgba16Float, additive: true),
              let trail = pipe("cd_full_vertex", "cd_trail_fragment", .rgba16Float),
              let bright = pipe("cd_full_vertex", "cd_bright_fragment", .rgba16Float),
              let blur = pipe("cd_full_vertex", "cd_blur_fragment", .rgba16Float),
              let comp = pipe("cd_full_vertex", "cd_composite_fragment", .bgra8Unorm) else { return nil }
        cardPipe = card; linePipe = line; trailPipe = trail; brightPipe = bright; blurPipe = blur; compositePipe = comp

        let ds = MTLDepthStencilDescriptor()
        ds.depthCompareFunction = .less
        ds.isDepthWriteEnabled = true
        guard let depthState = dev.makeDepthStencilState(descriptor: ds) else { return nil }
        self.depthState = depthState

        // 粒子：卡正面上一列一列（同一列的点脱落以后走同一条路，连起来就是一缕光纤）。24 列：录屏里一束光大约二十来根光纤
        let n = Compat.legacyDevice ? 16_384 : 32_768
        count = n
        var rng = SplitMix(seed: 0xC0FFEE)
        let columns = 24
        var ps: [Particle] = []
        ps.reserveCapacity(n)
        for i in 0..<n {
            let col = i % columns
            let colU = (Float(col) + 0.5) / Float(columns)
            let u = min(0.999, max(0.001, colU + (rng.float() - 0.5) * 0.005))
            let v = rng.float()
            let seed = rng.float()
            let strand = (Float(col) + 0.5) / Float(columns)   // 这一缕的编号：同一列完全相同（着色器里按它取这一缕的快慢、弯法、颜色）
            ps.append(Particle(pos: SIMD4(0, 0, 0, -1), vel: SIMD4(0, 0, 0, 1), home: SIMD4(u, v, seed, strand), orig: SIMD4(0, 0, 0, 0)))
        }
        guard let pb = dev.makeBuffer(bytes: ps, length: MemoryLayout<Particle>.stride * n, options: .storageModeShared) else { return nil }
        particles = pb

        let mesh = Self.cardMesh()
        cardVertexCount = mesh.count
        guard let mb = dev.makeBuffer(bytes: mesh, length: MemoryLayout<CardVertex>.stride * mesh.count, options: .storageModeShared) else { return nil }
        cardMesh = mb

        let loader = MTKTextureLoader(device: dev)
        let opts: [MTKTextureLoader.Option: Any] = [.SRGB: false, .textureUsage: MTLTextureUsage.shaderRead.rawValue]
        guard let fimg = Self.frontImage(sizeLabel: sizeLabel).cgImage, let bimg = Self.backImage().cgImage,
              let ft = try? loader.newTexture(cgImage: fimg, options: opts),
              let bt = try? loader.newTexture(cgImage: bimg, options: opts) else { return nil }
        frontTex = ft
        backTex = bt
        super.init()
    }

    // MARK: 尺寸

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { allocate(size) }

    private func allocate(_ s: CGSize) {
        guard s.width >= 8, s.height >= 8 else { return }
        size = s
        let w = Int(s.width), h = Int(s.height)
        func tex(_ w: Int, _ h: Int, _ f: MTLPixelFormat = .rgba16Float) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: f, width: max(1, w), height: max(1, h), mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)
        }
        cardTex = tex(w, h)
        lineTex = tex(w, h)
        depthTex = tex(w, h, .depth32Float)
        trailTex = [tex(w / 2, h / 2), tex(w / 2, h / 2)].compactMap { $0 }
        brightTex = tex(w / 4, h / 4)
        blurTmp = tex(w / 4, h / 4)
        bloomA = tex(w / 4, h / 4)
        bloomB = tex(w / 4, h / 4)
        trailIndex = 0
        // 拖尾从黑的开始
        if let cb = queue.makeCommandBuffer() {
            for t in trailTex { clear(cb, t) }
            cb.commit()
        }
    }

    private func clear(_ cb: MTLCommandBuffer, _ t: MTLTexture) {
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = t
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].storeAction = .store
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        cb.makeRenderCommandEncoder(descriptor: rp)?.endEncoding()
    }

    // MARK: 一帧

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = Float(min(1.0 / 30, max(1.0 / 240, now - last)))
        last = now
        scale = Float(view.contentScaleFactor)
        if size != view.drawableSize { allocate(view.drawableSize) }
        guard let cardTex, let lineTex, let depthTex, trailTex.count == 2, let brightTex, let blurTmp, let bloomA, let bloomB,
              let drawable = view.currentDrawable, let rpd = view.currentRenderPassDescriptor,
              let cb = queue.makeCommandBuffer() else { return }

        var U = uniforms(now: now, dt: dt)

        // 1. 粒子
        if let ce = cb.makeComputeCommandEncoder() {
            ce.setComputePipelineState(update)
            ce.setBuffer(particles, offset: 0, index: 0)
            ce.setBytes(&U, length: MemoryLayout<Uniforms>.stride, index: 1)
            let tg = MTLSize(width: min(256, update.maxTotalThreadsPerThreadgroup), height: 1, depth: 1)
            ce.dispatchThreadgroups(MTLSize(width: (count + tg.width - 1) / tg.width, height: 1, depth: 1), threadsPerThreadgroup: tg)
            ce.endEncoding()
        }

        // 2. 卡（带深度）
        let cp = MTLRenderPassDescriptor()
        cp.colorAttachments[0].texture = cardTex
        cp.colorAttachments[0].loadAction = .clear
        cp.colorAttachments[0].storeAction = .store
        cp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        cp.depthAttachment.texture = depthTex
        cp.depthAttachment.loadAction = .clear
        cp.depthAttachment.storeAction = .dontCare
        cp.depthAttachment.clearDepth = 1
        if let e = cb.makeRenderCommandEncoder(descriptor: cp) {
            if U.trail.w > 0.001 {
                e.setRenderPipelineState(cardPipe)
                e.setDepthStencilState(depthState)
                e.setCullMode(.none)
                e.setVertexBuffer(cardMesh, offset: 0, index: 0)
                e.setVertexBytes(&U, length: MemoryLayout<Uniforms>.stride, index: 1)
                e.setFragmentBytes(&U, length: MemoryLayout<Uniforms>.stride, index: 1)
                e.setFragmentTexture(frontTex, index: 0)
                e.setFragmentTexture(backTex, index: 1)
                e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: cardVertexCount)
            }
            e.endEncoding()
        }

        // 3. 光线（相加）
        let lp = MTLRenderPassDescriptor()
        lp.colorAttachments[0].texture = lineTex
        lp.colorAttachments[0].loadAction = .clear
        lp.colorAttachments[0].storeAction = .store
        lp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        if let e = cb.makeRenderCommandEncoder(descriptor: lp) {
            if engine.start != nil && !engine.reduceMotion {
                e.setRenderPipelineState(linePipe)
                e.setVertexBuffer(particles, offset: 0, index: 0)
                e.setVertexBytes(&U, length: MemoryLayout<Uniforms>.stride, index: 1)
                e.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: count)
            }
            e.endEncoding()
        }

        // 4. 拖尾
        let prev = trailTex[trailIndex], next = trailTex[1 - trailIndex]
        trailIndex = 1 - trailIndex
        fullPass(cb, target: next, pipe: trailPipe) { e in
            e.setFragmentTexture(prev, index: 0)
            e.setFragmentTexture(lineTex, index: 1)
            e.setFragmentBytes(&U, length: MemoryLayout<Uniforms>.stride, index: 1)
        }

        // 5. 辉光：亮部 → 横竖两遍（窄）→ 再横竖两遍（宽）
        fullPass(cb, target: brightTex, pipe: brightPipe) { e in
            e.setFragmentTexture(lineTex, index: 0)
            e.setFragmentTexture(next, index: 1)
            e.setFragmentTexture(cardTex, index: 2)
        }
        let bw = Float(brightTex.width), bh = Float(brightTex.height)
        blur(cb, from: brightTex, to: blurTmp, step: SIMD4(1.2 / bw, 0, 0, 0))
        blur(cb, from: blurTmp, to: bloomA, step: SIMD4(0, 1.2 / bh, 0, 0))
        blur(cb, from: bloomA, to: blurTmp, step: SIMD4(4.0 / bw, 0, 0, 0))
        blur(cb, from: blurTmp, to: bloomB, step: SIMD4(0, 4.0 / bh, 0, 0))

        // 6. 合成到屏幕
        rpd.colorAttachments[0].loadAction = .dontCare
        rpd.colorAttachments[0].storeAction = .store
        if let e = cb.makeRenderCommandEncoder(descriptor: rpd) {
            e.setRenderPipelineState(compositePipe)
            e.setFragmentTexture(cardTex, index: 0)
            e.setFragmentTexture(lineTex, index: 1)
            e.setFragmentTexture(next, index: 2)
            e.setFragmentTexture(bloomA, index: 3)
            e.setFragmentTexture(bloomB, index: 4)
            e.setFragmentBytes(&U, length: MemoryLayout<Uniforms>.stride, index: 1)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            e.endEncoding()
        }
        cb.present(drawable)
        cb.commit()
    }

    private func fullPass(_ cb: MTLCommandBuffer, target: MTLTexture, pipe: MTLRenderPipelineState, bind: (MTLRenderCommandEncoder) -> Void) {
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = target
        rp.colorAttachments[0].loadAction = .dontCare
        rp.colorAttachments[0].storeAction = .store
        guard let e = cb.makeRenderCommandEncoder(descriptor: rp) else { return }
        e.setRenderPipelineState(pipe)
        bind(e)
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        e.endEncoding()
    }

    private func blur(_ cb: MTLCommandBuffer, from: MTLTexture, to: MTLTexture, step: SIMD4<Float>) {
        var st = step
        fullPass(cb, target: to, pipe: blurPipe) { e in
            e.setFragmentTexture(from, index: 0)
            e.setFragmentBytes(&st, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        }
    }

    // MARK: 这一帧的参数

    private func uniforms(now: CFTimeInterval, dt: Float) -> Uniforms {
        let t = Float(now - t0)
        let started = engine.start != nil
        let e = Float(engine.elapsed(now))
        let reduce = engine.reduceMotion
        let w = Float(max(size.width, 1)), h = Float(max(size.height, 1))
        let aspect = w / h

        // 相机
        let proj = Self.perspective(fovY: Self.fovY, aspect: aspect, near: 0.1, far: 30)
        let view = Self.lookAt(eye: Self.eye, center: .zero, up: SIMD3(0, 1, 0))
        let halfVis = Self.eye.z * tan(Self.fovY / 2)

        // 卡：浮着、慢慢转。点了「清除」：0.75 秒里往上飘约一成屏高、稍微再歪一点，平时那点晃动收掉（每次转到侧面的时刻都一样）；
        // 1.4 – 3.3 秒转到侧对着人，3.4 – 4.5 秒转回正面（参照录屏）
        let E = Double(e)
        let rise: Float = started ? Float(ramp(0, 0.75, E)) : 0
        let wobble: Float = reduce ? 0 : 1
        let calm = 1 - 0.85 * rise
        let swing: Float = started ? 1.35 * Float(ramp(1.4, 3.3, E) - ramp(3.35, 4.5, E)) : 0
        let yaw = (0.32 * sin(t * 0.47) * calm + 0.22) * wobble + swing * wobble
        let pitch = (0.10 * sin(t * 0.36) * calm - 0.10) * wobble - rise * 0.12 * wobble
        let roll = (0.05 * sin(t * 0.29) * calm - 0.06) * wobble + rise * 0.10 * wobble
        let bob = 0.035 * sin(t * 0.9) * wobble * calm
        let cardY = halfVis * (0.27 + 0.21 * rise) + bob
        let cardX = (Float(engine.centerX) * 2 - 1) * halfVis * aspect
        let model = Self.translation(SIMD3(cardX, cardY, 0)) * Self.rotationY(yaw) * Self.rotationX(pitch) * Self.rotationZ(roll)

        // 汇聚点：进度胶囊正中，落在 z = 0 那一层
        let tx = Float(engine.target.x), ty = Float(engine.target.y)
        let target = SIMD3<Float>((tx * 2 - 1) * halfVis * aspect, (1 - ty * 2) * halfVis, 0)

        let front: Float = started ? Float(engine.front(now)) * 1.16 - 0.06 : -0.2
        // 光纤：最后一缕 5.9 秒落进按钮，之后才整体变淡
        let fade: Float = started ? Float(1 - ramp(5.9, 6.5, E)) : 1
        // 收尾的画面一直留着，「已清除」那 1.3 秒里才暗下去
        let out = 1 - 0.9 * ramp(6.6, 7.5, E)
        // 光源：0.5 秒起胶囊那儿先有一点点光，1.4 秒光纤落到以后越来越亮，5.2 秒到顶；3 秒以后轻轻地呼吸（约 0.55 秒一下）
        let light: Float = started ? Float((0.10 * ramp(0.5, 1.4, E) + 0.90 * ramp(1.4, 5.2, E)) * out) : 0
        let breath = 1 + 0.12 * ramp(3.0, 3.6, E) * sin(2 * .pi * E / 0.55)
        let lightPulse: Float = reduce ? light * 0.8 : light * Float(breath)
        // 环境光：1.5 秒起慢慢泛起来，到结尾还在变浓
        let ambX = min(1, max(0, (E - 1.5) / 5.0))
        let ambient: Float = started ? Float((1 - pow(1 - ambX, 1.5)) * out) : 0
        // 收尾：下面一截被光漫过去
        let endBurst: Float = started && !reduce ? Float(ramp(5.0, 6.2, E) * out) : 0
        // 卡上的碎光那一截：一开始卡高的一成多，前沿动起来以后三成，卡转到侧面以后剩下的整块都是碎光
        let bandW: Float = started ? Float(0.13 + 0.17 * ramp(0.5, 2.0, E) + 0.8 * ramp(2.6, 3.4, E)) : 0.13
        let bokehIn: Float = started && !reduce ? Float(ramp(2.8, 4.6, E)) : 0
        let raysIn: Float = started && !reduce ? Float(ramp(4.2, 5.8, E)) : 0
        let cardFade: Float = started ? Float(1 - ramp(5.0, 5.4, E)) : 1
        let keep = Float(pow(0.6, Double(dt) * 60))
        // 进度胶囊的半高、半宽（占画面高的比例）：胶囊那一圈光贴着它
        let capHH = Float(engine.capsulePt.height) * 0.5 * scale / h
        let capHW = Float(engine.capsulePt.width) * 0.5 * scale / h

        return Uniforms(
            viewProj: proj * view,
            cardModel: model,
            camera: SIMD4(Self.eye, endBurst),
            timing: SIMD4(t, dt, front, fade),
            target: SIMD4(target, capHH),
            screen: SIMD4(w, h, 0.45 * scale, lightPulse),       // 光线半宽（像素）：屏上约 0.9 点
            params: SIMD4(0.8, 0.9, 0.035, Float(count)),    // 落到按钮约 0.8 秒、一路最多拧约 0.9 弧度、每缕横向摆动幅度
            targetScreen: SIMD4(tx, ty, aspect, t),
            cardInfo: SIMD4(Self.halfW, Self.halfH, Self.halfT, reduce ? 1 : 0),
            trail: SIMD4(keep, 1.0, ambient, cardFade),
            phase: SIMD4(bandW, bokehIn, raysIn, capHW)
        )
    }

    private func ramp(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    // MARK: 卡的网格（凸多边形挤出：正面、背面、一圈侧边）

    private static func cardMesh() -> [CardVertex] {
        let hw = halfW, hh = halfH, ht = halfT, ch = chamfer
        let poly: [SIMD2<Float>] = [SIMD2(-hw, -hh), SIMD2(hw, -hh), SIMD2(hw, hh - ch), SIMD2(hw - ch, hh), SIMD2(-hw, hh)]
        func u(_ p: SIMD2<Float>) -> Float { (p.x + hw) / (2 * hw) }
        func v(_ p: SIMD2<Float>) -> Float { (p.y + hh) / (2 * hh) }
        var out: [CardVertex] = []
        for i in 1..<(poly.count - 1) {
            for p in [poly[0], poly[i], poly[i + 1]] {
                out.append(CardVertex(pos: SIMD4(p.x, p.y, ht, 0), nrm: SIMD4(0, 0, 1, 0), uv: SIMD4(u(p), 1 - v(p), v(p), u(p))))
            }
            for p in [poly[0], poly[i + 1], poly[i]] {
                out.append(CardVertex(pos: SIMD4(p.x, p.y, -ht, 1), nrm: SIMD4(0, 0, -1, 0), uv: SIMD4(1 - u(p), 1 - v(p), v(p), u(p))))
            }
        }
        for i in 0..<poly.count {
            let a = poly[i], b = poly[(i + 1) % poly.count]
            let dir = simd_normalize(b - a)
            let n = SIMD4<Float>(dir.y, -dir.x, 0, 0)
            func vert(_ p: SIMD2<Float>, _ z: Float) -> CardVertex {
                CardVertex(pos: SIMD4(p.x, p.y, z, 2), nrm: n, uv: SIMD4(u(p), 1 - v(p), v(p), u(p)))
            }
            out += [vert(a, ht), vert(b, ht), vert(b, -ht), vert(a, ht), vert(b, -ht), vert(a, -ht)]
        }
        return out
    }

    // MARK: 卡面（Core Graphics 画好再上传）

    private static let texW: CGFloat = 600, texH: CGFloat = 800

    private static func frontImage(sizeLabel: String) -> UIImage {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: texW, height: texH), format: fmt).image { ctx in
            let g = ctx.cgContext
            // 黑色的壳，一点点上亮下暗
            let body = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: [UIColor(white: 0.13, alpha: 1).cgColor, UIColor(white: 0.07, alpha: 1).cgColor] as CFArray,
                                  locations: [0, 1])!
            g.drawLinearGradient(body, start: .zero, end: CGPoint(x: 0, y: texH), options: [])
            // 标签区
            let label = CGRect(x: 34, y: 60, width: texW - 68, height: texH - 140)
            g.setFillColor(UIColor(white: 0.055, alpha: 1).cgColor)
            g.addPath(UIBezierPath(roundedRect: label, cornerRadius: 18).cgPath)
            g.fillPath()
            g.setStrokeColor(UIColor(white: 0.22, alpha: 1).cgColor)
            g.setLineWidth(2)
            g.addPath(UIBezierPath(roundedRect: label, cornerRadius: 18).cgPath)
            g.strokePath()
            // 右边一条黄色竖带，竖着写字
            let yellow = UIColor(red: 0.98, green: 0.80, blue: 0.18, alpha: 1)
            let stripe = CGRect(x: label.maxX - 92, y: label.minY + 22, width: 64, height: label.height - 44)
            g.setFillColor(yellow.cgColor)
            g.addPath(UIBezierPath(roundedRect: stripe, cornerRadius: 8).cgPath)
            g.fillPath()
            g.saveGState()
            g.translateBy(x: stripe.midX, y: stripe.midY)
            g.rotate(by: -.pi / 2)
            let stripeText = NSAttributedString(string: "CUVEN MAX", attributes: [
                .font: UIFont.systemFont(ofSize: 40, weight: .heavy), .foregroundColor: UIColor.black, .kern: 3,
            ])
            let ss = stripeText.size()
            stripeText.draw(at: CGPoint(x: -ss.width / 2, y: -ss.height / 2))
            g.restoreGState()
            // 左上：缓存大小
            let left = label.minX + 30
            let big = NSAttributedString(string: sizeLabel.isEmpty ? "—" : sizeLabel, attributes: [
                .font: UIFont.systemFont(ofSize: sizeLabel.count > 6 ? 58 : 70, weight: .heavy), .foregroundColor: UIColor.white,
            ])
            big.draw(at: CGPoint(x: left, y: label.minY + 34))
            NSAttributedString(string: "CACHE", attributes: [
                .font: UIFont.systemFont(ofSize: 26, weight: .bold), .foregroundColor: yellow, .kern: 2,
            ]).draw(at: CGPoint(x: left + 2, y: label.minY + 122))
            // 中间：字标
            NSAttributedString(string: "Cuven", attributes: [
                .font: UIFont.systemFont(ofSize: 76, weight: .bold), .foregroundColor: UIColor.white,
            ]).draw(at: CGPoint(x: left, y: label.midY - 30))
            NSAttributedString(string: "影片资料 · 海报 · 剧照", attributes: [
                .font: UIFont.systemFont(ofSize: 24, weight: .semibold), .foregroundColor: UIColor(white: 0.72, alpha: 1),
            ]).draw(at: CGPoint(x: left + 2, y: label.midY + 60))
            // 下沿：一行小字
            NSAttributedString(string: "MEDIA CACHE CARD", attributes: [
                .font: UIFont.systemFont(ofSize: 20, weight: .semibold), .foregroundColor: UIColor(white: 0.5, alpha: 1), .kern: 3,
            ]).draw(at: CGPoint(x: left + 2, y: label.maxY - 52))
            // 左边的写保护拨片
            g.setFillColor(UIColor(white: 0.32, alpha: 1).cgColor)
            g.fill(CGRect(x: 0, y: 190, width: 14, height: 70))
        }
    }

    private static func backImage() -> UIImage {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: texW, height: texH), format: fmt).image { ctx in
            let g = ctx.cgContext
            g.setFillColor(UIColor(white: 0.08, alpha: 1).cgColor)
            g.fill(CGRect(x: 0, y: 0, width: texW, height: texH))
            // 金色触点
            g.setFillColor(UIColor(red: 0.78, green: 0.62, blue: 0.30, alpha: 1).cgColor)
            for i in 0..<8 {
                g.fill(CGRect(x: 60 + CGFloat(i) * 58, y: 40, width: 38, height: 120))
            }
        }
    }

    // MARK: 矩阵

    private static func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let y = 1 / tan(fovY * 0.5), x = y / aspect, z = far / (near - far)
        return simd_float4x4(columns: (SIMD4(x, 0, 0, 0), SIMD4(0, y, 0, 0), SIMD4(0, 0, z, -1), SIMD4(0, 0, z * near, 0)))
    }

    private static func lookAt(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let f = simd_normalize(center - eye), s = simd_normalize(simd_cross(f, up)), u = simd_cross(s, f)
        return simd_float4x4(columns: (SIMD4(s.x, u.x, -f.x, 0), SIMD4(s.y, u.y, -f.y, 0), SIMD4(s.z, u.z, -f.z, 0),
                                       SIMD4(-simd_dot(s, eye), -simd_dot(u, eye), simd_dot(f, eye), 1)))
    }

    private static func translation(_ t: SIMD3<Float>) -> simd_float4x4 {
        simd_float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(t, 1)))
    }

    private static func rotationX(_ a: Float) -> simd_float4x4 {
        let c = cos(a), s = sin(a)
        return simd_float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, c, s, 0), SIMD4(0, -s, c, 0), SIMD4(0, 0, 0, 1)))
    }

    private static func rotationY(_ a: Float) -> simd_float4x4 {
        let c = cos(a), s = sin(a)
        return simd_float4x4(columns: (SIMD4(c, 0, -s, 0), SIMD4(0, 1, 0, 0), SIMD4(s, 0, c, 0), SIMD4(0, 0, 0, 1)))
    }

    private static func rotationZ(_ a: Float) -> simd_float4x4 {
        let c = cos(a), s = sin(a)
        return simd_float4x4(columns: (SIMD4(c, s, 0, 0), SIMD4(-s, c, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1)))
    }
}

/// 固定种子的随机数（每次的粒子都一样：动画每次看起来一致）
private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func float() -> Float { Float(next() >> 40) / Float(1 << 24) }
}

/// SwiftUI 里的那块 Metal 画布（铺满）
struct CacheDissolveCanvas: UIViewRepresentable {
    let engine: CacheDissolveEngine
    let sizeLabel: String

    final class Coordinator { var renderer: CacheDissolveRenderer? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MTKView {
        let v = MTKView()
        v.colorPixelFormat = .bgra8Unorm
        v.framebufferOnly = true
        v.preferredFramesPerSecond = 60
        v.isOpaque = true
        v.backgroundColor = .black
        v.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        // 2 倍就够细了（3 倍屏上省一半多的像素，帧率稳）
        v.contentScaleFactor = min(UIScreen.main.scale, 2)
        if let r = CacheDissolveRenderer(engine: engine, sizeLabel: sizeLabel) {
            v.device = r.device
            v.delegate = r
            context.coordinator.renderer = r
        } else {
            v.isPaused = true
        }
        return v
    }

    func updateUIView(_ v: MTKView, context: Context) {}

    static func dismantleUIView(_ v: MTKView, coordinator: Coordinator) {
        v.isPaused = true
        v.delegate = nil
        coordinator.renderer = nil
    }
}
