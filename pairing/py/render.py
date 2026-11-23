"""训练数据（外观 v2）：复刻的 3D 粒子云 × 码的调制 → 随机相机 → 和手机上同一套「找框 + 极坐标展开」→ 网络输入；
目标是每个采样点真实的 D（软正负）。

  · 粒子云本身和码无关：用浏览器把 web/pair.js（码关掉，M = 1）在一个 10 秒循环里渲染 360 帧（pairing/frames/），
    每帧存「覆盖度」c（1 − 透过率）和每单位覆盖度的蓝色程度 k
  · 显示时码乘在每个粒子的光学深度上 → 一点的透过率 T 变成 T^M：带码的蓝色程度 = (1 − (1 − c)^M) · k
    M 和显示时一样：192² 网格、8 位量化、双线性取样；码平面可以转任意角度
  · 扫描端把连着几帧的极坐标图平均了再进网络（滚动的结构抹平、码留下来）：这里同样把连着 n 帧（AVG_FRAMES/4 – AVG_FRAMES）平均
  · 相机：透视 / 倾斜 ≤ 40°、远近、偏心 → 失焦、手抖、曝光、伽马、摩尔纹、反光、噪点"""
import math, os
import numpy as np, torch, torch.nn.functional as F
import spec

EXT = 1.6                    # 码平面的范围：[-1.6, 1.6]²（云的半径 = 1）
CAM = 256                    # 相机裁出来的正方形
PR, PA = 24, 192             # 极坐标：径向 24 格（r 0.10–1.08）、角向 192 格
R_LO, R_HI = 0.10, 1.08
TH = 0.06
N_RAYS, RAY_N, RAY_T0, RAY_T1 = 24, 64, 0.2, 1.8
AVG_FRAMES = 16              # 扫描端平均最近几帧的极坐标图（30 帧每秒时约半秒）
K_RMS = None                 # 半径 = K_RMS × sqrt(主轴方差)（下面标定）
EDGE_K = None                # 半高处的半径 / 真半径（下面标定）

# ── 码的调制网格：和显示时一样（192²，像素中心取样，第 0 行 y 最小）──
MG = spec.CODE_GRID
_c = -EXT + (np.arange(MG) + 0.5) * 2 * EXT / MG
_X, _Y = np.meshgrid(_c, _c)
_Wx, _Wy = spec.warp_xy(_X, _Y)
_rr, _th = np.hypot(_Wx, _Wy), np.arctan2(_Wy, _Wx)
BASIS = torch.tensor(np.stack([np.exp(-((_rr - ri) ** 2) / (2 * spec.SIGMA_R ** 2) - (ri * spec.wrap(_th - pi)) ** 2 / (2 * st * st))
                               for ri, pi, st in spec.CELLS]), dtype=torch.float32)            # 160 × MG × MG
GATE2 = torch.clamp(BASIS.sum(0) / spec.E0, 0, 1) ** 2

def code_grids(b):
    """b：B × 160 → D（B × MG × MG）、M（8 位量化后的，和显示时纹理里的一样）"""
    D = torch.einsum('bi,ixy->bxy', b, BASIS)
    M = (1 + spec.ALPHA * torch.tanh(D / spec.TAU)) * (1 + spec.BETA * GATE2 * torch.exp(-(D / spec.W) ** 2))
    M = torch.round(M / spec.CODE_SCALE * 255).clamp(0, 255) / 255 * spec.CODE_SCALE
    return D, M

# ── 渲染好的粒子云帧 ──
FRAMES = os.environ.get('CPC_FRAMES', os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'frames', 'look-frames.npz'))
_z = np.load(FRAMES)
COV = torch.from_numpy(_z['cov'])                                      # NF × S × S（uint8）
KK = torch.from_numpy(_z['k'])
FRAD = float(_z['radius_px']); FSIZE = int(_z['size'])
NF = COV.shape[0]
# 半分辨率的一份（云在相机里小的时候用，免得隔点取样把颗粒取花了）
COV2 = F.avg_pool2d(COV[:, None].float(), 2)[:, 0].round().to(torch.uint8)
KK2 = F.avg_pool2d(KK[:, None].float(), 2)[:, 0].round().to(torch.uint8)

def homography(B, g, severity=1.0):
    """云的平面（单位：半径）→ 相机像素。倾斜 0–40°、任意转角、远近、焦距、偏心"""
    tilt = torch.rand(B, generator=g) * math.radians(40) * severity
    axis = torch.rand(B, generator=g) * 6.283
    rot = torch.rand(B, generator=g) * 6.283
    rcam = 45 + torch.rand(B, generator=g) * 70                      # 云在相机里的半径（像素）
    f = 250 + torch.rand(B, generator=g) * 450
    cx = CAM / 2 + (torch.rand(B, generator=g) - 0.5) * 50 * severity
    cy = CAM / 2 + (torch.rand(B, generator=g) - 0.5) * 50 * severity
    H = torch.zeros(B, 3, 3)
    for i in range(B):
        c, s = math.cos(rot[i]), math.sin(rot[i])
        Rz = torch.tensor([[c, -s, 0], [s, c, 0], [0, 0, 1.0]])
        ux, uy = math.cos(axis[i]), math.sin(axis[i]); t = float(tilt[i]); ct, st = math.cos(t), math.sin(t)
        # 绕平面内的轴 (ux, uy, 0) 转 t（罗德里格斯）
        Ru = torch.tensor([[ct + ux * ux * (1 - ct), ux * uy * (1 - ct), uy * st],
                           [uy * ux * (1 - ct), ct + uy * uy * (1 - ct), -ux * st],
                           [-uy * st, ux * st, ct]])
        Rm = Ru @ Rz
        Z0 = float(f[i]) / float(rcam[i])                            # 云半径 1 → 正对时投成 rcam 像素
        # 平面点 (x, y, 0) → 相机 (X, Y, Z) = Rm·(x, y, 0) + (0, 0, Z0)；像素 = f·X/Z + c
        K = torch.tensor([[float(f[i]), 0, float(cx[i])], [0, float(f[i]), float(cy[i])], [0, 0, 1.0]])
        M = torch.stack([Rm[:, 0], Rm[:, 1], torch.tensor([0, 0, Z0])], dim=1)
        H[i] = K @ M
    return H

def project(H, x, y):
    p = torch.stack([x, y, torch.ones_like(x)], dim=-1) @ H.transpose(1, 2)
    return p[..., 0] / p[..., 2], p[..., 1] / p[..., 2]

def gauss_kernel(sig):
    r = max(1, int(math.ceil(3 * sig)))
    t = torch.arange(-r, r + 1, dtype=torch.float32)
    k = torch.exp(-t * t / (2 * sig * sig)); return k / k.sum()

def blur(img, sig):
    if sig < 0.3: return img
    k = gauss_kernel(sig); n = len(k)
    img = F.conv2d(img, k.view(1, 1, 1, n), padding=(0, n // 2))
    return F.conv2d(img, k.view(1, 1, n, 1), padding=(n // 2, 0))

def camera_ink(b, g, severity=1.0, H=None, nframes=None, theta=None):
    """b：B × 160 → 相机里看到的「蓝色程度」（B × 1 × CAM × CAM）、单应矩阵 H、码的 D 网格、码平面的转角"""
    B = b.shape[0]
    D, M = code_grids(b)
    H = H if H is not None else homography(B, g, severity)
    theta = theta if theta is not None else torch.rand(B, generator=g) * 2 * math.pi
    vv, uu = torch.meshgrid(torch.arange(CAM).float(), torch.arange(CAM).float(), indexing='ij')
    q = torch.stack([uu, vv, torch.ones_like(uu)], -1).view(1, -1, 3) @ torch.linalg.inv(H).transpose(1, 2)
    xf = (q[..., 0] / q[..., 2]).view(B, CAM, CAM); yf = (q[..., 1] / q[..., 2]).view(B, CAM, CAM)   # 云的坐标（y 朝下）
    ct, st = torch.cos(theta)[:, None, None], torch.sin(theta)[:, None, None]
    xc, yc = ct * xf - st * yf, st * xf + ct * yf                                                       # 码平面
    Mc = F.grid_sample(M[:, None], torch.stack([xc / EXT, yc / EXT], -1), mode='bilinear', padding_mode='border', align_corners=False)
    J = torch.sqrt(torch.abs(torch.linalg.det(H[:, :2, :2] / H[:, 2:, 2:])))                         # 正中附近：每单位多少像素
    gscale = FRAD / (FSIZE / 2)
    out = torch.empty(B, 1, CAM, CAM)
    for i in range(B):
        n = nframes or int(torch.randint(max(1, AVG_FRAMES // 4), AVG_FRAMES + 1, (1,), generator=g))
        f0 = int(torch.randint(0, NF, (1,), generator=g))
        idx = (torch.arange(n) + f0) % NF
        small = float(J[i]) < FRAD * 0.6
        cov = (COV2 if small else COV)[idx][:, None].float() / 255
        kk = (KK2 if small else KK)[idx][:, None].float() / 255
        grid = torch.stack([xf[i] * gscale, yf[i] * gscale], -1)[None].expand(n, -1, -1, -1)
        cs = F.grid_sample(cov, grid, mode='bilinear', padding_mode='zeros', align_corners=False)
        ks = F.grid_sample(kk, grid, mode='bilinear', padding_mode='zeros', align_corners=False)
        ink = ((1 - (1 - cs.clamp(0, 0.995)) ** Mc[i:i + 1]) * ks).mean(0, keepdim=True)
        # 相机
        sig = float(0.4 + torch.rand(1, generator=g) * 0.8 + torch.rand(1, generator=g) * 1.4 * severity)
        im = blur(ink, sig)
        if torch.rand(1, generator=g) < 0.3 * severity:                 # 手抖：一条线的运动模糊
            L = int(2 + torch.rand(1, generator=g) * 5); ang = float(torch.rand(1, generator=g) * 3.1416)
            k = torch.zeros(1, 1, 2 * L + 1, 2 * L + 1)
            for t in range(-L, L + 1):
                k[0, 0, int(round(L + t * math.sin(ang))), int(round(L + t * math.cos(ang)))] = 1
            im = F.conv2d(im, k / k.sum(), padding=L)
        inside = im[im > 0.01]
        scale = float(inside.mean()) if inside.numel() else 1.0
        target = 0.15 + float(torch.rand(1, generator=g)) * 0.45        # 曝光：云里面的平均「墨」落在 0.15–0.6
        c = -math.log(1 - target) / max(scale, 1e-6)
        im = 1 - torch.exp(-c * im)
        gain = 0.6 + float(torch.rand(1, generator=g)) * 0.6; gam = 0.7 + float(torch.rand(1, generator=g)) * 0.7
        im = gain * im.clamp(0, 1) ** gam + (float(torch.rand(1, generator=g)) * 0.13 - 0.05) * severity
        if torch.rand(1, generator=g) < 0.5 * severity:                 # 屏幕像素和相机像素打架：摩尔纹
            kk2 = 0.8 + float(torch.rand(1, generator=g)) * 1.7; a = float(torch.rand(1, generator=g)) * 3.1416
            im = im + float(torch.rand(1, generator=g)) * 0.06 * torch.sin(kk2 * (uu * math.cos(a) + vv * math.sin(a)))
        if torch.rand(1, generator=g) < 0.15 * severity:                # 反光：一大块变白
            gx, gy = float(torch.rand(1, generator=g)) * CAM, float(torch.rand(1, generator=g)) * CAM
            gr = 20 + float(torch.rand(1, generator=g)) * 50
            im = im * (1 - (0.3 + 0.5 * float(torch.rand(1, generator=g))) * torch.exp(-((uu - gx) ** 2 + (vv - gy) ** 2) / (2 * gr * gr)))
        im = im + torch.randn(im.shape, generator=g) * float(torch.rand(1, generator=g)) * 0.06 * severity / math.sqrt(n)
        out[i] = im.clamp(0, 1)[0]
    return out, H, D, theta

def ellipse_area_radius(H):
    """单位圆投到相机里的面积 → 等效半径（像素）"""
    t = torch.linspace(0, 2 * math.pi, 361)[:-1]
    B = H.shape[0]
    u, v = project(H, torch.cos(t)[None].expand(B, -1), torch.sin(t)[None].expand(B, -1))
    area = 0.5 * torch.abs((u * torch.roll(v, -1, 1) - torch.roll(u, -1, 1) * v).sum(1))
    return torch.sqrt(area / math.pi)

# ── 找框（和手机上逐步一致：减背景算矩 → 24 条射线找亮边的半高点 → 最小二乘 → 除以 EDGE_K → 去掉旋转）──
def frame(ink):
    """ink：B × 1 × CAM × CAM → c（B × 2）、M（B × 2 × 2）：极坐标点 (r cos φ, r sin φ) → 像素 = c + M·(…)"""
    B = ink.shape[0]
    flat = ink.view(B, -1)
    bg = torch.quantile(flat, 0.2, dim=1)
    w = torch.clamp(ink[:, 0] - bg[:, None, None] - 0.04, min=0)
    yy, xx = torch.meshgrid(torch.arange(CAM).float(), torch.arange(CAM).float(), indexing='ij')
    m = w.sum((1, 2)).clamp(min=1e-6)
    mx = (w * xx).sum((1, 2)) / m; my = (w * yy).sum((1, 2)) / m
    dx = xx[None] - mx[:, None, None]; dy = yy[None] - my[:, None, None]
    cxx = (w * dx * dx).sum((1, 2)) / m; cyy = (w * dy * dy).sum((1, 2)) / m; cxy = (w * dx * dy).sum((1, 2)) / m
    C = torch.stack([torch.stack([cxx, cxy], -1), torch.stack([cxy, cyy], -1)], -2)
    ev, V = torch.linalg.eigh(C)
    V = V.flip(-1); ev = ev.flip(-1)
    det = torch.linalg.det(V); V[:, :, 1] = V[:, :, 1] * det[:, None]
    ax = K_RMS * torch.sqrt(ev.clamp(min=1e-6))
    M0 = V * ax[:, None, :]                                            # 粗映射
    c0 = torch.stack([mx, my], -1)
    # 射线
    th = torch.arange(N_RAYS).float() / N_RAYS * 2 * math.pi
    t = torch.linspace(RAY_T0, RAY_T1, RAY_N)
    u = torch.stack([torch.cos(th)[:, None] * t[None], torch.sin(th)[:, None] * t[None]], -1)   # R × N × 2
    pts = c0[:, None, None] + torch.einsum('bij,rnj->brni', M0, u)                              # B × R × N × 2
    grid = pts / (CAM - 1) * 2 - 1
    prof = F.grid_sample(ink, grid, mode='bilinear', padding_mode='zeros', align_corners=True)[:, 0] - bg[:, None, None]
    prof = F.avg_pool1d(prof.reshape(B * N_RAYS, 1, RAY_N), 5, stride=1, padding=2).view(B, N_RAYS, RAY_N)
    lo = int((0.6 - RAY_T0) / (RAY_T1 - RAY_T0) * (RAY_N - 1)); hi = int((1.4 - RAY_T0) / (RAY_T1 - RAY_T0) * (RAY_N - 1))
    pk, pi = prof[:, :, lo:hi + 1].max(-1); pi = pi + lo
    idx = torch.arange(RAY_N)[None, None]
    below = (prof < 0.5 * pk[..., None]) & (idx > pi[..., None])
    first = torch.where(below, idx.expand_as(below), torch.full_like(below, RAY_N - 1, dtype=torch.long)).min(-1).values
    # 亚像素：在 first-1 和 first 之间线性插值到半高
    f1 = first.clamp(1, RAY_N - 1); f0 = f1 - 1
    p0 = prof.gather(-1, f0[..., None])[..., 0]; p1 = prof.gather(-1, f1[..., None])[..., 0]
    frac = ((p0 - 0.5 * pk) / (p0 - p1).clamp(min=1e-6)).clamp(0, 1)
    te = RAY_T0 + (f0.float() + frac) / (RAY_N - 1) * (RAY_T1 - RAY_T0)                         # B × R
    e = c0[:, None] + torch.einsum('bij,brj->bri', M0, torch.stack([torch.cos(th)[None] * te, torch.sin(th)[None] * te], -1))
    # 最小二乘：e_k = c + M·(cos θ_k, sin θ_k)
    A = torch.stack([torch.ones(N_RAYS), torch.cos(th), torch.sin(th)], -1)                    # R × 3
    def fit(mask):
        W = mask.float()                                                                       # B × R
        AtA = torch.einsum('ri,br,rj->bij', A, W, A) + 1e-6 * torch.eye(3)
        Atb = torch.einsum('ri,br,brk->bik', A, W, e)
        return torch.linalg.solve(AtA, Atb)                                                    # B × 3 × 2
    sol = fit(torch.ones(B, N_RAYS, dtype=torch.bool))
    res = (e - torch.einsum('ri,bik->brk', A, sol)).norm(dim=-1)
    keep = res <= res.sort(-1).values[:, N_RAYS - 5:N_RAYS - 4]
    sol = fit(keep)
    c = sol[:, 0]
    M = torch.stack([sol[:, 1], sol[:, 2]], -1) / EDGE_K                                        # 列：cos、sin 的系数
    bad = (torch.linalg.det(M) <= 0) | ~torch.isfinite(M).all((1, 2))
    M = torch.where(bad[:, None, None], M0, M); c = torch.where(bad[:, None], c0, c)
    return c, canon(M)

def canon(M):
    """去掉 M 里的旋转（极分解 M = R·P，只留对称正定的 P）：角度 0 永远对着相机画面的 x 方向。
    手机拿稳时前后几帧的极坐标图就是对齐的，才能取平均（特征向量定的方向每帧都在乱跳，平均起来反而更糊）"""
    a, b, c, d = M[:, 0, 0], M[:, 0, 1], M[:, 1, 0], M[:, 1, 1]
    n = torch.sqrt((a + d) ** 2 + (c - b) ** 2).clamp(min=1e-9)
    ca, sa = (a + d) / n, (c - b) / n                                  # R = [[ca, -sa], [sa, ca]]
    P = torch.stack([torch.stack([ca * a + sa * c, ca * b + sa * d], -1),
                     torch.stack([-sa * a + ca * c, -sa * b + ca * d], -1)], -2)
    return P

def polar_sample_m(ink, c, M):
    r, a = polar_grid()
    ex = r * torch.cos(a); ey = r * torch.sin(a)
    px = c[:, 0, None, None] + M[:, 0, 0, None, None] * ex + M[:, 0, 1, None, None] * ey
    py = c[:, 1, None, None] + M[:, 1, 0, None, None] * ex + M[:, 1, 1, None, None] * ey
    grid = torch.stack([px / (CAM - 1) * 2 - 1, py / (CAM - 1) * 2 - 1], -1)
    return F.grid_sample(ink, grid, mode='bilinear', padding_mode='zeros', align_corners=True), px, py

def polar_grid():
    r = torch.linspace(R_LO, R_HI, PR)
    a = torch.arange(PA).float() / PA * 2 * math.pi
    return r[:, None].expand(PR, PA), a[None, :].expand(PR, PA)

def normalize(pol):
    """每张自己做归一（亮度、对比度差别交给这一步）"""
    m = pol.mean((2, 3), keepdim=True); s = pol.std((2, 3), keepdim=True)
    return (pol - m) / (s + 1e-4)

def _calib():
    """K_RMS、EDGE_K：正对、无畸变、几帧平均时，「矩」和「半高处」量出来的半径 / 真半径（取中位数）"""
    global K_RMS, EDGE_K
    g = torch.Generator().manual_seed(17)
    b = torch.randint(0, 2, (24, spec.N_CELLS), generator=g).float() * 2 - 1
    ink, H, _, _ = camera_ink(b, g, 0.0, nframes=AVG_FRAMES)
    r = ellipse_area_radius(H)
    flat = ink.view(24, -1)
    bg = torch.quantile(flat, 0.2, dim=1)
    w = torch.clamp(ink[:, 0] - bg[:, None, None] - 0.04, min=0)
    yy, xx = torch.meshgrid(torch.arange(CAM).float(), torch.arange(CAM).float(), indexing='ij')
    m = w.sum((1, 2)); mx = (w * xx).sum((1, 2)) / m; my = (w * yy).sum((1, 2)) / m
    var = (w * ((xx - mx[:, None, None]) ** 2 + (yy - my[:, None, None]) ** 2)).sum((1, 2)) / m / 2
    K_RMS = float(torch.median(r / torch.sqrt(var)))
    EDGE_K = 1.0
    c, M = frame(ink)
    EDGE_K = float(torch.median(torch.sqrt(torch.abs(torch.linalg.det(M))) / r))
_calib()

def batch(B, g, severity=1.0, bits=None, nframes=None):
    b = bits if bits is not None else torch.randint(0, 2, (B, spec.N_CELLS), generator=g).float() * 2 - 1
    ink, H, D, theta = camera_ink(b, g, severity, nframes=nframes)
    c, M = frame(ink)
    pol, px, py = polar_sample_m(ink, c, M)
    # 目标：每个取样点 → 云的坐标 → 码平面 → 那里真实的 D
    q = torch.stack([px, py, torch.ones_like(px)], -1) @ torch.linalg.inv(H).transpose(1, 2)[:, None]
    sx = q[..., 0] / q[..., 2]; sy = q[..., 1] / q[..., 2]
    ct, st = torch.cos(theta)[:, None, None], torch.sin(theta)[:, None, None]
    xc, yc = ct * sx - st * sy, st * sx + ct * sy
    Dt = F.grid_sample(D[:, None], torch.stack([xc / EXT, yc / EXT], -1), mode='bilinear', padding_mode='zeros', align_corners=False)
    mask = (torch.hypot(sx, sy) < 1.0).float()[:, None]
    return normalize(pol), torch.tanh(Dt / 0.35), mask, b, ink
