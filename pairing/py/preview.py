"""渲染一帧「用户看到的」粒子云（白底蓝点），对照 Apple 的样子调参用"""
import numpy as np, sys
import spec
from PIL import Image

def render(pair_id, secret, n=70000, size=700, seed=0, dark=False):
    rng = np.random.default_rng(seed)
    b = spec.cell_signs(pair_id, secret)
    G = 400; ext = 1.7
    xs = np.linspace(-ext, ext, G)
    X, Y = np.meshgrid(xs, xs)
    R = np.hypot(X, Y)
    D, E = spec.field(b, X, Y, coverage=True)
    rho = spec.density(D, E, R)
    p = (rho / rho.sum()).ravel()
    idx = rng.choice(p.size, size=n, p=p)
    px = (idx % G + rng.random(n)) / G * size
    py = (idx // G + rng.random(n)) / G * size
    depth = rng.random(n)
    img = np.zeros((size, size), np.float32)
    np.add.at(img, (py.astype(int).clip(0, size - 1), px.astype(int).clip(0, size - 1)), 0.35 + 0.65 * depth)
    # 粒子是 1–2 像素的小点：轻微模糊一下
    k = np.array([0.25, 0.5, 0.25])
    img = np.apply_along_axis(lambda v: np.convolve(v, k, 'same'), 0, img)
    img = np.apply_along_axis(lambda v: np.convolve(v, k, 'same'), 1, img)
    ink = 1 - np.exp(-1.6 * img)
    light = np.array([120, 190, 245], np.float32) / 255
    deep = np.array([30, 110, 230], np.float32) / 255
    col = light[None, None] + (deep - light)[None, None] * np.clip(ink * 1.4 - 0.2, 0, 1)[..., None]
    if dark:
        rgb = ink[..., None] * col * 1.3
    else:
        rgb = 1 - ink[..., None] * (1 - col)
    return Image.fromarray((np.clip(rgb, 0, 1) * 255).astype(np.uint8))

if __name__ == '__main__':
    a = render(0x123456, 0x89ABCDEF, seed=1)
    b = render(0x654321, 0x0F0F0F0F, seed=2)
    c = render(0x123456, 0x89ABCDEF, seed=3, dark=True)
    W = Image.new('RGB', (2100, 700), 'white'); W.paste(a, (0, 0)); W.paste(b, (700, 0)); W.paste(c, (1400, 0))
    W.save(sys.argv[1] if len(sys.argv) > 1 else 'preview.png')
