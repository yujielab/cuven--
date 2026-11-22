import sys, numpy as np, torch
import spec, render, model, decode
torch.set_num_threads(2)
net = model.Net(); net.load_state_dict(torch.load('../model/cpc1.pt')); net.eval()
def diag(n, sev, seed):
    g = torch.Generator().manual_seed(seed); rng = np.random.default_rng(seed)
    rows = []
    for _ in range(n):
        pid, sec = int(rng.integers(0, 1 << 24)), int(rng.integers(0, 1 << 32))
        bt = spec.cell_signs(pid, sec)
        b = torch.tensor(bt, dtype=torch.float32)[None]
        x, y, m, _, _ = render.batch_v11(1, g, severity=sev, bits=b)
        with torch.no_grad(): d = net(model.with_radius(x))[0, 0].numpy()
        S = decode.cell_scores(d)                                          # 160 × PA
        agree = (np.sign(S) == bt[:, None]).mean(0)                        # 每个旋转下格子正负的一致率
        so = int(np.argmax(agree))                                         # 「上帝视角」的旋转
        pil = (spec.PILOTS[:, None] * S[spec.PILOT_IDX]).sum(0) / (np.sqrt((S[spec.PILOT_IDX] ** 2).sum(0)) + 1e-9)
        sp = int(np.argmax(pil))
        soft = spec.soft_from_cells(S[:, so]); bits = spec.viterbi(soft / (np.abs(soft).mean() + 1e-9))
        rows.append((agree[so], so == sp or abs(so - sp) <= 1, spec.parse_payload(bits) == (pid, sec), float(((np.sign(d) == np.sign(y[0,0].numpy())) * m[0,0].numpy()).sum() / m.sum())))
    a = np.array(rows, dtype=float)
    print(f'sev {sev}: 格子正负一致率（对的旋转）{a[:,0].mean():.3f}（最差 {a[:,0].min():.2f}）· 导频找对旋转 {a[:,1].mean():.0%} · 用对的旋转能解出 {a[:,2].mean():.0%} · 像素正负 {a[:,3].mean():.3f}')
for sev in (0.5, 1.0): diag(20, sev, 3 + int(sev * 10))
