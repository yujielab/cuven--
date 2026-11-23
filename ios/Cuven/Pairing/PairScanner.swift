import Foundation
import AVFoundation
import Metal
import CoreVideo

// MARK: - 扫描：相机 → GPU 算「蓝色程度」→ 解码器
//
// 后置相机 1920×1080、BGRA；每一帧在 GPU 上裁出正中间的正方形（屏幕上的那个圆框）、缩成 256 × 256、
// 算 B − R（蓝色的粒子在白底 / 黑底上都是正的，背景是 0）→ PairDecoder（椭圆、极坐标、网络、匹配滤波、Viterbi）。
// 解码在一条串行队列上跑，上一帧没算完就丢掉这一帧；同一个结果连着两次才回调。

final class PairScanner: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private struct InkParams { var ox: UInt32; var oy: UInt32; var side: UInt32; var dst: UInt32; var scale: Float }

    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "cuven.pair.scan", qos: .userInitiated)
    private let decoder: PairDecoder
    private let device: MTLDevice?
    private let cq: MTLCommandQueue?
    private let ink: MTLComputePipelineState?
    private var cache: CVMetalTextureCache?
    private let inkBuf: MTLBuffer?
    private var busy = false
    private var done = false
    private let cam: Int
    var onResult: ((UInt32, UInt32) -> Void)?
    /// 调试：最近一帧的「看清了几分」（导频的相关度，0–1）
    var onScore: ((Float) -> Void)?

    /// 相机现在的状态（扫描页圆圈下面显示）：以前相机起不来就是一个空圆圈，看不出为什么
    enum CamState: Equatable { case starting, running, noCamera, paused(String), failed(String) }
    var onState: ((CamState) -> Void)?
    private func report(_ s: CamState) { DispatchQueue.main.async { self.onState?(s) } }
    private var observers: [NSObjectProtocol] = []
    private var restarted = false

    init?(decoder: PairDecoder? = PairDecoder()) {
        guard let decoder else { return nil }
        self.decoder = decoder
        cam = decoder.spec.decode.cam
        let dev = MTLCreateSystemDefaultDevice()
        device = dev
        cq = dev?.makeCommandQueue()
        ink = dev?.makeDefaultLibrary()?.makeFunction(name: "pair_ink").flatMap { try? dev?.makeComputePipelineState(function: $0) }
        inkBuf = dev?.makeBuffer(length: decoder.spec.decode.cam * decoder.spec.decode.cam * 4, options: .storageModeShared)
        super.init()
        if let dev { CVMetalTextureCacheCreate(nil, nil, dev, nil, &cache) }
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { [weak self] n in
            let raw = (n.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int) ?? -1
            self?.report(.paused(Self.reasonText(AVCaptureSession.InterruptionReason(rawValue: raw))))
        })
        observers.append(nc.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil) { [weak self] _ in
            self?.report(.running)
        })
        observers.append(nc.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] n in
            guard let self else { return }
            let e = n.userInfo?[AVCaptureSessionErrorKey] as? NSError
            // 媒体服务重置之类：重启一次；再坏就报出来
            if !restarted {
                restarted = true
                self.queue.async {
                    if !self.session.isRunning { self.session.startRunning() }
                    self.report(self.session.isRunning ? .running : .failed("相机出错了（\(e?.code ?? 0)）"))
                }
            } else {
                report(.failed("相机出错了（\(e?.code ?? 0)）"))
            }
        })
    }

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    private static func reasonText(_ r: AVCaptureSession.InterruptionReason?) -> String {
        switch r {
        case .videoDeviceNotAvailableWithMultipleForegroundApps?: return "几个 App 同时在前台时相机被系统暂停了：把 Cuven 切到全屏再试"
        case .videoDeviceInUseByAnotherClient?: return "相机正被别的 App 用着"
        case .videoDeviceNotAvailableDueToSystemPressure?: return "手机太热了，相机暂停了一下"
        case .videoDeviceNotAvailableInBackground?: return "Cuven 在后台，相机暂停了"
        default: return "相机被系统暂停了"
        }
    }

    /// 后置相机：优先多摄的虚拟设备（离得太近时自动换超广角微距，贴近屏幕也对得上焦），没有再退回广角
    private static func backCamera() -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
        let found = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .back).devices
        for t in types { if let d = found.first(where: { $0.deviceType == t }) { return d } }
        return AVCaptureDevice.default(for: .video)
    }

    static var authorized: Bool { AVCaptureDevice.authorizationStatus(for: .video) == .authorized }
    static func requestAccess() async -> Bool { await AVCaptureDevice.requestAccess(for: .video) }

    func start() {
        report(.starting)
        queue.async { [self] in
            if session.inputs.isEmpty {
                session.beginConfiguration()
                // iPhone Duo 展开、iPad：几个 App 同时在前台（分屏 / 多窗口）时，不开这一项相机会被系统暂停 —— 扫描框里就是空的
                if session.isMultitaskingCameraAccessSupported { session.isMultitaskingCameraAccessEnabled = true }
                session.sessionPreset = session.canSetSessionPreset(.hd1920x1080) ? .hd1920x1080 : .high
                guard let cam = Self.backCamera(), let input = try? AVCaptureDeviceInput(device: cam), session.canAddInput(input) else {
                    session.commitConfiguration()
                    report(.noCamera)
                    return
                }
                session.addInput(input)
                if (try? cam.lockForConfiguration()) != nil {
                    if cam.isFocusModeSupported(.continuousAutoFocus) { cam.focusMode = .continuousAutoFocus }
                    if cam.isAutoFocusRangeRestrictionSupported { cam.autoFocusRangeRestriction = .near }
                    if cam.isExposureModeSupported(.continuousAutoExposure) { cam.exposureMode = .continuousAutoExposure }
                    cam.unlockForConfiguration()
                }
                let out = AVCaptureVideoDataOutput()
                out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                out.alwaysDiscardsLateVideoFrames = true
                out.setSampleBufferDelegate(self, queue: queue)
                if session.canAddOutput(out) { session.addOutput(out) }
                session.commitConfiguration()
            }
            done = false
            restarted = false
            decoder.reset()
            if !session.isRunning { session.startRunning() }
            if session.isRunning { report(.running) }
            else if session.isInterrupted { report(.paused("相机被系统暂停了")) }
            else { report(.failed("相机没有启动")) }
        }
    }

    /// 现在用的后置相机（预览层按它算横竖）
    var camera: AVCaptureDevice? { (session.inputs.first as? AVCaptureDeviceInput)?.device }

    func stop() { queue.async { [self] in if session.isRunning { session.stopRunning() } } }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !busy, !done, let pb = CMSampleBufferGetImageBuffer(sampleBuffer), let frame = inkFrame(pb) else { return }
        busy = true
        defer { busy = false }
        let hit = decoder.feed(ink: frame)
        onScore?(decoder.lastScore)
        if let hit {
            done = true
            DispatchQueue.main.async { self.onResult?(hit.id, hit.secret) }
        }
    }

    /// 相机帧 → cam × cam 的蓝色程度（GPU）
    private func inkFrame(_ pb: CVPixelBuffer) -> [Float]? {
        guard let cache, let cq, let ink, let inkBuf else { return nil }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        var cvTex: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, .bgra8Unorm, w, h, 0, &cvTex) == kCVReturnSuccess,
              let ct = cvTex, let tex = CVMetalTextureGetTexture(ct),
              let cb = cq.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else { return nil }
        let side = min(w, h)
        var p = InkParams(ox: UInt32((w - side) / 2), oy: UInt32((h - side) / 2), side: UInt32(side), dst: UInt32(cam), scale: 1.6)
        enc.setComputePipelineState(ink)
        enc.setTexture(tex, index: 0)
        enc.setBuffer(inkBuf, offset: 0, index: 0)
        enc.setBytes(&p, length: MemoryLayout<InkParams>.stride, index: 1)
        enc.dispatchThreads(MTLSize(width: cam, height: cam, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        let ptr = inkBuf.contents().bindMemory(to: Float.self, capacity: cam * cam)
        return Array(UnsafeBufferPointer(start: ptr, count: cam * cam))
    }
}
