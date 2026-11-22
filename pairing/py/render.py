"""训练数据：随机码 → 密度 → 撒粒子 → 随机相机（透视 / 旋转 / 远近）→ 模糊、曝光、噪点、摩尔纹、反光
→ 和手机上同一套「椭圆 + 极坐标展开」→ 网络输入；目标是每个采样点真实的 D（软正负）。"""
import math
import numpy as np, torch, torch.nn.functional as F
import spec

GS = 160                     # 源网格（云的平面，[-1.6, 1.6]²）
EXT = 1.6
CAM = 256                    # 相机裁出来的正方形
PR, PA = 24, 192             # 极坐标：径向 24 格（r 0.10–1.08）、角向 192 格
R_LO, R_HI = 0.10, 1.08
TH = 0.06                    # 算矩之前减掉的底（背景不完全干净）
K_RMS = None                 # 半径 = K_RMS × sqrt(主轴方差)（下面现算）

xs = np.linspace(-EXT, EXT, GS, endpoint=False) + EXT / GS
X, Y = np.meshgrid(xs, xs)
R = np.hypot(X, Y)
_Dbasis = []
Wx, Wy = spec.warp_xy(X, Y)
rr = np.hypot(Wx, Wy); th = np.arctan2(Wy, Wx)
for ri, pi, st in spec.CELLS:
    dr = rr - ri; dt = ri * spec.wrap(th - pi)
    _Dbasis.append(np.exp(-(dr * dr) / (2 * spec.SIGMA_R ** 2) - (dt * dt) / (2 * st * st)))
BASIS = torch.tensor(np.stack(_Dbasis), dtype=torch.float32)          # 160 × GS × GS
COVER = BASIS.sum(0)                                                   # 覆盖度（和码无关）
SHELL = torch.tensor(spec.shell(R), dtype=torch.float32)
GATE2 = torch.clamp(COVER / spec.E0, 0, 1) ** 2

def density(b):
    """b：B × 160（±1）→ D、ρ（B × GS × GS）"""
    D = torch.einsum('bi,ixy->bxy', b, BASIS)
    rho = SHELL * (1 + spec.ALPHA * torch.tanh(D / spec.TAU)) * (1 + spec.BETA * GATE2 * torch.exp(-(D / spec.W) ** 2))
    return D, rho

def _calib():
    """K_RMS：没有任何畸变时，主轴标准差 × K_RMS = 云的半径（对一批随机码取平均）"""
    g = torch.Generator().manual_seed(7)
    b = torch.randint(0, 2, (64, spec.N_CELLS), generator=g).float() * 2 - 1
    _, rho = density(b)
    w = torch.clamp(rho / rho.amax(dim=(1, 2), keepdim=True), 0, 1)
    Xt = torch.tensor(X, dtype=torch.float32); Yt = torch.tensor(Y, dtype=torch.float32)
    m = w.sum((1, 2))
    vx = (w * Xt * Xt).sum((1, 2)) / m
    return float((1.0 / torch.sqrt(vx)).mean())
K_RMS = _calib()

def lumps(B, g):
    """大尺度的疏密起伏（装饰，和码无关）"""
    Xt = torch.tensor(X, dtype=torch.float32)[None]; Yt = torch.tensor(Y, dtype=torch.float32)[None]
    out = torch.ones(B, GS, GS)
    amp = torch.rand(B, 1, 1, generator=g) * 0.30
    for _ in range(3):
        kx = (torch.rand(B, 1, 1, generator=g) - 0.5) * 6; ky = (torch.rand(B, 1, 1, generator=g) - 0.5) * 6
        ph = torch.rand(B, 1, 1, generator=g) * 6.283
        out = out + amp / 3 * torch.cos(kx * Xt + ky * Yt + ph)
    return out.clamp(min=0.3)

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

def camera_image(b, g, severity=1.0, n_particles=None, H=None):
    """b：B × 160 → 相机里看到的「蓝色程度」图（B × 1 × CAM × CAM）与单应矩阵"""
    B = b.shape[0]
    D, rho = density(b)
    rho = rho * lumps(B, g)
    N = n_particles or int(30000 + torch.rand(1, generator=g) * 90000)
    idx = torch.multinomial(rho.view(B, -1), N, replacement=True, generator=g)
    col = (idx % GS).float() + torch.rand(B, N, generator=g)
    row = (idx // GS).float() + torch.rand(B, N, generator=g)
    x = col / GS * 2 * EXT - EXT; y = row / GS * 2 * EXT - EXT
    H = H if H is not None else homography(B, g, severity)
    u, v = project(H, x, y)
    ui = u.round().long(); vi = v.round().long()
    ok = (ui >= 0) & (ui < CAM) & (vi >= 0) & (vi < CAM)
    flat = (torch.arange(B)[:, None] * CAM * CAM + vi * CAM + ui)[ok]
    cnt = torch.bincount(flat, minlength=B * CAM * CAM).float().view(B, 1, CAM, CAM)
    out = torch.empty_like(cnt)
    for i in range(B):
        sig = float(0.5 + torch.rand(1, generator=g) * 1.0 + torch.rand(1, generator=g) * 1.6 * severity)
        im = blur(cnt[i:i + 1], sig)
        if torch.rand(1, generator=g) < 0.3 * severity:                 # 手抖：一条线的运动模糊
            L = int(2 + torch.rand(1, generator=g) * 5); ang = float(torch.rand(1, generator=g) * 3.1416)
            k = torch.zeros(1, 1, 2 * L + 1, 2 * L + 1)
            for t in range(-L, L + 1):
                k[0, 0, int(round(L + t * math.sin(ang))), int(round(L + t * math.cos(ang)))] = 1
            im = F.conv2d(im, k / k.sum(), padding=L)
        # 曝光：让云里面的平均「墨」落在 0.15–0.6
        inside = im[im > 0]
        scale = float(inside.mean()) if inside.numel() else 1.0
        target = 0.15 + float(torch.rand(1, generator=g)) * 0.45
        c = -math.log(1 - target) / max(scale, 1e-6)
        ink = 1 - torch.exp(-c * im)
        gain = 0.6 + float(torch.rand(1, generator=g)) * 0.6; gam = 0.7 + float(torch.rand(1, generator=g)) * 0.7
        ink = gain * ink.clamp(0, 1) ** gam + (float(torch.rand(1, generator=g)) * 0.13 - 0.05) * severity
        yy, xx = torch.meshgrid(torch.arange(CAM).float(), torch.arange(CAM).float(), indexing='ij')
        if torch.rand(1, generator=g) < 0.5 * severity:                 # 屏幕像素和相机像素打架：摩尔纹
            kk = 0.8 + float(torch.rand(1, generator=g)) * 1.7; a = float(torch.rand(1, generator=g)) * 3.1416
            ink = ink + float(torch.rand(1, generator=g)) * 0.06 * torch.sin(kk * (xx * math.cos(a) + yy * math.sin(a)))
        if torch.rand(1, generator=g) < 0.15 * severity:                # 反光：一大块变白
            gx, gy = float(torch.rand(1, generator=g)) * CAM, float(torch.rand(1, generator=g)) * CAM
            gr = 20 + float(torch.rand(1, generator=g)) * 50
            ink = ink * (1 - (0.3 + 0.5 * float(torch.rand(1, generator=g))) * torch.exp(-((xx - gx) ** 2 + (yy - gy) ** 2) / (2 * gr * gr)))
        ink = ink + torch.randn(ink.shape, generator=g) * float(torch.rand(1, generator=g)) * 0.06 * severity
        out[i] = ink.clamp(0, 1)
    return out, H, D

def ellipse(ink):
    """手机上同一套：减底 → 矩 → 椭圆（中心、两轴、方向；方向保持右手系，不镜像）"""
    B = ink.shape[0]
    w = torch.clamp(ink[:, 0] - TH, min=0)
    yy, xx = torch.meshgrid(torch.arange(CAM).float(), torch.arange(CAM).float(), indexing='ij')
    m = w.sum((1, 2)).clamp(min=1e-6)
    mx = (w * xx).sum((1, 2)) / m; my = (w * yy).sum((1, 2)) / m
    dx = xx[None] - mx[:, None, None]; dy = yy[None] - my[:, None, None]
    cxx = (w * dx * dx).sum((1, 2)) / m; cyy = (w * dy * dy).sum((1, 2)) / m; cxy = (w * dx * dy).sum((1, 2)) / m
    C = torch.stack([torch.stack([cxx, cxy], -1), torch.stack([cxy, cyy], -1)], -2)
    ev, V = torch.linalg.eigh(C)                                      # 升序
    V = V.flip(-1); ev = ev.flip(-1)
    det = torch.linalg.det(V)
    V[:, :, 1] = V[:, :, 1] * det[:, None]                            # 保持右手系
    ax = K_RMS * torch.sqrt(ev.clamp(min=1e-6))
    return mx, my, V, ax

def polar_grid():
    r = torch.linspace(R_LO, R_HI, PR)
    a = torch.arange(PA).float() / PA * 2 * math.pi
    return r[:, None].expand(PR, PA), a[None, :].expand(PR, PA)

def polar_sample(ink, mx, my, V, ax):
    """极坐标网格上的点（单位：估出来的半径）→ 相机像素 → 双线性取样。返回 B × 1 × PR × PA，以及取样点像素坐标"""
    r, a = polar_grid()
    ex = r * torch.cos(a); ey = r * torch.sin(a)
    px = mx[:, None, None] + V[:, 0, 0, None, None] * ax[:, 0, None, None] * ex + V[:, 0, 1, None, None] * ax[:, 1, None, None] * ey
    py = my[:, None, None] + V[:, 1, 0, None, None] * ax[:, 0, None, None] * ex + V[:, 1, 1, None, None] * ax[:, 1, None, None] * ey
    grid = torch.stack([px / (CAM - 1) * 2 - 1, py / (CAM - 1) * 2 - 1], -1)
    out = F.grid_sample(ink, grid, mode='bilinear', padding_mode='zeros', align_corners=True)
    return out, px, py

def normalize(pol):
    """每张自己做归一（亮度、对比度差别交给这一步）"""
    m = pol.mean((2, 3), keepdim=True); s = pol.std((2, 3), keepdim=True)
    return (pol - m) / (s + 1e-4)

def batch(B, g, severity=1.0, bits=None):
    b = bits if bits is not None else torch.randint(0, 2, (B, spec.N_CELLS), generator=g).float() * 2 - 1
    ink, H, D = camera_image(b, g, severity)
    mx, my, V, ax = ellipse(ink)
    pol, px, py = polar_sample(ink, mx, my, V, ax)
    # 目标：每个取样点在云平面上的位置 → 那里真实的 D
    Hi = torch.linalg.inv(H)
    q = torch.stack([px, py, torch.ones_like(px)], -1) @ Hi.transpose(1, 2)[:, None]
    sx = q[..., 0] / q[..., 2]; sy = q[..., 1] / q[..., 2]
    grid = torch.stack([sx / EXT, sy / EXT], -1)                       # 源网格 [-EXT, EXT] → [-1, 1]
    Dt = F.grid_sample(D[:, None], grid, mode='bilinear', padding_mode='zeros', align_corners=False)
    mask = (torch.hypot(sx, sy) < 1.0).float()[:, None]
    return normalize(pol), torch.tanh(Dt / 0.35), mask, b, ink

# ── v1.1：更准的「框」（中心 + 2×2 映射）─────────────────────────────
# 只靠矩估半径误差 14%（背景、过曝、反光都会把矩撑大），外圈的格子又细 → 模板对不上。现在两步：
#   ① 减掉背景（全画面 20% 分位）再算矩 → 粗中心、粗椭圆
#   ② 在粗椭圆的坐标里打 24 条射线，每条找「亮边过了峰值、掉到峰值一半」的那一点（球壳边上最密、外面一圈雾往下掉）
#      → 24 个边缘点拟合 c + M·(cos θ, sin θ)（最小二乘，去掉最差的 4 个再拟合一次）→ 除以标定常数 EDGE_K
N_RAYS, RAY_N, RAY_T0, RAY_T1 = 24, 64, 0.2, 1.8
EDGE_K = None            # 半宽处的半径 / 真半径（下面标定）
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

def _calib_edge():
    """EDGE_K：无畸变、中等曝光时，半宽处的半径 / 真半径（对一批随机码取中位数）"""
    global EDGE_K
    EDGE_K = 1.0
    g = torch.Generator().manual_seed(17)
    vals = []
    for _ in range(4):
        b = torch.randint(0, 2, (16, spec.N_CELLS), generator=g).float() * 2 - 1
        ink, H, _ = camera_image(b, g, 0.0)
        c, M = frame(ink)
        t = torch.linspace(0, 2 * math.pi, 361)[:-1]
        u, v = project(H, torch.cos(t)[None].expand(16, -1), torch.sin(t)[None].expand(16, -1))
        area = 0.5 * torch.abs((u * torch.roll(v, -1, 1) - torch.roll(u, -1, 1) * v).sum(1))
        vals += (torch.sqrt(torch.abs(torch.linalg.det(M))) / torch.sqrt(area / math.pi)).tolist()
    EDGE_K = float(np.median(vals))
_calib_edge()

def batch_v11(B, g, severity=1.0, bits=None):
    """和 batch 一样，只是「框」换成 v1.1 的 frame"""
    b = bits if bits is not None else torch.randint(0, 2, (B, spec.N_CELLS), generator=g).float() * 2 - 1
    ink, H, D = camera_image(b, g, severity)
    c, M = frame(ink)
    pol, px, py = polar_sample_m(ink, c, M)
    Hi = torch.linalg.inv(H)
    q = torch.stack([px, py, torch.ones_like(px)], -1) @ Hi.transpose(1, 2)[:, None]
    sx = q[..., 0] / q[..., 2]; sy = q[..., 1] / q[..., 2]
    grid = torch.stack([sx / EXT, sy / EXT], -1)
    Dt = F.grid_sample(D[:, None], grid, mode='bilinear', padding_mode='zeros', align_corners=False)
    mask = (torch.hypot(sx, sy) < 1.0).float()[:, None]
    return normalize(pol), torch.tanh(Dt / 0.35), mask, b, ink
