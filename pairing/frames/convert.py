"""渲染好的帧（码关掉）→ look-frames.npz：覆盖度 c = (1 − R) / 0.89（粒子的红色分量平均约 0.11）、每单位覆盖度的蓝色程度 k = (B − R) / c
python3 convert.py <帧目录> [半径像素，默认 120] [画布边长，默认 400]"""
import sys, glob, numpy as np
from PIL import Image
fs = sorted(glob.glob(sys.argv[1].rstrip('/') + '/*.png'))
rad = float(sys.argv[2]) if len(sys.argv) > 2 else 120.0; size = int(sys.argv[3]) if len(sys.argv) > 3 else 400
cov = np.zeros((len(fs), size, size), np.uint8); kk = np.zeros((len(fs), size, size), np.uint8)
for i, f in enumerate(fs):
    a = np.asarray(Image.open(f).convert('RGB')).astype(np.float32) / 255
    r, b = a[..., 0], a[..., 2]
    c = np.clip((1 - r) / 0.89, 0, 0.995)
    k = np.where(c > 0.02, np.clip((b - r) / np.maximum(c, 1e-3), 0, 1), 0.55)
    cov[i] = np.round(c * 255); kk[i] = np.round(k * 255)
np.savez_compressed('look-frames.npz', cov=cov, k=kk, radius_px=rad, size=size)
print(len(fs), 'frames → look-frames.npz')
