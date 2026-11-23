"""评估：python3 eval.py [模型 .pt] [每档个数] [浏览器渲染的帧目录 …]

  · 合成相机画面的端到端解码率（单帧 / 平均 AVG_FRAMES 帧）
  · 浏览器里真渲染出来的带码粒子云（pairing/frames/render.mjs 渲染、文件夹名 <编号>-<密钥>）：
    每帧当成一张正对的相机画面，滑动地取最近 AVG_FRAMES 帧平均（和扫描端一样），看能不能解出来
"""
import os, sys, glob, numpy as np, torch
from PIL import Image
import spec, render, model, decode

torch.set_num_threads(4)
net = model.Net(); net.load_state_dict(torch.load(sys.argv[1] if len(sys.argv) > 1 else '../model/cpc1.pt')); net.eval()

def polar_of(ink):
    """ink：CAM × CAM（0–1）→ 归一过的极坐标图（1 × 1 × PR × PA）"""
    t = torch.tensor(ink, dtype=torch.float32)[None, None]
    c, M = render.frame(t)
    pol, _, _ = render.polar_sample_m(t, c, M)
    return render.normalize(pol)

def decode_polar(x):
    with torch.no_grad(): d = net(model.with_radius(x))[0, 0].numpy()
    return decode.decode_ls(d)[0]

def e2e(n, sev, seed, nf):
    g = torch.Generator().manual_seed(seed); rng = np.random.default_rng(seed); ok = 0
    for _ in range(n):
        pid, sec = int(rng.integers(0, 1 << 24)), int(rng.integers(0, 1 << 32))
        b = torch.tensor(spec.cell_signs(pid, sec), dtype=torch.float32)[None]
        x, _, _, _, _ = render.batch(1, g, severity=sev, bits=b, nframes=nf)
        ok += int(decode_polar(x) == (pid, sec))
    return ok / n

def shot_ink(path):
    """截图 → 蓝色程度（B − R），裁正中间的正方形、按块平均缩成 CAM × CAM（和扫描端 GPU 上一样）"""
    im = np.asarray(Image.open(path).convert('RGB')).astype(np.float32) / 255
    h, w, _ = im.shape; s = min(h, w)
    im = im[(h - s) // 2:(h - s) // 2 + s, (w - s) // 2:(w - s) // 2 + s]
    ink = np.clip((im[..., 2] - im[..., 0]) * 1.6, 0, 1)
    return np.asarray(Image.fromarray(ink.astype(np.float32), 'F').resize((render.CAM, render.CAM), Image.BOX))

def run_rendered(folder):
    pid, sec = (int(v) for v in os.path.basename(folder.rstrip('/')).split('-')[:2])
    pols = [polar_of(shot_ink(f)) for f in sorted(glob.glob(os.path.join(folder, '*.png')))]
    single = sum(decode_polar(p) == (pid, sec) for p in pols)
    K = render.AVG_FRAMES
    wins = [torch.stack(pols[i:i + K]).mean(0) for i in range(0, len(pols) - K + 1)]
    multi = sum(decode_polar(w) == (pid, sec) for w in wins)
    return single, len(pols), multi, len(wins)

if __name__ == '__main__':
    n = int(sys.argv[2]) if len(sys.argv) > 2 else 40
    for sev in (0.5, 0.75, 1.0):
        print(f'合成相机画面 sev {sev}: 1 帧 {e2e(n, sev, 7 + int(sev * 10), 1):.0%} / '
              f'{render.AVG_FRAMES} 帧平均 {e2e(n, sev, 7 + int(sev * 10), render.AVG_FRAMES):.0%}', flush=True)
    for folder in sys.argv[3:]:
        s, ns, m, nm = run_rendered(folder)
        print(f'浏览器渲染 {os.path.basename(folder.rstrip("/"))}: 单帧 {s}/{ns}，{render.AVG_FRAMES} 帧平均 {m}/{nm}', flush=True)
