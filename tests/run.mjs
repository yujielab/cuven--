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
  await H.bindAudioTx();
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

console.log(`\n${fail ? '✗' : '✓'} ${pass} 通过，${fail} 失败`);
process.exit(fail ? 1 : 0);
