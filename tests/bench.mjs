// 性能基准：node tests/bench.mjs [样片…]
// 用真实 Worker 代码（../Stream_v25.js，模拟 Dropbox 读本地样片）把一部片的每一段 HLS 都切一遍：
// 索引（主列表）、视频 / 音频分段、内封字幕分段，量进程 CPU 时间、输出字节与每段耗时。
// 只量 Worker 这一侧的活（解析 EBML、拼 fMP4、杜比视界转换、字幕），回源是本地文件，网络不计。
// BENCH_REPEAT=3 重复几遍取最好的一遍（冷缓存：每遍都清缓存）。
import fs from 'node:fs';
import path from 'node:path';
import * as H from './harness.mjs';

H.env.HLS_PREFETCH = '0';                 // 不预取：只量请求本身
const files = process.argv.slice(2).length ? process.argv.slice(2) : ['hdr10_multi.mkv', 'dv7.mkv', 'avc_zsub.mkv', 'subscan.mkv'];
const repeat = Math.max(1, +process.env.BENCH_REPEAT || 1);
const cpu = () => { const u = process.cpuUsage(); return (u.user + u.system) / 1000; };
const settle = async () => { while (H.pending.length) await Promise.all(H.pending.splice(0)); };
const drain = async r => { let n = 0; if (r.body) for await (const c of r.body) n += c.length; return n; };

async function once(file) {
  await settle(); caches.default.m.clear();
  const base = `/hls/${H.token('/Movies/' + file)}/`;
  const t0 = cpu(), w0 = performance.now();
  const master = await (await H.call(base + 'master.m3u8')).text();
  await settle();
  const tIdx = cpu() - t0;
  const uris = [...master.matchAll(/URI="([^"]+)"/g)].map(m => m[1]).concat(master.split('\n').filter(l => l && !l.startsWith('#')));
  const kinds = { v: [0, 0, 0], a: [0, 0, 0], s: [0, 0, 0] };   // [段数, 字节, CPU ms]
  for (const u of [...new Set(uris)]) {
    const pl = await (await H.call(base + u)).text();
    const dir = u.replace(/[^/]+$/, '');
    const name = u.split('/').pop();
    const kind = /^v/.test(name) ? 'v' : /^[at]\d/.test(name) ? 'a' : /^[sxo]\d/.test(name) ? 's' : null;
    if (!kind) continue;
    const map = /#EXT-X-MAP:URI="([^"]+)"/.exec(pl);
    if (map) await drain(await H.call(base + dir + map[1]));
    for (const seg of pl.split('\n').filter(l => l && !l.startsWith('#'))) {
      const c0 = cpu();
      const n = await drain(await H.call(base + dir + seg));
      await settle();
      const k = kinds[kind]; k[0]++; k[1] += n; k[2] += cpu() - c0;
    }
  }
  return { tIdx, kinds, cpu: cpu() - t0, wall: performance.now() - w0 };
}

const rows = [];
for (const f of files) {
  if (!fs.existsSync(path.join(H.SAMPLES, f))) { console.log('跳过（没有样片）：', f); continue; }
  let best = null;
  for (let i = 0; i < repeat; i++) { const r = await once(f); if (!best || r.cpu < best.cpu) best = r; }
  const { kinds: K } = best;
  const mb = K.v[1] / 1048576;
  rows.push(f);
  console.log(`${f}\n  索引 ${best.tIdx.toFixed(1)} ms · 视频 ${K.v[0]} 段 ${mb.toFixed(1)} MB，CPU ${K.v[2].toFixed(1)} ms（每段 ${(K.v[2] / Math.max(1, K.v[0])).toFixed(2)} ms，${(mb / (K.v[2] / 1000)).toFixed(0)} MB/s）` +
    ` · 音频 ${K.a[0]} 段 CPU ${K.a[2].toFixed(1)} ms · 字幕 ${K.s[0]} 段 CPU ${K.s[2].toFixed(1)} ms · 合计 CPU ${best.cpu.toFixed(0)} ms / 墙钟 ${best.wall.toFixed(0)} ms`);
}
process.exit(0);
