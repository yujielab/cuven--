"""导出 JS / Swift 共用的规范（cpc1-spec.json）和对照用例（cpc1-vectors.json）"""
import json, numpy as np
import spec, render

S = {
    'version': spec.VERSION,
    'cells': [[round(float(r), 6), round(float(p), 6), round(float(st), 6)] for r, p, st in spec.CELLS],
    'sigmaR': spec.SIGMA_R,
    'pilotIdx': spec.PILOT_IDX.tolist(), 'pilots': spec.PILOTS.astype(int).tolist(),
    'dataIdx': spec.DATA_IDX.tolist(), 'interleave': spec.INTERLEAVE.tolist(),
    'warp': [list(w) for w in spec.WARP],
    'alpha': spec.ALPHA, 'tau': spec.TAU, 'beta': spec.BETA, 'w': spec.W, 'e0': spec.E0,
    # 显示：码的调制网格（边长、8 位纹理里存 M / codeScale）、码平面每秒转的弧度
    'codeGrid': spec.CODE_GRID, 'codeScale': spec.CODE_SCALE, 'codeSpin': spec.CODE_SPIN,
    'conv': {'k': spec.K, 'g1': spec.G1, 'g2': spec.G2},
    'decode': {'cam': render.CAM, 'pr': render.PR, 'pa': render.PA, 'rLo': render.R_LO, 'rHi': render.R_HI,
               'th': render.TH, 'kRms': round(render.K_RMS, 6), 'targetScale': 0.35,
               # v1.1 的框：背景分位、减底余量、射线（条数、每条点数、起止）、半高处 / 真半径；最小二乘解卷的正则
               'bgQ': 0.2, 'bgMargin': 0.04, 'rays': render.N_RAYS, 'rayN': render.RAY_N, 'rayT0': render.RAY_T0, 'rayT1': render.RAY_T1,
               'edgeK': round(render.EDGE_K, 6), 'lsReg': 1e-3,
               # 扫描端：最近几帧的极坐标图取平均再进网络
               'avgFrames': render.AVG_FRAMES},
}
json.dump(S, open('../model/cpc1-spec.json', 'w'), separators=(',', ':'))

rng = np.random.default_rng(5)
vec = []
for _ in range(4):
    pid, sec = int(rng.integers(0, 1 << 24)), int(rng.integers(0, 1 << 32))
    b = spec.cell_signs(pid, sec)
    pts = rng.uniform(-1.2, 1.2, (12, 2))
    D, E = spec.field(b, pts[:, 0], pts[:, 1], coverage=True)
    m = spec.modulation(D, E)
    vec.append({'id': pid, 'secret': sec, 'signs': b.astype(int).tolist(),
                'pts': pts.round(6).tolist(), 'D': D.round(6).tolist(), 'm': m.round(6).tolist()})
json.dump(vec, open('../model/cpc1-vectors.json', 'w'), separators=(',', ':'))
print('spec', len(json.dumps(S)), 'bytes; vectors', len(vec))
