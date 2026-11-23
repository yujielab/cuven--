import SwiftUI
import MetalKit

// MARK: - 粒子云（显示的那一边，GPU）
//
// 外观：照 Apple 配对动画复刻的那一版（和网页 web/pair.js 同一套着色器）—— 3D 球壳 5.3 万点 + 光晕 1.65 万点 + 12 缕丝各 1500 点，
// 绕斜轴滚动、几层剪切把壳「折」起来，10 秒一个循环；再按录屏拟合的逐帧光学密度校正（pair-density.png，120 帧拼一张）调浓淡。
// 所有运动都在顶点着色器里算，粒子缓冲是静态的（和网页同一个随机数种子，粒子一模一样）。
// 码：每个粒子的光学深度乘上它在屏幕上那一点的 M（PairCodec.modulationGrid → 192² 的 8 位纹理）。3D 的云在滚、码钉在屏幕平面上慢慢转，
// 相机几帧一平均，滚动的结构抹平了，码就显出来（PairDecoder 平均最近几帧的极坐标图）。

final class PairCloudRenderer: NSObject, MTKViewDelegate {
    private struct Uniforms {
        var scaleCenter: SIMD4<Float>
        var params: SIMD4<Float>          // 粒子大小比例、相位、浓淡、码平面范围
        var codeRotDensity: SIMD4<Float>  // 码平面 cos / sin、密度图一帧占的比例
        var densityOrigins: SIMD4<Float>
        var misc: SIMD4<Float>            // 两帧之间的插值、codeScale
    }
    private struct Particle { var position: SIMD4<Float>; var detail: SIMD4<Float> }

    static let loopSeconds: Double = 10
    private static let bodyPoints = 53_000, haloPoints = 16_500, wisps = 12, pointsPerWisp = 1_500
    private static let densityTile = 112, densityColumns = 12, densityFrames = 120
    private static var densityStride: Int { densityTile + 2 }
    private static var densityWidth: Int { densityStride * densityColumns }
    private static var densityHeight: Int { densityStride * (densityFrames / densityColumns) }

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let particles: MTLBuffer
    private let count: Int
    private var densityTex: MTLTexture
    private var codeTex: MTLTexture
    private var densityReady = false
    private let codeScale: Float
    private let codeSpin: Float
    private let t0 = CACurrentMediaTime()
    private var codeT0 = CACurrentMediaTime()
    private(set) var coded = false
    /// 云半径占短边的比例
    var radiusFraction: Float = 0.30

    /// 登录页能不能先显示粒子云：有配对规范和 Metal，而且不是演示模式（演示数据不连网，UI 测试也要看登录页本身）
    static var canShow: Bool { !DemoData.enabled && PairSpec.shared != nil && MTLCreateSystemDefaultDevice() != nil }

    init?(pixelFormat: MTLPixelFormat = .bgra8Unorm, spec: PairSpec? = PairSpec.shared) {
        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue(), let lib = dev.makeDefaultLibrary() else { return nil }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: "pair_cloud_vertex")
        d.fragmentFunction = lib.makeFunction(name: "pair_cloud_fragment")
        let ca = d.colorAttachments[0]!
        ca.pixelFormat = pixelFormat
        // 画在透明底上、输出预乘：颜色 over 混合，透明度累积（和网页 blendFuncSeparate 一样）
        ca.isBlendingEnabled = true
        ca.rgbBlendOperation = .add
        ca.alphaBlendOperation = .add
        ca.sourceRGBBlendFactor = .sourceAlpha
        ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
        ca.sourceAlphaBlendFactor = .one
        ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let rp = try? dev.makeRenderPipelineState(descriptor: d) else { return nil }
        let pts = Self.buildParticles()
        guard let buf = pts.withUnsafeBytes({ dev.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }),
              let dt = Self.r8Texture(dev, width: 1, height: 1, bytes: [128]),
              let ct = Self.r8Texture(dev, width: 1, height: 1, bytes: [85]) else { return nil }   // 没码时 M = 1（85 / 255 × 3）
        device = dev; queue = q; pipeline = rp; particles = buf; count = pts.count
        densityTex = dt; codeTex = ct
        codeScale = Float(spec?.codeScale ?? 3)
        codeSpin = Float(spec?.codeSpin ?? 0.05)
        super.init()
        if let t = Self.loadDensity(dev) { densityTex = t; densityReady = true }
    }

    // 和网页同一个 xorshift 种子：粒子一模一样
    private static func buildParticles() -> [Particle] {
        var state: UInt32 = 0x7a32f9d1
        func random() -> Float {
            state ^= state << 13; state ^= state >> 17; state ^= state << 5
            return Float(Double(state) / 4294967296.0)
        }
        func bell() -> Float { (random() + random() + random() + random() - 2) * 1.73 }
        var out: [Particle] = []
        out.reserveCapacity(bodyPoints + haloPoints + wisps * pointsPerWisp)
        for i in 0..<(bodyPoints + haloPoints) {
            let halo = i >= bodyPoints
            let lon = random() * 2 * .pi, z = random() * 2 - 1, eq = (1 - z * z).squareRoot(), isShell = random() < 0.82
            let radius: Float = halo ? 1.07 + 0.57 * pow(random(), 1.85) : isShell ? 0.937 + 0.101 * bell() : 0.96 * cbrt(random())
            let a = cos(lon) * eq * radius, b = sin(lon) * eq * radius, c = z * radius
            let d0 = random(), d1: Float = halo ? random() : 0.63 + 0.37 * random(), d2 = random()
            out.append(Particle(position: SIMD4(a, b, c, 0), detail: SIMD4(d0, d1, d2, halo ? 1 : 0)))
        }
        for s in 0..<wisps {
            let lon = Float(s) * 2.399963 + 0.55 * random()
            let elev = asin((Float(s) + 0.5) / Float(wisps) * 1.83 - 0.915) + 0.15 * bell()
            let idPhase = Float(s) * 1.954 + 0.5 * random()
            for _ in 0..<pointsPerWisp {
                let along = random() * 2 - 1, scatter: Float = random() < 0.22 ? 2.7 : 1
                let d0 = random(), d1 = bell() * scatter, d2 = bell() * scatter
                out.append(Particle(position: SIMD4(lon, elev, along, idPhase), detail: SIMD4(d0, d1, d2, 2)))
            }
        }
        return out
    }

    private static func r8Texture(_ dev: MTLDevice, width: Int, height: Int, bytes: [UInt8]) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: width, height: height, mipmapped: false)
        d.usage = .shaderRead
        guard let t = dev.makeTexture(descriptor: d) else { return nil }
        bytes.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width) }
        return t
    }

    /// 密度校正图（灰度 PNG）：直接读解码后的原始字节，不经过色彩管理
    private static func loadDensity(_ dev: MTLDevice) -> MTLTexture? {
        guard let url = Bundle.main.url(forResource: "pair-density", withExtension: "png"),
              let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
              img.width == densityWidth, img.height == densityHeight else { return nil }
        var bytes = [UInt8](repeating: 0, count: img.width * img.height)
        if img.bitsPerPixel == 8, img.bitsPerComponent == 8, let data = img.dataProvider?.data, let p = CFDataGetBytePtr(data) {
            let row = img.bytesPerRow
            for y in 0..<img.height { for x in 0..<img.width { bytes[y * img.width + x] = p[y * row + x] } }
        } else {
            guard let ctx = CGContext(data: &bytes, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        }
        return r8Texture(dev, width: img.width, height: img.height, bytes: bytes)
    }

    /// 换一团码：调制网格 → 8 位纹理（M / codeScale）
    func setCode(id: UInt32, secret: UInt32, spec: PairSpec) {
        let G = spec.codeGrid
        let m = PairCodec.modulationGrid(PairCodec.cellSigns(id: id, secret: secret, spec: spec), size: G, spec: spec)
        let px = m.map { UInt8(max(0, min(255, ($0 / Float(spec.codeScale) * 255).rounded()))) }
        if let t = Self.r8Texture(device, width: G, height: G, bytes: px) { codeTex = t }
        codeT0 = CACurrentMediaTime()
        coded = true
    }

    // 浓淡在一个循环里的变化（照录屏拟合）
    private static func gathering(_ ph: Float) -> Float {
        0.649 + 0.031 * cos(ph) - 0.125 * sin(ph) + 0.036 * cos(2 * ph) + 0.109 * sin(2 * ph)
            - 0.222 * cos(3 * ph) - 0.036 * sin(3 * ph) - 0.047 * cos(4 * ph) + 0.013 * sin(4 * ph)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard coded, let rpd = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cb = queue.makeCommandBuffer() else { return }
        let now = CACurrentMediaTime()
        encode(cb, target: rpd, size: view.drawableSize, scale: Float(view.contentScaleFactor), time: now - t0, codeTime: now - codeT0)
        cb.present(drawable)
        cb.commit()
    }

    /// 一帧：t 秒时的云（size：像素；scale：每点多少像素）
    func encode(_ cb: MTLCommandBuffer, target rpd: MTLRenderPassDescriptor, size: CGSize, scale: Float, time t: Double, codeTime: Double) {
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let re = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        let w = Float(size.width) / scale, h = Float(size.height) / scale          // 点
        let radius = min(w, h) * radiusFraction
        let progress = (t / Self.loopSeconds).truncatingRemainder(dividingBy: 1)
        let phase = Float(progress * 2 * .pi)
        let f = progress * Double(Self.densityFrames)
        let a = Int(f) % Self.densityFrames, b = (a + 1) % Self.densityFrames
        func left(_ i: Int) -> Float { Float((i % Self.densityColumns) * Self.densityStride + 1) / Float(Self.densityWidth) }
        func top(_ i: Int) -> Float { Float((i / Self.densityColumns) * Self.densityStride + 1) / Float(Self.densityHeight) }
        let ang = Float(codeTime) * codeSpin
        var u = Uniforms(
            scaleCenter: SIMD4(radius * 2 / w, radius * 2 / h, 0, 0),
            params: SIMD4(radius / 186.5 * scale, phase, Self.gathering(phase), Float(PairCodec.ext)),
            codeRotDensity: SIMD4(cos(ang), sin(ang),
                                  densityReady ? Float(Self.densityTile) / Float(Self.densityWidth) : 0,
                                  densityReady ? Float(Self.densityTile) / Float(Self.densityHeight) : 0),
            densityOrigins: densityReady ? SIMD4(left(a), top(a), left(b), top(b)) : SIMD4(0.5, 0.5, 0.5, 0.5),
            misc: SIMD4(Float(f - f.rounded(.down)), codeScale, 0, 0))
        re.setRenderPipelineState(pipeline)
        re.setVertexBuffer(particles, offset: 0, index: 0)
        re.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
        re.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
        re.setFragmentTexture(densityTex, index: 0)
        re.setFragmentTexture(codeTex, index: 1)
        re.drawPrimitives(type: .point, vertexStart: 0, vertexCount: count)
        re.endEncoding()
    }

    /// 离屏画一帧（自检用）：side × side 像素、t 秒时，读回 BGRA（预乘过的、透明底）
    func renderOffscreen(side: Int, time: Double, codeTime: Double = 0) -> [UInt8]? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: side, height: side, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: d), let cb = queue.makeCommandBuffer() else { return nil }
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = tex
        rpd.colorAttachments[0].storeAction = .store
        encode(cb, target: rpd, size: CGSize(width: side, height: side), scale: 1, time: time, codeTime: codeTime)
        cb.commit()
        cb.waitUntilCompleted()
        var px = [UInt8](repeating: 0, count: side * side * 4)
        px.withUnsafeMutableBytes { tex.getBytes($0.baseAddress!, bytesPerRow: side * 4, from: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0) }
        return px
    }
}

/// SwiftUI 里的粒子云：给码就显示，不给码不画
struct PairCloudView: UIViewRepresentable {
    let id: UInt32?
    let secret: UInt32?

    final class Coordinator { var renderer: PairCloudRenderer?; var code: (UInt32, UInt32)? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MTKView {
        let v = MTKView()
        v.isOpaque = false
        v.backgroundColor = .clear
        v.colorPixelFormat = .bgra8Unorm
        v.preferredFramesPerSecond = 60
        v.framebufferOnly = true
        (v.layer as? CAMetalLayer)?.isOpaque = false
        if let r = PairCloudRenderer() {
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
