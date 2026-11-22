"""同一个姿态连拍几帧（粒子在动、噪点不同）取平均；匹配滤波 vs 最小二乘解卷"""
import numpy as np, torch
import spec, render, model, decode
torch.set_num_threads(3)
net = model.Net(); net.load_state_dict(torch.load('../model/cpc1.pt')); net.eval()
T = decode.T.reshape(spec.N_CELLS, -1)                                      # 160 × (PR·PA)
G = T @ T.T + 1e-3 * np.eye(spec.N_CELLS)
Gi = np.linalg.inv(G)
def cells_ls(d, s):
    D = np.roll(d, -s, axis=1).reshape(-1)                                  # 对齐到旋转 s
    return Gi @ (T @ D)
def run(n, sev, frames, seed):
    g = torch.Generator().manual_seed(seed); rng = np.random.default_rng(seed)
    mf = ls = dec_mf = dec_ls = rot = fullok = 0
    for _ in range(n):
        pid, sec = int(rng.integers(0, 1 << 24)), int(rng.integers(0, 1 << 32))
        bt = spec.cell_signs(pid, sec); b = torch.tensor(bt, dtype=torch.float32)[None]
        H = render.homography(1, g, sev)
        acc = None
        for k in range(frames):
            ink, _, _ = render.camera_image(b, g, sev, H=H)
            c, M = render.frame(ink)
            pol, _, _ = render.polar_sample_m(ink, c, M)
            with torch.no_grad(): d = net(model.with_radius(render.normalize(pol)))[0, 0].numpy()
            acc = d if acc is None else acc + d
        d = acc / frames
        S = decode.cell_scores(d)
        so = int(np.argmax((np.sign(S) == bt[:, None]).mean(0)))
        p_ls, s_ls, _ = decode.decode_ls(d)
        rot_ok = abs(((s_ls - so + render.PA // 2) % render.PA) - render.PA // 2) <= 1
        full = p_ls == (pid, sec)
        mf += (np.sign(S[:, so]) == bt).mean()
        L = cells_ls(d, so); ls += (np.sign(L) == bt).mean()
        for est, name in ((S[:, so], 'mf'), (L, 'ls')):
            soft = spec.soft_from_cells(est); bits = spec.viterbi(soft / (np.abs(soft).mean() + 1e-9))
            ok = spec.parse_payload(bits) == (pid, sec)
            if name == 'mf': dec_mf += ok
            else: dec_ls += ok
        rot += rot_ok; fullok += full
    print(f'sev {sev} × {frames} 帧：格子一致率 匹配滤波 {mf/n:.3f} / 最小二乘 {ls/n:.3f} · 用对的旋转解出 {dec_mf/n:.0%} / {dec_ls/n:.0%} · 导频找对旋转 {rot/n:.0%} · 完整解码 {fullok/n:.0%}', flush=True)
for sev in (0.5, 1.0):
    for fr in (1, 4): run(16, sev, fr, 5 + int(sev * 10) + fr)
