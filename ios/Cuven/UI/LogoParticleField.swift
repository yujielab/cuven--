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
//   90–100% 拼好的小字标从稍大一点、低一点的地方落定进条里那一格（这一层到 1 就藏起来，换成条里的真字标；「继续播放」由调用方淡入）
// 两头都用同一张处理好的字标图（ImagePipeline.logo，和 LogoImage 显示的是同一张，含反白 / HDR），粒子的形状、颜色都从它取。
// 没有时钟：只在输入变了时画一帧（滚动停住就停在这一帧），进度不在 0…1 之间时整层藏起来、什么都不做。
// 颜色：能显示 HDR 的屏上画布是扩展线性的浮点（和 LogoHDR 的字标一样）；SDR 屏上是 8 位、不带 _srgb 的 Display P3，
// 贴图和粒子的颜色也留在编码空间里预乘、叠加——和 SwiftUI / Core Animation 画真字标是同一种算法，
// 半透明的边、粒子的软边和尾巴不会比真字标亮一圈，两头交接时字标边的粗细不跳。
// 切格子、定门槛、撒粒子在后台做（LogoParticleBaker），推进详情页的那几帧主线程不卡；切好了才画，调用方可以从 onReady 知道。
// 不在转场时（停住 1.5 秒以后）画布只留 1×1：整窗大小的浮点画布一张就几十 MB，详情页一层层推进去，每一页都留着太占内存。

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
    /// 画布自己的左上角，和 from / to 在同一个 SwiftUI 坐标系里量（例如 GeometryReader 的 frame(in: .global).origin）。
    /// 不给就用 UIKit 的窗口坐标：宿主视图贴着窗口原点时两者一样，嵌在别的宿主里（弹层、iPad 侧边栏旁边那一栏）时可能差一截
    var origin: CGPoint? = nil
    /// 这一层能不能画这张字标（有 Metal、粒子已经在后台切好）：变了才回调，在主线程、这次视图更新以后。
    /// 调用方可以在 false 时不藏头部的真字标（改成交叉淡入淡出），字标不会在半路上没了
    var onReady: ((Bool) -> Void)? = nil

    final class Coordinator {
        var renderer: LogoParticleRenderer?
        /// 没有 Metal 的那一次 false 已经说过了
        var reportedNoMetal = false
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MTKView {
        // 能显示 HDR 的屏上字标是 HDR 的（LogoHDR：亮部最多到 SDR 白的两倍）：画布也开 EDR，不然真字标一藏起来亮的地方就暗一截。
        // SDR 用 8 位、不带 _srgb：和 SwiftUI 一样在编码空间里预乘、叠加（见文件头），和仓库里别的 Metal 画布一样
        let hdr = LogoHDR.enabled
        let format: MTLPixelFormat = hdr ? .rgba16Float : .bgra8Unorm
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
        if let r = LogoParticleRenderer(pixelFormat: format, hdr: hdr) {
            v.device = r.device
            v.delegate = r
            r.view = v
            context.coordinator.renderer = r
        }
        // 不在转场时画布只留 1×1（见文件头）：要画的时候 LogoParticleRenderer.sync 再撑回整窗大小
        v.autoResizeDrawable = false
        v.drawableSize = CGSize(width: 1, height: 1)
        if let layer = v.layer as? CAMetalLayer {
            layer.isOpaque = false
            // HDR：着色器里是扩展线性的 Display P3（和字标管线一致）；SDR：编码过的 Display P3（和 8 位的字标图一样）
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
            // 没有 Metal：告诉调用方这一层画不了（只说一次，放到这次视图更新以后）
            if !c.reportedNoMetal, let onReady {
                c.reportedNoMetal = true
                Task { @MainActor in onReady(false) }
            }
            return
        }
        r.onReady = onReady
        r.set(image: image, from: from, to: to, origin: origin, progress: progress, reduceMotion: reduceMotion)
        r.sync()
    }

    static func dismantleUIView(_ v: MTKView, coordinator: Coordinator) {
        v.isPaused = true
        v.delegate = nil
        coordinator.renderer?.view = nil
        coordinator.renderer = nil
    }
}

final class LogoParticleRenderer: NSObject, MTKViewDelegate {
    /// 和 LogoParticles.metal 里的 LPUniforms 一一对应（8 个 float4，128 字节）
    private struct Uniforms {
        var view: SIMD4<Float>
        var src: SIMD4<Float>
        var dst: SIMD4<Float>
        var grid: SIMD4<Float>
        var path: SIMD4<Float>
        var anchor: SIMD4<Float>
        var extra: SIMD4<Float>
        var tone: SIMD4<Float>
    }
    /// LPQuad
    private struct Quad {
        var rect: SIMD4<Float>
        var info: SIMD4<Float>
        var shadow: SIMD4<Float>
    }
    /// 由字标图切好、传上 GPU 的一套（换图、字标大小变了很多才重切）
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

    /// 格子和粒子交接的那一小段（进度）：格子淡出 / 淡入的同时同一处的粒子淡入 / 淡出
    private static let handoff: Float = 0.012

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let quadPipe: MTLRenderPipelineState
    private let shadowPipe: MTLRenderPipelineState
    private let dotPipe: MTLRenderPipelineState
    /// 画布是不是 EDR 的浮点（否则 8 位、编码空间）
    private let hdr: Bool
    /// 画在哪一块画布上（显隐、画布大小、切好以后重画都由这里管）
    weak var view: MTKView?
    /// 见 LogoParticleField.onReady
    var onReady: ((Bool) -> Void)?

    private var image: UIImage?
    private var built: Built?
    /// 最近一次按多大的字标切的（还在切的也算）：失败了也记着，不每帧重试
    private var bakedSize = CGSize.zero
    /// 每切一次加一：切完回来对不上（换了图、又按新大小切了）就扔掉
    private var generation = 0
    private var baking = false
    private var reportedReady: Bool?
    private var from = CGRect.zero
    private var to = CGRect.zero
    private var fieldOrigin: CGPoint?
    private var progress: Double = 0
    private var reduceMotion = false
    /// 输入变了、还没画
    private var dirty = true
    /// 画布露着（整窗大小）
    private var shown = false
    /// 层里留着一张整窗大小的图
    private var presented = false
    /// 缩回 1×1 时要交一帧 1×1 的空白，换掉层里那张整窗的旧图
    private var flushPending = false
    /// 每次露出 / 藏起加一：藏起来 1.5 秒后缩画布时对得上才缩（中途又露出来了就不缩）
    private var idleToken = 0

    init?(pixelFormat: MTLPixelFormat, hdr: Bool) {
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
        self.hdr = hdr
        super.init()
    }

    /// 这一帧要不要画（藏起来的时候什么都不做）
    var active: Bool {
        built != nil && !reduceMotion && progress > 0 && progress < 1
            && from.width >= 2 && from.height >= 2 && to.width >= 1 && to.height >= 1
    }

    /// SwiftUI 每次更新都会调：只在真变了时标记重画；换了图（或大字标大小变了两成五以上）才在后台重新切格子
    func set(image: UIImage?, from: CGRect, to: CGRect, origin: CGPoint?, progress: Double, reduceMotion: Bool) {
        if image !== self.image {
            // 换了图：旧的那一套不能再画，还在切的也作废
            self.image = image
            built = nil
            bakedSize = .zero
            generation &+= 1
            baking = false
            dirty = true
        }
        if let image, from.width >= 2, from.height >= 2 {
            let s = bakedSize
            let stale = s == .zero
                || abs(from.width - s.width) > s.width * 0.25
                || abs(from.height - s.height) > s.height * 0.25
            if stale { bake(image, size: from.size) }
        }
        if from != self.from || to != self.to || origin != fieldOrigin || progress != self.progress || reduceMotion != self.reduceMotion {
            self.from = from
            self.to = to
            fieldOrigin = origin
            self.progress = progress
            self.reduceMotion = reduceMotion
            dirty = true
        }
        reportReady()
    }

    /// 后台切格子；切完回到主线程建贴图、缓冲。按新大小重切时，原来那一套接着画到新的切好为止（转屏时不会空一下）
    private func bake(_ image: UIImage, size: CGSize) {
        bakedSize = size
        generation &+= 1
        baking = true
        let gen = generation
        let hdr = self.hdr
        let legacy = Compat.legacyDevice
        Task { @MainActor [weak self] in
            let baked = await Task.detached(priority: .userInitiated) {
                LogoParticleBaker.bake(image, size: size, hdr: hdr, legacy: legacy)
            }.value
            guard let self, self.generation == gen else { return }
            self.baking = false
            // 按新大小重切失败：留着原来那一套（同一张图，只是格子大小差一点）
            if let baked, let b = self.upload(baked) { self.built = b }
            self.dirty = true
            self.reportReady()
            self.sync()
        }
    }

    /// 能不能画变了才告诉调用方；第一套还在切（或者还没量到字标多大）时先不说（马上就有结果）
    private func reportReady() {
        guard let cb = onReady else { return }
        let ready = built != nil
        if ready == reportedReady { return }
        let waiting = baking || (image != nil && bakedSize == .zero)
        if reportedReady == nil, !ready, waiting { return }
        reportedReady = ready
        // 放到这次视图更新以后再说：回调里通常会改 SwiftUI 的状态
        Task { @MainActor in cb(ready) }
    }

    /// 按现在的输入定画布：要画时露出来（闲着缩成了 1×1 就先撑回整窗大小）再画；不画时藏起来，
    /// 停住一会儿（1.5 秒）还不画，才缩回 1×1 并换掉层里那张整窗的旧图，放掉那几十 MB
    /// （在顶上附近来回滚时不用每次重新分配整窗的画布）
    func sync() {
        guard let v = view else { return }
        let show = active
        if show != shown {
            shown = show
            idleToken &+= 1
            if show {
                if !v.autoResizeDrawable {
                    let b = v.bounds.size
                    let k = v.contentScaleFactor
                    if b.width > 0, b.height > 0 {
                        v.drawableSize = CGSize(width: b.width * k, height: b.height * k)
                    }
                    v.autoResizeDrawable = true
                }
                v.isHidden = false
            } else {
                v.isHidden = true
                let token = idleToken
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(1500))
                    guard let self, self.idleToken == token, !self.shown else { return }
                    self.releaseCanvas()
                }
            }
        }
        if !show {
            // 藏着的时候层里留的不是这一帧：下次露出来先重画
            dirty = true
        } else if dirty {
            v.setNeedsDisplay()
        }
    }

    /// 画布缩回 1×1；层里还留着整窗大小的那张，就交一帧 1×1 的空白换掉它（池子里大的那几张随之放掉）
    private func releaseCanvas() {
        guard let v = view, v.autoResizeDrawable || presented else { return }
        v.autoResizeDrawable = false
        v.drawableSize = CGSize(width: 1, height: 1)
        if presented {
            flushPending = true
            v.draw()
        }
    }

    // MARK: 一帧

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        dirty = true
        if active { view.setNeedsDisplay() }
    }

    func draw(in view: MTKView) {
        guard active, let b = built else {
            if flushPending {
                flushPending = false
                clear(view)
            }
            return
        }
        flushPending = false
        let bounds = view.bounds.size
        let ds = view.drawableSize
        guard bounds.width > 0, bounds.height > 0, ds.width >= 2, ds.height >= 2,
              let drawable = view.currentDrawable, let rpd = view.currentRenderPassDescriptor,
              let cb = queue.makeCommandBuffer() else { return }
        dirty = false

        let scale = Float(ds.width / bounds.width)
        // 画布的左上角：和 from / to 同一个坐标系（调用方量好了就用它，不然是 UIKit 的窗口坐标）
        let o = fieldOrigin ?? view.convert(CGPoint.zero, to: nil)
        let p = Float(progress)
        func local(_ r: CGRect) -> SIMD4<Float> {
            SIMD4(Float(r.minX - o.x) * scale, Float(r.minY - o.y) * scale, Float(r.width) * scale, Float(r.height) * scale)
        }
        // 0–20%：大字标跟着页面往上走的同时缩到 0.92（靠左、上下居中缩：左边距不变）
        let shrink = 1 - 0.08 * Self.smooth(p / 0.2)
        let sh = from.height * CGFloat(shrink)
        let src = local(CGRect(x: from.minX, y: from.midY - sh / 2, width: from.width * CGFloat(shrink), height: sh))
        // 90–100%（用户要求「落定进顶上的条」）：小字标在稍大一点（+6%）、低一点（3 点）的地方拼好，0.8 以后收进那一格；
        // 靠左缩放，左边距不变；p = 1 时正好是 to，换成条里的真字标不跳
        let settle = CGFloat(1 - Self.smooth((p - 0.8) / 0.2))
        let grow = 1 + 0.06 * settle
        let th = to.height * grow
        let dst = local(CGRect(x: to.minX, y: to.midY - th / 2 + 3 * settle, width: to.width * grow, height: th))
        // 光流的起点跟着溶解的前沿从右往左挪（右下先走，最后走的是左上）：最后几粒不用横穿整枚字标
        let fx = 0.84 - 0.40 * Self.smooth((p - 0.12) / 0.5)
        let sa = SIMD2(src.x + fx * src.z, src.y + 0.58 * src.w)
        let da = SIMD2(dst.x + 0.62 * dst.z, dst.y + 0.55 * dst.w)
        let pt = scale
        // 往右鼓：控制点偏屏宽的 9%，但不超过这段路长的 12%（路长按至少 300 点算）。iPhone 竖拿和以前一样（约 35 点），
        // iPad、横拿屏很宽、路不长，按屏宽算会甩出去一大截，不是「稍微往右鼓」
        let widthPt = Float(view.window?.bounds.width ?? bounds.width)
        let chordPt = simd_length(da - sa) / pt
        let bowPt = min(0.09 * widthPt, 0.12 * max(chordPt, 300))
        var U = Uniforms(
            view: SIMD4(Float(ds.width), Float(ds.height), pt, p),
            src: src,
            dst: dst,
            grid: SIMD4(Float(b.cols), Float(b.rows), Self.handoff, 0.010),
            // 中段收到原来宽度的 5%；横向抖 4 点、摆 2.5 点
            path: SIMD4(bowPt * pt, 0.95, 4 * pt, 2.5 * pt),
            anchor: SIMD4(sa.x, sa.y, da.x, da.y),
            // 尾巴最长 14 点；刚离开散开 14 点、落定前散开 5 点；弧线至少按 40 点高算（大字标滚到很上面时也有弧度）
            extra: SIMD4(14 * pt, 14 * pt, 5 * pt, 40 * pt),
            // 粒子路上提亮多少、闪一下提亮多少、颜色上限：编码空间里同样的亮度变化数值小一些；SDR 不超过 1（预乘的颜色不超过 alpha）
            tone: hdr ? SIMD4<Float>(0.25, 0.9, LogoHDR.peak, 0) : SIMD4<Float>(0.10, 0.35, 1, 0)
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
        presented = true
    }

    /// 交一帧 1×1 的空白（画布刚缩回 1×1）：层里不再留着整窗大小的那张
    private func clear(_ view: MTKView) {
        guard let drawable = view.currentDrawable, let rpd = view.currentRenderPassDescriptor,
              let cb = queue.makeCommandBuffer() else { return }
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        rpd.colorAttachments[0].storeAction = .store
        cb.makeRenderCommandEncoder(descriptor: rpd)?.endEncoding()
        cb.commit()
        cb.waitUntilScheduled()
        drawable.present()
        presented = false
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

    /// 后台切好的那一套传上 GPU（主线程，几百 KB 到几 MB 的拷贝）：贴图带 mip（小字标靠它缩小，影子靠它模糊）
    private func upload(_ k: LogoParticleBake) -> Built? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: k.hdr ? .rgba16Float : .rgba8Unorm,
                                                            width: k.w, height: k.h, mipmapped: true)
        // 共享存储：CPU 直接写第 0 级；renderTarget：有的 GPU 生成 mip 走的是渲染
        desc.storageMode = .shared
        desc.usage = [.shaderRead, .renderTarget]
        guard let texture = device.makeTexture(descriptor: desc) else { return nil }
        let region = MTLRegionMake2D(0, 0, k.w, k.h)
        let texels = k.w * k.h * 4
        if k.hdr {
            guard k.half.count == texels else { return nil }
            k.half.withUnsafeBytes { raw in
                if let base = raw.baseAddress {
                    texture.replace(region: region, mipmapLevel: 0, withBytes: base, bytesPerRow: k.w * 8)
                }
            }
        } else {
            guard k.bytes.count == texels else { return nil }
            k.bytes.withUnsafeBytes { raw in
                if let base = raw.baseAddress {
                    texture.replace(region: region, mipmapLevel: 0, withBytes: base, bytesPerRow: k.w * 4)
                }
            }
        }
        if let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: texture)
            blit.endEncoding()
            cb.commit()
        }
        guard let cells = k.cells.withUnsafeBytes({ raw -> MTLBuffer? in
            guard let base = raw.baseAddress else { return nil }
            return device.makeBuffer(bytes: base, length: raw.count, options: .storageModeShared)
        }) else { return nil }
        let particleBuffer: MTLBuffer?
        if k.particles.isEmpty {
            particleBuffer = device.makeBuffer(length: MemoryLayout<LPParticleData>.stride, options: .storageModeShared)
        } else {
            particleBuffer = k.particles.withUnsafeBytes { raw -> MTLBuffer? in
                guard let base = raw.baseAddress else { return nil }
                return device.makeBuffer(bytes: base, length: raw.count, options: .storageModeShared)
            }
        }
        guard let particles = particleBuffer else { return nil }
        return Built(texture: texture, cells: cells, particles: particles, particleCount: k.particles.count,
                     cols: k.cols, rows: k.rows, firstArrive: k.firstArrive, lastDepart: k.lastDepart)
    }

    private static func smooth(_ x: Float) -> Float {
        let t = min(1, max(0, x))
        return t * t * (3 - 2 * t)
    }
}

// MARK: - 切格子、定门槛、撒粒子（后台线程；只用值类型，主线程拿到以后再建贴图和缓冲）

/// 和 LogoParticles.metal 里的 LPParticle 一一对应
fileprivate struct LPParticleData: Sendable {
    var cell: SIMD4<Float>
    var color: SIMD4<Float>
    var seed: SIMD4<Float>
    var shape: SIMD4<Float>
}

/// 后台切好的一套：贴图第 0 级的像素（HDR 是半精度浮点、线性；SDR 是 8 位、编码过的，都是预乘的 Display P3）、每格的两个门槛、粒子
fileprivate struct LogoParticleBake: Sendable {
    let w: Int
    let h: Int
    let hdr: Bool
    let half: [UInt16]
    let bytes: [UInt8]
    let cells: [SIMD2<Float>]
    let particles: [LPParticleData]
    let cols: Int
    let rows: Int
    let firstArrive: Float
    let lastDepart: Float
}

fileprivate enum LogoParticleBaker {
    // 节奏（进度）：离开 0.012–0.62、主字标 0.65–0.80、厂牌 0.75–0.86、副标题 0.79–0.90（用户给的分段）
    static let departSpan: (Float, Float) = (0.012, 0.62)
    static let arriveWindows: [(Float, Float)] = [(0.65, 0.80), (0.75, 0.86), (0.79, 0.90)]
    /// 一格多大（点，按大字标）
    static let cellPt: CGFloat = 2.4

    /// 解出来的字标：data 是预乘的 RGBA 浮点（HDR 线性、SDR 编码空间，和画布一致；第一行是最上面一行），
    /// half / bytes 是传上贴图的那一份（只有一份不空）
    private struct Decoded {
        let data: [Float]
        let half: [UInt16]
        let bytes: [UInt8]
        let w: Int
        let h: Int
    }

    static func bake(_ image: UIImage, size: CGSize, hdr: Bool, legacy: Bool) -> LogoParticleBake? {
        guard let px = decode(image, hdr: hdr) else { return nil }
        let w = px.w, h = px.h

        // 格子：大字标上约 2.4 点一格（小字标上一点出头）
        let cols = max(12, min(200, Int((size.width / cellPt).rounded())))
        let rows = max(4, min(100, Int((size.height / cellPt).rounded())))
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
        let band = bands(coverage: coverage, cols: cols, rows: rows)

        // 离开：右下先走（加一点噪声），副标题晚一点走（说明里黄色只是「几粒点缀」）；按名次排成先疏后密，
        // 前 20% 的进度只走掉一成多，主字标还认得出来。
        // 名次只数有墨的格子；空格子（字和字之间、四周）跟着身边的名次走：影子按格子淡，不能一开始就没了
        let isAlive = (0..<n).map { peak[$0] > 0.03 }
        var key = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let u = (Float(i % cols) + 0.5) / Float(cols)
            let v = (Float(i / cols) + 0.5) / Float(rows)
            let late: Float = band[i] == 2 ? 0.14 : 0
            key[i] = 0.62 * u + 0.38 * v + (cellHash(i, 1) - 0.5) * 0.10 - late
        }
        let order = (0..<n).sorted { key[$0] > key[$1] }
        var depart = [Float](repeating: 0, count: n)
        var arrive = [Float](repeating: 0, count: n)
        let (d0, d1) = departSpan
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
            let (a0, a1) = arriveWindows[b]
            var k = 0
            for i in members {
                let q = min(1, Float(k) / Float(total))
                let a = min(a1, max(a0, a0 + (a1 - a0) * q + (cellHash(i, 2) - 0.5) * 0.012))
                arrive[i] = min(arriveWindows[2].1, max(a, depart[i] + 0.07))
                if isAlive[i] { k += 1 }
            }
        }
        let cellData = (0..<n).map { SIMD2<Float>(depart[$0], arrive[$0]) }

        // 粒子：每格一到三粒（领头那粒在格子正中，另外的在格子里随便一处、路上落后一点）；副标题只给六成的格子各一粒、小一点
        let perCell = legacy ? 2 : 3
        var parts: [LPParticleData] = []
        parts.reserveCapacity(alive.count * perCell)
        for i in alive {
            let c = i % cols, r = i / cols
            let s = sum[i]
            let a = max(s.w, 1e-6)
            let rgb = SIMD3(s.x / a, s.y / a, s.z / a)
            let opacity = min(1, coverage[i] * 1.5)
            let sub = band[i] == 2
            if sub && cellHash(i, 9) > 0.6 { continue }
            for k in 0..<(sub ? 1 : perCell) {
                let j = i * 4 + k
                let u: Float, v: Float, size: Float, lag: Float
                if k == 0 {
                    u = (Float(c) + 0.5) / Float(cols)
                    v = (Float(r) + 0.5) / Float(rows)
                    size = (1.3 + 0.7 * cellHash(j, 3)) * (sub ? 0.75 : 1)
                    lag = 0.15 * cellHash(j, 4)
                } else {
                    u = (Float(c) + cellHash(j, 5)) / Float(cols)
                    v = (Float(r) + cellHash(j, 6)) / Float(rows)
                    size = 0.8 + 0.5 * cellHash(j, 3)
                    lag = 0.1 + 0.5 * cellHash(j, 4)
                }
                parts.append(LPParticleData(
                    cell: SIMD4(u, v, depart[i], arrive[i]),
                    color: SIMD4(rgb.x, rgb.y, rgb.z, opacity * (k == 0 ? 1 : 0.8)),
                    seed: SIMD4(cellHash(j, 7), cellHash(j, 8), cellHash(j, 10), cellHash(j, 11)),
                    shape: SIMD4(size, lag, cellHash(j, 12), 0)
                ))
            }
        }

        let firstArrive = alive.map { arrive[$0] }.min() ?? arriveWindows[0].0
        let lastDepart = alive.map { depart[$0] }.max() ?? d1
        return LogoParticleBake(w: w, h: h, hdr: hdr, half: px.half, bytes: px.bytes, cells: cellData, particles: parts,
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

    /// 字标图 → 预乘的 RGBA（第一行是最上面一行），最长边不超过 1024 像素。
    /// HDR：线性扩展 Display P3 的浮点，亮部（> 1）原样留着；浮点的画布建不起来就退回 8 位、自己换成线性。
    /// SDR：8 位 Display P3，预乘本来就在编码空间里（和 SwiftUI / Core Animation 画这张图一样），原样当贴图
    private static func decode(_ image: UIImage, hdr: Bool) -> Decoded? {
        guard let cg = image.cgImage, cg.width > 0, cg.height > 0 else { return nil }
        let k = min(1.0, 1024.0 / Double(max(cg.width, cg.height)))
        let w = max(1, Int((Double(cg.width) * k).rounded()))
        let h = max(1, Int((Double(cg.height) * k).rounded()))
        let count = w * h * 4
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        if hdr, let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) {
            var data = [Float](repeating: 0, count: count)
            let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            let ok: Bool = data.withUnsafeMutableBytes { buf in
                guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 32, bytesPerRow: w * 16,
                                          space: space, bitmapInfo: info) else { return false }
                ctx.interpolationQuality = .high
                ctx.draw(cg, in: rect)
                return true
            }
            if ok { return Decoded(data: data, half: data.map { Self.halfBits($0) }, bytes: [], w: w, h: h) }
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
        if !hdr {
            return Decoded(data: bytes.map { Float($0) / 255 }, half: [], bytes: bytes, w: w, h: h)
        }
        var data = [Float](repeating: 0, count: count)
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
        return Decoded(data: data, half: data.map { Self.halfBits($0) }, bytes: [], w: w, h: h)
    }

    /// 固定的整数哈希 → 0…1：同一枚字标每次切出来的门槛、抖动都一样（倒着滚原路回去）
    private static func cellHash(_ i: Int, _ salt: UInt32) -> Float {
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
