"""解码网络：极坐标图（24 × 192，角向首尾相接）→ 每个点的 D 软正负。
只有 3×3 空洞卷积 + ReLU，没有 BN —— iOS 上用 Metal 手写的计算着色器逐层跑，网页（以后要扫描时）用 WebGL 同一套。"""
import torch, torch.nn as nn, torch.nn.functional as F
import json, struct

LAYERS = [  # (输入通道, 输出通道, 径向空洞, 角向空洞)
    (2, 24, 1, 1),
    (24, 24, 1, 2),
    (24, 24, 2, 4),
    (24, 24, 2, 8),
    (24, 24, 4, 16),
    (24, 24, 1, 2),
    (24, 24, 1, 1),
]

class CircConv(nn.Module):
    def __init__(self, cin, cout, dr, da):
        super().__init__()
        self.dr, self.da = dr, da
        self.conv = nn.Conv2d(cin, cout, 3, dilation=(dr, da))
    def forward(self, x):
        x = F.pad(x, (self.da, self.da, 0, 0), mode='circular')       # 角向首尾相接
        x = F.pad(x, (0, 0, self.dr, self.dr))                          # 径向补 0
        return self.conv(x)

class Net(nn.Module):
    def __init__(self):
        super().__init__()
        self.body = nn.ModuleList([CircConv(*l) for l in LAYERS])
        self.head = nn.Conv2d(LAYERS[-1][1], 1, 1)
    def forward(self, x):
        for m in self.body: x = F.relu(m(x))
        return torch.tanh(self.head(x))

def with_radius(x):
    """第二个输入通道：这一行的半径（0–1），让网络知道自己在第几圈"""
    B, _, H, W = x.shape
    r = torch.linspace(0, 1, H).view(1, 1, H, 1).expand(B, 1, H, W)
    return torch.cat([x, r], 1)

def export(net, path_json, path_bin):
    """权重导出：float32 小端，按层顺序 [weight(cout, cin, 3, 3), bias(cout)]…，最后 head"""
    meta = {'version': 1, 'input': [2, 24, 192], 'layers': [], 'head': {}}
    blob = bytearray()
    for (cin, cout, dr, da), m in zip(LAYERS, net.body):
        w = m.conv.weight.detach().float().contiguous().view(-1).tolist(); b = m.conv.bias.detach().float().tolist()
        meta['layers'].append({'cin': cin, 'cout': cout, 'dr': dr, 'da': da, 'offset': len(blob) // 4})
        blob += struct.pack('<%df' % len(w), *w) + struct.pack('<%df' % len(b), *b)
    w = net.head.weight.detach().float().view(-1).tolist(); b = net.head.bias.detach().float().tolist()
    meta['head'] = {'cin': LAYERS[-1][1], 'offset': len(blob) // 4}
    blob += struct.pack('<%df' % len(w), *w) + struct.pack('<%df' % len(b), *b)
    meta['floats'] = len(blob) // 4
    open(path_bin, 'wb').write(blob); json.dump(meta, open(path_json, 'w'), indent=1)
