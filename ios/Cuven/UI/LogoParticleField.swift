import MetalKit
import os
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
// 画面只看进度，不看时钟：0 < p < 1 时 MTKView 自己的时钟每秒画 60 帧（旧机型 30），每帧取最新的输入；p 是 0 或 1 时整层藏起来、停着，什么都不画。
//
// 画法照着这个 App 里在用户真机上画得出来的那几个（CacheDissolveRenderer、FlowFunnelRenderer、SendGlowRenderer）：
// 普通的 MTKView、bgra8Unorm，由 view 自己叫 draw(in:)，用 currentDrawable / currentRenderPassDescriptor，cb.present 以后再 commit；
// 不用 presentsWithTransaction，画布不缩成 1×1，也不先试画一帧。以前那一套（EDR 的浮点透明画布、跟 SwiftUI 同一个事务交画布、
// 藏着的时候先交一帧 1×1 的空白、GPU 生成 mip）在用户真机 iPhone Duo（IPA 335）上一直没说过「画得出来」：
// 往下滚只有两枚真字标交叉淡入淡出，一粒粒子都没有。
// 颜色：现在只有 SDR。画布是 8 位、不带 _srgb 的 Display P3，不开 EDR（wantsExtendedDynamicRangeContent）——
// EDR 的透明画布在真机上从来没验证过画得出来，先走一条确定能画的路。LogoHDR 的字标照样能用：画进 8 位的 Display P3，
// 比 SDR 白还亮的部分截到 1（粒子层比真字标的亮部暗一点，可以接受）。贴图和粒子的颜色留在编码空间里预乘、叠加——
// 和 SwiftUI / Core Animation 画真字标是同一种算法，半透明的边、粒子的软边和尾巴不会比真字标亮一圈。
// 切格子、定门槛、撒粒子、缩 mip 都在后台做（LogoParticleBaker），主线程只把它们拷进共享存储的贴图和缓冲
// （不经过 GPU：不用 blit 生成 mip，贴图也不当渲染目标）。拷好了、管线也在，就从 onReady 说「画得出来」。
// 画不出来的时候字标不能凭空消失：没有 Metal、管线建不起来、切不出来 / 拷不上去，onReady 就一直是 false（调用方让两枚真字标交叉淡入淡出）；
// 画到一半 GPU 报错、露出来以后一直画不上，也改说 false。每一步失败和第一帧都记一行 lpLog。

/// 粒子层的诊断日志：只有哪一步、像素格式、尺寸、进度，不含片名和地址（仓库公开）。
/// 进系统日志（装到手机上的发行版也有，Console 里搜「logo particles」；画不上、放弃这一类记成 error，系统会留着），
/// Debug 构建另外写进诊断文件（Perf.file）
private func lpLog(_ s: String, failure: Bool = false) {
    let line = "logo particles: " + s
    if failure {
        Perf.logger.error("\(line, privacy: .public)")
        Perf.file(line)
    } else {
        Perf.log(line)
    }
}

private func lpFormatName(_ f: MTLPixelFormat) -> String {
    switch f {
    case .rgba16Float: return "rgba16Float"
    case .bgra8Unorm: return "bgra8Unorm"
    default: return "pixelFormat \(f.rawValue)"
    }
}

private func lpRect(_ r: SIMD4<Float>) -> String {
    "\(Int(r.x)),\(Int(r.y)) \(Int(r.z))x\(Int(r.w))"
}


/// GPU 那边的结果：命令做完时在 Metal 的线程上写，主线程画下一帧之前（和每次 SwiftUI 更新时）取。
/// 不留着命令缓冲本身：它拽着画布，池子里的画布会不够用
private final class LPGPUStatus: @unchecked Sendable {
    private let lock = NSLock()
    private var error: String?
    private var completed = false

    func record(failed: Bool, message: String?) {
        lock.lock()
        if failed {
            if error == nil { error = message ?? "unknown error" }
        } else {
            completed = true
        }
        lock.unlock()
    }

    /// 上次取过以后：有没有哪一帧在 GPU 上出错、有没有哪一帧顺利做完
    func take() -> (error: String?, completed: Bool) {
        lock.lock()
        defer { lock.unlock() }
        let r = (error: error, completed: completed)
        error = nil
        completed = false
        return r
    }
}

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
    /// 这一层能不能画这张字标：有 Metal、管线建好了、粒子已经在后台切好并拷上了 GPU。
    /// 一建好先说一次（还在切：false），以后变了才回调，在主线程、这次视图更新以后。画到一半 GPU 报错、露出来以后一直画不上，
    /// 会再说一次 false（这一页不再试）。调用方在不是 true 的时候不该藏头部的真字标（改成交叉淡入淡出），字标不会在半路上没了
    var onReady: ((Bool) -> Void)? = nil

    final class Coordinator {
        var renderer: LogoParticleRenderer?
        /// 没有 Metal 的那一次 false 已经说过了
        var reportedNoMetal = false
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MTKView {
        let v = MTKView()
        // 先停着：设了 delegate 以后不会马上开始每秒 60 帧（不在转场时什么都不画）
        v.isPaused = true
        v.enableSetNeedsDisplay = false
        v.colorPixelFormat = .bgra8Unorm
        v.framebufferOnly = true
        // 和 FlowFunnelCanvas 一样：旧机型（改进兼容性那一档）30 帧
        v.preferredFramesPerSecond = Compat.legacyDevice ? 30 : 60
        // 画布跟着视图的大小走（MTKView 自己撑），不缩成 1×1
        v.autoResizeDrawable = true
        v.isOpaque = false
        v.backgroundColor = .clear
        v.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        v.isUserInteractionEnabled = false
        v.isAccessibilityElement = false
        v.accessibilityElementsHidden = true
        // 两头都要和真字标一样清楚：3 倍屏上就按 3 倍画（旧机型 2 倍，省内存）；露出来时再按窗口所在的那块屏校一次
        v.contentScaleFactor = min(UIScreen.main.scale, Compat.legacyDevice ? 2 : 3)
        v.isHidden = true
        if let layer = v.layer as? CAMetalLayer {
            layer.isOpaque = false
            // 8 位、编码过的 Display P3（和贴图一样）；只有 SDR，不开 EDR（见文件头）
            layer.colorspace = CGColorSpace(name: CGColorSpace.displayP3)
        }
        if let r = LogoParticleRenderer(legacy: Compat.legacyDevice) {
            v.device = r.device
            v.delegate = r
            r.view = v
            context.coordinator.renderer = r
        }
        update(v, context.coordinator)
        return v
    }

    func updateUIView(_ v: MTKView, context: Context) { update(v, context.coordinator) }

    private func update(_ v: MTKView, _ c: Coordinator) {
        guard let r = c.renderer else {
            if !v.isHidden { v.isHidden = true }
            if !v.isPaused { v.isPaused = true }
            // 没有 Metal：告诉调用方这一层画不了（只说一次，放到这次视图更新以后）
            if !c.reportedNoMetal {
                c.reportedNoMetal = true
                lpLog("no Metal renderer on this page", failure: true)
                if let onReady { Task { @MainActor in onReady(false) } }
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
    /// 三条管线（bgra8Unorm）
    private struct Pipes {
        let quad: MTLRenderPipelineState
        let shadow: MTLRenderPipelineState
        let dot: MTLRenderPipelineState
    }

    /// 画布的像素格式：只有 SDR（见文件头）
    private static let format: MTLPixelFormat = .bgra8Unorm
    /// 格子和粒子交接的那一小段（进度）：格子淡出 / 淡入的同时同一处的粒子淡入 / 淡出
    private static let handoff: Float = 0.012
    /// 露出来以后连着这么多帧没画上（拿不到画布、视图没有大小……）就放弃这一页：还一帧都没画过时 12 帧（约 0.2 秒），
    /// 画过以后 90 帧（展开 / 折起的中途画布和视图会对不上几帧，不算坏）
    private static let missesBeforeFirstFrame = 12
    private static let missesAfterFirstFrame = 90

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipes: Pipes
    /// 旧机型：每格少撒一粒
    private let legacy: Bool
    /// 画在哪一块画布上（显隐、停走都由这里管）
    weak var view: MTKView?
    /// 见 LogoParticleField.onReady
    var onReady: ((Bool) -> Void)?

    private var image: UIImage?
    /// 字标图的像素大小（诊断用）
    private var imagePx = (w: 0, h: 0)
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
    /// 画布露着、MTKView 的时钟在走
    private var shown = false
    /// 这一页画过（交出去）几帧
    private var frames = 0
    /// 有一帧在 GPU 上顺利做完了
    private var gpuOK = false
    /// 放弃了（为什么）：这一页不再画，调用方交叉淡入淡出两枚真字标
    private var broken: String?
    /// 露着的时候连着没画上的帧数（画上一帧就清零）
    private var misses = 0
    private let gpu = LPGPUStatus()
    /// 同一件事一页只记一次日志
    private var noted = Set<String>()

    init?(legacy: Bool) {
        guard let dev = MTLCreateSystemDefaultDevice() else {
            lpLog("no Metal device", failure: true)
            return nil
        }
        guard let q = dev.makeCommandQueue() else {
            lpLog("no command queue", failure: true)
            return nil
        }
        guard let lib = dev.makeDefaultLibrary() else {
            lpLog("no default Metal library", failure: true)
            return nil
        }
        guard let p = LogoParticleRenderer.makePipes(dev, lib) else { return nil }
        device = dev
        queue = q
        pipes = p
        self.legacy = legacy
        super.init()
    }

    /// 预乘 alpha 的「盖上去」：叠在页面上，和 SwiftUI 画真字标一样
    private static func makePipes(_ dev: MTLDevice, _ lib: MTLLibrary) -> Pipes? {
        let format = LogoParticleRenderer.format
        func pipe(_ v: String, _ f: String) -> MTLRenderPipelineState? {
            guard let vf = lib.makeFunction(name: v), let ff = lib.makeFunction(name: f) else {
                lpLog("shader \(v) / \(f) missing from the default library", failure: true)
                return nil
            }
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = vf
            d.fragmentFunction = ff
            let ca = d.colorAttachments[0]!
            ca.pixelFormat = format
            ca.isBlendingEnabled = true
            ca.rgbBlendOperation = .add
            ca.alphaBlendOperation = .add
            ca.sourceRGBBlendFactor = .one
            ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
            ca.sourceAlphaBlendFactor = .one
            ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            do {
                return try dev.makeRenderPipelineState(descriptor: d)
            } catch {
                lpLog("pipeline \(f) for \(lpFormatName(format)) failed: \(error.localizedDescription)", failure: true)
                return nil
            }
        }
        guard let qp = pipe("lp_quad_vertex", "lp_logo_fragment"),
              let sp = pipe("lp_quad_vertex", "lp_shadow_fragment"),
              let dp = pipe("lp_dot_vertex", "lp_dot_fragment") else { return nil }
        return Pipes(quad: qp, shadow: sp, dot: dp)
    }

    /// 这一帧要不要画（藏起来的时候什么都不做）
    var active: Bool {
        broken == nil && built != nil && !reduceMotion && progress > 0 && progress < 1
            && from.width >= 2 && from.height >= 2 && to.width >= 1 && to.height >= 1
    }

    /// SwiftUI 每次更新都会调：只记下最新的输入（露着的时候 MTKView 每一帧都按它画）；
    /// 换了图（或大字标大小变了两成五以上）才在后台重新切格子
    func set(image: UIImage?, from: CGRect, to: CGRect, origin: CGPoint?, progress: Double, reduceMotion: Bool) {
        if image !== self.image {
            // 换了图：旧的那一套不能再画，还在切的也作废
            self.image = image
            imagePx = (w: image?.cgImage?.width ?? 0, h: image?.cgImage?.height ?? 0)
            built = nil
            bakedSize = .zero
            generation &+= 1
            baking = false
        }
        if let image, from.width >= 2, from.height >= 2 {
            let s = bakedSize
            let stale = s == .zero
                || abs(from.width - s.width) > s.width * 0.25
                || abs(from.height - s.height) > s.height * 0.25
            if stale { bake(image, size: from.size) }
        }
        self.from = from
        self.to = to
        fieldOrigin = origin
        self.progress = progress
        self.reduceMotion = reduceMotion
        reportReady()
    }

    /// 后台切格子、缩 mip；切完回到主线程拷进贴图、缓冲。按新大小重切时，原来那一套接着画到新的切好为止（转屏时不会空一下）
    private func bake(_ image: UIImage, size: CGSize) {
        bakedSize = size
        generation &+= 1
        baking = true
        let gen = generation
        let legacy = self.legacy
        Task { @MainActor [weak self] in
            let baked = await Task.detached(priority: .userInitiated) {
                LogoParticleBaker.bake(image, size: size, legacy: legacy)
            }.value
            guard let self, self.generation == gen else { return }
            self.baking = false
            // 按新大小重切失败：留着原来那一套（同一张图，只是格子大小差一点）
            if let baked {
                if let b = self.upload(baked) {
                    self.built = b
                    lpLog("baked \(b.cols)x\(b.rows) cells, \(b.particleCount) particles, \(baked.w)x\(baked.h) px texture"
                          + " with \(baked.levels.count) mip levels for a \(Int(size.width))x\(Int(size.height)) pt logo")
                }
            } else {
                lpLog("bake failed for a \(Int(size.width))x\(Int(size.height)) pt logo", failure: true)
            }
            self.reportReady()
            self.sync()
        }
    }

    /// 能不能画变了才告诉调用方。「能」= 切好了、拷上了 GPU（管线在 init 里就建好了），也没放弃。
    /// 一建好就先说一次（多半是 false：还在切）：SwiftUI 换了一块新画布时，调用方手里不会还留着上一块说过的 true
    private func reportReady() {
        let ready = broken == nil && built != nil
        guard let cb = onReady, ready != reportedReady else { return }
        let before = reportedReady
        reportedReady = ready
        if ready {
            lpLog("ready — \(canvasState)")
        } else if before == true {
            let why = broken ?? "re-baking for a new logo image"
            lpLog("no longer ready (\(why)) — \(canvasState)")
        }
        // 放到这次视图更新以后再说：回调里通常会改 SwiftUI 的状态
        Task { @MainActor in cb(ready) }
    }

    /// 按现在的输入定画布：要画时露出来、就地先画一帧，再让 MTKView 自己的时钟接着画；不画时停下、藏起来
    func sync() {
        guard let v = view else { return }
        checkGPU()
        let show = active
        if show != shown {
            shown = show
            if show {
                misses = 0
                fitScale(v)
                v.isHidden = false
                // 露出来的这一下先就地画一帧（停着的 MTKView 由 draw() 明着叫 draw(in:)），
                // 不让层里上一次转场留下的那张先露出来一下，再交给 view 自己的时钟
                v.draw()
                // 上面这一帧里可能已经放弃了（GPU 报错、画布格式不对）
                if shown { v.isPaused = false }
            } else {
                v.isPaused = true
                v.isHidden = true
            }
        }
        if !show { explainIdle() }
    }

    /// 倍数按窗口所在的那块屏（UIScreen.main 在折叠屏、外接屏上不一定是这块）
    private func fitScale(_ v: MTKView) {
        let screen = v.window?.windowScene?.screen.scale ?? 0
        let s = screen > 0 ? screen : v.traitCollection.displayScale
        guard s > 0 else { return }
        let k = min(s, Compat.legacyDevice ? 2 : 3)
        if abs(v.contentScaleFactor - k) > 0.01 { v.contentScaleFactor = k }
    }

    // MARK: 画不上的时候

    /// 同一件事一页只记一次
    private func note(_ key: String, _ detail: @autoclosure () -> String, failure: Bool = false) {
        guard noted.insert(key).inserted else { return }
        lpLog(detail(), failure: failure)
    }

    /// 现在这块画布的样子（日志用）
    private var canvasState: String {
        let b = view?.bounds.size ?? .zero
        let ds = view?.drawableSize ?? .zero
        let k = view?.contentScaleFactor ?? 0
        return "\(lpFormatName(Self.format)) bounds \(Int(b.width))x\(Int(b.height))"
            + " drawable \(Int(ds.width))x\(Int(ds.height)) scale \(k) window \(view?.window != nil)"
            + " p \(String(format: "%.3f", progress))"
    }

    /// 要画（0 < p < 1）却不画：为什么（日志、诊断用）
    private func explainIdle() {
        guard progress > 0, progress < 1 else { return }
        let why: String
        if broken != nil {
            why = "gave up earlier on this page"
        } else if reduceMotion {
            why = "reduce motion"
        } else if built == nil {
            why = baking ? "particles still baking" : (image == nil ? "no logo image" : "no baked particles")
        } else if from.width < 2 || from.height < 2 {
            why = "hero logo frame not measured"
        } else if to.width < 1 || to.height < 1 {
            why = "bar slot not measured"
        } else {
            return
        }
        note("idle:" + why, "skipping frames: \(why) — \(canvasState)")
    }

    /// 露着却没画上这一帧：MTKView 下一帧自己会再来；连着太多帧都不行就放弃这一页
    private func skipped(_ why: String) {
        misses += 1
        note("skip:" + why, "frame skipped: \(why) — \(canvasState)", failure: true)
        let limit = frames == 0 ? Self.missesBeforeFirstFrame : Self.missesAfterFirstFrame
        if misses >= limit {
            fail("\(misses) frames in a row not drawn (last: \(why))")
        }
    }

    /// GPU 那边的结果：第一帧顺利做完记一行；哪一帧出了错就放弃这一页
    private func checkGPU() {
        let s = gpu.take()
        if s.completed, !gpuOK {
            gpuOK = true
            lpLog("first frame finished on the GPU — \(canvasState)")
        }
        if let err = s.error { fail("the GPU failed a frame: \(err)") }
    }

    /// 画不了：这一页不再画，停下、藏起来，告诉调用方（两枚真字标交叉淡入淡出）
    private func fail(_ why: String) {
        guard broken == nil else { return }
        broken = why
        lpLog("giving up, the page cross-fades the real logos instead: \(why) — \(canvasState)", failure: true)
        shown = false
        if let v = view {
            v.isPaused = true
            v.isHidden = true
        }
        reportReady()
    }


    // MARK: 一帧

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // 画布大小变了（转屏、展开 / 折起）：露着的时候下一帧就按新的大小画，这里只更新诊断
    }

    /// MTKView 自己的时钟（露着的时候每秒 60 帧，旧机型 30）或 sync 里露出来的那一下明着叫：按最新的输入画一帧
    func draw(in view: MTKView) {
        checkGPU()
        guard active, let b = built else { return }
        let bounds = view.bounds.size
        let ds = view.drawableSize
        guard bounds.width > 0, bounds.height > 0, ds.width >= 2, ds.height >= 2 else {
            skipped("the canvas has no size yet")
            return
        }
        // 画布和视图的宽高比对不上（展开 / 折起的中途）：位置全会错，等 MTKView 把画布撑对再画
        let sx = ds.width / bounds.width, sy = ds.height / bounds.height
        guard abs(sx - sy) <= 0.02 * max(sx, sy) else {
            skipped("drawable and view disagree on the aspect ratio")
            return
        }
        guard let drawable = view.currentDrawable, let rpd = view.currentRenderPassDescriptor else {
            skipped("no drawable")
            return
        }
        guard drawable.texture.pixelFormat == Self.format else {
            fail("the drawable is \(lpFormatName(drawable.texture.pixelFormat)), the pipelines are \(lpFormatName(Self.format))")
            return
        }
        guard let cb = queue.makeCommandBuffer() else {
            skipped("no command buffer")
            return
        }
        // 按真拿到的这张画布的像素算（和 drawableSize 本该一样）
        let tw = CGFloat(drawable.texture.width), thh = CGFloat(drawable.texture.height)

        let scale = Float(tw / bounds.width)
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
            view: SIMD4(Float(tw), Float(thh), pt, p),
            src: src,
            dst: dst,
            grid: SIMD4(Float(b.cols), Float(b.rows), Self.handoff, 0.010),
            // 中段收到原来宽度的 5%；横向抖 4 点、摆 2.5 点
            path: SIMD4(bowPt * pt, 0.95, 4 * pt, 2.5 * pt),
            anchor: SIMD4(sa.x, sa.y, da.x, da.y),
            // 尾巴最长 14 点；刚离开散开 14 点、落定前散开 5 点；弧线至少按 40 点高算（大字标滚到很上面时也有弧度）
            extra: SIMD4(14 * pt, 14 * pt, 5 * pt, 40 * pt),
            // 粒子路上提亮多少、闪一下提亮多少、颜色上限：编码空间里的幅度；SDR 不超过 1（预乘的颜色不超过 alpha）
            tone: SIMD4<Float>(0.10, 0.35, 1, 0)
        )

        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        rpd.colorAttachments[0].storeAction = .store
        guard let e = cb.makeRenderCommandEncoder(descriptor: rpd) else {
            skipped("no render command encoder")
            return
        }
        e.setFragmentBuffer(b.cells, offset: 0, index: 2)
        e.setFragmentTexture(b.texture, index: 0)
        // 1. 大字标上还没走的格子（连影子）
        if p < b.lastDepart + Self.handoff {
            drawQuad(e, pipes.shadow, U, shadowQuad(src, which: 0, scale: scale, texture: b.texture))
            drawQuad(e, pipes.quad, U, Quad(rect: src, info: SIMD4(0, 0, 0, 0), shadow: .zero))
        }
        // 2. 小字标上已经落定的格子（连影子）
        if p > b.firstArrive - Self.handoff {
            drawQuad(e, pipes.shadow, U, shadowQuad(dst, which: 1, scale: scale, texture: b.texture))
            drawQuad(e, pipes.quad, U, Quad(rect: dst, info: SIMD4(0, 1, 0, 0), shadow: .zero))
        }
        // 3. 路上的粒子：每粒一个拉长的小四边形（实例化）
        if b.particleCount > 0 {
            e.setRenderPipelineState(pipes.dot)
            e.setVertexBuffer(b.particles, offset: 0, index: 0)
            e.setVertexBytes(&U, length: MemoryLayout<Uniforms>.stride, index: 1)
            e.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: b.particleCount)
        }
        e.endEncoding()
        // GPU 的结果只记下来，下一帧开始前（和下一次 SwiftUI 更新时）看（不留着命令缓冲本身）
        let status = gpu
        cb.addCompletedHandler { @Sendable done in
            status.record(failed: done.status == .error, message: done.error.map { "\($0)" })
        }
        cb.present(drawable)
        cb.commit()
        misses = 0
        frames &+= 1
        if frames == 1 {
            lpLog("first frame drawn — \(canvasState) src \(lpRect(src)) dst \(lpRect(dst)) px, \(b.cols)x\(b.rows) cells, \(b.particleCount) particles")
        }
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

    /// 后台切好的那一套传上 GPU（主线程，几百 KB 到几 MB 的拷贝）：贴图带后台缩好的整条 mip（小字标靠它缩小，影子靠它模糊）。
    /// 共享存储、只给着色器读：每一级都由 CPU 直接写，不用 GPU 生成 mip，也不当渲染目标（以前那样在真机上没验证过）
    private func upload(_ k: LogoParticleBake) -> Built? {
        guard !k.levels.isEmpty else {
            lpLog("upload: no mip levels for a \(k.w)x\(k.h) texture", failure: true)
            return nil
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: k.w, height: k.h, mipmapped: false)
        desc.mipmapLevelCount = k.levels.count
        desc.storageMode = .shared
        desc.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: desc) else {
            lpLog("upload: no \(k.w)x\(k.h) texture with \(k.levels.count) mip levels", failure: true)
            return nil
        }
        var lw = k.w, lh = k.h
        for (i, level) in k.levels.enumerated() {
            guard level.count == lw * lh * 4 else {
                lpLog("upload: mip \(i) has \(level.count) bytes for \(lw)x\(lh)", failure: true)
                return nil
            }
            let region = MTLRegionMake2D(0, 0, lw, lh)
            let rowBytes = lw * 4
            level.withUnsafeBytes { raw in
                if let base = raw.baseAddress {
                    texture.replace(region: region, mipmapLevel: i, withBytes: base, bytesPerRow: rowBytes)
                }
            }
            lw = max(1, lw / 2)
            lh = max(1, lh / 2)
        }
        guard let cells = k.cells.withUnsafeBytes({ raw -> MTLBuffer? in
            guard let base = raw.baseAddress else { return nil }
            return device.makeBuffer(bytes: base, length: raw.count, options: .storageModeShared)
        }) else {
            lpLog("upload: no cell buffer (\(k.cols)x\(k.rows) cells)", failure: true)
            return nil
        }
        let particleBuffer: MTLBuffer?
        if k.particles.isEmpty {
            particleBuffer = device.makeBuffer(length: MemoryLayout<LPParticleData>.stride, options: .storageModeShared)
        } else {
            particleBuffer = k.particles.withUnsafeBytes { raw -> MTLBuffer? in
                guard let base = raw.baseAddress else { return nil }
                return device.makeBuffer(bytes: base, length: raw.count, options: .storageModeShared)
            }
        }
        guard let particles = particleBuffer else {
            lpLog("upload: no particle buffer (\(k.particles.count) particles)", failure: true)
            return nil
        }
        return Built(texture: texture, cells: cells, particles: particles, particleCount: k.particles.count,
                     cols: k.cols, rows: k.rows, firstArrive: k.firstArrive, lastDepart: k.lastDepart)
    }

    private static func smooth(_ x: Float) -> Float {
        let t = min(1, max(0, x))
        return t * t * (3 - 2 * t)
    }
}


// MARK: - 切格子、定门槛、撒粒子、缩 mip（后台线程；只用值类型，主线程拿到以后再建贴图和缓冲）

/// 和 LogoParticles.metal 里的 LPParticle 一一对应
fileprivate struct LPParticleData: Sendable {
    var cell: SIMD4<Float>
    var color: SIMD4<Float>
    var seed: SIMD4<Float>
    var shape: SIMD4<Float>
}

/// 后台切好的一套：贴图每一级 mip 的像素（8 位、预乘过的 Display P3，编码空间；第 0 级在最前，一直缩到 1×1）、每格的两个门槛、粒子
fileprivate struct LogoParticleBake: Sendable {
    let w: Int
    let h: Int
    let levels: [[UInt8]]
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

    /// 解出来的字标：8 位、预乘过的 RGBA（Display P3 编码空间，第一行是最上面一行），原样当贴图的第 0 级
    private struct Decoded {
        let bytes: [UInt8]
        let w: Int
        let h: Int
    }

    static func bake(_ image: UIImage, size: CGSize, legacy: Bool) -> LogoParticleBake? {
        guard let px = decode(image) else { return nil }
        let w = px.w, h = px.h

        // 格子：大字标上约 2.4 点一格（小字标上一点出头）
        let cols = max(12, min(200, Int((size.width / cellPt).rounded())))
        let rows = max(4, min(100, Int((size.height / cellPt).rounded())))
        let n = cols * rows
        var sum = [SIMD4<Float>](repeating: .zero, count: n)
        var peak = [Float](repeating: 0, count: n)
        var count = [Float](repeating: 0, count: n)
        let inv: Float = 1 / 255
        px.bytes.withUnsafeBufferPointer { d in
            for y in 0..<h {
                let cy = min(rows - 1, y * rows / h)
                let rowBase = y * w * 4
                for x in 0..<w {
                    let ci = cy * cols + min(cols - 1, x * cols / w)
                    let o = rowBase + x * 4
                    let a = Float(d[o + 3]) * inv
                    sum[ci] += SIMD4(Float(d[o]) * inv, Float(d[o + 1]) * inv, Float(d[o + 2]) * inv, a)
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
        return LogoParticleBake(w: w, h: h, levels: mips(px.bytes, w: w, h: h), cells: cellData, particles: parts,
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

    /// 字标图 → 8 位、预乘过的 Display P3（第一行是最上面一行），最长边不超过 1024 像素。
    /// 预乘本来就在编码空间里（和 SwiftUI / Core Animation 画这张图一样），原样当贴图。
    /// LogoHDR 的字标（16 位浮点、扩展线性 Display P3）也画进这块 8 位的：CoreGraphics 换回编码空间，比 SDR 白还亮的截到 1（只有 SDR，见文件头）
    private static func decode(_ image: UIImage) -> Decoded? {
        guard let cg = image.cgImage, cg.width > 0, cg.height > 0 else {
            lpLog("decode: the logo has no bitmap (cgImage \(image.cgImage != nil))", failure: true)
            return nil
        }
        let k = min(1.0, 1024.0 / Double(max(cg.width, cg.height)))
        let w = max(1, Int((Double(cg.width) * k).rounded()))
        let h = max(1, Int((Double(cg.height) * k).rounded()))
        guard let p3 = CGColorSpace(name: CGColorSpace.displayP3) else {
            lpLog("decode: no Display P3 color space", failure: true)
            return nil
        }
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let ok: Bool = bytes.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: p3, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else {
            lpLog("decode: no 8-bit context for a \(w)x\(h) logo (\(cg.bitsPerComponent) bpc source)", failure: true)
            return nil
        }
        return Decoded(bytes: bytes, w: w, h: h)
    }

    /// 整条 mip：第 0 级是原图，往下每一级取上一级 2×2 的平均（预乘过的值直接平均就对），一直缩到 1×1。
    /// 每一级的大小和 Metal 的约定一样（max(1, 上一级 / 2)），级数 = floor(log2(最长边)) + 1
    private static func mips(_ base: [UInt8], w: Int, h: Int) -> [[UInt8]] {
        var levels: [[UInt8]] = [base]
        var pw = w, ph = h
        while pw > 1 || ph > 1 {
            let nw = max(1, pw / 2), nh = max(1, ph / 2)
            var next = [UInt8](repeating: 0, count: nw * nh * 4)
            let prev = levels[levels.count - 1]
            let srcW = pw, srcH = ph
            prev.withUnsafeBufferPointer { s in
                next.withUnsafeMutableBufferPointer { d in
                    for y in 0..<nh {
                        let y0 = min(2 * y, srcH - 1), y1 = min(2 * y + 1, srcH - 1)
                        for x in 0..<nw {
                            let x0 = min(2 * x, srcW - 1), x1 = min(2 * x + 1, srcW - 1)
                            let i00 = (y0 * srcW + x0) * 4, i01 = (y0 * srcW + x1) * 4
                            let i10 = (y1 * srcW + x0) * 4, i11 = (y1 * srcW + x1) * 4
                            let o = (y * nw + x) * 4
                            for ch in 0..<4 {
                                let total = UInt16(s[i00 + ch]) + UInt16(s[i01 + ch]) + UInt16(s[i10 + ch]) + UInt16(s[i11 + ch])
                                d[o + ch] = UInt8((total + 2) / 4)
                            }
                        }
                    }
                }
            }
            levels.append(next)
            pw = nw
            ph = nh
        }
        return levels
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
}
