// 请求添加 Worker 回归测试：node request/tests/run.mjs
// 不需要网络：D1 用 node:sqlite 的内存库模拟；影片库 / 传输 / PikPak / TMDB 分季 / 账户核对全部在这里模拟。
// 时钟是假的（Date.now 可拨），定时任务一轮一轮手动跑。
import { DatabaseSync } from 'node:sqlite';
import { pathToFileURL, fileURLToPath } from 'node:url';
import path from 'node:path';

const HERE = path.dirname(fileURLToPath(import.meta.url));
let pass = 0, failN = 0;
const ok = (cond, name, extra) => { if (cond) pass++; else { failN++; console.log('✗', name, extra !== undefined ? JSON.stringify(extra) : ''); } };

/* ── 假时钟 ── */
const realNow = Date.now;
let OFF = 0;
Date.now = () => realNow() + OFF;
const advance = (ms) => { OFF += ms; };

/* ── D1 ── */
class D1 {
  constructor(){ this.db = new DatabaseSync(':memory:'); }
  prepare(sql){
    const db = this.db;
    const st = { args: [],
      bind(...a){ st.args = a; return st; },
      async first(){ return db.prepare(sql).get(...st.args) ?? null; },
      async all(){ return { results: db.prepare(sql).all(...st.args) }; },
      async run(){ const r = db.prepare(sql).run(...st.args); return { meta: { changes: Number(r.changes), last_row_id: Number(r.lastInsertRowid) } }; },
    };
    return st;
  }
  async batch(list){ const out = []; for (const s of list) out.push(await s.run()); return out; }
}

/* ── 模拟的外部世界 ── */
const W = {
  files: new Map(),          // PikPak 文件：id → { id, name, kind, parent_id, size, phase, trashed }
  tasks: new Map(),          // PikPak 云下载任务：id → { id, phase, progress, file_id, file_name }
  seq: 1,
  versions: {},              // 'movie:550' / 'tv:1399:2' → items
  push: [],                  // 影片库收到的推送
  tf: [],                    // 传输收到的调用
  check: [],                 // 传输 check 依次回什么
  job: {},                   // jobid → { finished, success, bytes, total }
  exists: new Set(),         // dropbox:auto 下面有什么
  verifyOK: true,
  pkCalls: [],
  signins: 0,
  catalog: { movie: [], tv: [] },
  aired: { '1399:2': { total: 6, aired: 4 } },
};
const pkFolderWith = (name, children) => {
  const id = 'F' + (W.seq++);
  W.files.set(id, { id, name, kind: 'drive#folder', parent_id: 'AUTO', size: '0', phase: 'PHASE_TYPE_RUNNING', trashed: false });
  for (const [n, size] of children){
    const fid = 'f' + (W.seq++);
    W.files.set(fid, { id: fid, name: n, kind: 'drive#file', parent_id: id, size: String(size), phase: 'PHASE_TYPE_COMPLETE', trashed: false });
  }
  return id;
};
W.files.set('AUTO', { id: 'AUTO', name: 'auto', kind: 'drive#folder', parent_id: '', size: '0', phase: 'PHASE_TYPE_COMPLETE', trashed: false });
/* 推送一个 tid 时 PikPak 上落成什么：电影是带垃圾的文件夹，剧集是整季文件夹 */
const LAYOUT = {
  1: () => ['Fight.Club.1999.2160p.Remux', [['Fight.Club.1999.2160p.mkv', 60e9], ['sample.mkv', 2e8], ['最新地址.txt', 100]]],
  2: () => ['Fight.Club.1999.1080p.BluRay', [['Fight.Club.1999.1080p.mkv', 12e9], ['Fight.Club.sample.mkv', 1e8], ['www.ads.url', 50]]],
  10: () => ['权力的游戏.第2季[全4集].Game.of.Thrones.S02.2160p', [['S02E01.mkv', 5e9], ['S02E02.mkv', 5e9]]],
  11: () => ['Game.of.Thrones.S02.1080p.WEB-DL', [['S02E01.mkv', 2e9], ['S02E02.mkv', 2e9], ['S02E03.mkv', 2e9], ['S02E04.mkv', 2e9]]],
};
const finishTask = (taskId) => {
  const t = W.tasks.get(taskId);
  W.tasks.delete(taskId);
  const f = W.files.get(t.file_id); if (f) f.phase = 'PHASE_TYPE_COMPLETE';
};

const J = (o, status = 200) => new Response(JSON.stringify(o), { status, headers: { 'content-type': 'application/json' } });
globalThis.fetch = async (url, init = {}) => {
  const u = new URL(url), p = u.pathname, m = (init.method || 'GET').toUpperCase();
  const body = init.body ? JSON.parse(init.body) : null;
  const H = init.headers || {};
  /* 影片库 */
  if (u.host === 'lb.cuven.us'){
    if (H['x-gate'] !== 'gate') return J({ error: '口令不正确' }, 401);
    if (p === '/api/link/versions'){
      const src = u.searchParams.get('src'), id = u.searchParams.get('id'), season = u.searchParams.get('season');
      const key = src + ':' + id + (src === 'tv' ? ':' + (season || 2) : '');
      const items = W.versions[key];
      if (!items) return J({ error: '索引里没有这部影片' }, 404);
      return J({ id: +id, src, title: src === 'tv' ? '权力的游戏' : '搏击俱乐部', original: 'X', year: src === 'tv' ? '2011' : '1999', poster: '/p.jpg',
                 own: 0, seasons: src === 'tv' ? [1, 2] : [], season: src === 'tv' ? +(season || 2) : 0, items });
    }
    if (p === '/api/pikpush'){
      const it = body.items[0];
      W.push.push({ src: u.searchParams.get('src'), parent: body.parent, tid: it.tid });
      if (W.pushStop){ return J({ items: [{ tid: it.tid, ok: 0, retry: 1, held: 1 }], ok: 0, stop: W.pushStop }); }
      const [name, children] = LAYOUT[it.tid]();
      const fid = pkFolderWith(name, children);
      const task = 'T' + (W.seq++);
      W.tasks.set(task, { id: task, phase: 'PHASE_TYPE_RUNNING', progress: 0, file_id: fid, file_name: name });
      return J({ items: [{ tid: it.tid, ok: 1, task, name, file: fid, fileName: name }], ok: 1, stop: '' });
    }
    if (p === '/api/pikpak'){
      const act = u.searchParams.get('do');
      if (act === 'ls') return J({ parent: '', folders: [{ id: 'AUTO', name: 'auto' }, { id: 'X', name: 'other' }] });
      if (act === 'status') return J({ on: 1, ok: 1, user: 'pk***@x.com' });
    }
    if (p === '/api/catalog'){
      const src = u.searchParams.get('src');
      return J({ total: W.catalog[src].length, hidden: 0, page: 1, pages: 1, items: W.catalog[src], src });
    }
    return J({ error: 'lb 404 ' + p }, 404);
  }
  /* 传输 */
  if (u.host === 'transfer.cuven.us'){
    if (H['x-cuven-link'] !== 'link') return J({ error: '口令不对' }, 401);
    const op = p.replace('/api/link/', '');
    W.tf.push([op, body]);
    if (W.tfDown > 0){ W.tfDown--; return J({ error: 'HTTP 523 · Cloudflare 连不上 VPS（已自动重试 2 次）' }, 502); }
    const jobOf = (id) => W.job[id] || { finished: true, success: true, bytes: 1, total: 1 };
    switch (op){
      case 'ping': return J({ ok: 1, version: 'v1.68', core: 'test' });
      case 'organize': return J({ files: 3, deleted: ['ad.txt'], failed: [] });
      case 'check': return J(W.check.shift() || { k: 'ok', total: 4, vids: 4, have: [1, 2, 3, 4], miss: [], ongoing: false });
      case 'rename': return J({ name: 'Game.of.Thrones.S02.1080p.[Full-4]-Cuven®', jobid: 77 });
      case 'copy': return J({ jobid: (W.copyJobs || []).shift() || 88 });
      case 'job': return J({ error: '', speed: 2097152, ...jobOf(body.jobid) });
      case 'jobs': return J({ jobs: Object.fromEntries(body.ids.map(id => [id, { error: '', speed: 1, ...jobOf(id) }])) });
      case 'stop': (W.stopped = W.stopped || []).push(body.jobid); return J({ ok: 1 });
      case 'verify': {
        if (W.verifyDown){ W.verifyDown--; return J({ error: '核对时列 Dropbox 那边失败：HTTP 524', side: 'dst' }, 502); }
        const good = W.verifySeq && W.verifySeq.length ? W.verifySeq.shift() : W.verifyOK;
        return J(good
          ? { ok: 1, src: { count: 2, bytes: 9 }, dst: { count: 3, bytes: 10 }, missing: [], missingCount: 0, differ: [], differCount: 0, extra: 1 }
          : { ok: 0, src: { count: 2, bytes: 9 }, dst: { count: 1, bytes: 4 }, missing: ['E02.mkv'], missingCount: 1, differ: [], differCount: 0, extra: 0 });
      }
      case 'purge': W.exists.add(body.item); return J({ ok: 1 });
      case 'exists': return Array.isArray(body.items)
        ? J({ exists: Object.fromEntries(body.items.map(n => [n, W.exists.has(n) ? 1 : 0])) })
        : J({ exists: W.exists.has(body.item) ? 1 : 0 });
    }
    return J({ error: 'tf 404' }, 404);
  }
  /* TMDB 分季 */
  if (u.host === 'stream.cuven.online' && p === '/api/tmdb/season'){
    const a = W.aired[u.searchParams.get('id') + ':' + u.searchParams.get('season')] || { total: 0, aired: 0 };
    const eps = [];
    for (let i = 1; i <= a.total; i++) eps.push({ ep: i, air_date: i <= a.aired ? '2020-01-0' + i : '2999-01-01' });
    return J({ episodes: eps });
  }
  /* 账户 */
  if (u.host === 'check.cuven.us'){
    const name = decodeURIComponent(p.replace('/check/', ''));
    return J(['alice', 'bob', '小明'].includes(name) ? { exists: true, data: { username: name } } : { exists: false });
  }
  /* PikPak */
  if (u.host === 'user.mypikpak.com'){
    if (p === '/v1/shield/captcha/init') return J({ captcha_token: 'ct' });
    if (p === '/v1/auth/signin'){ W.signins++; return body.password === 'pkpass' ? J({ access_token: 'AT', refresh_token: 'RT', sub: 'S', expires_in: 7200 }) : J({ error: 'invalid_account_or_password' }, 400); }
    if (p === '/v1/auth/token') return J({ access_token: 'AT2', refresh_token: 'RT', expires_in: 7200 });
  }
  if (u.host === 'api-drive.mypikpak.com'){
    if (!String(H.authorization || '').startsWith('Bearer AT')) return J({ error: 'unauthenticated', error_code: 16 }, 401);
    W.pkCalls.push(m + ' ' + p);
    if (p === '/drive/v1/about') return J({ quota: { limit: '6597069766656', usage: '1099511627776' } });
    if (p === '/drive/v1/tasks' && m === 'GET') return J({ tasks: [...W.tasks.values()], next_page_token: '' });
    if (p === '/drive/v1/tasks' && m === 'DELETE'){
      for (const id of u.searchParams.getAll('task_ids')){
        const t = W.tasks.get(id); W.tasks.delete(id);
        if (t && u.searchParams.get('delete_files') === 'true'){ const f = W.files.get(t.file_id); if (f) f.trashed = true; }
      }
      return J({});
    }
    if (p.startsWith('/drive/v1/files/')){
      const f = W.files.get(decodeURIComponent(p.slice('/drive/v1/files/'.length)));
      return f ? J(f) : J({ error: 'file_not_found', error_code: 3 }, 404);
    }
    if (p === '/drive/v1/files' && m === 'GET'){
      const parent = u.searchParams.get('parent_id');
      return J({ files: [...W.files.values()].filter(f => f.parent_id === parent && !f.trashed), next_page_token: '' });
    }
    if (p === '/drive/v1/files:batchMove'){ for (const id of body.ids) W.files.get(id).parent_id = body.to.parent_id; return J({}); }
    if (p === '/drive/v1/files:batchTrash'){ for (const id of body.ids){ const f = W.files.get(id); if (f) f.trashed = true; } return J({}); }
  }
  throw new Error('unexpected fetch ' + m + ' ' + url);
};

const env = { DB: new D1(), ADMIN_KEY: 'admin-secret', LB_GATE: 'gate', LINK_KEY: 'link' };
/* 用户实测：D1 库是共用的，里面原来就有别人的 kv（没有 exp 列）、log（列也不一样）——
   v1.0 的 CREATE TABLE IF NOT EXISTS 跳过它们，一查就是 no such column: exp。
   现在表名带 tj_ 前缀，别人的表一点不碰；tj_kv 万一是缺列的老样子，自己补上 */
env.DB.db.exec("CREATE TABLE kv (k TEXT PRIMARY KEY, v TEXT)");
env.DB.db.exec("INSERT INTO kv (k, v) VALUES ('theirs', 'keep me')");
env.DB.db.exec("CREATE TABLE log (id INTEGER PRIMARY KEY, line TEXT)");
env.DB.db.exec("CREATE TABLE tj_kv (k TEXT PRIMARY KEY, v TEXT)");
const worker = (await import(pathToFileURL(path.join(HERE, '..', 'worker.js')).href)).default;
const call = async (method, p, { body, user, admin } = {}) => {
  const h = { 'content-type': 'application/json' };
  if (user) h['x-cuven-user'] = encodeURIComponent(user);
  if (admin) h['x-admin-key'] = admin === true ? env.ADMIN_KEY : admin;
  const r = await worker.fetch(new Request('https://tj.cuven.us' + p, { method, headers: h, body: body ? JSON.stringify(body) : undefined }), env, { waitUntil(){} });
  const txt = await r.text();
  let j; try { j = JSON.parse(txt); } catch { j = txt; }
  return [r.status, j];
};
const tick = async () => { advance(3 * 60000 + 6000); let pr; await worker.scheduled({}, env, { waitUntil(p){ pr = p; } }); await pr; };
const mine = async (user = 'alice') => (await call('GET', '/app/requests', { user }))[1].items;
const one = async (id) => (await call('GET', '/admin/api/state', { admin: true }))[1].reqs.find(r => r.id === id);

/* ── 面板口令、设置、PikPak 密码加密 ── */
{
  const [s1] = await call('GET', '/admin/api/state', { admin: 'wrong' });
  ok(s1 === 401, '面板：错口令 401');
  const [s2, st] = await call('POST', '/admin/api/cfg', { admin: true, body: { pkUser: 'pk@x.com', pkPass: 'pkpass', grp: 'Cuven®' } });
  ok(s2 === 200 && st.cfg.pkSet && st.cfg.pkUser === 'pk***@x.com', '面板：保存 PikPak 账号（只回打码的）', st.cfg);
  const raw = env.DB.db.prepare("SELECT v FROM tj_kv WHERE k = 'cfg'").get().v;
  ok(!raw.includes('pkpass') && raw.includes('pkPassEnc'), 'D1 里的 PikPak 密码是加密的');
  const [, pk] = await call('POST', '/admin/api/pk', { admin: true, body: {} });
  ok(pk.ok === 1 && pk.auto && pk.auto.same === 1, '面板：测试 PikPak 登录 + /auto 对得上', pk);
  const [, links] = await call('POST', '/admin/api/links', { admin: true, body: {} });
  ok(links.lb.ok && links.transfer.ok, '面板：影片库 / 传输都通', links);
}

/* ── 请求：账户核对、没资源、创建、跟上 ── */
W.versions['movie:550'] = [
  { tid: 1, title: 'Fight Club 1999 2160p Remux', mb: 60000, size: '58.6 GB', labels: ['4K', 'DV'], res: '2160p' },
  { tid: 2, title: 'Fight Club 1999 1080p BluRay', mb: 12000, size: '11.7 GB', labels: ['1080p'], res: '1080p' },
];
W.versions['movie:551'] = [];
let movieId;
{
  ok((await call('POST', '/app/requests', { body: { src: 'movie', id: 550 } }))[0] === 401, '没登录 401');
  ok((await call('POST', '/app/requests', { user: 'mallory', body: { src: 'movie', id: 550 } }))[0] === 401, '不存在的用户名 401');
  const [s0, none] = await call('POST', '/app/requests', { user: 'alice', body: { src: 'movie', id: 551 } });
  ok(s0 === 404 && none.none === 1, '没有资源的不收', none);
  ok((await call('POST', '/app/requests', { user: 'alice', body: { src: 'movie', id: 999 } }))[0] === 404, '索引里没有的 404');
  const [s1, a] = await call('POST', '/app/requests', { user: 'alice', body: { src: 'movie', id: 550 } });
  ok(s1 === 200 && a.created === 1 && a.request.step === 1 && a.request.pct === 0 && a.request.label === '等待制片商', '创建：STEP 1 / 0%', a);
  ok(!('note' in a.request) && !('spec' in a.request) && !('tries' in a.request), '给 App 的进度不带内部说明（note / 规格 / 试过几个）', a.request);
  movieId = a.request.id;
  const [, b] = await call('POST', '/app/requests', { user: '小明', body: { src: 'movie', id: 550 } });
  ok(b.joined === 1 && b.request.id === movieId, '同一部第二个人请求：跟上，不重复下', b);
  ok((await mine('小明')).some(r => r.id === movieId), '中文用户名（编码过的头）也认得');
}

/* ── 电影全流程：推送 → 失败换规格 → 下完 → 清洗 → 传输 → 核对 → 删 PikPak → 等发行 → 已发行 ── */
{
  await tick();
  let r = await one(movieId);
  ok(r.stage === 'download' && W.push.length === 1 && W.push[0].tid === 1 && W.push[0].parent === 'AUTO' && W.push[0].src === 'movie',
     '① 推送第一个规格到 /auto', { r, push: W.push });
  const t1 = [...W.tasks.keys()][0];
  W.tasks.get(t1).progress = 40;
  await tick();
  r = (await mine()).find(x => x.id === movieId);
  ok(r.step === 2 && r.pct === 28 && r.label === '等待回应', '② 云下载 40% → STEP 2 / 28%', r);
  W.tasks.get(t1).phase = 'PHASE_TYPE_ERROR';
  const f1 = W.tasks.get(t1).file_id;
  await tick();
  r = await one(movieId);
  ok(r.stage === 'queued' && r.tried === 1 && !W.tasks.has(t1) && W.files.get(f1).trashed, '云下载出错：删任务和文件，换下一个规格', r);
  await tick();
  r = await one(movieId);
  ok(r.stage === 'download' && W.push.length === 2 && W.push[1].tid === 2, '推第二个规格', W.push);
  const t2 = [...W.tasks.keys()][0];
  const f2 = W.tasks.get(t2).file_id;
  finishTask(t2);
  await tick();
  r = await one(movieId);
  ok(r.stage === 'clean', '下完 → 清洗', r);
  await tick();
  r = await one(movieId);
  const big = [...W.files.values()].find(f => f.name === 'Fight.Club.1999.1080p.mkv');
  ok(r.stage === 'copy' && big.parent_id === 'AUTO' && W.files.get(f2).trashed && r.item === 'Fight.Club.1999.1080p.mkv',
     '清洗：最大的视频移到 /auto，原文件夹进回收站', { r, big });
  W.job[88] = { finished: false, success: false, bytes: 500, total: 1000 };
  await tick();
  ok(W.tf.some(([op, b]) => op === 'copy' && b.item === 'Fight.Club.1999.1080p.mkv' && b.kind === 'file'), '④ 触发 webdav → dropbox 复制（文件）');
  await tick();
  r = (await mine()).find(x => x.id === movieId);
  ok(r.step === 4 && r.pct === 69 && r.label === '等待传输' && r.note === undefined, '传输 50% → STEP 4 / 69%（App 看不到内部说明）', r);
  ok(/50%/.test((await one(movieId)).note), '控制面板看得到「传输到 Dropbox 50%」');
  W.job[88] = { finished: true, success: true, bytes: 1000, total: 1000 };
  await tick();
  ok((await one(movieId)).stage === 'verify', '传完 → 核对');
  await tick();
  ok((await one(movieId)).stage === 'purge', '核对一致 → 删 PikPak');
  await tick();
  r = (await mine()).find(x => x.id === movieId);
  ok(r.stage === 'release' && r.step === 5 && r.pct === 80 && r.label === '最终发行审批', '⑤ 最终发行审批：STEP 5 / 80%', r);
  ok(W.tf.findIndex(([op]) => op === 'verify') < W.tf.findIndex(([op]) => op === 'purge'), '先核对再删除');
  await tick();
  ok((await one(movieId)).stage === 'release', '5 分钟内不去看');
  advance(6 * 60000); await tick();
  ok((await one(movieId)).stage === 'release', '还在 dropbox:/auto → 继续等');
  W.exists.delete('Fight.Club.1999.1080p.mkv');
  advance(6 * 60000); await tick();
  r = (await mine()).find(x => x.id === movieId);
  ok(r.state === 'done' && r.pct === 100, '人工挪走 → 已发行 100%', r);
}

/* ── 剧集：不完整就降档；标题没写总集数按 TMDB 已播出的核对；改名；传文件夹 ── */
W.versions['tv:1399:2'] = [
  { tid: 10, title: '权力的游戏 第2季 全4集 2160p', mb: 20000, labels: ['4K'], res: '2160p', total: 4, pack: 'full' },
  { tid: 11, title: 'Game of Thrones S02 1080p WEB-DL', mb: 8000, labels: ['1080p'], res: '1080p', total: 0, pack: '?' },
];
let tvId;
{
  const [s, a] = await call('POST', '/app/requests', { user: 'bob', body: { src: 'tv', id: 1399, season: 2 } });
  ok(s === 200 && a.request.season === 2, '剧集按季请求', a);
  tvId = a.request.id;
  ok((await call('POST', '/app/requests', { user: 'bob', body: { src: 'tv', id: 1399 } }))[0] === 400, '剧集不说第几季 400');
  await tick();
  let t = [...W.tasks.keys()][0];
  finishTask(t);
  W.check.push({ k: 'short', total: 4, vids: 2, have: [1, 2], miss: [3, 4], ongoing: false });
  await tick();
  let r = await one(tvId);
  ok(r.stage === 'check', '剧集下完 → 整理 + 核对', r);
  await tick();
  r = await one(tvId);
  ok(r.stage === 'queued' && r.tried === 1, '缺集 → 降档重试', r);
  const org = W.tf.find(([op]) => op === 'organize');
  ok(org && /全4集/.test(org[1].dir), '先整理文件夹（删垃圾）', org);
  const chk1 = W.tf.filter(([op]) => op === 'check')[0];
  ok(chk1[1].total === 4, '核对用标题里写的总集数', chk1);
  await tick();
  t = [...W.tasks.keys()][0];
  finishTask(t);
  await tick(); await tick();
  r = await one(tvId);
  const chk2 = W.tf.filter(([op]) => op === 'check')[1];
  ok(chk2 && chk2[1].total === 4, '标题没写总集数：按 TMDB 已播出的 4 集核对', chk2);
  ok(r.stage === 'rename', '整季完整 → 改名', r);
  W.job[77] = { finished: false, success: false, bytes: 1, total: 2 };
  await tick();
  r = (await mine('bob')).find(x => x.id === tvId);
  ok(r.step === 3 && r.stage === 'rename', '改名中 STEP 3', r);
  W.job[77] = { finished: true, success: true, bytes: 2, total: 2 };
  await tick();
  r = await one(tvId);
  ok(r.stage === 'copy' && r.item === 'Game.of.Thrones.S02.1080p.[Full-4]-Cuven®', '改好名 → 传输', r);
  W.verifyOK = false;
  W.job[88] = { finished: true, success: true, bytes: 1, total: 1 };
  await tick(); await tick(); await tick(); await tick();      // 开传输 → 传完 → 核对不一致 → 再核对还不一致
  r = await one(tvId);
  ok(r.stage === 'copy' && /补传 1 个文件/.test(r.note), '两端对不上：先再核对一次，还对不上才补传缺的那 1 个，不删 PikPak', r);
  ok(!W.tf.some(([op, b]) => op === 'purge' && b.item === r.item), '对不上时没有删除');
  W.verifyOK = true;
  await tick(); await tick(); await tick(); await tick();
  r = await one(tvId);
  ok(r.stage === 'release' && W.tf.some(([op, b]) => op === 'copy' && b.kind === 'dir'), '剧集按文件夹传完，等发行', r);
}

/* ── 目录 / 详情：带上请求进度 ── */
W.catalog.movie = [{ id: 550, title: '搏击俱乐部', year: '1999', poster: '/p.jpg', vote: 8.4, res: '2160p', hb: 7, rb: 6, own: 0, sid: 'secret' },
                   { id: 600, title: 'B', year: '2001', poster: '', vote: 7, own: 1 }];
W.catalog.tv = [{ id: 1399, title: '权力的游戏', year: '2011', poster: '/g.jpg', vote: 8.5, own: 0 }];
{
  const [s, c] = await call('GET', '/app/catalog?src=all&q=游戏');
  ok(s === 200 && c.items.length === 3 && c.items[0].src === 'movie' && c.items[1].src === 'tv', '目录：电影和剧集交替排', c.items.map(x => x.src));
  ok(!('sid' in c.items[0]), '目录不外露帖子编号');
  ok(c.items[0].req && c.items[0].req.state === 'done' && c.items[1].req && c.items[1].req.step === 5, '目录条目带请求进度', c.items);
  const [, d] = await call('GET', '/app/detail?src=tv&id=1399&season=2');
  ok(d.known === 1 && d.count === 2 && d.seasons.length === 2 && d.req && d.req.id === tvId && d.reqs['2'], '详情：剧集这一季的请求', d);
  const [, d2] = await call('GET', '/app/detail?src=movie&id=777');
  ok(d2.known === 0 && d2.count === 0, '详情：索引里没有的', d2);
}

/* ── 限额、刚失败过、面板操作 ── */
{
  for (let i = 0; i < 5; i++) W.versions['movie:' + (700 + i)] = [{ tid: 1, title: 'x', mb: 1, labels: [], res: '1080p' }];
  W.versions['movie:705'] = [{ tid: 1, title: 'x', mb: 1, labels: [], res: '1080p' }];
  for (let i = 0; i < 5; i++) await call('POST', '/app/requests', { user: 'alice', body: { src: 'movie', id: 700 + i } });
  const [s, j] = await call('POST', '/app/requests', { user: 'alice', body: { src: 'movie', id: 705 } });
  ok(s === 429 && j.cap === 'user', '一个用户同时最多 5 个', j);
  const id700 = (await mine()).find(r => r.tmdb === 700).id;
  const [, c1] = await call('POST', '/admin/api/req', { admin: true, body: { id: id700, act: 'cancel' } });
  ok(c1.request.state === 'cancelled' && c1.request.step === 1, '面板：取消（停在出事的那一步）', c1);
  const [, rt] = await call('POST', '/admin/api/req', { admin: true, body: { id: id700, act: 'retry' } });
  ok(rt.request.state === 'active' && rt.request.stage === 'queued', '面板：重试', rt);
  /* 所有规格都失败 → failed；一天之内再请求拿回那条失败的 */
  W.versions['movie:800'] = [{ tid: 2, title: 'only', mb: 1, labels: [], res: '1080p' }];
  const [, a] = await call('POST', '/app/requests', { user: 'bob', body: { src: 'movie', id: 800 } });
  const id800 = a.request.id;
  /* 只推进这一条：把别的往后推 */
  env.DB.db.prepare('UPDATE tj_req SET next = ? WHERE id != ?').run(Date.now() + 86400000 * 9, id800);
  await tick();
  const t = [...W.tasks.values()].find(x => x.file_name.includes('1080p.BluRay'));
  W.tasks.get(t.id).phase = 'PHASE_TYPE_ERROR';
  await tick(); await tick();
  const r = (await mine('bob')).find(x => x.id === id800);
  ok(r.state === 'failed' && r.note === undefined && /所有规格都试过了/.test((await one(id800)).note), '所有规格都失败 → 失败（原因只在控制面板里）', r);
  const [, again] = await call('POST', '/app/requests', { user: 'bob', body: { src: 'movie', id: 800 } });
  ok(again.failedRecently === 1 && again.request.id === id800, '刚失败过：一天内不重开', again);
  advance(86400000 + 1000);
  const [, later] = await call('POST', '/app/requests', { user: 'bob', body: { src: 'movie', id: 800 } });
  ok(later.created === 1 && later.request.id !== id800, '过一天可以重新请求', later);
}

/* ── PikPak 没配账号：下载那一步停下来等，不报错不换规格 ── */
{
  await call('POST', '/admin/api/cfg', { admin: true, body: { pkClear: true } });
  env.DB.db.prepare("UPDATE tj_req SET next = 0 WHERE stage = 'download'").run();
  const before = W.push.length;
  await tick(); await tick();          // 这一轮刚推送进 download 的，下一轮才走到要 PikPak 的那一步
  const st = (await call('GET', '/admin/api/state', { admin: true }))[1];
  const dl = st.reqs.filter(r => r.stage === 'download');
  ok(dl.length && dl.every(r => /PikPak 账号/.test(r.note)) && W.push.length >= before, '没配 PikPak：等，不换规格', dl.map(r => r.note));
  ok(!st.cfg.pkSet, '清掉了 PikPak 账号');
}


/* ══ v2.0 核心：资源位、公平排队、批量轮询、看门狗、作业丢失、熔断、ETag ══
   清空队列重新来，免得前面的请求占着资源位 */
{
  env.DB.db.exec('DELETE FROM tj_req');
  env.DB.db.exec("DELETE FROM tj_kv WHERE k IN ('health', 'tick:last')");
  await call('POST', '/admin/api/cfg', { admin: true, body: { pkUser: 'pk@x.com', pkPass: 'pkpass', pkSlots: 2, vpsSlots: 1 } });
  for (const id of [901, 902, 903, 904]) W.versions['movie:' + id] = [{ tid: 2, title: 'Movie ' + id + ' 1080p', mb: 1, labels: [], res: '1080p' }];
  const ids = {};
  for (const id of [901, 902, 903]) ids[id] = (await call('POST', '/app/requests', { user: 'alice', body: { src: 'movie', id } }))[1].request.id;
  ids[904] = (await call('POST', '/app/requests', { user: 'bob', body: { src: 'movie', id: 904 } }))[1].request.id;
  const st = async () => (await call('GET', '/admin/api/state', { admin: true }))[1];
  const of = (s, tm) => s.reqs.find(r => r.tmdb === tm);

  await tick();
  let s = await st();
  ok(of(s, 901).stage === 'download' && of(s, 904).stage === 'download' && of(s, 902).stage === 'queued' && of(s, 903).stage === 'queued',
     '资源位 2 个：每个人的第一个先上（alice 的第一部 + bob 的那部），alice 的另外两部排队', s.reqs.map(r => [r.tmdb, r.stage]));
  ok(/PikPak 同时云下载已满/.test(of(s, 902).note) && of(s, 902).errs === 0, '排队等位子不算出错', of(s, 902));
  ok(s.slots.pk.used === 2 && s.slots.pk.max === 2 && of(s, 902).pos === 1 && of(s, 903).pos === 2, '面板：资源位 2 / 2，排队第 1、2 位', { slots: s.slots, p2: of(s, 902).pos, p3: of(s, 903).pos });
  ok((await mine()).every(r => r.note === undefined && r.pos === undefined), 'App 看不到排队细节');

  /* 两部下完 → 清洗 → 传输：VPS 只给 1 个位子，第二部排队 */
  for (const t of [...W.tasks.keys()]) finishTask(t);
  W.copyJobs = [501, 502];
  W.job[501] = { finished: false, success: false, bytes: 100, total: 1000 };
  W.job[502] = { finished: false, success: false, bytes: 200, total: 1000 };
  await tick();          // download → clean（腾出 PikPak 位子：排队的两部推上去）
  s = await st();
  ok(of(s, 902).stage === 'download' && of(s, 903).stage === 'download', '前面的下完腾出位子，排队的接着推', s.reqs.map(r => [r.tmdb, r.stage]));
  await tick();          // clean → copy
  await tick();          // copy：一个开传输，一个排队
  s = await st();
  const copying = s.reqs.filter(r => r.stage === 'copy');
  ok(copying.length === 2 && copying.filter(r => /VPS 同时传输已满/.test(r.note)).length === 1 && s.slots.vps.used === 1,
     'VPS 只给 1 个传输位子：第二部排队', copying.map(r => [r.tmdb, r.note]));
  await call('POST', '/admin/api/cfg', { admin: true, body: { vpsSlots: 2 } });
  await tick();
  s = await st();
  ok(s.slots.vps.used === 2, '位子调成 2：第二部也开始传', s.slots);

  /* 批量轮询：两个传输作业一轮只问一次 */
  const before = W.tf.length;
  W.job[501].bytes = 150; W.job[502].bytes = 260;
  await tick();
  const ops = W.tf.slice(before).map(x => x[0]);
  ok(ops.filter(o => o === 'jobs').length === 1 && !ops.includes('job'), '两个传输作业：一轮只发一次 /api/link/jobs', ops);

  /* 看门狗：501 一小时没有新字节 → 停掉重开；502 的作业丢了（VPS 重启）→ 从断点重开 */
  W.job[502] = { missing: 1, finished: true, success: false, error: 'job not found' };
  W.job[501].bytes = 150;
  advance(61 * 60000);
  W.copyJobs = [601, 602];
  await tick();
  s = await st();
  ok((W.stopped || []).includes(501), '传输一小时没进展：先停掉作业', W.stopped);
  const notes = (await call('GET', '/admin/api/log?id=' + ids[901], { admin: true }))[1].items.map(l => l.msg)
    .concat((await call('GET', '/admin/api/log?id=' + ids[904], { admin: true }))[1].items.map(l => l.msg))
    .concat((await call('GET', '/admin/api/log?id=' + ids[902], { admin: true }))[1].items.map(l => l.msg))
    .concat((await call('GET', '/admin/api/log?id=' + ids[903], { admin: true }))[1].items.map(l => l.msg));
  ok(notes.some(m => /没有进展，停掉重开/.test(m)) && notes.some(m => /作业没了/.test(m)), '日志里写着停掉重开、作业丢了重开', notes.filter(m => /进展|没了/.test(m)));
  const copiesBefore = W.tf.filter(x => x[0] === 'copy').length;
  await tick();
  ok(W.tf.filter(x => x[0] === 'copy').length >= copiesBefore + 2, '两部都重新开了传输（copy 会跳过传完的）');

  /* 熔断：VPS 连着出错 3 次 → 熔断，后面几轮不再去碰它，请求原地等、不算出错 */
  W.tfDown = 99;
  const tickShort = async () => { advance(61000); let pr; await worker.scheduled({}, env, { waitUntil(p){ pr = p; } }); await pr; };
  env.DB.db.prepare("UPDATE tj_req SET next = 0 WHERE stage = 'copy'").run();
  await tickShort();
  s = await st();
  ok(s.health.vps.open > s.now && /523/.test(s.health.vps.err), 'VPS 连着失败：熔断（面板看得到原因）', s.health.vps);
  const callsAtOpen = W.tf.length;
  env.DB.db.prepare("UPDATE tj_req SET next = 0 WHERE stage = 'copy'").run();
  await tickShort();
  s = await st();
  ok(W.tf.length === callsAtOpen, '熔断中：这一轮一次都没去碰 VPS', W.tf.slice(callsAtOpen).map(x => x[0]));
  ok(s.reqs.filter(r => r.stage === 'copy').every(r => /暂时不可用/.test(r.note) && r.state === 'active'), '要用 VPS 的请求原地等，不失败', s.reqs.map(r => [r.stage, r.note, r.errs]));
  W.tfDown = 0;
  advance(3 * 60000);
  await tickShort();
  s = await st();
  ok(!(s.health.vps.open > s.now) && s.health.vps.trips === 0, '到期试探一次，通了就恢复', s.health.vps);

  /* ETag：没变就 304 */
  const get = (tag) => worker.fetch(new Request('https://tj.cuven.us/app/requests', { headers: { 'x-cuven-user': 'alice', ...(tag ? { 'if-none-match': tag } : {}) } }), env, {});
  const r1 = await get();
  const tag = r1.headers.get('etag');
  const r2 = await get(tag);
  ok(r1.status === 200 && tag && r2.status === 304 && (await r2.text()) === '', '我的请求没变：304 不带正文', { s1: r1.status, tag, s2: r2.status });

  /* 发行检查（只剩一条在等发行时单独问）：不在 /auto 了就是已发行 */
  const rid = ids[903];
  env.DB.db.prepare("UPDATE tj_req SET stage = 'release', next = 0, data = json_set(data, '$.item', 'gone.mkv') WHERE id = ?").run(rid);
  await tickShort();
  s = await st();
  ok(of(s, 903).state === 'done', '发行检查：不在 /auto 了就是已发行', of(s, 903));
}


/* ══ 两端核对（用户：「经常触发两端核对不一致，重新传输」）══ */
{
  env.DB.db.exec('DELETE FROM tj_req');
  env.DB.db.exec("DELETE FROM tj_kv WHERE k IN ('health', 'tick:last')");
  W.versions['movie:950'] = [{ tid: 2, title: 'Verify 1080p', mb: 1, labels: [], res: '1080p' }];
  const id = (await call('POST', '/app/requests', { user: 'alice', body: { src: 'movie', id: 950 } }))[1].request.id;
  W.job[88] = { finished: true, success: true, bytes: 1, total: 1 };
  W.copyJobs = [];
  await tick();                                   // 推送
  for (const t of [...W.tasks.keys()]) finishTask(t);
  await tick(); await tick(); await tick();        // 下完 → 清洗 → 开传输
  const copies = () => W.tf.filter(x => x[0] === 'copy');
  const nCopy0 = copies().length;
  await tick();                                   // 传完 → 核对（等 45 秒再核对）
  let r = await one(id);
  ok(r.stage === 'verify' && r.next - Date.now() > 30000, '传完先等一会儿再核对（两边列表刷新）', r);

  /* 列目录失败：没核对成，过会儿再核对，不补传、不算补传次数 */
  W.verifyDown = 1;
  await tick();
  r = await one(id);
  ok(r.stage === 'verify' && copies().length === nCopy0 && /列目录失败|列 Dropbox/.test(r.note), '核对时列目录失败：不当不一致、不补传', r);

  /* 第一次不一致：再核对一次就好了（列表刚刷新）→ 不补传 */
  W.verifySeq = [false, true];
  await tick(); r = await one(id);
  ok(r.stage === 'verify' && /2 分钟后再核对一次/.test(r.note) && copies().length === nCopy0, '第一次不一致：2 分钟后再核对，不马上重传', r);
  await tick(); r = await one(id);
  ok(r.stage === 'purge' && copies().length === nCopy0, '再核对一次就一致了：一次都没重传', r);
  const log = (await call('GET', '/admin/api/log?id=' + id, { admin: true }))[1].items.map(l => l.msg);
  ok(log.some(m => /两端核对一致：2 个文件.*Dropbox 那边多 1 个，不影响/.test(m)), '日志：一致（Dropbox 多出来的不算）', log.slice(0, 4));
  ok(log.some(m => /缺 1 个.*E02\.mkv/.test(m)), '日志：写清楚缺了哪个文件', log.filter(m => /不一致/.test(m)));
}
{
  /* 一直不一致：补传缺的（第一次走 WebDAV，第二次起改从 PikPak 原生接口、只按大小），补传 3 次还不行才停下 */
  env.DB.db.exec('DELETE FROM tj_req');
  W.versions['movie:951'] = [{ tid: 2, title: 'Verify2 1080p', mb: 1, labels: [], res: '1080p' }];
  const id = (await call('POST', '/app/requests', { user: 'alice', body: { src: 'movie', id: 951 } }))[1].request.id;
  await tick();
  for (const t of [...W.tasks.keys()]) finishTask(t);
  await tick(); await tick(); await tick(); await tick();     // → verify
  W.verifySeq = []; W.verifyOK = false;
  const copyArgs = () => W.tf.filter(x => x[0] === 'copy').map(x => x[1]);
  const n0 = copyArgs().length, tf0 = W.tf.length;
  const toCopy = async () => { for (let i = 0; i < 6; i++){ await tick(); if ((await one(id)).stage !== 'verify') break; } };
  await toCopy();
  let r = await one(id);
  ok(r.stage === 'copy' && /补传 1 个文件/.test(r.note), '两次核对都不一致：补传缺的那 1 个', r);
  await tick();                                                 // 开补传
  ok(copyArgs().length === n0 + 1 && !copyArgs()[n0].from, '第一次补传还是从 WebDAV', copyArgs()[n0]);
  await tick(); await toCopy(); await tick();                   // 传完 → 核对两次 → 第二次补传
  const second = copyArgs()[n0 + 1];
  ok(second && second.from === 'pikpak' && second.sizeOnly === 1, '第二次补传改从 PikPak 原生接口、只按大小', second);
  for (let i = 0; i < 12; i++){ await tick(); if ((await one(id)).state === 'failed') break; }
  r = await one(id);
  ok(r.state === 'failed' && /补传 3 次后两端还是对不上（缺 1 个）/.test(r.note), '补传 3 次还对不上：停下，原因写清楚', r);
  ok(!W.tf.slice(tf0).some(([op]) => op === 'purge'), '一直对不上：PikPak 那份没删');
  W.verifyOK = true;
}

/* ── 共用的 D1：别人的表原样不动，自己的表缺的列补上了 ── */
{
  const theirs = env.DB.db.prepare("SELECT v FROM kv WHERE k = 'theirs'").get();
  const kvCols = env.DB.db.prepare('PRAGMA table_info(kv)').all().map(c => c.name);
  const logCols = env.DB.db.prepare('PRAGMA table_info(log)').all().map(c => c.name);
  ok(theirs && theirs.v === 'keep me' && kvCols.join() === 'k,v' && logCols.join() === 'id,line', '共用的 D1：别人的 kv / log 表一点没动', { kvCols, logCols });
  const tjCols = env.DB.db.prepare('PRAGMA table_info(tj_kv)').all().map(c => c.name);
  ok(tjCols.includes('exp'), '缺 exp 列的 tj_kv 自己补上了', tjCols);
}

console.log(`\n请求添加 Worker：${pass} 项通过，${failN} 项失败`);
process.exit(failN ? 1 : 0);
