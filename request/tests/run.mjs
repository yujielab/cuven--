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
    switch (op){
      case 'ping': return J({ ok: 1, version: 'v1.68', core: 'test' });
      case 'organize': return J({ files: 3, deleted: ['ad.txt'], failed: [] });
      case 'check': return J(W.check.shift() || { k: 'ok', total: 4, vids: 4, have: [1, 2, 3, 4], miss: [], ongoing: false });
      case 'rename': return J({ name: 'Game.of.Thrones.S02.1080p.[Full-4]-Cuven®', jobid: 77 });
      case 'copy': return J({ jobid: 88 });
      case 'job': { const s = W.job[body.jobid] || { finished: true, success: true, bytes: 1, total: 1 }; return J({ error: '', speed: 2097152, ...s }); }
      case 'verify': return J({ ok: W.verifyOK ? 1 : 0, src: { count: 1, bytes: 9 }, dst: { count: W.verifyOK ? 1 : 0, bytes: 9 } });
      case 'purge': W.exists.add(body.item); return J({ ok: 1 });
      case 'exists': return J({ exists: W.exists.has(body.item) ? 1 : 0 });
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
const tick = async () => { advance(61000); let pr; await worker.scheduled({}, env, { waitUntil(p){ pr = p; } }); await pr; };
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
  ok(s1 === 200 && a.created === 1 && a.request.step === 1 && a.request.pct === 0 && a.request.label === '已请求', '创建：STEP 1 / 0%', a);
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
  ok(r.step === 2 && r.pct === 28 && r.label === '待传输', '② 云下载 40% → STEP 2 / 28%', r);
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
  ok(r.step === 4 && r.pct === 69 && /50%/.test(r.note), '传输 50% → STEP 4 / 69%', r);
  W.job[88] = { finished: true, success: true, bytes: 1000, total: 1000 };
  await tick();
  ok((await one(movieId)).stage === 'verify', '传完 → 核对');
  await tick();
  ok((await one(movieId)).stage === 'purge', '核对一致 → 删 PikPak');
  await tick();
  r = (await mine()).find(x => x.id === movieId);
  ok(r.stage === 'release' && r.step === 5 && r.pct === 80 && r.label === '等待工作人员的最终发行', '⑤ 等待发行：STEP 5 / 80%', r);
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
  await tick(); await tick(); await tick();
  r = await one(tvId);
  ok(r.stage === 'copy' && /不一致/.test(r.note), '两端对不上：重新传，不删 PikPak', r);
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
  ok(r.state === 'failed' && /所有规格都试过了/.test(r.note), '所有规格都失败 → 失败', r);
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
