"""训练：python3 train.py [步数]。每 200 步存一次、打印一次；最后跑端到端解码率"""
import sys, time, math, torch, numpy as np
import spec, render, model, decode

torch.set_num_threads(4)
steps = int(sys.argv[1]) if len(sys.argv) > 1 else 3000
init = sys.argv[2] if len(sys.argv) > 2 else ''
net = model.Net()
if init: net.load_state_dict(torch.load(init)); print('接着训练：', init, flush=True)
opt = torch.optim.Adam(net.parameters(), lr=2e-3)
sched = torch.optim.lr_scheduler.OneCycleLR(opt, max_lr=2e-3, total_steps=steps, pct_start=0.08)
g = torch.Generator().manual_seed(1234)
t0 = time.time(); run = 0.0
for step in range(1, steps + 1):
    sev = min(1.0, (0.75 if init else 0.4) + step / (steps * 0.5))      # 先易后难（接着训练时从 0.75 起）
    x, y, m, _, _ = render.batch_v11(32, g, severity=sev)
    out = net(model.with_radius(x))
    loss = (((out - y) ** 2) * m).sum() / m.sum()
    opt.zero_grad(); loss.backward(); opt.step(); sched.step()
    run = 0.98 * run + 0.02 * float(loss.detach()) if step > 1 else float(loss.detach())
    if step % 200 == 0 or step == steps:
        # 格子正负的准确率（匹配滤波 + 已知旋转之外的那套，直接看取样点的正负）
        with torch.no_grad():
            acc = (((out > 0) == (y > 0)).float() * m).sum() / m.sum()
        print(f'step {step} loss {run:.4f} sign-acc {float(acc):.3f} sev {sev:.2f} {time.time() - t0:.0f}s', flush=True)
        torch.save(net.state_dict(), '../model/cpc1.pt')
model.export(net, '../model/cpc1.json', '../model/cpc1.bin')

# 端到端：随机配对码 → 渲染 → 解码
def e2e(n, sev, seed):
    g2 = torch.Generator().manual_seed(seed); rng = np.random.default_rng(seed)
    ok = 0
    for i in range(n):
        pid, sec = int(rng.integers(0, 1 << 24)), int(rng.integers(0, 1 << 32))
        b = torch.tensor(spec.cell_signs(pid, sec), dtype=torch.float32)[None]
        x, _, _, _, _ = render.batch_v11(1, g2, severity=sev, bits=b)
        with torch.no_grad(): d = net(model.with_radius(x))[0, 0].numpy()
        p, _, _ = decode.decode_ls(d)
        ok += int(p == (pid, sec))
    return ok / n
for sev in (0.5, 1.0):
    print(f'e2e sev {sev}: {e2e(60, sev, 99 + int(sev * 10)):.2%}', flush=True)
