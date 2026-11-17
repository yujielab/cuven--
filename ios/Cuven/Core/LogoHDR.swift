import UIKit
import CoreGraphics

// MARK: - 字标的 HDR 管线（用户要求「全局海报 logo 使用 HDR 管线处理，以增强用户体验和满意度」）
//
// 「海报 logo」是片名字标（用户之前说「红色位置应该显示海报 logo」指的就是它）。字标都是 SDR 的 PNG（Apple TV / TMDB），
// 全 App 的字标都经过 LogoImage → ImagePipeline.logo，在后台多走这一道：
// 1. 画进 8 位、预乘 alpha 的 Display P3（CoreGraphics 负责换色彩空间；宽色域的字标不被压成 sRGB），逐像素去掉预乘；
// 2. 深色字标反白（判断不变，见 LogoTone）：在伽马空间里把 HSL 的亮度倒过来（每个通道加上 1 − 最大 − 最小），色相、饱和度不变。
//    以前是 SwiftUI 的 colorInvert + hueRotation(180°)，挪进管线以后 HDR 的值不再经过 SwiftUI 的颜色滤镜；
// 3. 亮部扩展（只在能显示 HDR 的屏上）：转成线性光，按最亮那个通道 v 算一个增益——v ≤ 0.25（约 sRGB 的 54%）不动，
//    往上沿平滑曲线升到 v = 1 时的 2 倍（SDR 白的两倍亮，正好一档）；三个通道乘同一个数，色相、饱和度不变。
//    中间调和暗部和原来一样，只有白字和亮色的部分「发光」；
// 4. 存成 16 位浮点、扩展线性 Display P3（和 ImageIO 解 HDR 图出来的是同一种），只有字标这一种图这么存（内存是 8 位图的两倍）。
// 显示：字标的 Image 允许高动态范围（allowedDynamicRange(.high)）；UIImage 自己算 HDR 信息（内容余量约 2），
// 屏幕当下的余量不够（户外调到最亮、低电量模式）时由系统压回去。不能显示 HDR 的屏不做第 3、4 步：只反白，存回 8 位。
enum LogoHDR {
    /// 白色字标最亮到 SDR 白的几倍
    static let peak: Float = 2.0
    /// 最亮通道（线性）低于它的不动
    static let knee: Float = 0.25

    /// 这块屏能显示 HDR 吗（第一次要画字标时在主线程看一次）
    nonisolated(unsafe) static var enabled = false
    nonisolated(unsafe) private static var known = false

    /// 看一眼窗口所在屏幕的 EDR 潜在余量（> 1 就是能显示 HDR 的屏）；还没有窗口场景时下次再看
    @MainActor static func prepare() {
        guard !known,
              let screen = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first?.screen else { return }
        enabled = screen.potentialEDRHeadroom > 1.05
        known = true
    }

    /// sRGB / Display P3 共用的传递函数：编码值（0…1，分 4096 格）→ 线性光
    private static let toLinear: [Float] = (0..<4096).map { i in
        let c = Float(i) / 4095
        return c <= 0.04045 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4)
    }

    /// 深色反白 + 亮部扩展。hdr 为 false：只反白，出 8 位 Display P3；两样都不用做：原图
    static func process(_ image: UIImage, invert: Bool, hdr: Bool) -> UIImage? {
        guard invert || hdr else { return image }
        guard let src = image.cgImage else { return nil }
        let w = src.width, h = src.height
        guard w > 0, h > 0, w * h <= 4_000_000,
              let p3 = CGColorSpace(name: CGColorSpace.displayP3),
              let linear = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) else { return nil }
        let count = w * h
        var rgba = [UInt8](repeating: 0, count: count * 4)
        let drawn: Bool = rgba.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: p3, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(src, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }

        let lut = toLinear
        let lift = peak - 1, span = 1 - knee
        var half = hdr ? [UInt16](repeating: 0, count: count * 4) : []
        for i in 0..<count {
            let o = i * 4
            let a8 = rgba[o + 3]
            guard a8 > 0 else { continue }
            let a = Float(a8) / 255
            // 去预乘（8 位的预乘是在伽马空间里做的）
            var r = min(1, Float(rgba[o]) / 255 / a)
            var g = min(1, Float(rgba[o + 1]) / 255 / a)
            var b = min(1, Float(rgba[o + 2]) / 255 / a)
            if invert {
                let d = 1 - max(r, g, b) - min(r, g, b)
                r = min(1, max(0, r + d))
                g = min(1, max(0, g + d))
                b = min(1, max(0, b + d))
            }
            if hdr {
                var lr = lut[Int(r * 4095 + 0.5)], lg = lut[Int(g * 4095 + 0.5)], lb = lut[Int(b * 4095 + 0.5)]
                let t = min(1, max(0, (max(lr, lg, lb) - knee) / span))
                let k = 1 + lift * (t * t * (3 - 2 * t))
                lr *= k
                lg *= k
                lb *= k
                // 线性空间里的预乘
                half[o] = halfBits(lr * a)
                half[o + 1] = halfBits(lg * a)
                half[o + 2] = halfBits(lb * a)
                half[o + 3] = halfBits(a)
            } else {
                rgba[o] = UInt8(min(255, (r * a * 255).rounded()))
                rgba[o + 1] = UInt8(min(255, (g * a * 255).rounded()))
                rgba[o + 2] = UInt8(min(255, (b * a * 255).rounded()))
            }
        }

        let cg: CGImage?
        if hdr {
            let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                                    | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)
            let data = half.withUnsafeBytes { Data($0) }
            cg = CGDataProvider(data: data as CFData).flatMap {
                CGImage(width: w, height: h, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: w * 8, space: linear,
                        bitmapInfo: info, provider: $0, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
            }
        } else {
            let data = Data(rgba)
            cg = CGDataProvider(data: data as CFData).flatMap {
                CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: p3,
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                        provider: $0, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
            }
        }
        guard let cg else { return nil }
        return UIImage(cgImage: cg, scale: image.scale, orientation: image.imageOrientation)
    }

    /// 32 位浮点 → 16 位浮点的位（四舍五入；小到看不出来的当 0，超出范围的取最大的有限值）
    @inline(__always) static func halfBits(_ value: Float) -> UInt16 {
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
