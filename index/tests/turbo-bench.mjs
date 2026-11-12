// 极限模式 vs 普通模式：同一个论坛、同样的网络延迟，比墙钟时间。
//   node index/tests/turbo-bench.mjs [每年部数=150] [论坛每页 ms=450] [TMDB 每次 ms=160] [R2 每次 ms=25]
// 模拟的东西：
//   · 论坛、TMDB、R2 的往返延迟（±30% 抖动）；
//   · Cloudflare「每次调用最多 6 条同时打开的出站连接」—— 用 AsyncLocalStorage 给每次调用记账，超出的排队；
//   · Worker 自己的等待是真的（限速间隔 260 / 160ms、轮间间隔、R2 写入间隔）；
//   · 浏览器那一侧：普通模式照 runBuild 的节奏（每轮之间歇 260ms），极限模式跑的是页面里那一份 turboRun。
// 不模拟的：Free 计划的 CPU 上限（10ms 量级，测不出来）、论坛真实的限速阈值。
import fs from 'node:fs';
import vm from 'node:vm';
import { AsyncLocalStorage } from 'node:async_hooks';
import * as H from './harness.mjs';

const PER_YEAR = +process.argv[2] || 150, FMS = +process.argv[3] || 450, TMS = +process.argv[4] || 160, RMS = process.argv[5] != null ? +process.argv[5] : 25;
const sleep = (ms) => new Promise(r => setTimeout(r, ms));
const jit = (ms) => ms * (0.7 + Math.random() * 0.6);
const als = new AsyncLocalStorage();

/* 片名：两三个汉字 + 两个英文词，保证互不相同、不带数字（数字会被当成续集号 / 年份） */
const HAN = '星海山河风云月光夜雨雪花火林城桥塔湖岛龙虎鹰狼梦影歌舞剑侠春秋金银铁石'.split('');
const EN = ['Alpha', 'Bravo', 'Cedar', 'Delta', 'Ember', 'Falcon', 'Garnet', 'Harbor', 'Ivory', 'Juniper', 'Kestrel', 'Lumen', 'Marble', 'Nimbus', 'Onyx', 'Prairie', 'Quartz', 'Raven', 'Summit', 'Tundra'];
function makeWorld() {
  const e = H.makeEnv();
  const { W } = e;
  W.forum.perPage = 30;
  let tid = 100000, id = 600000, n = 0;
  const RES = ['2160p', '1080p', '720p', '1080p'], SRC = ['WEB-DL', 'BluRay', 'REMUX', 'WEBRip'];
  for (const [y, yid] of [[2025, 32], [2024, 31]]) {
    const list = [];
    for (let f = 0; f < PER_YEAR; f++, n++) {
      const cn = HAN[n % HAN.length] + HAN[Math.floor(n / HAN.length) % HAN.length] + HAN[(n * 7 + 3) % HAN.length];
      const en = EN[n % EN.length] + ' ' + EN[Math.floor(n / EN.length) % EN.length] + ' ' + EN[(n * 3 + 1) % EN.length];
      W.tmdb.movie.push({ id: id, title: cn, original_title: en, release_date: y + '-05-01', poster_path: '/p' + id + '.jpg', popularity: 40, vote_average: 7, vote_count: 500 });
      const vers = 1 + (f % 4);
      for (let v = 0; v < vers; v++) list.push({ tid: tid++, title: `${cn} ${en.replace(/ /g, '.')}.${y}.${RES[v]}.${SRC[v]}.x265 ${8 + v}.5GB`, film: id });
      id++;
    }
    for (let u = 0; u < 6; u++) list.push({ tid: tid++, title: `无此片${y}${'甲乙丙丁戊己'[u]} Nonexistent.Film.${y}.1080p.WEB-DL 4GB`, film: null });
    W.forum.boards['44'] = W.forum.boards['44'] || {};
    W.forum.boards['44']['movie_nianfen=' + yid] = list.reverse();
  }
  /* 每次调用最多 6 条连接 + 往返延迟 */
  const sem = new Map();
  const slot = async () => {
    const k = als.getStore() || 0;
    let s = sem.get(k); if (!s) sem.set(k, s = { n: 0, q: [] });
    if (s.n >= 6) await new Promise(r => s.q.push(r));
    s.n++;
    return () => { s.n--; const nx = s.q.shift(); if (nx) nx(); };
  };
  const lag = (ms) => async () => { const rel = await slot(); await sleep(jit(ms)); rel(); return null; };
  W.forum.fail = lag(FMS);
  W.tmdb.fail = lag(TMS);
  if (RMS > 0) for (const m of ['get', 'put', 'delete', 'list']) {
    const f = e.r2[m].bind(e.r2);
    e.r2[m] = async (...a) => { await sleep(jit(RMS)); return f(...a); };
  }
  return e;
}

let inv = 0;
function caller(I) {
  return async (u, o = {}) => {
    const res = await als.run(++inv, () => I.call(u, { method: o.method || 'GET', headers: o.body ? { 'content-type': 'application/json' } : {}, ...(o.body ? { body: o.body } : {}) }));
    const j = await res.json().catch(() => null);
    if (!res.ok) { const e = new Error((j && j.error) || 'HTTP ' + res.status); e.status = res.status; e.data = j || {}; throw e; }
    return j;
  };
}

/* IDX_BASE_WORKER=旧版 worker.js：普通模式那一栏换成旧版跑（例如合并前的 v6.1），看总提速 */
async function runNormal() {
  const e = makeWorld();
  const I = H.isolate(e.env, e.W, { realTime: true, ...(process.env.IDX_BASE_WORKER ? { file: process.env.IDX_BASE_WORKER } : {}) });
  const api = caller(I);
  const t0 = Date.now();
  let rounds = 0, r;
  for (; rounds < 2000; rounds++) {
    try { r = await api('/api/build'); }
    catch (x) { if (x.data && x.data.busy) { await sleep(1000); continue; } throw x; }
    if (r.done) break;
    await sleep(r.rateHit ? 4000 : 260);
  }
  await I.settle();
  return { mode: process.env.IDX_BASE_WORKER ? '旧版普通模式' : '普通模式', ms: Date.now() - t0, rounds: rounds + 1, tm: 0, e };
}

async function runTurbo() {
  const e = makeWorld();
  const I = H.isolate(e.env, e.W, { realTime: true });
  const src = /\/\*<turbo>\*\/([\s\S]*?)\/\*<\/turbo>\*\//.exec(fs.readFileSync(H.SRC_FILE, 'utf8'))[1];
  const c = vm.createContext({ JSON, Object, Math, Array, String, Number });
  vm.runInContext(src + '\n;globalThis.__t = turboRun;', c);
  const base = caller(I);
  let tm = 0;
  const api = (u, o) => { if (u.startsWith('/api/tm')) tm++; return base(u, o); };
  const t0 = Date.now();
  const out = await new Promise(resolve => c.__t({
    api, later: (fn, ms) => setTimeout(fn, ms), stopped: () => false,
    progress: () => {}, done: (msg, bad, st) => resolve({ msg, bad, st }),
  }));
  await I.settle();
  return { mode: '极限模式', ms: Date.now() - t0, rounds: out.st.rounds, tm, e, msg: out.msg, maxK: out.st.K };
}

console.log(`论坛：2 年 × ${PER_YEAR} 部（每部 1–4 个版本，每页 30 帖）· 延迟：论坛 ${FMS}ms · TMDB ${TMS}ms · R2 ${RMS}ms（±30%）· 每次调用 6 条连接`);
const rows = [];
for (const fn of [runNormal, runTurbo]) {
  const r = await fn();
  const mv = r.e.r2.json('idx/v4/movies.json');
  const st = r.e.r2.json('idx/v4/state.json');
  rows.push({ ...r, movies: Object.keys(mv.m).length, rels: st.rels, forum: r.e.W.forum.calls, tmdb: r.e.W.tmdb.calls });
  const x = rows[rows.length - 1];
  console.log(`  ${x.mode}：${(x.ms / 1000).toFixed(1)}s · ${x.rounds} 轮扫描${x.tm ? ' · 认定工 ' + x.tm + ' 次' : ''} · 论坛请求 ${x.forum} · TMDB 请求 ${x.tmdb} · ${x.movies} 部 / ${x.rels} 个片源${x.msg ? ' · ' + x.msg : ''}`);
}
const [a, b] = rows;
console.log(`\n极限模式快 ${(a.ms / b.ms).toFixed(1)} 倍（${(a.ms / 1000).toFixed(1)}s → ${(b.ms / 1000).toFixed(1)}s）；两边建出来的影片 ${a.movies === b.movies ? '一样多' : '不一样多！'}（${a.movies} / ${b.movies}）`);
process.exit(0);
