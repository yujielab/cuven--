import SwiftUI
import UIKit
import ImageIO
import CoreImage
import CoreImage.CIFilterBuiltins

/// 详情页头部的画面：裁成画面区的宽高比、底下一段渐进式模糊；edge 是裁好以后最底下一条的平均色（头部下半截的底色）
struct HeroArt: @unchecked Sendable {
    let image: UIImage
    let edge: UIColor
}

/// 解码以后再给图做一道处理（结果和原图分开缓存）
enum ImageEffect: String, Hashable, Sendable {
    case none
    /// 底部一段渐进式模糊：上半张清楚，往下越来越糊（分集卡、预告片卡：字压在模糊上，Apple TV 的样子）
    case bottomBlur
    /// 精选卡：先裁成 3:4（很瘦的竖版主视觉留上面、海报居中），再把下半段渐进式地糊掉（字标和两行字压在上面）
    case featureCard
}

/// 图片：内存缓存（NSCache）+ 磁盘缓存（URLCache）+ 按显示尺寸降采样解码 —— 一屏几十张海报也不吃内存。
actor ImagePipeline {
    static let shared = ImagePipeline()

    private let memory = NSCache<NSString, UIImage>()
    private var inflight: [String: Task<UIImage?, Never>] = [:]
    /// 详情页头部处理好的画面（按「地址 + 尺寸 + 宽高比」）
    private var heroCache: [String: HeroArt] = [:]
    private let session: URLSession

    init() {
        memory.totalCostLimit = 160 << 20
        let cfg = URLSessionConfiguration.default
        cfg.urlCache = URLCache(memoryCapacity: 24 << 20, diskCapacity: 600 << 20)
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        cfg.timeoutIntervalForRequest = 30
        cfg.httpMaximumConnectionsPerHost = 6
        session = URLSession(configuration: cfg)
    }

    func image(_ url: URL, maxPixel: CGFloat) async -> UIImage? {
        let key = "\(url.absoluteString)#\(Int(maxPixel))" as NSString
        if let hit = memory.object(forKey: key) { return hit }
        if url.scheme == "demo" {                       // 演示数据：本地画，不走网络
            let img = DemoData.render(url, maxPixel: maxPixel)
            if let img { memory.setObject(img, forKey: key) }
            return img
        }
        if let t = inflight[key as String] { return await t.value }
        let session = self.session
        let task = Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let (data, resp) = try? await session.data(from: url),
                  let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            return Self.decode(data, maxPixel: maxPixel)
        }
        inflight[key as String] = task
        let img = await task.value
        inflight[key as String] = nil
        if let img {
            let cost = Int(img.size.width * img.size.height * img.scale * img.scale * 4)
            memory.setObject(img, forKey: key, cost: cost)
        }
        return img
    }

    /// 处理过的图（见 ImageEffect）：先照常拿原图，再在后台做一次处理，按「地址 + 尺寸 + 处理」记在内存里
    func image(_ url: URL, maxPixel: CGFloat, effect: ImageEffect) async -> UIImage? {
        guard effect != .none else { return await image(url, maxPixel: maxPixel) }
        let key = "\(url.absoluteString)#\(Int(maxPixel))#\(effect.rawValue)" as NSString
        if let hit = memory.object(forKey: key) { return hit }
        guard let base = await image(url, maxPixel: maxPixel) else { return nil }
        let out = await Task.detached(priority: .userInitiated) { ImageEffects.apply(effect, to: base) }.value ?? base
        let cost = Int(out.size.width * out.size.height * out.scale * out.scale * 4)
        memory.setObject(out, forKey: key, cost: cost)
        return out
    }

    /// 详情页头部的画面：裁成画面区的宽高比、底下渐进式模糊，顺带取底边的主色；解码和处理都在后台，结果记在内存里
    func heroArt(_ url: URL, maxPixel: CGFloat, aspect: CGFloat) async -> HeroArt? {
        let key = "\(url.absoluteString)#\(Int(maxPixel))#\(Int((aspect * 100).rounded()))"
        if let hit = heroCache[key] { return hit }
        guard let base = await image(url, maxPixel: maxPixel) else { return nil }
        guard let out = await Task.detached(priority: .userInitiated, operation: { ImageEffects.heroArt(base, aspect: aspect) }).value else { return nil }
        if heroCache.count > 24 { heroCache.removeAll() }
        heroCache[key] = out
        return out
    }

    /// 只要原始字节（字标的明暗分析用，见 LogoTone）
    func data(_ url: URL) async -> Data? {
        if url.scheme == "demo" { return DemoData.render(url, maxPixel: 400)?.pngData() }
        guard let (data, resp) = try? await session.data(from: url),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        return data
    }

    nonisolated static func decode(_ data: Data, maxPixel: CGFloat) -> UIImage? {
        let opts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithData(data as CFData, opts) else { return UIImage(data: data) }
        let thumbOpts = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(64, Int(maxPixel)),
        ] as CFDictionary
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts) else { return UIImage(data: data) }
        return UIImage(cgImage: cg)
    }
}

/// 图的后期处理（Core Image，在后台线程做；CIContext 线程安全，全 App 共用一个）
enum ImageEffects {
    nonisolated(unsafe) private static let context = CIContext(options: [.cacheIntermediates: false])

    static func apply(_ effect: ImageEffect, to image: UIImage) -> UIImage? {
        switch effect {
        case .none: return image
        case .bottomBlur: return bottomBlur(image)
        case .featureCard: return featureCard(image)
        }
    }

    /// 详情页头部：裁成画面区的宽高比（很瘦的竖版主视觉从靠近顶上取、别的从偏上取，比画面区宽的左右居中），
    /// 下段渐进式模糊（离底 42% 起，8% 以下糊到最大），再取最底下 14% 那一条的平均色
    static func heroArt(_ image: UIImage, aspect: CGFloat) -> HeroArt? {
        guard let cg = image.cgImage, aspect > 0 else { return nil }
        let W = CGFloat(cg.width), H = CGFloat(cg.height)
        guard W > 8, H > 8 else { return nil }
        var rect = CGRect(x: 0, y: 0, width: W, height: H)
        if W / H < aspect {
            let h = (W / aspect).rounded(.down)
            let slack = H - h
            let y = (slack * (W / H < 0.6 ? 0.06 : 0.25)).rounded(.down)
            rect = CGRect(x: 0, y: y, width: W, height: h)
        } else if W / H > aspect {
            let w = (H * aspect).rounded(.down)
            rect = CGRect(x: ((W - w) / 2).rounded(.down), y: 0, width: w, height: H)
        }
        guard let cropped = cg.cropping(to: rect) else { return nil }
        let base = UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
        let edge = averageColor(cropped, bottom: 0.14) ?? UIColor(white: 0.08, alpha: 1)
        let soft = bottomBlur(base, clearAbove: 0.42, fullBelow: 0.08) ?? base
        return HeroArt(image: soft, edge: edge)
    }

    /// 一张图最底下那一条（占高的 bottom）的平均色
    static func averageColor(_ cg: CGImage, bottom: CGFloat) -> UIColor? {
        let img = CIImage(cgImage: cg)
        let r = img.extent
        let avg = CIFilter.areaAverage()
        avg.inputImage = img
        avg.extent = CGRect(x: r.minX, y: r.minY, width: r.width, height: max(1, r.height * bottom))
        guard let out = avg.outputImage else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        context.render(out, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return UIColor(red: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255, blue: CGFloat(px[2]) / 255, alpha: 1)
    }

    /// 头部下半截的底色：保留取到的色相，饱和度略提，亮度压到 0.34 以下（白字压在上面看得清：F34、C58）
    static func heroTone(_ c: UIColor) -> UIColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard c.getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return UIColor(white: 0.08, alpha: 1) }
        return UIColor(hue: h, saturation: min(1, s * 1.08), brightness: min(b, 0.34), alpha: 1)
    }

    /// 精选卡：裁成 3:4。比 3:4 瘦的往高里裁——Apple TV 的竖版主视觉（约 0.46）人物多在上半截，从离顶 8% 处往下取；
    /// 2:3 的纯净海报居中取；比 3:4 宽的左右居中取。裁好再把下半段糊掉（离底 46% 起，24% 以下糊到最大）
    static func featureCard(_ image: UIImage) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        let W = CGFloat(cg.width), H = CGFloat(cg.height)
        guard W > 8, H > 8 else { return nil }
        let aspect: CGFloat = 3.0 / 4.0
        var rect = CGRect(x: 0, y: 0, width: W, height: H)
        if W / H < aspect {
            let h = (W / aspect).rounded(.down)
            let y = W / H < 0.6 ? min(H - h, (H * 0.08).rounded(.down)) : ((H - h) / 2).rounded(.down)
            rect = CGRect(x: 0, y: y, width: W, height: h)
        } else if W / H > aspect {
            let w = (H * aspect).rounded(.down)
            rect = CGRect(x: ((W - w) / 2).rounded(.down), y: 0, width: w, height: H)
        }
        // CGImage 的裁切以左上为原点
        guard let cropped = cg.cropping(to: rect) else { return nil }
        let base = UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
        return bottomBlur(base, clearAbove: 0.46, fullBelow: 0.24) ?? base
    }

    /// 渐进式模糊：用一张竖向渐变当遮罩做「可变半径模糊」（CIMaskedVariableBlur：遮罩黑处不糊、白处糊到最大）。
    /// 默认离底 48% 以上清楚，往下逐渐变糊，离底 26% 以下糊到最大（字就压在这一段上）；半径按图宽算，大小图糊得一样
    static func bottomBlur(_ image: UIImage, clearAbove: CGFloat = 0.48, fullBelow: CGFloat = 0.26) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        let input = CIImage(cgImage: cg)
        let r = input.extent
        guard r.width > 8, r.height > 8 else { return nil }
        // Core Image 的原点在左下：y 越小越靠底
        let ramp = CIFilter.linearGradient()
        ramp.point0 = CGPoint(x: r.midX, y: r.minY + r.height * clearAbove)
        ramp.color0 = CIColor.black
        ramp.point1 = CGPoint(x: r.midX, y: r.minY + r.height * fullBelow)
        ramp.color1 = CIColor.white
        guard let mask = ramp.outputImage?.cropped(to: r) else { return nil }
        let blur = CIFilter.maskedVariableBlur()
        // 先把边缘向外延展，糊的时候四边不会渗进透明、发暗
        blur.inputImage = input.clampedToExtent()
        blur.mask = mask
        blur.radius = Float(max(4, r.width * 0.03))
        guard let out = blur.outputImage?.cropped(to: r) else { return nil }
        // 按原图的色彩空间出图（Apple 的图有的是 Display P3：不压成 sRGB、不掉饱和度）；不是 RGB 的就用默认的
        let space = cg.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
        guard let done = space.flatMap({ context.createCGImage(out, from: r, format: .RGBA8, colorSpace: $0) })
                ?? context.createCGImage(out, from: r) else { return nil }
        return UIImage(cgImage: done, scale: image.scale, orientation: image.imageOrientation)
    }
}

/// 网络图片视图：加载前是一块暗色占位，加载完淡入
struct RemoteImage: View {
    let url: URL?
    var maxPixel: CGFloat = 900
    var contentMode: ContentMode = .fill
    var placeholder: Color = Color.white.opacity(0.06)
    /// 解码后的处理（分集卡、预告片卡底部的渐进式模糊）
    var effect: ImageEffect = .none

    @State private var image: UIImage?
    @State private var loadedURL: URL?

    var body: some View {
        let _ = Perf.count("image")
        ZStack {
            placeholder
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            }
        }
        .task(id: url) {
            guard let url else { image = nil; return }
            if loadedURL != url { image = nil }
            let img = await ImagePipeline.shared.image(url, maxPixel: maxPixel, effect: effect)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { image = img }
            loadedURL = url
        }
    }
}

/// 深色字标自动反白（与网页版同一套判断）：
/// 读一张缩小的字标，只看实心像素（alpha ≥ 0.5），按相对亮度分暗墨（< 0.13）与亮墨（> 0.30）；
/// 暗墨七成以上、亮墨不到一成，才算深色字标 —— 贴在压暗的画面上看不见，要反相（再把色相转半圈，彩色点缀保留色相）。
/// 纯红、白字黑描边、白字都不动。结果按 URL 记在内存和本地。
@MainActor
final class LogoTone {
    static let shared = LogoTone()
    private var known: [String: Bool] = [:]
    private var pending: [String: Task<Bool, Never>] = [:]
    private let key = "logo_tone_v1"

    init() {
        if let d = UserDefaults.standard.dictionary(forKey: key) as? [String: Bool] { known = d }
    }

    private func id(_ url: URL) -> String {
        // TMDB 同一枚字标的不同尺寸是同一个文件：按文件名记；别家（Apple TV）按整条地址记
        (url.host ?? "").contains("tmdb") ? url.lastPathComponent : url.absoluteString
    }

    func cached(_ url: URL) -> Bool? { known[id(url)] }

    func isDark(_ url: URL) async -> Bool {
        let k = id(url)
        if let v = known[k] { return v }
        if let t = pending[k] { return await t.value }
        let t = Task<Bool, Never> {
            guard let data = await ImagePipeline.shared.data(url) else { return false }
            return await Task.detached(priority: .utility) { LogoTone.measure(data) }.value
        }
        pending[k] = t
        let v = await t.value
        pending[k] = nil
        known[k] = v
        if known.count > 800 { known.removeAll() }
        UserDefaults.standard.set(known, forKey: key)
        return v
    }

    nonisolated static func measure(_ data: Data) -> Bool {
        guard let img = ImagePipeline.decode(data, maxPixel: 160), let cg = img.cgImage else { return false }
        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { return false }
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        let ok: Bool = px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return false }
        func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        var ink = 0, dim = 0, lit = 0
        var i = 0
        while i < px.count {
            let a = Double(px[i + 3])
            if a >= 128 {
                // 预乘过 alpha：除回去得到原色
                let r = min(1, Double(px[i]) / a), g = min(1, Double(px[i + 1]) / a), b = min(1, Double(px[i + 2]) / a)
                let L = 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
                ink += 1
                if L < 0.13 { dim += 1 } else if L > 0.3 { lit += 1 }
            }
            i += 4
        }
        guard ink >= 24 else { return false }
        return Double(dim) >= Double(ink) * 0.7 && Double(lit) <= Double(ink) * 0.1
    }
}

/// 字标：统一高度、宽度跟着比例走（超出可用宽度才按宽收）；深色字标自动反白
struct LogoImage: View {
    let url: URL?
    var height: CGFloat
    var alignment: Alignment = .center
    var fallback: String? = nil
    /// 宽度上限（网页版详情页：最大 320×110，按比例收，框跟着字标实际大小走）
    var maxWidth: CGFloat = .infinity

    @State private var image: UIImage?
    @State private var dark = false
    @State private var failed = false

    var body: some View {
        let _ = Perf.count("logo")
        Group {
            if let image {
                let aspect = max(0.1, image.size.width / max(1, image.size.height))
                let h = min(height, maxWidth / aspect)
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: maxWidth.isFinite ? h * aspect : nil, height: h)
                    .frame(maxWidth: .infinity, alignment: alignment)
                    .modifier(InvertIf(on: dark))
                    .shadow(color: .black.opacity(0.55), radius: 12, y: 4)
                    .transition(.opacity)
            } else if failed || url == nil, let fallback {
                Text(fallback)
                    .font(.system(size: height * 0.42, weight: .heavy))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(alignment == .leading ? .leading : .center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .frame(maxWidth: .infinity, minHeight: height, alignment: alignment)
                    .shadow(color: .black.opacity(0.5), radius: 10, y: 3)
            } else {
                Color.clear.frame(height: height)
            }
        }
        .task(id: url) {
            failed = false
            guard let url else { image = nil; return }
            if let d = LogoTone.shared.cached(url) { dark = d }
            let img = await ImagePipeline.shared.image(url, maxPixel: 900)
            let d = await LogoTone.shared.isDark(url)      // 字节已在 URLCache 里，不再走网络
            guard !Task.isCancelled else { return }
            dark = d
            if let img { withAnimation(.easeOut(duration: 0.3)) { image = img } } else { failed = true }
        }
    }
}

private struct InvertIf: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on {
            content.colorInvert().hueRotation(.degrees(180))
        } else {
            content
        }
    }
}
