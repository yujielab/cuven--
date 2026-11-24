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
  lib: { mode: 404, seen: new Set() },   // 片库（Stream Worker）：404 = 老版本没有 /api/auto/sync；'on' / 'off' / 'down'
  sync: [],                  // 片库收到的 /api/auto/sync
  renames: [],               // PikPak 上的改名（加追踪码）
  /* 2.6 批量 */
  caps: null,                // 传输 Worker ping 回的 caps（null = 909，没有 caps）
  tvName: 'ram2',            // 传输 Worker 的 AUTO_TV_DIR
  nofilter: false,           // batch-copy 回 409 nofilter
  batchJobs: [],             // batch-copy 依次给的作业号
  batchCalls: [],            // 真开了的 batch-copy（不算 reused）
  batchRun: {},              // key → 作业号
  bverify: [], bpurge: [],   // batch-verify / batch-purge 收到的
  vbad: new Map(),           // 'sub/名字' → 还要对不上几次（batch-verify）
  copyWhileBatch: 0,         // 有批量作业在跑时开了单个 copy（不该有）
  existsTv: new Set(),       // dropbox:auto/ram2 下面有什么
  mkdirs: [],                // 影片库收到的 do=mkdir
  lbCalls: 0,
  fileGetDown: 0,            // PikPak 读单个文件（GET /drive/v1/files/<id>）接下来几次回 500
};
const pkFolderWith = (name, children, parent = 'AUTO') => {
  const id = 'F' + (W.seq++);
  W.files.set(id, { id, name, kind: 'drive#folder', parent_id: parent, size: '0', phase: 'PHASE_TYPE_RUNNING', trashed: false });
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
  30: () => ['Heat.1995.1080p.BluRay', [['Heat.1995.1080p.mkv', 9e9]]],
  31: () => ['Ronin.1998.1080p.BluRay', [['Ronin.1998.1080p.mkv', 8e9]]],
  32: () => ['Collateral.2004.1080p.BluRay', [['Collateral.2004.1080p.mkv', 8e9]]],
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
    W.lbCalls++;
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
      const fid = pkFolderWith(name, children, body.parent || 'AUTO');
      const task = 'T' + (W.seq++);
      W.tasks.set(task, { id: task, phase: 'PHASE_TYPE_RUNNING', progress: 0, file_id: fid, file_name: name });
      return J({ items: [{ tid: it.tid, ok: 1, task, name, file: fid, fileName: name }], ok: 1, stop: '' });
    }
    if (p === '/api/pikpak'){
      const act = u.searchParams.get('do');
      const parent = u.searchParams.get('parent') || '';
      if (act === 'ls' && !parent) return J({ parent: '', folders: [{ id: 'AUTO', name: 'auto' }, { id: 'X', name: 'other' }] });
      if (act === 'ls') return J({ parent, folders: [...W.files.values()].filter(f => f.parent_id === parent && f.kind === 'drive#folder' && !f.trashed).map(f => ({ id: f.id, name: f.name })) });
      if (act === 'mkdir'){
        W.mkdirs.push(body);
        const id = 'D' + (W.seq++);
        W.files.set(id, { id, name: body.name, kind: 'drive#folder', parent_id: body.parent, size: '0', phase: 'PHASE_TYPE_COMPLETE', trashed: false });
        return J({ id, name: body.name });
      }
      if (act === 'status') return J({ on: 1, ok: 1, user: 'pk***@x.com' });
    }
    if (p === '/api/catalog'){
      const src = u.searchParams.get('src');
      W.lastCatalogQ = u.searchParams;
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
    const keyOf = (x) => (x.sub ? x.sub + '/' : '') + x.item;
    const batchBusy = () => Object.values(W.batchRun).some(id => W.job[id] && W.job[id].finished === false);
    switch (op){
      case 'ping': return J({ ok: 1, version: 'v1.68', core: 'test', ...(W.caps ? { caps: W.caps, tv: W.tvName } : {}) });
      case 'organize': return J({ files: 3, deleted: ['ad.txt'], failed: [] });
      case 'check': return J(W.check.shift() || { k: 'ok', total: 4, vids: 4, have: [1, 2, 3, 4], miss: [], ongoing: false });
      case 'rename': {
        /* 910：sub = 现在在哪个区，to = 改完放哪个区（剧集区的文件夹在 /auto/ram2 下面） */
        const area = body.sub ? ([...W.files.values()].find(f => f.parent_id === 'AUTO' && f.name === body.sub && f.kind === 'drive#folder') || {}).id : 'AUTO';
        const name = /^Show\./.test(body.dir) ? body.dir.replace('.WEB-DL', '.[Full-4]-Cuven®') : 'Game.of.Thrones.S02.1080p.[Full-4]-Cuven®';
        const dir = [...W.files.values()].find(f => f.parent_id === area && f.name === body.dir && !f.trashed);
        if (dir) dir.name = name;            // rclone 在 PikPak 上把文件夹改了名
        return J({ name, jobid: 77, ...(body.sub ? { sub: body.to || '' } : {}) });
      }
      case 'copy':
        if (batchBusy()) W.copyWhileBatch++;
        return J({ jobid: (W.copyJobs || []).shift() || 88 });
      case 'batch-copy': {
        if (!(W.caps || []).includes('batch')) return J({ error: 'item 不对' }, 400);      // 909：不认识的接口落到单条校验
        if (W.nofilter) return J({ error: '试列时列出了不在这一批里的东西：rclone 不认筛选规则', nofilter: 1 }, 409);
        const items = body.items || [];
        if (!items.length || items.length > 16) return J({ error: '一批 1–16 个' }, 400);
        const run = W.batchRun[body.key];
        if (run && W.job[run] && W.job[run].finished === false) return J({ jobid: run, reused: true });
        const jobid = W.batchJobs.shift() || (4000 + W.batchCalls.length + 1);
        W.batchCalls.push(body); W.batchRun[body.key] = jobid;
        return J({ jobid, total: items.length * 1e9, files: items.reduce((s, x) => s + (x.kind === 'dir' ? 4 : 1), 0),
                   items: Object.fromEntries(items.map(x => [keyOf(x), { count: x.kind === 'dir' ? 4 : 1, bytes: 1e9 }])) });
      }
      case 'batch-verify': {
        W.bverify.push(body);
        const results = {};
        for (const x of body.items){
          const k = keyOf(x), bad = (W.vbad.get(k) || 0) > 0;
          if (bad) W.vbad.set(k, W.vbad.get(k) - 1);
          results[k] = bad ? { ok: 0, src: { count: 4, bytes: 9 }, dst: { count: 3, bytes: 7 }, missing: ['E04.mkv'], missingCount: 1, differ: [], differCount: 0, extra: 0 }
                           : { ok: 1, src: { count: 4, bytes: 9 }, dst: { count: 4, bytes: 9 }, missing: [], missingCount: 0, differ: [], differCount: 0, extra: 0 };
        }
        return J({ results });
      }
      case 'batch-purge': {
        if (body.items.length > 8) return J({ error: '一次最多 8 个' }, 400);
        W.bpurge.push(body);
        for (const x of body.items) (x.sub ? W.existsTv : W.exists).add(x.item);
        return J({ results: Object.fromEntries(body.items.map(x => [keyOf(x), { ok: 1 }])) });
      }
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
      case 'purge': (body.sub ? W.existsTv : W.exists).add(body.item); return J({ ok: 1 });
      case 'exists': return Array.isArray(body.items)
        ? J({ exists: Object.fromEntries(body.items.map(n => [n, W.exists.has(n) ? 1 : 0])),
              ...(Array.isArray(body.tv) && body.tv.length ? { tv: Object.fromEntries(body.tv.map(n => [n, W.existsTv.has(n) ? 1 : 0])) } : {}) })
        : J({ exists: (body.sub ? W.existsTv : W.exists).has(body.item) ? 1 : 0 });
    }
    return J({ error: 'tf 404' }, 404);
  }
  /* 片库：重看一眼 /auto，回这几个名字收录了没有 */
  if (u.host === 'stream.cuven.online' && p === '/api/auto/sync'){
    const items = u.searchParams.getAll('item');
    W.sync.push({ items, codes: u.searchParams.getAll('code'), tmdbs: u.searchParams.getAll('tmdb'), tv: u.searchParams.get('tv') === '1', key: H['x-sync-key'] || '' });
    if (W.lib.mode === 404) return J({ error: 'Not found', path: p }, 404);
    if (W.lib.mode === 'down') return J({ error: 'Internal error' }, 500);
    if (W.lib.mode === 'off') return J({ ok: false, off: 1 });
    const codes = u.searchParams.getAll('code'), tmdbs = u.searchParams.getAll('tmdb');
    const where = Object.fromEntries(codes.filter(k => W.lib.where && W.lib.where[k]).map(k => [k, W.lib.where[k]]));
    const found = Object.fromEntries(tmdbs.filter(k => W.lib.found && W.lib.found[k]).map(k => [k, W.lib.found[k]]));
    return J({ ok: true, root: '/auto', movies: W.lib.seen.size, has: Object.fromEntries(items.map(n => [n, W.lib.seen.has(n)])), where, found });
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
      if (m === 'GET' && W.fileGetDown > 0){ W.fileGetDown--; return J({ error: 'internal_error', error_code: 500 }, 500); }
      if (f && m === 'PATCH'){ W.renames.push([f.name, body.name]); if (W.renameDeny) return J({ error: 'permission_denied', error_code: 7 }, 403); f.name = body.name; }
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
/* OVERS：每一轮 tick:last 的 over（2.6：这一轮有几个子请求被预算挡回去），给「从开批到就绪没有一轮被掐」那样的检查用 */
const OVERS = [];
const tick = async () => {
  advance(3 * 60000 + 6000); let pr; await worker.scheduled({}, env, { waitUntil(p){ pr = p; } }); await pr;
  const v = env.DB.db.prepare("SELECT v FROM tj_kv WHERE k = 'tick:last'").get();
  OVERS.push(v ? JSON.parse(v.v).over || 0 : 0);
};
const mine = async (user = 'alice') => (await call('GET', '/app/requests', { user }))[1].items;
const one = async (id) => (await call('GET', '/admin/api/state', { admin: true }))[1].reqs.find(r => r.id === id);

/* ── 面板口令、设置、PikPak 密码加密 ── */
{
  const [s1] = await call('GET', '/admin/api/state', { admin: 'wrong' });
  ok(s1 === 401, '面板：错口令 401');
  // 前面几段测的是「等工作人员发行」那条老路：先关掉「抵达 /auto 自动通过」，到 v2.2 那一段再打开。
  // 2.6 以前的几段测的都是一部一部传的那条路：关掉批量传输（batch:false），限额用 2.5 的默认值（5 / 30），到 2.6 那几段再打开
  const [s2, st] = await call('POST', '/admin/api/cfg', { admin: true, body: { pkUser: 'pk@x.com', pkPass: 'pkpass', grp: 'Cuven®', autoReady: false,
    batch: false, userCap: 5, globalCap: 30 } });
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
  const tagged = 'Fight.Club.1999.1080p.[auto-m550-r' + movieId + '].mkv';
  ok(big.name === tagged && (await one(movieId)).item === tagged && (await one(movieId)).tag === '[auto-m550-r' + movieId + ']',
     '传之前在 PikPak 上改名：文件名带上追踪码 auto-m550-r<请求编号>（扩展名前面）', { name: big.name, r: await one(movieId) });
  ok(W.tf.some(([op, b]) => op === 'copy' && b.item === tagged && b.kind === 'file'), '④ 触发 webdav → dropbox 复制（文件，用带追踪码的名字）');
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
  W.exists.delete(tagged);
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
  ok(r.item === 'Game.of.Thrones.S02.1080p.[Full-4]-Cuven®.[auto-tv1399s2-r' + tvId + ']' && W.tf.some(([op, b]) => op === 'copy' && b.item === r.item),
     '剧集文件夹名带上追踪码 auto-tv1399s2-r<请求编号>（剧集带季）', r.item);
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
  await call('GET', '/app/catalog?src=movie&year=2024&own=hide');
  ok(W.lastCatalogQ && W.lastCatalogQ.get('year') === '2024', '目录：年份转给影片库（全部影片按年份分节）', W.lastCatalogQ && String(W.lastCatalogQ));
  await call('GET', '/app/catalog?src=movie&year=abc');
  ok(W.lastCatalogQ && !W.lastCatalogQ.has('year'), '目录：不像年份的不转', W.lastCatalogQ && String(W.lastCatalogQ));
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

/* ══ v2.4：文件抵达 /auto 自动通过最终审核（用户：「当文件抵达 auto 自动通过最终审核，使影片可以播放」）══ */
{
  env.DB.db.exec('DELETE FROM tj_req');
  env.DB.db.exec("DELETE FROM tj_kv WHERE k IN ('health', 'tick:last', 'track')");
  await call('POST', '/admin/api/cfg', { admin: true, body: { autoReady: true } });
  W.verifyOK = true; W.verifySeq = []; W.copyJobs = [];
  W.job[88] = { finished: true, success: true, bytes: 1, total: 1 };
  W.versions['movie:960'] = [{ tid: 30, title: 'Heat 1995 1080p', mb: 1, labels: [], res: '1080p' }];
  W.versions['movie:961'] = [{ tid: 31, title: 'Ronin 1998 1080p', mb: 1, labels: [], res: '1080p' }];
  W.versions['movie:962'] = [{ tid: 32, title: 'Collateral 2004 1080p', mb: 1, labels: [], res: '1080p' }];
  const req = async (id, user = 'alice') => (await call('POST', '/app/requests', { user, body: { src: 'movie', id } }))[1].request.id;
  /** 一路推到删完 PikPak（purge 那一轮之后） */
  const toPurged = async (id) => {
    await tick();
    for (const t of [...W.tasks.keys()]) finishTask(t);
    for (let i = 0; i < 10; i++){ await tick(); const r = await one(id); if (r.stage !== 'purge' ? ['release', 'done'].includes(r.stage) : W.tf.some(([op, b]) => op === 'purge' && b.item === r.item)) break; }
    return one(id);
  };
  const logOf = async (id) => (await call('GET', '/admin/api/log?id=' + id, { admin: true }))[1].items.map(l => l.msg);

  /* 抵达 /auto、片库当场就收录了：自动通过最终审核，可以播放 */
  W.lib = { mode: 'on', seen: new Set(), where: {} };
  W.sync = [];
  const a = await req(960);
  const heat = 'Heat.1995.1080p.[auto-m960-r' + a + '].mkv';
  W.lib.seen.add(heat);
  let r = await toPurged(a);
  let app = (await mine()).find(x => x.id === a);
  ok(r.state === 'done' && r.next === 0 && /可以播放（自动通过最终审核）/.test(r.note) && app.state === 'done' && app.pct === 100,
     '文件抵达 /auto：自动通过最终审核，片库当场收录 → 可以播放（App 100%、「立即播放」）', { r, app });
  ok(!W.tf.some(([op, x]) => op === 'exists' && (x.item === heat || (x.items || []).includes(heat))), '不进「最终发行审批」、不等工作人员挪');
  ok(W.sync.some(s => s.items.includes(heat) && s.codes.includes(String(a))), '通过的同时请片库马上收录（带名字和追踪码）', W.sync);
  ok((await logOf(a)).some(m => /文件已抵达 \/auto，自动通过最终审核；片库已收录 → 可以播放了/.test(m)), '日志：抵达 /auto 自动通过最终审核');

  /* 片库还没收录（列表慢几秒）：照样当场通过；之后每分钟催片库，收录了就停 */
  const b = await req(961);
  const ronin = 'Ronin.1998.1080p.[auto-m961-r' + b + '].mkv';
  r = await toPurged(b);
  app = (await mine()).find(x => x.id === b);
  ok(r.state === 'done' && app.pct === 100 && r.next > 0, '片库还没收录：照样当场自动通过（App 100%），留着接着催片库', r);
  ok((await logOf(b)).some(m => /自动通过最终审核；片库还没收录.*每分钟催一次/.test(m)), '日志：片库还没收录，每分钟催一次');
  W.sync = [];
  await tick();
  ok(W.sync.some(s => s.items.includes(ronin)) && (await one(b)).next > 0, '下一轮接着催片库', W.sync);
  W.lib.seen.add(ronin);
  const updated0 = (await mine()).find(x => x.id === b).updated;
  await tick();
  r = await one(b);
  ok(r.next === 0 && (await logOf(b)).some(m => /片库已收录 → 可以播放了/.test(m)), '片库收录了：不再催', r);
  ok((await mine()).find(x => x.id === b).updated === updated0, '催片库只改记录：App 上的时间不跳');

  /* 片库连不上：照样通过、不出错；连上了收录了就停 */
  W.lib.mode = 'down';
  const c3 = await req(962);
  r = await toPurged(c3);
  ok(r.state === 'done' && !r.errs && r.next > 0, '片库连不上：照样自动通过，不算出错，接着催', r);
  W.lib.mode = 'on'; W.lib.seen.add('Collateral.2004.1080p.[auto-m962-r' + c3 + '].mkv');
  advance(2 * 60000); await tick();
  ok((await one(c3)).next === 0, '片库连上、收录了：不再催');

  /* 老版本片库（没有 /api/auto/sync）：照样通过，日志写清楚要等工作人员挪进片库才能播放，不再催 */
  env.DB.db.exec('DELETE FROM tj_req');
  W.lib = { mode: 404, seen: new Set(), where: {} };
  const d = await req(960);
  r = await toPurged(d);
  ok(r.state === 'done' && r.next === 0, '老版本片库：照样自动通过最终审核', r);
  ok((await logOf(d)).some(m => /片库不收录 \/auto.*要等工作人员挪进片库才能播放/.test(m)), '日志写清楚：老版本片库要等工作人员挪进片库才能播放');
  W.sync = [];
  advance(5 * 60000); await tick();
  ok(W.sync.length === 0, '老版本片库：不再催');

  /* 以前停在「最终发行审批」的（升级之前进来的）：下一轮直接通过；好几条一次问完 */
  env.DB.db.exec('DELETE FROM tj_req');
  W.lib = { mode: 'on', seen: new Set(['Heat.1995.1080p.mkv', 'Ronin.1998.1080p.mkv']), where: {} };
  const e1 = await req(960), e2 = await req(961);
  for (const [id, item] of [[e1, 'Heat.1995.1080p.mkv'], [e2, 'Ronin.1998.1080p.mkv']]){
    env.DB.db.prepare("UPDATE tj_req SET stage = 'release', next = 0, data = json_set(data, '$.item', ?, '$.kind', 'file', '$.autoOff', 1) WHERE id = ?").run(item, id);
    W.exists.add(item);
  }
  W.sync = [];
  await tick();
  ok((await one(e1)).state === 'done' && (await one(e2)).state === 'done', '停在最终发行审批的（以前片库不收录时留下的）：下一轮直接通过');
  ok(W.sync.length === 1 && W.sync[0].items.length === 2, '好几条一次问完片库', W.sync);

  /* 面板关掉「自动通过」：照旧等工作人员发行 */
  env.DB.db.exec('DELETE FROM tj_req');
  const [, st] = await call('POST', '/admin/api/cfg', { admin: true, body: { autoReady: false } });
  ok(st.cfg.autoReady === false, '面板：可以关掉「文件抵达 /auto 自动通过最终审核」', st.cfg);
  const f1 = await req(960);
  env.DB.db.prepare("UPDATE tj_req SET stage = 'release', next = 0, data = json_set(data, '$.item', 'Heat.1995.1080p.mkv', '$.kind', 'file') WHERE id = ?").run(f1);
  W.sync = [];
  await tick();
  ok(W.sync.length === 0 && (await one(f1)).stage === 'release', '关掉以后：照旧等工作人员发行，不问片库', W.sync);
  await call('POST', '/admin/api/cfg', { admin: true, body: { autoReady: true } });
  W.lib.mode = 'on';
  const [, links] = await call('POST', '/admin/api/links', { admin: true, body: {} });
  ok(links.stream && links.stream.ok && links.stream.root === '/auto', '面板「测试连接」：片库收录 /auto', links.stream);
  W.lib.mode = 404;
  const [, links2] = await call('POST', '/admin/api/links', { admin: true, body: {} });
  ok(links2.stream.ok && links2.stream.off, '面板「测试连接」：老版本片库写清楚「不收录 /auto」', links2.stream);
}

/* ══ v2.3：名字里带追踪码，传完以后也能一直追踪（用户：「在文件和文件夹名中带上 auto-tmdb唯一码-内部代码」）══ */
{
  env.DB.db.exec('DELETE FROM tj_req');
  env.DB.db.exec("DELETE FROM tj_kv WHERE k IN ('health', 'tick:last', 'track')");
  W.lib = { mode: 'on', seen: new Set(), where: {} };
  W.renames = []; W.sync = [];
  const req = async (id) => (await call('POST', '/app/requests', { user: 'alice', body: { src: 'movie', id } }))[1].request.id;
  const toPurged = async (id) => {
    await tick();
    for (const t of [...W.tasks.keys()]) finishTask(t);
    for (let i = 0; i < 10; i++){ await tick(); const r = await one(id); if (r.stage !== 'purge' ? ['release', 'done'].includes(r.stage) : W.tf.some(([op, b]) => op === 'purge' && b.item === r.item)) break; }
    return one(id);
  };

  /* 片库按追踪码认出来（名字写法对不上也行）；问的时候带着追踪码 */
  const a = await req(960);
  let r = await toPurged(a);
  ok(W.renames.some(([from, to]) => from === 'Heat.1995.1080p.mkv' && to === 'Heat.1995.1080p.[auto-m960-r' + a + '].mkv'), 'PikPak 上改名：扩展名前面加 [auto-m<TMDB>-r<请求编号>]', W.renames);
  ok(W.sync.some(s => s.codes.includes(String(a))), '问片库时带着追踪码（请求编号）', W.sync.slice(-1));
  ok(r.state === 'done' && r.next > 0, '抵达 /auto 自动通过，片库还没收录：接着催', r);
  W.lib.where[String(a)] = { path: '/auto/heat.1995.1080p.[auto-m960-r' + a + '].mkv', auto: true, kind: 'movie' };
  await tick();
  r = await one(a);
  ok(r.state === 'done' && r.next === 0 && !r.home, '片库按追踪码认出来了（名字大小写对不上也行）→ 不再催；还在 /auto 不算归档', r);

  /* 就绪以后接着追踪：工作人员挪进 ram 了 → 面板写去了哪儿；App 上的时间不跳 */
  const updated0 = (await mine()).find(x => x.id === a).updated;
  W.lib.where[String(a)] = { path: '/ram/Heat.1995.1080p.[auto-m960-r' + a + '].mkv', auto: false, kind: 'movie' };
  await tick();
  ok(!(await one(a)).home, '还没到 30 分钟：不去追');
  advance(31 * 60000); await tick();
  r = await one(a);
  ok(r.home === '/ram/Heat.1995.1080p.[auto-m960-r' + a + '].mkv' && (await mine()).find(x => x.id === a).updated === updated0,
     '30 分钟一轮：按追踪码找到它被挪到了 /ram（只改记录，App 上「最近」的时间不跳）', r);
  const log = (await call('GET', '/admin/api/log?id=' + a, { admin: true }))[1].items.map(l => l.msg);
  ok(log.some(m => /工作人员已归档：\/ram\/Heat/.test(m)), '日志：工作人员已归档到哪儿', log.slice(0, 2));
  const nSync = W.sync.length;
  advance(31 * 60000); await tick();
  ok(!W.sync.slice(nSync).some(s => s.codes.includes(String(a))), '找到归宿以后不再追这一条');

  /* 已经被挪走了才第一次问到：一样算就绪，直接记下归宿 */
  const b = await req(961);
  W.lib.where = {};
  r = await toPurged(b);
  W.lib.where[String(b)] = { path: '/ram/Ronin.1998.1080p.[auto-m961-r' + b + '].mkv', auto: false, kind: 'movie' };
  await tick();
  r = await one(b);
  ok(r.state === 'done' && r.next === 0 && /^\/ram\/Ronin/.test(r.home), '催片库时已经被挪进 /ram：按追踪码找到，归宿直接记下', r);

  /* 哪儿都找不到（改了名 / 删了）：连着 6 次才放弃 */
  const c3 = await req(962);
  W.lib.where = {};
  r = await toPurged(c3);
  W.lib.where[String(c3)] = { path: '/auto/x', auto: true, kind: 'movie' };
  await tick();
  ok((await one(c3)).state === 'done', '就绪');
  W.lib.where = {};
  for (let i = 0; i < 5; i++){ advance(31 * 60000); await tick(); }
  ok(!(await one(c3)).home, '找不到 5 次：还在追（片库的列表可能慢）');
  advance(31 * 60000); await tick();
  ok(/找不到了/.test((await one(c3)).home), '连着 6 次哪儿都找不到：不再追踪，面板写清楚', await one(c3));

  /* PikPak 不让改名：照原名传，不耽误 */
  env.DB.db.exec('DELETE FROM tj_req');
  W.renameDeny = true;
  const d = await req(960);
  r = await toPurged(d);
  ok(r.item === 'Heat.1995.1080p.mkv' && r.tag === '' && W.tf.some(([op, x]) => op === 'copy' && x.item === 'Heat.1995.1080p.mkv'), 'PikPak 不让改名：照原名传', r);
  W.renameDeny = false;

  /* 面板关掉追踪码：不改名 */
  env.DB.db.exec('DELETE FROM tj_req');
  const [, st] = await call('POST', '/admin/api/cfg', { admin: true, body: { tagNames: false } });
  ok(st.cfg.tagNames === false, '面板：可以关掉追踪码', st.cfg);
  W.renames = [];
  const e = await req(961);
  r = await toPurged(e);
  ok(W.renames.length === 0 && r.item === 'Ronin.1998.1080p.mkv', '关掉以后不改名', { renames: W.renames, item: r.item });
  await call('POST', '/admin/api/cfg', { admin: true, body: { tagNames: true } });
}

/* ══ v2.5：追踪码优先 —— 新请求先核对片库，片库里已有带这个 TMDB 编号的追踪码就不再下载 ══ */
{
  env.DB.db.exec('DELETE FROM tj_req');
  env.DB.db.exec("DELETE FROM tj_kv WHERE k IN ('health', 'tick:last', 'track')");
  W.versions['movie:970'] = [{ tid: 30, title: 'Heat 1995 1080p', mb: 1, labels: [], res: '1080p' }];
  W.versions['movie:971'] = [{ tid: 31, title: 'Ronin 1998 1080p', mb: 1, labels: [], res: '1080p' }];
  W.lib = { mode: 'on', seen: new Set(), where: {}, found: { m970: { path: '/ram/Heat.1995.1080p.[auto-m970-r3].mkv', auto: false, kind: 'movie', ready: true, code: '3' } } };
  W.sync = [];
  const push0 = W.push.length;
  const a = (await call('POST', '/app/requests', { user: 'alice', body: { src: 'movie', id: 970 } }))[1].request.id;
  await tick();
  let r = await one(a);
  const app = (await mine()).find(x => x.id === a);
  ok(r.state === 'done' && /片库里已有/.test(r.note) && app.pct === 100 && W.push.length === push0,
     '片库里已有带这个 TMDB 编号追踪码的那一部：不再推送下载，直接就绪（App 100%、「立即播放」）', { r, push: W.push.length - push0 });
  ok(W.sync.some(s => s.tmdbs.includes('m970')), '核对时问的是追踪码里的 TMDB 那一截（m970）', W.sync);
  ok(r.home === '/ram/Heat.1995.1080p.[auto-m970-r3].mkv', '记下片库里那一部在哪儿', r);
  const log = (await call('GET', '/admin/api/log?id=' + a, { admin: true }))[1].items.map(l => l.msg);
  ok(log.some(m => /片库里已经有了（追踪码 r3，在 \/ram\/Heat/.test(m)), '日志写清楚是哪一条请求加的、在哪儿');

  /* 片库里没有：照常下载；片库连不上：照常下载，不耽误 */
  const b = (await call('POST', '/app/requests', { user: 'alice', body: { src: 'movie', id: 971 } }))[1].request.id;
  W.lib.mode = 'down';
  await tick();
  r = await one(b);
  ok(r.stage === 'download' && W.push.length === push0 + 1, '片库连不上：照常推送下载，不耽误', r);
  W.lib.mode = 404;
}

/* ══════════════════════════════════════════════════════════════════
   2.6：请求中心批量提交、凑满 16 部一起传（16 路并行传输 / 16 路并发核对）、剧集放进 /auto/ram2
   ══════════════════════════════════════════════════════════════════ */
const lastTick = () => JSON.parse(env.DB.db.prepare("SELECT v FROM tj_kv WHERE k = 'tick:last'").get().v);
const reset26 = () => {
  env.DB.db.exec('DELETE FROM tj_req'); env.DB.db.exec('DELETE FROM tj_batch');
  env.DB.db.exec("DELETE FROM tj_kv WHERE k IN ('health', 'tick:last', 'track', 'tf:caps', 'tv:id', 'flow:live')");
  W.batchCalls = []; W.batchRun = {}; W.batchJobs = []; W.bverify = []; W.bpurge = []; W.vbad = new Map(); W.copyWhileBatch = 0; W.nofilter = false;
};
const batchPost = (user, items) => call('POST', '/app/requests/batch', { user, body: { items } });
const flowGet = async (user, tag) => {
  const r = await worker.fetch(new Request('https://tj.cuven.us/app/flow', { headers: { 'x-cuven-user': encodeURIComponent(user), ...(tag ? { 'if-none-match': tag } : {}) } }), env, {});
  return [r.status, r.headers.get('etag'), r.status === 200 ? await r.json() : null];
};

/* ── /app/requests/batch：created / joined / failedRecently / limit / invalid，一组 SQL，不问影片库 ── */
{
  reset26();
  W.caps = ['sub', 'batch']; W.tvName = 'ram2';
  await call('POST', '/admin/api/cfg', { admin: true, body: { batch: true, userCap: 50, globalCap: 200, autoReady: true, tagNames: true } });
  const [, st0] = await call('GET', '/admin/api/state', { admin: true });
  ok(st0.cfg.batch === true && st0.cfg.batchMin === 16 && st0.cfg.batchMax === 16 && st0.cfg.xfers === 16 && st0.cfg.checkers === 16 &&
     st0.cfg.basketMax === 50 && st0.cfg.tvSub === 'ram2' && st0.cfg.batchWait === 30, '2.6 默认：批量开、凑 16 部、16 路传输 / 核对、请求中心最多 50、剧集在 ram2', st0.cfg);
  const lb0 = W.lbCalls;
  const [s, j] = await batchPost('alice', [
    { src: 'movie', id: 1100, title: '甲<b>', year: 2001, poster: '/a.jpg' },
    { src: 'movie', id: 1101, poster: 'javascript:alert(1)' },
    { src: 'tv', id: 1399, season: 3 },
    { src: 'tv', id: 1399 },                 // 剧集没说第几季
    { src: 'music', id: 5 },                 // 不认得
    { src: 'movie', id: 1100 },              // 篮子里重复的
  ]);
  const res = j.items.map(x => x.result);
  ok(s === 200 && j.bid > 0 && res.join() === 'created,created,created,invalid,invalid,created', '一次提交：每条回结果（认不得的 invalid）', j);
  ok(W.lbCalls === lb0, '一次提交不问影片库（版本留给 ① 去问）', W.lbCalls - lb0);
  const a = j.items[0].request;
  ok(a.stage === 'queued' && a.bid === j.bid && a.title === '甲<b>' && a.year === '2001' && j.items[5].request.id === a.id, '新建的记上 bid、片名年份先用 App 给的占位', a);
  ok(j.items[1].request.poster === '' && j.items[2].request.season === 3, '海报只收路径 / https，剧集带季', j.items[1].request);
  ok(env.DB.db.prepare('SELECT COUNT(*) AS n FROM tj_req WHERE bid = ?').get(j.bid).n === 3, 'D1 里三条，同一个 bid');
  const logs = (await call('GET', '/admin/api/log?id=' + a.id, { admin: true }))[1].items.map(l => l.msg);
  ok(logs.some(m => /alice 请求添加（请求中心一次提交 3 部）：甲/.test(m)), '日志一条 SQL 写完：谁、一次提交几部', logs);

  /* 同一部别人已经在请求：跟上（users 里加上这个人），bid 是新的一次 */
  const [, k] = await batchPost('bob', [{ src: 'movie', id: 1100 }, { src: 'movie', id: 1102 }]);
  ok(k.bid > j.bid && k.items[0].result === 'joined' && k.items[0].request.id === a.id && k.items[1].result === 'created', '已经在进行中的：跟上，不重复下', k);
  const users = JSON.parse(env.DB.db.prepare('SELECT users FROM tj_req WHERE id = ?').get(a.id).users);
  ok(users.join() === 'alice,bob' && (await mine('bob')).some(r => r.id === a.id), '跟上的人加进 users，「我的请求」里看得到', users);
  const [, k2] = await batchPost('bob', [{ src: 'movie', id: 1100 }]);
  ok(k2.items[0].result === 'joined' && JSON.parse(env.DB.db.prepare('SELECT users FROM tj_req WHERE id = ?').get(a.id).users).length === 2, '再提交一次：不重复加人');

  /* 一天之内失败过的：拿回那条 */
  env.DB.db.prepare("UPDATE tj_req SET stage = 'failed', updated = ? WHERE tmdb = 1101").run(Date.now());
  const [, f] = await batchPost('bob', [{ src: 'movie', id: 1101 }]);
  ok(f.items[0].result === 'failedRecently' && f.items[0].request.state === 'failed' &&
     JSON.parse(env.DB.db.prepare('SELECT users FROM tj_req WHERE tmdb = 1101').get().users).includes('bob'), '刚失败过：拿回那条失败的（也加上这个人）', f);

  /* 限额：这个人的、全部的 */
  await call('POST', '/admin/api/cfg', { admin: true, body: { userCap: 2 } });
  const [, l] = await batchPost('小明', [{ src: 'movie', id: 1103 }, { src: 'movie', id: 1104 }, { src: 'movie', id: 1105 }]);
  ok(l.items.map(x => x.result).join() === 'created,created,limit' && l.items[2].cap === 'user' && !l.items[2].request, '超了每个人的限额：limit（cap: user）', l);
  const active = env.DB.db.prepare("SELECT COUNT(*) AS n FROM tj_req WHERE stage NOT IN ('done','failed','cancelled','release')").get().n;
  await call('POST', '/admin/api/cfg', { admin: true, body: { userCap: 50, globalCap: active } });
  const [, g] = await batchPost('alice', [{ src: 'movie', id: 1106 }]);
  ok(g.items[0].result === 'limit' && g.items[0].cap === 'global', '超了全部的限额：limit（cap: global）', g);
  await call('POST', '/admin/api/cfg', { admin: true, body: { globalCap: 200 } });

  /* 请求篮最多 50 条；空的、没登录、用户名不存在都不收 */
  const many = Array.from({ length: 51 }, (_, i) => ({ src: 'movie', id: 1200 + i }));
  ok((await batchPost('alice', many))[0] === 400, '一次超过 50 条：400');
  ok((await batchPost('alice', []))[0] === 400, '空的请求篮：400');
  ok((await call('POST', '/app/requests/batch', { body: { items: [{ src: 'movie', id: 1 }] } }))[0] === 401, '没登录：401');
  ok((await batchPost('mallory', [{ src: 'movie', id: 1 }]))[0] === 401, '用户名不存在：401');
  const [, mx] = await call('POST', '/admin/api/cfg', { admin: true, body: { basketMax: 99, batchMin: 20, batchMax: 99, xfers: 64, tvSub: '../x' } });
  ok(mx.cfg.basketMax === 50 && mx.cfg.batchMax === 16 && mx.cfg.batchMin === 16 && mx.cfg.xfers === 16 && mx.cfg.tvSub === 'ram2', '面板的设置有上限（剧集区名字不对的不收）', mx.cfg);
}

/* ── 端到端：14 部电影 + 4 季剧集一次提交 → 下载 / 清洗（剧集在 /auto/ram2）→ 凑满 16 部一起传 → 一次核对 → 8 个一次删 → 就绪 ── */
{
  reset26();
  W.caps = ['sub', 'batch']; W.tvName = 'ram2';
  await call('POST', '/admin/api/cfg', { admin: true, body: { batch: true, batchMin: 16, batchMax: 16, batchWait: 600, pkSlots: 20, vpsSlots: 2,
    xfers: 16, checkers: 16, tvSub: 'ram2', autoReady: true, tagNames: true, userCap: 50, globalCap: 200 } });
  W.lib = { mode: 'on', seen: new Set(), where: {}, found: {} };
  W.sync = []; W.renames = []; W.mkdirs = [];
  W.copyJobs = [];
  W.job[88] = { finished: true, success: true, bytes: 1, total: 1 };
  W.job[77] = { finished: true, success: true, bytes: 2, total: 2 };
  const items = [];
  for (let i = 0; i < 14; i++){
    const tid = 100 + i;
    LAYOUT[tid] = () => ['Movie' + i + '.2020.1080p.BluRay', [['Movie' + i + '.2020.1080p.mkv', 4e9 + i], ['sample.mkv', 1e8]]];
    W.versions['movie:' + (2000 + i)] = [{ tid, title: 'Movie ' + i, mb: 1, labels: [], res: '1080p' }];
    items.push({ src: 'movie', id: 2000 + i, title: 'Movie ' + i });
  }
  [[3001, 1], [3001, 2], [3002, 1], [3003, 1]].forEach(([id, sn], i) => {
    const tid = 200 + i;
    LAYOUT[tid] = () => ['Show.' + id + '.S0' + sn + '.1080p.WEB-DL', [['E01.mkv', 1e9], ['E02.mkv', 1e9], ['E03.mkv', 1e9], ['E04.mkv', 1e9]]];
    W.versions['tv:' + id + ':' + sn] = [{ tid, title: 'Show ' + id + ' S' + sn, mb: 1, labels: [], res: '1080p', total: 4 }];
    items.push({ src: 'tv', id, season: sn });
  });
  const [, sub] = await batchPost('alice', items);
  ok(sub.items.length === 18 && sub.items.every(x => x.result === 'created'), '请求中心一次提交 18 部（14 部电影 + 4 季剧集）', sub.items.map(x => x.result));
  const ids = sub.items.map(x => x.request.id);
  W.batchJobs = [4101, 4102];
  W.job[4101] = { finished: false, success: false, bytes: 0, total: 16e9 };
  W.job[4102] = { finished: false, success: false, bytes: 0, total: 2e9 };
  let maxF = 0, ticks = 0, sawParked = false, sawReady = false;
  /* over = 这一轮有几个子请求被预算挡回去（c.n 到不了 42 以上，光看 fetches ≤ 42 永远成立）；tfL = 开批那一轮之前传输收到的调用数。
     凑批之前 18 部一起清洗，一轮用满 42 个、最后一步被挡回去下一轮再做是正常的（看调度的先后），这里不查 */
  let tfL = 0;
  const tf0 = W.tf.length, push0 = W.push.length;
  for (; ticks < 40 && !W.batchCalls.length; ticks++){
    for (const t of [...W.tasks.keys()]) finishTask(t);
    tfL = W.tf.length;
    await tick();
    maxF = Math.max(maxF, lastTick().fetches);
    const rd = env.DB.db.prepare("SELECT next, data FROM tj_req WHERE stage = 'ready'").all().filter(x => JSON.parse(x.data).tag !== undefined);
    if (rd.length){ sawReady = true; if (rd.every(x => x.next > Date.now() + 5 * 60000)) sawParked = true; }
  }
  ok(W.batchCalls.length === 1, '清洗好的凑够 16 部：开一批（' + ticks + ' 轮）', { ticks, stages: env.DB.db.prepare('SELECT stage, COUNT(*) n FROM tj_req GROUP BY stage').all() });
  ok(sawReady && sawParked, '等待凑批的加好追踪码以后停着（不用每轮都排上）');
  ok(W.sync.some(x => x.tmdbs.length >= 16), '新请求核对片库：一次问完（不是 18 次）', W.sync.map(x => x.tmdbs.length));
  const bc = W.batchCalls[0];
  ok(bc.items.length === 16 && bc.transfers === 16 && bc.checkers === 16 && /^\d+$/.test(bc.key), 'batch-copy：16 部、Transfers 16、Checkers 16、key = 批次编号', { n: bc.items.length, t: bc.transfers, c: bc.checkers, key: bc.key });
  ok(bc.items.every(x => x.kind === 'dir' ? x.sub === 'ram2' && /^Show\./.test(x.item) : x.sub === '' && /\.mkv$/.test(x.item)) && bc.items.some(x => x.kind === 'dir'),
     '电影在 /auto（sub 空），剧集在 /auto/ram2（sub: ram2）', bc.items);
  ok(bc.items.every(x => /\[auto-(m|tv)\d+(s\d+)?-r\d+\]/.test(x.item)), '一批里的名字都带上了追踪码（在 ready 那一步加的）', bc.items.map(x => x.item));
  const tvId = JSON.parse(env.DB.db.prepare("SELECT v FROM tj_kv WHERE k = 'tv:id'").get().v);
  const tvPush = W.push.slice(push0).filter(p => p.src === 'tv'), mvPush = W.push.slice(push0).filter(p => p.src === 'movie');
  ok(tvId.name === 'ram2' && tvId.parent === 'AUTO' && W.mkdirs.length === 1 && W.mkdirs[0].parent === 'AUTO' && W.mkdirs[0].name === 'ram2',
     'PikPak 上的 /auto/ram2：问影片库没有就建一个（只建一次，存 tj_kv）', { tvId, mk: W.mkdirs });
  ok(tvPush.length === 4 && tvPush.every(p => p.parent === tvId.id) && mvPush.every(p => p.parent === 'AUTO'), '剧集推进 /auto/ram2，电影照旧推进 /auto', W.push.slice(push0));
  ok(W.renames.some(([from, to]) => /^Show\.3001\.S01/.test(from) && /\[auto-tv3001s1-r\d+\]$/.test(to)), '剧集的追踪码在 /auto/ram2 里加', W.renames.filter(([f]) => /^Show/.test(f)));
  ok(maxF <= 42, '凑批之前每一轮的子请求都没超 42', maxF);
  const lt = lastTick(), opsL = W.tf.slice(tfL).map(x => x[0]), o0 = OVERS.length;
  ok(lt.over === 0 && opsL.filter(o => o === 'batch-copy').length === 1 && lt.batch && lt.batch.items === 16,
     '开批那一轮：一个 batch-copy 开 16 部，没有子请求被预算挡回去', { fetches: lt.fetches, over: lt.over, ops: opsL });

  /* 成员停在 copy、不用每轮排上；多的两部等下一批 */
  const members = env.DB.db.prepare('SELECT id, stage, next, bat FROM tj_req WHERE bat > 0').all();
  const bid1 = members[0].bat;
  ok(members.length === 16 && members.every(x => x.stage === 'copy' && x.bat === bid1 && x.next > Date.now() + 10 * 60000) && String(bid1) === bc.key,
     '16 个成员停在 copy（进度由批次一起改）', members);
  await tick();                                                   // 多的那两部也加好追踪码、停下
  W.job[4101] = { finished: false, success: false, bytes: 8e9, total: 16e9, speed: 50 * 1048576, eta: 160, transfers: 5, totalTransfers: 26 };
  const tfA = W.tf.length;
  await tick();
  const opsA = W.tf.slice(tfA).map(x => x[0]);
  ok(lastTick().due === 0 && opsA.filter(o => o === 'job').length === 1 && opsA.length === 1, '批量传输中：一轮只问一次作业进度，没有别的条目到期', { due: lastTick().due, ops: opsA });
  let app = (await mine()).filter(r => r.batch === bid1);
  ok(app.length === 16 && app.every(r => r.step === 4 && r.pct === 69 && r.label === '等待传输'), '成员的进度一起改：一半 → STEP 4 / 69%（带 batch）', app.map(r => r.pct));
  const waiting = (await mine()).filter(r => r.stage === 'ready');
  ok(waiting.length === 2 && waiting.every(r => r.step === 4 && r.pct === 60 && r.wait && r.wait.ready === 2 && r.wait.need === 16), '多的两部等下一批：STEP 4「等待传输」，带 wait', waiting);
  ok(W.copyWhileBatch === 0 && !W.tf.slice(tf0).some(([op]) => op === 'copy'), '批量在传：没有一个单个传输');

  /* /app/flow：凑批进度和正在传的那一批；没变 304；实时进度缓存 5 秒 */
  const nLive = () => W.tf.filter(([op, b]) => op === 'job' && b.detail).length;
  const l0 = nLive();
  const [fs1, ft1, f1] = await flowGet('alice');
  const [fs2] = await flowGet('alice', ft1);
  const files = bc.items.reduce((s, x) => s + (x.kind === 'dir' ? 4 : 1), 0);
  ok(fs1 === 200 && f1.at > 0 && f1.poll === 5 && f1.gate.ready === 2 && f1.gate.need === 16 && f1.gate.mine === 2 &&
     f1.batch && f1.batch.id === bid1 && f1.batch.stage === 'copy' && f1.batch.items === 16 && f1.batch.mine.length === 16 &&
     f1.batch.bytes === 8e9 && f1.batch.total === 16e9 && f1.batch.pct === 50 && f1.batch.speed === 50 * 1048576 && f1.batch.eta === 160 &&
     f1.batch.files.done === 5 && f1.batch.files.total === files && f1.batch.started > 0, '/app/flow：这一批 16 部、字节 / 速度 / 剩余时间 / 文件数、我的是哪几条，凑批 2 / 16', f1);
  ok(fs2 === 304, '/app/flow 没变：304', fs2);
  ok(nLive() - l0 === 1, '实时进度缓存 5 秒：两次只问了一次传输 Worker', nLive() - l0);
  const [, , fb] = await flowGet('bob');
  ok(fb.batch.mine.length === 0 && fb.gate.mine === 0 && !/Movie|Show|搏击|权力/.test(JSON.stringify(fb)), '/app/flow 只有汇总：不带别人的请求和片名', fb);
  ok((await call('GET', '/app/flow'))[0] === 401, '/app/flow 要登录');

  /* 批量里取消一部：这一批照常跑完 */
  const cancelId = members.find(x => ids.indexOf(x.id) < 14).id;
  const [, cc] = await call('POST', '/admin/api/req', { admin: true, body: { id: cancelId, act: 'cancel' } });
  ok(cc.request.state === 'cancelled' && !(W.stopped || []).includes(4101), '批量里取消一部：这一条取消了，作业照常跑', cc.request);

  /* 传完：成员一起去核对；多的两部开下一批（前面没有了） */
  W.job[4101] = { finished: true, success: true, bytes: 16e9, total: 16e9 };
  const badTv = bc.items.find(x => x.kind === 'dir');
  W.vbad.set('ram2/' + badTv.item, 2);                          // 这一季对不上两次 → 单个补传
  await tick();
  let st = env.DB.db.prepare('SELECT stage, COUNT(*) n FROM tj_req WHERE bat = ? GROUP BY stage').all(bid1);
  ok(st.find(x => x.stage === 'verify').n === 15 && st.find(x => x.stage === 'cancelled').n === 1, '传完：15 个成员一起去核对，取消的那条不核对', st);
  const clog = (await call('GET', '/admin/api/log?id=' + cancelId, { admin: true }))[1].items.map(l => l.msg);
  ok(clog.some(m => /已经取消，不核对、不删；它传到 Dropbox 的那份留在原处/.test(m)), '日志写清楚：取消的那部在 Dropbox 的那份留在原处', clog.slice(0, 3));
  ok(W.batchCalls.length === 2 && W.batchCalls[1].items.length === 2 && W.batchCalls[1].transfers === 16 && lastTick().batch && /前面没有/.test(lastTick().batch.why),
     '上一批传完：多的两部开下一批（前面没有还会清洗好的了）', { calls: W.batchCalls.length, why: lastTick().batch });
  const bid2 = env.DB.db.prepare('SELECT MAX(id) AS id FROM tj_batch').get().id;

  /* 一次核对一批：14 部一致 → 删 PikPak；那一季对不上 → 2 分钟后再核对 */
  const v0 = W.bverify.length, tfV = W.tf.length;
  await tick();
  const lv = lastTick(), opsV = W.tf.slice(tfV).map(x => x[0]);
  ok(lv.over === 0 && lv.fetches < 39 && opsV.filter(o => o === 'batch-verify').length === 1 && opsV.length <= 4,
     '核对那一轮：一个 batch-verify，总共没几个子请求（没碰到预算线、没被掐）', { fetches: lv.fetches, over: lv.over, ops: opsV });
  ok(W.bverify.length === v0 + 1 && W.bverify[v0].items.length === 15 && !W.tf.slice(tfV).some(([op]) => op === 'verify'),
     '核对：15 部一次 batch-verify（没有一个一个核对）', W.bverify.map(b => b.items.length));
  ok(W.bverify[v0].items.filter(x => x.kind === 'dir').every(x => x.sub === 'ram2'), 'batch-verify 里剧集带 sub');
  st = env.DB.db.prepare('SELECT stage, COUNT(*) n FROM tj_req WHERE bat = ? GROUP BY stage').all(bid1);
  ok(st.find(x => x.stage === 'purge').n === 14 && st.find(x => x.stage === 'verify').n === 1, '14 部一致 → 删 PikPak；那一季再核对一次', st);

  /* 删 PikPak：8 个一次（14 部 = 2 次）、云下载任务一次删完、片库一次问完 → 就绪；那一季还是对不上 → 等这一批传完单个补传 */
  const p0 = W.bpurge.length, del0 = W.pkCalls.filter(x => x === 'DELETE /drive/v1/tasks').length, s0 = W.sync.length, tfP = W.tf.length;
  await tick();
  const lp = lastTick(), opsP = W.tf.slice(tfP).map(x => x[0]);
  ok(lp.over === 0 && lp.fetches < 39 && opsP.filter(o => o === 'batch-purge').length === 2 && !opsP.includes('purge'),
     '删除那一轮：两个 batch-purge、没有单个删，没碰到预算线、没被掐', { fetches: lp.fetches, over: lp.over, ops: opsP });
  ok(W.bpurge.length === p0 + 2 && W.bpurge.slice(p0).map(b => b.items.length).join() === '8,6', '删 PikPak：8 个一次 batch-purge（14 部 = 2 次）', W.bpurge.slice(p0).map(b => b.items.length));
  ok(W.pkCalls.filter(x => x === 'DELETE /drive/v1/tasks').length === del0 + 1, '云下载任务一次删完');
  ok(W.sync.slice(s0).filter(x => x.items.length >= 14).length === 1 && W.sync.slice(s0).filter(x => x.items.length === 1).length === 0, '自动通过时问片库：14 部一次问完', W.sync.slice(s0).map(x => x.items.length));
  const done1 = (await mine()).filter(r => r.state === 'done');
  ok(done1.length === 14 && done1.every(r => r.pct === 100), '14 部就绪（App 100%）', done1.length);
  let bad = env.DB.db.prepare('SELECT id, stage, bat, data FROM tj_req WHERE tmdb = ? AND season = ?').get(...(() => { const m = /^Show\.(\d+)\.S0(\d)/.exec(badTv.item); return [+m[1], +m[2]]; })());
  ok(bad.stage === 'copy' && bad.bat === 0, '那一季两次都对不上：离开那一批，单个补传', bad);
  ok(lastTick().fetches <= 42, '核对 / 删除那一轮的子请求没超 42', lastTick().fetches);
  await tick();
  bad = env.DB.db.prepare('SELECT stage, note FROM tj_req WHERE id = ?').get(bad.id);
  ok(bad.stage === 'copy' && /批量 #\d+ 正在传/.test(bad.note) && W.copyWhileBatch === 0, '下一批还在传：单个补传排队等它传完', bad);

  /* 下一批传完：那一季才开始单个补传（带 sub）；之后一个一个核对 / 删除，全部就绪 */
  W.job[4102] = { finished: true, success: true, bytes: 2e9, total: 2e9 };
  const c0 = W.tf.filter(([op]) => op === 'copy').length;
  await tick();
  const solo = W.tf.filter(([op]) => op === 'copy').slice(c0);
  ok(solo.length === 1 && solo[0][1].sub === 'ram2' && solo[0][1].kind === 'dir' && W.copyWhileBatch === 0, '批量都传完了：那一季单个补传（带 sub: ram2）', solo);
  for (let i = 0; i < 15; i++){ await tick(); maxF = Math.max(maxF, lastTick().fetches); if (env.DB.db.prepare("SELECT COUNT(*) n FROM tj_req WHERE stage NOT IN ('done','cancelled')").get().n === 0) break; }
  const fin = env.DB.db.prepare('SELECT stage, COUNT(*) n FROM tj_req GROUP BY stage').all();
  ok(fin.find(x => x.stage === 'done').n === 17 && fin.find(x => x.stage === 'cancelled').n === 1 && fin.length === 2, '17 部全部就绪（取消的那部除外）', fin);
  ok(env.DB.db.prepare('SELECT COUNT(*) n FROM tj_batch WHERE ended = 0').get().n === 0, '两批都收尾了');
  ok(maxF <= 42, '整个流程每一轮的子请求都没超 42', maxF);
  ok(OVERS.length - o0 >= 10 && Math.max(...OVERS.slice(o0)) === 0, '从开批到全部就绪：没有一轮有子请求被预算挡回去（over 一直是 0）', OVERS.slice(o0));
  /* 剧集的每一个传输调用都带 sub: ram2 */
  const tvCalls = W.tf.slice(tf0).filter(([, b]) => b && (/^Show\./.test(b.dir || b.item || '') || (b.items || []).some(x => /^Show\./.test(x && x.item))));
  const ops = new Set(tvCalls.map(([op]) => op));
  ok(tvCalls.length && tvCalls.every(([, b]) => b.items ? b.items.filter(x => /^Show\./.test(x.item)).every(x => x.sub === 'ram2') : b.sub === 'ram2' && (b.to === undefined || b.to === 'ram2')),
     '剧集的每一个传输调用都带 sub: ram2', tvCalls.filter(([, b]) => !(b.items || b.sub === 'ram2')));
  ok(['organize', 'check', 'rename', 'batch-copy', 'batch-verify', 'batch-purge', 'copy', 'verify', 'purge'].every(o => ops.has(o)),
     '（整理、核对整季、改名、批量传输 / 核对 / 删除、单个补传 / 核对 / 删除都覆盖到了）', [...ops]);
  const [, , f3] = await flowGet('alice');
  ok(f3.batch === null && f3.poll === 20 && f3.gate.ready === 0, '都传完了：/app/flow 没有在传的批，20 秒问一次', f3);
}

/* ── 凑批的几条退路（假时钟）：老版本 App 的等 10 分钟、请求中心的等 30 分钟、这一次提交的都清洗好了、前面没有了、退避很久的不等 ── */
{
  let seq = 0;
  const seedReady = (n, bid = 0) => {
    const out = [];
    for (let i = 0; i < n; i++){
      const tmdb = 5000 + (seq++), t = Date.now();
      const r = env.DB.db.prepare(`INSERT INTO tj_req (src, tmdb, season, title, users, stage, note, data, created, updated, since, next, bid)
        VALUES ('movie', ?, 0, 'seed', '["alice"]', 'ready', '', ?, ?, ?, ?, ?, ?)`)
        .run(tmdb, JSON.stringify({ item: 'Seed.' + tmdb + '.[auto-m' + tmdb + '-r0].mkv', kind: 'file', tag: '' }), t, t, t, t + 3600e3, bid);
      out.push(Number(r.lastInsertRowid));
    }
    return out;
  };
  /* 前面还在云下载的（有进度、不出错，每 2 分钟看一次） */
  const seedUp = (bid = 0, next = 0) => {
    const tmdb = 5000 + (seq++), task = 'Tup' + tmdb, t = Date.now();
    W.tasks.set(task, { id: task, phase: 'PHASE_TYPE_RUNNING', progress: 50, file_id: 'nofile', file_name: 'up' });
    env.DB.db.prepare(`INSERT INTO tj_req (src, tmdb, season, title, users, stage, note, data, created, updated, since, next, bid)
      VALUES ('movie', ?, 0, 'up', '["bob"]', 'download', '', ?, ?, ?, ?, ?, ?)`).run(tmdb, JSON.stringify({ task, errs: next ? 3 : 0 }), t, t, t, next, bid);
  };
  const reset = () => { reset26(); for (const k of [...W.tasks.keys()]) if (k.startsWith('Tup')) W.tasks.delete(k); W.caps = ['sub', 'batch']; };
  await call('POST', '/admin/api/cfg', { admin: true, body: { batch: true, batchMin: 16, batchMax: 16, batchWait: 30, vpsSlots: 2 } });
  const launched = () => W.batchCalls.length;

  /* 老版本 App 一部一部提交的（bid = 0）：前面还有在下载的 → 最多等 10 分钟 */
  reset(); seedReady(3); seedUp();
  for (let i = 0; i < 3; i++) await tick();
  ok(launched() === 0, '老版本 App 提交的 3 部、前面还有在下载的：先等（9 分钟）', lastTick());
  await tick();
  ok(launched() === 1 && W.batchCalls[0].items.length === 3 && /最早的一部等了 1[0-9] 分钟/.test(lastTick().batch.why), '等了 10 分钟以上：有几部传几部', lastTick().batch);

  /* 请求中心提交的（bid > 0）、这一次提交的还有在下载的 → 等 30 分钟 */
  reset(); seedReady(3, 7); seedUp(7);
  for (let i = 0; i < 9; i++) await tick();
  ok(launched() === 0, '请求中心提交的、同一次提交还有在下载的：等（28 分钟）');
  await tick();
  ok(launched() === 1 && /最早的一部等了 3[0-9] 分钟/.test(lastTick().batch.why), '等了 30 分钟以上：有几部传几部', lastTick().batch);

  /* 这一次提交的都清洗好了（别人的提交还在下载）：不用等 */
  reset(); seedReady(3, 9); seedUp(10);
  await tick();
  ok(launched() === 1 && W.batchCalls[0].items.length === 3 && /这一次提交的都清洗好了/.test(lastTick().batch.why), '这一次提交的都清洗好了：马上开（别人的还在下载也不等）', lastTick().batch);

  /* 前面没有还会清洗好的了 / 前面的都在长时间退避 */
  reset(); seedReady(2);
  await tick();
  ok(launched() === 1 && /前面没有/.test(lastTick().batch.why), '前面什么都没有了：马上开', lastTick().batch);
  reset(); seedReady(2); seedUp(0, Date.now() + 3600e3);
  await tick();
  ok(launched() === 1 && /前面没有/.test(lastTick().batch.why), '前面的在退避一小时：不等它', lastTick().batch);

  /* 凑够 16 部：一批 16 部，多的等下一批；一次只跑一批 */
  reset(); seedReady(17); seedUp();
  W.batchJobs = [4201]; W.job[4201] = { finished: false, success: false, bytes: 0, total: 1 };
  await tick();
  ok(launched() === 1 && W.batchCalls[0].items.length === 16 && /凑够 16 部/.test(lastTick().batch.why) &&
     env.DB.db.prepare("SELECT COUNT(*) n FROM tj_req WHERE stage = 'ready'").get().n === 1, '凑够 16 部：一批 16 部，多的那部等下一批', lastTick().batch);
  seedReady(16);
  await tick(); await tick();
  ok(launched() === 1, '一批在传：不开第二批（一次只跑一批）', W.batchCalls.length);

  /* 单个传输还在跑：不开批（rclone 内存） */
  reset(); seedReady(2);
  env.DB.db.prepare(`INSERT INTO tj_req (src, tmdb, season, title, users, stage, note, data, created, updated, since, next)
    VALUES ('movie', 5999, 0, 'solo', '["bob"]', 'copy', '', '{"item":"solo.mkv","kind":"file","tag":"","job":501}', 1, 1, 1, ?)`).run(Date.now() + 3600e3);
  W.job[501] = { finished: false, success: false, bytes: 1, total: 10 };
  await tick();
  ok(launched() === 0, '单个传输还在跑：先不开批');
  W.job[501] = { finished: true, success: true, bytes: 10, total: 10 };
  env.DB.db.prepare("UPDATE tj_req SET next = 0 WHERE tmdb = 5999").run();
  await tick(); await tick();
  ok(launched() === 1, '单个传完了：开批');

  /* VPS 熔断中：不开批 */
  reset(); seedReady(2);
  await call('POST', '/admin/api/links', { admin: true, body: {} });          // 面板「测试连接」顺手记下传输 Worker 会什么
  env.DB.db.prepare("INSERT INTO tj_kv (k, v, exp) VALUES ('health', ?, 0) ON CONFLICT(k) DO UPDATE SET v = excluded.v")
    .run(JSON.stringify({ vps: { fails: 0, trips: 1, open: Date.now() + 3600e3, err: 'HTTP 523', ok: 0, bad: Date.now() } }));
  const tfB = W.tf.length;
  await tick();
  ok(launched() === 0 && W.tf.length === tfB, 'VPS 熔断中：不开批，一次都不碰 VPS');
  env.DB.db.exec("DELETE FROM tj_kv WHERE k = 'health'");
  await tick();
  ok(launched() === 1, '熔断过了：开批');

  /* 一次给 4 部加追踪码：/auto 只列一次 */
  reset();
  const ids = [];
  for (let i = 0; i < 4; i++){
    const fid = 'tagf' + i, name = 'Tagme' + i + '.2019.1080p.mkv', tmdb = 5900 + i;
    W.files.set(fid, { id: fid, name, kind: 'drive#file', parent_id: 'AUTO', size: '100', phase: 'PHASE_TYPE_COMPLETE', trashed: false });
    ids.push(Number(env.DB.db.prepare(`INSERT INTO tj_req (src, tmdb, season, title, users, stage, note, data, created, updated, since, next, bid)
      VALUES ('movie', ?, 0, 'tag', '["alice"]', 'ready', '', ?, 1, 1, ?, 0, 0)`).run(tmdb, JSON.stringify({ item: name, kind: 'file', file: fid }), Date.now()).lastInsertRowid));
  }
  const ls0 = W.pkCalls.filter(x => x === 'GET /drive/v1/files').length, pa0 = W.renames.length;
  await tick();
  ok(W.pkCalls.filter(x => x === 'GET /drive/v1/files').length - ls0 === 1 && W.renames.length - pa0 === 4, '4 部一起加追踪码：/auto 这一轮只列一次', { list: W.pkCalls.filter(x => x === 'GET /drive/v1/files').length - ls0 });
  ok(launched() === 1 && W.batchCalls[0].items.every(x => /\[auto-m59\d\d-r\d+\]\.mkv$/.test(x.item)), '加好追踪码的这一轮就开批（前面没有了）', W.batchCalls[0] && W.batchCalls[0].items);

  /* rclone 不认筛选规则（409 nofilter）：这一批退回一个一个传，6 小时内都一个一个传 */
  reset(); seedReady(2);
  W.nofilter = true;
  const c0 = W.tf.filter(([op]) => op === 'copy').length;
  await tick();
  const solo = W.tf.filter(([op]) => op === 'copy').slice(c0);
  const b0 = env.DB.db.prepare('SELECT * FROM tj_batch ORDER BY id DESC LIMIT 1').get();
  ok(solo.length === 2 && b0.ended > 0 && /nofilter/.test(JSON.parse(b0.data).off) && env.DB.db.prepare('SELECT COUNT(*) n FROM tj_req WHERE bat > 0').get().n === 0,
     '409 nofilter：这一批收尾，两部当场退回一个一个传', { solo, b0 });
  const caps = JSON.parse(env.DB.db.prepare("SELECT v FROM tj_kv WHERE k = 'tf:caps'").get().v);
  ok(caps.nofilter > Date.now() + 5 * 3600e3, '记下 rclone 不认筛选规则（6 小时）', caps);
  const health = JSON.parse(env.DB.db.prepare("SELECT v FROM tj_kv WHERE k = 'health'").get()?.v || '{}');
  ok(!(health.vps && health.vps.fails), '409 nofilter 不算 VPS 坏了（不进熔断）', health.vps);
  seedReady(2);
  const nb = W.batchCalls.length, c1 = W.tf.filter(([op]) => op === 'copy').length;
  W.copyJobs = [];
  await tick();
  ok(W.batchCalls.length === nb && W.tf.filter(([op]) => op === 'copy').length - c1 >= 1, '之后等着的直接一个一个传，不再试批量');
  W.nofilter = false;
  reset();
}

/* ── 批量传输的看门狗：开作业时 VPS 抖了（同一个 key 再开）、作业号没记下来（认出正在跑的）、一小时没进展、作业丢了 ── */
{
  reset26();
  W.caps = ['sub', 'batch'];
  await call('POST', '/admin/api/cfg', { admin: true, body: { batch: true, batchMin: 16, batchWait: 600, vpsSlots: 2 } });
  await call('POST', '/admin/api/links', { admin: true, body: {} });        // 先记下传输 Worker 会批量
  for (let i = 0; i < 2; i++){
    const t = Date.now();
    env.DB.db.prepare(`INSERT INTO tj_req (src, tmdb, season, title, users, stage, note, data, created, updated, since, next, bid)
      VALUES ('movie', ?, 0, 'w', '["alice"]', 'ready', '', ?, ?, ?, ?, ?, 0)`).run(6200 + i, JSON.stringify({ item: 'W' + i + '.mkv', kind: 'file', tag: '' }), t, t, t, t + 3600e3);
  }
  const bcs = () => W.tf.filter(([op]) => op === 'batch-copy').map(x => x[1]);
  const n0 = bcs().length;
  W.tfDown = 1;                                                 // 开作业的那一下 VPS 抖了
  await tick();
  let b = env.DB.db.prepare('SELECT * FROM tj_batch ORDER BY id DESC LIMIT 1').get();
  ok(bcs().length === n0 + 1 && W.batchCalls.length === 0 && b && !JSON.parse(b.data).job && b.ended === 0 &&
     env.DB.db.prepare("SELECT COUNT(*) n FROM tj_req WHERE stage = 'copy' AND bat = ?").get(b.id).n === 2, '开作业时 VPS 抖了：批次和成员记下了，作业还没开', b);
  W.batchJobs = [4301]; W.job[4301] = { finished: false, success: false, bytes: 100, total: 2e9 };
  await tick();
  b = env.DB.db.prepare('SELECT * FROM tj_batch WHERE id = ?').get(b.id);
  ok(JSON.parse(b.data).job === 4301 && bcs().slice(n0).every(x => x.key === String(b.id)), '下一轮同一个 key 再开，开成了', bcs().slice(n0).map(x => x.key));
  /* 作业号没记下来（这边超时了，那边其实开了）：同一个 key 再开 → 传输 Worker 认出正在跑的那个，不开第二个 */
  env.DB.db.prepare("UPDATE tj_batch SET data = json_set(data, '$.job', 0, '$.tryAt', 0) WHERE id = ?").run(b.id);
  const calls0 = W.batchCalls.length;
  await tick();
  b = env.DB.db.prepare('SELECT * FROM tj_batch WHERE id = ?').get(b.id);
  ok(JSON.parse(b.data).job === 4301 && W.batchCalls.length === calls0, '作业号丢了：同一个 key 认出正在跑的作业（reused），没开第二个', JSON.parse(b.data));
  const blog = (await call('GET', '/admin/api/log?id=0', { admin: true }))[1].items.map(l => l.msg);
  ok(blog.some(m => /接上了正在跑的传输作业 4301/.test(m)), '日志：接上了正在跑的作业', blog.slice(0, 3));
  /* 一小时没有新字节：停掉重开（rclone 跳过传完的） */
  await tick();                                                 // 问到 100 字节
  advance(61 * 60000);
  await tick();                                                 // 一小时后还是 100 字节
  ok((W.stopped || []).includes(4301), '批量传输一小时没进展：停掉作业', W.stopped);
  W.job[4301].finished = true;                                  // 停掉了
  W.batchJobs = [4302]; W.job[4302] = { missing: 1, finished: true, success: false, error: 'job not found' };
  await tick();
  b = env.DB.db.prepare('SELECT * FROM tj_batch WHERE id = ?').get(b.id);
  ok(JSON.parse(b.data).job === 4302 && JSON.parse(b.data).ctries === 1, '停掉以后重开（同一批、同一个 key）', JSON.parse(b.data));
  /* 作业丢了（VPS 重启）：从断点重开 */
  W.batchJobs = [4303]; W.job[4303] = { finished: false, success: false, bytes: 5, total: 2e9 };
  await tick(); await tick();
  b = env.DB.db.prepare('SELECT * FROM tj_batch WHERE id = ?').get(b.id);
  ok(JSON.parse(b.data).job === 4303 && JSON.parse(b.data).lost === 1, '作业丢了：从断点重开', JSON.parse(b.data));
  const mem = env.DB.db.prepare('SELECT stage FROM tj_req WHERE bat = ?').all(b.id);
  ok(mem.length === 2 && mem.every(x => x.stage === 'copy'), '这期间成员一直停在批量里，没有一个单个传输', mem);
  W.job[4303] = { finished: true, success: true, bytes: 2e9, total: 2e9 };
  await tick();
  ok(env.DB.db.prepare('SELECT COUNT(*) n FROM tj_req WHERE bat = ? AND stage = \'verify\'').get(b.id).n === 2, '传完：一起去核对');
  reset26();
}

/* ── 面板操作：等待凑批的取消 / 重试 / 换规格；批量里的重试；中途关掉批量传输 ── */
{
  reset26();
  W.caps = ['sub', 'batch'];
  await call('POST', '/admin/api/cfg', { admin: true, body: { batch: true, batchMin: 16, batchWait: 600 } });
  const seed = (tmdb, stage, data, extra = '') => {
    const fid = 'pf' + tmdb, tid = 'pt' + tmdb;
    W.files.set(fid, { id: fid, name: data.item, kind: 'drive#file', parent_id: 'AUTO', size: '1', phase: 'PHASE_TYPE_COMPLETE', trashed: false });
    W.tasks.set(tid, { id: tid, phase: 'PHASE_TYPE_RUNNING', progress: 100, file_id: fid, file_name: data.item });
    W.versions['movie:' + tmdb] = [{ tid: 30, title: 'A', mb: 1, labels: [], res: '1080p' }, { tid: 31, title: 'B', mb: 1, labels: [], res: '1080p' }];
    return Number(env.DB.db.prepare(`INSERT INTO tj_req (src, tmdb, season, title, users, stage, note, data, created, updated, since, next, bat)
      VALUES ('movie', ?, 0, 'p', '["alice"]', ?, '', ?, 1, 1, 1, ?, ?)`).run(tmdb, stage, JSON.stringify({ file: fid, task: tid, cur: { tid: 30, t: 'A' }, tried: [], vers: W.versions['movie:' + tmdb].map(v => ({ ...v, t: v.title })), versAt: Date.now(), ...data }),
      Date.now() + 3600e3, extra || 0).lastInsertRowid);
  };
  const act = async (id, a) => (await call('POST', '/admin/api/req', { admin: true, body: { id, act: a } }))[1];
  /* 换规格：等待凑批的也能换（PikPak 那份删掉、追踪码忘掉，下一个规格重新加） */
  const s1 = seed(6101, 'ready', { item: 'P1.[auto-m6101-r1].mkv', kind: 'file', tag: '[auto-m6101-r1]' });
  const k1 = await act(s1, 'skip');
  const r1 = JSON.parse(env.DB.db.prepare('SELECT data FROM tj_req WHERE id = ?').get(s1).data);
  ok(k1.request.stage === 'queued' && W.files.get('pf6101').trashed && r1.tag === undefined && r1.tried.includes(30), '等待凑批的换规格：删 PikPak 那份、忘掉追踪码、记下试过', { k1, r1 });
  /* 取消：PikPak 那份删掉；重试从推送那一步重来 */
  const s2 = seed(6102, 'ready', { item: 'P2.[auto-m6102-r2].mkv', kind: 'file', tag: '[auto-m6102-r2]' });
  const c2 = await act(s2, 'cancel');
  ok(c2.request.state === 'cancelled' && W.files.get('pf6102').trashed && !W.tasks.has('pt6102'), '等待凑批的取消：PikPak 上的任务和文件一起删', c2.request);
  const t2 = await act(s2, 'retry');
  ok(t2.request.stage === 'queued' && t2.request.state === 'active', '取消后重试：从推送那一步重来（PikPak 那份已经删了）', t2.request);
  /* 批量里取消的重试：离开那一批，回去等凑批 */
  const s3 = seed(6103, 'cancelled', { item: 'P3.[auto-m6103-r3].mkv', kind: 'file', tag: '[auto-m6103-r3]', batch: 99, lastStage: 'copy' }, 99);
  const t3 = await act(s3, 'retry');
  const r3 = env.DB.db.prepare('SELECT bat, data FROM tj_req WHERE id = ?').get(s3);
  ok(t3.request.stage === 'ready' && r3.bat === 0 && JSON.parse(r3.data).batch === undefined && !t3.request.batch, '批量里取消的重试：离开那一批，回去等凑批', { t3: t3.request, r3 });
  /* 中途关掉批量传输：等着的直接一个一个传 */
  await call('POST', '/admin/api/cfg', { admin: true, body: { batch: false } });
  W.copyJobs = [];
  const c0 = W.tf.filter(([op]) => op === 'copy').length;
  await tick();
  ok((await one(s3)).stage === 'copy' && W.tf.filter(([op]) => op === 'copy').length > c0 && W.batchCalls.length === 0, '关掉批量传输：等待凑批的直接单个传', await one(s3));
  await call('POST', '/admin/api/cfg', { admin: true, body: { batch: true } });
  for (const k of ['pt6101', 'pt6102', 'pt6103']) W.tasks.delete(k);
}

/* ── 发行检查（关了自动通过）：剧集区的名字放在 tv 里一起问 ── */
{
  reset26();
  W.caps = ['sub', 'batch'];
  await call('POST', '/admin/api/cfg', { admin: true, body: { autoReady: false } });
  const ins = (tmdb, data) => Number(env.DB.db.prepare(`INSERT INTO tj_req (src, tmdb, season, title, users, stage, note, data, created, updated, since, next)
    VALUES (?, ?, ?, 'r', '["alice"]', 'release', '', ?, 1, 1, 1, 0)`).run(data.sub ? 'tv' : 'movie', tmdb, data.sub ? 1 : 0, JSON.stringify(data)).lastInsertRowid);
  W.exists = new Set(['Rel.Movie.mkv']); W.existsTv = new Set(['Rel.Show.A']);
  const m = ins(6001, { item: 'Rel.Movie.mkv', kind: 'file', tag: '' });
  const a = ins(6002, { item: 'Rel.Show.A', kind: 'dir', sub: 'ram2', tag: '' });
  const b = ins(6003, { item: 'Rel.Show.B', kind: 'dir', sub: 'ram2', tag: '' });
  const e0 = W.tf.length;
  await tick();
  const ex = W.tf.slice(e0).filter(([op]) => op === 'exists');
  ok(ex.length === 1 && ex[0][1].items.join() === 'Rel.Movie.mkv' && ex[0][1].tv.join() === 'Rel.Show.A,Rel.Show.B', '发行检查一次问完：电影在 items，剧集区的在 tv', ex);
  ok((await one(m)).stage === 'release' && (await one(a)).stage === 'release' && (await one(b)).state === 'done', '还在 dropbox:auto/ram2 的接着等，不在了的已发行');
  env.DB.db.exec('DELETE FROM tj_req');
  await call('POST', '/admin/api/cfg', { admin: true, body: { autoReady: true } });
}

/* ── 传输 Worker 是老版本（909：ping 里没有 caps）：剧集照旧放 /auto、一个一个传，什么都不带 sub ── */
{
  reset26();
  W.caps = null;
  await call('POST', '/admin/api/cfg', { admin: true, body: { batch: true } });
  W.lib = { mode: 404, seen: new Set() };
  W.copyJobs = []; W.job[88] = { finished: true, success: true, bytes: 1, total: 1 };
  const tf0 = W.tf.length, push0 = W.push.length;
  const mv = (await call('POST', '/app/requests', { user: 'alice', body: { src: 'movie', id: 2000 } }))[1].request;
  const tv = (await call('POST', '/app/requests', { user: 'alice', body: { src: 'tv', id: 3002, season: 1 } }))[1].request;
  ok(!mv.bid && !tv.bid, '老版本 App 一部一部提交：没有 bid');
  for (let i = 0; i < 14; i++){
    for (const t of [...W.tasks.keys()]) finishTask(t);
    await tick();
    if ((await one(mv.id)).state === 'done' && (await one(tv.id)).state === 'done') break;
  }
  ok((await one(mv.id)).state === 'done' && (await one(tv.id)).state === 'done', '老版本传输 Worker：照样一部一部传完、就绪', [await one(mv.id), await one(tv.id)]);
  const calls = W.tf.slice(tf0);
  ok(calls.some(([op]) => op === 'ping') && !calls.some(([op]) => op.startsWith('batch-')), '问过 ping，没有 caps：不用批量接口', [...new Set(calls.map(x => x[0]))]);
  ok(calls.every(([, b]) => !b || b.sub === undefined) && W.push.slice(push0).every(p => p.parent === 'AUTO'), '剧集照旧放 /auto，调用里不带 sub', W.push.slice(push0));
  ok(calls.some(([op, b]) => op === 'copy' && b.kind === 'dir') && calls.some(([op, b]) => op === 'copy' && b.kind === 'file'), '电影、剧集都走单个传输');
  const logs = (await call('GET', '/admin/api/log?id=' + mv.id, { admin: true }))[1].items.map(l => l.msg);
  ok(!logs.some(m => /等待凑批/.test(m)), '老版本：不进「等待凑批」');
  W.caps = ['sub', 'batch'];
}

/* ── 2.6 的几处细节：补传先传完再开下一批、加追踪码读回来之前被掐、第二个在传的批次、跟上等待凑批的带 wait ── */
{
  reset26();
  W.caps = ['sub', 'batch'];
  await call('POST', '/admin/api/cfg', { admin: true, body: { batch: true, batchMin: 16, batchMax: 16, batchWait: 600, vpsSlots: 2, tagNames: true } });
  await call('POST', '/admin/api/links', { admin: true, body: {} });        // 先记下传输 Worker 会批量
  let seq = 0;
  const ins = (stage, data, extra = {}) => {
    const t = Date.now(), tmdb = 7000 + (seq++);
    return Number(env.DB.db.prepare(`INSERT INTO tj_req (src, tmdb, season, title, users, stage, note, data, created, updated, since, next, bid, bat)
      VALUES ('movie', ?, 0, 'x', '["alice"]', ?, '', ?, ?, ?, ?, ?, ?, ?)`)
      .run(tmdb, stage, JSON.stringify(data), t, t, extra.since ?? t, extra.next ?? t + 3600e3, extra.bid ?? 0, extra.bat ?? 0).lastInsertRowid);
  };
  const launched = () => W.batchCalls.length;

  /* 批量里对不上、排着队的单个补传：先让它传完，再开下一批（不然一批接一批开，它一直排不上） */
  for (let i = 0; i < 2; i++) ins('ready', { item: 'Rd' + i + '.mkv', kind: 'file', tag: '' });
  const solo = ins('copy', { item: 'Solo.mkv', kind: 'file', tag: '', vtries: 1, rode: 3 }, { next: 0 });
  W.copyJobs = [91]; W.job[91] = { finished: true, success: true, bytes: 5, total: 5 };
  const c0 = W.tf.filter(([op]) => op === 'copy').length;
  await tick();
  ok(launched() === 0 && W.tf.filter(([op]) => op === 'copy').length === c0 + 1, '排着队的补传先开传，这一轮不开批', { launched: launched(), solo: await one(solo) });
  await tick();
  ok(launched() === 1 && (await one(solo)).stage !== 'copy' && W.batchCalls[0].items.length === 2, '补传传完了：再开批', { launched: launched(), solo: (await one(solo)).stage });
  /* 退避很久的单个传输（一直出错的）不挡着开批 */
  reset26(); W.caps = ['sub', 'batch'];
  await call('POST', '/admin/api/links', { admin: true, body: {} });
  for (let i = 0; i < 2; i++) ins('ready', { item: 'Rb' + i + '.mkv', kind: 'file', tag: '' });
  ins('copy', { item: 'Stuck.mkv', kind: 'file', tag: '', errs: 4 }, { next: Date.now() + 3600e3 });
  await tick();
  ok(launched() === 1, '退避一小时的单个传输不挡着开批');

  /* 加追踪码：PikPak 改了名、读回来那一下失败（或者子请求用完了）→ 新名字已经记下，下一轮不再改、不拿旧名字去找 */
  reset26(); W.caps = ['sub', 'batch'];
  await call('POST', '/admin/api/links', { admin: true, body: {} });
  W.files.set('tg1', { id: 'tg1', name: 'Tagcut.2018.1080p.mkv', kind: 'drive#file', parent_id: 'AUTO', size: '10', phase: 'PHASE_TYPE_COMPLETE', trashed: false });
  const tg = ins('ready', { item: 'Tagcut.2018.1080p.mkv', kind: 'file', file: 'tg1' }, { next: 0 });
  const rn0 = W.renames.length;
  W.fileGetDown = 1;
  await tick();
  let d = JSON.parse(env.DB.db.prepare('SELECT data FROM tj_req WHERE id = ?').get(tg).data);
  ok(W.renames.length === rn0 + 1 && /\[auto-m\d+-r\d+\]\.mkv$/.test(d.item) && d.tag === undefined && launched() === 0,
     '改了名、读回来失败：新名字先记下（追踪码还没确认，不开批）', d);
  advance(5 * 60000);
  await tick();
  d = JSON.parse(env.DB.db.prepare('SELECT data FROM tj_req WHERE id = ?').get(tg).data);
  ok(W.renames.length === rn0 + 1 && d.tag && d.item.includes(d.tag) && launched() === 1 && W.batchCalls[0].items[0].item === d.item,
     '下一轮：名字里已经有追踪码，不再改名，用新名字开批', { d, b: W.batchCalls[0] });
  W.fileGetDown = 0;

  /* 面板「推进一轮」和定时任务撞上、开出了第二个在传的批次：前面那一批传完之前不动它（不会被当成传完了去核对），之后再开 */
  reset26(); W.caps = ['sub', 'batch'];
  await call('POST', '/admin/api/links', { admin: true, body: {} });
  for (let i = 0; i < 2; i++) ins('ready', { item: 'Ra' + i + '.mkv', kind: 'file', tag: '' });
  W.batchJobs = [4501, 4502]; W.job[4501] = { finished: false, success: false, bytes: 1, total: 2e9 }; W.job[4502] = { finished: false, success: false, bytes: 1, total: 1e9 };
  await tick();
  const b1 = env.DB.db.prepare('SELECT id FROM tj_batch ORDER BY id DESC LIMIT 1').get().id;
  const t = Date.now();
  const b2 = Number(env.DB.db.prepare("INSERT INTO tj_batch (stage, items, data, created, updated) VALUES ('copy', '[]', '{}', ?, ?)").run(t, t).lastInsertRowid);
  const m2 = ins('copy', { item: 'Second.mkv', kind: 'file', tag: '', batch: b2 }, { bat: b2 });
  await tick();
  ok(env.DB.db.prepare('SELECT stage FROM tj_batch WHERE id = ?').get(b2).stage === 'copy' && (await one(m2)).stage === 'copy' && launched() === 1,
     '第二个在传的批次：前面那一批还在传，原样不动', { b2: env.DB.db.prepare('SELECT * FROM tj_batch WHERE id = ?').get(b2), m2: (await one(m2)).stage });
  W.job[4501] = { finished: true, success: true, bytes: 2e9, total: 2e9 };
  await tick();
  await tick();
  ok(launched() === 2 && W.batchCalls[1].key === String(b2) && W.batchCalls[1].items.map(x => x.item).join() === 'Second.mkv' && (await one(m2)).stage === 'copy',
     '前面那一批传完：再开第二个（key = 它自己的编号）', { calls: W.batchCalls.map(x => x.key), b1, b2 });

  /* 请求中心提交时跟上了一条在等待凑批的：回包里一样带 wait */
  reset26(); W.caps = ['sub', 'batch'];
  const t2 = Date.now();
  env.DB.db.prepare(`INSERT INTO tj_req (src, tmdb, season, title, users, stage, note, data, created, updated, since, next)
    VALUES ('movie', 7900, 0, 'w', '["alice"]', 'ready', '', '{"item":"W.mkv","kind":"file","tag":""}', ?, ?, ?, ?)`).run(t2, t2, t2, t2 + 3600e3);
  const [, jb] = await batchPost('bob', [{ src: 'movie', id: 7900 }]);
  ok(jb.items[0].result === 'joined' && jb.items[0].request.stage === 'ready' && jb.items[0].request.wait && jb.items[0].request.wait.ready === 1 &&
     jb.items[0].request.wait.need === 16 && jb.items[0].request.pct === 60, '跟上等待凑批的：回包带 wait（1 / 16），STEP 4 的 60%', jb.items[0]);
  reset26();
}

/* ── 2.6 一次只跑一批：在传的批次单独查（收尾中的再多也挤不掉它）、排在后面的也在 copy 的成员接着停、库里也挡住第二批 ── */
{
  const PARK = 15 * 60000;                                      // LIMIT.memberPark：batchGate 把成员停这么久
  let seq = 0;
  const ins = (stage, data, extra = {}) => {
    const t = Date.now(), tmdb = 8000 + (seq++);
    return Number(env.DB.db.prepare(`INSERT INTO tj_req (src, tmdb, season, title, users, stage, note, data, created, updated, since, next, bid, bat)
      VALUES ('movie', ?, 0, 'x', '["alice"]', ?, '', ?, ?, ?, ?, ?, ?, ?)`)
      .run(tmdb, stage, JSON.stringify(data), t, t, extra.since ?? t, extra.next ?? t + 3600e3, extra.bid ?? 0, extra.bat ?? 0).lastInsertRowid);
  };
  const newBatch = (stage, data = {}) => {
    const t = Date.now();
    return Number(env.DB.db.prepare('INSERT INTO tj_batch (stage, items, data, created, updated) VALUES (?, ?, ?, ?, ?)').run(stage, '[]', JSON.stringify(data), t, t).lastInsertRowid);
  };
  const row = (id) => { const x = env.DB.db.prepare('SELECT stage, bat, note, data FROM tj_req WHERE id = ?').get(id); return { ...x, d: JSON.parse(x.data) }; };
  const bstage = (id) => env.DB.db.prepare('SELECT stage, ended FROM tj_batch WHERE id = ?').get(id);
  const running = () => Object.entries(W.batchRun).filter(([, id]) => W.job[id] && W.job[id].finished === false).map(([k]) => k);
  const setup = async () => {
    reset26(); W.caps = ['sub', 'batch'];
    await call('POST', '/admin/api/cfg', { admin: true, body: { batch: true, batchMin: 16, batchMax: 16, batchWait: 600, vpsSlots: 2, tagNames: true, autoReady: true } });
    await call('POST', '/admin/api/links', { admin: true, body: {} });      // 先记下传输 Worker 会批量
  };

  /* 收尾中的批次 22 批（成员删 PikPak 一直出错，退避 8 小时）+ 正在传的那一批（编号最大）+ 两部等着凑批 + 一条排队的单个补传 */
  await setup();
  const old = [];
  for (let i = 0; i < 22; i++){
    const id = newBatch('purge'); old.push(id);
    if (i < 21) ins('purge', { item: 'Old' + i + '.mkv', kind: 'file', tag: '', errs: 5 }, { bat: id, next: Date.now() + 8 * 3600e3 });
  }
  const t0 = Date.now();
  const run = newBatch('copy', { job: 4601, started: t0, cbAt: t0, cb: 1 });
  W.job[4601] = { finished: false, success: false, bytes: 5e8, total: 2e9 }; W.batchRun[String(run)] = 4601;
  const mem = [0, 1].map(i => ins('copy', { item: 'Run' + i + '.mkv', kind: 'file', tag: '', batch: run }, { bat: run, next: t0 + PARK }));
  for (let i = 0; i < 2; i++) ins('ready', { item: 'Next' + i + '.mkv', kind: 'file', tag: '' });
  const recopy = ins('copy', { item: 'Recopy.mkv', kind: 'file', tag: '', vtries: 1, rode: old[0] }, { next: 0 });
  W.copyJobs = [92]; W.job[92] = { finished: false, success: false, bytes: 1, total: 9 };
  const tfA = W.tf.length;
  await tick();
  const opsA = W.tf.slice(tfA);
  ok(W.batchCalls.length === 0 && opsA.filter(([op, b]) => op === 'job' && b.jobid === 4601).length === 1 && !opsA.some(([op]) => op === 'copy') && W.copyWhileBatch === 0,
     '收尾中的批次有 22 批：正在传的那一批照样认得出（问了它的作业，没开第二批，没开单个传输）', opsA.map(x => x[0]));
  ok(new RegExp('批量 #' + run + ' 正在传').test(row(recopy).note), '排队的单个补传：等正在传的那一批', row(recopy).note);
  ok(bstage(old[21]).stage === 'done' && bstage(old[21]).ended > 0 && bstage(old[0]).stage === 'purge',
     '收尾中的批次一批不漏：最新的那批（成员都走完了）也收尾了，不只看最早的 20 批', { first: bstage(old[0]), last: bstage(old[21]) });
  for (let i = 0; i < 7; i++){ W.job[4601].bytes += 1e8; await tick(); }   // 22 分钟：成员停满 15 分钟醒过来一次
  const polls = W.tf.slice(tfA).filter(([op, b]) => op === 'job' && b.jobid === 4601).length;
  ok(mem.every(id => row(id).stage === 'copy' && row(id).bat === run && row(id).d.batch === run) && polls === 8 && W.batchCalls.length === 0 && W.copyWhileBatch === 0,
     '22 分钟里每轮都问这一批的作业；成员醒过来也接着停着，不提前去核对', { polls, mem: mem.map(row).map(x => x.stage), calls: W.batchCalls.map(x => x.key) });
  W.job[4601] = { finished: true, success: true, bytes: 2e9, total: 2e9 };
  await tick();
  ok(mem.every(id => row(id).stage === 'verify') && bstage(run).stage === 'verify', '这一批传完：成员一起去核对');
  await tick();
  ok(W.tf.some(([op, b]) => op === 'copy' && b.item === 'Recopy.mkv') && W.copyWhileBatch === 0, '没有在传的批了：排队的单个补传才开传');

  /* 排在后面、也在 copy 的第二批（以前面板「推进一轮」撞上定时任务开出来的）：成员按 memberPark 停着、醒过来不提前去核对；
     前面那一批传完时有等着凑批的，也先开第二批的作业，不凑第三批（不会两个作业一起跑） */
  await setup();
  for (let i = 0; i < 2; i++) ins('ready', { item: 'Ra' + i + '.mkv', kind: 'file', tag: '' });
  W.batchJobs = [4501, 4502, 4503];
  for (const j of [4501, 4502, 4503]) W.job[j] = { finished: false, success: false, bytes: 1, total: 1e9 };
  await tick();
  const b1 = env.DB.db.prepare('SELECT MAX(id) AS id FROM tj_batch').get().id;
  const b2 = newBatch('copy');
  const m2 = ins('copy', { item: 'Second.mkv', kind: 'file', tag: '', batch: b2 }, { bat: b2, next: Date.now() + PARK });
  const wait = [0, 1].map(i => ins('ready', { item: 'Rc' + i + '.mkv', kind: 'file', tag: '' }));
  let most = 0;
  for (let i = 0; i < 7; i++){ W.job[4501].bytes += 1e8; await tick(); most = Math.max(most, running().length); }
  const l2 = (await call('GET', '/admin/api/log?id=' + m2, { admin: true }))[1].items.map(l => l.msg);
  ok(row(m2).stage === 'copy' && row(m2).bat === b2 && row(m2).d.batch === b2 && bstage(b2).stage === 'copy' && !l2.some(m => /核对/.test(m)) &&
     W.batchCalls.map(x => x.key).join() === String(b1), '第二批的成员停满 15 分钟醒过来：自己那一批还没开，接着停着（不去核对）', { m2: row(m2), l2 });
  ok(new RegExp('批量 #' + b2 + ' 排队：等批量 #' + b1).test(row(m2).note), '面板上写着第二批在排队', row(m2).note);
  const [, , fw] = await flowGet('alice');
  ok(fw.batch && fw.batch.id === b1 && fw.batch.stage === 'copy', '/app/flow 给的是正在传的那一批（不是排在后面的）', fw.batch);
  const [, sw] = await call('GET', '/admin/api/state', { admin: true });
  ok(sw.batch && sw.batch.id === b1 && sw.slots.batch === b1, '面板的系统卡也是正在传的那一批', sw.batch);
  W.job[4501] = { finished: true, success: true, bytes: 1e9, total: 1e9 };
  await tick(); most = Math.max(most, running().length);
  ok(W.batchCalls.length === 1 && env.DB.db.prepare("SELECT COUNT(*) n FROM tj_batch WHERE ended = 0 AND stage = 'copy'").get().n === 1 &&
     wait.every(id => row(id).stage === 'ready' && row(id).bat === 0), '第一批传完：等着凑批的不凑第三批（第二批还在 copy）', { calls: W.batchCalls.map(x => x.key), wait: wait.map(row).map(x => x.stage) });
  await tick(); most = Math.max(most, running().length);
  ok(W.batchCalls.length === 2 && W.batchCalls[1].key === String(b2) && running().join() === String(b2), '下一轮开第二批的作业（key = 它自己的编号）', { calls: W.batchCalls.map(x => x.key), running: running() });
  W.job[4502] = { finished: true, success: true, bytes: 1e9, total: 1e9 };
  await tick(); most = Math.max(most, running().length);
  ok(W.batchCalls.length === 3 && W.batchCalls[2].items.map(x => x.item).join() === 'Rc0.mkv,Rc1.mkv' && most === 1,
     '第二批传完：等着的两部这才开第三批；从头到尾同时只有一个批量作业', { calls: W.batchCalls.map(x => x.key), most });

  /* 库里也挡住：凑批时另一边（面板「推进一轮」不拿租约）刚插了一批在 copy 的 → 这边插不进去，不开、不动成员 */
  await setup();
  const rr = [0, 1].map(i => ins('ready', { item: 'Rr' + i + '.mkv', kind: 'file', tag: '' }));
  const prep = env.DB.prepare;
  let racer = 0;
  env.DB.prepare = function (sql){
    if (!racer && /^INSERT INTO tj_batch/.test(sql)){
      const t = Date.now();
      racer = Number(this.db.prepare("INSERT INTO tj_batch (stage, items, data, created, updated) VALUES ('copy', '[]', ?, ?, ?)").run(JSON.stringify({ job: 4801, started: t, cbAt: t }), t, t).lastInsertRowid);
      W.job[4801] = { finished: false, success: false, bytes: 1, total: 9 }; W.batchRun[String(racer)] = 4801;
    }
    return prep.call(this, sql);
  };
  try { await tick(); } finally { env.DB.prepare = prep; }
  ok(racer > 0 && W.batchCalls.length === 0 && env.DB.db.prepare('SELECT COUNT(*) n FROM tj_batch WHERE ended = 0').get().n === 1 &&
     rr.every(id => row(id).stage === 'ready' && row(id).bat === 0), '另一边刚开了一批：这边插不进第二批，等着的原样不动', { racer, calls: W.batchCalls.length, rr: rr.map(row) });
  const tfR = W.tf.length;
  await tick();
  ok(W.tf.slice(tfR).some(([op, b]) => op === 'job' && b.jobid === 4801) && W.batchCalls.length === 0, '下一轮：认出那一批在传（问它的作业），照样不开第二批');
}

/* ── 2.6 凑批、/app/flow 的查询走索引：tj_req 不删旧的（就绪、失败的留着追踪、看历史），整张表读一遍很贵（D1 按读了几行算） ── */
{
  reset26(); W.caps = ['sub', 'batch'];
  await call('POST', '/admin/api/cfg', { admin: true, body: { batch: true, batchMin: 16, batchWait: 600 } });
  await call('POST', '/admin/api/links', { admin: true, body: {} });
  const t = Date.now();
  const hist = env.DB.db.prepare(`INSERT INTO tj_req (src, tmdb, season, title, users, stage, note, data, created, updated, since, next, bid, bat)
    VALUES ('movie', ?, 0, 'h', '["alice"]', ?, '', '{}', 1, 1, 1, 0, ?, ?)`);
  for (let i = 0; i < 300; i++) hist.run(9000 + i, i % 10 ? 'done' : 'failed', i % 3, i % 7);
  for (let i = 0; i < 3; i++) env.DB.db.prepare(`INSERT INTO tj_req (src, tmdb, season, title, users, stage, note, data, created, updated, since, next, bid)
    VALUES ('movie', ?, 0, 'r', '["alice"]', 'ready', '', ?, ?, ?, ?, ?, 1)`).run(9500 + i, JSON.stringify({ item: 'Ix' + i + '.mkv', kind: 'file', tag: '' }), t, t, t, t + 3600e3);
  env.DB.db.prepare(`INSERT INTO tj_req (src, tmdb, season, title, users, stage, note, data, created, updated, since, next, bid)
    VALUES ('movie', 9600, 0, 'u', '["bob"]', 'download', '', '{"task":"nope"}', ?, ?, ?, ?, 1)`).run(t, t, t, t + 6 * 60000);   // 同一次提交还在下载：先不开批
  const seen = [];
  const prep = env.DB.prepare;
  env.DB.prepare = function (sql){ seen.push(sql); return prep.call(this, sql); };
  try { await tick(); await flowGet('alice'); } finally { env.DB.prepare = prep; }
  const idx = env.DB.db.prepare('PRAGMA index_list(tj_req)').all().map(x => x.name);
  const plans = [...new Set(seen)].filter(s => /\btj_req\b/.test(s) && /^\s*(SELECT|UPDATE)/i.test(s))
    .map(s => [s.replace(/\s+/g, ' ').slice(0, 90), env.DB.db.prepare('EXPLAIN QUERY PLAN ' + s).all().map(x => x.detail)]);
  const scans = plans.filter(([, p]) => p.some(d => /^SCAN tj_req\b/.test(d)));
  ok(idx.includes('tj_req_stage'), 'tj_req 有 stage 的索引（db() 给老库也补上）', idx);
  ok(plans.length >= 8 && !scans.length, '定时任务一轮 + /app/flow 的查询没有一条把 tj_req 整张表读一遍', scans);
  ok(seen.filter(s => /stage = 'ready' ORDER BY since/.test(s)).length === 2, '有加好追踪码的等着：凑批那一步一轮查两次（开头、末尾）');
  seen.length = 0;
  env.DB.db.exec("DELETE FROM tj_req WHERE stage IN ('ready', 'download')");
  env.DB.prepare = function (sql){ seen.push(sql); return prep.call(this, sql); };
  try { await tick(); } finally { env.DB.prepare = prep; }
  ok(seen.filter(s => /stage = 'ready' ORDER BY since/.test(s)).length === 1, '一个等着凑批的都没有：一轮只查一次（末尾不再查）', seen.filter(s => /ready/.test(s)));
  env.DB.db.exec('DELETE FROM tj_req');
}

/* ── 2.6 子请求预算：一轮里有调用被预算挡回去，tick:last 记下 over（面板的系统卡也写着），下一轮接着做、不算出错 ── */
{
  reset26(); W.caps = ['sub', 'batch'];
  await call('POST', '/admin/api/cfg', { admin: true, body: { batch: true, pkSlots: 20 } });
  await call('POST', '/admin/api/links', { admin: true, body: {} });
  /* 下下来的是很深的文件夹（12 个子文件夹、每个下面再 12 个）：清洗一部要列 25 个文件夹，两部一轮做不完 */
  const deep = (tag) => {
    const root = 'deep' + tag, F = (id, name, parent, kind = 'drive#folder', size = '0') =>
      W.files.set(id, { id, name, kind, parent_id: parent, size, phase: 'PHASE_TYPE_COMPLETE', trashed: false });
    F(root, 'Deep.' + tag + '.2020.1080p', 'AUTO');
    F(root + 'v', 'Deep.' + tag + '.2020.1080p.mkv', root, 'drive#file', '5000000000');
    for (let i = 0; i < 12; i++){ F(root + 'a' + i, 'd' + i, root); for (let j = 0; j < 12; j++) F(root + 'a' + i + 'b' + j, 'e' + j, root + 'a' + i); }
    return root;
  };
  const ids = ['A', 'B'].map((tag, i) => Number(env.DB.db.prepare(`INSERT INTO tj_req (src, tmdb, season, title, users, stage, note, data, created, updated, since, next)
    VALUES ('movie', ?, 0, 'deep', '["alice"]', 'clean', '', ?, 1, 1, 1, 0)`).run(9700 + i, JSON.stringify({ file: deep(tag), cur: { tid: 1, t: 'x' }, tried: [] })).lastInsertRowid));
  const st = () => ids.map(id => env.DB.db.prepare('SELECT stage, data FROM tj_req WHERE id = ?').get(id)).map(x => ({ stage: x.stage, errs: JSON.parse(x.data).errs || 0 }));
  await tick();
  const l1 = lastTick(), s1 = st();
  ok(l1.over >= 1 && l1.fetches === 42 && s1.filter(x => x.stage === 'ready').length === 1 && s1.filter(x => x.stage === 'clean').length === 1 && s1.every(x => !x.errs),
     '一轮的子请求用完了：tick:last 记下有几个被挡回去（over），第二部留到下一轮、不算出错', { l1, s1 });
  const [, sp] = await call('GET', '/admin/api/state', { admin: true });
  ok(sp.tick && sp.tick.over === l1.over, '面板的系统卡拿得到 over', sp.tick);
  await tick();
  ok(st().every(x => x.stage === 'ready') && lastTick().over === 0, '下一轮：第二部也清洗好了，没有再被挡', { s: st(), l: lastTick() });
  env.DB.db.exec('DELETE FROM tj_req');
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
