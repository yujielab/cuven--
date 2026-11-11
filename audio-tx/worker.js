/**
 * cuven audio-tx —— DTS / TrueHD / Opus / Vorbis / MP2 / MP3 / PCM → AC-3 转码 Worker
 * ────────────────────────────────────────────────────────────────
 * 主 Worker（Stream_v25.js）通过 Service Binding `AUDIO_TX`、或者公网地址（变量 `AUDIO_TX_URL`，
 * 本 Worker 挂自定义域名）调用它，把一个 HLS 分段
 * 所需的源音频帧发过来，这里在 WASM（精简 libavcodec + libswresample）里解码、
 * 对齐到全局 AC-3 帧网格、编码，回传 AC-3 帧。
 *
 * 分段之间无缝的关键：
 *   · 输出帧 n 覆盖采样 [anchor + n·1536, anchor + (n+1)·1536)，与哪个请求生成无关
 *   · AC-3 编码器固有 256 采样延迟 → 从网格起点 G 之前 1280 采样开始喂 PCM，
 *     丢掉第一帧（预热），之后每帧都恰好落在网格上，且 MDCT 重叠区用的是真实采样
 *   · 主 Worker 会多读一段越过分段边界的音频，保证本段最后一帧的重叠区同样真实
 *
 * 请求：POST，正文 = u32(头长度) | 头 JSON | 各帧负载首尾相接
 *   头 = { kind, rate, ch, bits, extra(b64|null), outCh, bitrate, s0, frames, aus:[[t, key, size]...] }
 *   t 为该帧起点（输出采样率下的采样序号，已吸附到源帧网格）
 * 响应：u32(帧数) | u32 × 帧数（各帧字节数） | AC-3 帧首尾相接
 */
import wasm from './tx.wasm';

let inst = null;
function instance() {
  if (inst) return inst;
  let mem = null;
  const view = () => new DataView(mem.buffer);
  // 只有 libc 的少量 WASI 依赖：日志已静音，时钟 / 环境变量给最小实现即可
  const wasi = {
    fd_write: (fd, iovs, n, nw) => { const v = view(); let t = 0; for (let i = 0; i < n; i++) t += v.getUint32(iovs + i * 8 + 4, true); v.setUint32(nw, t, true); return 0; },
    fd_close: () => 0, fd_seek: () => 0, fd_read: () => 0, fd_fdstat_get: () => 0,
    environ_sizes_get: (c, s) => { view().setUint32(c, 0, true); view().setUint32(s, 0, true); return 0; },
    environ_get: () => 0,
    clock_time_get: (id, prec, out) => { view().setBigUint64(out, BigInt(Date.now()) * 1000000n, true); return 0; },
    proc_exit: code => { throw new Error(`wasm exit ${code}`); },
  };
  const imports = { wasi_snapshot_preview1: new Proxy(wasi, { get: (o, k) => o[k] || (() => 0) }) };
  const env = new Proxy({}, { get: () => () => 0 });
  const i = new WebAssembly.Instance(wasm, { ...imports, env });
  mem = i.exports.memory;
  if (i.exports._initialize) i.exports._initialize();
  inst = i.exports;
  return inst;
}

function b64(s) { const b = atob(s); const u = new Uint8Array(b.length); for (let i = 0; i < b.length; i++) u[i] = b.charCodeAt(i); return u; }

export function transcode(X, h, data) {
  const heap = () => new Uint8Array(X.memory.buffer);
  const put = u8 => { const p = X.tx_alloc(Math.max(1, u8.length)); heap().set(u8, p); return p; };
  const extra = h.extra ? b64(h.extra) : null;
  const ep = extra ? put(extra) : 0;
  const tx = X.tx_open(h.kind, h.rate, h.ch, h.bits || 0, ep, extra ? extra.length : 0, h.outCh, h.bitrate);
  if (ep) X.tx_dealloc(ep);
  if (!tx) throw new Error('decoder/encoder init failed');
  const FS = X.tx_frame_size(tx);
  const need = h.frames + 1;                 // +1 = 预热帧（丢弃）
  const target = h.s0 - 1280;                // 编码器 256 延迟 + 一整帧预热
  let started = false, skipLeft = 0, made = 0, off = 0;
  const buf = X.tx_alloc(65536);
  let cap = 65536, bp = buf;
  try {
    for (const [t, key, size] of h.aus) {
      const au = data.subarray(off, off + size);
      off += size;
      if (made >= need) break;
      // TrueHD / MLP 只能从 major sync（MKV 关键帧）开始解
      if (!started && (h.kind === 2 || h.kind === 3) && !key) continue;
      if (size > cap) { X.tx_dealloc(bp); cap = size + 4096; bp = X.tx_alloc(cap); }
      heap().set(au, bp);
      const n = X.tx_decode(tx, bp, size);
      if (n < 0) throw new Error('decode failed');
      if (!started) {
        if (n === 0) continue;
        started = true;
        const d = target - t;                // 正：先丢掉多出来的采样；负：前面补静音
        if (d < 0) X.tx_pad(tx, -d); else skipLeft = d;
      }
      if (skipLeft) skipLeft -= X.tx_skip(tx, skipLeft);
      if (!skipLeft) made += X.tx_encode(tx, need - made);
    }
    if (made < need) {
      // 一帧都没解出来（坏数据）或源音频提前结束（片尾）：队尾补静音把帧凑齐，时间轴不断
      if (skipLeft) { X.tx_skip(tx, skipLeft); skipLeft = 0; }
      X.tx_tail(tx, Math.max(0, (need - made) * FS - X.tx_pcm_len(tx)));
      made += X.tx_encode(tx, need - made);
    }
    const nf = X.tx_nframes(tx);
    const sizes = new Uint32Array(X.memory.buffer, X.tx_sizes(tx), nf).slice();
    const out = heap().slice(X.tx_out(tx), X.tx_out(tx) + X.tx_out_len(tx));
    // 丢掉预热帧
    const first = nf > 0 ? sizes[0] : 0;
    const keep = sizes.slice(1, 1 + h.frames);
    const body = new Uint8Array(4 + keep.length * 4 + keep.reduce((a, b) => a + b, 0));
    const dv = new DataView(body.buffer);
    dv.setUint32(0, keep.length);
    keep.forEach((s, i) => dv.setUint32(4 + i * 4, s));
    body.set(out.subarray(first, first + keep.reduce((a, b) => a + b, 0)), 4 + keep.length * 4);
    return { body, errors: X.tx_errors(tx) };
  } finally {
    X.tx_dealloc(bp);
    X.tx_close(tx);
  }
}

/* 公网地址调用时的共享密钥：配了 AUDIO_TX_KEY（Secret），请求头 X-Audio-Tx-Key 必须是同一个值，否则 401 ——
   挂在自定义域名上谁都能访问，不设密钥等于把转码 CPU 白送给外人。走 Service Binding 时可以不设 */
function keyOk(request, env) {
  const want = env && env.AUDIO_TX_KEY ? String(env.AUDIO_TX_KEY) : '';
  if (!want) return true;
  const got = request.headers.get('X-Audio-Tx-Key') || '';
  if (got.length !== want.length) return false;
  let d = 0;
  for (let i = 0; i < want.length; i++) d |= got.charCodeAt(i) ^ want.charCodeAt(i);
  return d === 0;
}

export default {
  async fetch(request, env) {
    if (!keyOk(request, env)) return new Response('unauthorized', { status: 401 });
    // GET：健康检查。告诉主 Worker 这边有没有在校验密钥（它据此在 /health 上提示）
    if (request.method !== 'POST') return new Response(`cuven audio-tx; key=${env && env.AUDIO_TX_KEY ? 'on' : 'off'}`, { status: 200 });
    const buf = new Uint8Array(await request.arrayBuffer());
    const hl = new DataView(buf.buffer, buf.byteOffset).getUint32(0);
    const h = JSON.parse(new TextDecoder().decode(buf.subarray(4, 4 + hl)));
    try {
      const { body, errors } = transcode(instance(), h, buf.subarray(4 + hl));
      return new Response(body, { headers: { 'Content-Type': 'application/octet-stream', 'X-TX-Errors': String(errors) } });
    } catch (e) {
      inst = null;                            // 实例状态可能已损坏：下次重建
      return new Response(String(e && e.message || e), { status: 500 });
    }
  },
};
