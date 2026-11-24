import MetalKit
import simd
import SwiftUI
import UIKit

// MARK: - 详情页字标的粒子转场：Metal 那一半（着色器在 LogoParticles.metal）
//
// 用户要求（动效说明 + 参考录屏）：往下滚，头部的大字标化成细粒子，沿一条先往右鼓、再弯进左上角的弧线飞上去，
// 在顶上条里拼回小字标；往回滚原路倒回去，重新拼成大字标。整段只跟着滚动进度走：
//   0–20%   大字标跟着页面往上走、稍微缩一点（0.92），右下边开始一粒粒剥落，主字标还认得出来
//   20–65%  红、蓝的细粒子（夹几粒副标题的黄）连成一条窄的光流，拖一小截渐隐的尾巴；先往右鼓，再弯进左上角
//   65–90%  在小字标的位置拼回来：中间的主字标先到，然后上面的厂牌、下面的黄色副标题
//   90–100% 小字标已经拼齐（这一层到 1 就藏起来，换成条里的真字标；「继续播放」由调用方淡入）
// 两头都用同一张处理好的字标图（ImagePipeline.logo，和 LogoImage 显示的是同一张，含反白 / HDR），粒子的形状、颜色都从它取。
// 没有时钟：只在输入变了时画一帧（滚动停住就停在这一帧），进度不在 0…1 之间时整层藏起来、什么都不做。

/// 铺满整个详情页窗口的透明画布：头部大字标（from）化成粒子，飞进顶上条里的小字标（to）。
/// from / to 是窗口坐标（SwiftUI 的 .global）；画布自己按它在窗口里的位置换算，所以不必和窗口一样大。
/// progress：0 = 字标在头部原位，1 = 已经落进条里；只在 0 < p < 1 时画。
/// reduceMotion = true 时不画（不放粒子；调用方让两枚真字标交叉淡入淡出）。不接手势，旁白不念。
struct LogoParticleField: UIViewRepresentable {
    let image: UIImage?
    let from: CGRect
    let to: CGRect
    let progress: Double
    var reduceMotion = false

    final class Coordinator { var renderer: LogoParticleRenderer? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MTKView {
        // 能显示 HDR 的屏上字标是 HDR 的（LogoHDR：亮部最多到 SDR 白的两倍）：画布也开 EDR，不然真字标一藏起来亮的地方就暗一截
        let hdr = LogoHDR.enabled
        let format: MTLPixelFormat = hdr ? .rgba16Float : .bgra8Unorm_srgb
        let v = MTKView()
        v.colorPixelFormat = format
        v.framebufferOnly = true
        v.isOpaque = false
        v.backgroundColor = .clear
        v.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        // 按需画：输入变了才画一帧（停住就停在这一帧）
        v.isPaused = true
        v.enableSetNeedsDisplay = true
        // 这一帧和 SwiftUI 同一个事务提交：真字标藏起来的那一刻，画布上正好是同一张图，不会空一帧或叠一帧
        v.presentsWithTransaction = true
        v.isUserInteractionEnabled = false
        v.isAccessibilityElement = false
        v.accessibilityElementsHidden = true
        // 两头都要和真字标一样清楚：3 倍屏上就按 3 倍画（旧机型 2 倍，省内存）
        v.contentScaleFactor = min(UIScreen.main.scale, Compat.legacyDevice ? 2 : 3)
        v.isHidden = true
        if let r = LogoParticleRenderer(pixelFormat: format) {
            v.device = r.device
            v.delegate = r
            context.coordinator.renderer = r
        }
        if let layer = v.layer as? CAMetalLayer {
            layer.isOpaque = false
            // 着色器里的颜色都是线性的 Display P3（和字标管线一致）：HDR 时是扩展线性，SDR 时写进 sRGB 编码的画布（同一条传递函数）
            layer.colorspace = CGColorSpace(name: hdr ? CGColorSpace.extendedLinearDisplayP3 : CGColorSpace.displayP3)
            layer.wantsExtendedDynamicRangeContent = hdr
        }
        update(v, context.coordinator)
        return v
    }

    func updateUIView(_ v: MTKView, context: Context) { update(v, context.coordinator) }

    private func update(_ v: MTKView, _ c: Coordinator) {
        guard let r = c.renderer else {
            if !v.isHidden { v.isHidden = true }
            return
        }
        r.set(image: image, from: from, to: to, progress: progress, reduceMotion: reduceMotion)
        let show = r.active
        if v.isHidden == show { v.isHidden = !show }
        if !show {
            // 藏着的时候层里留的是旧的一帧：下次露出来先重画
            r.dirty = true
        } else if r.dirty {
            v.setNeedsDisplay()
        }
    }

    static func dismantleUIView(_ v: MTKView, coordinator: Coordinator) {
        v.isPaused = true
        v.delegate = nil
        coordinator.renderer = nil
    }
}

final class LogoParticleRenderer: NSObject, MTKViewDelegate {
    /// 和 LogoParticles.metal 里的 LPUniforms 一一对应
    private struct Uniforms {
        var view: SIMD4<Float>
        var src: SIMD4<Float>
        var dst: SIMD4<Float>
        var grid: SIMD4<Float>
        var path: SIMD4<Float>
        var anchor: SIMD4<Float>
        var extra: SIMD4<Float>
    }
    /// LPQuad
    private struct Quad {
        var rect: SIMD4<Float>
        var info: SIMD4<Float>
        var shadow: SIMD4<Float>
    }
    /// LPParticle
    private struct Particle {
        var cell: SIMD4<Float>
        var color: SIMD4<Float>
        var seed: SIMD4<Float>
        var shape: SIMD4<Float>
    }
    /// 由字标图算好的东西（换图、字标大小变了很多才重算）
    private struct Built {
        let texture: MTLTexture
        let cells: MTLBuffer
        let particles: MTLBuffer
        let particleCount: Int
        let cols: Int
        let rows: Int
        /// 最早落定、最晚离开的进度：这两段以外不用画那一枚字标
        let firstArrive: Float
        let lastDepart: Float
    }

    // 节奏（进度）：离开 0.012–0.62、主字标 0.65–0.80、厂牌 0.75–0.86、副标题 0.79–0.90（用户给的分段）
    private static let departSpan: (Float, Float) = (0.012, 0.62)
    private static let arriveWindows: [(Float, Float)] = [(0.65, 0.80), (0.75, 0.86), (0.79, 0.90)]
    /// 格子和粒子交接的那一小段（进度）：格子淡出 / 淡入的同时同一处的粒子淡入 / 淡出
    private static let handoff: Float = 0.012
    /// 一格多大（点，按大字标）
    private static let cellPt: CGFloat = 2.4

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let quadPipe: MTLRenderPipelineState
    private let shadowPipe: MTLRenderPipelineState
    private let dotPipe: MTLRenderPipelineState

    private var image: UIImage?
    private var builtSize = CGSize.zero
    private var built: Built?
    private var from = CGRect.zero
    private var to = CGRect.zero
    private var progress: Double = 0
    private var reduceMotion = false
    /// 输入变了、还没画
    var dirty = true

    init?(pixelFormat: MTLPixelFormat) {
        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue(), let lib = dev.makeDefaultLibrary() else { return nil }
        // 预乘 alpha 的「盖上去」：叠在页面上，和 SwiftUI 画真字标一样
        func pipe(_ v: String, _ f: String) -> MTLRenderPipelineState? {
            guard let vf = lib.makeFunction(name: v), let ff = lib.makeFunction(name: f) else { return nil }
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = vf
            d.fragmentFunction = ff
            let ca = d.colorAttachments[0]!
            ca.pixelFormat = pixelFormat
            ca.isBlendingEnabled = true
            ca.rgbBlendOperation = .add
            ca.alphaBlendOperation = .add
            ca.sourceRGBBlendFactor = .one
            ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
            ca.sourceAlphaBlendFactor = .one
            ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try? dev.makeRenderPipelineState(descriptor: d)
        }
        guard let qp = pipe("lp_quad_vertex", "lp_logo_fragment"),
              let sp = pipe("lp_quad_vertex", "lp_shadow_fragment"),
              let dp = pipe("lp_dot_vertex", "lp_dot_fragment") else { return nil }
        device = dev
        queue = q
        quadPipe = qp
        shadowPipe = sp
        dotPipe = dp
        super.init()
    }

    /// 这一帧要不要画（藏起来的时候什么都不做）
    var active: Bool {
        built != nil && !reduceMotion && progress > 0 && progress < 1
            && from.width >= 2 && from.height >= 2 && to.width >= 1 && to.height >= 1
    }

    /// SwiftUI 每次更新都会调：只在真变了时标记重画；换了图（或大字标大小变了两成五以上）才重新切格子
    func set(image: UIImage?, from: CGRect, to: CGRect, progress: Double, reduceMotion: Bool) {
        let sizeOK = from.width >= 2 && from.height >= 2
        var rebuild = image !== self.image
        if !rebuild, image != nil, sizeOK {
            if builtSize == .zero {
                rebuild = true
            } else {
                rebuild = abs(from.width - builtSize.width) > builtSize.width * 0.25
                    || abs(from.height - builtSize.height) > builtSize.height * 0.25
            }
        }
        if rebuild {
            self.image = image
            built = nil
            builtSize = .zero
            if let image, sizeOK {
                // 失败了也记下这个大小：不每帧重试
                builtSize = from.size
                built = build(image, size: from.size)
            }
            dirty = true
        }
        if from != self.from || to != self.to || progress != self.progress || reduceMotion != self.reduceMotion {
            self.from = from
            self.to = to
            self.progress = progress
            self.reduceMotion = reduceMotion
            dirty = true
        }
    }

    // MARK: 一帧

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        dirty = true
        if active { view.setNeedsDisplay() }
    }

    func draw(in view: MTKView) {
        guard active, let b = built else { return }
        let bounds = view.bounds.size
        let ds = view.drawableSize
        guard bounds.width > 0, bounds.height > 0, ds.width >= 1, ds.height >= 1,
              let drawable = view.currentDrawable, let rpd = view.currentRenderPassDescriptor,
              let cb = queue.makeCommandBuffer() else { return }
        dirty = false

        let scale = Float(ds.width / bounds.width)
        let origin = view.convert(CGPoint.zero, to: nil)
        let p = Float(progress)
        func local(_ r: CGRect) -> SIMD4<Float> {
            SIMD4(Float(r.minX - origin.x) * scale, Float(r.minY - origin.y) * scale, Float(r.width) * scale, Float(r.height) * scale)
        }
        // 0–20%：大字标跟着页面往上走的同时缩到 0.92（靠左、上下居中缩：左边距不变）
        let shrink = 1 - 0.08 * Self.smooth(p / 0.2)
        let sh = from.height * CGFloat(shrink)
        let src = local(CGRect(x: from.minX, y: from.midY - sh / 2, width: from.width * CGFloat(shrink), height: sh))
        let dst = local(to)
        // 光流的起点跟着溶解的前沿从右往左挪（右下先走，最后走的是左上）：最后几粒不用横穿整枚字标
        let fx = 0.84 - 0.40 * Self.smooth((p - 0.12) / 0.5)
        let sa = SIMD2(src.x + fx * src.z, src.y + 0.58 * src.w)
        let da = SIMD2(dst.x + 0.62 * dst.z, dst.y + 0.55 * dst.w)
        let pt = scale
        let widthPt = Float(bounds.width)
        var U = Uniforms(
            view: SIMD4(Float(ds.width), Float(ds.height), pt, p),
            src: src,
            dst: dst,
            grid: SIMD4(Float(b.cols), Float(b.rows), Self.handoff, 0.010),
            // 往右鼓：控制点偏屏宽的 9%（弧线最鼓处约屏宽的 6–8%）；中段收到原来宽度的 5%；横向抖 4 点、摆 2.5 点
            path: SIMD4(0.09 * widthPt * pt, 0.95, 4 * pt, 2.5 * pt),
            anchor: SIMD4(sa.x, sa.y, da.x, da.y),
            // 尾巴最长 14 点；刚离开散开 14 点、落定前散开 5 点；弧线至少按 40 点高算（大字标滚到很上面时也有弧度）
            extra: SIMD4(14 * pt, 14 * pt, 5 * pt, 40 * pt)
        )

        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        rpd.colorAttachments[0].storeAction = .store
        if let e = cb.makeRenderCommandEncoder(descriptor: rpd) {
            e.setFragmentBuffer(b.cells, offset: 0, index: 2)
            e.setFragmentTexture(b.texture, index: 0)
            // 1. 大字标上还没走的格子（连影子）
            if p < b.lastDepart + Self.handoff {
                drawQuad(e, shadowPipe, U, shadowQuad(src, which: 0, scale: scale, texture: b.texture))
                drawQuad(e, quadPipe, U, Quad(rect: src, info: SIMD4(0, 0, 0, 0), shadow: .zero))
            }
            // 2. 小字标上已经落定的格子（连影子）
            if p > b.firstArrive - Self.handoff {
                drawQuad(e, shadowPipe, U, shadowQuad(dst, which: 1, scale: scale, texture: b.texture))
                drawQuad(e, quadPipe, U, Quad(rect: dst, info: SIMD4(0, 1, 0, 0), shadow: .zero))
            }
            // 3. 路上的粒子：每粒一个拉长的小四边形（实例化）
            if b.particleCount > 0 {
                e.setRenderPipelineState(dotPipe)
                e.setVertexBuffer(b.particles, offset: 0, index: 0)
                e.setVertexBytes(&U, length: MemoryLayout<Uniforms>.stride, index: 1)
                e.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: b.particleCount)
            }
            e.endEncoding()
        }
        // presentsWithTransaction：排进 GPU 以后再在这个事务里交出去
        cb.commit()
        cb.waitUntilScheduled()
        drawable.present()
    }

    private func drawQuad(_ e: MTLRenderCommandEncoder, _ pipe: MTLRenderPipelineState, _ uniforms: Uniforms, _ quad: Quad) {
        var u = uniforms
        var q = quad
        e.setRenderPipelineState(pipe)
        e.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        e.setVertexBytes(&q, length: MemoryLayout<Quad>.stride, index: 1)
        e.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        e.setFragmentBytes(&q, length: MemoryLayout<Quad>.stride, index: 1)
        e.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    /// 影子：照 LogoImage 的 .shadow(黑 55%、半径 12、往下 4 点)，按这一枚字标的大小换算成 uv 和 mip 级别
    private func shadowQuad(_ rect: SIMD4<Float>, which: Float, scale: Float, texture: MTLTexture) -> Quad {
        let sigma: Float = 6 * scale, drop: Float = 4 * scale
        let w = max(rect.z, 1), h = max(rect.w, 1)
        let texelsPerSigma = sigma / w * Float(texture.width)
        let lod = min(max(log2(max(texelsPerSigma, 1)), 0), Float(max(texture.mipmapLevelCount - 1, 0)))
        return Quad(rect: rect,
                    info: SIMD4(3 * sigma + drop, which, lod, 0),
                    shadow: SIMD4(drop / h, 1.1 * sigma / w, 1.1 * sigma / h, 0.55))
    }

    private static func smooth(_ x: Float) -> Float {
        let t = min(1, max(0, x))
        return t * t * (3 - 2 * t)
    }

    // MARK: 切格子、定门槛、撒粒子（换图时在主线程上做一次）

    private func build(_ image: UIImage, size: CGSize) -> Built? {
        guard let px = Self.decode(image) else { return nil }
        let w = px.w, h = px.h

        // 贴图：线性扩展 Display P3、预乘，半精度浮点；带 mip（小字标靠它缩小，影子靠它模糊）
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: true)
        desc.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: desc) else { return nil }
        var half = [UInt16](repeating: 0, count: w * h * 4)
        px.data.withUnsafeBufferPointer { s in
            half.withUnsafeMutableBufferPointer { d in
                for i in 0..<s.count { d[i] = Self.halfBits(s[i]) }
            }
        }
        half.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                texture.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: base, bytesPerRow: w * 8)
            }
        }
        if let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: texture)
            blit.endEncoding()
            cb.commit()
        }

        // 格子：大字标上约 2.4 点一格（小字标上一点出头）
        let cols = max(12, min(200, Int((size.width / Self.cellPt).rounded())))
        let rows = max(4, min(100, Int((size.height / Self.cellPt).rounded())))
        let n = cols * rows
        var sum = [SIMD4<Float>](repeating: .zero, count: n)
        var peak = [Float](repeating: 0, count: n)
        var count = [Float](repeating: 0, count: n)
        px.data.withUnsafeBufferPointer { d in
            for y in 0..<h {
                let cy = min(rows - 1, y * rows / h)
                let rowBase = y * w * 4
                for x in 0..<w {
                    let ci = cy * cols + min(cols - 1, x * cols / w)
                    let o = rowBase + x * 4
                    let a = d[o + 3]
                    sum[ci] += SIMD4(d[o], d[o + 1], d[o + 2], a)
                    count[ci] += 1
                    if a > peak[ci] { peak[ci] = a }
                }
            }
        }
        var coverage = [Float](repeating: 0, count: n)
        for i in 0..<n where count[i] > 0 { coverage[i] = sum[i].w / count[i] }
        // 几乎全透明的格子不算（没有粒子，门槛也无所谓）
        let alive = (0..<n).filter { peak[$0] > 0.03 }

        // 分三条：中间的主字标、上面（厂牌）、下面（副标题）
        let band = Self.bands(coverage: coverage, cols: cols, rows: rows)

        // 离开：右下先走（加一点噪声），副标题晚一点走（说明里黄色只是「几粒点缀」）；按名次排成先疏后密，
        // 前 20% 的进度只走掉一成多，主字标还认得出来。
        // 名次只数有墨的格子；空格子（字和字之间、四周）跟着身边的名次走：影子按格子淡，不能一开始就没了
        let isAlive = (0..<n).map { peak[$0] > 0.03 }
        var key = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let u = (Float(i % cols) + 0.5) / Float(cols)
            let v = (Float(i / cols) + 0.5) / Float(rows)
            let late: Float = band[i] == 2 ? 0.14 : 0
            key[i] = 0.62 * u + 0.38 * v + (Self.hash(i, 1) - 0.5) * 0.10 - late
        }
        let order = (0..<n).sorted { key[$0] > key[$1] }
        var depart = [Float](repeating: 0, count: n)
        var arrive = [Float](repeating: 0, count: n)
        let (d0, d1) = Self.departSpan
        let aliveTotal = max(alive.count - 1, 1)
        var seen = 0
        for i in order {
            let q = min(1, Float(seen) / Float(aliveTotal))
            depart[i] = d0 + (d1 - d0) * powf(q, 0.55)
            if isAlive[i] { seen += 1 }
        }
        // 落定：每一条在自己的时间窗里按离开的先后排（先走先到，路上不互相超车）；至少飞 0.07
        for b in 0..<3 {
            let members = order.filter { band[$0] == b }
            let total = max(members.filter { isAlive[$0] }.count - 1, 1)
            let (a0, a1) = Self.arriveWindows[b]
            var k = 0
            for i in members {
                let q = min(1, Float(k) / Float(total))
                let a = min(a1, max(a0, a0 + (a1 - a0) * q + (Self.hash(i, 2) - 0.5) * 0.012))
                arrive[i] = min(Self.arriveWindows[2].1, max(a, depart[i] + 0.07))
                if isAlive[i] { k += 1 }
            }
        }
        let cellData = (0..<n).map { SIMD2<Float>(depart[$0], arrive[$0]) }

        // 粒子：每格一到三粒（领头那粒在格子正中，另外的在格子里随便一处、路上落后一点）；副标题只给六成的格子各一粒、小一点
        let perCell = Compat.legacyDevice ? 2 : 3
        var parts: [Particle] = []
        parts.reserveCapacity(alive.count * perCell)
        for i in alive {
            let c = i % cols, r = i / cols
            let s = sum[i]
            let a = max(s.w, 1e-6)
            let rgb = SIMD3(s.x / a, s.y / a, s.z / a)
            let opacity = min(1, coverage[i] * 1.5)
            let sub = band[i] == 2
            if sub && Self.hash(i, 9) > 0.6 { continue }
            for k in 0..<(sub ? 1 : perCell) {
                let j = i * 4 + k
                let u: Float, v: Float, size: Float, lag: Float
                if k == 0 {
                    u = (Float(c) + 0.5) / Float(cols)
                    v = (Float(r) + 0.5) / Float(rows)
                    size = (1.3 + 0.7 * Self.hash(j, 3)) * (sub ? 0.75 : 1)
                    lag = 0.15 * Self.hash(j, 4)
                } else {
                    u = (Float(c) + Self.hash(j, 5)) / Float(cols)
                    v = (Float(r) + Self.hash(j, 6)) / Float(rows)
                    size = 0.8 + 0.5 * Self.hash(j, 3)
                    lag = 0.1 + 0.5 * Self.hash(j, 4)
                }
                parts.append(Particle(
                    cell: SIMD4(u, v, depart[i], arrive[i]),
                    color: SIMD4(rgb.x, rgb.y, rgb.z, opacity * (k == 0 ? 1 : 0.8)),
                    seed: SIMD4(Self.hash(j, 7), Self.hash(j, 8), Self.hash(j, 10), Self.hash(j, 11)),
                    shape: SIMD4(size, lag, Self.hash(j, 12), 0)
                ))
            }
        }

        guard let cells = cellData.withUnsafeBytes({ raw -> MTLBuffer? in
            guard let base = raw.baseAddress else { return nil }
            return device.makeBuffer(bytes: base, length: raw.count, options: .storageModeShared)
        }) else { return nil }
        let particleBuffer: MTLBuffer?
        if parts.isEmpty {
            particleBuffer = device.makeBuffer(length: MemoryLayout<Particle>.stride, options: .storageModeShared)
        } else {
            particleBuffer = parts.withUnsafeBytes { raw -> MTLBuffer? in
                guard let base = raw.baseAddress else { return nil }
                return device.makeBuffer(bytes: base, length: raw.count, options: .storageModeShared)
            }
        }
        guard let particles = particleBuffer else { return nil }
        let firstArrive = alive.map { arrive[$0] }.min() ?? Self.arriveWindows[0].0
        let lastDepart = alive.map { depart[$0] }.max() ?? d1
        return Built(texture: texture, cells: cells, particles: particles, particleCount: parts.count,
                     cols: cols, rows: rows, firstArrive: firstArrive, lastDepart: lastDepart)
    }

    /// 每一行格子属于哪一条：0 中间的主字标，1 上面，2 下面。
    /// 先按整行的墨量找真正的空隙（厂牌和主字标之间那种），墨最多的那一段是主字标所在；
    /// 再在这一段里从最浓的那一行往上下扩，墨量掉到一半以下的就不算主字标（副标题常常和主字标挨着，但细得多）
    private static func bands(coverage: [Float], cols: Int, rows: Int) -> [Int] {
        var prof = [Float](repeating: 0, count: rows)
        for r in 0..<rows {
            var s: Float = 0
            for c in 0..<cols { s += coverage[r * cols + c] }
            prof[r] = s / Float(cols)
        }
        var sm = prof
        for r in 0..<rows {
            sm[r] = (prof[max(r - 1, 0)] + 2 * prof[r] + prof[min(r + 1, rows - 1)]) / 4
        }
        let top = sm.max() ?? 0
        var cuts: [Int] = []
        if rows >= 3, top > 0 {
            for r in 1..<(rows - 1) {
                guard sm[r] <= sm[r - 1], sm[r] <= sm[r + 1] else { continue }
                let above = sm[0..<r].max() ?? 0
                let below = sm[(r + 1)...].max() ?? 0
                let lower = min(above, below)
                if sm[r] < 0.6 * lower, lower > 0.08 * top, cuts.last.map({ r - $0 > 2 }) ?? true {
                    cuts.append(r)
                }
            }
        }
        let edges = [0] + cuts + [rows]
        var mainA = 0, mainB = rows, best: Float = -1
        for k in 0..<(edges.count - 1) {
            let a = edges[k], b = edges[k + 1]
            guard b > a else { continue }
            let mass = prof[a..<b].reduce(0, +)
            if mass > best { best = mass; mainA = a; mainB = b }
        }
        var pk = mainA
        for r in mainA..<mainB where sm[r] > sm[pk] { pk = r }
        if sm[pk] > 0 {
            let cutoff = 0.45 * sm[pk]
            var lo = pk, hi = pk + 1
            while lo > mainA, sm[lo - 1] >= cutoff { lo -= 1 }
            while hi < mainB, sm[hi] >= cutoff { hi += 1 }
            mainA = lo
            mainB = hi
        }
        var band = [Int](repeating: 0, count: cols * rows)
        for r in 0..<rows {
            let b = r < mainA ? 1 : (r >= mainB ? 2 : 0)
            for c in 0..<cols { band[r * cols + c] = b }
        }
        return band
    }

    /// 字标图 → 线性扩展 Display P3、预乘的浮点 RGBA（第一行是最上面一行）。HDR 字标的亮部（> 1）原样留着。
    /// 浮点的画布建不起来就退回 8 位 Display P3（和 LogoHDR 同一种），自己换成线性
    private static func decode(_ image: UIImage) -> (data: [Float], w: Int, h: Int)? {
        guard let cg = image.cgImage, cg.width > 0, cg.height > 0 else { return nil }
        let k = min(1.0, 1024.0 / Double(max(cg.width, cg.height)))
        let w = max(1, Int((Double(cg.width) * k).rounded()))
        let h = max(1, Int((Double(cg.height) * k).rounded()))
        let count = w * h * 4
        var data = [Float](repeating: 0, count: count)
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        if let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) {
            let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            let ok: Bool = data.withUnsafeMutableBytes { buf in
                guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 32, bytesPerRow: w * 16,
                                          space: space, bitmapInfo: info) else { return false }
                ctx.interpolationQuality = .high
                ctx.draw(cg, in: rect)
                return true
            }
            if ok { return (data, w, h) }
        }
        guard let p3 = CGColorSpace(name: CGColorSpace.displayP3) else { return nil }
        var bytes = [UInt8](repeating: 0, count: count)
        let ok8: Bool = bytes.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: p3, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(cg, in: rect)
            return true
        }
        guard ok8 else { return nil }
        for i in stride(from: 0, to: count, by: 4) {
            let a8 = bytes[i + 3]
            guard a8 > 0 else { continue }
            let a = Float(a8) / 255
            for ch in 0..<3 {
                // 8 位的预乘是在伽马空间里做的：先除回去，换成线性，再在线性里预乘
                let v = min(1, Float(bytes[i + ch]) / 255 / a)
                let lin = v <= 0.04045 ? v / 12.92 : powf((v + 0.055) / 1.055, 2.4)
                data[i + ch] = lin * a
            }
            data[i + 3] = a
        }
        return (data, w, h)
    }

    /// 固定的整数哈希 → 0…1：同一枚字标每次切出来的门槛、抖动都一样（倒着滚原路回去）
    private static func hash(_ i: Int, _ salt: UInt32) -> Float {
        var x = UInt32(truncatingIfNeeded: i) &* 0x9E37_79B1 &+ salt &* 0x85EB_CA77
        x ^= x >> 16
        x = x &* 0x7FEB_352D
        x ^= x >> 15
        x = x &* 0x846C_A68B
        x ^= x >> 16
        return Float(x >> 8) / 16_777_216
    }

    /// 32 位浮点 → 16 位浮点的位（和 LogoHDR.halfBits 一样：四舍五入；太小的当 0，超出范围的取最大的有限值）
    private static func halfBits(_ value: Float) -> UInt16 {
        let x = value.bitPattern
        let sign = UInt16(truncatingIfNeeded: (x >> 16) & 0x8000)
        let e = Int((x >> 23) & 0xFF) - 127 + 15
        if e <= 0 { return sign }
        if e >= 31 { return sign | 0x7BFF }
        var mant = x & 0x7F_FFFF
        var exp = UInt32(e)
        mant += 0x1000
        if mant & 0x80_0000 != 0 {
            mant = 0
            exp += 1
            if exp >= 31 { return sign | 0x7BFF }
        }
        return sign | UInt16(truncatingIfNeeded: (exp << 10) | (mant >> 13))
    }
}
