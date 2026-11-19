import AVFoundation
import CoreVideo
import Foundation
import Metal
import QuartzCore

/// Taps the decoded frames of whatever AVPlayer is playing, without touching the picture on screen.
///
/// · One AVPlayerItemVideoOutput per player item, asking for small (256 × 144) BGRA, IOSurface-backed,
///   Metal-compatible pixel buffers: the decoder's scaler does the downsizing, nothing full-resolution is copied.
/// · Each pixel buffer becomes a Metal texture through CVMetalTextureCache (zero copy: the texture aliases the
///   IOSurface). The CVMetalTexture is kept alive until the command buffer that reads it completes.
/// · Pull-based from the render loop: a frame is taken only when the output has a new one for the current host time,
///   so a paused or stalled video costs nothing and the last analysed frame keeps lighting the cards.
/// · The current item is checked every tick, so a new episode, a looped item or a new local file just works.
@MainActor
public final class VideoFrameProcessor {
    struct Frame {
        let texture: any MTLTexture
        let holder: CVMetalTexture
    }

    public weak var player: AVPlayer?
    private weak var item: AVPlayerItem?
    private var output: AVPlayerItemVideoOutput?
    private let textureCache: CVMetalTextureCache
    /// Frames taken since the source last changed
    public private(set) var framesSinceSourceChange = 0
    /// Increments every time the player switches to another item
    public private(set) var sourceGeneration = 0

    static let width = 256
    static let height = 144

    init(textureCache: CVMetalTextureCache) {
        self.textureCache = textureCache
    }

    var hasVideo: Bool { output != nil }

    /// Natural size of the current picture (for the aspect-fit rect the lighting maps onto)
    var presentationSize: CGSize {
        guard let item else { return .zero }
        return item.presentationSize
    }

    /// Follows player.currentItem; returns true when the source changed this tick
    @discardableResult
    func syncItem() -> Bool {
        let current = player?.currentItem
        guard current !== item else { return false }
        detach()
        if let current {
            let attributes: [String: any Sendable] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Self.width,
                kCVPixelBufferHeightKey as String: Self.height,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: any Sendable](),
            ]
            let o = AVPlayerItemVideoOutput(pixelBufferAttributes: attributes)
            o.suppressesPlayerRendering = false
            current.add(o)
            output = o
            item = current
        }
        sourceGeneration += 1
        framesSinceSourceChange = 0
        return true
    }

    /// The newest decoded frame for this host time, if there is one we have not seen
    func nextFrame(hostTime: CFTimeInterval) -> Frame? {
        guard let output else { return nil }
        let itemTime = output.itemTime(forHostTime: hostTime)
        guard itemTime.isValid, output.hasNewPixelBuffer(forItemTime: itemTime),
              let pixelBuffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) else { return nil }
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, pixelBuffer, nil,
                                                                .bgra8Unorm, w, h, 0, &cvTexture)
        guard status == kCVReturnSuccess, let cvTexture, let texture = CVMetalTextureGetTexture(cvTexture) else { return nil }
        framesSinceSourceChange += 1
        return Frame(texture: texture, holder: cvTexture)
    }

    func detach() {
        if let output, let item, item.outputs.contains(where: { $0 === output }) {
            item.remove(output)
        }
        output = nil
        item = nil
    }

    /// Let go of cached textures (background, memory warning)
    func flush() {
        CVMetalTextureCacheFlush(textureCache, 0)
    }
}
