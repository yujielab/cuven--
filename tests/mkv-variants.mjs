// 由一个正常的 MKV 派生几种「不规范」的视频轨，测 Worker 的参数集重建与 Annex B 处理：
//   node mkv-variants.mjs <in.mkv> <输出前缀>
// HEVC / H.264（4 字节长度前缀）：
//   <前缀>_inband.mkv  配置盒（hvcC / avcC）里的参数集个数改成 0 —— 参数集只在码流里
//   <前缀>_nopriv.mkv  CodecPrivate 整个换成同样大小的 Void 元素 —— 连配置盒都没有
//   <前缀>_annexb.mkv  帧里每个 4 字节长度前缀原地换成起始码 00 00 00 01 —— Annex B 帧
// AV1：
//   <前缀>_nopriv.mkv  CodecPrivate（av1C）与 Colour 都换成 Void —— 配置与色彩只能从序列头 OBU 里来
// 都是原地改字节，文件大小、簇位置、Cues 一概不变。
import fs from 'node:fs';

const [inp, prefix] = process.argv.slice(2);
if (!inp || !prefix) { console.error('用法：node mkv-variants.mjs <in.mkv> <输出前缀>'); process.exit(2); }
const src = new Uint8Array(fs.readFileSync(inp));

/** EBML 变长整数 → [值, 字节数]（大小字段；全 1 = 未知大小） */
function vint(u8, p) {
  const b = u8[p];
  let len = 1, mask = 0x80;
  while (len <= 8 && !(b & mask)) { len++; mask >>= 1; }
  let v = b & (mask - 1), all1 = v === mask - 1;
  for (let i = 1; i < len; i++) { v = v * 256 + u8[p + i]; if (u8[p + i] !== 255) all1 = false; }
  return [all1 ? Infinity : v, len];
}
/** 元素 ID（保留标记位）→ [ID, 字节数] */
function eid(u8, p) {
  const [, len] = vint(u8, p);
  let v = 0;
  for (let i = 0; i < len; i++) v = v * 256 + u8[p + i];
  return [v, len];
}
function* children(u8, a, b) {
  let p = a;
  while (p < b) {
    const [id, il] = eid(u8, p);
    const [size, sl] = vint(u8, p + il);
    const data = p + il + sl;
    const end = size === Infinity ? b : Math.min(b, data + size);
    yield { id, start: p, idLen: il, sizeLen: sl, data, size: end - data, end };
    p = end;
  }
}
const ID = { Segment: 0x18538067, Tracks: 0x1654AE6B, TrackEntry: 0xAE, TrackNumber: 0xD7, TrackType: 0x83,
  CodecID: 0x86, CodecPrivate: 0x63A2, Video: 0xE0, Colour: 0x55B0,
  Cluster: 0x1F43B675, SimpleBlock: 0xA3, BlockGroup: 0xA0, Block: 0xA1 };
const uint = (u8, a, b) => { let v = 0; for (let i = a; i < b; i++) v = v * 256 + u8[i]; return v; };

// 视频轨：编号、编码、CodecPrivate 位置
let seg = null, video = null;
for (const el of children(src, 0, src.length)) if (el.id === ID.Segment) seg = el;
for (const el of children(src, seg.data, seg.end)) {
  if (el.id !== ID.Tracks) continue;
  for (const te of children(src, el.data, el.end)) {
    if (te.id !== ID.TrackEntry) continue;
    const t = {};
    for (const f of children(src, te.data, te.end)) {
      if (f.id === ID.TrackNumber) t.num = uint(src, f.data, f.end);
      else if (f.id === ID.TrackType) t.type = uint(src, f.data, f.end);
      else if (f.id === ID.CodecID) t.codec = new TextDecoder().decode(src.subarray(f.data, f.end));
      else if (f.id === ID.CodecPrivate) t.priv = f;
      else if (f.id === ID.Video) for (const g of children(src, f.data, f.end)) if (g.id === ID.Colour) t.colour = g;
    }
    if (t.type === 1 && !video) video = t;
  }
}
if (!video || !video.priv) throw new Error('找不到带 CodecPrivate 的视频轨');
const hevc = video.codec === 'V_MPEGH/ISO/HEVC', av1 = video.codec === 'V_AV1';
if (!hevc && !av1 && video.codec !== 'V_MPEG4/ISO/AVC') throw new Error('只支持 HEVC / H.264 / AV1：' + video.codec);
const pv = video.priv;

/** 一个元素原地换成同样长的 Void（ID 字节数不同时，差额由大小字段补上） */
function toVoid(cp, el) {
  const n = el.idLen + el.sizeLen - 1;                            // 新大小字段的字节数
  if (n < 1 || n > 8) throw new Error('元素头部长度异常');
  cp[el.start] = 0xEC;
  let v = el.size;
  for (let i = n - 1; i >= 0; i--) { cp[el.start + 1 + i] = v & 255; v = Math.floor(v / 256); }
  cp[el.start + 1] |= 0x80 >> (n - 1);
}

if (av1) {
  const cp = src.slice();
  toVoid(cp, pv);
  if (video.colour) toVoid(cp, video.colour);
  fs.writeFileSync(`${prefix}_nopriv.mkv`, cp);
  console.log(`${prefix}: AV1，去掉了 av1C${video.colour ? ' 与 Colour' : ''}`);
  process.exit(0);
}

// ① 参数集只在码流里
{
  const cp = src.slice();
  if (hevc) cp[pv.data + 22] = 0;                                  // numOfArrays = 0
  else {
    if (cp[pv.data + 6] !== 0) throw new Error('SPS 太长：改不成「0 个 SPS、0 个 PPS」');
    cp[pv.data + 5] = 0xE0;                                         // numOfSequenceParameterSets = 0（下一字节 0 = 0 个 PPS）
  }
  fs.writeFileSync(`${prefix}_inband.mkv`, cp);
}
// ② 没有 CodecPrivate：整个元素换成同样长的 Void
{
  const cp = src.slice();
  toVoid(cp, pv);
  fs.writeFileSync(`${prefix}_nopriv.mkv`, cp);
}
// ③ Annex B 帧：每个 4 字节长度前缀 → 00 00 00 01
{
  const cp = src.slice();
  let frames = 0;
  const frame = (a, b) => {
    let p = a;
    while (p + 4 <= b) {
      const len = uint(cp, p, p + 4);
      if (len < 1 || p + 4 + len > b) throw new Error('帧里的 NAL 长度对不上（不是 4 字节前缀？）');
      cp[p] = 0; cp[p + 1] = 0; cp[p + 2] = 0; cp[p + 3] = 1;
      p += 4 + len;
    }
    frames++;
  };
  const block = (a, b) => {
    const [num, nl] = vint(cp, a);
    if (num !== video.num) return;
    const flags = cp[a + nl + 2];
    if (flags & 0x06) throw new Error('视频块用了 lacing');
    frame(a + nl + 3, b);
  };
  for (const cl of children(cp, seg.data, seg.end)) {
    if (cl.id !== ID.Cluster) continue;
    for (const el of children(cp, cl.data, cl.end)) {
      if (el.id === ID.SimpleBlock) block(el.data, el.end);
      else if (el.id === ID.BlockGroup) for (const g of children(cp, el.data, el.end)) if (g.id === ID.Block) block(g.data, g.end);
    }
  }
  fs.writeFileSync(`${prefix}_annexb.mkv`, cp);
  console.log(`${prefix}: ${hevc ? 'HEVC' : 'H.264'}，${frames} 帧`);
}
