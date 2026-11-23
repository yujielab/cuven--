"""
Cuven 粒子码（CPC）v1 —— 规范与参考实现（numpy）

一团粒子云里藏 64 位：配对编号 24 位 + 密钥 32 位 + CRC-8。
  · 卷积码（K=7，生成多项式 171 / 133，八进制，码率 1/2，补 6 个 0 收尾）→ 140 个码位
  · 再加 20 个已知的导频位（找旋转用）→ 160 个格子，排在 5 圈上
  · 每个格子是一团 ± 的高斯：D(x) = Σ b_i · G_i(x)，b_i ∈ {+1, −1}
  · 外观是照 Apple 配对动画复刻的 3D 粒子云（web/pair.js，iOS PairCloud）；码藏在每个粒子的光学深度里：
      光学深度 × M，M = （1 + α·tanh(D/τ)）×（1 + β·覆盖度²·exp(−(D/w)²)），按粒子在屏幕上的位置取
      正的一侧浓一点 → 读得出正负；零线上浓一些（只在有格子的地方）
  · 解码：相机 → 蓝色程度 → 找框 → 极坐标展开 → 几帧平均 → 神经网络估 D → 最小二乘解出 160 个格子
          → 导频找旋转 → Viterbi → CRC
JS（网页）、Swift（iOS）照这份逐项实现，常数一个都不能改。
"""
import numpy as np

VERSION = 2                    # 2：外观换成复刻的 3D 粒子云，码改成光学深度的调制（格子、编码不变）

# ── 格子：5 圈，半径（以云的半径为 1）、格数、起始角 ──
RINGS = [  # (半径, 格数, 起始角弧度)
    (0.25, 14, 0.00),
    (0.44, 22, 0.37),
    (0.62, 30, 0.74),
    (0.78, 42, 1.11),
    (0.92, 52, 1.48),
]
N_CELLS = sum(n for _, n, _ in RINGS)          # 160
SIGMA_R = 0.070                                 # 高斯的径向宽度
SIGMA_T_FRAC = 0.45                             # 切向宽度 = 这一圈相邻格子间距 × 0.45

def _hash01(i, salt):
    """确定性的 [0, 1) 伪随机（各语言照抄：32 位整数运算）"""
    h = (i * 2654435761 + salt * 40503 + 0x9E3779B9) & 0xFFFFFFFF
    h ^= h >> 15; h = (h * 0x2C1B3C6D) & 0xFFFFFFFF
    h ^= h >> 12; h = (h * 0x297A2D39) & 0xFFFFFFFF
    h ^= h >> 15
    return h / 4294967296.0

def cells():
    """每个格子：(半径 r, 角 φ, 切向 σ)。顺序：一圈一圈，角度从小到大。
    位置带一点确定性的抖动（半径 ±0.025、角度 ±0.18 个格距），免得排得太整齐"""
    out = []
    i = 0
    for r, n, off in RINGS:
        st = SIGMA_T_FRAC * 2 * np.pi * r / n
        for k in range(n):
            jr = (_hash01(i, 1) - 0.5) * 0.05
            ja = (_hash01(i, 2) - 0.5) * 0.36 * 2 * np.pi / n
            out.append((r + jr, off + 2 * np.pi * k / n + ja, st))
            i += 1
    return np.array(out, dtype=np.float64)

CELLS = cells()

# ── 导频：全局编号 i % 8 == 3 的 20 个格子，值来自 7 位 LFSR（x^7 + x^6 + 1，初值 0x5A）──
PILOT_IDX = np.array([i for i in range(N_CELLS) if i % 8 == 3])
def _pilots():
    s, out = 0x5A, []
    for _ in range(len(PILOT_IDX)):
        b = ((s >> 6) ^ (s >> 5)) & 1
        s = ((s << 1) | b) & 0x7F
        out.append(1 if b else -1)
    return np.array(out, dtype=np.float64)
PILOTS = _pilots()
DATA_IDX = np.array([i for i in range(N_CELLS) if i % 8 != 3])     # 140 个
N_CODED = 140
INTERLEAVE = np.array([(k * 53) % N_CODED for k in range(N_CODED)])  # 第 k 个码位放在 DATA_IDX[INTERLEAVE[k]]

# ── CRC-8（多项式 0x07，初值 0）──
def crc8(data: bytes) -> int:
    c = 0
    for byte in data:
        c ^= byte
        for _ in range(8):
            c = ((c << 1) ^ 0x07) & 0xFF if c & 0x80 else (c << 1) & 0xFF
    return c

def payload_bits(pair_id: int, secret: int) -> np.ndarray:
    """配对编号（24 位）+ 密钥（32 位）+ CRC-8 → 64 位（高位在前）"""
    assert 0 <= pair_id < (1 << 24) and 0 <= secret < (1 << 32)
    body = pair_id.to_bytes(3, 'big') + secret.to_bytes(4, 'big')
    full = body + bytes([crc8(body)])
    return np.array([(full[i // 8] >> (7 - i % 8)) & 1 for i in range(64)], dtype=np.int64)

def parse_payload(bits) -> tuple | None:
    by = bytes(int(''.join(str(int(b)) for b in bits[i:i + 8]), 2) for i in range(0, 64, 8))
    if crc8(by[:7]) != by[7]:
        return None
    return int.from_bytes(by[:3], 'big'), int.from_bytes(by[3:7], 'big')

# ── 卷积码 K=7，G1 = 0o171，G2 = 0o133 ──
G1, G2, K = 0o171, 0o133, 7
def _parity(x): return bin(x).count('1') & 1
def conv_encode(bits) -> np.ndarray:
    st, out = 0, []
    for b in list(bits) + [0] * (K - 1):
        st = ((st << 1) | int(b)) & 0x7F
        out += [_parity(st & G1), _parity(st & G2)]
    return np.array(out, dtype=np.int64)

def viterbi(soft) -> np.ndarray:
    """soft：140 个软值（正 = 码位 1）。返回 64 个信息位"""
    n = len(soft) // 2
    INF = -1e18
    metric = np.full(64, INF); metric[0] = 0.0
    hist = np.zeros((n, 64), dtype=np.int64)
    for t in range(n):
        s1, s2 = soft[2 * t], soft[2 * t + 1]
        new = np.full(64, INF); prev = np.zeros(64, dtype=np.int64)
        for s in range(64):
            if metric[s] == INF: continue
            for b in (0, 1):
                full = ((s << 1) | b) & 0x7F
                o1, o2 = _parity(full & G1), _parity(full & G2)
                m = metric[s] + (s1 if o1 else -s1) + (s2 if o2 else -s2)
                ns = full & 0x3F
                if m > new[ns]: new[ns] = m; prev[ns] = (s << 1) | b
        metric = new; hist[t] = prev
    s, bits = 0, []
    for t in range(n - 1, -1, -1):
        p = hist[t][s]; bits.append(p & 1); s = p >> 1
    bits = bits[::-1]
    return np.array(bits[:n - (K - 1)], dtype=np.int64)

def cell_signs(pair_id: int, secret: int) -> np.ndarray:
    """160 个格子的正负（±1）"""
    coded = conv_encode(payload_bits(pair_id, secret))            # 140
    b = np.zeros(N_CELLS)
    b[PILOT_IDX] = PILOTS
    b[DATA_IDX[INTERLEAVE]] = 2.0 * coded - 1.0
    return b

def soft_from_cells(cell_soft) -> np.ndarray:
    """160 个格子的软值 → 140 个码位的软值（按交织表取回）"""
    return np.asarray(cell_soft)[DATA_IDX[INTERLEAVE]]

# ── 场与密度 ──
ALPHA, TAU = 0.25, 0.30       # 正的一侧浓一点：1 + α·tanh(D/τ)
BETA, W = 0.60, 0.10          # 零线上浓一些：1 + β·覆盖度²·exp(−(D/w)²)
def wrap(a): return (a + np.pi) % (2 * np.pi) - np.pi

# 固定的平滑扭曲（各语言照抄）：格子不再是一圈圈整齐的团，零线弯弯曲曲像折起来的丝
WARP = [  # (幅度, kx, ky, 相位) —— 位移 dx += a·sin(kx·x + ky·y + p)，dy += a·cos(ky·x − kx·y + p·1.3)
    (0.060, 2.3, 3.1, 0.7),
    (0.045, -3.7, 1.9, 2.1),
    (0.030, 5.3, -4.1, 4.4),
]
def warp_xy(x, y):
    dx = np.zeros_like(x); dy = np.zeros_like(y)
    for a, kx, ky, p in WARP:
        dx += a * np.sin(kx * x + ky * y + p)
        dy += a * np.cos(ky * x - kx * y + p * 1.3)
    return x + dx, y + dy

def field(b, x, y, coverage=False):
    """D(x, y) = Σ b_i G_i（x、y 为任意形状的数组，单位：云的半径；先过一遍固定扭曲）。
    coverage=True 时同时回 E = Σ G_i（这里有没有格子：没有格子的地方 D≈0，不能当零线）"""
    x, y = warp_xy(x, y)
    r = np.hypot(x, y); th = np.arctan2(y, x)
    D = np.zeros_like(r); E = np.zeros_like(r)
    for (ri, pi, st), bi in zip(CELLS, b):
        dr = r - ri; dt = ri * wrap(th - pi)
        g = np.exp(-(dr * dr) / (2 * SIGMA_R ** 2) - (dt * dt) / (2 * st * st))
        D += bi * g; E += g
    return (D, E) if coverage else D

E0 = 0.55                     # 覆盖度到这个数才算「有格子」：零线上的那一项只在有格子的地方
def modulation(D, E):
    """光学深度的倍数 M（显示时乘到每个粒子上；网页 / iOS 存成 8 位纹理：M / 3）"""
    gate = np.clip(E / E0, 0.0, 1.0)
    return (1.0 + ALPHA * np.tanh(D / TAU)) * (1.0 + BETA * gate * gate * np.exp(-(D / W) ** 2))
CODE_SCALE = 3.0              # 纹理里存 M / CODE_SCALE
CODE_GRID = 192               # 调制网格 192²，覆盖 [-1.6, 1.6]²
CODE_SPIN = 0.05              # 码平面每秒转的弧度
