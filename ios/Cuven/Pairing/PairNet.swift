import Foundation
import Metal

// MARK: - 解码网络（GPU）
//
// 极坐标图（2 × 24 × 192：归一过的蓝色程度 + 半径）→ 每个点的 D 软正负（24 × 192）。
// 七层 3×3 空洞卷积（角向首尾相接、径向补 0）+ ReLU，最后 1×1 + tanh；约 3.2 万个参数、一帧约 1.5 亿次乘加。
// 权重：cpc1.bin（float32 小端，按层 [weight(cout, cin, 3, 3), bias(cout)]，最后 head），层的形状在 cpc1.json。
// 在 Metal 上逐层跑（PairShaders.metal 的 pair_conv / pair_head）；没有 Metal 时退回 CPU（同一套算法，慢一些）。

final class PairNet {
    struct Layer: Decodable { let cin: Int; let cout: Int; let dr: Int; let da: Int; let offset: Int }
    private struct Meta: Decodable {
        struct Head: Decodable { let cin: Int; let offset: Int }
        let input: [Int]; let layers: [Layer]; let head: Head; let floats: Int
    }
    private struct ConvParams { var cin: UInt32; var cout: UInt32; var h: UInt32; var w: UInt32; var dr: Int32; var da: Int32; var woff: UInt32; var boff: UInt32 }

    let layers: [Layer]
    let h: Int, w: Int
    private let headCin: Int, headOff: Int
    private let weights: [Float]
    private let device: MTLDevice?
    private let queue: MTLCommandQueue?
    private let conv: MTLComputePipelineState?
    private let head: MTLComputePipelineState?
    private let wbuf: MTLBuffer?
    private let bufA: MTLBuffer?, bufB: MTLBuffer?, outBuf: MTLBuffer?
    private(set) var usesGPU = false

    init?(bundle: Bundle = .main) {
        guard let mu = bundle.url(forResource: "cpc1", withExtension: "json"),
              let bu = bundle.url(forResource: "cpc1", withExtension: "bin"),
              let md = try? Data(contentsOf: mu), let meta = try? JSONDecoder().decode(Meta.self, from: md),
              let bd = try? Data(contentsOf: bu), bd.count == meta.floats * 4 else { return nil }
        layers = meta.layers; h = meta.input[1]; w = meta.input[2]
        headCin = meta.head.cin; headOff = meta.head.offset
        weights = bd.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let maxC = max(meta.input[0], layers.map(\.cout).max() ?? 1)
        let dev = MTLCreateSystemDefaultDevice()
        let lib = dev?.makeDefaultLibrary()
        device = dev
        queue = dev?.makeCommandQueue()
        conv = lib?.makeFunction(name: "pair_conv").flatMap { try? dev?.makeComputePipelineState(function: $0) }
        head = lib?.makeFunction(name: "pair_head").flatMap { try? dev?.makeComputePipelineState(function: $0) }
        wbuf = weights.withUnsafeBytes { dev?.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
        bufA = dev?.makeBuffer(length: maxC * h * w * 4, options: .storageModeShared)
        bufB = dev?.makeBuffer(length: maxC * h * w * 4, options: .storageModeShared)
        outBuf = dev?.makeBuffer(length: h * w * 4, options: .storageModeShared)
        usesGPU = queue != nil && conv != nil && head != nil && wbuf != nil && bufA != nil && bufB != nil && outBuf != nil
    }

    /// input：2 × h × w → h × w（-1…1）
    func run(_ input: [Float]) -> [Float] {
        if usesGPU, let r = runGPU(input) { return r }
        return runCPU(input)
    }

    private func runGPU(_ input: [Float]) -> [Float]? {
        guard let queue, let conv, let head, let wbuf, let bufA, let bufB, let outBuf,
              let cb = queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else { return nil }
        input.withUnsafeBytes { src in bufA.contents().copyMemory(from: src.baseAddress!, byteCount: src.count) }
        var src = bufA, dst = bufB
        enc.setComputePipelineState(conv)
        for l in layers {
            var p = ConvParams(cin: UInt32(l.cin), cout: UInt32(l.cout), h: UInt32(h), w: UInt32(w), dr: Int32(l.dr), da: Int32(l.da),
                               woff: UInt32(l.offset), boff: UInt32(l.offset + l.cout * l.cin * 9))
            enc.setBuffer(src, offset: 0, index: 0)
            enc.setBuffer(dst, offset: 0, index: 1)
            enc.setBuffer(wbuf, offset: 0, index: 2)
            enc.setBytes(&p, length: MemoryLayout<ConvParams>.stride, index: 3)
            enc.dispatchThreads(MTLSize(width: w, height: h, depth: l.cout), threadsPerThreadgroup: MTLSize(width: 32, height: 4, depth: 1))
            swap(&src, &dst)
        }
        var hp = ConvParams(cin: UInt32(headCin), cout: 1, h: UInt32(h), w: UInt32(w), dr: 0, da: 0, woff: UInt32(headOff), boff: UInt32(headOff + headCin))
        enc.setComputePipelineState(head)
        enc.setBuffer(src, offset: 0, index: 0)
        enc.setBuffer(outBuf, offset: 0, index: 1)
        enc.setBuffer(wbuf, offset: 0, index: 2)
        enc.setBytes(&hp, length: MemoryLayout<ConvParams>.stride, index: 3)
        enc.dispatchThreads(MTLSize(width: w, height: h, depth: 1), threadsPerThreadgroup: MTLSize(width: 32, height: 4, depth: 1))
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        guard cb.status == .completed else { return nil }
        let p = outBuf.contents().bindMemory(to: Float.self, capacity: h * w)
        return Array(UnsafeBufferPointer(start: p, count: h * w))
    }

    /// CPU 参考实现（和着色器同一套算法）
    func runCPU(_ input: [Float]) -> [Float] {
        var x = input
        let h = self.h, w = self.w, weights = self.weights
        for l in layers {
            var y = [Float](repeating: 0, count: l.cout * h * w)
            let boff = l.offset + l.cout * l.cin * 9
            let xin = x
            y.withUnsafeMutableBufferPointer { ybuf in
            let yout = ybuf.baseAddress!
            DispatchQueue.concurrentPerform(iterations: l.cout) { co in
                var plane = [Float](repeating: weights[boff + co], count: h * w)
                for ci in 0..<l.cin {
                    for ky in 0..<3 {
                        for kx in 0..<3 {
                            let wv = weights[l.offset + ((co * l.cin + ci) * 3 + ky) * 3 + kx]
                            let oy = (ky - 1) * l.dr, ox = (kx - 1) * l.da
                            for yy in 0..<h {
                                let sy = yy + oy
                                if sy < 0 || sy >= h { continue }
                                let srow = (ci * h + sy) * w
                                for xx in 0..<w {
                                    var sx = (xx + ox) % w
                                    if sx < 0 { sx += w }
                                    plane[yy * w + xx] += wv * xin[srow + sx]
                                }
                            }
                        }
                    }
                }
                for i in 0..<(h * w) { yout[co * h * w + i] = max(plane[i], 0) }
            }
            }
            x = y
        }
        var out = [Float](repeating: weights[headOff + headCin], count: h * w)
        for ci in 0..<headCin {
            let wv = weights[headOff + ci]
            for i in 0..<(h * w) { out[i] += wv * x[ci * h * w + i] }
        }
        return out.map { tanh($0) }
    }
}
