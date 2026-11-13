import SwiftUI
import UIKit
import ImageIO

/// 图片：内存缓存（NSCache）+ 磁盘缓存（URLCache）+ 按显示尺寸降采样解码 —— 一屏几十张海报也不吃内存。
actor ImagePipeline {
    static let shared = ImagePipeline()

    private let memory = NSCache<NSString, UIImage>()
    private var inflight: [String: Task<UIImage?, Never>] = [:]
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

    /// 只要原始字节（字标的明暗分析用，见 LogoTone）
    func data(_ url: URL) async -> Data? {
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

/// 网络图片视图：加载前是一块暗色占位，加载完淡入
struct RemoteImage: View {
    let url: URL?
    var maxPixel: CGFloat = 900
    var contentMode: ContentMode = .fill
    var placeholder: Color = Color.white.opacity(0.06)

    @State private var image: UIImage?
    @State private var loadedURL: URL?

    var body: some View {
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
            let img = await ImagePipeline.shared.image(url, maxPixel: maxPixel)
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

    @State private var image: UIImage?
    @State private var dark = false
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: height)
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
