// 真 workerd 冒烟测试（wrangler dev --local）：node index/tests/workerd.mjs
// 本地起一个 HTTP 服务假扮论坛 / TMDB / 总账，Worker 跑在真的 workerd 里（R2、KV 是 miniflare 的本地实现），
// 验证 Node vm 测不到的那部分：R2 的条件写 / list / 批量删除、GBK 解码、String.raw 页面、定时任务入口。
import http from 'node:http';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import * as H from './harness.mjs';

let pass = 0, fail = 0;
const ok = (c, m) => { if (c) { pass++; console.log('  ✓', m); } else { fail++; console.log('  ✗', m); } };

const W = H.world();
const MP = 18400 + Math.floor(Math.random() * 500), WP = MP + 1;
W.forum.base = `http://127.0.0.1:${MP}/forum/`;
W.recv.base = `http://127.0.0.1:${MP}`;
for (let i = 0; i < 12; i++) {
  W.tmdb.movie.push({ id: 300 + i, title: '测试影片' + '甲乙丙丁戊己庚辛壬癸子丑'[i], original_title: 'Test Film ' + String.fromCharCode(65 + i), release_date: '2025-03-01', vote_count: 800, vote_average: 7, poster_path: '/t.jpg', popularity: 30 });
}
W.forum.boards['44'] = { 'movie_nianfen=32': W.tmdb.movie.flatMap((m, i) => [0, 1].map(v => ({ tid: 7000 + i * 2 + v, title: `${m.title} ${m.original_title.replace(/ /g, '.')}.2025.${v ? '1080p' : '2160p'}.WEB-DL.x265 ${8 + v}.5GB` }))) };
W.forum.threads[7000] = { attach: [{ aid: 'T1', name: 'a.torrent', bytes: H.torrent({ name: 'a.mkv', length: 9, 'piece length': 16384, pieces: Buffer.alloc(20) }).bytes }] };
W.recv.meta = { gen: 'w1' };
W.recv.doc = { gen: 'w1', items: [
  { key: 'a', kind: 'movie', name: 'x.mkv', tmdb: 300, type: 'movie', title: '测试影片甲', orig: 'Test Film A', year: '2025' },
  { key: 'b', kind: 'movie', name: '測試影片乙.2025.mkv', guess: '測試影片乙', guessZh: '測試影片乙', guessYear: '2025' },
] };

const srv = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://127.0.0.1:${MP}`);
  const r = await H.worldFetch(W, url).catch(e => new Response(String(e), { status: 500 }));
  if (!r) { res.writeHead(404); res.end(); return; }
  const headers = {};
  r.headers.forEach((v, k) => { if (k !== 'set-cookie') headers[k] = v; });
  const sc = r.headers.getSetCookie ? r.headers.getSetCookie() : [];
  if (sc.length) headers['set-cookie'] = sc;
  res.writeHead(r.status, headers);
  res.end(Buffer.from(await r.arrayBuffer()));
});
await new Promise(r => srv.listen(MP, '127.0.0.1', r));

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'idx-workerd-'));
fs.copyFileSync(H.SRC_FILE, path.join(dir, 'worker.js'));
fs.writeFileSync(path.join(dir, 'wrangler.toml'), `name = "idx-smoke"
main = "worker.js"
compatibility_date = "2024-09-23"
[[r2_buckets]]
binding = "R2"
bucket_name = "idx-smoke"
[[kv_namespaces]]
binding = "KV"
id = "idxsmoke"
[vars]
SITE_BASE = "${W.forum.base}"
TMDB_BASE = "http://127.0.0.1:${MP}/3"
RECV_BASE = "http://127.0.0.1:${MP}"
SITE_USER = "u"
SITE_PASS = "p"
TMDB_KEY = "k"
`);
const wr = spawn('npx', ['--yes', 'wrangler@3.114.0', 'dev', '--local', '--port', String(WP), '--ip', '127.0.0.1', '--test-scheduled', '--persist-to', path.join(dir, 'state')],
  { cwd: dir, env: { ...process.env, NO_D1_WARNING: 'true', WRANGLER_SEND_METRICS: 'false', CI: '1' } });
let log = '';
wr.stdout.on('data', d => { log += d; }); wr.stderr.on('data', d => { log += d; });
const up = await (async () => { for (let i = 0; i < 240; i++) { if (/Ready on/.test(log)) return true; await new Promise(r => setTimeout(r, 500)); } return false; })();
const base = `http://127.0.0.1:${WP}`;
const get = (p, init) => fetch(base + p, init);
try {
  ok(up, 'wrangler dev 起来了（真 workerd）' + (up ? '' : '：' + log.slice(-400)));
  if (up) {
    const page = await get('/');
    const html = await page.text();
    ok(page.status === 200 && /<script/.test(html) && html.length > 100000, `首页 ${html.length} 字节（String.raw 页面在 workerd 里拼得出来）`);
    let r, n = 0;
    for (; n < 30; n++) { r = await (await get('/api/build')).json(); if (r.error || r.done) break; }
    ok(r && r.done && !r.error && r.movies === 12, `建索引 ${n + 1} 轮跑完：${r && (r.error || r.movies + ' 部 · ' + r.rels + ' 个片源')}`);
    const st = await (await get('/api/state')).json();
    ok(st.movies === 12 && !st.busy, '状态接口：12 部、锁已释放（R2 条件写在真 R2 实现里生效）');
    await (await get('/api/lib?refresh=1')).json();
    const cat = await (await get('/api/catalog?min=0&own=all')).json();
    const own = Object.fromEntries((cat.items || []).map(x => [x.id, x.own]));
    ok(cat.total === 12 && own[300] === 2 && own[301] === 1 && !own[302], `缺片检测：id 相同的判确定、繁体文件名的判疑似、没有的显示缺片（${JSON.stringify(cat.lib && cat.lib.match)}）`);
    const det = await (await get('/api/detail?id=300')).json();
    ok(det.items && det.items.length === 2, '详情：两个版本');
    const fx = await (await get('/api/fetch', { method: 'POST', body: JSON.stringify({ items: [{ tid: 7000, name: 'a' }] }) })).json();
    ok(fx.items && fx.items[0].ok && fx.items[0].kind === 'torrent', '取件：GBK 帖子页解析 + 种子校验');
    const bk = await (await get('/api/repair?do=backup')).json();
    ok(bk.ok && bk.files === 3, '手动备份：' + (bk.msg || bk.error));
    const dg = await (await get('/api/diagnose')).json();
    ok(dg.checks && !dg.checks.some(c => c.level === 'fail'), `体检：${dg.verdict}`);
    /* 极限模式：重置 2025 年，用页面里那一份调度代码（<turbo> 标记之间）在真 workerd 里重建 ——
       认定工的 Object.create(env)、POST 正文、并发的 /api/tm 都在真运行时里走一遍 */
    const rs = await (await get('/api/reset?year=2025')).json();
    const src = /\/\*<turbo>\*\/([\s\S]*?)\/\*<\/turbo>\*\//.exec(fs.readFileSync(H.SRC_FILE, 'utf8'))[1];
    const turboRun = new Function(src + '\n;return turboRun;')();
    let tmN = 0;
    const api = async (u, o = {}) => {
      if (u.startsWith('/api/tm')) tmN++;
      const res = await get(u, { method: o.method || 'GET', headers: o.body ? { 'content-type': 'application/json' } : {}, body: o.body });
      const j = await res.json().catch(() => null);
      if (!res.ok) { const e = new Error((j && j.error) || 'HTTP ' + res.status); e.status = res.status; e.data = j || {}; throw e; }
      return j;
    };
    const t = await new Promise(resolve => turboRun({ api, later: (fn, ms) => setTimeout(fn, Math.min(ms, 300)), stopped: () => false, done: (msg, bad) => resolve({ msg, bad }) }));
    const st2 = await (await get('/api/state')).json();
    ok(rs.dropped === 12 && t.msg === '完成' && st2.movies === 12 && tmN > 0 && st2.pend && !st2.pend.wait,
      `极限模式在真 workerd 里重建 2025 年：${t.msg} · ${st2.movies} 部 · 认定工调用 ${tmN} 次 · 排队 ${st2.pend ? st2.pend.wait : '?'}`);
    const sc = await get('/__scheduled?cron=0+20+*+*+*');
    ok(sc.status === 200, '定时任务入口跑通');
  }
} finally {
  wr.kill('SIGTERM');
  srv.close();
  setTimeout(() => process.exit(fail ? 1 : 0), 300);
}
console.log(`\n${fail ? '✗' : '✓'} ${pass} 通过，${fail} 失败`);
