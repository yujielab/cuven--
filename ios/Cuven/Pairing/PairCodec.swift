import Foundation

// MARK: - Cuven 粒子码（CPC）v1 —— 光学配对用的「粒子云」
//
// 一团粒子云里藏 64 位：配对编号 24 位 + 密钥 32 位 + CRC-8。
//   · 卷积码（K=7，171 / 133，码率 1/2，补 6 个 0）→ 140 码位；交织；加 20 个导频 → 160 个格子，排在 5 圈上
//   · 每个格子一团 ± 高斯：D(x) = Σ b_i·G_i(扭曲后的 x)；调制 M = （1 + α·tanh(D/τ)）×（1 + β·覆盖度²·exp(−(D/w)²)）
//     显示时（PairCloud，照 Apple 配对动画复刻的 3D 粒子云）每个粒子的光学深度乘上屏幕上那一点的 M：正的一侧浓一点、零线上浓一些
//   · 解码：相机 → 蓝色程度（B − R）→ 找框（矩 + 射线找亮边 + 最小二乘，去掉旋转）→ 极坐标展开（24 × 192）
//           → 最近几帧平均（滚动的云抹平、码留下）→ 神经网络估 D（PairNet，Metal）→ 每个旋转下最小二乘解出 160 个格子
//           → 导频定旋转 → Viterbi → CRC
// 规范和 Python 参考实现（pairing/py/spec.py，训练用）、网页（web/pair.js）逐项一致；常数在 cpc1-spec.json（三边同一份）。

struct PairSpec: Decodable {
    struct Conv: Decodable { let k: Int; let g1: Int; let g2: Int }
    struct Decode: Decodable {
        let cam: Int; let pr: Int; let pa: Int
        let rLo: Double; let rHi: Double; let th: Double; let kRms: Double; let targetScale: Double
        // v1.1 的框：背景分位、减底余量、射线；半高处 / 真半径；最小二乘解卷的正则
        let bgQ: Double; let bgMargin: Double; let rays: Int; let rayN: Int; let rayT0: Double; let rayT1: Double
        let edgeK: Double; let lsReg: Double
        let avgFrames: Int              // 平均最近几帧的极坐标图
    }
    let version: Int
    let cells: [[Double]]           // (半径, 角, 切向 σ)
    let sigmaR: Double
    let pilotIdx: [Int]
    let pilots: [Int]
    let dataIdx: [Int]
    let interleave: [Int]
    let warp: [[Double]]            // (幅度, kx, ky, 相位)
    let alpha: Double
    let tau: Double
    let beta: Double
    let w: Double
    let e0: Double
    let codeGrid: Int                   // 调制网格边长（显示用的纹理）
    let codeScale: Double               // 8 位纹理里存 M / codeScale
    let codeSpin: Double                // 码平面每秒转的弧度
    let conv: Conv
    let decode: Decode

    static let shared: PairSpec? = {
        guard let url = Bundle.main.url(forResource: "cpc1-spec", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PairSpec.self, from: data)
    }()
}

enum PairCodec {
    /// 场的范围：[-1.6, 1.6]²（云的半径 = 1）
    static let ext = 1.6

    // MARK: 编码

    static func crc8(_ bytes: [UInt8]) -> UInt8 {
        var c: UInt8 = 0
        for byte in bytes {
            c ^= byte
            for _ in 0..<8 { c = (c & 0x80) != 0 ? (c << 1) ^ 0x07 : c << 1 }
        }
        return c
    }

    private static func parity(_ x: Int) -> UInt8 { UInt8(x.nonzeroBitCount & 1) }

    static func payloadBits(id: UInt32, secret: UInt32) -> [UInt8] {
        var b: [UInt8] = [UInt8((id >> 16) & 255), UInt8((id >> 8) & 255), UInt8(id & 255),
                          UInt8((secret >> 24) & 255), UInt8((secret >> 16) & 255), UInt8((secret >> 8) & 255), UInt8(secret & 255)]
        b.append(crc8(b))
        return (0..<64).map { (b[$0 >> 3] >> UInt8(7 - ($0 & 7))) & 1 }
    }

    static func convEncode(_ bits: [UInt8], spec: PairSpec) -> [UInt8] {
        var st = 0
        var out: [UInt8] = []
        for b in bits + [UInt8](repeating: 0, count: spec.conv.k - 1) {
            st = ((st << 1) | Int(b)) & 0x7F
            out.append(parity(st & spec.conv.g1))
            out.append(parity(st & spec.conv.g2))
        }
        return out
    }

    /// 160 个格子的正负（±1）
    static func cellSigns(id: UInt32, secret: UInt32, spec: PairSpec) -> [Float] {
        let coded = convEncode(payloadBits(id: id, secret: secret), spec: spec)
        var b = [Float](repeating: 0, count: spec.cells.count)
        for (i, idx) in spec.pilotIdx.enumerated() { b[idx] = Float(spec.pilots[i]) }
        for (k, c) in coded.enumerated() { b[spec.dataIdx[spec.interleave[k]]] = c == 1 ? 1 : -1 }
        return b
    }

    // MARK: 场与密度

    static func wrapAngle(_ a: Double) -> Double {
        var x = (a + .pi).truncatingRemainder(dividingBy: 2 * .pi)
        if x < 0 { x += 2 * .pi }
        return x - .pi
    }

    static func warp(_ x: Double, _ y: Double, spec: PairSpec) -> (Double, Double) {
        var dx = 0.0, dy = 0.0
        for w in spec.warp {
            dx += w[0] * sin(w[1] * x + w[2] * y + w[3])
            dy += w[0] * cos(w[2] * x - w[1] * y + w[3] * 1.3)
        }
        return (x + dx, y + dy)
    }

    /// D（带正负的场）和 E（覆盖度：这里有没有格子）
    static func field(_ b: [Float], _ x: Double, _ y: Double, spec: PairSpec) -> (D: Double, E: Double) {
        let (wx, wy) = warp(x, y, spec: spec)
        let r = (wx * wx + wy * wy).squareRoot(), th = atan2(wy, wx)
        let s2r = 2 * spec.sigmaR * spec.sigmaR
        var D = 0.0, E = 0.0
        for (i, c) in spec.cells.enumerated() {
            let dr = r - c[0], dt = c[0] * wrapAngle(th - c[1])
            let g = exp(-(dr * dr) / s2r - (dt * dt) / (2 * c[2] * c[2]))
            D += Double(b[i]) * g
            E += g
        }
        return (D, E)
    }

    /// 调制 M（光学深度的倍数）
    static func modulation(_ D: Double, _ E: Double, spec: PairSpec) -> Double {
        let gate = min(1, max(0, E / spec.e0))
        return (1 + spec.alpha * tanh(D / spec.tau)) * (1 + spec.beta * gate * gate * exp(-(D / spec.w) * (D / spec.w)))
    }

    /// G × G 的调制网格（覆盖 [-ext, ext]²，按像素中心取样；第 0 行是 y 最小的那一行 —— 码平面的 y 在屏幕上朝下）。
    /// 逐点算 160 个高斯的参考实现（自检、对照用）；显示用 codeTexture（稀疏基底，结果一样）
    static func modulationGrid(_ b: [Float], size G: Int, spec: PairSpec) -> [Float] {
        var m = [Float](repeating: 0, count: G * G)
        let cell = 2 * ext / Double(G)
        m.withUnsafeMutableBufferPointer { buf in
            let out = buf.baseAddress!                       // 指针在并行之前取一次：每行只写自己那一段
            DispatchQueue.concurrentPerform(iterations: G) { j in
                let y = -ext + (Double(j) + 0.5) * cell
                for i in 0..<G {
                    let f = field(b, -ext + (Double(i) + 0.5) * cell, y, spec: spec)
                    out[j * G + i] = Float(modulation(f.D, f.E, spec: spec))
                }
            }
        }
        return m
    }

    /// 调制网格 → 8 位纹理（M / codeScale）
    static func textureBytes(_ m: [Float], spec: PairSpec) -> [UInt8] {
        m.map { UInt8(max(0, min(255, ($0 / Float(spec.codeScale) * 255).rounded()))) }
    }

    /// 一团码的 8 位纹理（codeGrid²）：走稀疏基底，几毫秒。第一次要先建基底（和一次逐点算差不多），放在后台线程上调
    static func codeTexture(id: UInt32, secret: UInt32, spec: PairSpec) -> [UInt8] {
        let G = spec.codeGrid
        return textureBytes(basis(spec: spec, size: G).grid(cellSigns(id: id, secret: secret, spec: spec), spec: spec), spec: spec)
    }

    private static let basisLock = NSLock()
    nonisolated(unsafe) private static var basisCache: ModulationBasis?
    /// 稀疏基底只建一次（整个 App 共用；几个线程同时要时，后来的等第一个建完）
    static func basis(spec: PairSpec, size G: Int) -> ModulationBasis {
        basisLock.lock(); defer { basisLock.unlock() }
        if let b = basisCache, b.size == G, b.cellCount == spec.cells.count { return b }
        let b = ModulationBasis(spec: spec, size: G)
        basisCache = b
        return b
    }
    /// 提前在后台建好（显示端一出来、/pair/open 还在路上时调）
    static func prewarm(spec: PairSpec? = PairSpec.shared) {
        guard let spec else { return }
        Task.detached(priority: .userInitiated) { _ = basis(spec: spec, size: spec.codeGrid) }
    }

    /// 编号 + 密钥拼成一个 64 位的键（记「后端说不对」的码）
    static func key(id: UInt32, secret: UInt32) -> UInt64 { UInt64(id) << 32 | UInt64(secret) }

    // MARK: 解码：Viterbi、CRC

    /// soft：140 个软值（正 = 码位 1）→ 64 个信息位
    static func viterbi(_ soft: [Float], spec: PairSpec) -> [UInt8] {
        let n = soft.count / 2, K = spec.conv.k
        let ninf = -Float.greatestFiniteMagnitude
        var metric = [Float](repeating: ninf, count: 64); metric[0] = 0
        var hist = [[Int]](repeating: [Int](repeating: 0, count: 64), count: n)
        for t in 0..<n {
            let s1 = soft[2 * t], s2 = soft[2 * t + 1]
            var next = [Float](repeating: ninf, count: 64)
            var prev = [Int](repeating: 0, count: 64)
            for s in 0..<64 where metric[s] != ninf {
                for b in 0...1 {
                    let full = ((s << 1) | b) & 0x7F
                    let o1 = parity(full & spec.conv.g1), o2 = parity(full & spec.conv.g2)
                    let m = metric[s] + (o1 == 1 ? s1 : -s1) + (o2 == 1 ? s2 : -s2)
                    let ns = full & 0x3F
                    if m > next[ns] { next[ns] = m; prev[ns] = (s << 1) | b }
                }
            }
            metric = next; hist[t] = prev
        }
        var s = 0
        var bits: [UInt8] = []
        for t in stride(from: n - 1, through: 0, by: -1) {
            let p = hist[t][s]
            bits.append(UInt8(p & 1))
            s = p >> 1
        }
        bits.reverse()
        return Array(bits.prefix(n - (K - 1)))
    }

    static func parse(_ bits: [UInt8]) -> (id: UInt32, secret: UInt32)? {
        guard bits.count >= 64 else { return nil }
        var by = [UInt8](repeating: 0, count: 8)
        for i in 0..<64 { by[i >> 3] |= bits[i] << UInt8(7 - (i & 7)) }
        guard crc8(Array(by[0..<7])) == by[7] else { return nil }
        let id = (UInt32(by[0]) << 16) | (UInt32(by[1]) << 8) | UInt32(by[2])
        let secret = (UInt32(by[3]) << 24) | (UInt32(by[4]) << 16) | (UInt32(by[5]) << 8) | UInt32(by[6])
        // CRC-8 初值是 0：全零也是合法码字，软值整体偏负时 Viterbi 最容易「解」出它。后端从不发 (0, 0)
        if id == 0 && secret == 0 { return nil }
        return (id, secret)
    }
}

// MARK: - 调制网格的稀疏基底（显示端）

/// 和码无关的部分只算一次：每个纹素的覆盖度 E（160 个格子全加），和碰得到它的格子（g > 1e-7，平均约 6 个）的编号、高斯权重，按 CSR 存。
/// 换一团码只要 D = Σ b[格子]·g 再算 M（约 22 万次乘加、几毫秒）；逐点算要 590 万次 exp。
/// 8 位纹理和 modulationGrid 逐点算的一样（只有四舍五入恰好卡在边上的点可能差 1/255）
struct ModulationBasis: Sendable {
    static let cutoff = 1e-7
    let size: Int
    let cellCount: Int
    let E: [Double]          // size²
    let start: [Int32]       // size² + 1：第 p 个纹素的格子在 cell / weight 的 [start[p], start[p + 1])
    let cell: [UInt8]
    let weight: [Float]

    init(spec: PairSpec, size G: Int) {
        struct Row { var E: [Double] = []; var count: [Int32] = []; var cell: [UInt8] = []; var weight: [Float] = [] }
        let nc = spec.cells.count
        precondition(nc <= 256, "格子编号要放进 UInt8")
        // 格子的常数摊平（式子和 PairCodec.field 一模一样，值也就一样）
        let cr = spec.cells.map { $0[0] }, ca = spec.cells.map { $0[1] }, ct = spec.cells.map { 2 * $0[2] * $0[2] }
        let s2r = 2 * spec.sigmaR * spec.sigmaR
        let ext = PairCodec.ext, step = 2 * ext / Double(G)
        var rows = [Row](repeating: Row(), count: G)
        rows.withUnsafeMutableBufferPointer { buf in
            let out = buf.baseAddress!                       // 每行只写自己那一格
            DispatchQueue.concurrentPerform(iterations: G) { j in
                var row = Row()
                row.E.reserveCapacity(G); row.count.reserveCapacity(G)
                row.cell.reserveCapacity(G * 8); row.weight.reserveCapacity(G * 8)
                let y = -ext + (Double(j) + 0.5) * step
                for i in 0..<G {
                    let (wx, wy) = PairCodec.warp(-ext + (Double(i) + 0.5) * step, y, spec: spec)
                    let r = (wx * wx + wy * wy).squareRoot(), th = atan2(wy, wx)
                    var e = 0.0, n: Int32 = 0
                    for k in 0..<nc {
                        let dr = r - cr[k], dt = cr[k] * PairCodec.wrapAngle(th - ca[k])
                        let g = exp(-(dr * dr) / s2r - (dt * dt) / ct[k])
                        e += g
                        if g > Self.cutoff { row.cell.append(UInt8(k)); row.weight.append(Float(g)); n += 1 }
                    }
                    row.E.append(e); row.count.append(n)
                }
                out[j] = row
            }
        }
        let total = rows.reduce(0) { $0 + $1.cell.count }
        var E = [Double](), start = [Int32](), cell = [UInt8](), weight = [Float]()
        E.reserveCapacity(G * G); start.reserveCapacity(G * G + 1)
        cell.reserveCapacity(total); weight.reserveCapacity(total)
        start.append(0)
        var acc: Int32 = 0
        for r in rows {
            E.append(contentsOf: r.E)
            for c in r.count { acc += c; start.append(acc) }
            cell.append(contentsOf: r.cell); weight.append(contentsOf: r.weight)
        }
        size = G; cellCount = nc
        self.E = E; self.start = start; self.cell = cell; self.weight = weight
    }

    /// b：160 个格子的正负 → size × size 的 M（和 modulationGrid 同一个排布）
    func grid(_ b: [Float], spec: PairSpec) -> [Float] {
        let n = size * size
        guard b.count >= cellCount else { return [Float](repeating: 1, count: n) }
        var m = [Float](repeating: 0, count: n)
        m.withUnsafeMutableBufferPointer { mb in
            cell.withUnsafeBufferPointer { cb in
                weight.withUnsafeBufferPointer { wb in
                    b.withUnsafeBufferPointer { bb in
                        for p in 0..<n {
                            var D = 0.0
                            for k in Int(start[p])..<Int(start[p + 1]) { D += Double(bb[Int(cb[k])]) * Double(wb[k]) }
                            mb[p] = Float(PairCodec.modulation(D, E[p], spec: spec))
                        }
                    }
                }
            }
        }
        return m
    }
}

// MARK: - 解码器（相机一帧帧喂进来）

/// 一帧：cam × cam 的「蓝色程度」（0–1，第 0 行在上）→ 认出来了就回（编号, 密钥）。
/// 和 Python 参考实现（pairing/py/render.py 的 frame、decode.py 的 decode_ls）逐步一致：
///   ① 减背景（20% 分位）算矩 → 粗椭圆；② 24 条射线找亮边的半高点 → 最小二乘拟合中心 + 2×2 映射（去掉最差 4 个再拟合）
///   ③ 去掉映射里的旋转（极分解，只留对称的那一半）：角度 0 永远对着画面的 x 方向，前后几帧的极坐标图是对齐的 → 可以平均
///   ④ 极坐标展开 → 网络（GPU）→ 前后几帧平均 → 每个旋转下最小二乘解出 160 个格子 → 导频定旋转 → Viterbi → CRC
/// 每帧用的缓冲都是建的时候开好、反复用的（以前每帧新开约 1 MB）；不是线程安全的：只在扫描那一条串行队列上用
final class PairDecoder {
    struct Frame { var cx: Float; var cy: Float; var m: (Float, Float, Float, Float) }   // 像素 = c + M·(x, y)，M 按行存

    let spec: PairSpec
    let net: PairNet
    private let pr: Int, pa: Int, cam: Int
    private struct Tap { let row: Int32; let col: Int32; let v: Float }
    private var taps: [[Tap]] = []
    private var ginv: [Float] = []                       // 160 × 160：(TᵀT + λI)⁻¹
    private var last: (UInt32, UInt32)?
    private(set) var lastScore: Float = 0

    // 每帧复用的缓冲
    private var wBuf: [Float]                            // cam²：减过背景的蓝色程度
    private var qBuf: [Float]                            // cam²：找背景分位用（快速选择会打乱顺序）
    private let rowR: [Float]                            // pr：极坐标每一行的半径
    private let colCos: [Float], colSin: [Float]         // pa：每一列的角度
    private var polar: [Float]                           // 2 × pr × pa：这一帧的极坐标图（第 1 通道是半径，不变）
    private var ring: [Float]                            // avgFrames × pr × pa：最近几帧的极坐标图（环形）
    private var ringHead = 0, ringCount = 0
    private var avg: [Float]                             // 2 × pr × pa：平均过的 → 网络输入
    private var raw: [Float]                             // 160 × pa：每个格子模板和 D̂ 的相关
    private var pilotL: [Float]                          // 导频数 × pa：导频格子在每个旋转下的解
    private var score: [Float]                           // pa

    // 后端说不对的码（误读、过期）：解码时跳过、试下一个旋转。同一个码一直在画面里认出来（真在屏幕上）→ 记一次，扫描页给个提示
    private var rejected: Set<UInt64> = []
    private var rejectedHits: [UInt64: Int] = [:]
    private var rejectedAgain: UInt64?

    init?(spec: PairSpec? = PairSpec.shared, net: PairNet? = PairNet()) {
        guard let spec, let net else { return nil }
        self.spec = spec; self.net = net
        let d = spec.decode
        let pr = d.pr, pa = d.pa, cam = d.cam, n = pr * pa
        self.pr = pr; self.pa = pa; self.cam = cam
        wBuf = [Float](repeating: 0, count: cam * cam)
        qBuf = [Float](repeating: 0, count: cam * cam)
        rowR = (0..<pr).map { Float(d.rLo + (d.rHi - d.rLo) * Double($0) / Double(pr - 1)) }
        colCos = (0..<pa).map { cos(Float($0) / Float(pa) * 2 * .pi) }
        colSin = (0..<pa).map { sin(Float($0) / Float(pa) * 2 * .pi) }
        var p = [Float](repeating: 0, count: 2 * n)
        for row in 0..<pr {
            let rv = Float(row) / Float(pr - 1)
            for col in 0..<pa { p[n + row * pa + col] = rv }
        }
        polar = p; avg = p
        ring = [Float](repeating: 0, count: max(1, d.avgFrames) * n)
        raw = [Float](repeating: 0, count: spec.cells.count * pa)
        pilotL = [Float](repeating: 0, count: spec.pilotIdx.count * pa)
        score = [Float](repeating: 0, count: pa)
        buildTemplates()
    }

    /// 重新开始扫：窗口、上一次的结果、被拒过的码全清
    func reset() {
        resetWindow()
        rejected = []; rejectedHits = [:]; rejectedAgain = nil
    }
    /// 只清窗口和上一次的结果（相机停过一阵，画面是旧的）
    func resetWindow() { ringHead = 0; ringCount = 0; last = nil }

    /// 后端说这个码不对：以后解到它就跳过（窗口留着，接着扫的下一帧就能出结果）
    func reject(id: UInt32, secret: UInt32) {
        let k = PairCodec.key(id: id, secret: secret)
        rejected.insert(k)
        if let l = last, l.0 == id, l.1 == secret { last = nil }
    }
    /// 被拒过的码又连着认出来好几次 → 回它一次（之后同一个码不再回）
    func takeRejectedAgain() -> (id: UInt32, secret: UInt32)? {
        guard let k = rejectedAgain else { return nil }
        rejectedAgain = nil
        return (UInt32(truncatingIfNeeded: k >> 32), UInt32(truncatingIfNeeded: k))
    }

    /// 极坐标网格上每个格子的模板（稀疏：只存不为 0 的点）+ 模板的 Gram 矩阵的逆（最小二乘解卷用）
    private func buildTemplates() {
        let d = spec.decode
        let nc = spec.cells.count, np = pr * pa
        // 扭曲只和网格上的点有关、和格子无关：每个点算一次（以前每个格子都重算一遍，73.7 万次 → 4608 次；值一样）
        var rr = [Double](repeating: 0, count: np), th = [Double](repeating: 0, count: np)
        for row in 0..<pr {
            let r = d.rLo + (d.rHi - d.rLo) * Double(row) / Double(pr - 1)
            for col in 0..<pa {
                let a = Double(col) / Double(pa) * 2 * .pi
                let (wx, wy) = PairCodec.warp(r * cos(a), r * sin(a), spec: spec)
                rr[row * pa + col] = (wx * wx + wy * wy).squareRoot(); th[row * pa + col] = atan2(wy, wx)
            }
        }
        var dense = [Float](repeating: 0, count: nc * np)
        let s2r = 2 * spec.sigmaR * spec.sigmaR
        taps = []
        for (i, c) in spec.cells.enumerated() {
            var list: [Tap] = []
            for p in 0..<np {
                let dr = rr[p] - c[0], dt = c[0] * PairCodec.wrapAngle(th[p] - c[1])
                let g = Float(exp(-(dr * dr) / s2r - (dt * dt) / (2 * c[2] * c[2])))
                dense[i * np + p] = g
                if g > 1e-4 { list.append(Tap(row: Int32(p / pa), col: Int32(p % pa), v: g)) }
            }
            taps.append(list)
        }
        // Gram = T·Tᵀ + λI，再求逆（高斯 - 约当，双精度；只在开始时算一次）
        var G = [Double](repeating: 0, count: nc * nc)
        dense.withUnsafeBufferPointer { T in
            let base = T.baseAddress!
            G.withUnsafeMutableBufferPointer { gb in
                let gp = gb.baseAddress!
                DispatchQueue.concurrentPerform(iterations: nc) { i in
                    for j in i..<nc {
                        var acc = 0.0
                        let ti = base + i * np, tj = base + j * np
                        for k in 0..<np { acc += Double(ti[k]) * Double(tj[k]) }
                        gp[i * nc + j] = acc; gp[j * nc + i] = acc
                    }
                }
            }
        }
        for i in 0..<nc { G[i * nc + i] += d.lsReg }
        ginv = PairDecoder.invert(G, nc).map { Float($0) }
    }

    private static func invert(_ a0: [Double], _ n: Int) -> [Double] {
        var a = a0
        var inv = [Double](repeating: 0, count: n * n)
        for i in 0..<n { inv[i * n + i] = 1 }
        for c in 0..<n {
            var p = c
            for r in (c + 1)..<n where abs(a[r * n + c]) > abs(a[p * n + c]) { p = r }
            if p != c { for k in 0..<n { a.swapAt(c * n + k, p * n + k); inv.swapAt(c * n + k, p * n + k) } }
            let d = a[c * n + c]
            if abs(d) < 1e-12 { continue }
            for k in 0..<n { a[c * n + k] /= d; inv[c * n + k] /= d }
            for r in 0..<n where r != c {
                let f = a[r * n + c]
                if f == 0 { continue }
                for k in 0..<n { a[r * n + k] -= f * a[c * n + k]; inv[r * n + k] -= f * inv[c * n + k] }
            }
        }
        return inv
    }

    private func sample(_ img: [Float], _ x: Float, _ y: Float) -> Float {
        let x0 = Int(floor(x)), y0 = Int(floor(y))
        let fx = x - Float(x0), fy = y - Float(y0)
        func px(_ i: Int, _ j: Int) -> Float { (i < 0 || j < 0 || i >= cam || j >= cam) ? 0 : img[j * cam + i] }
        return px(x0, y0) * (1 - fx) * (1 - fy) + px(x0 + 1, y0) * fx * (1 - fy) + px(x0, y0 + 1) * (1 - fx) * fy + px(x0 + 1, y0 + 1) * fx * fy
    }

    /// 和 PyTorch 的 quantile（线性插值）一样、和整个排序以后取的值一模一样；但不排序：快速选择找第 i 小，
    /// 再在它右边找最小的（= 第 i + 1 小），O(n)。v 的顺序会被打乱
    static func quantile(_ v: inout [Float], _ q: Double) -> Float {
        let n = v.count
        guard n > 0 else { return 0 }
        let pos = q * Double(n - 1), i = Int(pos), f = Float(pos - Double(i))
        return v.withUnsafeMutableBufferPointer { b -> Float in
            let lo = select(b, i)
            guard i + 1 < n else { return lo }
            var hi = b[i + 1]
            for k in (i + 2)..<n where b[k] < hi { hi = b[k] }
            return lo * (1 - f) + hi * f
        }
    }

    /// 快速选择：把第 k 小的放到 b[k]，左边都 ≤ 它、右边都 ≥ 它。三数取中做轴、三路划分（背景大片相同的值也不退化）
    static func select(_ b: UnsafeMutableBufferPointer<Float>, _ k: Int) -> Float {
        var lo = 0, hi = b.count - 1
        while lo < hi {
            let x = b[lo], y = b[lo + (hi - lo) / 2], z = b[hi]
            let pivot = max(min(x, y), min(max(x, y), z))
            // [lo, lt) < 轴，[lt, gt] == 轴，(gt, hi] > 轴
            var lt = lo, gt = hi, i = lo
            while i <= gt {
                let v = b[i]
                if v < pivot { b.swapAt(lt, i); lt += 1; i += 1 }
                else if v > pivot { b.swapAt(i, gt); gt -= 1 }
                else { i += 1 }
            }
            if k < lt { hi = lt - 1 } else if k > gt { lo = gt + 1 } else { return b[k] }
        }
        return b[k]
    }

    private static func copy(_ src: [Float], into dst: inout [Float]) {
        let n = min(src.count, dst.count)
        dst.withUnsafeMutableBufferPointer { d in src.withUnsafeBufferPointer { s in d.baseAddress!.update(from: s.baseAddress!, count: n) } }
    }

    /// 框：中心 + 2×2 映射（已去掉旋转）。认不出来（几乎没有蓝色）→ nil
    func frame(_ ink: [Float]) -> Frame? {
        let d = spec.decode
        guard ink.count == cam * cam else { return nil }
        PairDecoder.copy(ink, into: &qBuf)
        let bg = PairDecoder.quantile(&qBuf, d.bgQ)
        // ① 粗椭圆（w 借用复用的缓冲：每个点都会写到）
        var w = [Float]()
        swap(&w, &wBuf)
        defer { swap(&w, &wBuf) }
        var m: Float = 0, sx: Float = 0, sy: Float = 0
        for y in 0..<cam { for x in 0..<cam {
            let v = max(ink[y * cam + x] - bg - Float(d.bgMargin), 0); w[y * cam + x] = v
            m += v; sx += v * Float(x); sy += v * Float(y)
        } }
        guard m > 50 else { return nil }
        let mx = sx / m, my = sy / m
        var cxx: Float = 0, cyy: Float = 0, cxy: Float = 0
        for y in 0..<cam {
            let dy = Float(y) - my
            for x in 0..<cam {
                let v = w[y * cam + x]
                if v == 0 { continue }
                let dx = Float(x) - mx
                cxx += v * dx * dx; cyy += v * dy * dy; cxy += v * dx * dy
            }
        }
        cxx /= m; cyy /= m; cxy /= m
        let tr = (cxx + cyy) / 2, df = ((cxx - cyy) / 2 * (cxx - cyy) / 2 + cxy * cxy).squareRoot()
        let l1 = tr + df, l2 = max(tr - df, 1e-6)
        var v0x: Float, v0y: Float
        if abs(cxy) > 1e-9 { v0x = cxy; v0y = l1 - cxx } else if cxx >= cyy { v0x = 1; v0y = 0 } else { v0x = 0; v0y = 1 }
        let nrm = (v0x * v0x + v0y * v0y).squareRoot(); v0x /= nrm; v0y /= nrm
        let k = Float(d.kRms), a0 = k * l1.squareRoot(), b0 = k * l2.squareRoot()
        // M0 的两列：主轴 × a0、主轴逆时针 90°（右手系）× b0
        let m0 = (v0x * a0, -v0y * b0, v0y * a0, v0x * b0)
        // ② 射线找亮边
        let R = d.rays, N = d.rayN
        let lo = Int((0.6 - d.rayT0) / (d.rayT1 - d.rayT0) * Double(N - 1)), hi = Int((1.4 - d.rayT0) / (d.rayT1 - d.rayT0) * Double(N - 1))
        var ex = [Float](repeating: 0, count: R), ey = [Float](repeating: 0, count: R)
        var cosT = [Float](repeating: 0, count: R), sinT = [Float](repeating: 0, count: R)
        var prof = [Float](repeating: 0, count: N), sm = [Float](repeating: 0, count: N)    // 每条射线都整段重写
        for r in 0..<R {
            let th = Float(r) / Float(R) * 2 * .pi
            let ct = cos(th), st = sin(th)
            cosT[r] = ct; sinT[r] = st
            for n in 0..<N {
                let t = Float(d.rayT0) + Float(n) / Float(N - 1) * Float(d.rayT1 - d.rayT0)
                let ux = ct * t, uy = st * t
                prof[n] = sample(ink, mx + m0.0 * ux + m0.1 * uy, my + m0.2 * ux + m0.3 * uy) - bg
            }
            // 5 点平均（出界算 0，和 avg_pool1d 一样）
            for n in 0..<N { var acc: Float = 0; for j in (n - 2)...(n + 2) where j >= 0 && j < N { acc += prof[j] }; sm[n] = acc / 5 }
            var pk = -Float.greatestFiniteMagnitude, pi = lo
            for n in lo...hi where sm[n] > pk { pk = sm[n]; pi = n }
            var first = N - 1
            for n in (pi + 1)..<N where sm[n] < 0.5 * pk { first = n; break }
            let f1 = min(max(first, 1), N - 1), f0 = f1 - 1
            let p0 = sm[f0], p1 = sm[f1]
            let frac = min(1, max(0, (p0 - 0.5 * pk) / max(p0 - p1, 1e-6)))
            let te = Float(d.rayT0) + (Float(f0) + frac) / Float(N - 1) * Float(d.rayT1 - d.rayT0)
            let ux = ct * te, uy = st * te
            ex[r] = mx + m0.0 * ux + m0.1 * uy; ey[r] = my + m0.2 * ux + m0.3 * uy
        }
        // 最小二乘：e = c + M·(cos θ, sin θ)
        func fit(_ keep: [Bool]) -> [Double]? {                       // 3 × 2：行 = (常数, cos, sin)，列 = (x, y)
            var ata = [Double](repeating: 0, count: 9), atb = [Double](repeating: 0, count: 6)
            for r in 0..<R where keep[r] {
                let a = [1.0, Double(cosT[r]), Double(sinT[r])]
                for i in 0..<3 { for j in 0..<3 { ata[i * 3 + j] += a[i] * a[j] }; atb[i * 2] += a[i] * Double(ex[r]); atb[i * 2 + 1] += a[i] * Double(ey[r]) }
            }
            for i in 0..<3 { ata[i * 3 + i] += 1e-6 }
            let inv = PairDecoder.invert(ata, 3)
            var x = [Double](repeating: 0, count: 6)
            for i in 0..<3 { for j in 0..<3 { x[i * 2] += inv[i * 3 + j] * atb[j * 2]; x[i * 2 + 1] += inv[i * 3 + j] * atb[j * 2 + 1] } }
            return x.allSatisfy(\.isFinite) ? x : nil
        }
        var keep = [Bool](repeating: true, count: R)
        guard var sol = fit(keep) else { return nil }
        var res = [Float](repeating: 0, count: R)
        for r in 0..<R {
            let px = sol[0] + sol[2] * Double(cosT[r]) + sol[4] * Double(sinT[r])
            let py = sol[1] + sol[3] * Double(cosT[r]) + sol[5] * Double(sinT[r])
            res[r] = Float(((Double(ex[r]) - px) * (Double(ex[r]) - px) + (Double(ey[r]) - py) * (Double(ey[r]) - py)).squareRoot())
        }
        let cut = res.sorted()[R - 5]
        for r in 0..<R { keep[r] = res[r] <= cut }
        if let s2 = fit(keep) { sol = s2 }
        let ek = d.edgeK
        // M 的两列：cos 的系数 (sol[2], sol[3])、sin 的系数 (sol[4], sol[5])
        var M = (Float(sol[2] / ek), Float(sol[4] / ek), Float(sol[3] / ek), Float(sol[5] / ek))
        var c = (Float(sol[0]), Float(sol[1]))
        let det = M.0 * M.3 - M.1 * M.2
        if !(det > 0) || !M.0.isFinite || !M.1.isFinite || !M.2.isFinite || !M.3.isFinite { M = m0; c = (mx, my) }
        // ③ 去掉旋转：M = R·P，只留 P
        let (a, b, cc, dd) = M
        let n = ((a + dd) * (a + dd) + (cc - b) * (cc - b)).squareRoot()
        let ca = (a + dd) / max(n, 1e-9), sa = (cc - b) / max(n, 1e-9)
        let P = (ca * a + sa * cc, ca * b + sa * dd, -sa * a + ca * cc, -sa * b + ca * dd)
        return Frame(cx: c.0, cy: c.1, m: P)
    }

    /// 极坐标展开（双线性，出界补 0）+ 归一 → polar 的第 0 通道（网络输入；第 1 通道是半径，建的时候就填好了）
    private func fillPolar(_ ink: [Float], _ f: Frame) {
        var out = [Float]()
        swap(&out, &polar)
        defer { swap(&out, &polar) }
        for row in 0..<pr {
            let r = rowR[row]
            for col in 0..<pa {
                let ex = r * colCos[col], ey = r * colSin[col]
                out[row * pa + col] = sample(ink, f.cx + f.m.0 * ex + f.m.1 * ey, f.cy + f.m.2 * ex + f.m.3 * ey)
            }
        }
        let n = pr * pa
        var mean: Float = 0
        for i in 0..<n { mean += out[i] }
        mean /= Float(n)
        var v: Float = 0
        for i in 0..<n { let t = out[i] - mean; v += t * t }
        let sd = (v / Float(n - 1)).squareRoot() + 1e-4                  // 和 PyTorch 的 std（N − 1）一样
        for i in 0..<n { out[i] = (out[i] - mean) / sd }
    }

    /// 极坐标展开 + 归一 → 网络输入（2 × pr × pa：第 0 通道蓝色程度，第 1 通道半径）
    func polarInput(_ ink: [Float], _ f: Frame) -> [Float] {
        fillPolar(ink, f)
        return polar
    }

    /// D̂（pr × pa）→ 每个旋转下最小二乘解出的 160 个格子 → 导频定旋转 → Viterbi → CRC。
    /// L = Ginv · raw 只算用得到的：导频那 20 行算所有旋转（定旋转），数据格子只算挑出来的那几列（以前 160 行 × 192 列全算；
    /// 每个数加的顺序没变，结果一模一样）
    func decode(_ dhat: [Float], tries: Int = 3) -> (id: UInt32, secret: UInt32)? {
        let nc = spec.cells.count, np = spec.pilotIdx.count
        let taps = self.taps, pa = self.pa
        guard dhat.count >= pr * pa else { return nil }
        var raw = [Float]()
        swap(&raw, &self.raw)
        defer { swap(&raw, &self.raw) }
        raw.withUnsafeMutableBufferPointer { buf in                      // 每个格子模板和 D̂ 的相关（所有旋转）
            let out = buf.baseAddress!
            dhat.withUnsafeBufferPointer { dp in
                let dd = dp.baseAddress!
                DispatchQueue.concurrentPerform(iterations: nc) { i in
                    let tl = taps[i]
                    for s in 0..<pa {
                        var acc: Float = 0
                        for t in tl {
                            var c = Int(t.col) + s
                            if c >= pa { c -= pa }
                            acc += t.v * dd[Int(t.row) * pa + c]
                        }
                        out[i * pa + s] = acc
                    }
                }
            }
        }
        let gi = ginv, pilotIdx = spec.pilotIdx
        var pl = [Float]()
        swap(&pl, &pilotL)
        defer { swap(&pl, &pilotL) }
        pl.withUnsafeMutableBufferPointer { lb in
            let lp = lb.baseAddress!
            raw.withUnsafeBufferPointer { rb in
                let rp = rb.baseAddress!
                DispatchQueue.concurrentPerform(iterations: np) { jj in
                    let i = pilotIdx[jj], row = lp + jj * pa
                    for s in 0..<pa { row[s] = 0 }
                    for j in 0..<nc {
                        let g = gi[i * nc + j]
                        if g == 0 { continue }
                        for s in 0..<pa { row[s] += g * rp[j * pa + s] }
                    }
                }
            }
        }
        var score = [Float]()
        swap(&score, &self.score)
        defer { swap(&score, &self.score) }
        for s in 0..<pa {
            var pil: Float = 0, nrm: Float = 0
            for j in 0..<np {
                let v = pl[j * pa + s]
                pil += Float(spec.pilots[j]) * v; nrm += v * v
            }
            score[s] = pil / (nrm.squareRoot() + 1e-9)
        }
        let order = (0..<pa).sorted { score[$0] > score[$1] }
        lastScore = score[order[0]]
        var blocked: UInt64?
        for s in order.prefix(tries) {
            var soft = [Float](repeating: 0, count: spec.interleave.count)
            for k in 0..<soft.count {
                let i = spec.dataIdx[spec.interleave[k]]
                var acc: Float = 0
                for j in 0..<nc {
                    let g = gi[i * nc + j]
                    if g == 0 { continue }
                    acc += g * raw[j * pa + s]
                }
                soft[k] = acc
            }
            let mean = soft.reduce(0) { $0 + abs($1) } / Float(soft.count) + 1e-9
            guard let p = PairCodec.parse(PairCodec.viterbi(soft.map { $0 / mean }, spec: spec)) else { continue }
            if p.id == 0 { continue }                                    // 后端从不发编号 0
            let key = PairCodec.key(id: p.id, secret: p.secret)
            if rejected.contains(key) { blocked = blocked ?? key; continue }
            return p
        }
        if let b = blocked {
            let c = (rejectedHits[b] ?? 0) + 1
            rejectedHits[b] = c
            if c == max(4, spec.decode.avgFrames) { rejectedAgain = b }
        }
        return nil
    }

    /// 喂一帧。最近 avgFrames 帧的极坐标图取平均再进网络（框已经去掉旋转，手机拿稳时前后几帧是对齐的；
    /// 3D 的云在滚，平均一下滚动的结构就抹平了，码留下来）；同一个结果连着两次才算数
    func feed(ink: [Float]) -> (id: UInt32, secret: UInt32)? {
        guard ink.count == cam * cam, let f = frame(ink) else { return nil }
        let size = (abs(f.m.0 * f.m.3 - f.m.1 * f.m.2)).squareRoot()
        guard size > 20, size < Float(cam) else { return nil }
        fillPolar(ink, f)
        let n = pr * pa, F = max(1, spec.decode.avgFrames)
        let head = ringHead
        ring.withUnsafeMutableBufferPointer { rb in
            polar.withUnsafeBufferPointer { pb in (rb.baseAddress! + head * n).update(from: pb.baseAddress!, count: n) }
        }
        ringHead = (ringHead + 1) % F
        ringCount = min(ringCount + 1, F)
        // 从最老的一帧加到最新的（和以前按数组顺序加一样）
        let first = (ringHead - ringCount + F) % F, count = ringCount
        avg.withUnsafeMutableBufferPointer { ab in
            ring.withUnsafeBufferPointer { rb in
                let a = ab.baseAddress!, r = rb.baseAddress!
                for i in 0..<n { a[i] = 0 }
                for k in 0..<count {
                    let src = r + ((first + k) % F) * n
                    for i in 0..<n { a[i] += src[i] }
                }
                for i in 0..<n { a[i] /= Float(count) }
            }
        }
        guard let hit = decode(net.run(avg)) else { return nil }
        defer { last = hit }
        if let l = last, l.0 == hit.id, l.1 == hit.secret { return hit }
        return nil
    }
}
