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
