"""评估：python3 eval.py [模型 .pt] —— 合成相机画面的端到端解码率，以及截图（网页 / iOS 自检）能不能解出来"""
import sys, glob, json, numpy as np, torch
from PIL import Image
import spec, render, model, decode

torch.set_num_threads(2)
net = model.Net(); net.load_state_dict(torch.load(sys.argv[1] if len(sys.argv) > 1 else '../model/cpc1.pt')); net.eval()

def run_ink(ink):
    """ink：CAM × CAM（0–1）→ 解码结果、导频分"""
    t = torch.tensor(ink, dtype=torch.float32)[None, None]
    c, M = render.frame(t)
    pol, _, _ = render.polar_sample_m(t, c, M)
    with torch.no_grad(): d = net(model.with_radius(render.normalize(pol)))[0, 0].numpy()
    p, s, S = decode.decode(d)
    return p

def e2e(n, sev, seed):
    g = torch.Generator().manual_seed(seed); rng = np.random.default_rng(seed); ok = 0
    for _ in range(n):
        pid, sec = int(rng.integers(0, 1 << 24)), int(rng.integers(0, 1 << 32))
        b = torch.tensor(spec.cell_signs(pid, sec), dtype=torch.float32)[None]
        x, _, _, _, _ = render.batch_v11(1, g, severity=sev, bits=b)
        with torch.no_grad(): d = net(model.with_radius(x))[0, 0].numpy()
        ok += int(decode.decode(d)[0] == (pid, sec))
    return ok / n

def shot_ink(path):
    im = np.asarray(Image.open(path).convert('RGB')).astype(np.float32) / 255
    h, w, _ = im.shape; s = min(h, w)
    im = im[(h - s) // 2:(h - s) // 2 + s, (w - s) // 2:(w - s) // 2 + s]
    ink = np.clip((im[..., 2] - im[..., 0]) * 1.6, 0, 1)
    return np.asarray(Image.fromarray((ink * 255).astype(np.uint8)).resize((render.CAM, render.CAM), Image.BILINEAR)).astype(np.float32) / 255

if __name__ == '__main__':
    for sev in (0.5, 1.0):
        print(f'合成相机画面 sev {sev}: {e2e(int(sys.argv[2]) if len(sys.argv) > 2 else 40, sev, 7 + int(sev * 10)):.0%}', flush=True)
    for path in sorted(glob.glob(sys.argv[3] if len(sys.argv) > 3 else '/nonexistent/*.png')):
        print('截图', path.split('/')[-1], '→', run_ink(shot_ink(path)), flush=True)
