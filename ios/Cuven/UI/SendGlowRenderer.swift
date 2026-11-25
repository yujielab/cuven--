import MetalKit
import SwiftUI
import UIKit

// MARK: - 「申请添加」上滑发送的光：Metal 画布 + 折射 + 胶囊底下的光（着色器在 SendGlow.metal）
//
// 用户要求：可申请添加的影片 / 剧集，上滑或按下「申请添加」→ 粒子箭头飞行动效、屏幕显示「正在发往请求中心」→ 打勾、
// 「已添加至请求中心，等待您进一步操作」和添加的时间。光照着用户发来的录屏和 Swipe-to-Send 设计说明做：
//   发送中（从松手算起，秒）：
//     0.00 – 0.55  光从底下胶囊那儿往上漫开（云顶 0.95 → 0.50 屏高，ease-out），箭头从屏幕下沿穿过云升到约 0.69 屏高、淡入
//     0.55 以后    等结果：箭头继续稳稳地慢慢往上（0.7 秒 0.67、1.1 秒 0.64、1.7 秒 0.61，照录屏量的）、慢慢变小变柔，云一直慢慢飘
//   成功：先收发送的光，再从结果到的那一刻（at）算起：
//     收光       箭头再往上一点、变小变柔、淡掉，云往下沉着淡掉（录屏 4.63 → 4.80 秒：勾出来的时候中间已经黑了）。
//                浮层可以把 at 放到 0.2 秒以后（先切到 .success、先收光），收光就用这 0.2 秒；at 就是现在时 0.06 秒收完
//     0.00 – 0.20  中心闪一下（青绿 → 紫）
//     0.04 – 0.75  一道环从结果那一组的中心往外走（ease-out），0.16 – 0.85 外沿带一点绿 / 琥珀色边，0.45 – 0.82 淡掉
//     环走到哪儿，哪一段圆角边就亮起来（0.8 – 1.3 最远那个角也亮满）；0.6 – 2.4 边缘光再亮一点到位，0.9 – 4.0 慢慢从紫往青漂
//     折射（sendRefraction）：0.07 – 0.09 最强，0.4 以前没了；带子的半径和环用同一个走法（reach，iPad 上走得远）
//   失败：发送的光往下沉着淡掉（0.5 秒），只剩一圈很淡的灰紫边（不呼吸），不放环
//   「减弱动态效果」：箭头不动、云不飘，没有环、没有闪光、没有折射，全部淡入淡出
//   画面不再变了就停下来不画（减弱动态效果淡完、失败落定）；成功落定以后只剩边上慢慢漂的颜色，降到 30 / 20 帧

/// 画布现在在哪一步（时间都是 CACurrentMediaTime）
enum SendGlowPhase: Equatable {
    case idle
    case sending(start: CFTimeInterval)
    case success(sendStart: CFTimeInterval, at: CFTimeInterval)
    case failure(at: CFTimeInterval)
}

/// 设计说明里的起始配色
enum SendGlowPalette {
    static let ink = Color(red: 11 / 255, green: 11 / 255, blue: 18 / 255)
    static let blue = Color(red: 66 / 255, green: 99 / 255, blue: 1)
    static let violet = Color(red: 130 / 255, green: 104 / 255, blue: 1)
    static let cyan = Color(red: 113 / 255, green: 217 / 255, blue: 1)
}

/// 时间线：画布、折射都从这儿取（数都是设计说明的起始值，再对着录屏调过）
enum SendGlowTimeline {
    static func clamp01(_ x: Double) -> Double { min(1, max(0, x)) }

    static func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = clamp01((x - a) / (b - a))
        return t * t * (3 - 2 * t)
    }

    static func easeOut(_ x: Double, power: Double = 3) -> Double {
        1 - pow(1 - clamp01(x), power)
    }

    /// 发送中的样子（位置都是占画布的比例，y 往下）
    struct Sending {
        var arrowY: Double
        var arrowScale: Double
        var arrowAlpha: Double
        var cloudTop: Double
        var cloudAmp: Double
        var soft: Double
    }

    /// t：从松手算起几秒
    static func sending(_ t: Double, reduceMotion: Bool) -> Sending {
        if reduceMotion {
            let a = smooth(0, 0.35, t)
            return Sending(arrowY: 0.70, arrowScale: 0.85, arrowAlpha: a, cloudTop: 0.50, cloudAmp: a, soft: 0.3)
        }
        // 0.55 秒：箭头从屏幕下沿穿过云升上来（设计说明 armed release 450–650 ms）；之后等结果时稳稳地慢慢往上、慢慢变小。
        // 往上的那一段 0.25 秒起、平滑接上（乘一个 smoothstep，速度不跳）：照录屏量的 0.5 秒 0.69、0.7 秒 0.66、1.1 秒 0.64、1.7 秒 0.61 屏高
        let e = easeOut(t / 0.55)
        let rise = (1 - exp(-max(0, t - 0.25) / 0.85)) * smooth(0.25, 0.55, t)
        let shrink = 1 - exp(-max(0, t - 0.35) / 1.1)
        return Sending(
            arrowY: 1.02 + (0.72 - 1.02) * e - 0.13 * rise,
            arrowScale: (0.8 + 0.2 * e) * (1 - 0.38 * shrink),
            arrowAlpha: smooth(0.04, 0.36, t),
            cloudTop: 0.95 + (0.50 - 0.95) * easeOut(t / 0.6) - 0.05 * (1 - exp(-max(0, t - 0.6) / 1.5)),
            cloudAmp: smooth(0, 0.42, t),
            soft: 1 - exp(-max(0, t - 0.4) / 1.4))
    }

    /// 成功以后发送的光怎么收（录屏 4.63 → 4.80 秒：箭头先往上、变小变柔，再淡掉；云和那一行字几乎没了，勾才从黑下来的中间出来）。
    /// x：从开始收算起几秒；window：收完要多久（浮层提前 0.2 秒切到成功时就是 0.2，没有提前时 0.06：折射最强那几帧中间已经黑了）
    static func exitAfterSuccess(_ s: inout Sending, _ x: Double, window: Double = 0.2, reduceMotion: Bool) {
        if reduceMotion {
            let k = 1 - smooth(0, 0.3, x)
            s.arrowAlpha *= k
            s.cloudAmp *= k
            return
        }
        let w = max(0.03, window)
        let m = easeOut(x / w, power: 2)
        s.arrowY -= min(0.06, 0.3 * w) * m
        s.arrowScale *= 1 - 0.3 * m
        s.soft = min(1, s.soft + 0.4 * m)
        s.arrowAlpha *= 1 - smooth(0.15 * w, 0.9 * w, x)
        s.cloudAmp *= 1 - smooth(0, 0.85 * w, x)
        s.cloudTop += 0.12 * m
    }

    /// 失败：箭头往下沉一点淡掉，云慢一点淡掉
    static func exitAfterFailure(_ s: inout Sending, _ f: Double, reduceMotion: Bool) {
        if reduceMotion {
            let k = 1 - smooth(0, 0.35, f)
            s.arrowAlpha *= k
            s.cloudAmp *= k
            return
        }
        s.arrowAlpha *= 1 - smooth(0, 0.45, f)
        s.arrowY += 0.03 * easeOut(f / 0.45)
        s.cloudAmp *= 1 - smooth(0.05, 0.6, f)
        s.cloudTop += 0.2 * easeOut(f / 0.6)
    }

    /// 环往外走了几成（0…1）：ease-out，0.04 秒起步、0.75 秒走到最远的角外面
    static func ringProgress(_ u: Double) -> Double { easeOut((u - 0.04) / 0.71, power: 1.2) }
    static func ringAmp(_ u: Double) -> Double { smooth(0, 0.12, u) * (1 - smooth(0.45, 0.82, u)) }
    /// 环走到边上时外沿那一点绿 / 琥珀色（录屏 5.23 秒）
    static func fringe(_ u: Double) -> Double { smooth(0.16, 0.34, u) * (1 - smooth(0.55, 0.85, u)) }
    /// 结果出来那一下中心的闪光（录屏 4.80 秒）
    static func flash(_ u: Double) -> Double { smooth(0, 0.035, u) * (1 - smooth(0.06, 0.22, u)) }
    static func edgeAmp(_ u: Double) -> Double { 0.8 + 0.2 * smooth(0.6, 2.4, u) }
    /// 边缘光往青色漂了几成（录屏 7.0 秒：勾和边都偏青了）
    static func cyanDrift(_ u: Double) -> Double { smooth(0.9, 4.0, u) }

    /// 折射那一条带子（点）：半径跟着环走，最强在成功后 0.07–0.09 秒，0.4 秒以前没了
    struct Refraction {
        var radius: Double
        var width: Double
        var amount: Double
    }

    static func refraction(_ u: Double) -> Refraction {
        guard u >= 0 else { return Refraction(radius: 0, width: 1, amount: 0) }
        let r = 10 + 560 * ringProgress(u)
        return Refraction(radius: r, width: 26 + 0.3 * r, amount: 24 * smooth(0, 0.07, u) * (1 - smooth(0.09, 0.40, u)))
    }

    /// 折射最多挪多远（点）：R 通道挪 1.35 倍
    static let refractionMaxOffset: CGFloat = 34
}

// MARK: - Metal

final class SendGlowRenderer: NSObject, MTKViewDelegate {
    private struct Uniforms {
        var size: SIMD4<Float>
        var focus: SIMD4<Float>
        var arrow: SIMD4<Float>
        var cloud: SIMD4<Float>
        var ring: SIMD4<Float>
        var edge: SIMD4<Float>
    }

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipe: MTLRenderPipelineState

    var phase: SendGlowPhase = .idle {
        didSet { rememberSendStart() }
    }
    var reduceMotion = false
    /// 屏幕圆角（点）
    var cornerRadius: CGFloat = 0
    /// 结果那一组的中心（占画布的比例）
    var focus = CGPoint(x: 0.5, y: 0.44)

    private var lastSendStart: CFTimeInterval?
    private let t0 = CACurrentMediaTime()
    private var frame: UInt32 = 0

    init?(phase: SendGlowPhase) {
        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue(), let lib = dev.makeDefaultLibrary(),
              let vf = lib.makeFunction(name: "sg_vertex"), let ff = lib.makeFunction(name: "sg_fragment") else { return nil }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = vf
        d.fragmentFunction = ff
        d.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let p = try? dev.makeRenderPipelineState(descriptor: d) else { return nil }
        device = dev
        queue = q
        pipe = p
        self.phase = phase
        super.init()
        rememberSendStart()
    }

    /// 失败那一步不带松手的时刻：记住上一次，发送的光才能从当时的样子收掉
    private func rememberSendStart() {
        switch phase {
        case .sending(let s): lastSendStart = s
        case .success(let s, _): lastSendStart = s
        case .idle, .failure: break
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let size = view.drawableSize
        guard size.width >= 2, size.height >= 2, let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor, let cb = queue.makeCommandBuffer() else { return }
        frame &+= 1
        var U = uniforms(now: CACurrentMediaTime(), width: Float(size.width), height: Float(size.height),
                         scale: Float(view.contentScaleFactor))
        rpd.colorAttachments[0].loadAction = .dontCare
        if let e = cb.makeRenderCommandEncoder(descriptor: rpd) {
            e.setRenderPipelineState(pipe)
            e.setFragmentBytes(&U, length: MemoryLayout<Uniforms>.stride, index: 0)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            e.endEncoding()
        }
        cb.present(drawable)
        cb.commit()
    }

    private func uniforms(now: CFTimeInterval, width W: Float, height H: Float, scale: Float) -> Uniforms {
        typealias TL = SendGlowTimeline
        let reduce = reduceMotion
        let S = max(1, min(W, H))
        // 慢漂的时钟（云、边缘光的颜色）；一小时绕一圈，Float 精度不掉
        let drift: Float = reduce ? 0 : Float((now - t0).truncatingRemainder(dividingBy: 3600))
        let fx = Float(focus.x) * W, fy = Float(focus.y) * H

        var sendT: Double?
        var successU: Double?
        var failureU: Double?
        var idle: Float = 0
        switch phase {
        case .idle:
            idle = 1
        case .sending(let s):
            sendT = now - s
            idle = Float(1 - TL.smooth(0, 0.35, now - s))
        case .success(let s, let at):
            sendT = now - s
            successU = max(0, now - at)
        case .failure(let at):
            failureU = max(0, now - at)
            if let s = lastSendStart { sendT = now - s }
        }

        var arrow = SIMD4<Float>(fx, H, 0, 0)
        var cloud = SIMD4<Float>(H, 0, 0, idle)
        var particleT: Float = 0
        if let t = sendT {
            var look = TL.sending(max(0, t), reduceMotion: reduce)
            if let u = successU { TL.exitAfterSuccess(&look, u, reduceMotion: reduce) }
            if let f = failureU { TL.exitAfterFailure(&look, f, reduceMotion: reduce) }
            arrow = SIMD4(fx, Float(look.arrowY) * H, Float(look.arrowScale) * 0.24 * S, Float(look.arrowAlpha))
            cloud.x = Float(look.cloudTop) * H
            cloud.y = Float(look.cloudAmp)
            cloud.z = Float(look.soft)
            particleT = reduce ? 0 : Float(max(0, t).truncatingRemainder(dividingBy: 600))
        }

        // 没有环的时候半径给一个很大的数：边缘光整圈都算「环已经走过」
        var ring = SIMD4<Float>(1.0e6, 0, 1, 0)
        var edge = SIMD4<Float>(0, 0, 0, particleT)
        var calm: Float = 0
        if let u = successU {
            if reduce {
                edge.x = Float(0.9 * TL.smooth(0, 0.45, u))
                edge.y = 0.3
            } else {
                let p = Float(TL.ringProgress(u))
                func dist(_ x: Float, _ y: Float) -> Float { (x * x + y * y).squareRoot() }
                let far = max(dist(fx, fy), dist(W - fx, fy), dist(fx, H - fy), dist(W - fx, H - fy))
                let r0 = 0.03 * S
                let rMax = far + 0.12 * S
                ring = SIMD4(r0 + (rMax - r0) * p, Float(TL.ringAmp(u)), S * (0.05 + 0.10 * p), Float(TL.fringe(u)))
                edge.x = Float(TL.edgeAmp(u))
                edge.y = Float(TL.cyanDrift(u))
                edge.z = Float(TL.flash(u))
            }
        } else if let f = failureU {
            edge.x = Float(0.3 * TL.smooth(0.2, 0.9, f))
            calm = 1
        }

        return Uniforms(
            size: SIMD4(W, H, min(Float(cornerRadius) * scale, S * 0.5), drift),
            focus: SIMD4(fx, fy, Float(frame % 4096), calm),
            arrow: arrow,
            cloud: cloud,
            ring: ring,
            edge: edge)
    }
}

/// 只在挂在窗口上的时候跑（看不见就停，省电）
final class SendGlowMetalView: MTKView {
    var canRun = false {
        didSet { syncPaused() }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        syncPaused()
    }

    private func syncPaused() {
        isPaused = !(canRun && window != nil)
    }
}

/// 全屏的光（近黑的圆角视口）：发送中的云和粒子箭头、成功那一道环、贴着圆角边的内光。字和按钮都在 SwiftUI 那边，叠在上面
struct SendGlowCanvas: UIViewRepresentable {
    let phase: SendGlowPhase
    var reduceMotion = false
    /// 屏幕圆角（点）：边缘光沿着它走。系统没有公开读屏幕圆角的接口，由外面传进来；0 = 直角
    var cornerRadius: CGFloat = 0
    /// 结果那一组（勾、片名、按钮）的中心，占画布的比例：成功那一道环从这儿往外走
    var focus = UnitPoint(x: 0.5, y: 0.44)

    /// 「正在发往请求中心」那一行建议放的高度（占画布高的比例）：在云最亮的地方上面（设计说明 Sending composition）
    static let statusLineY: CGFloat = 0.42

    final class Coordinator { var renderer: SendGlowRenderer? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SendGlowMetalView {
        let renderer = SendGlowRenderer(phase: phase)
        let v = SendGlowMetalView(frame: .zero, device: renderer?.device)
        v.colorPixelFormat = .bgra8Unorm
        v.framebufferOnly = true
        // 旧机型（改进兼容性那一档）30 帧、1 倍像素：光都是软的，看不出差别，省电省发热
        v.preferredFramesPerSecond = frameRate(context)
        v.contentScaleFactor = Compat.legacyDevice ? 1 : min(2, max(1, context.environment.displayScale))
        v.isOpaque = true
        v.isUserInteractionEnabled = false
        v.accessibilityElementsHidden = true
        v.backgroundColor = UIColor(red: 11 / 255, green: 11 / 255, blue: 18 / 255, alpha: 1)
        v.clearColor = MTLClearColor(red: 11 / 255, green: 11 / 255, blue: 18 / 255, alpha: 1)
        if let renderer {
            v.delegate = renderer
            context.coordinator.renderer = renderer
            apply(to: renderer, context: context)
            v.canRun = true
        } else {
            v.canRun = false
        }
        return v
    }

    func updateUIView(_ v: SendGlowMetalView, context: Context) {
        guard let r = context.coordinator.renderer else { return }
        apply(to: r, context: context)
        let fps = frameRate(context)
        if v.preferredFramesPerSecond != fps { v.preferredFramesPerSecond = fps }
    }

    /// 减弱动态效果时画面几乎不动，30 帧就够
    private func frameRate(_ context: Context) -> Int {
        Compat.legacyDevice || reduceMotion || context.environment.accessibilityReduceMotion ? 30 : 60
    }

    private func apply(to r: SendGlowRenderer, context: Context) {
        r.phase = phase
        r.reduceMotion = reduceMotion || context.environment.accessibilityReduceMotion
        r.cornerRadius = max(0, cornerRadius)
        r.focus = CGPoint(x: focus.x, y: focus.y)
    }

    static func dismantleUIView(_ v: SendGlowMetalView, coordinator: Coordinator) {
        v.canRun = false
        v.delegate = nil
        coordinator.renderer = nil
    }
}

// MARK: - 折射（SwiftUI layerEffect）

extension View {
    /// 成功那一道环扫过结果那一组时的折射 + 色散（用户要求的动效，设计说明「Refraction follows the wave」）。
    /// time：成功后几秒；center：环的中心，用这个视图自己的坐标（点）；active = false 或波已经过去时什么都不做。
    /// 被挪出去的像素只能画在这个视图的范围里：给这一组四周留一点空（比如 .padding(36)）再套这个，勾和按钮被拉长时不会被裁掉
    func sendRefraction(time: Double, center: CGPoint, active: Bool) -> some View {
        let w = SendGlowTimeline.refraction(time)
        let on = active && w.amount > 0.01
        let m = SendGlowTimeline.refractionMaxOffset
        return layerEffect(
            ShaderLibrary.cuvenSendRefraction(
                .float2(Float(center.x), Float(center.y)),
                .float(Float(w.radius)),
                .float(Float(w.width)),
                .float(Float(on ? w.amount : 0))),
            maxSampleOffset: CGSize(width: m, height: m),
            isEnabled: on)
    }
}

// MARK: - 胶囊底下的光

/// 拖着「申请添加」胶囊往上时，胶囊底下那一团青紫色的柔光（用户要求的上滑发送；设计说明 Dragging：位置和光都跟着手指的同一个进度走）。
/// 纯 SwiftUI（渐变 + 模糊），整团光画在给它的框里（框多大光多大，模糊往外溢一点），框放在胶囊后面、稍微往下；不挡点按、读屏跳过。
/// intensity 0…1：光有多强。原位时给 0.2 左右（设计说明 Ready：胶囊下沿一点淡淡的青紫光），到了松手就发送的位置给 1
struct SendCapsuleGlow: View {
    let intensity: Double

    var body: some View {
        let k = min(1, max(0, intensity))
        GeometryReader { geo in
            let w = max(1, geo.size.width), h = max(1, geo.size.height)
            let blur = min(30, h * 0.2)
            ZStack {
                // 外面一大团淡的蓝紫，聚在胶囊正下方
                Ellipse()
                    .fill(RadialGradient(colors: [SendGlowPalette.violet.opacity(0.6), SendGlowPalette.blue.opacity(0.25), .clear],
                                         center: .center, startRadius: 0, endRadius: w * 0.5))
                    .frame(width: w, height: h * 0.9)
                    .offset(y: h * 0.05)
                    .blur(radius: blur)
                    .opacity(k)
                // 一条横着的光带：左青、中蓝、右紫（录屏 2.33 秒：右下角那一道青边）
                Capsule()
                    .fill(LinearGradient(colors: [SendGlowPalette.cyan, SendGlowPalette.blue, SendGlowPalette.violet],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: w * 0.86, height: h * 0.32)
                    .blur(radius: blur * 0.6)
                    .opacity(0.85 * k)
                // 白芯：拖得越高越亮
                Capsule()
                    .fill(Color.white)
                    .frame(width: w * 0.7, height: h * 0.12)
                    .blur(radius: blur * 0.35)
                    .opacity(0.9 * max(0, (k - 0.3) / 0.7))
            }
            .frame(width: w, height: h)
        }
        .blendMode(.plusLighter)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
