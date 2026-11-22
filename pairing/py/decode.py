"""完整解码：网络输出的 D̂（极坐标）→ 每个格子做匹配滤波（所有旋转一起算，FFT）→ 导频定旋转 → Viterbi → CRC"""
import math, numpy as np, torch
import spec, render

def templates():
    r, a = render.polar_grid()
    x = (r * torch.cos(a)).numpy(); y = (r * torch.sin(a)).numpy()
    wx, wy = spec.warp_xy(x, y)
    rr = np.hypot(wx, wy); th = np.arctan2(wy, wx)
    T = []
    for ri, pi, st in spec.CELLS:
        dr = rr - ri; dt = ri * spec.wrap(th - pi)
        T.append(np.exp(-(dr * dr) / (2 * spec.SIGMA_R ** 2) - (dt * dt) / (2 * st * st)))
    T = np.stack(T)                                                      # 160 × PR × PA
    return T, (T * T).sum((1, 2))
T, TN = templates()
TF = np.conj(np.fft.rfft(T, axis=2))                                     # 160 × PR × (PA/2+1)

def cell_scores(Dhat):
    """Dhat：PR × PA → 160 × PA（每个格子在每个旋转下的软值）"""
    Fd = np.fft.rfft(Dhat, axis=1)                                       # PR × F
    c = np.fft.irfft(Fd[None] * TF, n=render.PA, axis=2).sum(1)           # 160 × PA
    return c / TN[:, None]

def decode(Dhat, tries=3):
    S = cell_scores(Dhat)
    pil = (spec.PILOTS[:, None] * S[spec.PILOT_IDX]).sum(0)
    norm = np.sqrt((S[spec.PILOT_IDX] ** 2).sum(0)) + 1e-9
    order = np.argsort(-(pil / norm))
    for s in order[:tries]:
        soft = spec.soft_from_cells(S[:, s])
        bits = spec.viterbi(soft / (np.abs(soft).mean() + 1e-9))
        p = spec.parse_payload(bits)
        if p is not None:
            return p, int(s), S[:, s]
    return None, int(order[0]), S[:, order[0]]


# ── v1.1：最小二乘解卷（相邻格子的高斯有重叠：一起解比各自做匹配滤波准得多）+ 导频定旋转 ──
TF2 = T.reshape(T.shape[0], -1)
GRAM = TF2 @ TF2.T + 1e-3 * np.eye(T.shape[0])
GINV = np.linalg.inv(GRAM)

def cell_ls_all(Dhat):
    """Dhat：PR × PA → 160 × PA：每个旋转下最小二乘解出的格子值"""
    Fd = np.fft.rfft(Dhat, axis=1)
    raw = np.fft.irfft(Fd[None] * TF, n=render.PA, axis=2).sum(1)      # 160 × PA（没除以 TN 的相关）
    return GINV @ raw

def decode_ls(Dhat, tries=3):
    L = cell_ls_all(Dhat)
    pil = (spec.PILOTS[:, None] * L[spec.PILOT_IDX]).sum(0)
    norm = np.sqrt((L[spec.PILOT_IDX] ** 2).sum(0)) + 1e-9
    order = np.argsort(-(pil / norm))
    for s in order[:tries]:
        soft = spec.soft_from_cells(L[:, s])
        bits = spec.viterbi(soft / (np.abs(soft).mean() + 1e-9))
        p = spec.parse_payload(bits)
        if p is not None:
            return p, int(s), L[:, s]
    return None, int(order[0]), L[:, order[0]]
