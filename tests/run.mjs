// 回归测试：node tests/run.mjs（先跑一次 tests/make-samples.sh 生成样片）
import fs from 'node:fs';
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
