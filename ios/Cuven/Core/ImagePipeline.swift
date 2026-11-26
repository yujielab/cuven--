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

final class HeroArtBox {
    let art: HeroArt
    init(_ art: HeroArt) { self.art = art }
}

/// 解码以后再给图做一道处理（结果和原图分开缓存）
enum ImageEffect: String, Hashable, Sendable {
    case none
    /// 底部一段渐进式模糊：上半张清楚，往下越来越糊（分集卡、预告片卡：字压在模糊上，Apple TV 的样子）
    case bottomBlur
    /// 精选卡：先裁成 3:4（很瘦的竖版主视觉留上面、海报居中），再把下半段渐进式地糊掉（字标和两行字压在上面）
    case featureCard
    /// 长文案的分集卡（1.3 : 1）：糊的那一段更高（离底 46% 起，26% 以下最糊），两行简介和片长压在上面
    case bottomBlurTall
    /// 片段合集的竖卡（9 : 16，用户要求加渐进式模糊）：先裁成 9 : 16，再把下段糊掉（离底 36% 起，16% 以下最糊），分类名压在上面
    case clipCard
    /// 精选电影的大竖卡（3 : 4，用户要求「内部四周向内的渐进式模糊」）：先裁成 3 : 4，四边往里渐进式地糊，
    /// 中间清楚；底下那一截糊得高一点（字标和一行字压在上面）
    case bigCard
}

/// 图片：内存缓存（NSCache）+ 磁盘缓存（URLCache）+ 按显示尺寸降采样解码 —— 一屏几十张海报也不吃内存。
actor ImagePipeline {
    static let shared = ImagePipeline()

    /// NSCache 本身线程安全：视图第一次画的时候就能同步查（cached），不用等 actor
    nonisolated(unsafe) private let memory = NSCache<NSString, UIImage>()
    private var inflight: [String: Task<UIImage?, Never>] = [:]
    /// 详情页头部处理好的画面（按「地址 + 尺寸 + 宽高比」）
    nonisolated(unsafe) private let heroCache = NSCache<NSString, HeroArtBox>()
    private let session: URLSession
    /// 磁盘缓存（URLSession 用的同一个）：命中的那次不算流量。URLCache 本身线程安全：账户页同步查大小、清掉
    nonisolated(unsafe) private let diskCache: URLCache

    init() {
        memory.totalCostLimit = 160 << 20
        heroCache.countLimit = 24
        let cfg = URLSessionConfiguration.default
        let cache = URLCache(memoryCapacity: 24 << 20, diskCapacity: 600 << 20)
        diskCache = cache
        cfg.urlCache = cache
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        cfg.timeoutIntervalForRequest = 30
        cfg.httpMaximumConnectionsPerHost = 6
        session = URLSession(configuration: cfg)
    }

    /// 海报、剧照这些图在磁盘上占了多少（账户页「使用洞察」里的「清除缓存」）
    nonisolated var diskUsage: Int64 { Int64(diskCache.currentDiskUsage) }

    /// 清掉磁盘上的图；内存里的留着，屏上正显示的图不闪（再要的时候重新下载）
    nonisolated func clearDisk() { diskCache.removeAllCachedResponses() }

    /// 内存里已经有的（不等、不解码）：视图第一次画就直接用——滑回来的卡、再打开的详情页不会先闪一下占位再淡入
    nonisolated func cached(_ url: URL, maxPixel: CGFloat, effect: ImageEffect = .none) -> UIImage? {
        memory.object(forKey: Self.key(url, maxPixel, effect))
    }

    nonisolated private static func key(_ url: URL, _ maxPixel: CGFloat, _ effect: ImageEffect) -> NSString {
        (effect == .none ? "\(url.absoluteString)#\(Int(maxPixel))" : "\(url.absoluteString)#\(Int(maxPixel))#\(effect.rawValue)") as NSString
    }

    func image(_ url: URL, maxPixel: CGFloat) async -> UIImage? {
        let key = Self.key(url, maxPixel, .none)
        if let hit = memory.object(forKey: key) { return hit }
        if url.scheme == "demo" {                       // 演示数据：本地画，不走网络
            let img = DemoData.render(url, maxPixel: maxPixel)
            if let img { memory.setObject(img, forKey: key) }
            return img
        }
        if let t = inflight[key as String] { return await t.value }
        let session = self.session, cache = self.diskCache
        let task = Task.detached(priority: .userInitiated) { () -> UIImage? in
            // 账户页「流量概览」：磁盘缓存里已经有的不算，只记真的走了网络的那次
            let cached = cache.cachedResponse(for: URLRequest(url: url)) != nil
            guard let (data, resp) = try? await session.data(from: url),
                  let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            if !cached { UsageMeter.shared.add(data.count, to: .data) }
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
        let key = Self.key(url, maxPixel, effect)
        if let hit = memory.object(forKey: key) { return hit }
        guard let base = await image(url, maxPixel: maxPixel) else { return nil }
        let out = await Task.detached(priority: .userInitiated) { ImageEffects.apply(effect, to: base) }.value ?? base
        let cost = Int(out.size.width * out.size.height * out.scale * out.scale * 4)
        memory.setObject(out, forKey: key, cost: cost)
        return out
    }

    /// 字标按这个尺寸取（最长边 900 像素：详情页最大的字标 320 点宽，3 倍屏下也够）
    static let logoPixel: CGFloat = 900

    /// 字标：解码好的原图 → 深色的反白、能显示 HDR 的屏上亮部扩展到 HDR（LogoHDR）；结果按「地址 + 明暗 + HDR」记在内存里
    func logo(_ url: URL, dark: Bool) async -> UIImage? {
        let hdr = LogoHDR.enabled
        guard dark || hdr else { return await image(url, maxPixel: Self.logoPixel) }
        let key = Self.logoKey(url, dark: dark, hdr: hdr)
        if let hit = memory.object(forKey: key) { return hit }
        guard let base = await image(url, maxPixel: Self.logoPixel) else { return nil }
        let out = await Task.detached(priority: .userInitiated) { LogoHDR.process(base, invert: dark, hdr: hdr) }.value ?? base
        memory.setObject(out, forKey: key, cost: Self.cost(out))
        return out
    }

    /// 处理好的字标，内存里有就同步给（滑回来的卡、再打开的详情页，字标第一帧就在）
    nonisolated func cachedLogo(_ url: URL, dark: Bool) -> UIImage? {
        let hdr = LogoHDR.enabled
        guard dark || hdr else { return cached(url, maxPixel: Self.logoPixel) }
        return memory.object(forKey: Self.logoKey(url, dark: dark, hdr: hdr))
    }

    nonisolated private static func logoKey(_ url: URL, dark: Bool, hdr: Bool) -> NSString {
        "\(url.absoluteString)#logo\(dark ? "-dark" : "")\(hdr ? "-hdr" : "")" as NSString
    }

    /// 一张图在内存里占多少（HDR 字标是 16 位浮点，一个像素 8 字节）
    nonisolated private static func cost(_ img: UIImage) -> Int {
        if let cg = img.cgImage { return cg.bytesPerRow * cg.height }
        return Int(img.size.width * img.size.height * img.scale * img.scale * 4)
    }

    /// 详情页头部的画面：裁成画面区的宽高比、底下渐进式模糊，顺带取底边的主色；解码和处理都在后台，结果记在内存里
    func heroArt(_ url: URL, maxPixel: CGFloat, aspect: CGFloat) async -> HeroArt? {
        if let hit = cachedHeroArt(url, maxPixel: maxPixel, aspect: aspect) { return hit }
        guard let base = await image(url, maxPixel: maxPixel) else { return nil }
        guard let out = await Task.detached(priority: .userInitiated, operation: { ImageEffects.heroArt(base, aspect: aspect) }).value else { return nil }
        heroCache.setObject(HeroArtBox(out), forKey: Self.heroKey(url, maxPixel, aspect))
        return out
    }

    /// 处理好的头部画面，内存里有就同步给（再打开同一部片的详情页，头部直接是好的，不再淡入一遍）
    nonisolated func cachedHeroArt(_ url: URL, maxPixel: CGFloat, aspect: CGFloat) -> HeroArt? {
        heroCache.object(forKey: Self.heroKey(url, maxPixel, aspect))?.art
    }

    nonisolated private static func heroKey(_ url: URL, _ maxPixel: CGFloat, _ aspect: CGFloat) -> NSString {
        "\(url.absoluteString)#\(Int(maxPixel))#\(Int((aspect * 100).rounded()))" as NSString
    }

    /// 只要原始字节（字标的明暗分析用，见 LogoTone）
    func data(_ url: URL) async -> Data? {
        if url.scheme == "demo" { return DemoData.render(url, maxPixel: 400)?.pngData() }
        let cached = diskCache.cachedResponse(for: URLRequest(url: url)) != nil
        guard let (data, resp) = try? await session.data(from: url),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        if !cached { UsageMeter.shared.add(data.count, to: .data) }
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

/// 图的后期处理（Core Image，在后台线程做；CIContext 线程安全，全 App 共用一个）。
/// 用低优先级的 GPU 队列：渐进式模糊是在 GPU 上算的，滑一排分集卡、精选卡时每张新卡都要糊一次，
/// 以前和系统合成画面抢同一块 GPU，滑动掉帧（卡顿）；结果一模一样，只是忙的时候让画面先走
enum ImageEffects {
    nonisolated(unsafe) private static let context = CIContext(options: [.cacheIntermediates: false, .priorityRequestLow: true])

    static func apply(_ effect: ImageEffect, to image: UIImage) -> UIImage? {
        switch effect {
        case .none: return image
        case .bottomBlur: return bottomBlur(image)
        case .featureCard: return featureCard(image)
        case .bottomBlurTall: return bottomBlur(image, clearAbove: 0.46, fullBelow: 0.26)
        case .clipCard: return clipCard(image)
        case .bigCard: return bigCard(image)
        }
    }

    /// 精选电影的大竖卡：裁成 3 : 4（和精选卡同一个裁法：很瘦的竖版主视觉从离顶 8% 往下取，2:3 海报居中取），
    /// 再四边往里糊——左右各 14%、顶上 12% 由糊到清楚，底下离底 14% 以下最糊、36% 以上清楚
    static func bigCard(_ image: UIImage) -> UIImage? {
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
        guard let cropped = cg.cropping(to: rect) else { return nil }
        let base = UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
        return edgeBlur(base, side: 0.14, top: 0.12, bottomFull: 0.14, bottomClear: 0.36) ?? base
    }

    /// 四边往里的渐进式模糊：遮罩是四条线性渐变取最大（边上白 = 糊到最大，往里到 side / top / bottomClear 处变黑 = 清楚），
    /// 用可变半径模糊按遮罩糊；半径按图宽算（宽的 2.6%），大小图糊得一样
    static func edgeBlur(_ image: UIImage, side: CGFloat, top: CGFloat, bottomFull: CGFloat, bottomClear: CGFloat) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        let input = CIImage(cgImage: cg)
        let r = input.extent
        guard r.width > 8, r.height > 8 else { return nil }
        func ramp(_ edge: CGPoint, _ inner: CGPoint) -> CIImage? {
            let g = CIFilter.linearGradient()
            g.point0 = edge
            g.color0 = CIColor.white
            g.point1 = inner
            g.color1 = CIColor.black
            return g.outputImage?.cropped(to: r)
        }
        // Core Image 的原点在左下：y 小的是底边
        let parts: [CIImage?] = [
            ramp(CGPoint(x: r.minX, y: r.midY), CGPoint(x: r.minX + r.width * side, y: r.midY)),
            ramp(CGPoint(x: r.maxX, y: r.midY), CGPoint(x: r.maxX - r.width * side, y: r.midY)),
            ramp(CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.midX, y: r.maxY - r.height * top)),
            ramp(CGPoint(x: r.midX, y: r.minY + r.height * bottomFull), CGPoint(x: r.midX, y: r.minY + r.height * bottomClear)),
        ]
        let ramps = parts.compactMap { $0 }
        guard ramps.count == 4 else { return nil }
        var mask = ramps[0]
        for m in ramps.dropFirst() {
            let mx = CIFilter.maximumCompositing()
            mx.inputImage = m
            mx.backgroundImage = mask
            guard let out = mx.outputImage else { return nil }
            mask = out
        }
        let blur = CIFilter.maskedVariableBlur()
        // 先把边缘向外延展，糊的时候四边不会渗进透明、发暗
        blur.inputImage = input.clampedToExtent()
        blur.mask = mask.cropped(to: r)
        blur.radius = Float(max(4, r.width * 0.026))
        guard let out = blur.outputImage?.cropped(to: r) else { return nil }
        let space = cg.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
        guard let done = space.flatMap({ context.createCGImage(out, from: r, format: .RGBA8, colorSpace: $0) })
                ?? context.createCGImage(out, from: r) else { return nil }
        return UIImage(cgImage: done, scale: image.scale, orientation: image.imageOrientation)
    }

    /// 片段合集的竖卡：裁成 9 : 16（比它瘦的 Apple TV 竖版主视觉从离顶 6% 往下取，人物多在上半截；
    /// 比它宽的 2:3 海报左右居中取），再把下段渐进式地糊掉——不管画面原来是什么比例，糊的那一段都落在卡的同一个高度上
    static func clipCard(_ image: UIImage) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        let W = CGFloat(cg.width), H = CGFloat(cg.height)
        guard W > 8, H > 8 else { return nil }
        let aspect: CGFloat = 9.0 / 16.0
        var rect = CGRect(x: 0, y: 0, width: W, height: H)
        if W / H < aspect {
            let h = (W / aspect).rounded(.down)
            rect = CGRect(x: 0, y: min(H - h, (H * 0.06).rounded(.down)), width: W, height: h)
        } else if W / H > aspect {
            let w = (H * aspect).rounded(.down)
            rect = CGRect(x: ((W - w) / 2).rounded(.down), y: 0, width: w, height: H)
        }
        guard let cropped = cg.cropping(to: rect) else { return nil }
        let base = UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
        return bottomBlur(base, clearAbove: 0.36, fullBelow: 0.16) ?? base
    }

    /// 详情页头部：裁成画面区的宽高比（很瘦的竖版主视觉从靠近顶上取、别的从偏上取，比画面区宽的左右居中），
    /// 下段渐进式模糊（离底 17% 起，2% 以下糊到最大），再取最底下 14% 那一条的平均色
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
        // 渐进式模糊只在最下面那一截：画面高的 83% 起糊、98% 糊满，底边就是字标上沿（用户要求；
        // 后来用户要求所有渐进模糊再矮一些、轻一些：原来 76% 起糊）
        let soft = bottomBlur(base, clearAbove: 0.17, fullBelow: 0.02) ?? base
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
    /// 2:3 的纯净海报居中取；比 3:4 宽的左右居中取。裁好再把下段糊掉（离底 34% 起，16% 以下糊到最大）
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
        return bottomBlur(base, clearAbove: 0.34, fullBelow: 0.16) ?? base
    }

    /// 渐进式模糊：用一张竖向渐变当遮罩做「可变半径模糊」（CIMaskedVariableBlur：遮罩黑处不糊、白处糊到最大）。
    /// 默认离底 34% 以上清楚，往下逐渐变糊，离底 16% 以下糊到最大（字就压在这一段上）；半径按图宽算（宽的 1.8%），大小图糊得一样。
    /// 用户要求所有位置的渐进模糊都矮一些、轻一些：原来离底 48% 起、26% 以下最糊，半径是宽的 3%
    static func bottomBlur(_ image: UIImage, clearAbove: CGFloat = 0.34, fullBelow: CGFloat = 0.16) -> UIImage? {
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
        blur.radius = Float(max(3, r.width * 0.018))
        guard let out = blur.outputImage?.cropped(to: r) else { return nil }
        // 按原图的色彩空间出图（Apple 的图有的是 Display P3：不压成 sRGB、不掉饱和度）；不是 RGB 的就用默认的
        let space = cg.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
        guard let done = space.flatMap({ context.createCGImage(out, from: r, format: .RGBA8, colorSpace: $0) })
                ?? context.createCGImage(out, from: r) else { return nil }
        return UIImage(cgImage: done, scale: image.scale, orientation: image.imageOrientation)
    }
}

/// 网络图片视图：加载前是一块暗色占位，加载完淡入。
/// 按要显示的尺寸（maxPixel）取图；尺寸后来变大了就换一张更清楚的（同一张图原地换、不再淡入一遍）。
/// 用户截图：主页年份卡的画面、演员简介弹层的照片有时糊成一片色块——那是一张 64 像素的小图被放大了：
/// 这些地方按量出来的宽算 maxPixel，弹层、懒加载的一排第一次排版时宽常常还是 0，以前就按 0（解码时兜到 64 像素）取了，
/// 之后量出真的宽，地址没变就不再取。现在没量出尺寸之前不取，尺寸变大了重取
struct RemoteImage: View {
    let url: URL?
    let maxPixel: CGFloat
    let contentMode: ContentMode
    let placeholder: Color
    /// 解码后的处理（分集卡、预告片卡底部的渐进式模糊）
    let effect: ImageEffect
    /// 图到了（或者内存里本来就有）：给外面收骨架屏用（探索的画幅）
    let onLoad: (() -> Void)?

    @State private var image: UIImage?
    @State private var loadedURL: URL?
    /// 现在这张是按多大取的（换了更大的尺寸才重取）
    @State private var loadedPixel: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 比这还小，是还没量出尺寸（第一次排版前的 0）：先不取
    static let minPixel: CGFloat = 48

    /// 内存里已经有这张图：第一次画就直接是它（不闪占位、不再淡入一遍）
    init(url: URL?, maxPixel: CGFloat = 900, contentMode: ContentMode = .fill,
         placeholder: Color = Color.white.opacity(0.06), effect: ImageEffect = .none, onLoad: (() -> Void)? = nil) {
        self.url = url
        self.maxPixel = maxPixel
        self.contentMode = contentMode
        self.placeholder = placeholder
        self.effect = effect
        self.onLoad = onLoad
        let hit = maxPixel < Self.minPixel ? nil : url.flatMap { ImagePipeline.shared.cached($0, maxPixel: maxPixel, effect: effect) }
        _image = State(initialValue: hit)
        _loadedURL = State(initialValue: hit == nil ? nil : url)
        _loadedPixel = State(initialValue: hit == nil ? 0 : maxPixel)
    }

    private struct LoadKey: Equatable {
        let url: URL?
        let pixel: Int
    }

    var body: some View {
        let _ = Perf.count("image")
        ZStack {
            placeholder
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    // 第一次载入：从一点点模糊里淡入，不带方向（「减弱动态效果」时只淡入）
                    .transition(reduceMotion ? .opacity : .dsBlurFade(radius: 8))
            }
        }
        .onAppear { if image != nil { onLoad?() } }
        .task(id: LoadKey(url: url, pixel: maxPixel.isFinite ? Int(maxPixel) : 0)) {
            guard let url else { image = nil; loadedURL = nil; loadedPixel = 0; return }
            guard maxPixel.isFinite, maxPixel >= Self.minPixel else { return }
            let sameURL = loadedURL == url && image != nil
            // 手里这张够清楚（尺寸变小、或者只大了一点点）：不重取
            if sameURL, loadedPixel >= maxPixel * 0.8 { return }
            if !sameURL { image = nil }
            let img = await ImagePipeline.shared.image(url, maxPixel: maxPixel, effect: effect)
            guard !Task.isCancelled else { return }
            if sameURL {
                // 同一张图换成更清楚的：原地换，不再淡入（取不到就留着原来那张）
                if let img { image = img; loadedPixel = maxPixel }
            } else {
                withAnimation(.easeOut(duration: 0.32)) { image = img }
                loadedURL = url
                loadedPixel = img == nil ? 0 : maxPixel
                if img != nil { onLoad?() }
            }
        }
    }
}

/// 按顺序试几张图：前面那张取不到（地址失效、服务器出错、解不开）就换下一张；全都取不到就留着占位。
/// 用户截图：刷视频页整页黑着——那一部只试一张竖版画面，它取不到时没有退路（片库里的片子都有 TMDB 海报，却轮不到它）。
/// 候选换了（比如全量结果到了，多了纯净海报）：从头再试，排在前面的取到了才换上去；画面上那张本来就是第一张就不动
struct RemoteImageChain: View {
    let urls: [URL]
    let maxPixel: CGFloat
    let contentMode: ContentMode
    let placeholder: Color
    /// 解码后的处理（合集竖卡底部的渐进式模糊）
    let effect: ImageEffect

    @State private var image: UIImage?
    @State private var shown: URL?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(urls: [URL], maxPixel: CGFloat, contentMode: ContentMode = .fill, placeholder: Color = .clear,
         effect: ImageEffect = .none) {
        self.urls = urls
        self.maxPixel = maxPixel
        self.contentMode = contentMode
        self.placeholder = placeholder
        self.effect = effect
        // 内存里已经有第一张：第一帧就是它（滑回来的那一页不闪）
        if maxPixel >= RemoteImage.minPixel, let first = urls.first,
           let hit = ImagePipeline.shared.cached(first, maxPixel: maxPixel, effect: effect) {
            _image = State(initialValue: hit)
            _shown = State(initialValue: first)
        }
    }

    private struct LoadKey: Equatable {
        let urls: [URL]
        let pixel: Int
    }

    var body: some View {
        ZStack {
            placeholder
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(reduceMotion ? .opacity : .dsBlurFade(radius: 8))
            }
        }
        .task(id: LoadKey(urls: urls, pixel: maxPixel.isFinite ? Int(maxPixel) : 0)) {
            guard maxPixel.isFinite, maxPixel >= RemoteImage.minPixel else { return }
            for url in urls {
                // 排在它前面的都取不到，它已经在画面上了：不用再取
                if url == shown, image != nil { return }
                if let img = await ImagePipeline.shared.image(url, maxPixel: maxPixel, effect: effect) {
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeOut(duration: 0.32)) { image = img }
                    shown = url
                    return
                }
                if Task.isCancelled { return }
            }
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
        saveSoon()
        return v
    }

    /// 判过的结果攒一会儿再写进本机：以前每判一枚就把整张表（最多 800 项）写一遍 UserDefaults——
    /// 主线程上转属性列表、发变更通知，第一次滑过一排新片时每张新字标都来一次（卡顿）。现在 1.5 秒内的合成一次写
    private var saveTask: Task<Void, Never>?

    private func saveSoon() {
        guard saveTask == nil else { return }
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self else { return }
            self.saveTask = nil
            UserDefaults.standard.set(self.known, forKey: self.key)
        }
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

/// 字标：统一高度、宽度跟着比例走（超出可用宽度才按宽收）；深色字标自动反白。
/// 走字标管线（ImagePipeline.logo → LogoHDR）：反白在管线里做；能显示 HDR 的屏上亮部扩展到 HDR，这里允许高动态范围显示
struct LogoImage: View {
    let url: URL?
    var height: CGFloat
    var alignment: Alignment = .center
    var fallback: String? = nil
    /// 宽度上限（网页版详情页：最大 320×110，按比例收，框跟着字标实际大小走）
    var maxWidth: CGFloat = .infinity

    @State private var image: UIImage?
    @State private var failed = false
    @State private var loadedURL: URL?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 内存里已经有这枚处理好的字标（明暗也判过了）：第一次画就直接是它
    init(url: URL?, height: CGFloat, alignment: Alignment = .center, fallback: String? = nil, maxWidth: CGFloat = .infinity) {
        self.url = url
        self.height = height
        self.alignment = alignment
        self.fallback = fallback
        self.maxWidth = maxWidth
        LogoHDR.prepare()
        if let url, let d = LogoTone.shared.cached(url), let hit = ImagePipeline.shared.cachedLogo(url, dark: d) {
            _image = State(initialValue: hit)
            _loadedURL = State(initialValue: url)
        }
    }

    var body: some View {
        let _ = Perf.count("logo")
        Group {
            if let image {
                let aspect = max(0.1, image.size.width / max(1, image.size.height))
                let h = min(height, maxWidth / aspect)
                Image(uiImage: image)
                    .resizable()
                    // HDR 字标（LogoHDR）：允许高动态范围，白字比 SDR 白最多亮一倍；SDR 的字标不受影响
                    .allowedDynamicRange(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: maxWidth.isFinite ? h * aspect : nil, height: h)
                    .frame(maxWidth: .infinity, alignment: alignment)
                    .shadow(color: .black.opacity(0.55), radius: 12, y: 4)
                    // 字标是透明底：用透明的模糊淡入，不然透明的地方会先糊成一块黑框
                    .transition(reduceMotion ? .opacity : .dsBlurFadeClear(radius: 10))
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
            if loadedURL == url, image != nil { return }
            LogoHDR.prepare()
            // 先取原图（字节顺带进了磁盘缓存），再判明暗（读的是缓存里的字节，不再走网络），最后走字标管线（反白 / HDR）
            guard await ImagePipeline.shared.image(url, maxPixel: ImagePipeline.logoPixel) != nil else {
                if !Task.isCancelled { failed = true }
                return
            }
            let d = await LogoTone.shared.isDark(url)
            let img = await ImagePipeline.shared.logo(url, dark: d)
            guard !Task.isCancelled else { return }
            if let img { withAnimation(.easeOut(duration: 0.36)) { image = img }; loadedURL = url } else { failed = true }
        }
    }
}
