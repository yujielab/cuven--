// 索引库 Worker 回归测试：node index/tests/run.mjs
// 不需要网络、不需要样片：论坛 / TMDB / 总账 / R2 / KV 全部在 harness.mjs 里模拟。
import fs from 'node:fs';
import vm from 'node:vm';
import zlib from 'node:zlib';
import crypto from 'node:crypto';
import { execFileSync } from 'node:child_process';
import * as H from './harness.mjs';
import { score } from './match-score.mjs';
import { evaluate } from './match-synth.mjs';

let pass = 0, fail = 0;
/* v5.4 原版：从 git 里取（升级测试用） */
if (!process.env.IDX_OLD_WORKER) {
  try {
    const src = execFileSync('git', ['show', 'bcc6211:index/worker.js'], { cwd: new URL('..', import.meta.url).pathname, maxBuffer: 1 << 26 }).toString();
    fs.mkdirSync('/tmp/idx-test', { recursive: true });
    fs.writeFileSync('/tmp/idx-test/worker-v54.js', src);
    process.env.IDX_OLD_WORKER = '/tmp/idx-test/worker-v54.js';
  } catch {}
}
/* v6.3 原版：「剧集版块是 UTF-8」那项用它造一份乱码索引 */
if (!process.env.IDX_V63_WORKER) {
  try {
    const src = execFileSync('git', ['show', '4d11bdc:index/worker.js'], { cwd: new URL('..', import.meta.url).pathname, maxBuffer: 1 << 26 }).toString();
    fs.mkdirSync('/tmp/idx-test', { recursive: true });
    fs.writeFileSync('/tmp/idx-test/worker-v63.js', src);
    process.env.IDX_V63_WORKER = '/tmp/idx-test/worker-v63.js';
  } catch {}
}
/* v6.1 原版（合并前的 main）：「补回旧版漏掉的帖子」那项用 */
if (!process.env.IDX_V61_WORKER) {
  try {
    const src = execFileSync('git', ['show', '182e7b4:index/worker.js'], { cwd: new URL('..', import.meta.url).pathname, maxBuffer: 1 << 26 }).toString();
    fs.mkdirSync('/tmp/idx-test', { recursive: true });
    fs.writeFileSync('/tmp/idx-test/worker-v61.js', src);
    process.env.IDX_V61_WORKER = '/tmp/idx-test/worker-v61.js';
  } catch {}
}
const ok = (cond, msg) => { if (cond) { pass++; console.log('  ✓', msg); } else { fail++; console.log('  ✗', msg); } };
const NS = 'idx/v4/';
const LOCK_MS = 40000;

/* ── 一个小论坛：两年的帖子，若干部片，每部几个版本；另有 TMDB 查不到的帖子 ── */
const RES = ['2160p', '1080p', '720p'], SRCS = ['WEB-DL', 'BluRay', 'REMUX'], COD = ['HEVC', 'x264'];
function makeForum(W, opt = {}) {
  const films = [];
  const CN = ['沙丘', '星际穿越', '盗梦空间', '奥本海默', '芭比', '寄生虫', '小丑', '蝙蝠侠', '流浪地球', '满江红', '封神', '长安三万里', '孤注一掷', '消失的她', '热辣滚烫', '飞驰人生', '第二十条', '周处除三害', '年会不能停', '坚如磐石', '涉过愤怒的海', '巨齿鲨', '变形金刚', '碟中谍', '速度与激情', '银河护卫队', '蜘蛛侠', '闪电侠', '海王', '惊奇队长'];
  const EN = ['Dune', 'Interstellar', 'Inception', 'Oppenheimer', 'Barbie', 'Parasite', 'Joker', 'Batman', 'The Wandering Earth', 'Full River Red', 'Creation of the Gods', 'Chang An', 'No More Bets', 'Lost in the Stars', 'YOLO', 'Pegasus', 'Article 20', 'The Pig the Snake and the Pigeon', 'Johnny Keep Walking', 'Under the Light', 'Across the Furious Sea', 'Meg', 'Transformers', 'Mission Impossible', 'Fast X', 'Guardians of the Galaxy', 'Spider Man', 'The Flash', 'Aquaman', 'The Marvels'];
  let tid = 10000, id = 500000;
  const years = { 2025: 32, 2024: 31 };
  for (const [y, yid] of Object.entries(years)) {
    const list = [];
    const n = opt.films || 15;
    for (let f = 0; f < n; f++) {
      const k = (f + (y === '2024' ? 15 : 0)) % CN.length;
      const film = { id: id++, cn: CN[k] + (y === '2024' ? '' : ''), en: EN[k], y: +y };
      films.push(film);
      W.tmdb.movie.push({ id: film.id, title: film.cn, original_title: film.en, release_date: y + '-05-01', poster_path: '/p' + film.id + '.jpg', popularity: 50, vote_average: 7.2, vote_count: 900 });
      const vers = 1 + (f % 4);
      for (let v = 0; v < vers; v++) list.push({ tid: tid++, title: `${film.cn} ${film.en.replace(/ /g, '.')}.${y}.${RES[v % 3]}.${SRCS[v % 3]}.${COD[v % 2]} ${10 + v * 7}.${v}GB`, film: film.id });
    }
    /* TMDB 查不到的帖子：留底队列 */
    for (let u = 0; u < (opt.unmatched ?? 3); u++) list.push({ tid: tid++, title: `无此片${y}${u} Nonexistent.Film.${u}.${y}.1080p.WEB-DL.x264 5.${u}GB`, film: null });
    W.forum.boards['44'] = W.forum.boards['44'] || {};
    W.forum.boards['44']['movie_nianfen=' + yid] = list.reverse();
  }
  return films;
}
/* 片名互不相同的论坛（makeForum 里两年的片同名同原名、共用一个键，数「部数」时用这个） */
function makeForumU(W, perYear) {
  const HAN = '星海山河风云月光夜雨雪花火林城桥塔湖岛龙虎鹰狼梦影歌舞剑侠春秋金银铁石'.split('');
  const EN = ['Alpha', 'Bravo', 'Cedar', 'Delta', 'Ember', 'Falcon', 'Garnet', 'Harbor', 'Ivory', 'Juniper', 'Kestrel', 'Lumen', 'Marble', 'Nimbus', 'Onyx', 'Prairie', 'Quartz', 'Raven', 'Summit', 'Tundra'];
  let tid = 30000, id = 700000, n = 0;
  for (const [y, yid] of [[2025, 32], [2024, 31]]) {
    const list = [];
    for (let f = 0; f < perYear; f++, n++, id++) {
      const cn = HAN[n % HAN.length] + HAN[Math.floor(n / HAN.length) % HAN.length] + HAN[(n * 7 + 3) % HAN.length];
      const en = EN[n % EN.length] + ' ' + EN[Math.floor(n / EN.length) % EN.length] + ' ' + EN[(n * 3 + 1) % EN.length];
      W.tmdb.movie.push({ id, title: cn, original_title: en, release_date: y + '-05-01', poster_path: '/p' + id + '.jpg', popularity: 40, vote_average: 7, vote_count: 500 });
      for (let v = 0; v < 1 + (f % 4); v++) list.push({ tid: tid++, title: `${cn} ${en.replace(/ /g, '.')}.${y}.${RES[v % 3]}.${SRCS[v % 3]}.x265 ${8 + v}.5GB`, film: id });
    }
    W.forum.boards['44'] = W.forum.boards['44'] || {};
    W.forum.boards['44']['movie_nianfen=' + yid] = list.reverse();
  }
}
const allPosts = (W) => Object.values(W.forum.boards['44'] || {}).flat();

/** 索引的不变量：每个帖子只出现一次；认得出的都在分片里，认不出的都在留底队列里；计数对得上 */
function verify(X, r2, W, label, opt = {}) {
  const state = r2.json(NS + 'state.json'), movies = r2.json(NS + 'movies.json');
  const pend = r2.json('idx/v5/pending.json') || { q: {} };
  const errs = [];
  if (!state || !movies) { ok(false, label + '：索引文件不全'); return; }
  if (movies.cid !== state.cid) errs.push('提交号不一致 movies=' + movies.cid + ' state=' + state.cid);
  if (state.lock) errs.push('锁没放');
  const seen = new Map(), rowsBy = new Map();
  for (const [y, st] of Object.entries(state.years || {})) {
    const pn = st.pn || [], pg = st.pg || [];
    const ytids = new Set();
    for (let i = 0; i < pn.length; i++) {
      const key = NS + 'y' + y + (i ? '.p' + i : '') + (pg[i] ? '.g' + pg[i] : '') + '.json';
      const sh = r2.json(key);
      if (!sh) { errs.push('缺分片 ' + key); continue; }
      const g = X.decodeShard(sh);
      let n = 0;
      for (const [id, rows] of Object.entries(g)) for (const r of rows) {
        n++;
        if (seen.has(r.tid)) errs.push('重复的帖子 ' + r.tid + '（' + seen.get(r.tid) + ' 与 ' + key + '）');
        seen.set(r.tid, key); ytids.add(r.tid);
        rowsBy.set(id, (rowsBy.get(id) || 0) + 1);
        const mv = movies.m[id];
        if (!mv) errs.push('分片里有影片表没有的片 ' + id);
        else if (!(mv[13] && mv[13][y] && mv[13][y].includes(i))) errs.push('影片 ' + id + ' 的 SP 没记 ' + y + '#' + i);
      }
      if (n !== pn[i]) errs.push(y + '#' + i + ' 片表记 ' + pn[i] + ' 行，实际 ' + n);
    }
    if (pn.length) {
      const tk = NS + 'y' + y + '.t' + (st.tg ? '.g' + st.tg : '') + '.json';
      const t = r2.json(tk);
      if (!t) errs.push('缺 tid 表 ' + tk);
      else {
        const s = X.tidsParse(t);
        for (const x of ytids) if (!s.has(x)) { errs.push(y + ' 年 tid 表漏了 ' + x); break; }
      }
    }
  }
  const pendT = new Set(Object.values(pend.q).flatMap(e => e.r.map(r => r[0])));
  let lost = 0;
  for (const p of allPosts(W)) {
    if (p.film) { if (!seen.has(p.tid)) lost++; }
    else if (!pendT.has(p.tid) && !seen.has(p.tid)) lost++;
  }
  if (lost && !opt.partial) errs.push('丢了 ' + lost + ' 个帖子');
  if (!opt.skipCounts) for (const [id, mv] of Object.entries(movies.m)) if ((mv[8] || 0) !== (rowsBy.get(id) || 0)) { errs.push('影片 ' + id + ' 计数 ' + mv[8] + '，分片里 ' + (rowsBy.get(id) || 0)); break; }
  ok(!errs.length, label + (errs.length ? '：' + errs.slice(0, 4).join('；') : `：${seen.size} 个帖子各只出现一次，认不出的 ${pendT.size} 个都在留底队列，计数与分片一致`));
  return { posts: seen.size, pend: pendT.size };
}
async function buildAll(I, max = 400) {
  let r, n = 0, busy = 0;
  for (; n < max; n++) {
    const res = await I.call('/api/build');
    r = await res.json();
    if (res.status === 409) { busy++; if (busy > 30) break; I.clock.off += LOCK_MS + 1000; continue; }
    if (r.error) return { err: r.error, r, n };
    if (r.done) break;
  }
  await I.settle();
  return { r, n };
}

// 极限模式：从 worker.js 的页面里抽出浏览器端的调度代码（<turbo> 标记之间那一段），对着真 Worker 跑
let TURBO_SRC = null;
function turboRunFn() {
  if (!TURBO_SRC) TURBO_SRC = /\/\*<turbo>\*\/([\s\S]*?)\/\*<\/turbo>\*\//.exec(fs.readFileSync(H.SRC_FILE, 'utf8'))[1];
  const c = vm.createContext({ JSON, Object, Math, Array, String, Number });
  vm.runInContext(TURBO_SRC + '\n;globalThis.__turboRun = turboRun;', c);
  return c.__turboRun;
}
async function turboAll(I, opt = {}) {
  const run = turboRunFn();
  let act = 0, maxAct = 0, tm = 0, maxSub = 0;
  const rounds = [];
  const api = async (u, o = {}) => {
    const isTm = u.startsWith('/api/tm');
    if (isTm) { tm++; act++; maxAct = Math.max(maxAct, act); }
    try {
      if (isTm && opt.tmFail) { const f = opt.tmFail(); if (f) throw f; }
      const uu = opt.src ? u + (u.includes('?') ? '&' : '?') + 'src=' + opt.src : u;
      const res = await I.call(uu, { method: o.method || 'GET', headers: o.body ? { 'content-type': 'application/json' } : {}, ...(o.body ? { body: o.body } : {}) });
      const j = await res.json().catch(() => null);
      if (!res.ok) { const e = new Error((j && j.error) || ('HTTP ' + res.status)); e.status = res.status; e.data = j || {}; throw e; }
      if (isTm && j) maxSub = Math.max(maxSub, j.sub || 0);
      return j;
    } finally { if (isTm) act--; }
  };
  const out = await new Promise((resolve) => {
    run({
      api, now: () => Date.now(), later: (fn, ms) => setTimeout(fn, Math.min(ms || 0, opt.maxDelay ?? 2)),
      stopped: opt.stopped || (() => false), say: () => {},
      progress: (r) => { rounds.push(r); if (opt.snap) opt.snap(r); },
      done: (msg, bad, st) => resolve({ msg, bad, st, rounds, tm, maxAct, maxSub }),
    });
  });
  await I.settle();
  return out;
}

console.log('\n■ MFX 编解码：随机标题逐字节还原');
{
  const { env, W } = H.makeEnv();
  const I = H.isolate(env, W);
  const X = I.c;
  const R = (() => { let x = 7; return () => (x = (x * 1103515245 + 12345) >>> 0) / 4294967296; })();
  const pool = ['沙丘', '星際穿越', 'Dune', '.', '2160p', 'WEB-DL', ' ', 'DDP5.1', '-', 'HDR10+', '杜比视界', 'ＦＵＬＬ', '😀', '𠀀', 'ä', '\u0000', '\t', '[', ']', '【', '】', 'x265', '中英字幕', '1080p', 'REMUX'];
  const titles = [];
  for (let i = 0; i < 3000; i++) { let t = ''; const n = 1 + Math.floor(R() * 14); for (let j = 0; j < n; j++) t += pool[Math.floor(R() * pool.length)]; titles.push(t); }
  const groups = {};
  titles.forEach((t, i) => { (groups[100 + (i % 97)] = groups[100 + (i % 97)] || []).push({ tid: 900000 + i * 3, title: t, spec: i % 50000, mb: (i * 37) % 90000, score: (i % 90) - 6 }); });
  const sh = X.encodeShard(2024, groups, null);
  const back = X.decodeShard(JSON.parse(JSON.stringify(sh)));
  ok(X.sameGroups(groups, back), `分片编解码：${titles.length} 条（含表情、生僻字、控制字符、全角）逐字段还原`);
  const kept = X.encodeShard(2024, groups, sh.d.slice());
  ok(X.sameGroups(groups, X.decodeShard(kept)), '拿老码本增量编码，解出来一样');
  const best = X.encodeBest(2024, groups, sh.d);
  ok(X.sameGroups(groups, X.decodeShard(best.sh)), '「两种编码取小」那条路解出来一样');
  const one = X.shardRows(sh, 150);
  ok(JSON.stringify(one) === JSON.stringify(back[150]), '只解一部片（shardRows）与整片解码一致');
  const set = new Set(); for (let i = 0; i < 5000; i++) set.add(1 + Math.floor(R() * 9e7));
  const tb = X.tidsBlob(set, set.size);
  const ts = X.tidsParse(JSON.parse(JSON.stringify(tb)));
  ok(ts.size === set.size && [...set].every(x => ts.has(x)), `tid 表：${set.size} 个随机帖子号往返一致`);
}

console.log('\n■ 片名比对键 canon');
{
  const { env, W } = H.makeEnv();
  const X = H.isolate(env, W).c;
  const eq = [['復仇者聯盟4：終局之戰', '复仇者联盟4：终局之战'], ['ＩＮＴＥＲＳＴＥＬＬＡＲ', 'Interstellar'], ['Amélie', 'Amelie'], ['Rocky II', 'Rocky 2'],
    ['The Batman', 'Batman'], ['沙丘：第二部', '沙丘2'], ['Dune: Part Two', 'Dune Part 2'], ['Fast & Furious', 'Fast and Furious'], ['你的名字。', '你的名字'], ['Ⅱ', 'II'], ['Straße', 'Strasse']];
  const bad = eq.filter(([a, b]) => X.canon(a) !== X.canon(b));
  ok(!bad.length, `${eq.length} 组写法折到同一个键（繁体、全角、重音、罗马数字、冠词、第二部 / Part Two、&）${bad.length ? '；没折上：' + bad.map(x => x.join('≠')).join(' | ') : ''}`);
  const ne = [['X-Men', 'X-Men 10'], ['V for Vendetta', '5 for Vendetta'], ['小丑', '小丑2'], ['기생충', '寄生虫']];
  const merged = ne.filter(([a, b]) => X.canon(a) === X.canon(b));
  ok(!merged.length, '不该折到一起的不折（X 战警、V 字仇杀队、续集、不同语言）' + (merged.length ? '：' + merged.map(x => x.join('=')).join(' | ') : ''));
}

console.log('\n■ 缺片检测：标准答案');
{
  const r = await score();
  for (const src of ['movie', 'tv']) {
    const x = r[src];
    ok(x.fp === 0 && x.fn === 0, `${src === 'movie' ? '电影' : '剧集'} ${x.ok}/${x.n} 判对（误藏 ${x.fp} · 漏判 ${x.fn}）${x.fp + x.fn ? '：' + x.rows.filter(z => z[5] !== '✓' && z[5] !== '·').map(z => z[1] + z[2] + z[5]).join('、') : ''}`);
  }
}

console.log('\n■ 缺片检测：大样本压测（重拍、同名、繁体、全角、缺年份、认错 id）');
{
  for (const [seed, n, kind, minP, minR] of [[1, 6000, 'movie', 0.99, 0.99], [2, 6000, 'movie', 0.99, 0.99], [3, 3000, 'tv', 0.985, 0.985]]) {
    const r = await evaluate(seed, n, kind);
    ok(r.precision >= minP && r.recall >= minR, `${kind === 'movie' ? '电影' : '剧集'} seed=${seed}：索引 ${r.index} · 片库 ${r.lib} · 误藏 ${r.fp} · 漏判 ${r.fn} · 精确率 ${(r.precision * 100).toFixed(2)}% · 召回率 ${(r.recall * 100).toFixed(2)}%`);
  }
}

console.log('\n■ 建索引端到端');
let snapMid = null, filmsE2E = null;
{
  const { env, r2, W } = H.makeEnv();
  filmsE2E = makeForum(W);
  const I = H.isolate(env, W);
  let mid = null;
  for (let i = 0; i < 200; i++) {
    const r = await (await I.call('/api/build')).json();
    if (r.error) { ok(false, '建索引报错：' + r.error); break; }
    if (!mid && (r.rels || 0) > 20) mid = r2.snapshot();
    if (r.done) break;
  }
  await I.settle();
  snapMid = mid;
  const v = verify(I.c, r2, W, '建完以后的不变量');
  const cat = await (await I.call('/api/catalog?min=0')).json();
  ok(cat.total === Object.keys(r2.json(NS + 'movies.json').m).length && cat.total > 0, `目录列出全部 ${cat.total} 部`);
  const det = await (await I.call('/api/detail?id=' + filmsE2E[3].id)).json();
  const posts = allPosts(W).filter(p => p.film === filmsE2E[3].id).length;
  ok(det.items && det.items.reduce((a, x) => a + (x.dupes || 1), 0) === posts, `详情：${filmsE2E[3].cn} 的 ${posts} 个版本都在`);
  const st = r2.json(NS + 'state.json');
  ok(Object.values(st.years).every(y => !y.pn || !y.pn.length || (Array.isArray(y.pg) && y.pg.length === y.pn.length && y.tg)), '片表带代号（pg / tg），分片与 tid 表都是 copy-on-write');
  void v;
  /* 再跑一轮增量：没有新帖就什么都不变 */
  const before = r2.json(NS + 'movies.json');
  const inc = await (await I.call('/api/incremental')).json();
  ok(inc.added === 0 && Object.keys(r2.json(NS + 'movies.json').m).length === Object.keys(before.m).length, '没有新帖时增量扫描不改任何东西');
  /* 论坛来了新帖 → 增量收进来 */
  const list = W.forum.boards['44']['movie_nianfen=32'];
  list.unshift({ tid: 99001, title: `${filmsE2E[0].cn} ${filmsE2E[0].en}.2025.2160p.REMUX.HEVC 60.1GB`, film: filmsE2E[0].id });
  const inc2 = await (await I.call('/api/incremental')).json();
  ok(inc2.added === 1, '新帖由增量扫描收进来（' + inc2.added + '）');
  verify(I.c, r2, W, '增量之后的不变量');
}

console.log('\n■ 掐进程：一轮里的每一次写之后被平台掐掉，换个 isolate 接着跑');
{
  let allGood = true, tried = 0, msgs = [];
  for (let k = 1; k <= 9; k++) {
    const { env, r2, W } = H.makeEnv();
    makeForum(W);
    r2.m = new Map([...snapMid].map(([a, b]) => [a, { ...b }]));
    const A = H.isolate(env, W);
    r2.f.dieAfter = r2.writes + k;
    await A.call('/api/build').then(r => r.json()).catch(() => null);
    await A.settle().catch(() => {});
    const died = r2.dead;
    r2.dead = false; r2.f.dieAfter = null;
    const B = H.isolate(env, W);
    B.clock.off = LOCK_MS + 5000;
    const b = await buildAll(B);
    await B.cron().catch(() => {});
    tried++;
    const before = pass; const bf = fail;
    verify(B.c, r2, W, `第 ${k} 次写之后掐掉${died ? '' : '（这一轮写得比 ' + k + ' 次少，没掐着）'}${b.err ? '，接着跑报错：' + b.err : ''}`);
    if (fail > bf) allGood = false;
    void before; void msgs;
  }
  ok(allGood, `${tried} 种掐法之后都能自己恢复：不丢帖子、不重复、计数对齐`);
}

console.log('\n■ R2 读失败：绝不拿空表覆盖');
{
  for (const [what, key] of [['movies.json 读到一半断了', NS + 'movies.json'], ['state.json 读到一半断了', NS + 'state.json'], ['留底队列读失败', 'idx/v5/pending.json']]) {
    const { env, r2, W } = H.makeEnv();
    makeForum(W);
    r2.m = new Map([...snapMid].map(([a, b]) => [a, { ...b }]));
    const before = r2.m.get(NS + 'movies.json').body, pb = (r2.m.get('idx/v5/pending.json') || {}).body;
    const I = H.isolate(env, W);
    r2.f.getFail = (k) => k === key ? 'body' : null;
    const r = await (await I.call('/api/build')).json();
    r2.f.getFail = null;
    ok(!!r.error && r2.m.get(NS + 'movies.json').body === before && (r2.m.get('idx/v5/pending.json') || {}).body === pb,
      `${what}：这一轮报错收工（${String(r.error).slice(0, 34)}…），影片表、留底队列一个字节没动`);
    const b = await buildAll(H.isolate(env, W));
    verify(H.isolate(env, W).c, r2, W, what + '之后接着跑完');
    void b;
  }
  /* 影片表被写坏 / 被删 */
  const { env, r2, W } = H.makeEnv();
  makeForum(W);
  r2.m = new Map([...snapMid].map(([a, b]) => [a, { ...b }]));
  const I = H.isolate(env, W);
  await I.cron();                                          // 先备份一份
  ok(r2.keys('bak/movie/').some(k => k.endsWith('movies.json')), '定时任务每天自动备份 movies / state / 留底队列');
  const good = r2.m.get(NS + 'movies.json').body;
  r2.m.set(NS + 'movies.json', { body: good.slice(0, good.length >> 1), etag: 'bad' });
  const r1 = await I.call('/api/build');
  const j1 = await r1.json();
  ok(r1.status >= 400 && /不是合法的 JSON/.test(j1.error) && r2.m.get(NS + 'movies.json').etag === 'bad', '影片表被写坏：建索引拒绝往下跑，坏文件原样留着（不会被空表覆盖）');
  const dg = await (await I.call('/api/diagnose')).json();
  ok(dg.checks.some(c => c.id === 'idx.read' && c.level === 'fail' && c.fix === 'restore'), '体检报出来，修复动作是「从备份恢复」');
  const rs = await (await I.call('/api/repair?do=restore')).json();
  ok(rs.ok && Object.keys(r2.json(NS + 'movies.json').m).length === Object.keys(JSON.parse(good).m).length, '从备份恢复：' + (rs.msg || rs.error));
  r2.m.delete(NS + 'movies.json');
  const j2 = await (await I.call('/api/build')).json();
  ok(/不见了/.test(j2.error || '') && !r2.m.has(NS + 'movies.json'), '影片表不见了（state 里还记着片数）：拒绝从空表重建');
  await I.call('/api/repair?do=restore');
  const b = await buildAll(H.isolate(env, W));
  await H.isolate(env, W).cron();
  verify(H.isolate(env, W).c, r2, W, '恢复之后接着跑完');
  void b;
}

console.log('\n■ 片库对照：总账停在 Stream v22，以 v25 的实时清单为准');
{
  const { env, r2, W } = H.makeEnv({ RECV_BASE: 'https://recv.test' });
  makeForumU(W, 20);
  /* 外语片：论坛标题有中文名，片库里的文件只有英文名（TMDB 中文结果里只有中文名和韩文原名） */
  const FOREIGN = [['寄生虫', '기생충', 'Parasite'], ['燃烧', '버닝', 'Burning'], ['小偷家族', '万引き家族', 'Shoplifters']];
  FOREIGN.forEach(([cn, orig, en], i) => {
    const id = 790000 + i;
    W.tmdb.movie.push({ id, title: cn, original_title: orig, en, release_date: '2024-03-01', poster_path: '/f' + i + '.jpg', popularity: 60, vote_average: 8, vote_count: 9000 });
    W.forum.boards['44']['movie_nianfen=31'].unshift({ tid: 39000 + i, title: `${cn} ${en}.2024.1080p.BluRay.x264 9.5GB`, film: id });
  });
  const I = H.isolate(env, W);
  await turboAll(I);
  const films = W.tmdb.movie.map(m => ({ id: m.id, cn: m.title, en: m.en || m.original_title, y: m.release_date.slice(0, 4) }));
  const fname = (m, en) => en ? `${m.en.replace(/ /g, '.')}.${m.y}.1080p.BluRay.x264.mkv` : `${m.cn}.${m.en.replace(/ /g, '.')}.${m.y}.2160p.WEB-DL.x265.mkv`;
  /* 片库：拥有前 30 部 + 三部外语片；v22 的总账只认得前 10 部 */
  const owned = films.slice(0, 30).concat(films.slice(-3));
  const notOwned = films.slice(30, films.length - 3);
  W.recv.meta = { gen: 'v22-7' };
  W.recv.doc = { gen: 'v22-7', ts: Date.now() - 40 * 86400e3, items: owned.slice(0, 10).map((m, i) => ({
    key: 'k' + i, kind: 'movie', name: fname(m), path: '/ram/' + fname(m), tmdb: m.id, type: 'movie', title: m.cn, orig: m.en, year: m.y,
    guess: m.cn, guessZh: m.cn, guessEn: m.en, guessYear: m.y })) };
  const ownMap = async () => {
    const all = [];
    for (let pg = 1; pg < 20; pg++) { const c = await (await I.call('/api/catalog?min=0&own=all&page=' + pg)).json(); all.push(...c.items); if (pg >= c.pages) break; }
    return new Map(all.map(x => [x.id, x.own]));
  };
  await I.call('/api/lib?refresh=1'); await I.settle();
  let om = await ownMap();
  const lostBefore = owned.filter(m => !om.get(m.id)).length;
  ok(lostBefore === owned.length - 10, `修之前（只有总账）：库里有的 ${owned.length} 部里 ${lostBefore} 部被判成缺片 —— 就是这次的问题`);

  /* Stream v25 的实时清单：前 20 部用论坛那种发布名，21–30 部换个规格，外语片只有英文名 */
  const vids = owned.map((m, i) => ({ name: fname(m, i >= 30), path: '/ram/' + (i >= 20 && i < 30 ? m.cn + ' (' + m.y + ')/' + fname(m).replace('2160p.WEB-DL.x265', '1080p.BluRay.x264') : fname(m, i >= 30)) }));
  W.recv.files = { root: '/ram', _gen: 'g1', _ts: Date.now() - 60000, videos: vids };
  W.recv.ptr = { g: 'g1' };
  /* 先让 TMDB 那头不通：看「索引片名键」一个 TMDB 请求不花能认出多少 */
  W.tmdb.fail = (u) => /search/.test(u.pathname) ? new Response('{}', { status: 500 }) : null;
  await I.call('/api/lib?refresh=1'); await I.settle();
  const st0 = await (await I.call('/api/lib')).json();
  om = await ownMap();
  const keyHit = owned.slice(10, 30).filter(m => om.get(m.id) === 2).length;
  ok(st0.src === 'live' && st0.match && st0.match.key >= 18 && keyHit >= 18,
    `TMDB 不通也照样认：文件名与论坛发布名同一个片名键，直接对上 ${st0.match && st0.match.key} 部（总账之外的 20 部里 ${keyHit} 部判为确定已有）`);
  W.tmdb.fail = null;
  for (let i = 0; i < 20; i++) { const r = await (await I.call('/api/lib?resolve=1')).json(); if (!r.left) break; }
  om = await ownMap();
  const miss = owned.filter(m => !om.get(m.id)), fp = notOwned.filter(m => om.get(m.id));
  const st = await (await I.call('/api/lib')).json();
  ok(!miss.length && !fp.length && st.src === 'live',
    `实时清单：库里的 ${owned.length} 部全判为已有（漏判 ${miss.length}${miss.length ? '：' + miss.map(m => m.cn).join('、') : ''}），没有的 ${notOwned.length} 部一部没藏（误藏 ${fp.length}）`);
  ok(st.viaLedger === 10 && st.viaTmdb === owned.length - 10,
    `来源：总账里同一个文件的 id ${st.viaLedger} 部 · 这边按文件名认定 ${st.viaTmdb} 部（含只有英文名的三部外语片：中文结果对不上就用英文再搜一次）`);
  const cat = await (await I.call('/api/catalog?min=0')).json();
  ok(cat.items.every(x => !owned.some(m => m.id === x.id)) && cat.total === notOwned.length, `目录（默认只看缺片）：${cat.total} 部，全是库里没有的`);

  /* 指纹没变：不下清单正文；新进库一部：指纹一变就认出来；删掉一部：重新显示为缺片 */
  const h0 = W.recv.hits['/file-list-v2.json'] || 0, d0 = W.recv.hits['/Received.json'] || 0;
  await I.call('/api/lib?refresh=1'); await I.settle();
  ok((W.recv.hits['/file-list-v2.json'] || 0) === h0 && (W.recv.hits['/Received.json'] || 0) === d0, '库快照指纹（lib-ptr.json）没变：清单正文、总账都不重下');
  const add = notOwned[0], gone = owned[15];
  W.recv.files = { root: '/ram', _gen: 'g2', _ts: Date.now(), videos: vids.filter(v => !v.name.startsWith(gone.cn + '.')).concat([{ name: fname(add), path: '/ram/' + fname(add) }]) };
  W.recv.ptr = { g: 'g2' };
  await I.call('/api/lib?refresh=1'); await I.settle();
  om = await ownMap();
  ok(om.get(add.id) && !om.get(gone.id) && (W.recv.hits['/Received.json'] || 0) === d0,
    `新进库「${add.cn}」立刻判为已有；删掉的「${gone.cn}」重新显示为缺片；总账（不会再变）没有重下`);
  /* 清单突然只剩一点点：多半是 Dropbox 列到一半，不拿它盖掉 */
  W.recv.files = { root: '/ram', _gen: 'g3', _ts: Date.now(), videos: vids.slice(0, 3) };
  W.recv.ptr = { g: 'g3' };
  await I.call('/api/lib?refresh=1'); await I.settle();
  om = await ownMap();
  ok(om.get(owned[25].id) && om.get(add.id), '清单突然只剩 3 个文件（上次 33 个）：判为列到一半出错，不用它，判定照旧');
}

console.log('\n■ 片库对照：实时清单走 Stream 接口（STREAM_KEY）、切片名分批、同名两年的片不认错、剧集');
{
  /* 公开桶里没有实时清单（FILE_CACHE 没挂公开域名）：走 STREAM_BASE + STREAM_KEY */
  const { env, r2, W } = H.makeEnv({ RECV_BASE: 'https://recv.test', STREAM_BASE: 'https://stream.test', STREAM_KEY: 'stream-secret' });
  makeForumU(W, 12);
  const I = H.isolate(env, W, { expose: ['LIVE_PARSE_MAX'] });
  await turboAll(I);
  const films = W.tmdb.movie;
  const vids = films.slice(0, 16).map(m => { const n = `${m.title}.${m.original_title.replace(/ /g, '.')}.${m.release_date.slice(0, 4)}.2160p.WEB-DL.x265.mkv`; return { name: n, path: '/ram/' + n }; });
  W.stream.files = { root: '/ram', videos: vids };
  W.stream.gen = 'sg1';
  I.c.__set('LIVE_PARSE_MAX', 5);
  let r, n = 0;
  for (; n < 10; n++) { r = await (await I.call('/api/lib?scan=1')).json(); if (!r.part) break; }
  I.c.__set('LIVE_PARSE_MAX', 800);
  const st = await (await I.call('/api/lib')).json();
  const cat = await (await I.call('/api/catalog?min=0&own=only')).json();
  ok(st.src === 'live' && st.via === 'stream' && W.stream.logins === 1 && n >= 3 && cat.total === 16,
    `走 Stream 接口：登录 ${W.stream.logins} 次（cookie 留着复用）；一次只切 5 个文件名，分 ${n + 1} 次同步切完；库里的 16 部全判为已有`);
  const l0 = W.stream.logins, c0 = W.stream.calls;
  await I.call('/api/lib?refresh=1'); await I.settle();
  ok(W.stream.logins === l0 && W.stream.calls - c0 <= 2, `指纹（/api/gen）没变：只问了 ${W.stream.calls - c0} 次，没重新登录、没下清单`);
  /* 口令不对：退回总账，并在面板上明说总账停在哪天 */
  const e2 = H.makeEnv({ RECV_BASE: 'https://recv.test', STREAM_BASE: 'https://stream.test', STREAM_KEY: 'wrong' });
  makeForumU(e2.W, 6);
  e2.W.stream.files = { root: '/ram', videos: vids };
  e2.W.recv.meta = { gen: 'v22' }; e2.W.recv.doc = { gen: 'v22', ts: Date.now() - 30 * 86400e3, items: [] };
  e2.W.recv.doc.items.push({ key: 'a', kind: 'movie', name: 'x.mkv', tmdb: 700000, type: 'movie', title: e2.W.tmdb.movie[0].title, orig: e2.W.tmdb.movie[0].original_title, year: '2025' });
  const J = H.isolate(e2.env, e2.W);
  await buildAll(J);
  await J.call('/api/lib?refresh=1'); await J.settle();
  const st2 = await (await J.call('/api/lib')).json();
  ok(st2.src === 'received' && st2.recvTs && Date.now() - st2.recvTs > 20 * 86400e3, '口令不对、实时清单拿不到：退回总账，面板拿到总账的时间（停了 30 天，会提示「之后进库的片会显示成缺片」）');

  /* 只配了 STREAM_BASE、没配口令：片库整个拿不到 —— 面板要说清楚为什么、该配什么（以前只是悄悄不过滤） */
  const e5 = H.makeEnv({ STREAM_BASE: 'https://stream.test' });
  makeForumU(e5.W, 4);
  e5.W.stream.files = { root: '/ram', videos: vids.slice(0, 2) };
  const Q = H.isolate(e5.env, e5.W);
  await buildAll(Q);
  await Q.call('/api/lib?refresh=1').catch(() => null); await Q.settle();
  const st5 = await (await Q.call('/api/lib')).json();
  ok(!st5.on && /STREAM_KEY/.test(st5.err || ''), '只配了 STREAM_BASE、Stream 设了口令：片库面板直说「拿不到片库」和该配 STREAM_KEY（' + String(st5.err || '').slice(0, 30) + '…）');

  /* 同名同原名、年份不同的另一部（重拍 / 老片）：索引里只有 2025 那部，库里那个文件写着 1999 */
  const e3 = H.makeEnv({ RECV_BASE: 'https://recv.test' });
  makeForumU(e3.W, 6);
  const K = H.isolate(e3.env, e3.W);
  await buildAll(K);
  const A = e3.W.tmdb.movie[0], B = e3.W.tmdb.movie[1];
  const nA = `${A.title}.${A.original_title.replace(/ /g, '.')}.1999.1080p.BluRay.x264.mkv`;
  const nB = `${B.title}.${B.original_title.replace(/ /g, '.')}.${B.release_date.slice(0, 4)}.1080p.BluRay.x264.mkv`;
  e3.W.recv.files = { root: '/ram', _gen: 'x1', _ts: Date.now(), videos: [{ name: nA, path: '/ram/' + nA }, { name: nB, path: '/ram/' + nB }] };
  e3.W.recv.ptr = { g: 'x1' };
  await K.call('/api/lib?refresh=1'); await K.settle();
  for (let i = 0; i < 5; i++) { const q = await (await K.call('/api/lib?resolve=1')).json(); if (!q.left) break; }
  const o3 = await (await K.call('/api/catalog?min=0&own=only')).json();
  ok(o3.total === 1 && o3.items[0].id === B.id, `库里的「${A.title} 1999」不是索引里的「${A.title} ${A.release_date.slice(0, 4)}」：不认（片名键要求同年、TMDB 认定差一年以上不认）；「${B.title}」照认`);

  /* 剧集：v25 剧集表自带 tmdbId */
  const e4 = H.makeEnv({ RECV_BASE: 'https://recv.test' });
  e4.W.tmdb.tv.push({ id: 1399, name: '权力的游戏', original_name: 'Game of Thrones', first_air_date: '2011-04-17', vote_count: 9000, vote_average: 8.4, poster_path: '/g.jpg', popularity: 80 },
                    { id: 94997, name: '龙之家族', original_name: 'House of the Dragon', first_air_date: '2022-08-21', vote_count: 4000, vote_average: 8.4, poster_path: '/h.jpg', popularity: 80 },
                    { id: 100088, name: '最后生还者', original_name: 'The Last of Us', first_air_date: '2023-01-15', vote_count: 5000, vote_average: 8.6, poster_path: '/l.jpg', popularity: 80 });
  e4.W.forum.boards['2'] = { 'tv_shangyingshijian_3=22': [
    { tid: 20001, title: '龙之家族 第二季 House.of.the.Dragon.S02.2024.2160p.WEB-DL.DDP5.1.HEVC 40GB' },
    { tid: 20003, title: '权力的游戏 第八季 Game.of.Thrones.S08.2019.1080p.BluRay.x264 30GB' },
    { tid: 20004, title: '最后生还者 第二季 The.Last.of.Us.S02.2024.2160p.WEB-DL 30GB' } ] };
  e4.W.recv.tv = { at: Date.now(), series: [
    { id: 'tv-1', path: '/ram2/House of the Dragon/Season 2', zh: '龙之家族', en: 'House of the Dragon', title: '龙之家族', season: 2, year: '2024', tmdbId: 94997, total: 8 },
    { id: 'tv-2', path: '/ram2/权力的游戏', zh: '权力的游戏', en: 'Game of Thrones', title: '权力的游戏', season: 8, year: '2019', tmdbId: 1399 } ] };
  const T = H.isolate(e4.env, e4.W);
  for (let i = 0; i < 20; i++) { const q = await (await T.call('/api/build?src=tv')).json(); if (q.done || q.error) break; }
  await T.call('/api/lib?refresh=1&src=tv'); await T.settle();
  const tc = await (await T.call('/api/catalog?min=0&own=all&src=tv')).json();
  const tom = new Map(tc.items.map(x => [x.id, x.own]));
  ok(tom.get(94997) === 2 && tom.get(1399) === 2 && !tom.get(100088), '剧集：v25 剧集表里认好的两部判为确定已有，没有的那部显示缺片');
}

console.log('\n■ 片库对照：新进库的片几分钟内自己认出来、各 isolate 跟上、详情页写明对上的文件');
{
  const { env, r2, W } = H.makeEnv({ RECV_BASE: 'https://recv.test' });
  makeForumU(W, 8);
  /* 「F1」这种：论坛标题是中文名，片库文件只有英文名（还多一截 The Movie），按名字比不上，只能靠 TMDB 认 */
  W.tmdb.movie.push({ id: 911430, title: 'F1：狂飙飞车', original_title: 'F1', en: 'F1', aka: ['F1 The Movie'], release_date: '2025-06-25', poster_path: '/f1.jpg', popularity: 300, vote_average: 7.8, vote_count: 2000 });
  W.forum.boards['44']['movie_nianfen=32'].unshift({ tid: 55001, title: 'F1：狂飙飞车 F1.2025.2160p.WEB-DL.DV.HDR 25GB', film: 911430 });
  const A = H.isolate(env, W), B = H.isolate(env, W);
  await turboAll(A);
  const m0 = W.tmdb.movie[0];
  const f0 = `${m0.title}.${m0.original_title.replace(/ /g, '.')}.2025.2160p.WEB-DL.x265.mkv`;
  W.recv.files = { root: '/ram', _gen: 'p1', _ts: Date.now(), videos: [{ name: f0, path: '/ram/' + f0 }] };
  W.recv.ptr = { g: 'p1' };
  await A.call('/api/lib?refresh=1'); await A.settle();
  await B.call('/api/catalog?min=0'); await B.settle();               // B 也加载一份片库（此时还没有 F1）
  const own = async (I, id) => { const c = await (await I.call('/api/catalog?min=0&own=all&q=' + encodeURIComponent(id === 911430 ? 'F1' : m0.title))).json(); const x = c.items.find(y => y.id === id); return x ? x.own : null; };
  ok(await own(B, 911430) === 0, '片库里还没有 F1：B 判它缺片');
  /* F1 进库（指纹变了）。没人点任何按钮：五分钟后 A 上一次普通的翻目录，后台同步 + 顺手认定 */
  const fF1 = 'F1 The Movie 2025 HKG BluRay Remux UHD DoVi HDR10 2160p Atmos TrueHD7.1-DreamHD.mkv';
  W.recv.files = { root: '/ram', _gen: 'p2', _ts: Date.now(), videos: [{ name: f0, path: '/ram/' + f0 }, { name: fF1, path: '/ram/' + fF1 }] };
  W.recv.ptr = { g: 'p2' };
  A.clock.off += 6 * 60000;
  const t0 = W.tmdb.calls;
  await A.call('/api/catalog?min=0'); await A.settle();
  const tmdbUsed = W.tmdb.calls - t0;
  ok(await own(A, 911430) === 2 && tmdbUsed > 0 && tmdbUsed <= 24,
    `没点任何按钮：翻目录时后台发现新文件、用自带的小配额认出来（TMDB ${tmdbUsed} 次，≤ 24），A 立刻判 F1「确定已有」`);
  /* B 的片库缓存是五分钟前的：五分钟一到也跟上（读回 A 写进 R2 的认定结果） */
  ok(await own(B, 911430) === 0, 'B 的缓存还没过期时照旧（最多五分钟）');
  B.clock.off += 6 * 60000;
  await B.call('/api/catalog?min=0'); await B.settle();
  ok(await own(B, 911430) === 2, 'B 五分钟一到就读回最新的片库成品：F1 也判「确定已有」（以前要等三十分钟）');
  const d = await (await A.call('/api/detail?id=911430')).json();
  const d0 = await (await A.call('/api/detail?id=' + m0.id)).json();
  ok(d.movie.lib && d.movie.lib.own === 2 && d.movie.lib.how === 'id' && d.movie.lib.file === fF1 && d0.movie.lib && d0.movie.lib.file === f0,
    `详情页写明对上的文件：「${d.movie.lib && d.movie.lib.file.slice(0, 26)}…」· ${d.movie.lib && d.movie.lib.how}`);
}

console.log('\n■ 片名以字母开头、切不出片名的帖子');
{
  const { env, r2, W } = H.makeEnv();
  makeForumU(W, 3);
  const X = { id: 127585, title: 'X战警：天启', original_title: 'X-Men: Apocalypse', release_date: '2025-05-18', poster_path: '/x.jpg', popularity: 80, vote_average: 7, vote_count: 9000 };
  W.tmdb.movie.push(X);
  W.forum.boards['44']['movie_nianfen=32'].unshift(
    { tid: 56001, title: 'X战警：天启 X-Men.Apocalypse.2025.1080p.BluRay.x264 10GB', film: X.id },
    { tid: 56002, title: 'E.T. 外星人 2025 1080p.BluRay 3GB', film: null });
  const I = H.isolate(env, W, { expose: ['parseTitle'] });
  await turboAll(I);
  const pt = I.k.parseTitle('F1：狂飙飞车 F1.The.Movie.2025.2160p 30GB');
  const mv = r2.json(NS + 'movies.json'), pd = r2.json('idx/v5/pending.json');
  const np = Object.entries(pd.q).find(([k]) => k.startsWith('np|'));
  ok(pt.cn === 'F1：狂飙飞车' && pt.latin === 'F1 The Movie' && mv.m[X.id], '中文名以字母开头（F1：狂飙飞车 / X战警：天启）：切得出中文名，帖子进了索引（以前中文名切成空的，整帖被跳过）');
  ok(np && np[1].r.some(r => r[0] === 56002), '切不出片名的帖子（「E.T. 外星人」这种）连同帖子行进了留底（解析器再升级时「重试匹配」能捡回来），不再悄悄丢掉');
  verify(I.c, r2, W, '片名以字母开头之后的不变量');
}

console.log('\n■ 剧集版块是 UTF-8：按真实编码解码，旧版存下的乱码一键重建');
{
  const OLD = process.env.IDX_V63_WORKER;
  const TVS = [['余生有你', 'Here We Meet Again'], ['我的人间烟火', 'Fireworks of My Heart'], ['繁花', 'Blossoms Shanghai'],
               ['漫长的季节', 'The Long Season'], ['狂飙', 'The Knockout'], ['三体', 'Three Body']];
  const mk = (enc) => {
    const e = H.makeEnv();
    makeForumU(e.W, 4);                       // 电影版块（GBK）：重建剧集时它一点不能动
    let tid = 60000;
    const rows = [];
    TVS.forEach(([cn, en], i) => {
      e.W.tmdb.tv.push({ id: 310000 + i, name: cn, original_name: en, first_air_date: '2025-0' + (1 + i) + '-10', vote_count: 900, vote_average: 7.8, poster_path: '/t' + i + '.jpg', popularity: 50 });
      /* 后三部只有中文名：旧版解成乱码之后一个字都对不上，只能进「未匹配」 */
      for (const r of ['2160p.WEB-DL.HEVC 40GB', '1080p.WEB-DL.H264 12GB'])
        rows.push({ tid: tid++, title: i < 3 ? `${cn}[全${18 + i}集][中文字幕].${en.replace(/ /g, '.')}.S01.2025.${r}` : `${cn}[全${18 + i}集][中文字幕].S01.2025.${r}`, film: 310000 + i });
    });
    e.W.forum.boards['2'] = { 'tv_shangyingshijian_3=22': rows };
    e.W.forum.encByFid['2'] = enc;
    return e;
  };
  if (!OLD || !fs.existsSync(OLD)) ok(false, '缺 v6.3 原版（IDX_V63_WORKER）：run.mjs 开头会从 git 取');
  else {
    const { env, r2, W } = mk('utf8');
    const O = H.isolate(env, W, { file: OLD });
    for (let i = 0; i < 40; i++) { const q = await (await O.call('/api/build')).json(); if (q.done || q.error) break; }
    for (let i = 0; i < 40; i++) { const q = await (await O.call('/api/build?src=tv')).json(); if (q.done || q.error) break; }
    await O.settle();
    const movie0 = r2.m.get(NS + 'movies.json').body;
    const N = H.isolate(env, W, { expose: ['mojibake', 'decodeHTML'] });
    const pd = r2.json('idx/tv/pending.json') || { q: {} };
    const samples = Object.values(pd.q).map(e => e.t);
    const st = await (await N.call('/api/state?src=tv')).json();
    const dg = await (await N.call('/api/diagnose?src=tv')).json();
    ok(samples.length >= 3 && samples.every(t => N.k.mojibake(t)) && st.pend && st.pend.garbled * 2 >= st.pend.gchk && dg.checks.some(c => c.id === 'idx.garbled' && c.fix === 'rebuildSource'),
      `旧版把 UTF-8 的剧集页当 GBK 解：留底里 ${samples.length} 条全是乱码（例如「${String(samples[0]).slice(0, 12)}…」），新版认得出来，体检给「重建本源索引」`);
    const real = ['跟踪者的猎物2 Stalkers.Prey.2.2020.1080p', '亚历克斯·费尔南德斯:全球最佳喜剧演员', '[全18集][中文字幕]', '余生有你'];
    ok(real.every(t => !N.k.mojibake(t)), '正常的中文标题不会被当成乱码（' + real.length + ' 条）');
    const rb = await (await N.call('/api/repair?do=rebuildSource&src=tv')).json();
    const tvm = r2.json('idx/tv/movies.json');
    ok(rb.ok && r2.keys('bak/tv/').some(k => k.endsWith('movies.json')) && Object.keys(tvm.m).length === 0 && !Object.keys((r2.json('idx/tv/pending.json') || { q: {} }).q).length,
      `重建：先备份（bak/tv/），再清空剧集索引（清掉 ${rb.dropped} 部）`);
    const t = await turboAll(N, { src: 'tv' });
    const tv2 = r2.json('idx/tv/movies.json');
    const d = await (await N.call('/api/detail?id=310000&src=tv')).json();
    const pd2 = r2.json('idx/tv/pending.json') || { q: {} };
    ok(Object.keys(tv2.m).length === TVS.length && d.items && d.items.some(x => /余生有你/.test(x.title)) && !Object.values(pd2.q).some(e => N.k.mojibake(e.t)),
      `重新抓（${t.msg}）：${Object.keys(tv2.m).length} 部剧全认出来，详情里的片源标题是「${d.items && d.items[0] && d.items[0].title.slice(0, 14)}…」，留底里一条乱码都没有`);
    ok(r2.m.get(NS + 'movies.json').body === movie0, '电影索引一个字节没动');
  }
  /* 响应头不声明编码的 UTF-8 页：靠「能不能按 UTF-8 严格解开」认出来 */
  const b = mk('utf8-bare');
  const B = H.isolate(b.env, b.W);
  await turboAll(B, { src: 'tv' });
  const tv3 = b.r2.json('idx/tv/movies.json');
  const d3 = await (await B.call('/api/detail?id=310002&src=tv')).json();
  ok(Object.keys(tv3.m).length === TVS.length && d3.items && d3.items.some(x => /繁花/.test(x.title)), '响应头不声明编码的 UTF-8 页面也按 UTF-8 解：6 部全认出、标题正常');
}

console.log('\n■ 认定管线 v3：英文、别名、去副标题；配额不够不下结论；「重试匹配」走认定工');
{
  const { env, r2, W } = H.makeEnv();
  makeForumU(W, 3);
  const SP = [
    { id: 880001, title: '在里乔的阳光下', orig: 'Sotto il sole di Riccione', en: 'Under the Riccione Sun', y: 2025, noZh: true,
      t: '在里乔的阳光下 Under.the.Riccione.Sun.2025.ITALIAN.1080p.WEB-DL 3.1GB', how: '没有中文译名：英文再搜一次' },
    { id: 880002, title: '没人知道我在这', orig: 'Nadie sabe que estoy aquí', en: "Nobody Knows I'm Here", y: 2025, strict: true,
      t: '没人知道我在这/歌手的秘密 Nobody.Knows.Im.Here.2025.1080p.WEB-DL 2.5GB', how: '「A/B」两个译名' },
    { id: 880003, title: '亚历克斯·费尔南德斯：全球最佳喜剧演员', orig: 'Alex Fernández: El mejor cómico del mundo', en: 'Alex Fernández: The Best Comedian in the World', y: 2025, noZh: true,
      t: '亚历克斯·费尔南德斯:全球最佳喜剧演员 Alex.Fernandez.The.Best.Comedian.in.the.World.2025.1080p 1.2GB', how: '西班牙语原名、英文带重音' },
  ];
  let tid = 77000;
  for (const x of SP) {
    W.tmdb.movie.push({ id: x.id, title: x.title, original_title: x.orig, en: x.en, release_date: x.y + '-04-01', poster_path: '/s.jpg', popularity: 20, vote_average: 6.8, vote_count: 300, noZh: x.noZh, strict: x.strict });
    W.forum.boards['44']['movie_nianfen=32'].unshift({ tid: tid++, title: x.t, film: x.id });
  }
  /* 还没上架的片：先认不出，TMDB 补了条目之后「重试匹配」认回来；查无此片的那条重试一次记一次 */
  W.forum.boards['44']['movie_nianfen=32'].unshift({ tid: tid++, title: '迟到的片 Late.Arrival.2025.1080p.WEB-DL 2GB', film: 880009 });
  W.forum.boards['44']['movie_nianfen=32'].unshift({ tid: tid++, title: '查无此片甲 Nowhere.Film.Alpha.2025.1080p 1GB', film: null });
  const I = H.isolate(env, W);
  await turboAll(I);
  const mv = r2.json(NS + 'movies.json');
  for (const x of SP) ok(!!mv.m[x.id] && /[\u4e00-\u9fff]/.test(mv.m[x.id][0]), `${x.how}：「${x.t.split(' ')[0]}」认下（片名「${mv.m[x.id] && mv.m[x.id][0]}」）`);
  ok(mv.pv >= 3, '认定规则升到 v' + mv.pv + '：以前「认不出」的结论作废、留底条目的重试次数归零');
  /* 配额只够 3 个请求：一组都不判「认不出」，全按「没下结论」交回 */
  I.c.__set('TURBO_FREE.sub', 3);
  const g = Array.from({ length: 12 }, (_, i) => ({ k: 'b' + i + '|x', cn: '没有这部片' + '甲乙丙丁戊己庚辛壬癸子丑'[i], la: 'No Such Film ' + i, ys: ['2025'], y: 2025, t: '没有这部片 No.Such.Film.2025' }));
  const tj = await (await I.call('/api/tm', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ g }) })).json();
  I.c.__set('TURBO_FREE.sub', 46);
  ok(tj.sub <= 3 && Object.values(tj.r).every(v => v === 0), `配额只够 ${tj.sub} 个请求：12 组一组都不判「认不出」（以前会把没轮到的判成认不出、帖子只留 12 条）`);
  /* TMDB 补上「迟到的片」→ 重试匹配（排队 + 认定工） */
  W.tmdb.movie.push({ id: 880009, title: '迟到的片', original_title: 'Late Arrival', release_date: '2025-06-01', poster_path: '/l.jpg', popularity: 10, vote_average: 6, vote_count: 100 });
  const rq = await (await I.call('/api/repair?do=requeueUnmatched')).json();
  const t2 = await turboAll(I);
  const mv2 = r2.json(NS + 'movies.json'), pd = r2.json('idx/v5/pending.json'), st2 = r2.json(NS + 'state.json');
  const done = new Set(st2.pdone || []);
  const nowhere = Object.entries(pd.q).find(([k, e]) => !done.has(k) && /查无此片甲/.test(e.t));
  ok(rq.queued >= 2 && mv2.m[880009] && nowhere && nowhere[1].n === 1 && nowhere[1].w === 'nohit',
    `重试匹配：${rq.queued} 组排进队列交给认定工（${t2.msg}）—— TMDB 补了条目的「迟到的片」认回来；查无此片的记一次重试（${nowhere && nowhere[1].n} 次）`);
  verify(I.c, r2, W, '认定管线 v3 之后的不变量');
}

console.log('\n■ 并发与锁');
{
  const { env, r2, W } = H.makeEnv();
  makeForum(W);
  const A = H.isolate(env, W), B = H.isolate(env, W);
  let busy = 0, okN = 0;
  for (let i = 0; i < 120; i++) {
    const [ra, rb] = await Promise.all([A.call('/api/build'), B.call('/api/build')]);
    for (const r of [ra, rb]) { if (r.status === 409) busy++; else if (r.status === 200) okN++; }
    const st = r2.json(NS + 'state.json');
    if (st && BUILD_DONE(st)) break;
  }
  ok(busy > 0 && okN > 0, `两个 isolate 同时建索引：一边跑、另一边回 409 等着（跑了 ${okN} 轮，挡回 ${busy} 次）`);
  await buildAll(A);
  verify(A.c, r2, W, '并发跑完以后的不变量');

  /* 锁被接管：A 卡在拉列表上超过锁期，B 接管并提交；A 醒来必须放弃提交 */
  const e2 = H.makeEnv();
  makeForum(e2.W);
  e2.r2.m = new Map([...snapMid].map(([a, b]) => [a, { ...b }]));
  const waiters = []; let hang = true;
  e2.W.forum.fail = (u) => (hang && /forumdisplay/.test(u.search)) ? new Promise(r => waiters.push(r)).then(() => null) : null;
  const A2 = H.isolate(e2.env, e2.W);
  const pA = A2.call('/api/build').then(r => r.json());
  for (let i = 0; i < 400 && !waiters.length; i++) await new Promise(r => setTimeout(r, 5));
  hang = false;
  const B2 = H.isolate(e2.env, e2.W);
  B2.clock.off = LOCK_MS + 2000;
  const rb = await (await B2.call('/api/build')).json();
  const cidB = e2.r2.json(NS + 'state.json').cid;
  const pendB = (e2.r2.m.get('idx/v5/pending.json') || {}).body;
  waiters.forEach(w => w());
  const ra = await pA;
  ok(waiters.length > 0 && !rb.error && e2.r2.json(NS + 'state.json').cid === cidB && (e2.r2.m.get('idx/v5/pending.json') || {}).body === pendB && /锁/.test(ra.error || ''),
    `锁被接管：B 接管并提交，A 醒来发现锁不是自己的、放弃提交，也没动留底队列（A：${String(ra.error || '居然提交了').slice(0, 26)}…）`);
  await buildAll(H.isolate(e2.env, e2.W));
  verify(H.isolate(e2.env, e2.W).c, e2.r2, e2.W, '接管之后接着跑完');
}
function BUILD_DONE(st) { return [2026, 2025, 2024, 2023, 2022, 2021, 2020].every(y => st.years && st.years[y] && st.years[y].done); }

console.log('\n■ 极限模式：扫描轮 + 并行认定工（跑的是页面里那一份调度代码）');
let snapTurbo = null;
{
  /* 普通模式建一遍，当参照 */
  const ref = H.makeEnv();
  makeForum(ref.W, { films: 30 });
  const R = H.isolate(ref.env, ref.W);
  const rb = await buildAll(R);
  const refMovies = Object.keys(ref.r2.json(NS + 'movies.json').m).sort().join(',');
  const refList = ref.W.forum.calls;

  const { env, r2, W } = H.makeEnv();
  makeForum(W, { films: 30 });
  const I = H.isolate(env, W);
  const t = await turboAll(I);
  ok(t.msg === '完成' && !t.bad, `极限模式跑完：${t.msg}（${t.rounds.length} 轮扫描 · ${t.tm} 次认定工调用 · 认定工最多并发 ${t.maxAct} 路）`);
  verify(I.c, r2, W, '极限模式建完以后的不变量');
  const mv = r2.json(NS + 'movies.json'), st = r2.json(NS + 'state.json'), pd = r2.json('idx/v5/pending.json') || { q: {} };
  const pdone = new Set(st.pdone || []);
  const waits = Object.entries(pd.q).filter(([k, e]) => e.w === 'wait' && !pdone.has(k));
  ok(Object.keys(mv.m).sort().join(',') === refMovies, `与普通模式建出来的影片表一模一样（${Object.keys(mv.m).length} 部）`);
  ok(!waits.length && st.pend && st.pend.wait === 0, '排队的条目全部认完，state 里的排队数是 0');
  ok(t.rounds.length < rb.n, `扫描轮数比普通模式少：${t.rounds.length} 轮 vs ${rb.n} 轮`);
  ok(W.forum.calls <= refList, `论坛请求不比普通模式多：${W.forum.calls} 次 vs 普通模式 ${refList} 次（普通模式认不完会把游标往回拨、重抓同几页）`);
  ok(t.maxAct >= 2 && t.maxSub <= 46, `认定工真的并行（最多 ${t.maxAct} 路同时在认），每路子请求不超过 46（最多 ${t.maxSub}）`);
  const cat = await (await I.call('/api/catalog?min=0')).json();
  ok(cat.total === Object.keys(mv.m).length, `目录列出全部 ${cat.total} 部`);
}

console.log('\n■ 极限模式：掐进程（交回认定结果的那一轮，每一次写之后都掐一次）');
{
  /* 中途快照：第一轮扫完 2025 年（只排队不认），认定工认一批交给第二轮（写进分片 + 扫 2024 年）——
     于是快照里既有已写进分片、还没从队列删掉的条目（state.pdone），也有排队等认的 2024 年条目 */
  {
    const { env, r2, W } = H.makeEnv();
    makeForum(W, { films: 30 });
    const I = H.isolate(env, W);
    const post = (u, body) => I.call(u, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) }).then(r => r.json());
    let r = await post('/api/build?turbo=1&year=2025', { hits: [], fly: [] });
    const tm = await post('/api/tm', { g: r.need.slice(0, 20) });
    r = await post('/api/build?turbo=1&year=2024', { hits: Object.entries(tm.r).filter(([, v]) => v), fly: [] });
    if ((r2.json(NS + 'state.json').pdone || []).length && r.waitN > 5) snapTurbo = r2.snapshot();
  }
  if (!snapTurbo) ok(false, '没拿到极限模式的中途快照');
  else {
    let allGood = true, tried = 0, died = 0;
    for (let k = 1; k <= 12; k++) {
      const { env, r2, W } = H.makeEnv();
      makeForum(W, { films: 30 });
      r2.m = new Map([...snapTurbo].map(([a, b]) => [a, { ...b }]));
      const A = H.isolate(env, W);
      /* 先拿认定工把排队的认一遍（不写 R2），再把结果交给一轮扫描 —— 这一轮的第 k 次写之后掐掉 */
      const pd = r2.json('idx/v5/pending.json'), st = r2.json(NS + 'state.json');
      const pdone = new Set(st.pdone || []);
      const g = Object.entries(pd.q).filter(([kk, e]) => e.w === 'wait' && !pdone.has(kk)).slice(0, 20).map(([kk, e]) => ({ k: kk, cn: e.cn, la: e.la, ys: e.ys, y: e.y, t: e.t }));
      const tm = await (await A.call('/api/tm', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ g }) })).json();
      const hits = Object.entries(tm.r).filter(([, v]) => v);
      r2.f.dieAfter = r2.writes + k;
      await A.call('/api/build?turbo=1', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ hits, fly: [] }) }).then(r => r.json()).catch(() => null);
      await A.settle().catch(() => {});
      if (r2.dead) died++;
      r2.dead = false; r2.f.dieAfter = null;
      const B = H.isolate(env, W);
      B.clock.off = LOCK_MS + 5000;
      const t = await turboAll(B);
      await B.cron().catch(() => {});                     // 掐在 movies.json 与 state.json 之间：定时任务自动「重算汇总」对齐计数（同普通模式）
      tried++;
      const bf = fail;
      verify(B.c, r2, W, `第 ${k} 次写之后掐掉${r2.writes ? '' : ''}，换个 isolate 用极限模式接着跑（${t.msg}，交回 ${hits.length} 条结果）`);
      if (fail > bf) allGood = false;
    }
    ok(allGood && died >= 6, `${tried} 种掐法（真掐着 ${died} 次）之后都能自己恢复：不丢帖子、不重复、计数对齐`);
  }
}

console.log('\n■ 极限模式：留底条目的延迟删除、坏结果、总开关、冷却、背压');
{
  const { env, r2, W } = H.makeEnv();
  makeForum(W, { films: 30 });
  const I = H.isolate(env, W);
  const post = (u, body) => I.call(u, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) }).then(r => r.json());
  /* 只扫不认：两轮扫描、不交结果 */
  let r1 = await post('/api/build?turbo=1', { hits: [], fly: [] });
  r1 = await post('/api/build?turbo=1', { hits: [], fly: [] });
  const pend0 = r2.json('idx/v5/pending.json');
  const waits0 = Object.entries(pend0.q).filter(([, e]) => e.w === 'wait');
  ok(waits0.length > 5 && r1.need.length > 0 && r1.queued >= 0 && waits0.every(([, e]) => e.r.length >= 1), `扫描轮只抓不认：${waits0.length} 组连同帖子行进了留底队列（wait），need 交出 ${r1.need.length} 组`);
  const tm = await post('/api/tm', { g: r1.need.slice(0, 20) });
  const hits = Object.entries(tm.r).filter(([, v]) => v && v.h);
  ok(tm.hit === hits.length && hits.length > 0 && tm.sub <= 46, `认定工认下 ${tm.hit} 组（子请求 ${tm.sub}）`);
  const r2a = await post('/api/build?turbo=1&pages=0', { hits, fly: [] });
  const st1 = r2.json(NS + 'state.json'), pend1 = r2.json('idx/v5/pending.json');
  ok(r2a.applied === hits.length && st1.pdone && st1.pdone.length === hits.length && hits.every(([k]) => pend1.q[k]),
    `交回 ${hits.length} 条：写进分片，记进 state.pdone，留底条目这一轮先不删（掐在两次写之间也不丢）`);
  const again = await post('/api/build?turbo=1&pages=0', { hits, fly: [] });
  const st2 = r2.json(NS + 'state.json'), pend2 = r2.json('idx/v5/pending.json');
  ok(again.applied === 0 && again.ack.length === hits.length && hits.every(([k]) => !pend2.q[k]) && !(st2.pdone || []).length,
    '同一批结果再交一遍：一条都不重写（ack 掉）；下一轮写队列时才把它们真正删掉，pdone 清空');
  verify(I.c, r2, W, '重复交结果之后的不变量', { partial: true });

  /* 坏结果：未知键、负 id、缺字段、年份乱写 */
  const live = Object.entries(pend2.q).filter(([, e]) => e.w === 'wait' && !/无此片/.test(e.t)).map(([k]) => k);
  const m0 = Object.keys(r2.json(NS + 'movies.json').m).length;
  const junk = Object.entries(pend2.q).filter(([, e]) => e.w === 'wait' && /无此片/.test(e.t)).map(([k]) => k);
  const bad = await post('/api/build?turbo=1&pages=0', { hits: [
    ['不存在的键|x', { h: [123, '假片', 'Fake', '2025-01-01', '', 7, 10, []] }],
    [live[0], { h: [-5, '负数', '', '', '', 0, 0, []] }],
    [live[1], { h: [77, '', '', '2025', '', 0, 0, []] }],
    [live[2], { h: 'not-an-array' }],
    [junk[0], { m: 'drop table' }],
  ], fly: [] });
  const pend3 = r2.json('idx/v5/pending.json');
  ok(bad.rej.length === 3 && bad.ack.includes('不存在的键|x') && Object.keys(r2.json(NS + 'movies.json').m).length === m0
    && pend3.q[live[0]].w === 'wait' && pend3.q[junk[0]].w === 'nohit',
    `坏结果：形状不对的 ${bad.rej.length} 条拒收（条目原样留着下次重认），未知键直接确认掉，乱写的「认不出」原因按 nohit 记；影片表一部没多`);

  /* 总开关 */
  const off = H.makeEnv({ TURBO: '0' });
  makeForum(off.W, { films: 6 });
  const O = H.isolate(off.env, off.W);
  const tmOff = await O.call('/api/tm', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ g: [] }) });
  const bOff = await (await O.call('/api/build?turbo=1', { method: 'POST', headers: { 'content-type': 'application/json' }, body: '{"hits":[]}' })).json();
  const tOff = await turboAll(O);
  ok(tmOff.status === 403 && bOff.turbo === 0 && !bOff.need && /关闭/.test(tOff.msg), `TURBO=0：认定工回 403、扫描轮按普通模式跑（turbo:0），浏览器那边退回普通模式（${tOff.msg}）`);

  /* 冷却：论坛那头不碰，认定结果照样写进去 */
  const cur = r2.json(NS + 'state.json');
  cur.cool = { until: Date.now() + 120000, why: '测试冷却', strikes: 4, gap: 1200 };
  r2.m.set(NS + 'state.json', { body: JSON.stringify(cur), etag: 'c1' });
  const live2 = Object.entries(r2.json('idx/v5/pending.json').q).filter(([, e]) => e.w === 'wait').map(([k, e]) => ({ k, cn: e.cn, la: e.la, ys: e.ys, y: e.y, t: e.t }));
  const tm2 = await post('/api/tm', { g: live2.slice(0, 20) });
  const h2 = Object.entries(tm2.r).filter(([, v]) => v && v.h);
  const f0 = W.forum.calls;
  const rc = await post('/api/build?turbo=1', { hits: h2, fly: [] });
  ok(rc.cooling > 0 && rc.pages === 0 && W.forum.calls === f0 && rc.applied === h2.length,
    `论坛冷却中：一页不抓（论坛请求 +${W.forum.calls - f0}），交回的 ${rc.applied} 条照样写进分片`);
  await I.call('/api/repair?do=cooldown');

  /* 背压：排队太多先停抓，扫描轮自己认一批 */
  await post('/api/build?turbo=1', { hits: [], fly: [] });      // 先扫一轮（2024 年），让队列里有排队的
  const wq = r2wait(r2);
  I.c.__set('TURBO_FREE.high', 1);
  const f1 = W.forum.calls;
  const bp = await post('/api/build?turbo=1', { hits: [], fly: [] });
  I.c.__set('TURBO_FREE.high', 360);
  ok(wq > 0 && bp.backlog === 1 && bp.pages === 0 && W.forum.calls === f1 && bp.tmdbCalls > 0 && bp.waitN < wq,
    `排队超过上限：这一轮不抓列表，用闲着的子请求自己认了 ${bp.tmdbCalls} 组（排队 ${wq} → ${bp.waitN}）`);
  const tEnd = await turboAll(I);
  verify(I.c, r2, W, '冷却、背压、坏结果之后接着跑完（' + tEnd.msg + '）');
}

console.log('\n■ 极限模式：认定工用不了（403 / 一直报错），扫描轮自己认');
{
  for (const [label, mk] of [['认定工回 403（服务端关掉了认定工）', () => Object.assign(new Error('off'), { status: 403, data: { off: 1 } })],
                             ['认定工一直 500', () => Object.assign(new Error('HTTP 500'), { status: 500, data: {} })]]) {
    const { env, r2, W } = H.makeEnv();
    makeForum(W, { films: 30 });
    const I = H.isolate(env, W);
    const t = await turboAll(I, { tmFail: mk });
    verify(I.c, r2, W, `${label}：${t.msg}（${t.rounds.length} 轮，排队 ${r2wait(r2)}）`);
  }
}

console.log('\n■ 从 v6.1 升级：补回旧版漏掉的帖子');
{
  /* v6.1 及更早：一轮认不完的组只把游标往回拨 ceil(n/28) 页，一页不到 28 组时前面页里没认完的就再也抓不回来 */
  const OLD = process.env.IDX_V61_WORKER;
  if (!OLD || !fs.existsSync(OLD)) ok(false, '缺 v6.1 原版（IDX_V61_WORKER）：run.mjs 开头会从 git 取');
  else {
    const { env, r2, W } = H.makeEnv();
    W.forum.perPage = 30;
    makeForumU(W, 40);
    const O = H.isolate(env, W, { file: OLD });
    for (let i = 0; i < 200; i++) { const r = await (await O.call('/api/build')).json(); if (r.done || r.error) break; }
    await O.settle();
    const films = new Set(allPosts(W).filter(p => p.film).map(p => p.film));
    const n0 = Object.keys(r2.json(NS + 'movies.json').m).length;
    const N = H.isolate(env, W);
    const rs = await (await N.call('/api/repair?do=rescanUnmatched')).json();
    const t = await turboAll(N);
    await N.cron();
    const n1 = Object.keys(r2.json(NS + 'movies.json').m).length;
    ok(n0 < films.size && n1 === films.size && rs.ok, `v6.1 建出来 ${n0} 部（应有 ${films.size} 部）；升级后点一次「重扫未匹配」、用极限模式重走一遍：${n1} 部（${t.msg}）`);
    verify(N.c, r2, W, '补回之后的不变量');
  }
}

console.log('\n■ 极限模式：中途关掉页面，普通模式 / 定时任务接着认');
{
  /* 只扫不认，扫到全部年份完成 */
  const mk = () => { const e = H.makeEnv(); makeForum(e.W, { films: 30 }); return e; };
  const a = mk();
  const A = H.isolate(a.env, a.W);
  for (let i = 0; i < 40; i++) {
    const r = await (await A.call('/api/build?turbo=1', { method: 'POST', headers: { 'content-type': 'application/json' }, body: '{"hits":[],"fly":[]}' })).json();
    if (r.done) break;
  }
  const w0 = r2wait(a.r2);
  const n = await buildAll(H.isolate(a.env, a.W));
  ok(w0 > 10 && r2wait(a.r2) === 0, `列表抓完、${w0} 组还在排队：普通模式「继续建立索引」把它们认完（${n.n} 轮）`);
  verify(A.c, a.r2, a.W, '普通模式认完排队之后的不变量');

  const b = mk();
  const B = H.isolate(b.env, b.W);
  for (let i = 0; i < 40; i++) {
    const r = await (await B.call('/api/build?turbo=1', { method: 'POST', headers: { 'content-type': 'application/json' }, body: '{"hits":[],"fly":[]}' })).json();
    if (r.done) break;
  }
  const w1 = r2wait(b.r2);
  let crons = 0;
  for (; crons < 12 && r2wait(b.r2) > 0; crons++) { B.clock.off += 60000; await B.cron(); }
  ok(w1 > 10 && r2wait(b.r2) === 0, `${w1} 组在排队、页面关了：每天的定时任务接着认完（${crons} 次）`);
  verify(B.c, b.r2, b.W, '定时任务认完排队之后的不变量');
}
function r2wait(r2) {
  const st = r2.json(NS + 'state.json') || {}, pd = r2.json('idx/v5/pending.json') || { q: {} };
  const done = new Set(st.pdone || []);
  return Object.entries(pd.q).filter(([k, e]) => e.w === 'wait' && !done.has(k)).length;
}

console.log('\n■ 极限模式：认定工的配额、TMDB 限流、第二轮网络失败、并发抓页的间隔与登录');
{
  const { env, W } = H.makeEnv();
  makeForum(W, { films: 30 });
  const I = H.isolate(env, W);
  W.tmdb.fail = () => new Response('{}', { status: 429, headers: { 'retry-after': '0' } });
  const t0 = W.tmdb.calls;
  const g = W.tmdb.movie.slice(0, 20).map((m, i) => ({ k: 'k' + i + '|x', cn: m.title, la: m.original_title, ys: ['2025'], y: 2025, t: m.title + ' ' + m.original_title + '.2025.1080p' }));
  const res = await I.call('/api/tm', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ g }) });
  const j = await res.json();
  ok(res.status === 200 && j.sub <= 46 && W.tmdb.calls - t0 <= 46 && j.n429 > 0 && Object.values(j.r).every(v => v === 0),
    `TMDB 一直回 429：认定工照样回 200，子请求 ${j.sub}（≤ 46，不会被平台掐），${j.n429} 次 429 交给浏览器退避，20 组都按「没下结论」交回`);
  W.tmdb.fail = null;
  /* 第二轮（原名）网络失败：不再判成「认不出」 */
  W.tmdb.movie.push({ id: 990001, title: 'Zyxland', original_title: 'Zyxland', release_date: '2025-02-02', poster_path: '/z.jpg', popularity: 20, vote_average: 7, vote_count: 100 });
  W.tmdb.fail = (u) => /Zyxland/i.test(u.searchParams.get('query') || '') ? new TypeError('fetch failed') : null;
  const j2 = await (await I.call('/api/tm', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ g: [{ k: 'zz|zyxland', cn: '某某之地', la: 'Zyxland', ys: ['2025'], y: 2025, t: '某某之地 Zyxland.2025.1080p.WEB-DL' }] }) })).json();
  W.tmdb.fail = null;
  const j3 = await (await I.call('/api/tm', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ g: [{ k: 'zz|zyxland', cn: '某某之地', la: 'Zyxland', ys: ['2025'], y: 2025, t: '某某之地 Zyxland.2025.1080p.WEB-DL' }] }) })).json();
  ok(j2.r['zz|zyxland'] === 0 && j3.r['zz|zyxland'] && j3.r['zz|zyxland'].h && j3.r['zz|zyxland'].h[0] === 990001,
    '中文名没搜到、换原名那一轮又断网：交回「没下结论」而不是「认不出」；网好了再认就认下了（以前这里直接判 miss，帖子行只留 12 条）');

  /* 并发抓页：请求起点按间隔错开；冷启动只登录一次 */
  const e2 = H.makeEnv();
  makeForum(e2.W, { films: 30 });
  const stamps = []; let logins = 0;
  e2.W.forum.fail = (u) => { if (/forumdisplay/.test(u.search)) stamps.push(Date.now()); if (/loginsubmit=yes/.test(u.search)) logins++; return new Promise(r => setTimeout(() => r(null), 30)); };
  const J = H.isolate(e2.env, e2.W, { realTime: true });
  const rr = await (await J.call('/api/build?turbo=1&year=2025', { method: 'POST', headers: { 'content-type': 'application/json' }, body: '{"hits":[],"fly":[]}' })).json();
  const gaps = stamps.slice(1).map((x, i) => x - stamps[i]);
  ok(stamps.length >= 3 && Math.min(...gaps) >= 100 && logins === 1 && !rr.error,
    `一轮并发抓 ${stamps.length} 页：请求起点最少隔 ${Math.min(...gaps)}ms（下限 120ms，挨过打会翻倍），冷启动只登录 ${logins} 次`);
}

console.log('\n■ 影片表只增不减、旧对象延迟清理');
{
  const { env, r2, W } = H.makeEnv();
  makeForum(W);
  r2.m = new Map([...snapMid].map(([a, b]) => [a, { ...b }]));
  const I = H.isolate(env, W);
  const X = I.c;
  const mv = r2.json(NS + 'movies.json'), st = r2.json(NS + 'state.json');
  const n0 = Object.keys(mv.m).length;
  delete mv.m[Object.keys(mv.m)[0]];
  let threw = null;
  try { await X.commitIndex(env, null, mv, st, { m0: n0 }); } catch (e) { threw = e.message; }
  ok(threw && /不该删片/.test(threw) && Object.keys(r2.json(NS + 'movies.json').m).length === n0, '这一轮影片表要变少：拒绝提交（' + (threw || '').slice(0, 30) + '…）');
  /* grave：被替换下来的旧分片十分钟后才删，被引用的永远不删 */
  const b0 = r2.keys(NS).length;
  await buildAll(I);
  /* 来一个新帖：2025 年最后一片被替换成新代号，旧的那份进 grave */
  W.forum.boards['44']['movie_nianfen=32'].unshift({ tid: 99101, title: `${filmsE2E[1].cn} ${filmsE2E[1].en}.2025.1080p.WEB-DL.x264 9.1GB`, film: filmsE2E[1].id });
  await (await I.call('/api/incremental')).json();
  const grave = r2.json(NS + 'state.json').grave || [];
  ok(grave.length > 0 && grave.every(([k]) => r2.m.has(k)), `被替换下来的 ${grave.length} 个旧对象还在（十分钟内别的 isolate 可能还在读）`);
  I.clock.off += 11 * 60000;
  await (await I.call('/api/incremental')).json();
  const st2 = r2.json(NS + 'state.json');
  const live = new Set(); for (const [y, s] of Object.entries(st2.years)) { (s.pn || []).forEach((_, i) => live.add(NS + 'y' + y + (i ? '.p' + i : '') + (s.pg[i] ? '.g' + s.pg[i] : '') + '.json')); }
  ok(grave.every(([k]) => !r2.m.has(k) || live.has(k)) && [...live].every(k => r2.m.has(k)), '十分钟后清掉旧对象；现在引用着的一个不少');
  /* 孤儿：掐掉的轮次写了新代号却没提交 */
  r2.m.set(NS + 'y2025.p0.gorphan1.json', { body: '{}', etag: 'o', uploaded: new Date(Date.now() - 7 * 3600e3) });
  r2.m.set(NS + 'y2025.p0.gfresh01.json', { body: '{}', etag: 'o', uploaded: new Date() });
  const s3 = r2.json(NS + 'state.json'); s3.bakAt = 0; r2.m.set(NS + 'state.json', { body: JSON.stringify(s3), etag: 'z' });
  await I.cron();
  ok(!r2.m.has(NS + 'y2025.p0.gorphan1.json') && r2.m.has(NS + 'y2025.p0.gfresh01.json'), '每日维护清掉六小时以上没人引用的孤儿对象，刚写的不动');
  void b0;
}

console.log('\n■ 导入清单：库里没有的自动查好版本、放进片单（等人确认再下）');
{
  const { env, r2, W } = H.makeEnv({ RECV_BASE: 'https://recv.test' });
  makeForumU(W, 6);
  const FX = [
    /* 多版本：挑分辨率 / 杜比视界 / 体积上限 */
    { id: 960001, cn: '群星闪耀时', en: 'Stars Align', y: 2025, rel: ['2160p.DV.HDR.REMUX.HEVC 78.5GB', '2160p.HDR10.WEB-DL.HEVC 22.1GB', '1080p.BluRay.x264 14.2GB', '720p.WEB-DL.x264 3.1GB'] },
    /* TMDB 上另有别名：清单里写的是别名，索引里认不出，问 TMDB 拿编号 */
    { id: 960002, cn: '远方来信', en: 'Letters From Afar', y: 2025, aka: ['天涯尺素'], rel: ['1080p.WEB-DL.x264 6.2GB'] },
    /* 外语片：清单只写英文名，索引里存的是中文名和韩文原名 */
    { id: 960003, cn: '雨夜迷踪', orig: '비 오는 밤', en: 'Rainy Night Trail', y: 2024, rel: ['1080p.BluRay.x264 9.5GB'] },
    /* 同名两部（不同年）：不写年份 → 说不准；写了年份 → 认准那一部 */
    { id: 960004, cn: '无声告白录', en: 'Silent Letter', y: 2024, rel: ['1080p.WEB-DL.x264 4GB'] },
    { id: 960005, cn: '无声告白录', en: 'Silent Confession', y: 2025, rel: ['2160p.WEB-DL.HEVC 15GB'] },
    /* 库里已有 */
    { id: 960006, cn: '旧梦重温', en: 'Old Dreams Again', y: 2024, rel: ['1080p.BluRay.x264 8GB'] },
  ];
  let tid = 61000;
  for (const f of FX) {
    W.tmdb.movie.push({ id: f.id, title: f.cn, original_title: f.orig || f.en, en: f.en, aka: f.aka, release_date: f.y + '-03-01', poster_path: '/i' + f.id + '.jpg', popularity: 30, vote_average: 7, vote_count: 400 });
    const b = W.forum.boards['44']['movie_nianfen=' + (f.y === 2025 ? 32 : 31)];
    for (const r of f.rel) b.unshift({ tid: tid++, title: `${f.cn} ${f.en.replace(/ /g, '.')}.${f.y}.${r}`, film: f.id });
  }
  /* TMDB 有、论坛没有的片 */
  W.tmdb.movie.push({ id: 960099, title: '尚未发布', original_title: 'Not Yet Posted', release_date: '2025-08-01', poster_path: '/n.jpg', popularity: 5, vote_average: 6, vote_count: 50 });
  const I = H.isolate(env, W);
  await turboAll(I);
  const mv = r2.json(NS + 'movies.json');
  ok(FX.every(f => mv.m[f.id]), '准备：' + FX.length + ' 部测试片都进了索引');
  /* 片库：只有「旧梦重温」 */
  W.recv.files = { root: '/ram', _gen: 'g1', _ts: Date.now() - 60000, videos: [{ name: '旧梦重温.Old.Dreams.Again.2024.1080p.BluRay.x264.mkv', path: '/ram/旧梦重温.Old.Dreams.Again.2024.1080p.BluRay.x264.mkv' }] };
  W.recv.ptr = { g: 'g1' };
  await I.call('/api/lib?refresh=1'); await I.settle();
  for (let i = 0; i < 10; i++) { const r = await (await I.call('/api/lib?resolve=1')).json(); if (!r.left) break; }
  const someId = Object.keys(mv.m).map(Number).find(id => id >= 700000 && id < 710000);
  const post = async (items, src) => (await I.call('/api/import' + (src ? '?src=' + src : ''), { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ items }) })).json();
  const t0 = W.tmdb.calls || 0;
  const r = await post([
    { 'tmbd_id(1)': String(someId), title: mv.m[someId][0] },                 // 0 手误的键名 + 编号是字符串
    { tmdb_id: 960006, title: '旧梦重温' },                                   // 1 库里已有
    { title: '群星闪耀时', year: 2025, res: '1080p' },                          // 2 只写片名 + 偏好 1080p
    { tmdb_id: 960001, hdr: 'dv', note: '收藏版' },                            // 3 同一部再来一次 → dup
    { title: '天涯尺素', year: 2025 },                                          // 4 别名：问 TMDB
    { title: 'Rainy Night Trail', year: 2024 },                                 // 5 只有英文名
    { title: '无声告白录' },                                                    // 6 同名两部，没写年份 → 说不准
    { title: '无声告白录', year: 2025 },                                        // 7 写了年份 → 认准
    { tmdb_id: 960099, title: '尚未发布' },                                     // 8 论坛没有
    { title: '世上根本没有这部片', year: 2025 },                                // 9 哪儿都没有
    { year: 2024 },                                                             // 10 缺 id 和片名
    { tmdb_id: 'abc', title: 'x' },                                             // 11 编号不是数字
    { tmdb_id: 94997, type: 'tv', title: '某部剧' },                            // 12 剧集放到电影这边
  ]);
  const S = r.items.map(x => x.status);
  ok(r.items.length === 13 && r.lib === 1, '13 条全有结果，片库在线（' + S.join(' ') + '）');
  ok(S[0] === 'add' && r.items[0].id === someId && r.items[0].sid === mv.m[someId][12], '「tmbd_id(1)」这种带序号、拼错的键名照认；没写偏好 → 默认版本（与片单「加入」时一样）');
  ok(S[1] === 'owned' && r.items[1].own === 2, '库里已有的跳过（' + r.items[1].reason + '）');
  ok(S[2] === 'add' && r.items[2].id === 960001 && r.items[2].res === '1080p' && /14\.2/.test(r.items[2].size || ''), '只写片名 + 年份 + res: 1080p → 认出「群星闪耀时」，挑 1080p 的那版（' + r.items[2].size + '，' + r.items[2].label + '）');
  ok(S[3] === 'dup', '同一部在清单里出现两次：第二次标「重复」，不重复加');
  ok(S[4] === 'add' && r.items[4].id === 960002 && r.items[4].via, '清单写的是别名「天涯尺素」：索引里没有这个名字，问 TMDB 认出是「远方来信」（' + r.items[4].via + '）');
  ok(S[5] === 'add' && r.items[5].id === 960003, '只写英文名「Rainy Night Trail」：认出「' + r.items[5].title + '」');
  ok(S[6] === 'ambiguous' && r.items[6].cands.length === 2 && r.items[6].cands.every(c => [960004, 960005].includes(c.id)), '同名两部、没写年份：不乱挑，列出 2 个候选让人点');
  ok(S[7] === 'add' && r.items[7].id === 960005, '写了年份 2025：认准 2025 年那部');
  ok(S[8] === 'notfound' && r.items[8].tmdb === 960099 && !r.items[8].retry, 'TMDB 有、论坛没有：标「论坛暂无」（' + r.items[8].reason + '）');
  ok(S[9] === 'notfound' && /都没找到/.test(r.items[9].reason), '哪儿都没有的片名：「' + r.items[9].reason + '」');
  ok(S[10] === 'invalid' && S[11] === 'invalid' && S[12] === 'invalid', '格式不对的三条各说原因：' + [10, 11, 12].map(i => r.items[i].reason).join(' / '));
  ok(r.tmdb <= 30 && r.tmdb >= 1, `TMDB 只为索引里找不到的片名问（这次 ${r.tmdb} 个请求，上限 30）`);
  /* 偏好：杜比视界、体积上限、找不到时退而求其次 */
  const r2b = await post([
    { tmdb_id: 960001, hdr: 'dv' },
  ]);
  const r3 = await post([{ tmdb_id: 960001, max_gb: 10 }]);
  const r4 = await post([{ tmdb_id: 960001, res: '2160p', max_gb: 30 }]);
  const r5 = await post([{ tmdb_id: 960002, res: '2160p' }]);
  const r6 = await post([{ tmdb_id: 960002, max_gb: 1 }]);
  ok(r2b.items[0].hb === 7 && /78\.5/.test(r2b.items[0].size), 'hdr: dv → 杜比视界那版（' + r2b.items[0].size + '）');
  ok(/3\.1/.test(r3.items[0].size) && !r3.items[0].reason, 'max_gb: 10 → 10GB 以内最好的那版（' + r3.items[0].size + ' ' + r3.items[0].res + '）');
  ok(r4.items[0].res === '2160p' && /22\.1/.test(r4.items[0].size), 'res: 2160p + max_gb: 30 → 30GB 以内的 2160p（' + r4.items[0].size + '）');
  ok(r5.items[0].status === 'add' && r5.items[0].res === '1080p' && /最接近/.test(r5.items[0].reason), '要 2160p 但只有 1080p：照样加、说明「' + r5.items[0].reason + '」');
  ok(r6.items[0].status === 'add' && /GB 以内/.test(r6.items[0].reason), '体积上限谁都满足不了：取最小的、说明「' + r6.items[0].reason + '」');
  /* 编号是人给的：索引里没有这个编号、片名倒对上一部 —— 不自动加，交给人确认 */
  const r7 = await post([{ tmdb_id: 123456789, title: '群星闪耀时', year: 2025 }]);
  ok(r7.items[0].status === 'ambiguous' && r7.items[0].cands.length === 1 && r7.items[0].cands[0].id === 960001,
    'tmdb_id 不在索引里、片名对上一部：不自动加，列出来让人确认（' + r7.items[0].reason + '）');
  /* 接口：GET 不行、正文不对 400、超过一批的上限只处理前 30 条 */
  const g = await I.call('/api/import');
  const b = await I.call('/api/import', { method: 'POST', headers: { 'content-type': 'application/json' }, body: '{"x":1}' });
  const big = await post(Array.from({ length: 35 }, (_, i) => ({ tmdb_id: 990000 + i })));
  ok(g.status === 405 && b.status === 400 && big.items.length === 30 && big.more === 5, '接口：GET 405、正文不对 400、一次最多 30 条（多出的 ' + big.more + ' 条交回让前端下一批再发）');
  ok(!r2.keys('').some(k => /import/i.test(k)), '导入只读：R2 里没有多出任何东西');
}

console.log('\n■ 导入清单 · 剧集：只要整季包（全 N 集），索引里没有的去论坛搜索页搜');
{
  const { env, r2, W } = H.makeEnv();
  makeForumU(W, 2);
  const TV = [
    { id: 410001, name: '长夜将尽', en: 'Long Night', y: 2026, rel: [
      ['[全12集][中文字幕].Long.Night.S01.2026.1080p.WEB-DL.H264', '30.5GB'],
      ['[全12集][高码版][中文字幕].Long.Night.S01.2026.2160p.WEB-DL.H265.HDR', '88.1GB'],
      ['[第12集][中文字幕].Long.Night.S01E12.2026.2160p.WEB-DL.H265.DV', '9.9GB']] },
    { id: 410002, name: '山海回声', en: 'Echoes', y: 2025, rel: [
      ['[全10集].Echoes.S01.2025.1080p.WEB-DL.H264', '20GB'],
      [' 第二季[第3-4集].Echoes.S02.2026.2160p.WEB-DL.H265', '10GB'],
      [' 第二季[第5集].Echoes.S02.2026.2160p.WEB-DL.H265', '5GB']] },
  ];
  let tid = 81000;
  W.forum.boards['2'] = { 'tv_shangyingshijian_3=23': [], 'tv_shangyingshijian_3=22': [] };
  for (const s of TV) {
    W.tmdb.tv.push({ id: s.id, name: s.name, original_name: s.en, first_air_date: s.y + '-02-01', poster_path: '/tv' + s.id + '.jpg', popularity: 30, vote_average: 7.5, vote_count: 300 });
    for (const [r, sz] of s.rel) W.forum.boards['2']['tv_shangyingshijian_3=' + (/2026/.test(r) ? 23 : 22)].unshift({ tid: tid++, title: s.name + r + ' ' + sz });
  }
  /* 只在论坛搜索里出现的帖子（连载中 / 新剧：剧集版块的「已完结」筛选收不进索引） */
  const SO = [
    [420001, '夫妻的博弈', 'Mrs Revenge', 2026, ['夫妻的博弈[高码版][全25集][国粤多音轨/中文字幕].Mrs.Revenge.S01.2026.2160p.HQ.WEB-DL.H265.AAC.2Audio-BlackTV 123.42GB',
      '夫妻的博弈[全25集][中文字幕].Mrs.Revenge.S01.2026.1080p.WEB-DL.H264-BlackTV 40.2GB', '夫妻的博弈[第25集][中文字幕].Mrs.Revenge.S01E25.2026.2160p.WEB-DL.H265.DV-BlackTV 5.1GB']],
    [420002, '风，带有香气', 'Kaze Kaoru', 2026, ['风，带有香气[第123集][中文字幕].Kaze.Kaoru.S01.1080p.LINETV.WEB-DL.AAC2.0.H.264-BlackTV 0.34GB',
      '风，带有香气[第122集][中文字幕].Kaze.Kaoru.S01.1080p.LINETV.WEB-DL.AAC2.0.H.264-BlackTV 0.33GB']],
    [420003, '降世神通：七净土', 'Avatar Seven Havens', 2026, ['降世神通：七净土[全8集][中文字幕].Avatar.Seven.Havens.S01.2026.2160p.WEB-DL.H265 30GB']],
    [420004, '夜曲', 'Nocturne', 2026, ['夜曲之歌[全10集][中文字幕].Nocturne.Song.S01.2026.1080p.WEB-DL 10GB']],
    [420005, '金银岛', 'Treasure Island', 2026, ['金银岛[全6集][中文字幕].Treasure.Island.1999.1080p.BluRay 12GB']],
    [420006, '视界任务', 'Vision Quest', 2026, ['视界任务[全8集][中文字幕].Vision.Quest.S01.2026.2160p.WEB-DL.H265 40GB']],
  ];
  W.forum.searchOnly = [];
  for (const [id, name, en, y, titles] of SO) {
    W.tmdb.tv.push({ id, name, original_name: en, first_air_date: y + '-03-01', poster_path: '/so' + id + '.jpg', popularity: 20, vote_average: 7, vote_count: 100 });
    for (const t of titles) W.forum.searchOnly.push({ tid: tid++, title: t, fid: 2 });
  }
  /* 电影版块里同名的帖子：剧集搜索不能把它算进来 */
  W.forum.searchOnly.push({ tid: tid++, title: '夫妻的博弈[全25集].Mrs.Revenge.2026.2160p.REMUX 300GB', fid: 44 });
  const I = H.isolate(env, W);
  await turboAll(I, { src: 'tv' });
  const tvm = r2.json('idx/tv/v3.movies.json') || r2.json('idx/tv/movies.json') || { m: {} };
  ok(tvm.m[410001] && tvm.m[410002], '准备：两部剧进了剧集索引');
  const post = async (path, body) => (await I.call(path + '?src=tv', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) })).json();
  const r = await post('/api/import', { items: [{ tmdb_id: 410001, title: '长夜将尽' }, { title: '山海回声' }, { tmdb_id: 420001, title: '夫妻的博弈' }] });
  const [a, b, c] = r.items;
  ok(a.status === 'add' && a.res === '2160p' && /88\.1/.test(a.size) && /全12集/.test(a.label),
    '索引里有的剧：不拿默认最佳（那是「第12集」的单集 DV 版），挑全 12 集里画质最好的 2160p（' + a.size + '，锁定「' + a.label + '」）');
  ok(b.status === 'incomplete' && /第 2 季/.test(b.reason) && /第 5 集/.test(b.reason) && b.cands.length === 2 && /第 5 集/.test(b.cands[0].label) && /第 1 季全集/.test(b.cands[1].label),
    '第二季只有单集 / 一段：不加，标「未完结」（' + b.reason + '），给两个按钮：' + b.cands.map(x => x.label).join(' / '));
  ok(c.status === 'notfound' && c.fs === 1, '索引里没有的：标出来交给论坛搜索（' + c.reason + '）');
  const fs = (item, kw) => post('/api/fsearch', kw ? { item, kw } : { item });
  /* 跟着「换个名字再搜」走到底（浏览器也是这么做的） */
  const fsAll = async (item) => { let x = await fs(item), n = 0; const kws = [x.again]; while (x.status === 'again' && n++ < 4){ x = await fs(item, x.again); kws.push(x.again); } x.kws = kws.filter(Boolean); return x; };
  W.forum.searchLog = [];
  const f1 = await fs({ tmdb_id: 420001, type: 'tv', title: '夫妻的博弈' });
  ok(f1.status === 'add' && f1.ext === 1 && f1.id === 420001 && f1.res === '2160p' && /123\.42/.test(f1.size) && /全25集/.test(f1.label) && f1.sid && f1.poster === '/so420001.jpg',
    '论坛搜索「夫妻的博弈」：搜到 4 条，去掉单集和电影版块那条，挑全 25 集里最好的 2160p（' + f1.size + '，' + f1.label + '）');
  ok(W.forum.searchLog.length === 1 && W.forum.searchLog[0].kw === '夫妻的博弈', '搜索词按 GBK 编码发给论坛（论坛收到「' + (W.forum.searchLog[0] || {}).kw + '」）');
  W.forum.searchGap = 30;
  const f2 = await fs({ tmdb_id: 420002, type: 'tv', title: '风，带有香气' });
  ok(f2.status === 'wait' && f2.wait === 30, '论坛限频（「30 秒内只能进行一次搜索」）：把秒数交回，浏览器等够了再搜（wait ' + f2.wait + '）');
  W.forum.searchGap = 0;
  const f3 = await fs({ tmdb_id: 420002, type: 'tv', title: '风，带有香气' });
  ok(f3.status === 'incomplete' && /第 123 集/.test(f3.reason) && f3.cands.length === 1 && f3.cands[0].rec.sid,
    '只有单集（第 122、123 集）：不加，标「未完结」（' + f3.reason + '），可以手动「' + (f3.cands[0] || {}).label + '」');
  const f4 = await fs({ tmdb_id: 420003, type: 'tv', title: '降世神通：七净土' });
  ok(f4.status === 'add' && /全8集/.test(f4.label) && W.forum.searchLog.slice(-1)[0].kw === '降世神通 七净土', '片名里的全角冒号换成空格再搜（论坛的空格是 AND）：「降世神通 七净土」搜到全 8 集');
  const f5 = await fsAll({ tmdb_id: 420004, type: 'tv', title: '夜曲' });
  ok(f5.status === 'notfound' && f5.kws.join() === 'Nocturne', '「夜曲」搜到「夜曲之歌」：片名对不上；换英文原名「Nocturne」再搜一次还是对不上，不加（' + f5.reason + '）');
  const f6 = await fsAll({ tmdb_id: 420005, type: 'tv', title: '金银岛' });
  ok(f6.status === 'notfound', '「金银岛」搜到 1999 年的那部：早于首播年，不加（' + f6.reason + '）');
  const f7 = await fs({ tmdb_id: 420006, type: 'tv', title: '幻视任务' });
  const f8 = f7.again ? await fs({ tmdb_id: 420006, type: 'tv', title: '幻视任务' }, f7.again) : null;
  ok(f7.status === 'again' && f7.again === '视界任务' && f8 && f8.status === 'add' && f8.title === '视界任务',
    '清单里的译名「幻视任务」论坛搜不到：换 TMDB 的中文名「视界任务」再搜一次，搜到全 8 集');
  const f9 = await fs({ title: '风，带有香气', type: 'tv' });
  ok(f9.status === 'incomplete' && f9.cands[0].rec.id < 0, '没有 tmdb_id 也能搜：片单里用帖子号（负数）当编号，不会撞上 TMDB 编号');
  const bad = await I.call('/api/fsearch?src=tv');
  ok(bad.status === 405 && !r2.keys('').some(k => /fsearch|search/i.test(k)), '接口只收 POST；搜索只读，R2 里没多出东西');
}

console.log('\n■ 从 v5.4 的线上数据升级');
{
  const { env, r2, W } = H.makeEnv();
  makeForum(W);
  const OLD = process.env.IDX_OLD_WORKER;
  if (!OLD || !fs.existsSync(OLD)) ok(false, '缺 v5.4 原版（IDX_OLD_WORKER）：run.mjs 开头会从 git 取');
  else {
    const O = H.isolate(env, W, { file: OLD });
    for (let i = 0; i < 3; i++) await (await O.call('/api/build')).json();
    await O.settle();
    const st0 = r2.json(NS + 'state.json');
    ok(!st0.cid && Object.values(st0.years).every(y => !y.pg), 'v5.4 建的索引：没有提交号、分片是老键名');
    const N = H.isolate(env, W);
    const cat0 = await (await N.call('/api/catalog?min=0')).json();
    ok(cat0.total > 0 && !cat0.error, `新版直接读老索引：目录 ${cat0.total} 部`);
    const b = await buildAll(N);
    verify(N.c, r2, W, '在老索引上接着建完' + (b.err ? '（' + b.err + '）' : ''));
    N.clock.off += 11 * 60000;
    W.forum.boards['44']['movie_nianfen=32'].unshift({ tid: 99201, title: `${filmsE2E[2].cn} ${filmsE2E[2].en}.2025.720p.WEB-DL.x264 3.1GB`, film: filmsE2E[2].id });
    await (await N.call('/api/incremental')).json();
    const legacyLeft = r2.keys(NS).filter(k => /y\d{4}(\.p\d+)?\.json$|y\d{4}\.t\.json$/.test(k));
    verify(N.c, r2, W, '升级后再增量一次（老键名的旧对象十分钟后清掉：还剩 ' + legacyLeft.length + ' 个老键）');
  }
}

console.log('\n■ 剧集源 + 两个源轮流跑（定时任务）');
{
  const { env, r2, W } = H.makeEnv();
  makeForum(W, { films: 6 });
  W.tmdb.tv.push({ id: 1399, name: '权力的游戏', original_name: 'Game of Thrones', first_air_date: '2011-04-17', vote_count: 9000, vote_average: 8.4, poster_path: '/g.jpg', popularity: 80 },
                 { id: 94997, name: '龙之家族', original_name: 'House of the Dragon', first_air_date: '2022-08-21', vote_count: 4000, vote_average: 8.4, poster_path: '/h.jpg', popularity: 80 });
  W.forum.boards['2'] = { 'tv_shangyingshijian_3=22': [
    { tid: 20001, title: '龙之家族 第二季 House.of.the.Dragon.S02.2024.2160p.WEB-DL.DDP5.1.HEVC 40GB' },
    { tid: 20002, title: '龙之家族 第二季 House.of.the.Dragon.S02.2024.1080p.WEB-DL.x264 12GB' },
    { tid: 20003, title: '权力的游戏 第八季 Game.of.Thrones.S08.2019.1080p.BluRay.x264 30GB' },
  ] };
  const I = H.isolate(env, W);
  for (let i = 0; i < 12; i++) await I.cron();
  const tv = r2.json('idx/tv/movies.json'), mv = r2.json(NS + 'movies.json');
  ok(tv && tv.m[94997] && tv.m[1399] && mv && Object.keys(mv.m).length === 12 && !mv.m[94997] && !tv.m[filmsE2E[0].id],
    `两个源各建各的：剧集 ${tv ? Object.keys(tv.m).length : 0} 部、电影 ${mv ? Object.keys(mv.m).length : 0} 部，键不串`);
  const d = await (await I.call('/api/detail?id=94997&src=tv')).json();
  ok(d.items && d.items.length === 2 && d.items.every(x => x.sn === 2), '剧集详情按季标出（第二季两个版本）');
}

console.log('\n■ 重试匹配 / 重置年份 / 重算汇总 / 压实码本 / 体检');
{
  const { env, r2, W } = H.makeEnv();
  const films = makeForum(W);
  const I = H.isolate(env, W);
  await buildAll(I);
  W.tmdb.movie.push({ id: 880000, title: '无此片20250', original_title: 'Nonexistent Film 0', release_date: '2025-01-01', vote_count: 500, vote_average: 6, poster_path: '/n.jpg', popularity: 10 });
  const rr = await (await I.call('/api/repair?do=retryUnmatched')).json();
  const mv = r2.json(NS + 'movies.json');
  ok(rr.fixed >= 1 && mv.m[880000] && mv.m[880000][8] === 1, `重试匹配：TMDB 补了条目之后认回来（${rr.msg}）`);
  verify(I.c, r2, W, '重试匹配之后的不变量');
  const n24 = Object.values(r2.json(NS + 'movies.json').m).filter(m => (m[7] || []).length === 1 && m[7][0] === 2024).length;
  const rs = await (await I.call('/api/reset?year=2024')).json();
  ok(rs.dropped === n24 && !Object.values(r2.json(NS + 'movies.json').m).some(m => (m[7] || []).includes(2024)), `重置 2024 年：只在那一年的 ${rs.dropped} 部摘掉`);
  await buildAll(I);
  verify(I.c, r2, W, '重置后重建的不变量');
  const op = await (await I.call('/api/optimize?year=2025')).json();
  ok(!op.error, '压实码本：' + (op.msg || op.error));
  let rsy = null;
  for (let i = 0; i < 10; i++) { rsy = await (await I.call('/api/repair?do=resync')).json(); if (rsy.done) break; }
  ok(rsy && rsy.done, '重算汇总：' + (rsy && rsy.msg));
  verify(I.c, r2, W, '压实 + 重算之后的不变量');
  const dg = await (await I.call('/api/diagnose')).json();
  const fails = dg.checks.filter(c => c.level === 'fail').map(c => c.name + '：' + c.detail);
  ok(!dg.error && !fails.length, `体检跑通：${dg.checks.length} 项，${dg.verdict}${fails.length ? '；' + fails.join('；') : ''}`);
  void films;
}

console.log('\n■ 种子解析');
{
  const { env, W } = H.makeEnv();
  const I = H.isolate(env, W);
  const X = I.c;
  const single = H.torrent({ name: 'Dune.2021.mkv', length: 123456, 'piece length': 262144, pieces: Buffer.alloc(20, 7) });
  const multi = H.torrent({ 'name.utf-8': '沙丘', name: 'Dune', files: [{ length: 5, path: ['a.mkv'] }, { length: 7, path: ['name', '4:info.txt'] }], 'piece length': 16384, pieces: Buffer.alloc(40, 1) },
    { comment: 'contains 4:info and 4:name inside', 'announce-list': [['udp://a.test:1/announce'], ['https://b.test/announce']] });
  for (const [lab, t, nm] of [['单文件', single, 'Dune.2021.mkv'], ['多文件 + name.utf-8 + 注释里有「4:info」', multi, '沙丘']]) {
    const m = X.torrentMeta(t.bytes);
    const d = crypto.createHash('sha1').update(Buffer.from(t.bytes.subarray(m.info[0], m.info[1]))).digest('hex');
    ok(d === t.btih && m.name === nm, `${lab}：info 位置与 btih（${t.btih.slice(0, 10)}…）正确，片名「${m.name}」`);
  }
  ok(X.torrentMeta(multi.bytes).trackers.length === 3, 'tracker 取 announce 与 announce-list');
  let bad = 0, t0 = Date.now();
  for (let cut = 1; cut < single.bytes.length; cut += 3) { try { X.torrentMeta(single.bytes.subarray(0, cut)); } catch { bad++; } }
  ok(bad === Math.ceil((single.bytes.length - 1) / 3) && Date.now() - t0 < 2000, `截断在任意位置的种子都报错、不死循环（${bad} 种截法，${Date.now() - t0}ms）`);
  W.forum.threads[777] = { attach: [{ aid: 'A1', name: 'Dune.torrent', bytes: multi.bytes }] };
  const mg = await (await I.call('/api/magnet?aid=A1')).json();
  ok(mg.btih === multi.btih && mg.magnet.startsWith('magnet:?xt=urn:btih:' + multi.btih), '磁力链接的 btih 与独立计算的一致');
}

console.log('\n■ 取件');
{
  const { env, W } = H.makeEnv();
  const t = H.torrent({ name: 'X.mkv', length: 1, 'piece length': 16384, pieces: Buffer.alloc(20) });
  W.forum.threads[501] = { attach: [{ aid: 'B1', name: 'X.torrent', bytes: t.bytes }] };
  W.forum.threads[502] = { attach: [], magnets: ['magnet:?xt=urn:btih:' + 'a'.repeat(40)] };
  W.forum.threads[503] = { attach: [] };
  const I = H.isolate(env, W);
  const post = (items) => I.call('/api/fetch', { method: 'POST', body: JSON.stringify({ items }) }).then(r => r.json());
  const r = await post([{ tid: 501, name: 'X' }, { tid: 502, name: 'Y' }, { tid: 503, name: 'Z' }]);
  const a = r.items.find(x => x.tid === 501), b = r.items.find(x => x.tid === 502), c = r.items.find(x => x.tid === 503);
  ok(a.ok && Buffer.from(a.b64, 'base64').equals(Buffer.from(t.bytes)) && b.ok && b.kind === 'magnet' && !c.ok && !c.retry, '种子字节原样、磁力链接、没有附件的明确报失败');
  W.forum.fail = (u) => /viewthread/.test(u.search) ? new Response('busy', { status: 503 }) : null;
  const r2 = await post([{ tid: 601, name: 'W' }]);
  W.forum.fail = null;
  ok(r2.items[0].retry === 1 && r2.items[0].soft === 1, '论坛 503：标成「稍后重取」（浏览器数次数，连着 4 次才算失败），不直接记失败');
}

console.log('\n■ 边界与兜底');
{
  const { env, W } = H.makeEnv();
  const I = H.isolate(env, W, { expose: ['GN', 'GSRC', 'GLAST'] });
  W.img.fail = true;
  const im = await I.call('/img?p=/abc.jpg');
  ok(im.status === 502, '海报上游断网：回 502，不抛异常');
  const cat = await (await I.call('/api/catalog?page=abc&min=xyz')).json();
  ok(cat.page === 1 && !cat.error, '目录页码 / 评分参数乱填：按默认处理');
  /* 源闸门卡死：剧集那一批的后台任务永远不结束 */
  I.c.__set('GN', 1); I.c.__set('GSRC', 'tv'); I.c.__set('GLAST', Date.now() - 130000);
  const r = await I.call('/api/state?src=movie');
  ok(r.status === 200, '源闸门两分钟没有进出：判为卡死、强制放行，不再一直回 409');
}

console.log('\n■ 浏览器里的打包（ZIP / CRC32 / base64）');
{
  const src = fs.readFileSync(H.SRC_FILE, 'utf8');
  const ws = /<script id="wsrc" type="text\/plain">([\s\S]*?)<\/script>/.exec(src)[1];
  const posted = [];
  const ctx = vm.createContext({ TextEncoder, Uint8Array, Uint32Array, postMessage: (m) => posted.push(m) });
  vm.runInContext(ws, ctx);
  const files = [];
  for (let i = 0; i < 40; i++) files.push({ name: `第${i}部 影片 ${'名'.repeat(i % 5)}.torrent`, data: new Uint8Array(crypto.randomBytes(100 + i * 997)) });
  files.push({ name: '_清单.txt', data: new TextEncoder().encode('清单\n') });
  const z = ctx.zip(files);
  fs.mkdirSync('/tmp/idx-test', { recursive: true });
  fs.writeFileSync('/tmp/idx-test/t.zip', z);
  const py = execFileSync('python3', ['-c', `
import zipfile,hashlib,json
z=zipfile.ZipFile('/tmp/idx-test/t.zip')
bad=z.testzip()
print(json.dumps({'bad':bad,'n':len(z.namelist()),'h':[hashlib.md5(z.read(n)).hexdigest() for n in z.namelist()],'names':z.namelist()}))`]).toString();
  const pr = JSON.parse(py);
  const same = pr.n === files.length && pr.h.every((h, i) => h === crypto.createHash('md5').update(files[i].data).digest('hex')) && pr.names.every((n, i) => n === files[i].name);
  ok(pr.bad === null && same, `ZIP：${files.length} 个文件（中文名）用 Python zipfile 解开，CRC 校验通过、内容与文件名逐个一致`);
  const buf = crypto.randomBytes(70000);
  ok(ctx.crc32(new Uint8Array(buf)) === zlib.crc32(buf), 'CRC32 与 zlib 一致');
  const b64 = buf.toString('base64');
  ok(Buffer.from(ctx.unb64(b64)).equals(buf) && Buffer.from(ctx.unb64(Buffer.from('ab').toString('base64'))).toString() === 'ab', 'base64 解码与 Node 一致（含补位）');
}

console.log('\n■ 页面里的脚本都能解析');
{
  const { env, W } = H.makeEnv();
  const I = H.isolate(env, W);
  const html = await (await I.call('/')).text();
  const blocks = [...html.matchAll(/<script(?![^>]*type="text\/plain")[^>]*>([\s\S]*?)<\/script>/g)].map(m => m[1]);
  const errs = [];
  for (const b of blocks) { try { new vm.Script(b); } catch (e) { errs.push(e.message); } }
  ok(blocks.length >= 4 && !errs.length, `页面 ${blocks.length} 段内联脚本语法正确${errs.length ? '：' + errs.join('；') : ''}`);
}

console.log(`\n${fail ? '✗' : '✓'} ${pass} 通过，${fail} 失败`);
process.exit(fail ? 1 : 0);
