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
///
/// HDR and Dolby Vision sources are never tapped. On a real device, adding a video output to an item that plays
/// Dolby Vision changed what the screen showed: an overexposed picture with a plain BGRA output, and a green and
/// magenta one (profile 5 decoded without its Dolby Vision processing) with an explicit Rec. 709 output. So the
/// output goes on an item only once it is known to be SDR — from the host's hint (the server's stream info, the
/// file name) or from the item itself (HLS variants' VIDEO-RANGE, the video format descriptions: PQ / HLG transfer,
/// Dolby Vision codec types). Until then, and for HDR, the lighting reads a still image instead (the title's
/// artwork, set by the host), fed through the same analysis for a couple of seconds and then held.
@MainActor
public final class VideoFrameProcessor {
    struct Frame {
        let texture: any MTLTexture
        /// Keeps the frame's storage alive until the GPU is done with it
        let holder: AnyObject
    }

    public weak var player: AVPlayer?
    private weak var item: AVPlayerItem?
    private var output: AVPlayerItemVideoOutput?
    private let textureCache: CVMetalTextureCache
    private let device: any MTLDevice
    /// Frames taken since the source last changed
    public private(set) var framesSinceSourceChange = 0
    /// Increments every time the player switches to another item
    public private(set) var sourceGeneration = 0

    /// What the host knows about the source's dynamic range
    public var rangeHint: LightingSourceRange = .unknown
    /// What the item itself says (filled in asynchronously per item)
    private(set) var detectedRange: LightingSourceRange = .unknown
    private var detection: Task<Void, Never>?

    /// Still image used when frames cannot be tapped
    private var stillTexture: (any MTLTexture)?
    private var stillFeeds = 0
    /// Analysis passes a still gets before the light is simply held (lets the temporal smoothing settle)
    private let stillFeedLimit = 72

    /// Size the decoder's scaler delivers frames at (the preset's sample size; changing it swaps the output
    /// on the same item without resetting the light)
    private(set) var sampleWidth = 256
    private(set) var sampleHeight = 144
    private var needsNewOutput = false

    func setSampleSize(width: Int, height: Int) {
        guard width != sampleWidth || height != sampleHeight else { return }
        sampleWidth = width
        sampleHeight = height
        needsNewOutput = true
    }

    init(textureCache: CVMetalTextureCache, device: any MTLDevice) {
        self.textureCache = textureCache
        self.device = device
    }

    /// Frames are being tapped from the video right now
    var hasVideo: Bool { output != nil }

    /// The current source is known to be HDR / Dolby Vision (lit from the still image)
    var isHighDynamicRange: Bool { effectiveRange == .hdr }

    private var effectiveRange: LightingSourceRange {
        if rangeHint == .hdr || detectedRange == .hdr { return .hdr }
        if rangeHint == .sdr || detectedRange == .sdr { return .sdr }
        return .unknown
    }

    /// Natural size of the current picture (for the aspect-fit rect the lighting maps onto)
    var presentationSize: CGSize {
        guard let item else { return .zero }
        return item.presentationSize
    }

    /// Follows player.currentItem and puts the tap on it only for SDR; returns true when the source changed this tick
    @discardableResult
    func syncItem() -> Bool {
        let current = player?.currentItem
        var changed = false
        if current !== item {
            removeOutput()
            item = current
            detectedRange = .unknown
            detection?.cancel()
            detection = nil
            if let current { detect(current) }
            sourceGeneration += 1
            framesSinceSourceChange = 0
            stillFeeds = 0
            changed = true
        }
        guard let current else { return changed }
        let allowed = effectiveRange == .sdr
        if allowed, output == nil || needsNewOutput {
            needsNewOutput = false
            removeOutput()
            let settings: [String: any Sendable] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: sampleWidth,
                kCVPixelBufferHeightKey as String: sampleHeight,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: any Sendable](),
            ]
            let o = AVPlayerItemVideoOutput(outputSettings: settings)
            o.suppressesPlayerRendering = false
            current.add(o)
            output = o
        } else if !allowed, output != nil {
            // Learned late that this is HDR: take the tap off again
            removeOutput()
        }
        return changed
    }

    /// The newest decoded frame for this host time, if there is one we have not seen; the still image while the
    /// video cannot be tapped
    func nextFrame(hostTime: CFTimeInterval) -> Frame? {
        guard let output else {
            guard let stillTexture, stillFeeds < stillFeedLimit else { return nil }
            stillFeeds += 1
            framesSinceSourceChange += 1
            return Frame(texture: stillTexture, holder: stillTexture)
        }
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

    /// The still the lighting reads when frames cannot be tapped (nil: none). Drawn once into a small BGRA texture
    /// (aspect-fill into the sample size)
    func setStill(_ image: CGImage?) {
        stillFeeds = 0
        guard let image else { stillTexture = nil; return }
        let w = sampleWidth, h = sampleHeight
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = bytes.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else { return false }
            let iw = CGFloat(image.width), ih = CGFloat(image.height)
            guard iw > 0, ih > 0 else { return false }
            let scale = max(CGFloat(w) / iw, CGFloat(h) / ih)
            let dw = iw * scale, dh = ih * scale
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: (CGFloat(w) - dw) / 2, y: (CGFloat(h) - dh) / 2, width: dw, height: dh))
            return true
        }
        guard drawn else { stillTexture = nil; return }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.shaderRead]
        d.storageMode = .shared
        guard let t = device.makeTexture(descriptor: d) else { stillTexture = nil; return }
        bytes.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: base, bytesPerRow: w * 4)
            }
        }
        t.label = "artwork still"
        stillTexture = t
    }

    func detach() {
        removeOutput()
        detection?.cancel()
        detection = nil
        item = nil
        detectedRange = .unknown
    }

    private func removeOutput() {
        if let output, let item, item.outputs.contains(where: { $0 === output }) {
            item.remove(output)
        }
        output = nil
    }

    /// Let go of cached textures (background, memory warning)
    func flush() {
        CVMetalTextureCacheFlush(textureCache, 0)
    }

    // MARK: Dynamic range of the item

    private func detect(_ item: AVPlayerItem) {
        let asset = UncheckedSendable(value: item.asset)
        detection = Task { @MainActor [weak self, weak item] in
            // 1. Files: the video track's format descriptions
            if let range = await Self.trackRange(of: asset), !Task.isCancelled {
                self?.finish(range, for: item)
                return
            }
            // 2. HLS: the variants' VIDEO-RANGE (only an HDR answer is trusted: a missing attribute reads as SDR)
            if await Self.variantsAreHDR(asset), !Task.isCancelled {
                self?.finish(.hdr, for: item)
                return
            }
            // 3. HLS once playing: the player item's tracks carry the current variant's format descriptions
            for _ in 0..<60 {
                if Task.isCancelled { return }
                guard let item else { return }
                if item.status == .failed { return }
                let descriptions = item.tracks.compactMap(\.assetTrack)
                    .filter { $0.mediaType == .video }
                    .flatMap { Self.descriptions(of: $0) }
                if !descriptions.isEmpty {
                    self?.finish(descriptions.contains(where: Self.isHDRFormat) ? .hdr : .sdr, for: item)
                    return
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func finish(_ range: LightingSourceRange, for item: AVPlayerItem?) {
        guard let item, item === self.item else { return }
        detectedRange = range
    }

    private nonisolated static func trackRange(of asset: UncheckedSendable<AVAsset>) async -> LightingSourceRange? {
        guard let tracks = try? await asset.value.loadTracks(withMediaType: .video), !tracks.isEmpty else { return nil }
        var found = false
        for t in tracks {
            guard let fds = try? await t.load(.formatDescriptions) else { continue }
            if fds.contains(where: isHDRFormat) { return .hdr }
            if !fds.isEmpty { found = true }
        }
        return found ? .sdr : nil
    }

    private nonisolated static func variantsAreHDR(_ asset: UncheckedSendable<AVAsset>) async -> Bool {
        guard let urlAsset = asset.value as? AVURLAsset, let variants = try? await urlAsset.load(.variants) else { return false }
        return variants.contains { v in
            guard let range = v.videoAttributes?.videoRange else { return false }
            return range != .sdr
        }
    }

    /// The synchronous accessor (deprecated, still served): the player item's tracks are already loaded
    private static func descriptions(of track: AVAssetTrack) -> [CMFormatDescription] {
        track.formatDescriptions.map { $0 as! CMFormatDescription }
    }

    /// PQ or HLG transfer, or a Dolby Vision codec type
    nonisolated static func isHDRFormat(_ fd: CMFormatDescription) -> Bool {
        let dolbyVision: Set<FourCharCode> = [0x6476_6831, 0x6476_6865, 0x6476_6131, 0x6476_6176]   // dvh1 dvhe dva1 dvav
        if dolbyVision.contains(CMFormatDescriptionGetMediaSubType(fd)) { return true }
        if let transfer = CMFormatDescriptionGetExtension(fd, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String {
            return transfer == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)
                || transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
        }
        return false
    }
}
