// 回归测试：node tests/run.mjs（先跑一次 tests/make-samples.sh 生成样片）
import fs from 'node:fs';
import crypto from 'node:crypto';
import path from 'node:path';
import http from 'node:http';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import * as H from './harness.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const S = f => path.join(H.SAMPLES, f);
const OUT = path.join(HERE, 'out');
let pass = 0, fail = 0;
const ok = (cond, msg) => { if (cond) { pass++; console.log('  ✓', msg); } else { fail++; console.log('  ✗', msg); } };
const ff = (args, opts = {}) => execFileSync('ffmpeg', ['-v', 'error', ...args], { maxBuffer: 1 << 30, ...opts });
const probe = (file, sel) => JSON.parse(execFileSync('ffprobe', ['-v', 'error', '-select_streams', sel, '-show_packets',
  '-show_data_hash', 'MD5', '-show_entries', 'packet=pts,dts,flags,data_hash:stream=time_base', '-show_streams',
  '-of', 'json', file], { maxBuffer: 1 << 30 }).toString());

/** 源轨与输出轨逐包比对：数据哈希、关键帧、PTS（输出整体 +10s） */
function samePackets(src, ssel, out, osel, label, ptsTol = 0.001) {
  const a = probe(src, ssel), b = probe(out, osel);
  const ta = eval(a.streams[0].time_base), tb = eval(b.streams[0].time_base);
  const A = a.packets, B = b.packets;
  let hash = 0, keys = 0, worst = 0, mono = true, order = true;
  for (let i = 0; i < Math.min(A.length, B.length); i++) {
    if (A[i].data_hash !== B[i].data_hash) hash++;
    if (A[i].flags[0] !== B[i].flags[0]) keys++;
    worst = Math.max(worst, Math.abs((B[i].pts * tb - 10) - A[i].pts * ta));
    if (i && +B[i].dts <= +B[i - 1].dts) mono = false;
    if (+B[i].dts > +B[i].pts) order = false;
  }
  ok(A.length === B.length && !hash && !keys && worst <= ptsTol && mono && order,
    `${label}: ${B.length}/${A.length} 包，哈希不符 ${hash}，关键帧不符 ${keys}，最大 ΔPTS ${(worst * 1000).toFixed(2)}ms，DTS 单调 ${mono}，DTS≤PTS ${order}`);
}

console.log('\n■ 杜比视界 RPU（dovi_tool 测试向量）');
{
  const X = await H.internals();
  const rd = f => { const d = new Uint8Array(fs.readFileSync(S('dovi/' + f))); return d.subarray(4); };
  const eq = (x, y) => x.length === y.length && x.every((v, i) => v === y[i]);
  for (const f of ['fel_orig.bin', 'mel_orig.bin', 'profile5.bin', 'profile8.bin']) {
    const R = X.dvRpuParse(X.nalUnescape(rd(f)));
    ok(eq(X.nalEscape(X.dvRpuWrite(R)), rd(f)), `${f} 解析→重写逐字节一致（profile ${X.dvRpuProfile(R.H)}）`);
  }
  let R = X.dvRpuParse(X.nalUnescape(rd('mel_orig.bin'))); X.dvRpuTo81(R, true);
  ok(eq(X.nalEscape(X.dvRpuWrite(R)), rd('mel_to_81.bin')), 'MEL → 8.1 与 dovi_tool 输出逐字节一致');
  R = X.dvRpuParse(X.nalUnescape(rd('fel_orig.bin'))); X.dvRpuTo81(R, false);
  ok(eq(X.nalEscape(X.dvRpuWrite(R)), rd('fel_to_81.bin')), 'FEL → 8.1（保留映射）与 dovi_tool 输出逐字节一致');
}

console.log('\n■ 管线提效：杜比视界转换复用、分片出口不再整段拷贝、令牌复核');
{
  const X = await H.internals();
  const rd = f => new Uint8Array(fs.readFileSync(S('dovi/' + f))).subarray(4);
  const nal = f => { const p = rd(f), n = new Uint8Array(p.length + 2); n[0] = 0x7C; n[1] = 0x01; n.set(p, 2); return n; };
  const eq = (x, y) => x.length === y.length && x.every((v, i) => v === y[i]);
  const fel = nal('fel_orig.bin'), mel = nal('mel_orig.bin');
  const a = X.dvRpuMemo(fel), b = X.dvRpuMemo(new Uint8Array(fel)), c = X.dvRpuMemo(mel), d = X.dvRpuMemo(fel);
  ok(a === b && eq(a, X.dvConvertRpuNal(fel)) && eq(c, X.dvConvertRpuNal(mel)) && !eq(a, c) && eq(d, a),
    '杜比视界：相邻帧同一份 RPU 直接复用上一次的转换结果；换了 RPU 就重新转；结果与逐帧转换逐字节一致');
  const big = new Uint8Array(40000).fill(7), mid = new Uint8Array(9000).fill(3);
  const small = [1, 2, 3].map(n => new Uint8Array(500).fill(n));
  const parts = [small[0], big, small[1], small[2], mid, mid, mid, mid, mid, mid, mid, mid, big];
  const ch = X.hlsChunks(parts);
  ok(eq(X.hlsConcat(ch), X.hlsConcat(parts)) && ch.filter(x => x === big).length === 2 && ch.length < parts.length,
    `分片出口：拼回来逐字节一致；≥ 16KB 的切片原样交出（不拷贝），零碎的攒成块（${parts.length} 片 → ${ch.length} 块）`);
}
{
  const f = '/Movies/avc_zsub.mkv';
  const good = H.token(f);
  const r1 = await H.call(`/hls/${good}/master.m3u8`);
  const [e0, s0, p0] = good.split('.');
  const forged = `${e0}.${(s0[0] === 'a' ? 'b' : 'a') + s0.slice(1)}.${p0}`;
  const r2 = await H.call(`/hls/${forged}/master.m3u8`);
  const exp = Math.floor(Date.now() / 1000) - 10;
  const old = `${exp}.${crypto.createHmac('sha256', H.SECRET).update(`${f}|${exp}`).digest('hex')}.${Buffer.from(f).toString('base64url')}`;
  const r3 = await H.call(`/hls/${old}/master.m3u8`);
  const r4 = await H.call(`/hls/${good}/master.m3u8`);
  ok(r1.status === 200 && r4.status === 200 && r2.status === 401 && r3.status === 401,
    `HLS 令牌验过一次就记住：同一个令牌照常放行（${r4.status}）；改了签名的（${r2.status}）、过期的（${r3.status}）照样拒`);
}

console.log('\n■ HEVC HDR10 + 全套音轨 / 字幕');
{
  const r = await H.dump('/Movies/hdr10_multi.mkv', path.join(OUT, 'multi'));
  const o = f => path.join(OUT, 'multi', f);
  ok(/VIDEO-RANGE=PQ/.test(r.master) && /CODECS="hvc1\.2\.4\.L63\.90,ec-3,ac-3,mp4a\.40\.2,fLaC"/.test(r.master), '主列表：PQ、编解码串');
  ok((r.master.match(/TYPE=SUBTITLES/g) || []).length === 4 && (r.master.match(/TYPE=SUBTITLES[^\n]*DEFAULT=YES/g) || []).length === 1,
    '字幕组：2 内封 + 2 外挂，只有一个默认');
  samePackets(S('hdr10_multi.mkv'), 'v:0', o('v.mp4'), 'v:0', 'HEVC 视频');
  samePackets(S('hdr10_multi.mkv'), 'a:0', o('v.mp4'), 'a:0', 'E-AC-3（复用）');
  samePackets(S('hdr10_multi.mkv'), 'a:1', o('a1.mp4'), 'a:0', 'AC-3');
  samePackets(S('hdr10_multi.mkv'), 'a:2', o('a2.mp4'), 'a:0', 'AAC（ffprobe 按 21ms 累加 lacing 时间，容差 2.1ms）', 0.0021);
  samePackets(S('hdr10_multi.mkv'), 'a:3', o('a3.mp4'), 'a:0', 'FLAC');
  const vtt = fs.readdirSync(o('')).filter(f => f.startsWith('s1_')).map(f => fs.readFileSync(o(f), 'utf8')).join('\n');
  ok(vtt.includes('line:8%') && vtt.includes('<i>斜体</i>第三句') && vtt.includes('第二句，逗号, 测试')
    && vtt.includes('X-TIMESTAMP-MAP=MPEGTS:900000'), 'ASS → WebVTT（\\an8 置顶、斜体、正文逗号、时间映射）');
}

console.log('\n■ 杜比视界片源');
for (const [f, re] of [['dv81', /CODECS="hvc1[^"]*",SUPPLEMENTAL-CODECS="dvh1\.08\.03\/db1p"/], ['dv5', /CODECS="dvh1\.05\.03,ec-3"/],
  ['dv7', /CODECS="hvc1[^"]*",SUPPLEMENTAL-CODECS="dvh1\.08\.03\/db1p"/]]) {
  const r = await H.dump(`/Movies/${f}.mkv`, path.join(OUT, f));
  ok(re.test(r.master) && /VIDEO-RANGE=PQ/.test(r.master), `${f}: 信令 ${re.exec(r.master)?.[0]}`);
}
{
  const X = await H.internals();
  const hevc = ff(['-i', path.join(OUT, 'dv7', 'v.mp4'), '-map', '0:v', '-c', 'copy', '-bsf:v', 'hevc_mp4toannexb', '-f', 'hevc', '-']);
  let el = 0, p8 = 0, bad = 0;
  const st = [];
  for (let i = 0; i + 3 < hevc.length; i++) if (hevc[i] === 0 && hevc[i + 1] === 0 && hevc[i + 2] === 1) { st.push(i + 3); i += 2; }
  st.forEach((s, k) => {
    const e = k + 1 < st.length ? st[k + 1] - 3 : hevc.length;
    const t = (hevc[s] >> 1) & 63;
    if (t === 63) el++;
    if (t === 62) { try { if (X.dvRpuProfile(X.dvRpuParse(X.dvRpuPayload(hevc.subarray(s, e))).H) === 8) p8++; else bad++; } catch { bad++; } }
  });
  ok(el === 0 && p8 === 288 && bad === 0, `P7 FEL → 8.1：增强层 NAL 剩 ${el}，profile 8 RPU ${p8}/288，失败 ${bad}`);
}

console.log('\n■ H.264 / AV1 / 字幕 / 异常');
{
  await H.dump('/Movies/avc_zsub.mkv', path.join(OUT, 'avc'));
  samePackets(S('avc_zsub.mkv'), 'v:0', path.join(OUT, 'avc', 'v.mp4'), 'v:0', 'H.264（B 帧金字塔）');
  const z = fs.readdirSync(path.join(OUT, 'avc')).filter(f => f.startsWith('s0_')).map(f => fs.readFileSync(path.join(OUT, 'avc', f), 'utf8')).join('');
  ok(z.includes('中文字幕 第一句'), 'zlib 压缩的内封 ASS 字幕');
  await H.dump('/Movies/av1_hdr.mkv', path.join(OUT, 'av1'));
  samePackets(S('av1_hdr.mkv'), 'v:0', path.join(OUT, 'av1', 'v.mp4'), 'v:0', 'AV1 10bit HDR10');
  const sc = await H.dump('/Movies/subscan.mkv', path.join(OUT, 'scan'));
  const sv = fs.readdirSync(path.join(OUT, 'scan')).filter(f => f.startsWith('s0_')).map(f => fs.readFileSync(path.join(OUT, 'scan', f), 'utf8')).join('');
  ok(sc.playlists.s0 && ['00:00:01.000', '00:00:05.000', '00:00:12.250', '00:00:21.000'].every(t => sv.includes(t)), '字幕没有 Cues 时扫描兜底');
  const nc = await H.call(`/hls/${H.token('/Movies/nocues.mkv')}/master.m3u8`);
  ok(nc.status === 422, `没有 Cues 的文件 → ${nc.status}`);
  const b = `/hls/${H.token('/Movies/hdr10_multi.mkv')}/`;
  ok((await H.call(b.replace(/\.([0-9a-f]{8})/, '.deadbeef') + 'master.m3u8')).status === 401, '错误签名 → 401');
  ok((await H.call(b + 'zzzz/v.m3u8')).status === 410, '过期播放列表 → 410');
  const idh = /\n([^/\n]+)\/v\.m3u8/.exec(await (await H.call(b + 'master.m3u8')).text())[1];
  const seq = [];
  for (let k = 0; k < 6; k++) seq.push(Buffer.from(await (await H.call(`${b}${idh}/v/${k}.m4s`)).arrayBuffer()));
  let same = true;
  for (const k of [4, 1, 5, 0, 3, 2]) if (!Buffer.from(await (await H.call(`${b}${idh}/v/${k}.m4s`)).arrayBuffer()).equals(seq[k])) same = false;
  ok(same, '乱序请求的分段与顺序请求逐字节一致');
}

console.log('\n■ 参数集：只在码流里 / 没有 CodecPrivate / Annex B 帧（HEVC、H.264、AV1）');
{
  const X = await H.internals();
  const box = (buf, type) => { const i = buf.indexOf(Buffer.from(type)); return i < 4 ? null : buf.subarray(i + 4, i - 4 + buf.readUInt32BE(i - 4)); };
  const codecOf = m => (/CODECS="([^",]+)/.exec(m) || [])[1];
  const ref = { hevc: codecOf((await H.dump('/Movies/hevc_rh.mkv', path.join(OUT, 'ps_ref_hevc'))).master),
    avc: codecOf((await H.dump('/Movies/avc_rh.mkv', path.join(OUT, 'ps_ref_avc'))).master) };
  for (const kind of ['hevc', 'avc']) {
    for (const v of ['inband', 'nopriv', 'annexb']) {
      const f = `${kind}_${v}`, dir = path.join(OUT, 'ps_' + f);
      const r = await H.dump(`/Movies/${f}.mkv`, dir);
      const mp4 = path.join(dir, 'v.mp4');
      const cfg = box(fs.readFileSync(mp4), kind === 'hevc' ? 'hvcC' : 'avcC');
      const p = kind === 'hevc' ? X.hevcParseHvcC(cfg) : X.avcParseAvcC(cfg);
      const have = kind === 'hevc' ? [32, 33, 34].every(t => p.nals.some(n => n.type === t)) : p.sps.length > 0 && p.pps.length > 0;
      const what = { inband: '参数集只在码流里', nopriv: '没有 CodecPrivate', annexb: 'Annex B 帧' }[v];
      ok(have && codecOf(r.master) === ref[kind],
        `${kind === 'hevc' ? 'HEVC' : 'H.264'} ${what}：重建的 ${kind === 'hevc' ? 'hvcC' : 'avcC'} 带齐参数集，CODECS 与标准文件一致（${codecOf(r.master)}）`);
      samePackets(S(`${kind}_rh.mkv`), 'v:0', mp4, 'v:0', `${kind === 'hevc' ? 'HEVC' : 'H.264'} ${what}：视频逐包一致${v === 'annexb' ? '（起始码转回长度前缀）' : ''}`);
      let err = '';
      try { ff(['-xerror', '-i', mp4, '-f', 'null', '-'], { stdio: ['ignore', 'ignore', 'pipe'] }); } catch (e) { err = String(e.stderr || e.message).slice(0, 160); }
      ok(!err, `${kind === 'hevc' ? 'HEVC' : 'H.264'} ${what}：ffmpeg 完整解码无错误${err ? '：' + err : ''}`);
    }
  }
  // AV1：没有 av1C、也没有 MKV 的 Colour —— av1C 与 PQ 都从序列头 OBU 里来
  {
    const refM = (await H.dump('/Movies/av1_hdr.mkv', path.join(OUT, 'ps_ref_av1'))).master;
    const r = await H.dump('/Movies/av1_nopriv.mkv', path.join(OUT, 'ps_av1_nopriv'));
    const mp4 = path.join(OUT, 'ps_av1_nopriv', 'v.mp4');
    const c1 = box(fs.readFileSync(mp4), 'av1C');
    ok(c1 && c1[0] === 0x81 && codecOf(r.master) === codecOf(refM) && /VIDEO-RANGE=PQ/.test(r.master),
      `AV1 没有 av1C 也没有 Colour：序列头里重建 av1C（${codecOf(r.master)}），仍判为 PQ（不会被当成 SDR 播得发灰）`);
    samePackets(S('av1_hdr.mkv'), 'v:0', mp4, 'v:0', 'AV1 没有 av1C：视频逐包一致');
  }
  // 凑不齐参数集：说清缺什么，而不是一句「暂不支持」
  const P = X.hlsParamConfig;
  let msg = '';
  try { P('hevc', { priv: null }, { video: [{ data: new Uint8Array([0, 0, 0, 3, 0x26, 0x01, 0xAF]) }] }); } catch (e) { msg = e.message; }
  ok(/缺 VPS \/ SPS \/ PPS/.test(msg), `参数集哪儿都找不到：报出缺了哪几个（${msg}）`);
  // 不支持的编码：说清是什么
  const u = X.hlsUnsupportedVideo;
  const vfw = new Uint8Array(40); vfw.set([0x57, 0x56, 0x43, 0x31], 16);       // 'WVC1'
  ok(/MPEG-2/.test(u({ codecId: 'V_MPEG2' })) && /VC-1/.test(u({ codecId: 'V_MS/VFW/FOURCC', priv: vfw })) && /VP9/.test(u({ codecId: 'V_VP9' })) && /VLC/.test(u({ codecId: 'V_VP9' })),
    '不支持的编码说清是什么（MPEG-2、VC-1、VP9……）和怎么办');
  // MP4 直连：hev1 只有带齐参数集才改名成 hvc1
  const entry = (cc, arrays) => {
    const e = new Uint8Array(200); e.set([...cc].map(c => c.charCodeAt(0)), 0); e[11] = 1;
    const hv = new Uint8Array(23 + arrays.length * 5); hv[22] = arrays.length;
    arrays.forEach((t, i) => hv.set([0x80 | t, 0, 1, 0, 0], 23 + i * 5));
    e.set([0, 0, 0, 8 + hv.length, 0x68, 0x76, 0x63, 0x43], 78); e.set(hv, 86);
    return e;
  };
  const full = entry('hev1', [32, 33, 34]), bare = entry('hev1', []);
  X.patchSafariMp4Buffer(full); X.patchSafariMp4Buffer(bare);
  ok(String.fromCharCode(...full.subarray(0, 4)) === 'hvc1' && String.fromCharCode(...bare.subarray(0, 4)) === 'hev1',
    'MP4 直连：hvcC 带齐参数集的 hev1 改名 hvc1；参数集只在码流里的不改（改了苹果反而拒播）');
}

console.log('\n■ 管线：并行窗口、边缘缓存预取、半路失败不落半截、字幕借道');
{
  const settle = () => Promise.all(H.pending.splice(0));
  const clear = async () => { await settle(); caches.default.m.clear(); };
  const ids = async b => /\n([^/\n]+)\/v\.m3u8/.exec(await (await H.call(b + 'master.m3u8')).text())[1];
  const file = '/Movies/hdr10_multi.mkv', b = `/hls/${H.token(file)}/`;
  const seg = async (idh, k, host) => Buffer.from(await (await H.call(`${b}${idh}/v/${k}.m4s`, 'GET', {}, host)).arrayBuffer());
  const segKeys = k => [...caches.default.m.keys()].filter(x => x.includes('/seg2/') && x.endsWith(`/v/${k}`) === false && x.includes(`/v/${k}/`));
  const fetchedFor = k => H.stats.ranges.filter(r => starts[k].has(r[1])).length;

  // 参照：关掉预取、默认窗口，逐段现取；顺手记下每段回源的起点
  H.env.HLS_PREFETCH = '0';
  await clear();
  const idh = await ids(b);
  await settle();
  const ref = [], starts = [];
  for (let k = 0; k < 5; k++) {
    H.stats.ranges.length = 0;
    ref.push(await seg(idh, k));
    await settle();
    starts.push(new Set(H.stats.ranges.map(r => r[1])));
  }
  let same = true;
  for (const w of ['1', '5']) {
    H.env.HLS_WINDOW = w;
    await clear();
    for (let k = 0; k < 5; k++) if (!(await seg(idh, k)).equals(ref[k])) same = false;
  }
  delete H.env.HLS_WINDOW;
  ok(same, '并行窗口 1 / 3 / 5 产出的分段逐字节一致');
  delete H.env.HLS_PREFETCH;

  // 第 k 段取完 → 后台取第 k+1 段进缓存；随后的第 k+1 段请求从缓存出、不再回源
  await clear();
  await seg(idh, 2);
  await settle();
  H.stats.ranges.length = 0;
  const s3 = await seg(idh, 3);
  await settle();
  ok(s3.equals(ref[3]) && fetchedFor(3) === 0, `第 2 段取完预取第 3 段：第 3 段从缓存出（回源 ${fetchedFor(3)} 次），逐字节一致`);

  // 第 k+1 段请求到达时预取还在半路（上游放慢）：等它写完从缓存出，不重复回源
  await clear();
  H.net.chunkDelayMs = 4;
  H.stats.ranges.length = 0;
  await seg(idh, 0);
  const s1 = await seg(idh, 1);
  await settle();
  H.net.chunkDelayMs = 0;
  ok(s1.equals(ref[1]) && fetchedFor(1) === starts[1].size, `预取半路来的请求：等它写完从缓存出，逐字节一致，回源 ${fetchedFor(1)} 次（= 一遍 ${starts[1].size} 次）`);

  // 回归：预取半路断流 —— 缓存替身照 workerd 的行为把半截落盘，但没有指针指着它，
  // 之后的请求读不到半截，重新现取出完整的一段
  await clear();
  H.env.STREAM_RESUME_MAX = '0';
  const head2 = Math.min(...starts[2]);
  H.net.fail = (f, s) => f === 'hdr10_multi.mkv' && starts[2].has(s) && s !== head2;
  await seg(idh, 1);
  await settle();
  H.net.fail = null;
  delete H.env.STREAM_RESUME_MAX;
  const halves = segKeys(2).map(x => caches.default.m.get(x).body.byteLength);
  const s2 = await seg(idh, 2);
  await settle();
  ok(halves.length > 0 && halves.every(n => n < ref[2].length) && s2.equals(ref[2]),
    `预取半路失败：缓存里留下半截（${halves.join('/')} < ${ref[2].length} 字节）却读不到，第 2 段重新取出完整且逐字节一致`);
  const again = await seg(idh, 3);
  await settle();
  ok(again.equals(ref[3]), '失败之后预取照常：第 3 段逐字节一致');

  // *.workers.dev 上 Cache API 不生效：不预取、不留缓存
  await clear();
  await seg(idh, 1, 'demo.workers.dev');
  await settle();
  ok(![...caches.default.m.keys()].some(x => x.includes('/seg2/')), '*.workers.dev 上不预取、不写分段缓存');

  // 没有字幕 Cues：字幕分段不再把整段视频字节重读一遍
  const f2 = '/Movies/subscan.mkv', b2 = `/hls/${H.token(f2)}/`;
  H.env.HLS_PREFETCH = '0';
  await clear();
  const idh2 = await ids(b2);
  const vref = [];
  for (let k = 0; k < 5; k++) vref.push(await (await H.call(`${b2}${idh2}/s0/${k}.vtt`)).text());
  const v2ref = [];
  for (let k = 0; k < 5; k++) v2ref.push(Buffer.from(await (await H.call(`${b2}${idh2}/v/${k}.m4s`)).arrayBuffer()));
  delete H.env.HLS_PREFETCH;
  await clear();
  await (await H.call(b2 + 'info.json')).text();
  await settle();
  await (await H.call(`${b2}${idh2}/v/1.m4s`)).arrayBuffer();
  H.stats.ranges.length = 0;
  const t1 = await (await H.call(`${b2}${idh2}/s0/1.vtt`)).text();
  ok(t1 === vref[1] && H.stats.ranges.length === 0, `字幕第 1 段：直接用视频那一遍顺手写好的 VTT，回源 ${H.stats.ranges.length} 次，与扫描结果一致`);
  await settle();
  H.stats.ranges.length = 0;
  const t4 = await (await H.call(`${b2}${idh2}/s0/4.vtt`)).text();
  await settle();
  const n4 = H.stats.ranges.length;
  const v4 = Buffer.from(await (await H.call(`${b2}${idh2}/v/4.m4s`)).arrayBuffer());
  await settle();
  ok(t4 === vref[4] && n4 > 0 && H.stats.ranges.length === n4 && v4.equals(v2ref[4]),
    `先要字幕第 4 段：起一路预取取第 4 段（回源 ${n4} 次），随后的视频请求从缓存出（新增 ${H.stats.ranges.length - n4} 次）、逐字节一致`);
  // 同一段的视频与字幕同时到：只读一遍字节，两边都正确
  await clear();
  await (await H.call(b2 + 'info.json')).text();
  await settle();
  H.net.chunkDelayMs = 3;
  H.stats.ranges.length = 0;
  const [v3, t3] = await Promise.all([
    H.call(`${b2}${idh2}/v/3.m4s`).then(r => r.arrayBuffer()).then(x => Buffer.from(x)),
    H.call(`${b2}${idh2}/s0/3.vtt`).then(r => r.text()),
  ]);
  const n3 = H.stats.ranges.length;
  await settle();
  H.net.chunkDelayMs = 0;
  const one = new Set(H.stats.ranges.filter((r, i) => i < n3).map(r => r[1])).size === n3;
  ok(v3.equals(v2ref[3]) && t3 === vref[3] && one, `同一段的视频与字幕同时请求：字幕等视频那一遍，回源 ${n3} 次不重复，两边都正确`);
  let allSame = true;
  for (let k = 0; k < 5; k++) if ((await (await H.call(`${b2}${idh2}/s0/${k}.vtt`)).text()) !== vref[k]) allSame = false;
  ok(allSame, '借道写出的字幕 VTT 与原扫描路径逐字一致（5 段）');
  await clear();
}

console.log('\n■ OpenSubtitles 自动补字幕（模拟接口）');
{
  /* 后台查询是 info.json 的 waitUntil 里再 waitUntil 出来的：等到队列真正清空 */
  const settle = async () => { while (H.pending.length) await Promise.all(H.pending.splice(0)); };
  const clear = async () => { await settle(); caches.default.m.clear(); };
  const calls = p => H.os.calls.filter(c => c.path === p);
  /* OpenSubtitles 的文件哈希（独立实现，用来核对 Worker 算的） */
  const mh = f => {
    const b = fs.readFileSync(S(f));
    let h = BigInt(b.length);
    for (const part of [b.subarray(0, 65536), b.subarray(b.length - 65536)]) for (let i = 0; i < 65536; i += 8) h += part.readBigUInt64LE(i);
    return (h & 0xFFFFFFFFFFFFFFFFn).toString(16).padStart(16, '0');
  };
  const tc = t => { const ms = Math.round(t * 1000); const p = (v, n = 2) => String(v).padStart(n, '0'); return `${p(Math.floor(ms / 3600000))}:${p(Math.floor(ms / 60000) % 60)}:${p(Math.floor(ms / 1000) % 60)},${p(ms % 1000, 3)}`; };
  const srt = (lines, dur) => lines.map((t, i) => { const a = 0.4 + i * (dur - 1) / lines.length; return `${i + 1}\n${tc(a)} --> ${tc(a + 0.5)}\n${t}\n`; }).join('\n');
  const SIMP = Array.from({ length: 12 }, (_, i) => `这是第${i + 1}句简体字幕，我们说话没问题`);
  const TRAD = Array.from({ length: 12 }, (_, i) => `這個問題很簡單，第${i + 1}句繁體字幕說話`);
  const master = async f => (await (await H.call(`/hls/${H.token(f)}/master.m3u8`)).text());
  const info = async f => (await H.call(`/hls/${H.token(f)}/info.json`)).json();
  const subLine = (m, re) => m.split('\n').find(l => l.startsWith('#EXT-X-MEDIA:TYPE=SUBTITLES') && re.test(l)) || '';
  const vtt = async (f, m, k = 0) => { const idh = /\n([^/\n]+)\/v\.m3u8/.exec(m)[1]; return (await H.call(`/hls/${H.token(f)}/${idh}/o0/${k}.vtt`)).text(); };
  const reset = () => { H.os.calls.length = 0; H.os.subs = []; H.os.files = {}; H.os.quota = false; };

  // 没配 Key：一次都不调
  await clear(); reset();
  await info('/Movies/dv81.mkv'); await settle();
  let m = await master('/Movies/dv81.mkv');
  ok(!H.os.calls.length && !/o0\.m3u8/.test(m), '没配 OPENSUBTITLES_API_KEY：不调用接口，主列表也没有在线字幕');

  H.env.OPENSUBTITLES_API_KEY = 'test-key'; H.env.OPENSUBTITLES_USERNAME = 'u'; H.env.OPENSUBTITLES_PASSWORD = 'p';
  // 一条字幕都没有的片子：哈希命中的胜过下载量高的、机翻的；帧率对不上让对方换算
  await clear(); reset();
  const h81 = mh('dv81.mkv');
  H.os.subs = [
    { id: 1, file_id: 1001, language: 'zh-cn', moviehash: h81, fps: 25, release: 'Some.Movie.2024.2160p.UHD.BluRay', downloads: 120 },
    { id: 2, file_id: 1002, language: 'zh-cn', query: 'dv81', release: 'Other.Release.720p', downloads: 90000 },
    { id: 3, file_id: 1003, language: 'zh-cn', moviehash: h81, mt: true, downloads: 500 },
  ];
  H.os.files = { 1001: { text: srt(SIMP, 12) }, 1002: { text: srt(['错的那一份'.repeat(2)], 12) }, 1003: { text: srt(['机翻'], 12) } };
  await info('/Movies/dv81.mkv'); await settle();
  const sc = calls('/subtitles'), dl = calls('/download');
  ok(sc.some(c => c.q.moviehash === h81) && sc.some(c => c.q.query === 'dv81'), `先按文件哈希（${h81}）再按片名搜`);
  const keys = c => c.search.split('&').map(kv => kv.split('=')[0]);
  ok(sc.every(c => keys(c).join() === keys(c).sort().join() && Object.values(c.q).every(v => v === v.toLowerCase())) && sc.every(c => c.q.languages === 'en,ze,zh-cn,zh-tw'),
    `查询参数按名字排好、全小写；一条字幕都没有 → 也要英文兜底（${sc[0] && sc[0].q.languages}）`);
  ok(calls('/login').length === 1 && sc.every(c => c.key === 'test-key' && c.auth === 'Bearer tok-os' && /^CuvenStream v25$/.test(c.ua)), '带 Api-Key / User-Agent，登录一次后带 token');
  ok(dl.length === 1 && dl[0].body.file_id === 1001 && dl[0].body.sub_format === 'srt' && dl[0].body.in_fps === 25 && dl[0].body.out_fps === 23.976,
    `挑中哈希命中的那条（不是下载量 9 万的、也不是机翻的），帧率 25 → 23.976 换算：${JSON.stringify(dl[0] && dl[0].body)}`);
  m = await master('/Movies/dv81.mkv');
  const line = subLine(m, /o0\.m3u8/);
  ok(/LANGUAGE="zh-Hans"/.test(line) && /NAME="简体中文（在线）"/.test(line) && /DEFAULT=YES/.test(line), `主列表多了一条在线简体中文，默认打开：${line.replace(/^#EXT-X-MEDIA:/, '').slice(0, 120)}`);
  const v0 = await vtt('/Movies/dv81.mkv', m, 0);
  ok(/^WEBVTT\nX-TIMESTAMP-MAP=MPEGTS:900000/.test(v0) && v0.includes('这是第1句简体字幕'), '在线字幕分段：带时间映射，内容是下载来的那一份');
  H.os.calls.length = 0;
  await info('/Movies/dv81.mkv'); await master('/Movies/dv81.mkv'); await settle();
  ok(!calls('/subtitles').length && !calls('/download').length, '再开一次：直接用存下的结果，不再搜索、不再花下载配额');

  // 只有英文内封字幕的片子：只要中文；只有繁体 → 逐字转成简体
  await clear(); reset();
  const hsc = mh('subscan.mkv');
  H.os.subs = [
    { id: 10, file_id: 1010, language: 'zh-tw', moviehash: hsc, downloads: 30 },
    { id: 11, file_id: 1011, language: 'en', moviehash: hsc, downloads: 9000 },
  ];
  H.os.files = { 1010: { text: srt(TRAD, 25) } };
  await info('/Movies/subscan.mkv'); await settle();
  ok(calls('/subtitles').every(c => c.q.languages === 'ze,zh-cn,zh-tw'), '已有英文字幕：只找中文');
  m = await master('/Movies/subscan.mkv');
  const v1 = await vtt('/Movies/subscan.mkv', m, 0);
  ok(/NAME="简体中文（在线 · 繁转简）"/.test(subLine(m, /o0/)) && v1.includes('这个问题很简单') && !v1.includes('這個'), `只有繁体：转成简体再给（${(v1.split('\n').find(l => /问题/.test(l)) || '').slice(0, 20)}）`);

  // 找不到：记下来，7 天内不再查
  await clear(); reset();
  await info('/Movies/dv5.mkv'); await settle();
  const n1 = calls('/subtitles').length;
  await info('/Movies/dv5.mkv'); m = await master('/Movies/dv5.mkv'); await settle();
  ok(n1 > 0 && calls('/subtitles').length === n1 && !/o0\.m3u8/.test(m) && !calls('/download').length, `没找到：主列表不加，之后不再重复搜索（搜了 ${n1} 次就停）`);

  // 下载配额用完：不加字幕，过后再查
  await clear(); reset();
  const h7 = mh('dv7.mkv');
  H.os.subs = [{ id: 20, file_id: 1020, language: 'zh-cn', moviehash: h7 }];
  H.os.files = { 1020: { text: srt(SIMP, 12) } };
  H.os.quota = true;
  await info('/Movies/dv7.mkv'); await settle();
  m = await master('/Movies/dv7.mkv');
  ok(calls('/download').length === 1 && !/o0\.m3u8/.test(m), '下载配额用完（406）：这次不加，记下等配额重置后再查');

  // 已经有简体：一次都不查
  await clear(); reset();
  await info('/Movies/hdr10_multi.mkv'); await master('/Movies/hdr10_multi.mkv'); await settle();
  await info('/Movies/avc_zsub.mkv'); await master('/Movies/avc_zsub.mkv'); await settle();
  ok(!H.os.calls.length, '已有简体中文（外挂 zh-Hans / 认作简体的「中文」）：不调用接口');

  // 只标了「中文」、其实是繁体的外挂字幕：算缺简体；主列表里改标繁体，在线简体默认打开
  await clear(); reset();
  fs.writeFileSync(S('av1_hdr.zh.srt'), srt(TRAD, 12));
  const hav = mh('av1_hdr.mkv');
  H.os.subs = [{ id: 30, file_id: 1030, language: 'zh-cn', moviehash: hav, downloads: 10 }];
  H.os.files = { 1030: { text: srt(SIMP, 12) } };
  await info('/Movies/av1_hdr.mkv'); await settle();
  m = await master('/Movies/av1_hdr.mkv');
  const x0 = subLine(m, /x0\.m3u8/), o0 = subLine(m, /o0\.m3u8/);
  ok(/LANGUAGE="zh-Hant"/.test(x0) && /NAME="繁体中文"/.test(x0) && /DEFAULT=NO/.test(x0) && /DEFAULT=YES/.test(o0),
    '「中文」外挂抽样认出是繁体：改标繁体中文，在线简体默认打开');
  fs.unlinkSync(S('av1_hdr.zh.srt'));

  // 直连（MP4）：/api/subs 里多一条在线字幕；GBK 编码的字幕照样正确解码
  await clear(); reset();
  const hmp = mh('avc_raw.mp4');
  const gbk = execFileSync('python3', ['-c', 'import sys; sys.stdout.buffer.write(sys.stdin.read().encode("gbk"))'], { input: srt(SIMP, 20) });
  H.os.subs = [{ id: 40, file_id: 1040, language: 'zh-cn', moviehash: hmp, downloads: 5 }];
  H.os.files = { 1040: { bytes: gbk } };
  /* /api/subs 要登录 Cookie（与前端一样）；字幕直链本身靠签名 */
  const exp = Math.floor(Date.now() / 1000) + 3600;
  const cookie = `auth=${exp}.${crypto.createHmac('sha256', H.SECRET).update(`sess|${exp}`).digest('hex')}`;
  const list = await (await H.call('/api/subs?path=' + encodeURIComponent('/Movies/avc_raw.mp4'), 'GET', { Cookie: cookie })).json();
  const online = (list.subs || []).find(x => x.online);
  ok(online && online.srclang === 'zh-Hans' && /os=1/.test(online.url), `直连：/api/subs 带上在线字幕（${online && online.label}）`);
  const full = online ? await (await H.call(online.url)).text() : '';
  ok(/^WEBVTT/.test(full) && full.includes('这是第1句简体字幕') && (full.match(/-->/g) || []).length === 12, 'GBK 编码的字幕解码正确，整份 VTT 给 <track> 用');

  // ── 在线字幕自动对齐（内封字幕不动，只给在线那条对时间）──
  const parseT = x => { const m = /(\d+):(\d+):(\d+)[,.](\d+)/.exec(x); return +m[1] * 3600 + +m[2] * 60 + +m[3] + +m[4] / 1000; };
  const cuesOf = text => [...text.matchAll(/(\d+:\d+:\d+[,.]\d+)\s*-->\s*(\d+:\d+:\d+[,.]\d+)/g)].map(m => ({ s: parseT(m[1]), e: parseT(m[2]) }));
  const REF = cuesOf(fs.readFileSync(S('sync_en.srt'), 'utf8'));
  const mkSrt = (cues, txt = i => `第${i + 1}句简体中文，我们说话没问题`) => cues.map((c, i) => `${i + 1}\n${tc(c.s)} --> ${tc(c.e)}\n${txt(i)}\n`).join('\n');
  const move = f => REF.map(c => ({ s: f(c.s), e: f(c.e) }));
  /* 直连那份整条 VTT（时间 = 对齐后的）：与参照逐条比，平均差多少秒 */
  const onlineVtt = async f => {
    const lst = await (await H.call('/api/subs?path=' + encodeURIComponent(f), 'GET', { Cookie: cookie })).json();
    const o = (lst.subs || []).find(x => x.online);
    return o ? (await H.call(o.url)).text() : '';
  };
  const err = text => { const c = cuesOf(text); if (c.length !== REF.length) return Infinity; let e = 0; c.forEach((x, i) => { e += Math.abs(x.s - REF[i].s); }); return e / c.length; };
  /* 每个情形用样片的一份拷贝：在线字幕的记录按文件存（进程内 + R2），同一个文件第二次就直接用上次的了 */
  const copies = [];
  const syncCase = async (label, src, cues, extra = {}) => {
    await clear(); reset();
    const f = `sync-${label}.mkv`;
    fs.copyFileSync(S(src), S(f)); copies.push(S(f));
    const hc = mh(f);
    const subs = (extra.subs || []).map(x => x.moviehash === 'SELF' ? { ...x, moviehash: hc } : x);
    H.os.subs = [{ id: 70, file_id: 1070, language: 'zh-cn', query: `sync-${label}`, ...(extra.main || {}), ...(extra.main && extra.main.moviehash === 'SELF' ? { moviehash: hc } : {}) }, ...subs];
    H.os.files = { 1070: { text: mkSrt(cues) }, ...(extra.files || {}) };
    await info('/Movies/' + f); await settle();
    const inf = await info('/Movies/' + f);
    return { sync: inf.online && inf.online.sync, vtt: await onlineVtt('/Movies/' + f), inf, f };
  };
  let r1 = await syncCase('offset', 'sync_ref.mkv', move(t => t + 3.2));
  ok(r1.sync && r1.sync.applied && r1.sync.segs.length === 1 && Math.abs(r1.sync.segs[0].off + 3.2) < 0.03 && /内封/.test(r1.sync.ref) && err(r1.vtt) < 0.03,
    `在线字幕整体晚 3.2 秒：拿内封英文字幕的时间当参照，偏移 ${r1.sync && r1.sync.segs[0].off}s，对齐后与参照平均差 ${err(r1.vtt).toFixed(3)}s（对上 ${r1.sync && r1.sync.before} → ${r1.sync && r1.sync.after}）`);
  const m1 = await master('/Movies/' + r1.f);
  const seg = await vtt('/Movies/' + r1.f, m1, 2);
  const segC = cuesOf(seg);
  ok(segC.length > 0 && segC.every(c => REF.some(x => Math.abs(x.s - c.s) < 0.03)), `HLS 的在线字幕分段也是对齐后的时间（第 2 段 ${segC.length} 条，都落在参照上）`);
  const lst1 = await (await H.call('/api/subs?path=' + encodeURIComponent('/Movies/' + r1.f), 'GET', { Cookie: cookie })).json();
  const u1 = ((lst1.subs || []).find(x => x.online) || {}).url || '';
  ok(/[?&]v=1070\.[0-9a-z]{3,}(&|$)/.test(u1), `直连的字幕链接带着对齐指纹（${(u1.match(/v=[^&]+/) || [''])[0]}）：换了对齐，浏览器不会拿旧时间`);
  r1 = await syncCase('pal', 'sync_ref.mkv', move(t => (t + 1.5) * 23.976 / 25));
  ok(r1.sync && r1.sync.applied && Math.abs(r1.sync.scale - 25 / 23.976) < 1e-4 && err(r1.vtt) < 0.05,
    `给 25 帧（PAL 加速）版本做的：认出速度比 ${r1.sync && r1.sync.scale.toFixed(5)}，越往后偏得越多的那种也拉回来（平均差 ${err(r1.vtt).toFixed(3)}s）`);
  r1 = await syncCase('cut', 'sync_ref.mkv', REF.map(c => c.s < 90 ? c : { s: c.s + 6.5, e: c.e + 6.5 }));
  ok(r1.sync && r1.sync.applied && r1.sync.segs.length === 2 && err(r1.vtt) < 0.05,
    `中途错开一截（后半段晚 6.5 秒：字幕是给中间多一段的版本做的）：切成两段各自对齐（${r1.sync && r1.sync.segs.map(g => g.off + 's').join(' / ')}，平均差 ${err(r1.vtt).toFixed(3)}s）`);
  r1 = await syncCase('in sync', 'sync_ref.mkv', REF.map(c => ({ s: c.s + 0.04, e: c.e - 0.03 })));
  ok(r1.sync && !r1.sync.applied && r1.sync.why === 'in-sync' && err(r1.vtt) < 0.05, '本来就对得上的：原样不动');
  let seedU = 5; const ru = () => ((seedU = (seedU * 1103515245 + 12345) % 2147483648) / 2147483648);
  const unrel = []; for (let x = 2; unrel.length < 90 && x < 170; x += 0.6 + ru() * 2.5) unrel.push({ s: x, e: x + 0.4 + ru() });
  r1 = await syncCase('unrelated', 'sync_ref.mkv', unrel);
  ok(r1.sync && !r1.sync.applied && cuesOf(r1.vtt).length === unrel.length && Math.abs(cuesOf(r1.vtt)[0].s - unrel[0].s) < 0.01,
    `和这部片对不上的（${r1.sync && r1.sync.why}）：不硬对，原样不动`);
  // 没有内封 / 外挂字幕：拿 OpenSubtitles 上同哈希（为这个文件做的）英文字幕当参照
  r1 = await syncCase('hashref', 'sync_nosub.mkv', move(t => t + 2.25), {
    subs: [{ id: 71, file_id: 1071, language: 'en', moviehash: 'SELF', downloads: 10 }], files: { 1071: { text: mkSrt(REF, i => `Line ${i + 1}`) } } });
  ok(r1.sync && r1.sync.applied && /同哈希/.test(r1.sync.ref) && Math.abs(r1.sync.segs[0].off + 2.25) < 0.03 && err(r1.vtt) < 0.03,
    `片子里没有字幕：拿 OpenSubtitles 上与这个文件哈希一致的英文字幕当参照（偏移 ${r1.sync && r1.sync.segs[0].off}s）`);
  ok(calls('/download').length === 2, '为了对齐多花一次下载配额，只在本地没有参照、选中的又不是为这个文件做的时候');
  // 选中的就是为这个文件做的（哈希一致）：不另花配额找参照
  r1 = await syncCase('selfhash', 'sync_nosub.mkv', REF, { main: { moviehash: 'SELF' },
    subs: [{ id: 73, file_id: 1073, language: 'en', moviehash: 'SELF', downloads: 10 }], files: { 1073: { text: mkSrt(REF, i => `Line ${i + 1}`) } } });
  ok(calls('/download').length === 1 && r1.sync === null, '选中的在线字幕本身哈希一致：不再下载参照，也不对齐');
  copies.forEach(f => { try { fs.unlinkSync(f); } catch (_) {} });
  // 图形字幕（PGS）当参照：只有时刻、不分出现消失
  const I = await H.internals();
  const pgsIdx = { scaleNs: 1e6, subs: [], subRefs: [{ lang: 'en', forced: false, t: REF.flatMap(c => [Math.round(c.s * 1000), Math.round(c.e * 1000)]) }] };
  const pref = I.syncRefFromIdx(pgsIdx);
  const pr = pref && I.subSync(move(t => t + 4), pref.cues, { pointsOnly: pref.pointsOnly });
  ok(pref && pref.pointsOnly && pr.applied && Math.abs(pr.segs[0].off + 4) < 0.03, `内封图形字幕（PGS）只有时刻也能当参照（偏移 ${pr && pr.segs[0].off}s）`);
  const both = I.syncRefFromIdx({ scaleNs: 1e6, subs: [{ forced: true, cues: REF.map(c => [c.s * 1000, (c.e - c.s) * 1000, 0, 0]) }], subRefs: [] });
  ok(both === null, 'forced 字幕（只翻外语对白的那种）不当参照');
  // 长片（合成）：一部片 = 一串说话片段；参照与在线字幕各自从说话片段做出来（各自抖动、拆合、漏译），再给在线那份加上各种错位
  const rng = seed => { let x = seed >>> 0 || 1; return () => { x = (x * 1664525 + 1013904223) >>> 0; return x / 4294967296; }; };
  const gauss = r => Math.sqrt(-2 * Math.log(Math.max(1e-9, r()))) * Math.cos(2 * Math.PI * r());
  const speech = (seed, dur) => {
    const r = rng(seed), out = [];
    for (let t = 20 + r() * 60; t < dur - 30;) {
      for (let i = 0, n = 3 + Math.floor(r() * 25); i < n && t < dur - 30; i++) { const d = 0.7 + r() * 4.5; out.push({ s: t, e: t + d }); t += d + 0.15 + r() * (r() < 0.8 ? 1.5 : 6); }
      t += 4 + r() * (r() < 0.7 ? 40 : 150);
    }
    return out;
  };
  const subsOf = (sp, seed, jit, drop) => {
    const r = rng(seed), out = [];
    for (let i = 0; i < sp.length; i++) {
      if (r() < drop) continue;
      let { s, e } = sp[i];
      if (i + 1 < sp.length && r() < 0.2 && sp[i + 1].s - e < 1 && e - s < 2.5) { e = sp[i + 1].e; i++; }
      const js = s + gauss(r) * jit, je = e + gauss(r) * jit + 0.2;
      if (e - s > 4 && r() < 0.3) { const m = (js + je) / 2; out.push({ s: js, e: m - 0.05 }, { s: m, e: je }); } else out.push({ s: js, e: Math.max(js + 0.4, je) });
    }
    return out;
  };
  const shift = (cues, f) => cues.map(c => { const x = f(c.s), k = (f(c.s + 0.001) - x) / 0.001; return { s: x, e: x + (c.e - c.s) * k }; });
  /* 对齐后，离真实时间 0.3 秒以内的字幕占多少 */
  const good = (tg, truth, r) => { const o = I.syncApply(tg, r); return o.length !== truth.length ? 0 : o.filter((c, i) => Math.abs(c.s - truth[i].s) <= 0.3).length / truth.length; };
  const longCase = (dur, seed, f) => {
    const sp = speech(seed, dur), ref = subsOf(sp, seed + 1, 0.08, 0.05), truth = subsOf(sp, seed + 2, 0.12, 0.1), tg = shift(truth, f);
    const t0 = Date.now(), r = I.subSync(tg, ref);
    return { r, g: good(tg, truth, r), ms: Date.now() - t0, ref };
  };
  let L = longCase(2700, 31, t => t + 0.8 + 1.7 * Math.floor(t / 540));
  ok(L.r.applied && L.r.segs.length >= 4 && L.g >= 0.97,
    `45 分钟一集、每段广告切口都错开一点（5 级台阶）：切成 ${L.r.segs.length} 段（${L.r.segs.map(g => g.off).join(' / ')}），${(L.g * 100).toFixed(1)}% 的字幕回到 0.3 秒以内`);
  L = longCase(7200, 41, t => t < 3300 ? t + 1.2 : t + 39.6);
  ok(L.r.applied && L.r.segs.length === 2 && L.g >= 0.98 && L.ms < 8000,
    `两小时的片子，中间多了 38 秒（加长版做的字幕）：两段 ${L.r.segs.map(g => g.off).join(' / ')}，${(L.g * 100).toFixed(1)}% 回到 0.3 秒以内（算了 ${L.ms} ms）`);
  L = longCase(7200, 51, t => t * 23.976 / 24 + 0.5);
  ok(L.r.applied && Math.abs(L.r.scale - 24 / 23.976) < 1e-6 && L.g >= 0.98,
    `24 帧与 23.976 帧之差（两小时差出 7 秒）：认出速度比 ${L.r.scale.toFixed(5)}，${(L.g * 100).toFixed(1)}% 回到 0.3 秒以内`);
  const other = subsOf(speech(99, 7200), 100, 0.1, 0.05);
  const ru2 = I.subSync(other, L.ref);
  ok(!ru2.applied, `别的片子的字幕（同样密度、同样长）：不对齐（${ru2.why}）`);
  await clear();
  for (const k of ['OPENSUBTITLES_API_KEY', 'OPENSUBTITLES_USERNAME', 'OPENSUBTITLES_PASSWORD']) delete H.env[k];
}

console.log('\n■ 剧集：/api/tv、/api/tv/episodes、/api/tmdb/season、/api/tmdb?type=tv');
{
  const settle = async () => { while (H.pending.length) await Promise.all(H.pending.splice(0)); };
  const exp = Math.floor(Date.now() / 1000) + 3600;
  const cookie = `auth=${exp}.${crypto.createHmac('sha256', H.SECRET).update(`sess|${exp}`).digest('hex')}`;
  const get = async u => { const r = await H.call(u, 'GET', { Cookie: cookie }); return { status: r.status, body: await r.json() }; };
  const ST = '/ram2/怪奇物语 Stranger Things S04 [Full-9] 2160p NF WEB-DL DV Atmos';
  const LOU = '/ram2/The.Last.of.Us.S02.2160p.MAX.WEB-DL.DDP5.1.Atmos.DV.H.265';
  const f = (p, size = 1000, at = '2026-01-01T00:00:00Z') => ({ path_display: p, size, server_modified: at });
  H.tv.entries = [
    ...[1, 2, 3, 4, 5].map(i => f(`${ST}/Stranger.Things.S04E0${i}.2160p.mkv`, 5000, `2026-03-0${i}T00:00:00Z`)),
    f(`${ST}/Stranger.Things.S04E03.1080p.mkv`, 2000), f(`${ST}/sample.mkv`, 10), f(`${ST}/Stranger.Things.S04E01.zh.srt`),
    ...[1, 2, 3].map(i => f(`${LOU}/The.Last.of.Us.S02E0${i}.mkv`)),
    f('/ram2/繁花 全30集 4K 国语/第01集.mp4'), f('/ram2/繁花 全30集 4K 国语/第十集.mp4'), f('/ram2/繁花 全30集 4K 国语/第02集.mp4'),
    f('/ram2/Fargo/Season 1/Fargo.S01E01.mkv'), f('/ram2/Fargo/Season 2/Fargo.S02E01.mkv'), f('/ram2/Fargo/Season 2/Fargo.S02E02.mkv'),
    f('/ram2/Fargo/Specials/Fargo.S00E01.mkv'), f('/ram2/Fargo/Season 2/Featurettes/Making.Of.mkv'),
    f('/ram2/Mixed Show/Mixed.Show.S01E01.mkv'), f('/ram2/Mixed Show/Mixed.Show.S01E02.mkv'), f('/ram2/Mixed Show/Mixed.Show.S02E01.mkv'),
    f('/ram2/loose.mkv'),
  ];
  H.tv.pageSize = 4;          // 分页：每页 4 条，翻好几页
  H.tmdb.shows = [
    { id: 100088, name: '最后生还者', original: 'The Last of Us', first: '2023-01-15',
      seasons: [{ n: 1, air: '2023-01-15', count: 9 }, { n: 2, air: '2025-04-13', count: 7 }] },
    { id: 66732, name: '怪奇物语', original: 'Stranger Things', first: '2016-07-15', seasons: [{ n: 4, air: '2022-05-27', count: 9 }] },
    { id: 60622, name: '冰血暴', original: 'Fargo', first: '2014-04-15',
      seasons: [{ n: 1, air: '2014-04-15', count: 10 }, { n: 2, air: '2015-10-12', count: 10,
        eps: [{ zh: '等待达美航空', en: 'Waiting for Dutch', overview: '', still: '/s1.jpg' }, { zh: '在雪地里', en: 'Before the Law', overview: '中文简介', still: '/s2.jpg' }] }] },
  ];
  H.tmdb.movies = [{ id: 275, title: 'Fargo', date: '1996-03-08' }];
  H.env.TMDB_API_KEY = 'tmdb-test';
  delete H.env.TV_FOLDER;

  const t0 = await get('/api/tv');
  await settle();
  const L = t0.body.series || [];
  const by = p => L.find(s => s.path === p);
  ok(t0.status === 200 && L.length === 7, `剧集表：7 部（${L.map(s => s.title + (s.season ? ' S' + s.season : '')).join('、')}），根目录散放的文件不算`);
  const st = by(ST);
  ok(st && st.zh === '怪奇物语' && st.en === 'Stranger Things' && st.season === 4 && st.declared === 9 && st.res === '4K' &&
     st.hdr === 'DV' && st.audio === 'Atmos' && st.brand === 'Netflix' && st.episodes === 5 && st.complete === false && st.title === '怪奇物语',
    '目录名解析：中英名、第 4 季、共 9 集、4K 杜比视界全景声、Netflix；样片与字幕不算集，1080p 重复版合并');
  ok(st && st.tmdbId === 66732 && st.year === '2022' && st.total === 9 && st.added === '2026-03-05T00:00:00Z',
    'TMDB 补上编号、这一季的年份、集数；入库时间取最新那集');
  const lou = by(LOU);
  ok(lou && lou.zh === '最后生还者' && lou.title === '最后生还者' && lou.year === '2025' && lou.tmdbId === 100088 && lou.brand === 'HBO',
    '只有英文名的目录：中文名由 TMDB 补（最后生还者），年份是第二季的 2025 而不是首播的 2023');
  const fh = by('/ram2/繁花 全30集 4K 国语');
  ok(fh && fh.zh === '繁花' && fh.declared === 30 && fh.langs.join() === '国语' && fh.episodes === 3 && fh.complete === false, '中文目录：全 30 集 / 国语，目前 3 集');
  ok(by('/ram2/Fargo/Season 1') && by('/ram2/Fargo/Season 2') && by('/ram2/Fargo/Season 2').episodes === 2 && by('/ram2/Fargo/Season 2').title === '冰血暴',
    'Season 1 / Season 2 子目录各算一季；特别篇与花絮目录不算');
  ok(by('/ram2/Mixed Show#S1') && by('/ram2/Mixed Show#S1').episodes === 2 && by('/ram2/Mixed Show#S2') && by('/ram2/Mixed Show#S2').season === 2,
    '一个目录混着两季：按文件里的季号拆成两张卡');

  const lists = H.tv.lists, calls = H.tmdb.calls.length;
  const t1 = await get('/api/tv');
  await settle();
  ok(t1.body.series.length === 7 && H.tv.lists === lists && H.tmdb.calls.length === calls, '10 分钟内再取：直接用存着的表，不再列目录、不再查 TMDB');

  const e1 = await get('/api/tv/episodes?path=' + encodeURIComponent(ST));
  ok(e1.status === 200 && e1.body.series.id === st.id && e1.body.episodes.map(e => e.ep).join() === '1,2,3,4,5' &&
     e1.body.episodes[2].name === 'Stranger.Things.S04E03.2160p.mkv', '分集表：按集号排，同一集留大的那个版本');
  const e2 = await get('/api/tv/episodes?path=' + encodeURIComponent('/ram2/繁花 全30集 4K 国语'));
  ok(e2.body.episodes.map(e => e.ep).join() === '1,2,10' && e2.body.episodes[2].path === '/ram2/繁花 全30集 4K 国语/第十集.mp4', '「第十集」认成第 10 集');
  const e3 = await get('/api/tv/episodes?path=' + encodeURIComponent('/ram2/没有这部剧'));
  ok(e3.status === 404, '不存在的剧：404');

  const s2 = await get('/api/tmdb/season?id=60622&season=2');
  const eps = s2.body.episodes || [];
  ok(eps.length === 2 && eps[0].name === '等待达美航空' && eps[0].overview === 'EN: Waiting for Dutch' && eps[1].overview === '中文简介' &&
     eps[0].still === 'https://image.tmdb.org/t/p/w780/s1.jpg' && eps[0].runtime === 50, 'TMDB 一季：中文集名，中文简介缺的补英文，剧照 w780');
  const n = H.tmdb.calls.length;
  await get('/api/tmdb/season?id=60622&season=2'); await settle();
  ok(H.tmdb.calls.length === n, '一季的分集信息有缓存');

  const m1 = await get('/api/tmdb?query=Fargo&type=tv&logo=1&year=2015');
  ok(m1.body && m1.body.type === 'tv' && m1.body.id === 60622 && m1.body.posterClean === 'https://image.tmdb.org/t/p/w780/clean.jpg',
    'type=tv：同名电影《冰血暴》(1996) 不会顶掉剧集；第二季的年份也能搜到；带纯净海报');
  const m2 = await get('/api/tmdb?query=Fargo');
  ok(m2.body && m2.body.type === 'movie' && m2.body.id === 275, '不带 type：老规矩，电影优先');

  // TV 目录不存在 → 空表（前端据此整段不显示），不报错
  H.env.TV_FOLDER = '/nope';
  const t2 = await get('/api/tv');
  await settle();
  ok(t2.status === 200 && Array.isArray(t2.body.series) && t2.body.series.length === 0, 'TV_FOLDER 不存在：回空表');
  delete H.env.TV_FOLDER; delete H.env.TMDB_API_KEY;
  H.tv.entries = []; H.tv.pageSize = 0;
}

console.log('\n■ 预告片：IMDb 直链优先，被拒时退到 TMDB 登记的 YouTube 官方预告');
{
  const settle = async () => { while (H.pending.length) await Promise.all(H.pending.splice(0)); };
  const exp = Math.floor(Date.now() / 1000) + 3600;
  const cookie = `auth=${exp}.${crypto.createHmac('sha256', H.SECRET).update(`sess|${exp}`).digest('hex')}`;
  const get = async u => { const r = await H.call(u, 'GET', { Cookie: cookie }); return { status: r.status, cc: r.headers.get('cache-control'), body: await r.json() }; };
  H.env.TMDB_API_KEY = 'tmdb-test';
  const mp4 = 'https://imdb-video.media-imdb.com/vi1/1080.mp4?Expires=1794453949&Signature=x';
  H.imdb.status = 200; H.imdb.calls = 0;
  H.imdb.title = { id: 'tt0111161', titleText: { text: 'The Shawshank Redemption' }, releaseYear: { year: 1994 }, plot: null, images: { edges: [] },
    primaryVideos: { edges: [{ node: { id: 'vi1', name: { value: 'Trailer' }, runtime: { value: 120 }, contentType: { displayName: { value: 'Trailer' } },
      thumbnail: null, playbackURLs: [{ displayName: { value: '1080p' }, videoMimeType: 'MP4', url: mp4 }] } }] } };
  const r0 = await get('/api/imdb/video?id=tt0111161&stills=0');
  ok(r0.body.video && r0.body.video.best === mp4 && r0.body.yt === null && /max-age=21600/.test(r0.cc), 'IMDb 给得出直链：照旧用直链 MP4（缓存 6 小时，短于签名有效期）');

  H.imdb.status = 403; H.imdb.calls = 0;
  H.tmdb.find.tt15239678 = { movie_results: [{ id: 693134 }], tv_results: [] };
  H.tmdb.videos['movie/693134'] = [
    { iso_639_1: 'en', key: 'Way9Dexny3w', site: 'YouTube', size: 1080, type: 'Trailer', official: true, published_at: '2023-12-21T00:00:00.000Z', name: 'Official Trailer 3' },
    { iso_639_1: 'en', key: 'U2Qp5pL3ovA', site: 'YouTube', size: 2160, type: 'Teaser', official: true, published_at: '2023-05-03T00:00:00.000Z', name: 'Teaser' },
    { iso_639_1: 'zh', key: 'zhTrailer01', site: 'YouTube', size: 1080, type: 'Trailer', official: true, published_at: '2024-02-01T00:00:00.000Z', name: '终极预告' },
    { iso_639_1: 'en', key: 'fanTrailer1', site: 'YouTube', size: 2160, type: 'Trailer', official: false, published_at: '2024-03-01T00:00:00.000Z', name: 'Fan made' },
    { iso_639_1: 'en', key: '123456789ab', site: 'Vimeo', size: 1080, type: 'Trailer', official: true, published_at: '2024-03-01T00:00:00.000Z', name: 'Vimeo' },
  ];
  const t0 = Date.now();
  const r1 = await get('/api/imdb/video?id=tt15239678&stills=0');
  ok(r1.body.video === null && r1.body.yt && r1.body.yt.key === 'zhTrailer01' && r1.body.yt.official && H.imdb.calls === 1 && Date.now() - t0 < 3000,
    `IMDb 回 403：退到 TMDB 的官方预告（${r1.body.yt && r1.body.yt.name}，${Date.now() - t0}ms，不等满超时）`);
  ok(/max-age=259200/.test(r1.cc), '只有 YouTube 预告的回包缓存 3 天');

  H.tmdb.videos['movie/27205'] = [{ iso_639_1: 'en', key: 'YoHD9XEInc0', site: 'YouTube', size: 1080, type: 'Trailer', official: true, published_at: '2010-05-01T00:00:00.000Z', name: 'Trailer' }];
  const c0 = H.tmdb.calls.length;
  const r2 = await get('/api/imdb/video?id=tt1375666&tmdb=27205&type=movie&stills=0');
  ok(r2.body.yt && r2.body.yt.key === 'YoHD9XEInc0' && H.imdb.calls === 1 && H.tmdb.calls.length - c0 === 1,
    'IMDb 刚拒绝过：下一部不再去问它；带着 TMDB 编号只要一次请求');

  await settle();
  const c1 = H.tmdb.calls.length;
  const r3 = await get('/api/imdb/video?id=tt15239678&stills=0');
  ok(r3.body.yt && r3.body.yt.key === 'zhTrailer01' && H.tmdb.calls.length === c1, '同一部再问：走缓存');

  H.tmdb.movies = [{ id: 275, title: 'Fargo', date: '1996-03-08' }];
  H.tmdb.videos['movie/275'] = [{ iso_639_1: 'en', key: 'h2tY82z3xXU', site: 'YouTube', size: 480, type: 'Trailer', official: true, published_at: '2016-01-01T00:00:00.000Z', name: 'Trailer' }];
  const r4 = await get('/api/imdb/video?query=Fargo&year=1996&stills=0');
  ok(r4.body.yt && r4.body.yt.key === 'h2tY82z3xXU', '只有片名和年份：TMDB 搜到再取预告');
  const r5 = await get('/api/imdb/video?query=NoSuchFilm&stills=0');
  ok(r5.status === 200 && r5.body.video === null && r5.body.yt === null, '查无此片：空回包，前端退回剧照');
  await settle();
  delete H.env.TMDB_API_KEY;
}

console.log('\n■ 片名匹配：文件名 → TMDB（候选打分、校验、宁缺毋滥）');
{
  const settle = async () => { while (H.pending.length) await Promise.all(H.pending.splice(0)); };
  const clear = async () => { await settle(); caches.default.m.clear(); };
  const exp = Math.floor(Date.now() / 1000) + 3600;
  const cookie = `auth=${exp}.${crypto.createHmac('sha256', H.SECRET).update(`sess|${exp}`).digest('hex')}`;
  const batch = async (names, logo = false) => {
    const r = await H.worker.fetch(new Request('https://w.test/api/tmdb-batch', { method: 'POST', headers: { 'Content-Type': 'application/json', Cookie: cookie },
      body: JSON.stringify({ queries: names.map(name => ({ name, logo })) }) }), H.env, H.ctx);
    await settle();
    return r.json();
  };
  const one = async (name, logo) => (await batch([name], logo))[name];
  H.env.TMDB_API_KEY = 'tmdb-test';
  H.tmdb.shows = [{ id: 7001, name: '某部冷门剧', original: 'Some Obscure Film', first: '1990-01-01',
    seasons: [{ n: 1, air: '1990-01-01', count: 8 }, { n: 9, air: '2015-03-01', count: 8 }] }];
  H.tmdb.movies = [
    // 同名不同年 + 续集：「Dune」三部都会被搜出来，最热门的是续集
    { id: 841, query: 'dune', title: '沙丘', en: 'Dune', date: '1984-12-14', pop: 40, votes: 3000 },
    { id: 438631, query: 'dune', title: '沙丘', en: 'Dune', date: '2021-09-15', pop: 120, votes: 12000, backdrop: '/b438631.jpg' },
    { id: 693134, query: 'dune part two', q: ['dune'], title: '沙丘2', en: 'Dune: Part Two', date: '2024-02-27', pop: 300, votes: 6000 },
    // 片名本身带年份
    { id: 335984, query: 'blade runner 2049', title: '银翼杀手2049', en: 'Blade Runner 2049', date: '2017-10-04', pop: 80 },
    { id: 78, query: 'blade runner', q: ['blade runner 2049'], title: '银翼杀手', en: 'Blade Runner', date: '1982-06-25', pop: 90 },
    { id: 464052, query: 'wonder woman 1984', title: '神奇女侠1984', en: 'Wonder Woman 1984', date: '2020-12-16', pop: 60 },
    { id: 297762, query: 'wonder woman', q: ['wonder woman 1984'], title: '神奇女侠', en: 'Wonder Woman', date: '2017-05-30', pop: 70 },
    // 续集号
    { id: 10193, query: 'toy story 3', title: '玩具总动员3', en: 'Toy Story 3', date: '2010-06-16', pop: 50 },
    { id: 301528, query: 'toy story 4', q: ['toy story 3'], title: '玩具总动员4', en: 'Toy Story 4', date: '2019-06-19', pop: 90 },
    // 中英文名都在文件名里；前作更热门、也会被搜出来
    { id: 842675, query: 'the wandering earth ii', q: ['流浪地球2'], title: '流浪地球2', en: 'The Wandering Earth II', original: '流浪地球2', lang: 'zh', date: '2023-01-22', pop: 40 },
    { id: 535167, query: 'the wandering earth', q: ['the wandering earth ii', '流浪地球2'], title: '流浪地球', en: 'The Wandering Earth', original: '流浪地球', lang: 'zh', date: '2019-02-05', pop: 90 },
    // 原名不是英文：只能靠英文名认
    { id: 496243, query: 'parasite', title: '寄生虫', en: 'Parasite', original: '기생충', lang: 'ko', date: '2019-05-30' },
    // 罗马音文件名：搜得到，但中英文名、原名都对不上 → 取别名表才认得出
    { id: 372058, query: 'kimi no na wa', title: '你的名字。', en: 'Your Name.', original: '君の名は。', lang: 'ja', date: '2016-08-26', aka: ['Kimi no Na wa.'] },
    // TMDB 上没有海报
    { id: 900001, query: 'no art film', title: '没有海报的片子', en: 'No Art Film', date: '2011-01-01', poster: null },
    { id: 900002, query: 'shaky', title: '网络抖动', en: 'Shaky', date: '2012-01-01' },
  ];
  await clear();
  let r = await batch(['Dune.1984.1080p.BluRay.mkv', 'Dune.mkv', 'Dune.Part.Two.2024.2160p.WEB-DL.DV.mkv']);
  ok(r['Dune.1984.1080p.BluRay.mkv']?.id === 841 && r['Dune.mkv']?.id === 438631 && r['Dune.Part.Two.2024.2160p.WEB-DL.DV.mkv']?.id === 693134,
    `同名不同年 / 续集：《沙丘》1984 → ${r['Dune.1984.1080p.BluRay.mkv']?.year}、不带年份 → ${r['Dune.mkv']?.year}（片名一样里票数最多的，不是更热门的续集）、《沙丘2》→ ${r['Dune.Part.Two.2024.2160p.WEB-DL.DV.mkv']?.year}`);
  r = await batch(['Blade.Runner.2049.2017.2160p.UHD.BluRay.x265-GRP.mkv', 'Wonder.Woman.1984.2020.1080p.WEB-DL.mkv']);
  ok(r['Blade.Runner.2049.2017.2160p.UHD.BluRay.x265-GRP.mkv']?.id === 335984 && r['Wonder.Woman.1984.2020.1080p.WEB-DL.mkv']?.id === 464052,
    `片名里的年份留在片名里：${r['Blade.Runner.2049.2017.2160p.UHD.BluRay.x265-GRP.mkv']?.title}、${r['Wonder.Woman.1984.2020.1080p.WEB-DL.mkv']?.title}（原来会截成《银翼杀手》《神奇女侠》）`);
  r = await batch(['Toy.Story.3.mkv']);
  ok(r['Toy.Story.3.mkv']?.id === 10193, `续集号对不上的不认：Toy.Story.3 → ${r['Toy.Story.3.mkv']?.title}（更热门的 4 也被搜出来了）`);
  r = await batch(['流浪地球2.The.Wandering.Earth.II.2023.2160p.WEB-DL.H265.mkv', 'Parasite.2019.1080p.mkv']);
  ok(r['流浪地球2.The.Wandering.Earth.II.2023.2160p.WEB-DL.H265.mkv']?.id === 842675 && r['Parasite.2019.1080p.mkv']?.id === 496243 && r['Parasite.2019.1080p.mkv']?.title === '寄生虫',
    `中英文名都用上：${r['流浪地球2.The.Wandering.Earth.II.2023.2160p.WEB-DL.H265.mkv']?.title}；原名是韩文的靠英文名认：${r['Parasite.2019.1080p.mkv']?.title}`);
  H.tmdb.calls.length = 0;
  r = await batch(['Kimi.no.Na.wa.2016.BluRay.1080p.mkv']);
  ok(r['Kimi.no.Na.wa.2016.BluRay.1080p.mkv']?.id === 372058 && H.tmdb.calls.some(c => c.path === '/movie/372058' && /alternative_titles/.test(c.q.append_to_response || '')),
    `罗马音文件名：取别名表认出《${r['Kimi.no.Na.wa.2016.BluRay.1080p.mkv']?.title}》`);
  H.tmdb.calls.length = 0;
  r = await batch(['Some.Obscure.Film.2015.1080p.mkv', 'Movie.Name.2019.1080p-sample.mkv', 'Totally.Unknown.Thing.2020.mkv']);
  ok(r['Some.Obscure.Film.2015.1080p.mkv'] === null && r['Totally.Unknown.Thing.2020.mkv'] === null,
    '电影认不上时不拿剧集顶：同名老剧那年播过一季也不认（首播 1990 ≠ 2015）；搜不到的就是没有（null）');
  ok(r['Movie.Name.2019.1080p-sample.mkv'] === null && !H.tmdb.calls.some(c => /movie name/i.test(c.q.query || '')), '样片 / 预告 / 花絮：直接回没有，不去搜');
  r = await batch(['No.Art.Film.2011.mkv']);
  ok(r['No.Art.Film.2011.mkv'] && r['No.Art.Film.2011.mkv'].id === 900001 && r['No.Art.Film.2011.mkv'].poster === null, 'TMDB 上没有海报：认得出，但 poster 为空（前端据此不显示）');
  await clear();
  H.itunes.results = [{ trackName: 'No Art Film', releaseDate: '2011-03-01T00:00:00Z', artworkUrl100: 'https://is1.mzstatic.com/image/thumb/a/100x100bb.jpg' }];
  r = await batch(['No.Art.Film.2011.mkv']);
  ok(/mzstatic/.test(r['No.Art.Film.2011.mkv']?.poster || ''), 'TMDB 没有海报时用 iTunes 补一张（片名、年份对得上的那条）');
  await clear();
  H.itunes.results = [{ trackName: 'No Art Film 2', releaseDate: '2016-03-01T00:00:00Z', artworkUrl100: 'https://is1.mzstatic.com/image/thumb/b/100x100bb.jpg' },
    { trackName: 'Something Else', releaseDate: '2011-03-01T00:00:00Z', artworkUrl100: 'https://is1.mzstatic.com/image/thumb/c/100x100bb.jpg' }];
  r = await batch(['No.Art.Film.2011.mkv']);
  ok(r['No.Art.Film.2011.mkv']?.poster === null, 'iTunes 只有续集 / 别的片子：不拿来顶（原来取第一条）');
  await clear();
  H.itunes.results = [{ trackName: 'Dune', releaseDate: '2021-10-22T00:00:00Z', artworkUrl100: 'https://is1.mzstatic.com/image/thumb/d/100x100bb.jpg' }];
  const full = await one('Dune.1984.1080p.BluRay.mkv', true);
  ok(full && full.id === 841 && !/mzstatic/.test(full.poster || '') && full.artworkSource === 'tmdb',
    '详情页：iTunes 搜到的是 2021 版 → 不换海报（TMDB 认的是 1984 版）');
  await clear();
  H.itunes.results = [{ trackName: 'Dune', releaseDate: '2021-10-22T00:00:00Z', artworkUrl100: 'https://is1.mzstatic.com/image/thumb/e/100x100bb.jpg' }];
  const full2 = await one('Dune.2021.2160p.mkv', true);
  ok(full2 && /mzstatic/.test(full2.poster || '') && /image\.tmdb\.org/.test(full2.backdrop || ''),
    '对得上的 iTunes 海报照用，但横向背景仍是 TMDB 的剧照（iTunes 只有竖版海报）');
  H.itunes.results = null;
  // TMDB 出错：这一项不回（不是 null），也不缓存；好了以后正常认
  await clear();
  H.tmdb.fail = (path, q) => /shaky/i.test(q.query || '');
  r = await batch(['Shaky.2012.mkv', 'Parasite.2019.1080p.mkv']);
  ok(!('Shaky.2012.mkv' in r) && r['Parasite.2019.1080p.mkv']?.id === 496243, 'TMDB 出错的那一项不回（前端过会儿再问），别的照常');
  H.tmdb.fail = null;
  r = await batch(['Shaky.2012.mkv']);
  ok(r['Shaky.2012.mkv']?.id === 900002, '出错那次没被当成「没有」缓存下来：恢复后正常认出');
  // 单条接口：剧集按编号取（剧集表认好的那部）
  const byId = await (await H.call('/api/tmdb?id=7001&type=tv&logo=1', 'GET', { Cookie: cookie })).json();
  ok(byId && byId.id === 7001 && byId.type === 'tv' && byId.title === '某部冷门剧', `/api/tmdb?id=&type=tv：按编号取，不再按名字重认（${byId && byId.title}）`);
  delete H.env.TMDB_API_KEY; H.tmdb.movies = []; H.tmdb.shows = [];
  await clear();
}

console.log('\n■ 字幕清洗：字幕组、发布 / 来源声明、网址、广告');
{
  const X = await H.internals();
  const D = 6000;                                                     // 片长 100 分钟
  const cue = (s, text) => ({ s, e: s + 2, text, settings: '' });
  const head = ['本字幕由XX字幕组翻译制作\n仅供学习交流，请于下载后24小时内删除', '翻译：张三  校对：李四', '人人影视原创翻译', '【YYeTs】',
    '-=TLF=-', 'www.zimuku.la 字幕库', 'Subtitles by explosiveskull', '中英字幕', 'Movie.2019.1080p.BluRay.x264-SPARKS', '@破烂熊字幕组',
    'Translated by: Jane Doe', '时间轴：王五', 'Sync and corrected by elderman', '微信公众号：电影字幕'];
  const keepHead = ['我们出发吧', '<i>Previously on...</i>', '- Where are you going?\n- Home.', '♪ 夜色多美好 ♪'];
  const mid = ['我们公司出品的东西都很好', '翻译一下这句话', '伊甸园里有一棵树', 'Email me at john@example.com', 'This book was translated by my father',
    '他是这家工作室的老板', '2019年我们在北京', 'Mr.Smith is here.', '你愿意加入我们吗？', '我在淘宝上买的', 'A telegram for you, sir.',
    '这仅供参考', '未经授权不得入内', 'I stand corrected by the facts.', '关注我的公众号', 'His mistake was corrected by the teacher.'];
  const dropMid = ['Visit www.badsite.com for more subs', 'QQ群：123456789', 'Please rate this subtitle at www.osdb.link/abc', '本片仅供学习交流'];
  const tail = ['Advertise your product or brand here\ncontact www.OpenSubtitles.org today', 'Support us and become VIP member\nto remove all ads from www.OpenSubtitles.org', '压制：CMCT'];
  const cues = [
    ...head.map((t, i) => cue(1 + i * 3, t)), ...keepHead.map((t, i) => cue(60 + i * 3, t)),
    ...mid.map((t, i) => cue(3000 + i * 3, t)), ...dropMid.map((t, i) => cue(3100 + i * 3, t)),
    cue(3200, '好的\n字幕组招募翻译 QQ群123456'),
    ...tail.map((t, i) => cue(D - 100 + i * 3, t)),
  ];
  const out = X.subClean(cues, D);
  const texts = out.map(c => c.text);
  const gone = [...head, ...dropMid, ...tail].filter(t => texts.includes(t) || texts.some(x => t.split('\n').some(l => x.includes(l) && l.length > 4)));
  ok(!gone.length, `片头片尾的署名 / 声明 / 广告、正片里的网址与引流全部删掉（${head.length + dropMid.length + tail.length} 条）${gone.length ? '；漏了：' + gone.join(' | ') : ''}`);
  const lost = [...keepHead, ...mid].filter(t => !texts.includes(t));
  ok(!lost.length, `台词一条不误删（片头的对白、正片里提到「出品」「翻译」「伊甸园」、邮箱、Mr.Smith…）${lost.length ? '；误删：' + lost.join(' | ') : ''}`);
  ok(texts.includes('好的'), '一条里混着广告行：只删那一行，台词留下');
  const vtt = X.hlsVtt(cues.filter(c => c.s > 2900 && c.s < 3300), D);
  ok(vtt.includes('伊甸园里有一棵树') && !vtt.includes('osdb') && !vtt.includes('QQ群'), 'HLS 分段 VTT 走同一套清洗');
  const ass = '[Script Info]\nScriptType: v4.00+\n\n[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n' +
    'Dialogue: 0,0:00:01.00,0:00:05.00,Staff,,0,0,0,,本片由 Cuven 校对\n' +
    'Dialogue: 0,0:00:06.00,0:00:08.00,Default,,0,0,0,,你好\n' +
    'Dialogue: 0,0:00:09.00,0:00:11.00,Note,,0,0,0,,注：双关语\n';
  const pc = X.hlsParseSubFile(ass, '.ass').map(c => c.text);
  ok(pc.join('|') === '你好|注：双关语', 'ASS 里 Staff 样式的署名整条不要；译注（Note）留着');
  // 直连外挂字幕：/api/subs/vtt 输出已清洗
  const srt = [['00:00:01,000', '00:00:04,000', '本字幕由XX字幕组翻译\nwww.example-subs.com'], ['00:00:05,000', '00:00:07,000', '你好'],
    ['00:00:08,000', '00:00:10,000', '再见']].map((c, i) => `${i + 1}\n${c[0]} --> ${c[1]}\n${c[2]}\n`).join('\n');
  fs.writeFileSync(S('clean_case.zh.srt'), srt);
  const exp = Math.floor(Date.now() / 1000) + 3600;
  const cookie = `auth=${exp}.${crypto.createHmac('sha256', H.SECRET).update(`sess|${exp}`).digest('hex')}`;
  const v = await (await H.call('/api/subs/vtt?path=' + encodeURIComponent('/Movies/clean_case.zh.srt'), 'GET', { Cookie: cookie })).text();
  fs.unlinkSync(S('clean_case.zh.srt'));
  ok(/^WEBVTT/.test(v) && v.includes('你好') && v.includes('再见') && !/字幕组|example-subs/.test(v), '直连的外挂字幕（/api/subs/vtt）也清洗过');
}

console.log('\n■ 增强型字幕清洗（c2）：水印、署名块、全角网址、绘图指令、分段不误删');
{
  const X = await H.internals();
  const D = 6000;
  const cue = (s, text, d = 2) => ({ s, e: s + d, text, settings: '' });
  const keepT = (out, t) => out.some(c => c.text === t);
  // ① 新认得的：全角网址、新版 OpenSubtitles 广告、资源来源、机翻声明、ASS 绘图指令、乱码
  const dropAny = ['更多美剧请访问 ＷＷＷ．ＹＹＥＴＳ．ＣＯＭ', 'Do you want subtitles for any video?\n-=[ ai.OpenSubtitles.com ]=-',
    'OpenSubtitles recommends using Nord VPN\nfrom 3.49 USD/month ----> osdb.link/vpn', 'Watch any video online with Open-SUBTITLES\nFree Browser extension: osdb.link/ext',
    'm 0 0 l 100 0 100 100 0 100', '��� ��', '【@影视工厂】'];
  const dropEdge = ['Resync for WEB-DL by Fenrir', 'Subtitles improved by Lu', '本资源来自XX论坛', '机翻，如有错误欢迎指正', '转载请注明出处', '扫码关注我们'];
  const mid = 3000;
  const c1 = [...dropAny.map((t, i) => cue(mid + i * 5, t)), ...dropEdge.map((t, i) => cue(30 + i * 20, t)), cue(mid + 200, '我们出发吧')];
  const o1 = X.subClean(c1, D);
  const left = [...dropAny, ...dropEdge].filter(t => o1.some(c => t.split('\n').some(l => c.text.includes(l))));
  ok(!left.length && keepT(o1, '我们出发吧'), `全角网址、新版 OpenSubtitles 广告、资源来源、机翻声明、ASS 绘图指令、乱码都删掉${left.length ? '；漏了：' + left.join(' | ') : ''}`);

  // ② 水印：同一行跟着整部片反复出现（第二行），全片都删；高频台词一条不动
  const c2 = [];
  for (let i = 0; i < 40; i++) c2.push(cue(300 + i * 130, `第${i}句台词`));
  for (let i = 0; i < 8; i++) c2[i * 5].text += '\n★影视工厂★';
  for (let i = 0; i < 10; i++) c2.push(cue(320 + i * 500, '好的'));
  for (let i = 0; i < 6; i++) c2.push(cue(340 + i * 800, 'Thank you.'));
  for (let i = 0; i < 4; i++) c2.push(cue(360 + i * 1200, '我是这家工作室的老板'));
  const o2 = X.subClean(c2, D);
  ok(!o2.some(c => c.text.includes('影视工厂')) && o2.filter(c => /^第\d+句台词$/.test(c.text)).length === 40,
    '水印（「★影视工厂★」跟着 8 条台词贯穿全片）：全片删掉，那 8 条台词本身留着');
  ok(o2.filter(c => c.text === '好的').length === 10 && o2.filter(c => c.text === 'Thank you.').length === 6 && o2.filter(c => c.text === '我是这家工作室的老板').length === 4,
    '高频台词（好的 ×10、Thank you. ×6、「我是这家工作室的老板」×4）不会被当成水印');

  // ③ 署名块：片头一串署名里夹着的弱信号一起删；紧跟在后面的对白不动。挂得久的片尾鸣谢删，久的开场旁白留着
  const c3 = [cue(2, '翻译：张三'), cue(5, '感谢所有成员的辛勤付出'), cue(8, '时间轴：王五'), cue(40, '我们出发吧'),
    cue(D - 30, '感谢收看', 15), cue(10, '很久很久以前，在一个遥远的地方', 12), cue(mid, '感谢大家的支持')];
  const o3 = X.subClean(c3, D);
  ok(!keepT(o3, '感谢所有成员的辛勤付出') && !keepT(o3, '翻译：张三') && keepT(o3, '我们出发吧'), '片头署名块里夹着的「感谢所有成员的辛勤付出」随整块删掉；后面的对白留着');
  ok(!keepT(o3, '感谢收看') && keepT(o3, '很久很久以前，在一个遥远的地方') && keepT(o3, '感谢大家的支持'),
    '片尾挂了 15 秒的「感谢收看」删掉；开场 12 秒的旁白、正片里的「感谢大家的支持」都留着');

  // ④ 像台词的行只靠弱信号：减一分，片头也不删
  const o4 = X.subClean([cue(20, '你愿意加入我们吗？'), cue(26, '关注我的公众号吧'), cue(32, 'Email me at john@example.com')], D);
  ok(o4.length === 3, '片头的「你愿意加入我们吗？」「关注我的公众号吧」、邮箱：像台词，不删');

  // ⑤ HLS 分段（partial）：c1 曾把每一段的前 6 / 后 6 条当片头片尾（门槛 3 分），正片台词被误删
  const win = [cue(mid, '你好'), cue(mid + 2, '这家工作室出品的片子'), cue(mid + 4, '好看吗'), cue(mid + 6, '还行')];
  const v5 = X.hlsVtt(win, D);
  ok(v5.includes('这家工作室出品的片子'), 'HLS 分段只按时间认片头片尾：正片中间「这家工作室出品的片子」（3 分）不再被误删');
  const v5b = X.hlsVtt([cue(20, '这家工作室出品'), cue(22, '你好')], D);
  ok(!v5b.includes('这家工作室出品') && v5b.includes('你好'), '片头那一段照旧按片头的门槛删');

  // ⑥ ASS 里 {\p1} 画的矢量图形：解析后只剩一串路径指令 → 删
  const ass = '[Script Info]\nScriptType: v4.00+\n\n[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n' +
    'Dialogue: 0,0:10:00.00,0:10:05.00,Default,,0,0,0,,{\\p1}m 0 0 l 100 0 100 100 0 100{\\p0}\n' +
    'Dialogue: 0,0:10:06.00,0:10:08.00,Default,,0,0,0,,你好\n';
  const pa = X.subClean(X.hlsParseSubFile(ass, '.ass'), D).map(c => c.text);
  ok(pa.join('|') === '你好', 'ASS 的矢量绘图（{\\p1} m 0 0 l …）不进字幕');
}

// ⑦ 外挂字幕的 HLS 分段：整份洗一次再按段取 —— 水印（每段只露一次）也认得出
console.log('\n■ 外挂字幕 HLS 分段走整份清洗');
{
  const settle = async () => { while (H.pending.length) await Promise.all(H.pending.splice(0)); };
  await settle(); caches.default.m.clear();
  const tc = s => { const h = Math.floor(s / 3600), m = Math.floor(s % 3600 / 60), x = s % 60; return `${String(h).padStart(2, '0')}:${String(m).padStart(2, '0')}:${x.toFixed(3).padStart(6, '0').replace('.', ',')}`; };
  const lines = [];
  for (let i = 0; i < 30; i++) lines.push([5 + i * 5.8, `第${i}句` + (i % 6 === 0 ? '\n【@字幕工厂】' : '')]);
  fs.writeFileSync(S('sync_nosub.zh.srt'), lines.map(([a, t], i) => `${i + 1}\n${tc(a)} --> ${tc(a + 2)}\n${t}\n`).join('\n'));
  try {
    const f = '/Movies/sync_nosub.mkv';
    const m = await (await H.call(`/hls/${H.token(f)}/master.m3u8`)).text();
    const idh = /\n([^/\n]+)\/v\.m3u8/.exec(m)[1];
    const pl = await (await H.call(`/hls/${H.token(f)}/${idh}/x0.m3u8`)).text();
    const n = (pl.match(/\.vtt/g) || []).length;
    let all = '';
    for (let k = 0; k < n; k++) all += await (await H.call(`/hls/${H.token(f)}/${idh}/x0/${k}.vtt`)).text();
    const said = new Set(all.match(/第\d+句/g) || []).size;          // 跨段的那条两段都有，按句数
    ok(n > 3 && said === 30 && !all.includes('字幕工厂'), `外挂字幕 ${n} 段：30 句台词都在，跟着台词出现 5 次的「【@字幕工厂】」一条不剩`);
  } finally { fs.unlinkSync(S('sync_nosub.zh.srt')); await settle(); caches.default.m.clear(); }
}

console.log('\n■ ffmpeg 作为 HLS 客户端（HTTP）');
{
  const srv = http.createServer(async (req, res) => {
    const r = await H.worker.fetch(new Request('http://' + req.headers.host + req.url), H.env, H.ctx);
    res.writeHead(r.status, Object.fromEntries(r.headers));
    if (r.body) for await (const c of r.body) res.write(c);
    res.end();
  });
  await new Promise(r => srv.listen(18181, '127.0.0.1', r));
  const url = `http://127.0.0.1:18181/hls/${H.token('/Movies/hdr10_multi.mkv')}/master.m3u8`;
  const md5 = args => execFileSync('sh', ['-c', `ffmpeg -v error ${args} -map 0:v:0 -f framemd5 - | grep -v '^#' | awk -F, '{print $6}' | md5sum`]).toString();
  // ffmpeg 解 HLS 会阻塞事件循环，所以放进子进程里跑
  const run = cmd => new Promise(res => import('node:child_process').then(cp => cp.exec(cmd, { maxBuffer: 1 << 30 }, (e, o) => res(o))));
  const viaHls = await run(`ffmpeg -v error -i '${url}' -map 0:v:0 -f framemd5 - | grep -v '^#' | awk -F, '{print $6}' | md5sum`);
  ok(viaHls === md5(`-i '${S('hdr10_multi.mkv')}'`), '经 HLS 解码的每帧 MD5 与直接解码源文件一致');
  srv.close();
}

if (fs.existsSync(path.join(HERE, '..', 'audio-tx', 'tx.wasm'))) {
  console.log('\n■ DTS / TrueHD / Opus → AC-3 转码');
  const health = async () => (await H.call('/health')).text();
  const h0 = await health();
  await H.bindAudioTx();
  const h1 = await health();
  ok(/DTS \/ TrueHD<\/span><span>— 未配置（绑定 AUDIO_TX 或设 AUDIO_TX_URL/.test(h0) && /DTS \/ TrueHD<\/span><span>✅ 已绑定，转码 Worker 在线/.test(h1),
    '健康页：转码 Worker 绑没绑、在不在线，一眼看得到（还有 TMDB / OpenSubtitles / 剧集目录 / 访问保护）');
  const b = `/hls/${H.token('/Movies/hdr10_multi.mkv')}/`;
  const m = await (await H.call(b + 'master.m3u8')).text();
  for (const [i, label] of [[4, 'DTS'], [5, 'TrueHD'], [6, 'Opus']]) {
    const uri = new RegExp(`URI="([^"]*t${i}\\.m3u8)"`).exec(m)?.[1];
    if (!uri) { ok(false, `${label} 转码音轨未出现在主列表`); continue; }
    const dir = uri.replace(/[^/]+$/, '');
    const pl = await (await H.call(b + uri)).text();
    const durs = pl.split('\n').filter(l => l.startsWith('#EXTINF')).map(l => parseFloat(l.slice(8)));
    const parts = [Buffer.from(await (await H.call(b + dir + `t${i}.mp4`)).arrayBuffer())];
    for (let k = 0; k < durs.length; k++) parts.push(Buffer.from(await (await H.call(`${b}${dir}t${i}/${k}.m4s`)).arrayBuffer()));
    const f = path.join(OUT, `t${i}.mp4`);
    fs.writeFileSync(f, Buffer.concat(parts));
    const pcm = args => { const b = ff([...args, '-ac', '2', '-ar', '48000', '-f', 'f32le', '-']); return new Float32Array(b.buffer, b.byteOffset, b.length >> 2); };
    const ref = pcm(['-i', S('hdr10_multi.mkv'), '-map', `0:a:${i}`]), got = pcm(['-i', f]);
    // 首尾各 0.25s 不计：测试信号在 t=0 突然起振，AC-3 对这种瞬态的预回声与分段无关
    const n = (Math.min(ref.length, got.length) >> 1) - 12000, skip = 12000;
    const e = new Float64Array(n), r = new Float64Array(n);
    for (let j = skip; j < n; j++) for (let c = 0; c < 2; c++) { const d = ref[2 * j + c] - got[2 * j + c]; e[j] += d * d; r[j] += ref[2 * j + c] ** 2; }
    const sum = (a, x, y) => { let s = 0; for (let j = x; j < y; j++) s += a[j]; return s; };
    const snr = 10 * Math.log10(sum(r, skip, n) / Math.max(1e-15, sum(e, skip, n)));
    const wins = [];
    for (let w = skip; w + 512 <= n; w += 512) wins.push(sum(e, w, w + 512) / 512);
    const median = wins.slice().sort((a, b) => a - b)[wins.length >> 1] || 1e-15;
    let t = 0, worst = 0, seams = 0;
    for (const d of durs.slice(0, -1)) {
      t += d;
      const c = Math.round(t * 48000);
      if (c - 256 > skip && c + 256 < n) { seams++; worst = Math.max(worst, sum(e, c - 256, c + 256) / 512 / median); }
    }
    ok(snr > 50 && seams === durs.length - 1 && worst < 4,
      `${label} → AC-3：SNR ${snr.toFixed(1)} dB（零偏移对齐），${seams} 个接缝处误差 / 中位误差 最大 ${worst.toFixed(2)}`);
  }
}

if (H.audioTx.worker) {
  console.log('\n■ 转码 Worker 走公网地址（AUDIO_TX_URL + AUDIO_TX_KEY，不用 Service Binding）');
  const b = `/hls/${H.token('/Movies/hdr10_multi.mkv')}/`;
  const m = await (await H.call(b + 'master.m3u8')).text();
  const u4 = new RegExp('URI="([^"]*t4\\.m3u8)"').exec(m)[1];
  const seg = b + u4.replace(/[^/]+$/, '') + 't4/1.m4s';
  const ref = Buffer.from(await (await H.call(seg)).arrayBuffer());           // Service Binding 转出来的那份
  const bound = H.env.AUDIO_TX;
  delete H.env.AUDIO_TX;
  H.env.AUDIO_TX_URL = 'https://audio.test/'; H.env.AUDIO_TX_KEY = 'k-test-123';
  H.audioTx.key = 'k-test-123'; H.audioTx.calls = 0;
  caches.default.m.clear();                                                    // 清掉边缘缓存：这次必须真的去转
  const got = await H.call(seg);
  const viaUrl = Buffer.from(await got.arrayBuffer());
  ok(got.status === 200 && H.audioTx.calls > 0 && viaUrl.length > 1000 && viaUrl.equals(ref),
    `经公网地址转码：输出与 Service Binding 逐字节一致（${viaUrl.length} 字节，${H.audioTx.calls} 次调用）`);
  const health = async () => (await H.call('/health')).text();
  ok(/DTS \/ TrueHD<\/span><span>✅ 经 audio\.test，转码 Worker 在线，密钥一致/.test(await health()), '健康页：经 audio.test、在线、密钥一致');
  H.audioTx.key = 'another-key'; caches.default.m.clear();
  const bad = await H.call(seg);
  ok(bad.status === 502 && /密钥不对/.test(await health()), `两边密钥不一样：转码分段失败（${bad.status}），健康页直说「密钥不对」`);
  H.audioTx.key = '';
  ok(/没配 AUDIO_TX_KEY/.test(await health()), '转码 Worker 没配密钥：健康页提醒公网地址谁都能调');
  delete H.env.AUDIO_TX_KEY;
  H.audioTx.key = 'k-test-123';
  ok(/密钥不对/.test(await health()), '主 Worker 没带密钥、转码 Worker 要密钥：一样报「密钥不对」');
  H.env.AUDIO_TX = bound; delete H.env.AUDIO_TX_URL; H.audioTx.key = '';
}

console.log(`\n${fail ? '✗' : '✓'} ${pass} 通过，${fail} 失败`);
process.exit(fail ? 1 : 0);
