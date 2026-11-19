import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation

// MARK: - 光影实验室的测试画面：四段合成的场景，每段 4 秒，循环播放
//
// 火光（左半边橙红色的火焰，闪动）→ 海面（蓝青色，波光在动，右上一点日光）→ 夜色（几乎全黑，左下三盏暖色路灯、右上一轮冷色月亮）
// → 霓虹（暗紫底，左边一条品红灯管、右边一条青色灯管、正上一块黄色招牌，呼吸闪动）。
// 用来核对：光的颜色跟着画面（火是暖的、海是冷的）、位置跟着画面（左边的火照亮左边的卡）、暗场只剩局部的光、转场平滑。
// 第一次用时现画现编码（640 × 360、30 fps、H.264，约一两秒），存在缓存目录里，以后直接用。

enum TestPatternVideo {
    static let sceneDuration: Double = 4
    static let sceneNames = ["火光", "海面", "夜色", "霓虹"]
    static let width = 640
    static let height = 360
    static let fps: Int32 = 30

    static var url: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("cuven-lighting-test-v1.mp4")
    }

    /// 测试片的地址（没有就现在生成）
    static func make() async throws -> URL {
        let target = url
        if FileManager.default.fileExists(atPath: target.path) { return target }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("cuven-lighting-\(UUID().uuidString).mp4")
        try await Task.detached(priority: .userInitiated) {
            try write(to: temp)
        }.value
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: temp, to: target)
        return target
    }

    enum Failure: Error { case writer, pool }

    private static func write(to url: URL) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 4_000_000],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        guard writer.canAdd(input) else { throw Failure.writer }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? Failure.writer }
        writer.startSession(atSourceTime: .zero)

        let total = Int(sceneDuration * Double(sceneNames.count) * Double(fps))
        for i in 0..<total {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
            guard let pool = adaptor.pixelBufferPool else { throw Failure.pool }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw Failure.pool }
            draw(frame: i, into: buffer)
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else { throw writer.error ?? Failure.writer }
    }

    private static func draw(frame i: Int, into buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let ctx = CGContext(data: base, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }
        // 左上角为原点，和画面一样
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        let t = Double(i) / Double(fps)
        let scene = min(Int(t / sceneDuration), sceneNames.count - 1)
        let local = t - Double(scene) * sceneDuration
        let w = CGFloat(width), h = CGFloat(height)
        switch scene {
        case 0: fire(ctx, w, h, local)
        case 1: ocean(ctx, w, h, local)
        case 2: night(ctx, w, h, local)
        default: neon(ctx, w, h, local)
        }
    }

    // MARK: 四段场景

    private static func fill(_ ctx: CGContext, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat, _ g: CGFloat, _ b: CGFloat) {
        ctx.setFillColor(red: r, green: g, blue: b, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    }

    private static func glow(_ ctx: CGContext, at p: CGPoint, radius: CGFloat, colors: [(CGFloat, CGFloat, CGFloat, CGFloat)]) {
        let space = CGColorSpaceCreateDeviceRGB()
        let components = colors.flatMap { [$0.0, $0.1, $0.2, $0.3] }
        let locations: [CGFloat] = colors.indices.map { CGFloat($0) / CGFloat(max(colors.count - 1, 1)) }
        guard let gradient = CGGradient(colorSpace: space, colorComponents: components, locations: locations, count: colors.count) else { return }
        ctx.drawRadialGradient(gradient, startCenter: p, startRadius: 0, endCenter: p, endRadius: radius, options: [])
    }

    private static func fire(_ ctx: CGContext, _ w: CGFloat, _ h: CGFloat, _ t: Double) {
        fill(ctx, w, h, 0.05, 0.02, 0.01)
        for k in 0..<7 {
            let kk = Double(k)
            let x = w * (0.12 + 0.06 * CGFloat(kk)) + CGFloat(sin(t * 3.1 + kk) * 10)
            let flicker = 0.85 + 0.15 * sin(t * 11 + kk * 1.7) * sin(t * 7.3 + kk)
            let r = h * CGFloat(0.42 + 0.08 * sin(t * 5 + kk * 1.3)) * CGFloat(flicker)
            glow(ctx, at: CGPoint(x: x, y: h * 0.92), radius: r, colors: [
                (1.0, 0.86, 0.45, 0.95), (1.0, 0.45, 0.08, 0.75), (0.75, 0.12, 0.02, 0.35), (0.2, 0.02, 0.0, 0.0),
            ])
        }
        // 火星
        for k in 0..<14 {
            let kk = Double(k)
            let y = h * CGFloat(1 - ((t * 0.25 + kk * 0.07).truncatingRemainder(dividingBy: 1)))
            let x = w * CGFloat(0.1 + 0.03 * kk) + CGFloat(sin(t * 2 + kk) * 14)
            glow(ctx, at: CGPoint(x: x, y: y), radius: 6, colors: [(1, 0.7, 0.3, 0.9), (1, 0.4, 0.1, 0)])
        }
    }

    private static func ocean(_ ctx: CGContext, _ w: CGFloat, _ h: CGFloat, _ t: Double) {
        let space = CGColorSpaceCreateDeviceRGB()
        let sky: [CGFloat] = [0.02, 0.18, 0.42, 1, 0.0, 0.42, 0.55, 1, 0.0, 0.3, 0.42, 1]
        if let g = CGGradient(colorSpace: space, colorComponents: sky, locations: [0, 0.55, 1], count: 3) {
            ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: h), options: [])
        }
        glow(ctx, at: CGPoint(x: w * 0.78, y: h * 0.2), radius: h * 0.38, colors: [
            (0.85, 0.97, 1.0, 0.9), (0.35, 0.8, 0.95, 0.4), (0.0, 0.5, 0.7, 0.0),
        ])
        ctx.setLineWidth(3)
        for k in 0..<10 {
            let kk = Double(k)
            let y0 = h * CGFloat(0.5 + 0.05 * kk)
            ctx.setStrokeColor(red: 0.55, green: 0.92, blue: 1.0, alpha: CGFloat(0.25 + 0.05 * kk))
            ctx.beginPath()
            for xi in stride(from: 0, through: Int(w), by: 8) {
                let x = CGFloat(xi)
                let y = y0 + CGFloat(sin(Double(x) / 38 + t * 2.2 + kk) * (4 + kk))
                if xi == 0 { ctx.move(to: CGPoint(x: x, y: y)) } else { ctx.addLine(to: CGPoint(x: x, y: y)) }
            }
            ctx.strokePath()
        }
    }

    private static func night(_ ctx: CGContext, _ w: CGFloat, _ h: CGFloat, _ t: Double) {
        fill(ctx, w, h, 0.01, 0.012, 0.025)
        for k in 0..<40 {
            let x = CGFloat((k * 97) % 640) / 640 * w
            let y = CGFloat((k * 53) % 180) / 360 * h
            ctx.setFillColor(red: 0.8, green: 0.85, blue: 1, alpha: CGFloat(0.3 + 0.3 * sin(t * 2 + Double(k))))
            ctx.fill(CGRect(x: x, y: y, width: 1.5, height: 1.5))
        }
        glow(ctx, at: CGPoint(x: w * 0.82, y: h * 0.18), radius: h * 0.16, colors: [
            (0.92, 0.96, 1.0, 1.0), (0.55, 0.7, 1.0, 0.35), (0.2, 0.3, 0.6, 0.0),
        ])
        for k in 0..<3 {
            let flicker = CGFloat(0.92 + 0.08 * sin(t * 9 + Double(k) * 2))
            glow(ctx, at: CGPoint(x: w * CGFloat(0.12 + 0.13 * Double(k)), y: h * 0.7), radius: h * 0.12 * flicker, colors: [
                (1.0, 0.85, 0.55, 1.0), (1.0, 0.55, 0.15, 0.45), (0.4, 0.15, 0.0, 0.0),
            ])
        }
    }

    private static func neon(_ ctx: CGContext, _ w: CGFloat, _ h: CGFloat, _ t: Double) {
        fill(ctx, w, h, 0.03, 0.0, 0.05)
        let pulse = CGFloat(0.8 + 0.2 * sin(t * 3))
        // 左：品红竖灯管
        glow(ctx, at: CGPoint(x: w * 0.1, y: h * 0.5), radius: h * 0.55 * pulse, colors: [
            (1.0, 0.2, 0.75, 0.55), (0.6, 0.0, 0.45, 0.15), (0.2, 0.0, 0.2, 0.0),
        ])
        ctx.setFillColor(red: 1.0, green: 0.55, blue: 0.95, alpha: 1)
        ctx.fill(CGRect(x: w * 0.09, y: h * 0.15, width: 10, height: h * 0.7))
        // 右：青色横灯管
        let pulse2 = CGFloat(0.8 + 0.2 * sin(t * 2.3 + 1))
        glow(ctx, at: CGPoint(x: w * 0.8, y: h * 0.62), radius: h * 0.45 * pulse2, colors: [
            (0.1, 0.95, 1.0, 0.55), (0.0, 0.5, 0.7, 0.15), (0.0, 0.2, 0.3, 0.0),
        ])
        ctx.setFillColor(red: 0.6, green: 1.0, blue: 1.0, alpha: 1)
        ctx.fill(CGRect(x: w * 0.66, y: h * 0.61, width: w * 0.28, height: 9))
        // 上：黄色招牌
        glow(ctx, at: CGPoint(x: w * 0.47, y: h * 0.16), radius: h * 0.2, colors: [
            (1.0, 0.9, 0.3, 0.8), (0.9, 0.6, 0.0, 0.2), (0.3, 0.2, 0.0, 0.0),
        ])
        ctx.setFillColor(red: 1.0, green: 0.95, blue: 0.55, alpha: 1)
        ctx.fill(CGRect(x: w * 0.42, y: h * 0.13, width: w * 0.1, height: h * 0.06))
    }
}
