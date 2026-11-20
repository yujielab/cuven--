/**
 * Cuven 请求添加 Worker（tj.cuven.us）v2.0
 *
 * v2.0：核心重做——稳、省、不堵
 *   · 熔断：影片库 / VPS / PikPak / TMDB 各自记健康，连续 3 次暂时性失败就熔断 2→4→8→15 分钟，要用它的请求原地等，
 *     不算出错、不换规格；到期放一次试探，通了就恢复（面板「系统」里看得到）
 *   · 智能队列：先把开了头的做完（发行检查 > 删除 > 核对 > 传输 > 改名 / 清洗 > 云下载 > 排队），排队中的每个人的第一个先上，
 *     好几个人在等的优先；PikPak 同时云下载、VPS 同时传输各有资源位（面板里调），满了排队，不会把 rclone 压垮
 *   · 批量：一轮里要问的 rclone 作业一次问完（/api/link/jobs），发行检查列一次目录（/api/link/exists {items}）
 *   · 看门狗：传输一小时 / 改名半小时没有新字节就停掉重开（copy 跳过已传完的）；VPS 重启丢了作业就从断点重开；
 *     依赖一天都连不上才停下等人
 *   · 状态只许按流程走（FLOW），每一步可重入；一轮的写入（请求 + 日志）攒起来一个事务写进 D1
 *   · /app/requests 带 ETag，App 轮询没变化时回 304
 *   要配合传输 Worker 908（52x 自动重试、批量接口）；老版本也能跑，只是退回一个一个问。
 *
 * v1.2：App 上的五步改成 等待制片商 → 等待回应 → 等待品质管理 → 等待传输 → 最终发行审批；给 App 的进度不再带内部说明
 *       （note / 规格 / 试过几个），只有控制面板看得到。
 * v1.1：D1 的表名都带 tj_ 前缀（tj_req / tj_kv / tj_log）。库和别的 Worker 共用、里面已经有叫 kv 的表时，
 *       v1.0 报 no such column: exp。建表后再对一遍列，缺的补上。
 *
 * App 里点「请求添加」→ 这里排队 → 每分钟的定时任务一步一步往前推：
 *
 *   ① 已请求    queued    问影片库（lb.cuven.us）这部片 / 这一季按规格排好的全部版本，取没试过的第一个，
 *                         让影片库把它推进 PikPak 的 /auto（影片库用它自己配的 PikPak 账号建云下载任务）
 *   ② 待传输    download  盯 PikPak 云下载任务到 100%。出错 / 2 小时没进度 / 12 小时没下完 → 删掉任务和文件，回到 ①
 *                         推下一个规格
 *   ③ 预处理中  clean     电影：文件夹里体积最大的视频移到 /auto，原文件夹进回收站（单文件直接用）
 *               check     剧集：传输 Worker 整理文件夹（删广告垃圾）→ 核对整季是否完整（总集数取标题里写的，
 *                         没写就按 TMDB 已播出的集数）→ 不完整 → 回到 ① 降档重试
 *               rename    剧集：传输 Worker 按发行命名改文件夹名（等 rclone 的任务跑完）
 *   ④ 正在传输  copy      VPS 上的 rclone：webdav:auto/<名字> → dropbox:auto/<名字>（先 copy）
 *               verify    两端核对（文件数 + 字节数），对不上重新 copy（最多 3 次）
 *               purge     核对一致才删 PikPak 那份
 *   ⑤ 等待工作人员的最终发行  release  每 5 分钟看一眼 dropbox:auto/<名字> 还在不在：人工挪去 ram / ram2 之后就不在了
 *   完成        done      已发行
 *
 * App 轮询 /app/requests 显示进度（STEP X OF 5、百分比），状态一变就发本地通知。
 *
 * 绑定 / 变量（Cloudflare 面板 → Worker → 设置）：
 *   DB             D1 数据库（表自己建，不用跑迁移；表名带 tj_ 前缀，可以和别的 Worker 共用一个库）
 *   ADMIN_KEY      控制面板口令（密钥）。PikPak 密码用它派生的密钥加密后存进 D1，换口令要重新填一次 PikPak 密码
 *   LB_GATE        影片库 Worker 的 GATE 口令（密钥）
 *   LINK_KEY       传输 Worker 的 LINK_KEY（密钥）
 *   LB_BASE        默认 https://lb.cuven.us
 *   TRANSFER_BASE  默认 https://transfer.cuven.us
 *   STREAM_BASE    默认 https://stream.cuven.online（TMDB 分季集数）
 *   ACCOUNT_BASE   默认 https://check.cuven.us（App 用户名核对：请求要带真实存在的用户名）
 *   AUTO_DIR       默认 auto
 *   定时触发器      * * * * *（每分钟）
 * PikPak 账号和密码在控制面板（https://tj.cuven.us/）里填：清洗（盯任务、移动、删文件夹）用它。
 * 它必须和影片库 Worker 配的 PIKPAK_USER 是同一个账号 —— 影片库推进哪个网盘，这里就去哪个网盘清洗。
 *
 * App 接口（不需要口令；请求类的要带 x-cuven-user: <用户名>）：
 *   GET  /app/catalog?src=movie|tv|all&q=&page=&sort=new|vote|hot|spec&own=all|hide&min=
 *        索引里的全部已知影片 / 剧集（TMDB 编号），带上这部片的请求进度
 *   GET  /app/detail?src=movie|tv&id=<TMDB>&season=
 *        有没有可请求的资源（几个版本、最好的规格），这部 / 每一季的请求进度
 *   GET  /app/requests                 我的请求（进行中的 + 30 天内结束的）
 *   POST /app/requests { src, id, season }   请求添加（同一部 / 同一季已经有人在请求就跟上，不重复下）
 *
 * 控制面板接口（x-admin-key: ADMIN_KEY）：/admin/api/state · cfg · pk · links · req · add · tick
 */

const VER = 'tj 2.0';
const MIN = 60000, HOUR = 3600000, DAY = 86400000;
const LIMIT = {
  userActive: 5,          // 一个用户同时进行中的请求
  globalActive: 30,       // 全部进行中的请求
  perTick: 24,            // 一轮最多推进几条（轮询类的步骤批量问，便宜）
  tickMs: 22000,          // 一轮的时间预算
  fetches: 42,            // 一轮的子请求预算（免费计划 50）
  dlStall: 2 * HOUR,      // 云下载这么久没进度就换规格
  dlMax: 12 * HOUR,       // 云下载最长等多久
  busyMax: 30 * MIN,      // 剧集文件夹里一直有没下完的分段文件
  copyTries: 3,
  copyStall: HOUR,        // 传输这么久没有新字节：停掉重开
  renameStall: 30 * MIN,  // 改名这么久没有进展：停掉重来
  lostMax: 5,             // rclone 作业丢了（VPS 重启）最多重开几次
  depGiveUp: DAY,         // 依赖一直连不上多久就停下等人
  stepErrors: 20,         // 同一步连续出错这么多次就停下来等人看
  releasePoll: 5 * MIN,
  refail: DAY,            // 失败后多久用户可以重新请求
};
const ACTIVE = ['queued', 'download', 'clean', 'check', 'rename', 'copy', 'verify', 'purge', 'release'];
const ENDED = ['done', 'failed', 'cancelled'];
const STEP_OF = { queued: 1, download: 2, clean: 3, check: 3, rename: 3, copy: 4, verify: 4, purge: 4, release: 5, done: 5 };
/* App 上给用户看的五步（用户定的说法）。内部在做什么（推到 PikPak、清洗、传 Dropbox…）只在控制面板里看得到 */
const STEP_LABELS = ['等待制片商', '等待回应', '等待品质管理', '等待传输', '最终发行审批'];
const STAGE_TEXT = {
  queued: '排队，准备推送到 PikPak', download: 'PikPak 云下载中', clean: '清洗文件夹', check: '整理并核对整季',
  rename: '按发行命名', copy: '传输到 Dropbox', verify: '核对两端', purge: '清理 PikPak', release: '等待工作人员发行',
  done: '已发行', failed: '失败', cancelled: '已取消',
};
const VIDEO_RE = /\.(mkv|mp4|m4v|ts|m2ts|mts|avi|mov|wmv|flv|webm|rmvb|iso)$/i;
const SAMPLE_RE = /(^|[.\s_\-\[(])(sample|trailer|预告|花絮)([.\s_\-\])]|$)/i;

const base = (env, k, d) => String(env[k] || d).replace(/\/+$/, '');
const now = () => Date.now();
const clamp = (v, a, b) => Math.min(b, Math.max(a, v));
const json = (o, status = 200, h = {}) => new Response(JSON.stringify(o), {
  status, headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store', ...h } });
const err = (msg, extra) => Object.assign(new Error(msg), extra || {});
const sleep = (ms) => new Promise(r => setTimeout(r, ms));

/* ══════════════════════════════════════════════════════════════════
   D1
   ══════════════════════════════════════════════════════════════════ */
/* 表名都带 tj_ 前缀：D1 库可能和别的 Worker 共用，里面已经有 kv / log / req 这种常见名字的表
   （用户实测：库里原来就有一张没有 exp 列的 kv，CREATE TABLE IF NOT EXISTS 跳过了它，查询报 no such column: exp）。
   建表之后再对一遍列：缺的列补上（以后加列也走这里），不碰别人的表。 */
const SCHEMA = [
  `CREATE TABLE IF NOT EXISTS tj_req (
     id INTEGER PRIMARY KEY AUTOINCREMENT, src TEXT NOT NULL, tmdb INTEGER NOT NULL, season INTEGER NOT NULL DEFAULT 0,
     title TEXT, year TEXT, poster TEXT, users TEXT NOT NULL DEFAULT '[]', stage TEXT NOT NULL, pct REAL NOT NULL DEFAULT 0,
     note TEXT, data TEXT NOT NULL DEFAULT '{}', created INTEGER, updated INTEGER, since INTEGER,
     next INTEGER NOT NULL DEFAULT 0, rev INTEGER NOT NULL DEFAULT 0)`,
  `CREATE TABLE IF NOT EXISTS tj_kv (k TEXT PRIMARY KEY, v TEXT, exp INTEGER NOT NULL DEFAULT 0)`,
  `CREATE TABLE IF NOT EXISTS tj_log (id INTEGER PRIMARY KEY AUTOINCREMENT, rid INTEGER, at INTEGER, msg TEXT)`,
];
/** 每张表应该有的列（补列用：ALTER TABLE ADD COLUMN 加不了主键，主键列只能建表时有） */
const COLUMNS = {
  tj_req: [['src', "TEXT NOT NULL DEFAULT ''"], ['tmdb', 'INTEGER NOT NULL DEFAULT 0'], ['season', 'INTEGER NOT NULL DEFAULT 0'],
           ['title', 'TEXT'], ['year', 'TEXT'], ['poster', 'TEXT'], ['users', "TEXT NOT NULL DEFAULT '[]'"],
           ['stage', "TEXT NOT NULL DEFAULT 'queued'"], ['pct', 'REAL NOT NULL DEFAULT 0'], ['note', 'TEXT'],
           ['data', "TEXT NOT NULL DEFAULT '{}'"], ['created', 'INTEGER'], ['updated', 'INTEGER'], ['since', 'INTEGER'],
           ['next', 'INTEGER NOT NULL DEFAULT 0'], ['rev', 'INTEGER NOT NULL DEFAULT 0']],
  tj_kv: [['v', 'TEXT'], ['exp', 'INTEGER NOT NULL DEFAULT 0']],
  tj_log: [['rid', 'INTEGER'], ['at', 'INTEGER'], ['msg', 'TEXT']],
};
const INDEXES = [
  `CREATE UNIQUE INDEX IF NOT EXISTS tj_req_live ON tj_req(src, tmdb, season) WHERE stage NOT IN ('done','failed','cancelled')`,
  `CREATE INDEX IF NOT EXISTS tj_req_next ON tj_req(next)`,
  `CREATE INDEX IF NOT EXISTS tj_req_tmdb ON tj_req(tmdb)`,
];
let SCHEMA_OK = false;
async function db(env){
  if (!env.DB) throw err('没绑 D1：Worker 设置 → 绑定 → D1 数据库，变量名 DB', { conf: 1 });
  if (SCHEMA_OK) return env.DB;
  await env.DB.batch(SCHEMA.map(s => env.DB.prepare(s)));
  const add = [];
  for (const [table, cols] of Object.entries(COLUMNS)){
    const have = new Set(((await env.DB.prepare('PRAGMA table_info(' + table + ')').all()).results || []).map(c => c.name));
    for (const [name, type] of cols) if (!have.has(name)) add.push('ALTER TABLE ' + table + ' ADD COLUMN ' + name + ' ' + type);
  }
  if (add.length) await env.DB.batch(add.map(s => env.DB.prepare(s)));
  await env.DB.batch(INDEXES.map(s => env.DB.prepare(s)));
  SCHEMA_OK = true;
  return env.DB;
}
async function kvGet(env, k){
  const r = await (await db(env)).prepare('SELECT v, exp FROM tj_kv WHERE k = ?').bind(k).first();
  if (!r || (r.exp && r.exp < now())) return null;
  try { return JSON.parse(r.v); } catch { return null; }
}
async function kvPut(env, k, v, ttl){
  await (await db(env)).prepare('INSERT INTO tj_kv (k, v, exp) VALUES (?, ?, ?) ON CONFLICT(k) DO UPDATE SET v = excluded.v, exp = excluded.exp')
    .bind(k, JSON.stringify(v), ttl ? now() + ttl : 0).run();
}
async function kvDel(env, k){ await (await db(env)).prepare('DELETE FROM tj_kv WHERE k = ?').bind(k).run(); }
/** 一轮只跑一个：定时任务和面板上的「立即跑一轮」撞上时后来的直接走 */
async function lease(env, k, ms){
  const t = now();
  const r = await (await db(env)).prepare(
    'INSERT INTO tj_kv (k, v, exp) VALUES (?, ?, ?) ON CONFLICT(k) DO UPDATE SET v = excluded.v, exp = excluded.exp WHERE tj_kv.exp < ?')
    .bind(k, '1', t + ms, t).run();
  return !!(r.meta && r.meta.changes);
}
async function logMsg(env, rid, msg){
  try { await (await db(env)).prepare('INSERT INTO tj_log (rid, at, msg) VALUES (?, ?, ?)').bind(rid || 0, now(), String(msg).slice(0, 500)).run(); } catch {}
}

function rowOf(x){
  if (!x) return null;
  let d = {}, users = [];
  try { d = JSON.parse(x.data || '{}') || {}; } catch {}
  try { users = JSON.parse(x.users || '[]') || []; } catch {}
  return { ...x, d, users };
}
async function getReq(env, id){
  return rowOf(await (await db(env)).prepare('SELECT * FROM tj_req WHERE id = ?').bind(id).first());
}
/** 存一条：rev 对得上才写（面板上刚取消 / 重试过的，这一轮推进的结果作废） */
async function saveReq(env, r){
  const t = now();
  const res = await (await db(env)).prepare(
    `UPDATE tj_req SET title = ?, year = ?, poster = ?, users = ?, stage = ?, pct = ?, note = ?, data = ?, updated = ?, since = ?,
       next = ?, rev = rev + 1 WHERE id = ? AND rev = ?`)
    .bind(r.title || '', r.year || '', r.poster || '', JSON.stringify(r.users || []), r.stage, +r.pct || 0, r.note || '',
          JSON.stringify(r.d || {}), t, r.since || t, r.next || 0, r.id, r.rev).run();
  const ok = !!(res.meta && res.meta.changes);
  if (ok){ r.rev++; r.updated = t; }
  return ok;
}

/* ══════════════════════════════════════════════════════════════════
   设置（PikPak 密码加密存放）
   ══════════════════════════════════════════════════════════════════ */
const CFG_DEF = { pkUser: '', pkPass: '', tpl: 'rel', lang: 'en', grp: 'Cuven®', userCap: LIMIT.userActive,
                  globalCap: LIMIT.globalActive, paused: false,
                  pkSlots: 4,     // PikPak 同时云下载几个
                  vpsSlots: 2 };  // VPS 同时传输几个（rclone 一次跑太多会把内存吃满、整个进程被杀）
const b64 = (u8) => { let s = ''; for (const c of u8) s += String.fromCharCode(c); return btoa(s); };
const unb64 = (s) => Uint8Array.from(atob(s), c => c.charCodeAt(0));
async function secretKey(env){
  if (!env.ADMIN_KEY) throw err('还没配 ADMIN_KEY', { conf: 1 });
  const h = await crypto.subtle.digest('SHA-256', new TextEncoder().encode('cuven-tj:' + env.ADMIN_KEY));
  return crypto.subtle.importKey('raw', h, 'AES-GCM', false, ['encrypt', 'decrypt']);
}
async function seal(env, text){
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ct = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv }, await secretKey(env), new TextEncoder().encode(text)));
  const out = new Uint8Array(12 + ct.length); out.set(iv); out.set(ct, 12);
  return b64(out);
}
async function unseal(env, s){
  if (!s) return '';
  try {
    const u = unb64(s);
    const pt = await crypto.subtle.decrypt({ name: 'AES-GCM', iv: u.slice(0, 12) }, await secretKey(env), u.slice(12));
    return new TextDecoder().decode(pt);
  } catch { return ''; }
}
async function loadCfg(env){
  const raw = (await kvGet(env, 'cfg')) || {};
  const cfg = { ...CFG_DEF, ...raw };
  cfg.pkPass = raw.pkPassEnc ? await unseal(env, raw.pkPassEnc) : '';
  delete cfg.pkPassEnc;
  return cfg;
}
async function saveCfg(env, patch){
  const raw = (await kvGet(env, 'cfg')) || {};
  const next = { ...raw };
  if (typeof patch.pkUser === 'string') next.pkUser = patch.pkUser.trim().slice(0, 120);
  if (typeof patch.pkPass === 'string' && patch.pkPass) next.pkPassEnc = await seal(env, patch.pkPass.slice(0, 200));
  if (patch.pkClear){ next.pkUser = ''; delete next.pkPassEnc; }
  if (['rel', 'std', 'season', 'nest', 'dot'].includes(patch.tpl)) next.tpl = patch.tpl;
  if (['en', 'cn', 'cnen'].includes(patch.lang)) next.lang = patch.lang;
  if (typeof patch.grp === 'string') next.grp = patch.grp.slice(0, 40);
  if (patch.userCap != null) next.userCap = clamp(parseInt(patch.userCap, 10) || LIMIT.userActive, 1, 50);
  if (patch.globalCap != null) next.globalCap = clamp(parseInt(patch.globalCap, 10) || LIMIT.globalActive, 1, 500);
  if (patch.paused != null) next.paused = !!patch.paused;
  if (patch.pkSlots != null) next.pkSlots = clamp(parseInt(patch.pkSlots, 10) || CFG_DEF.pkSlots, 1, 20);
  if (patch.vpsSlots != null) next.vpsSlots = clamp(parseInt(patch.vpsSlots, 10) || CFG_DEF.vpsSlots, 1, 8);
  if (next.pkUser !== raw.pkUser || next.pkPassEnc !== raw.pkPassEnc){ await kvDel(env, 'pk:tok'); PK_MEM = null; PK_FAIL = null; }
  await kvPut(env, 'cfg', next);
  return loadCfg(env);
}
const mask = (u) => { u = String(u || ''); const i = u.indexOf('@'); return !u ? '' : i > 0 ? u.slice(0, Math.min(2, i)) + '***' + u.slice(i) : u.slice(0, 3) + '***' + u.slice(-2); };

/* ══════════════════════════════════════════════════════════════════
   一轮的上下文：子请求预算 + 时间预算 + 这一轮里共用的缓存 + 依赖健康 + 写入缓冲
   ══════════════════════════════════════════════════════════════════ */
function context(env, cfg, budget){
  return { env, cfg, n: 0, max: budget || LIMIT.fetches, t0: now(), memo: {}, health: null, logs: null, pending: null, slots: null };
}
async function xfetch(c, url, init = {}, ms = 25000){
  if (c.n >= c.max) throw err('这一轮的子请求用完了，下一轮接着做', { budget: 1 });
  c.n++;
  const ac = new AbortController();
  const timer = setTimeout(() => ac.abort(), ms);
  try { return await fetch(url, { ...init, signal: ac.signal }); }
  catch (e){ throw err((e && e.name === 'AbortError' ? '超时：' : '连不上：') + new URL(url).host, { net: 1 }); }
  finally { clearTimeout(timer); }
}
async function readJSON(r){
  const txt = await r.text().catch(() => '');
  try { return txt ? JSON.parse(txt) : {}; } catch { return { error: txt.slice(0, 160) || ('HTTP ' + r.status) }; }
}

/* ══════════════════════════════════════════════════════════════════
   依赖的健康：熔断
   四个外部依赖：影片库（lb）、传输 / VPS（vps）、PikPak（pikpak）、TMDB 分季（stream）。
   同一个依赖连续 3 次「暂时性」失败（连不上、超时、5xx、429、影片库忙）就熔断 2 分钟：这一轮和后面几轮都不再碰它，
   要用它的请求原地等——不算出错次数、不换规格、不会因为对方抖一下就把一部片判死。
   到期放一次试探（半开）：通了就恢复；又失败就再熔断，时间翻倍（2 → 4 → 8 → 15 分钟封顶）。
   逻辑错误（4xx：参数不对、文件夹不在、作业没了）不算依赖坏了。状态存在 tj_kv 的 health 里，控制面板看得到。
   ══════════════════════════════════════════════════════════════════ */
const DEPS = { lb: '影片库', vps: '传输（VPS）', pikpak: 'PikPak', stream: 'TMDB' };
/** 每一步要用哪些依赖：熔断中的不去碰 */
const STAGE_DEPS = { queued: ['lb'], download: ['pikpak'], clean: ['pikpak'], check: ['vps'], rename: ['vps'],
                     copy: ['vps'], verify: ['vps'], purge: ['vps'], release: ['vps'] };
const transientErr = (e) => !!(e && !e.budget && !e.circuit && (e.net || e.status >= 500 || e.status === 429 || e.status === 409));
async function loadHealth(env){
  const h = (await kvGet(env, 'health')) || {};
  for (const k of Object.keys(DEPS)) h[k] = { fails: 0, trips: 0, open: 0, err: '', ok: 0, bad: 0, ...(h[k] || {}) };
  return h;
}
function depOpenUntil(c, dep){
  const h = c.health && c.health[dep];
  return h && h.open > now() ? h.open : 0;
}
function depResult(c, dep, e){
  if (!c.health) return;
  const h = c.health[dep], t = now();
  if (!e){
    if (h.fails || h.trips || h.open){ h.fails = 0; h.trips = 0; h.open = 0; c.healthDirty = true; }
    if (t - h.ok > MIN){ h.ok = t; c.healthDirty = true; }
    return;
  }
  if (!transientErr(e)) return;
  const halfOpen = h.open && h.open <= t;
  h.err = String(e.message || e).slice(0, 160); h.bad = t; h.fails++; c.healthDirty = true;
  if (halfOpen || h.fails >= 3){ h.trips = Math.min(h.trips + 1, 4); h.open = t + Math.min(15, 2 ** h.trips) * MIN; h.fails = 0; }
}
async function depCall(c, dep, fn){
  const until = depOpenUntil(c, dep);
  if (until) throw err(DEPS[dep] + '暂时不可用，约 ' + Math.max(1, Math.ceil((until - now()) / MIN)) + ' 分钟后再试', { circuit: dep, until });
  try { const v = await fn(); depResult(c, dep, null); return v; }
  catch (e){ depResult(c, dep, e); throw e; }
}

/* ── 影片库（lb.cuven.us）── */
async function lb(c, path, init){
  if (!c.env.LB_GATE) throw err('还没配 LB_GATE（影片库的 GATE 口令）', { conf: 1 });
  return depCall(c, 'lb', async () => {
    const r = await xfetch(c, base(c.env, 'LB_BASE', 'https://lb.cuven.us') + path, {
      ...(init || {}), headers: { 'x-gate': c.env.LB_GATE, 'content-type': 'application/json', ...((init || {}).headers || {}) } }, 40000);
    const j = await readJSON(r);
    if (!r.ok) throw err('影片库：' + (j.error || 'HTTP ' + r.status), { status: r.status, net: r.status >= 500 || r.status === 409 ? 1 : 0, lb: 1 });
    return j;
  });
}
const lbVersions = (c, src, id, season) =>
  lb(c, '/api/link/versions?src=' + src + '&id=' + id + (season ? '&season=' + season : ''));

/* ── 传输（transfer.cuven.us，VPS 上的 rclone）──
   传输 Worker 908 起自己会对 52x 重试；到这里还是 5xx，说明 VPS 那头真的有问题，算进熔断。
   422 是 rclone 自己回的逻辑错（作业没了、文件夹不在），不算 VPS 坏了 */
async function tf(c, op, body){
  if (!c.env.LINK_KEY) throw err('还没配 LINK_KEY（传输 Worker 的 LINK_KEY）', { conf: 1 });
  return depCall(c, 'vps', async () => {
    const r = await xfetch(c, base(c.env, 'TRANSFER_BASE', 'https://transfer.cuven.us') + '/api/link/' + op, {
      method: 'POST', headers: { 'x-cuven-link': c.env.LINK_KEY, 'content-type': 'application/json' }, body: JSON.stringify(body || {}) }, 60000);
    const j = await readJSON(r);
    if (!r.ok) throw err('传输：' + (j.error || 'HTTP ' + r.status), { status: r.status, net: r.status >= 500 ? 1 : 0, tf: 1 });
    return j;
  });
}

/* ── TMDB：一季已经播出的集数（标题里没写总集数时用来核对整季；问不到就当不知道）── */
async function airedCount(c, id, season){
  try {
    return await depCall(c, 'stream', async () => {
      const r = await xfetch(c, base(c.env, 'STREAM_BASE', 'https://stream.cuven.online') + '/api/tmdb/season?id=' + id + '&season=' + season, {}, 20000);
      if (r.status >= 500) throw err('TMDB：HTTP ' + r.status, { status: r.status, net: 1 });
      if (!r.ok) return 0;
      const j = await readJSON(r);
      const today = new Date().toISOString().slice(0, 10);
      const eps = (j.episodes || []).filter(e => e && e.ep > 0);
      return { total: eps.length, aired: eps.filter(e => e.air_date && e.air_date <= today).length };
    });
  } catch (e){ if (e.budget) throw e; return 0; }
}

/* ══════════════════════════════════════════════════════════════════
   PikPak（清洗用；协议同影片库 Worker 的那一份，设备号另起一个，两边各是各的会话）
   ══════════════════════════════════════════════════════════════════ */
const PK = {
  cid: 'YNxT9w7GMdWvEOKa', secret: 'dbw2OtmVEeuUvIptb1Coyg', ver: '1.47.1', pkg: 'com.pikcloud.pikpak',
  salts: ['Gez0T9ijiI9WCeTsKSg3SMlx', 'zQdbalsolyb1R/', 'ftOjr52zt51JD68C3s', 'yeOBMH0JkbQdEFNNwQ0RI9T3wU/v', 'BRJrQZiTQ65WtMvwO',
          'je8fqxKPdQVJiy1DM6Bc9Nb1', 'niV', '9hFCW2R1', 'sHKHpe2i96', 'p7c5E6AcXQ/IJUuAEC9W6', '', 'aRv9hjc9P+Pbn+u3krN6',
          'BzStcgE8qVdqjEH16l4', 'SqgeZvL5j9zoHP95xWHt', 'zVof5yaJkPe3VFpadPof'],
  ua: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
  signin: 'https://user.mypikpak.com/v1/auth/signin',
  user: 'https://user.mypikpak.com', api: 'https://api-drive.mypikpak.com',
};
const MD5_S = [7, 12, 17, 22, 5, 9, 14, 20, 4, 11, 16, 23, 6, 10, 15, 21];
const MD5_K = Array.from({ length: 64 }, (_, i) => Math.floor(Math.abs(Math.sin(i + 1)) * 4294967296) >>> 0);
function md5(str){
  const b = new TextEncoder().encode(String(str)), n = b.length;
  const w = new Uint32Array((((n + 8) >> 6) + 1) * 16);
  for (let i = 0; i < n; i++) w[i >> 2] |= b[i] << ((i & 3) * 8);
  w[n >> 2] |= 0x80 << ((n & 3) * 8);
  w[w.length - 2] = (n * 8) >>> 0;
  w[w.length - 1] = Math.floor(n / 0x20000000);
  let a = 0x67452301, bb = 0xefcdab89, c = 0x98badcfe, d = 0x10325476;
  for (let i = 0; i < w.length; i += 16){
    let A = a, B = bb, C = c, D = d;
    for (let j = 0; j < 64; j++){
      let f, g;
      if (j < 16){ f = (B & C) | (~B & D); g = j; }
      else if (j < 32){ f = (D & B) | (~D & C); g = (5 * j + 1) & 15; }
      else if (j < 48){ f = B ^ C ^ D; g = (3 * j + 5) & 15; }
      else { f = C ^ (B | ~D); g = (7 * j) & 15; }
      const x = (A + f + MD5_K[j] + w[i + g]) | 0, s = MD5_S[(j >> 4) * 4 + (j & 3)];
      A = D; D = C; C = B;
      B = (B + ((x << s) | (x >>> (32 - s)))) | 0;
    }
    a = (a + A) | 0; bb = (bb + B) | 0; c = (c + C) | 0; d = (d + D) | 0;
  }
  let out = '';
  for (const v of [a, bb, c, d]) for (let k = 0; k < 4; k++) out += ((v >>> (k * 8)) & 255).toString(16).padStart(2, '0');
  return out;
}
const pkDevice = (cfg) => md5('cuven-tj:' + cfg.pkUser + ':' + cfg.pkPass);
function pkSign(dev, ts){
  let s = PK.cid + PK.ver + PK.pkg + dev + ts;
  for (const salt of PK.salts) s = md5(s + salt);
  return '1.' + s;
}
const PK_MSG = [
  [/invalid_account_or_password|account_not_found|password_error/i, 'PikPak 账号或密码不对（在控制面板重新填）'],
  [/captcha_invalid|captcha_required/i, 'PikPak 的人机验证没通过'],
  [/file_space_not_enough|space_not_enough|quota_exceed/i, 'PikPak 空间不够了'],
  [/too_many_requests|frequen/i, 'PikPak 说请求太频繁'],
  [/file_not_found|not_found/i, 'PikPak 上找不到这个文件 / 任务'],
  [/permission_denied|forbidden/i, 'PikPak 拒绝了这个操作'],
];
function pkError(j, status){
  const raw = String((j && (j.error_description || j.error)) || ('HTTP ' + status));
  const key = String((j && j.error) || '') + ' ' + raw;
  const hit = PK_MSG.find(([re]) => re.test(key));
  return err(hit ? hit[1] + '：' + raw.slice(0, 80) : 'PikPak：' + raw.slice(0, 140),
    { pk: 1, code: Number(j && j.error_code) || 0, perr: String((j && j.error) || ''), status, notFound: /not_found/i.test(key) });
}
async function pkJSON(c, method, url, body, headers){
  return depCall(c, 'pikpak', async () => {
    const r = await xfetch(c, url, { method, body: body == null ? undefined : JSON.stringify(body),
      headers: { 'content-type': 'application/json; charset=utf-8', accept: 'application/json', 'user-agent': PK.ua, ...(headers || {}) } });
    const txt = await r.text().catch(() => '');
    let j = null;
    try { j = txt ? JSON.parse(txt) : {}; } catch {}
    if (j && !j.error && r.status < 400) return j;
    if (!j) throw err('PikPak 回的不是 JSON（HTTP ' + r.status + '）', { pk: 1, status: r.status, net: r.status >= 500 ? 1 : 0 });
    const e = pkError(j, r.status);
    if (r.status >= 500 || r.status === 429 || /too_many_requests|frequen/i.test(e.perr || '')) e.net = 1;   // PikPak 那头忙：算暂时性的
    throw e;
  });
}
async function pkCaptcha(c, action, meta){
  const dev = pkDevice(c.cfg);
  const j = await pkJSON(c, 'POST', PK.user + '/v1/shield/captcha/init', { client_id: PK.cid, action, device_id: dev, meta }, { 'x-device-id': dev });
  if (!j.captcha_token)
    throw err(j.url ? 'PikPak 要求人机验证（滑块），Worker 过不了：先用同一个账号在 PikPak 的 App 或网页上登录一次，过几分钟再试'
                    : 'PikPak 没给验证令牌', { pk: 1, captcha: 1 });
  return j.captcha_token;
}
const pkSignMeta = (c, sub) => { const t = String(now()); return { captcha_sign: pkSign(pkDevice(c.cfg), t), client_version: PK.ver, package_name: PK.pkg, user_id: sub || '', timestamp: t }; };
async function pkSignin(c){
  const u = String(c.cfg.pkUser).trim(), meta = {};
  if (/^[\w.+-]+@[\w-]+(\.[\w-]+)+$/.test(u)) meta.email = u;
  else if (/^\+?\d{11,18}$/.test(u)) meta.phone_number = u;
  else meta.username = u;
  const ct = await pkCaptcha(c, 'POST:' + PK.signin, meta);
  return pkJSON(c, 'POST', PK.user + '/v1/auth/signin',
    { client_id: PK.cid, client_secret: PK.secret, password: String(c.cfg.pkPass), username: u, captcha_token: ct }, { 'x-device-id': pkDevice(c.cfg) });
}
let PK_MEM = null, PK_FAIL = null;
async function pkAuth(c, force){
  if (!c.cfg.pkUser || !c.cfg.pkPass) throw err('还没在控制面板填 PikPak 账号和密码', { pk: 1, conf: 1 });
  const tag = md5('u:' + c.cfg.pkUser + ':' + c.cfg.pkPass).slice(0, 10);
  const fresh = (st) => st && st.u === tag && st.access && st.exp - 120000 > now();
  if (!force && fresh(PK_MEM)) return PK_MEM;
  let st = await kvGet(c.env, 'pk:tok');
  if (st && st.u !== tag) st = null;
  if (fresh(st) && (!force || !PK_MEM || st.access !== PK_MEM.access)) return (PK_MEM = st);
  if (PK_FAIL && PK_FAIL.tag === tag && now() < PK_FAIL.until) throw err(PK_FAIL.msg, { pk: 1, auth: 1, cool: 1 });
  let j = null;
  if (st && st.refresh){
    try { j = await pkJSON(c, 'POST', PK.user + '/v1/auth/token',
      { client_id: PK.cid, client_secret: PK.secret, grant_type: 'refresh_token', refresh_token: st.refresh }, { 'x-device-id': pkDevice(c.cfg) }); }
    catch (e){ if (e.budget || e.net) throw e; j = null; }
  }
  if (!j || !j.access_token){
    try { j = await pkSignin(c); }
    catch (e){
      if (!e.budget && !e.net){
        const bad = /invalid_account_or_password|account_not_found|password_error/i.test(e.perr || '');
        PK_FAIL = { tag, msg: e.message, until: now() + (bad ? 10 * MIN : MIN) };
      }
      e.auth = 1; throw e;
    }
  }
  if (!j.access_token) throw err('PikPak 登录没拿到令牌', { pk: 1, auth: 1 });
  PK_FAIL = null;
  st = { u: tag, access: j.access_token, refresh: j.refresh_token || (st && st.refresh) || '', sub: j.sub || (st && st.sub) || '',
         exp: now() + (Number(j.expires_in) || 7200) * 1000 };
  PK_MEM = st;
  await kvPut(c.env, 'pk:tok', st, 30 * DAY);
  return st;
}
async function pkCall(c, method, path, opt = {}){
  let st = await pkAuth(c), ct = '';
  let qs = '';
  if (opt.q){
    const sp = new URLSearchParams();
    for (const [k, v] of Object.entries(opt.q)){
      if (v == null || v === '') continue;
      if (Array.isArray(v)) v.forEach(x => sp.append(k, String(x))); else sp.append(k, String(v));
    }
    qs = '?' + sp.toString();
  }
  for (let i = 0; ; i++){
    const h = { authorization: 'Bearer ' + st.access, 'x-device-id': pkDevice(c.cfg) };
    if (ct) h['x-captcha-token'] = ct;
    try { return await pkJSON(c, method, PK.api + path + qs, opt.body, h); }
    catch (e){
      if (i >= 2 || e.budget || e.net) throw e;
      if (e.code === 16 || e.code === 4121 || e.code === 4122 || e.status === 401 || /unauthenticated|invalid_token/i.test(e.perr || '')){ st = await pkAuth(c, true); continue; }
      if (e.code === 9 || /captcha/i.test(e.perr || '')){ ct = await pkCaptcha(c, method + ':' + path, pkSignMeta(c, st.sub)); continue; }
      throw e;
    }
  }
}
/** 进行中 / 排队 / 出错的云下载任务（一轮只问一次，几条请求共用）。完成了的任务不在这里，去看文件 */
async function pkTasks(c){
  if (c.memo.tasks) return c.memo.tasks;
  const map = new Map();
  let token = '';
  for (let pg = 0; pg < 3; pg++){
    const j = await pkCall(c, 'GET', '/drive/v1/tasks', { q: { type: 'offline', thumbnail_size: 'SIZE_SMALL', limit: 200, page_token: token,
      filters: JSON.stringify({ phase: { in: 'PHASE_TYPE_RUNNING,PHASE_TYPE_PENDING,PHASE_TYPE_ERROR' } }) } });
    for (const t of (j.tasks || [])) if (t && t.id) map.set(String(t.id), t);
    token = j.next_page_token || '';
    if (!token) break;
  }
  return (c.memo.tasks = map);
}
async function pkFile(c, id){
  try { return await pkCall(c, 'GET', '/drive/v1/files/' + encodeURIComponent(id), { q: { thumbnail_size: 'SIZE_SMALL' } }); }
  catch (e){ if (e.notFound || e.status === 404) return null; throw e; }
}
/** 一个文件夹下面的东西（文件 + 文件夹，不进回收站里的） */
async function pkChildren(c, parent){
  const out = [];
  let token = '';
  for (let pg = 0; pg < 5; pg++){
    const j = await pkCall(c, 'GET', '/drive/v1/files', { q: { parent_id: parent || '', thumbnail_size: 'SIZE_SMALL', limit: 200,
      with_audit: 'false', page_token: token, filters: JSON.stringify({ trashed: { eq: false } }) } });
    for (const f of (j.files || [])) if (f && f.id) out.push(f);
    token = j.next_page_token || '';
    if (!token) break;
  }
  return out;
}
/** 往下翻几层，把文件都找出来 */
async function pkWalk(c, root, depth = 3){
  const files = [];
  let level = [root];
  for (let d = 0; d < depth && level.length; d++){
    const next = [];
    for (const id of level.slice(0, 12)){
      for (const f of await pkChildren(c, id)){
        if (f.kind === 'drive#folder') next.push(f.id);
        else files.push({ id: String(f.id), name: String(f.name || ''), size: Number(f.size) || 0, parent: String(f.parent_id || id) });
      }
    }
    level = next;
  }
  return files;
}
const pkMove = (c, ids, parent) => pkCall(c, 'POST', '/drive/v1/files:batchMove', { body: { ids, to: { parent_id: parent } } });
const pkTrash = (c, ids) => pkCall(c, 'POST', '/drive/v1/files:batchTrash', { body: { ids } });
const pkDelTasks = (c, ids, files) => pkCall(c, 'DELETE', '/drive/v1/tasks', { q: { task_ids: ids, delete_files: files ? 'true' : 'false' } });

/** /auto 的文件夹编号：问影片库（它往哪个网盘推，就以它看到的为准），没有就让它建一个 */
async function autoFolder(c, refresh){
  const name = String(c.env.AUTO_DIR || 'auto');
  if (!refresh && c.memo.auto) return c.memo.auto;
  if (!refresh){ const v = await kvGet(c.env, 'auto:id'); if (v && v.id && v.name === name) return (c.memo.auto = v.id); }
  const ls = await lb(c, '/api/pikpak?do=ls&parent=');
  let f = (ls.folders || []).find(x => x.name === name);
  if (!f) f = await lb(c, '/api/pikpak?do=mkdir', { method: 'POST', body: JSON.stringify({ parent: '', name }) });
  if (!f || !f.id) throw err('影片库没给出 /' + name + ' 的文件夹编号');
  await kvPut(c.env, 'auto:id', { id: String(f.id), name }, 7 * DAY);
  return (c.memo.auto = String(f.id));
}

/* ══════════════════════════════════════════════════════════════════
   状态机：每条请求一次往前走一步
   · 只许按 FLOW 走（其余跳转是程序错误，停下来等人，不会悄悄跳过一步）
   · 每一步都可以重入：中途被掐（预算、超时、VPS 重启）下一轮从同一步接着做，不重复推送 / 不重复开传输
   ══════════════════════════════════════════════════════════════════ */
const FLOW = {
  queued: ['queued', 'download'], download: ['clean', 'check', 'queued'], clean: ['copy', 'queued'], check: ['rename', 'queued'],
  rename: ['copy'], copy: ['verify'], verify: ['purge', 'copy'], purge: ['release'], release: [],
};
function go(r, stage, note){
  if (FLOW[r.stage] && !FLOW[r.stage].includes(stage)) throw err('状态不能从 ' + r.stage + ' 跳到 ' + stage, { bug: 1 });
  r.stage = stage; r.since = now(); r.pct = 0; r.next = now();
  r.note = note || STAGE_TEXT[stage] || '';
  r.d.errs = 0; delete r.d.errSince;
}
function fail(r, why){
  r.d.lastStage = r.stage;
  r.stage = 'failed'; r.since = now(); r.next = 0; r.note = why;
}
/** 这一轮里写日志：先攒着，和请求的更新一起一次写进 D1（不在一轮里的直接写） */
function clog(c, rid, msg){
  if (c.logs){ c.logs.push([rid || 0, now(), String(msg).slice(0, 500)]); return; }
  return logMsg(c.env, rid, msg);
}
/** 当前规格不行了：删掉 PikPak 上的任务和文件，记下试过，回到 ① 推下一个 */
async function drop(c, r, why){
  await clog(c, r.id, '放弃 ' + ((r.d.cur && r.d.cur.t) || '这个规格') + '：' + why);
  if (r.d.task) await pkDelTasks(c, [r.d.task], true).catch(() => {});
  if (r.d.file) await pkTrash(c, [r.d.file]).catch(() => {});
  if (r.d.cur && r.d.cur.tid != null) r.d.tried = [...new Set([...(r.d.tried || []), r.d.cur.tid])];
  for (const k of ['cur', 'task', 'file', 'fname', 'fkind', 'item', 'kind', 'job', 'newname', 'pmax', 'pat', 'org', 'check',
                   'busySince', 'ctries', 'rtries', 'lost', 'cb', 'cbAt', 'rb', 'rbAt', 'wait'])
    delete r.d[k];
  go(r, 'queued', why + '，换下一个规格');
}
/** 资源位：PikPak 同时云下载几个、VPS 同时传几个（面板里可调）。满了就排队等，不算出错 */
function slotFree(c, kind){
  const s = c.slots && c.slots[kind];
  return !s || s.used < s.max;
}
/** 作业进度：这一轮批量问过（/api/link/jobs）就用那一份，没有再单独问 */
async function jobStatus(c, id){
  const m = c.memo.jobs && c.memo.jobs[id];
  if (m && !m.error) return m;
  try { return await tf(c, 'job', { jobid: id }); }
  catch (e){ if (transientErr(e) || e.budget || e.circuit) throw e; return { finished: true, success: false, error: e.message }; }
}
async function stopJob(c, id){ await tf(c, 'stop', { jobid: id }).catch(e => { if (e.budget) throw e; }); }

async function stQueued(c, r){
  const t = now();
  if (!r.d.vers || !r.d.versAt || t - r.d.versAt > 6 * HOUR){
    let v;
    try { v = await lbVersions(c, r.src, r.tmdb, r.src === 'tv' ? r.season : 0); }
    catch (e){ if (e.status === 404) return fail(r, '影片库的索引里没有这部片了'); throw e; }
    r.d.vers = (v.items || []).map(x => ({ tid: x.tid, t: String(x.title || '').slice(0, 200), mb: x.mb || 0, size: x.size || '',
      res: x.res || '', labels: (x.labels || []).slice(0, 6), total: x.total || 0 }));
    r.d.versAt = t;
    if (v.title) r.title = v.title;
    if (v.year) r.year = String(v.year);
    if (v.poster) r.poster = v.poster;
  }
  const tried = new Set(r.d.tried || []);
  const v = r.d.vers.find(x => !tried.has(x.tid));
  if (!v) return fail(r, r.d.vers.length ? '所有规格都试过了，没有一个能完整下完' : (r.src === 'tv' ? '影片库里还没有这一季的整季资源' : '影片库里还没有这部片的资源'));
  if (!slotFree(c, 'pk')){
    r.d.wait = 'pk';
    r.note = '排队：PikPak 同时云下载已满（' + c.slots.pk.used + ' / ' + c.slots.pk.max + '），轮到就推送';
    r.next = t + 2 * MIN;
    return;
  }
  delete r.d.wait;
  const parent = await autoFolder(c);
  let j;
  try { j = await lb(c, '/api/pikpush?src=' + r.src, { method: 'POST', body: JSON.stringify({ parent, items: [{ tid: v.tid, name: r.title || '' }] }) }); }
  catch (e){
    if (/文件夹不在了/.test(e.message)) await kvDel(c.env, 'auto:id');
    throw e;
  }
  const it = (j.items || [])[0] || {};
  if (it.ok){
    r.d.cur = v; r.d.task = it.task || ''; r.d.file = it.file || ''; r.d.fname = it.fileName || it.name || '';
    await clog(c, r.id, '已推送到 PikPak：' + v.t);
    return go(r, 'download', '已推送到 PikPak，等云下载开始');
  }
  if (j.stop || it.retry){
    r.note = (j.stop || it.err || '影片库这会儿推不了') + '，稍后再试';
    r.next = t + (j.stop ? 15 : 3) * MIN;
    return;
  }
  r.d.tried = [...tried, v.tid];
  await clog(c, r.id, '推不了 ' + v.t + '：' + (it.err || '未知原因'));
  r.note = '这个规格推不了，换下一个';
  r.next = t;
}

async function stDownload(c, r){
  const t = now();
  const tasks = await pkTasks(c);
  const task = r.d.task ? tasks.get(String(r.d.task)) : null;
  if (task){
    if (task.phase === 'PHASE_TYPE_ERROR') return drop(c, r, 'PikPak 云下载失败' + (task.message ? '（' + String(task.message).slice(0, 60) + '）' : ''));
    if (task.file_id && !r.d.file) r.d.file = String(task.file_id);
    if (task.file_name) r.d.fname = String(task.file_name);
    const p = clamp((Number(task.progress) || 0) / 100, 0, 1);
    if (r.d.pmax == null || p > r.d.pmax + 0.001){ r.d.pmax = p; r.d.pat = t; }
    r.pct = p;
    if (t - (r.d.pat || r.since) > LIMIT.dlStall) return drop(c, r, '云下载 2 小时没有进度');
    if (t - r.since > LIMIT.dlMax) return drop(c, r, '云下载 12 小时还没完成');
    r.note = 'PikPak 云下载 ' + Math.round(p * 100) + '%';
    /* 快下完的看勤一点，刚开始的慢慢看（省子请求） */
    r.next = t + (p > 0.9 ? 1 : p > 0.5 ? 2 : 3) * MIN;
    return;
  }
  /* 不在进行中的任务里：要么下完了，要么没了 —— 看文件 */
  if (!r.d.file){
    /* 推送时 PikPak 没回文件编号：按名字在 /auto 里找 */
    const parent = await autoFolder(c);
    const hit = (await pkChildren(c, parent)).find(f => f.name === r.d.fname);
    if (!hit){
      if (t - r.since > 30 * MIN) return drop(c, r, '找不到云下载的任务和文件');
      r.next = t + 2 * MIN; return;
    }
    r.d.file = String(hit.id);
  }
  const f = await pkFile(c, r.d.file);
  if (!f && t - r.since < 10 * MIN){ r.next = t + MIN; return; }     // 刚推送，文件还没建出来
  if (!f || f.trashed) return drop(c, r, '云下载的文件不见了');
  if (f.phase && f.phase !== 'PHASE_TYPE_COMPLETE'){
    if (f.phase === 'PHASE_TYPE_ERROR') return drop(c, r, 'PikPak 云下载失败');
    if (t - r.since > LIMIT.dlMax) return drop(c, r, '云下载 12 小时还没完成');
    r.next = t + MIN; return;
  }
  r.d.fname = String(f.name || r.d.fname || '');
  r.d.fkind = f.kind === 'drive#folder' ? 'dir' : 'file';
  r.d.bytes = Number(f.size) || 0;
  await clog(c, r.id, 'PikPak 云下载完成：' + r.d.fname);
  go(r, r.src === 'tv' ? 'check' : 'clean');
}

/** 电影：最大的视频移到 /auto，原文件夹进回收站 */
async function stClean(c, r){
  const parent = await autoFolder(c);
  const f = await pkFile(c, r.d.file);
  if (!f || f.trashed) return drop(c, r, '云下载的文件不见了');
  if (f.kind !== 'drive#folder'){
    if (!VIDEO_RE.test(f.name || '')) return drop(c, r, '下下来的不是视频文件');
    if (String(f.parent_id || '') !== parent) await pkMove(c, [String(f.id)], parent);
    const moved = (await pkFile(c, String(f.id))) || f;
    r.d.item = String(moved.name || f.name); r.d.kind = 'file'; r.d.bytes = Number(moved.size) || 0;
    await clog(c, r.id, '电影文件：' + r.d.item);
    return go(r, 'copy');
  }
  const files = await pkWalk(c, String(f.id));
  const vids = files.filter(x => VIDEO_RE.test(x.name) && !SAMPLE_RE.test(x.name)).sort((a, b) => b.size - a.size);
  if (!vids.length) return drop(c, r, '文件夹里没有视频');
  const big = vids[0];
  await pkMove(c, [big.id], parent);
  const moved = (await pkFile(c, big.id)) || big;
  await pkTrash(c, [String(f.id)]).catch(e => clog(c, r.id, '原文件夹没删掉：' + e.message));
  r.d.file = big.id;
  r.d.item = String(moved.name || big.name); r.d.kind = 'file'; r.d.bytes = Number(moved.size) || big.size;
  await clog(c, r.id, '清洗完成：' + r.d.item + '（' + files.length + ' 个文件里最大的）');
  go(r, 'copy');
}

/** 剧集：整理（删广告垃圾）→ 核对整季 */
async function stCheck(c, r){
  const t = now();
  if (r.d.fkind !== 'dir') return drop(c, r, '下下来的是单个文件，不是整季');
  const dir = r.d.fname;
  if (!r.d.org){
    const o = await tf(c, 'organize', { dir });
    r.d.org = 1;
    if ((o.deleted || []).length) await clog(c, r.id, '整理：删了 ' + o.deleted.length + ' 个垃圾文件');
  }
  let total = (r.d.cur && r.d.cur.total) || 0;
  if (!total){
    if (r.d.tmdbTotal == null){ const a = await airedCount(c, r.tmdb, r.season || 1); r.d.tmdbTotal = a ? a.aired : 0; r.d.tmdbAll = a ? a.total : 0; }
    total = r.d.tmdbTotal || 0;
  }
  const v = await tf(c, 'check', { dir, total });
  r.d.check = { k: v.k, total: v.total || 0, vids: v.vids || 0, miss: (v.miss || []).slice(0, 30) };
  r.pct = 0.5;
  if (v.k === 'ok' || v.k === 'unsure'){
    await clog(c, r.id, '整季核对：' + (v.k === 'ok' ? '完整' : '文件数够（集号没全认出）') + '，' + v.vids + ' 个视频 / 共 ' + (v.total || total) + ' 集');
    return go(r, 'rename');
  }
  if (v.k === 'busy'){
    r.d.busySince = r.d.busySince || t;
    if (t - r.d.busySince > LIMIT.busyMax) return drop(c, r, '文件夹里一直有没下完的分段文件');
    r.note = '还有没下完的分段文件，稍等'; r.next = t + 2 * MIN; return;
  }
  if (v.k === 'short') return drop(c, r, '不完整：缺第 ' + (v.miss || []).slice(0, 8).join('、') + ((v.miss || []).length > 8 ? ' 等' : '') + ' 集');
  if (v.k === 'nonvid' || v.k === 'bare') return drop(c, r, '文件夹里没有认得出集号的视频');
  /* skip：标题写着还在连载，或者总集数无从得知 */
  if (v.ongoing) return drop(c, r, '标题写着还在连载，不是整季');
  if (!total && v.vids > 0){
    await clog(c, r.id, '标题和 TMDB 都给不出总集数，按 ' + v.vids + ' 个视频收下');
    return go(r, 'rename');
  }
  return drop(c, r, '核对不了整季（' + v.k + '）');
}

async function stRename(c, r){
  const t = now();
  if (!r.d.job){
    let j;
    try { j = await tf(c, 'rename', { dir: r.d.fname, tpl: c.cfg.tpl, lang: c.cfg.lang, grp: c.cfg.grp }); }
    catch (e){
      /* 上一次改名其实做完了、只是作业记录丢了（VPS 重启）：原名不在了 */
      if (r.d.newname && !transientErr(e) && !e.circuit && !e.budget && /not found|找不到|doesn't exist/i.test(e.message)){ r.d.fname = r.d.newname; return renamed(c, r); }
      throw e;
    }
    if (j.same){ r.d.newname = r.d.fname; return renamed(c, r); }
    r.d.job = j.jobid; r.d.newname = j.name; r.d.rb = 0; r.d.rbAt = t;
    r.note = '改名为 ' + j.name; r.next = t + 20000;
    return;
  }
  const s = await jobStatus(c, r.d.job);
  if (s.missing){
    /* VPS 重启过，作业没了：重新发一次改名（原名已经不在 = 其实改完了，上面那个分支会接住） */
    r.d.job = 0; r.d.lost = (r.d.lost || 0) + 1;
    await clog(c, r.id, '改名作业没了（VPS 重启过？），重来');
    if (r.d.lost > LIMIT.lostMax) return fail(r, '改名作业一直丢（VPS 反复重启）');
    r.next = t; return;
  }
  if (!s.finished){
    if (s.bytes > (r.d.rb || 0)){ r.d.rb = s.bytes; r.d.rbAt = t; }
    if (t - (r.d.rbAt || r.since) > LIMIT.renameStall){
      await stopJob(c, r.d.job);
      r.d.job = 0; r.d.rtries = (r.d.rtries || 0) + 1;
      await clog(c, r.id, '改名 ' + Math.round(LIMIT.renameStall / MIN) + ' 分钟没有进展，停掉重来');
      if (r.d.rtries >= 3) return fail(r, '改名一直没有进展');
      r.next = t + MIN; return;
    }
    r.pct = s.total ? clamp(s.bytes / s.total, 0, 1) : 0.5; r.next = t + 30000; return;
  }
  r.d.job = 0;
  if (!s.success){
    r.d.rtries = (r.d.rtries || 0) + 1;
    await clog(c, r.id, '改名出错：' + (s.error || '未知'));
    if (r.d.rtries >= 3) return fail(r, '改名失败：' + String(s.error || '').slice(0, 80));
    r.note = '改名出错，重试'; r.next = t + 2 * MIN; return;
  }
  return renamed(c, r);
}
async function renamed(c, r){
  r.d.item = r.d.newname || r.d.fname; r.d.kind = 'dir'; r.d.job = 0;
  await clog(c, r.id, '命名：' + r.d.item);
  go(r, 'copy');
}

async function stCopy(c, r){
  const t = now();
  if (!r.d.job){
    if (!slotFree(c, 'vps')){
      r.d.wait = 'vps';
      r.note = '排队：VPS 同时传输已满（' + c.slots.vps.used + ' / ' + c.slots.vps.max + '）';
      r.next = t + 2 * MIN;
      return;
    }
    delete r.d.wait;
    const j = await tf(c, 'copy', { item: r.d.item, kind: r.d.kind });
    if (!j.jobid) throw err('传输没给作业号');
    r.d.job = j.jobid; r.d.cstart = t; r.d.cb = 0; r.d.cbAt = t;
    r.note = '开始传输到 Dropbox'; r.next = t + 30000;
    return;
  }
  const s = await jobStatus(c, r.d.job);
  if (s.missing){
    /* VPS 重启过，作业没了：重新开（rclone copy 会跳过已经传完的文件） */
    r.d.job = 0; r.d.lost = (r.d.lost || 0) + 1;
    await clog(c, r.id, '传输作业没了（VPS 重启过？），从断点重开');
    if (r.d.lost > LIMIT.lostMax) return fail(r, '传输作业一直丢（VPS 反复重启）');
    r.next = t; return;
  }
  if (!s.finished){
    if (s.bytes > (r.d.cb || 0)){ r.d.cb = s.bytes; r.d.cbAt = t; }
    /* 看门狗：一直没有新字节 = 卡住了，停掉重开（copy 跳过已经传完的） */
    if (t - (r.d.cbAt || r.d.cstart || t) > LIMIT.copyStall){
      await stopJob(c, r.d.job);
      r.d.job = 0; r.d.ctries = (r.d.ctries || 0) + 1;
      await clog(c, r.id, '传输 ' + Math.round(LIMIT.copyStall / MIN) + ' 分钟没有进展，停掉重开（第 ' + r.d.ctries + ' 次）');
      if (r.d.ctries >= LIMIT.copyTries) return fail(r, '传输一直没有进展');
      r.next = t + MIN; return;
    }
    const p = s.total ? clamp(s.bytes / s.total, 0, 0.99) : r.pct;
    r.pct = p;
    r.note = '传输到 Dropbox ' + Math.round(p * 100) + '%' + (s.speed ? ' · ' + (s.speed / 1048576).toFixed(1) + ' MB/s' : '');
    r.next = t + MIN;
    return;
  }
  r.d.job = 0;
  if (!s.success){
    r.d.ctries = (r.d.ctries || 0) + 1;
    await clog(c, r.id, '传输出错（第 ' + r.d.ctries + ' 次）：' + (s.error || '未知'));
    if (r.d.ctries >= LIMIT.copyTries) return fail(r, '传输失败：' + String(s.error || '').slice(0, 80));
    r.note = '传输出错，重试'; r.next = t + 2 * MIN; return;
  }
  r.pct = 1;
  go(r, 'verify');
}

async function stVerify(c, r){
  const v = await tf(c, 'verify', { item: r.d.item, kind: r.d.kind });
  if (v.ok){
    await clog(c, r.id, '两端核对一致：' + v.dst.count + ' 个文件 / ' + v.dst.bytes + ' 字节');
    return go(r, 'purge');
  }
  r.d.ctries = (r.d.ctries || 0) + 1;
  await clog(c, r.id, '两端核对不一致：' + JSON.stringify({ src: v.src, dst: v.dst }));
  if (r.d.ctries >= LIMIT.copyTries) return fail(r, '两端核对一直不一致');
  go(r, 'copy', '两端核对不一致，重新传输');
}

async function stPurge(c, r){
  await tf(c, 'purge', { item: r.d.item, kind: r.d.kind });
  if (r.d.task && c.cfg.pkUser) await pkDelTasks(c, [r.d.task], false).catch(e => { if (e.budget) throw e; });
  await clog(c, r.id, '传输完成，PikPak 那份已删，等待发行：dropbox:' + (c.env.AUTO_DIR || 'auto') + '/' + r.d.item);
  go(r, 'release');
  r.next = now() + LIMIT.releasePoll;
}

async function stRelease(c, r){
  const batch = c.memo.exists;
  const exists = batch && r.d.item in batch ? batch[r.d.item] : (await tf(c, 'exists', { item: r.d.item })).exists;
  if (!exists){
    await clog(c, r.id, '已发行（不在 Dropbox 的 /auto 里了）');
    r.stage = 'done'; r.since = now(); r.next = 0; r.pct = 1; r.note = STAGE_TEXT.done;
    return;
  }
  r.next = now() + LIMIT.releasePoll;
}

const STAGES = { queued: stQueued, download: stDownload, clean: stClean, check: stCheck, rename: stRename,
                 copy: stCopy, verify: stVerify, purge: stPurge, release: stRelease };
/** 需要 PikPak 账号的步骤 */
const NEEDS_PK = new Set(['download', 'clean']);

async function advance(c, r){
  const fn = STAGES[r.stage];
  if (!fn) return;
  const before = r.stage;
  /* 要用的依赖在熔断：原地等它恢复（错开一点，免得恢复那一刻一窝蜂） */
  for (const dep of STAGE_DEPS[r.stage] || []){
    const until = depOpenUntil(c, dep);
    if (until){ r.note = DEPS[dep] + '暂时不可用，等它恢复'; r.next = until + Math.floor(Math.random() * 20000); return; }
  }
  if (NEEDS_PK.has(r.stage) && !(c.cfg.pkUser && c.cfg.pkPass)){
    r.note = '等控制面板填 PikPak 账号和密码'; r.next = now() + 5 * MIN; return;
  }
  try {
    await fn(c, r);
    if (r.stage === before && r.d.errs){ r.d.errs = 0; delete r.d.errSince; }
  } catch (e){
    if (e.budget){ r.next = now(); return; }
    if (e.circuit){ r.note = String(e.message); r.next = (e.until || now() + 2 * MIN) + Math.floor(Math.random() * 20000); return; }
    if (e.bug){ await clog(c, r.id, '内部状态出错：' + e.message); return fail(r, '内部状态出错：' + e.message); }
    const transient = transientErr(e) || !!e.cool;
    r.d.errs = (r.d.errs || 0) + 1;
    r.d.errSince = r.d.errSince || now();
    r.note = String(e.message || e).slice(0, 160);
    await clog(c, r.id, STAGE_TEXT[r.stage] + ' 出错（第 ' + r.d.errs + ' 次）：' + r.note);
    if (e.conf){ r.next = now() + 10 * MIN; return; }
    if (!transient && r.d.errs >= LIMIT.stepErrors) return fail(r, STAGE_TEXT[r.stage] + '一直出错：' + r.note);
    if (transient && now() - r.d.errSince > LIMIT.depGiveUp) return fail(r, STAGE_TEXT[r.stage] + '：依赖一天都连不上，停下等人处理（' + r.note + '）');
    /* 退避：2、4、8…30 分钟（暂时性的减半），带 ±15% 抖动 */
    const mins = Math.min(30, 2 ** Math.min(r.d.errs, 5)) / (transient ? 2 : 1);
    r.next = now() + Math.round(mins * MIN * (0.85 + Math.random() * 0.3));
  }
}

/* ══════════════════════════════════════════════════════════════════
   智能队列
   · 先把开了头的做完：发行检查 / 删 PikPak / 核对 > 传输 > 改名 / 清洗 > 云下载 > 排队中的
     （越往后的一步越早腾出 PikPak 和 VPS 的位子，整条流水线就不会堵在中间）
   · 排队中的按「这个人的第几个」打散：每个人的第一个先上，一个人连点五部不会把别人挤到后面
   · 同一档里人多的（好几个人在等）优先，再按到期时间、先来后到
   · 资源位：PikPak 同时云下载、VPS 同时传输各有上限（面板里调），满了排队等，不算出错
   · 批量：这一轮要问的 rclone 作业一次问完（/api/link/jobs），要看的发行检查列一次目录（/api/link/exists）
   ══════════════════════════════════════════════════════════════════ */
const STAGE_PRI = { purge: 9, verify: 8, release: 7, copy: 6, rename: 5, check: 4, clean: 4, download: 3, queued: 1 };
function schedule(rows){
  const list = rows.map(rowOf);
  const seen = new Map();
  for (const r of list.filter(r => r.stage === 'queued').sort((a, b) => (a.created || 0) - (b.created || 0))){
    const u = r.users[0] || '';
    const k = seen.get(u) || 0;
    r._fair = k; seen.set(u, k + 1);
  }
  return list.sort((a, b) => (STAGE_PRI[b.stage] || 0) - (STAGE_PRI[a.stage] || 0)
    || (a._fair || 0) - (b._fair || 0)
    || b.users.length - a.users.length
    || (a.next || 0) - (b.next || 0)
    || (a.created || 0) - (b.created || 0));
}
async function loadSlots(c){
  const rows = (await (await db(c.env)).prepare("SELECT stage, data FROM tj_req WHERE stage IN ('download', 'copy')").all()).results || [];
  let pk = 0, vps = 0;
  for (const x of rows){
    if (x.stage === 'download'){ pk++; continue; }
    try { if ((JSON.parse(x.data || '{}') || {}).job) vps++; } catch {}
  }
  c.slots = { pk: { used: pk, max: c.cfg.pkSlots || CFG_DEF.pkSlots }, vps: { used: vps, max: c.cfg.vpsSlots || CFG_DEF.vpsSlots } };
  return c.slots;
}
/** 这一轮要问的东西先一次问完：rclone 作业（传输 / 改名）、发行检查。老版本传输 Worker 没有批量接口就退回一个一个问 */
async function prefetch(c, list){
  if (depOpenUntil(c, 'vps')) return;
  const ids = [...new Set(list.filter(r => (r.stage === 'copy' || r.stage === 'rename') && r.d.job).map(r => r.d.job))];
  if (ids.length > 1){
    try { c.memo.jobs = (await tf(c, 'jobs', { ids: ids.slice(0, 12) })).jobs || null; }
    catch (e){ if (e.budget) throw e; }
  }
  const items = [...new Set(list.filter(r => r.stage === 'release' && r.d.item).map(r => r.d.item))];
  if (items.length > 1){
    try { c.memo.exists = (await tf(c, 'exists', { items: items.slice(0, 200) })).exists || null; }
    catch (e){ if (e.budget) throw e; }
  }
}
function saveStmt(d, r){
  return d.prepare(
    `UPDATE tj_req SET title = ?, year = ?, poster = ?, users = ?, stage = ?, pct = ?, note = ?, data = ?, updated = ?, since = ?,
       next = ?, rev = rev + 1 WHERE id = ? AND rev = ?`)
    .bind(r.title || '', r.year || '', r.poster || '', JSON.stringify(r.users || []), r.stage, +r.pct || 0, r.note || '',
          JSON.stringify(r.d || {}), now(), r.since || now(), r.next || 0, r.id, r.rev);
}
/** 攒着的请求更新和日志一次写进 D1（一个事务）。rev 对不上的那条（面板刚改过）不写，面板赢 */
async function flush(c){
  if (!(c.pending && c.pending.length) && !(c.logs && c.logs.length)) return [];
  const d = await db(c.env);
  const rs = c.pending || [], logs = c.logs || [];
  c.pending = []; c.logs = [];
  const stmts = rs.map(r => saveStmt(d, r))
    .concat(logs.map(([rid, at, msg]) => d.prepare('INSERT INTO tj_log (rid, at, msg) VALUES (?, ?, ?)').bind(rid, at, msg)));
  const res = await d.batch(stmts);
  return rs.map((r, i) => { const ok = !!(res[i] && res[i].meta && res[i].meta.changes); if (ok) r.rev++; return { id: r.id, ok }; });
}

async function tick(env, opt = {}){
  const t = now();
  if (!opt.force && !(await lease(env, 'tick', 55000))) return { busy: 1 };
  const cfg = await loadCfg(env);
  if (cfg.paused && !opt.force) return { paused: 1 };
  const c = context(env, cfg);
  c.health = await loadHealth(env);
  c.logs = []; c.pending = [];
  await loadSlots(c);
  const d = await db(env);
  const rows = (await d.prepare(`SELECT * FROM tj_req WHERE stage IN (${ACTIVE.map(() => '?').join(',')}) AND next <= ? ORDER BY next ASC LIMIT 60`)
    .bind(...ACTIVE, t).all()).results || [];
  const list = schedule(rows);
  const out = { done: 0, steps: [], due: list.length };
  try {
    await prefetch(c, list);
    for (const r of list){
      if (out.done >= LIMIT.perTick || now() - c.t0 > LIMIT.tickMs || c.n >= c.max - 3) break;
      const from = r.stage;
      const held = { pk: from === 'download', vps: from === 'copy' && !!r.d.job };
      await advance(c, r);
      c.slots.pk.used += (r.stage === 'download' ? 1 : 0) - (held.pk ? 1 : 0);
      c.slots.vps.used += (r.stage === 'copy' && r.d.job ? 1 : 0) - (held.vps ? 1 : 0);
      if (r.stage !== from) clog(c, r.id, STAGE_TEXT[from] + ' → ' + STAGE_TEXT[r.stage]);
      c.pending.push(r);
      out.steps.push({ id: r.id, from, to: r.stage, note: r.note });
      out.done++;
      if (c.pending.length >= 6) await flush(c);
    }
  } finally {
    await flush(c).catch(e => console.error('写入失败：', e && e.message));
    if (c.healthDirty) await kvPut(env, 'health', c.health).catch(() => {});
  }
  if (Math.random() < 0.03) await d.prepare('DELETE FROM tj_log WHERE id < (SELECT MAX(id) - 4000 FROM tj_log)').run().catch(() => {});
  out.fetches = c.n; out.ms = now() - c.t0; out.slots = c.slots;
  await kvPut(env, 'tick:last', { at: t, done: out.done, due: out.due, fetches: c.n, ms: out.ms }).catch(() => {});
  return out;
}

/* ══════════════════════════════════════════════════════════════════
   给 App 看的进度
   ══════════════════════════════════════════════════════════════════ */
function stepProgress(r){
  switch (r.stage){
    case 'download': return clamp(r.pct, 0, 1);
    case 'clean': return 0.3;
    case 'check': return 0.25 + (r.d.org ? 0.15 : 0);
    case 'rename': return 0.6 + 0.4 * clamp(r.pct, 0, 1);
    case 'copy': return 0.9 * clamp(r.pct, 0, 1);
    case 'verify': return 0.94;
    case 'purge': return 0.98;
    default: return 0;
  }
}
/** 一条请求的进度。internal = 控制面板用：多带内部说明（note）、当前规格、试过几个。
    给 App 的不带这些——用户不该看到推到哪个网盘、哪个版本、下载出了什么错 */
function view(r, internal){
  const state = r.stage === 'done' ? 'done' : r.stage === 'failed' ? 'failed' : r.stage === 'cancelled' ? 'cancelled' : 'active';
  /* 失败 / 取消停在出事的那一步 */
  const at = state === 'active' || state === 'done' ? r.stage : (r.d.lastStage || 'queued');
  const step = STEP_OF[at] || 1;
  const pct = state === 'done' ? 100 : Math.round(((step - 1) + (state === 'active' ? stepProgress(r) : 0)) / 5 * 100);
  const out = { id: r.id, src: r.src, tmdb: r.tmdb, season: r.season || 0, title: r.title || '', year: r.year || '', poster: r.poster || '',
           stage: r.stage, state, step, steps: 5, pct, label: STEP_LABELS[step - 1], created: r.created || 0, updated: r.updated || 0 };
  if (internal){
    out.note = r.note || '';
    out.spec = r.d.cur ? { res: r.d.cur.res || '', labels: r.d.cur.labels || [], size: r.d.cur.size || '' } : null;
    out.tries = (r.d.tried || []).length;
  }
  return out;
}

async function latestFor(env, src, ids){
  ids = [...new Set(ids.map(Number).filter(n => n > 0))].slice(0, 90);     // D1 一条语句最多绑 100 个参数
  if (!ids.length) return new Map();
  const res = await (await db(env)).prepare(`SELECT * FROM tj_req WHERE src = ? AND tmdb IN (${ids.map(() => '?').join(',')}) ORDER BY id DESC`)
    .bind(src, ...ids).all();
  const m = new Map();
  for (const x of res.results || []){
    const k = x.tmdb + ':' + (x.season || 0);
    if (!m.has(k)) m.set(k, view(rowOf(x)));
  }
  return m;
}
/** 一部片 / 剧集的「最要紧」那条：进行中的优先，其次最新的 */
function pickFor(m, id){
  let best = null;
  for (const [k, v] of m){
    if (!k.startsWith(id + ':')) continue;
    if (!best || (v.state === 'active' && best.state !== 'active') || (v.state === best.state && v.id > best.id)) best = v;
  }
  return best;
}

/* ── 账户：用户名得真实存在（check.cuven.us 上查得到）── */
async function userOK(env, name){
  if (!name || name.length > 64 || /[\/\\\x00-\x1f]/.test(name)) return false;
  const k = 'u:' + name.toLowerCase();
  if (await kvGet(env, k)) return true;
  const c = context(env, CFG_DEF, 4);
  /* 和 App 登录时同一个接口：/check/<用户名> → { exists }（老账户可能没有 username_ 账户档，不能拿它判断） */
  const r = await xfetch(c, base(env, 'ACCOUNT_BASE', 'https://check.cuven.us') + '/check/' + encodeURIComponent(name), {}, 10000);
  if (r.status === 404) return false;
  if (!r.ok) throw err('暂时核对不了账户，稍后再试', { status: 503 });
  const j = await readJSON(r);
  const ok = !!(j && j.exists === true);
  if (ok) await kvPut(env, k, 1, 7 * DAY);
  return ok;
}

async function createReq(env, user, body, admin){
  const src = body.src === 'tv' ? 'tv' : body.src === 'movie' ? 'movie' : '';
  const id = parseInt(body.id, 10) || 0;
  const season = src === 'tv' ? Math.max(1, parseInt(body.season, 10) || 0) : 0;
  if (!src || !id) return json({ error: '要 src（movie / tv）和 id（TMDB 编号）' }, 400);
  if (src === 'tv' && !(parseInt(body.season, 10) > 0)) return json({ error: '剧集要说明第几季' }, 400);
  const d = await db(env);
  const cfg = await loadCfg(env);
  const t = now();
  /* 同一部 / 同一季已经在进行中：跟上 */
  const live = rowOf(await d.prepare(`SELECT * FROM tj_req WHERE src = ? AND tmdb = ? AND season = ? AND stage NOT IN ('done','failed','cancelled')`)
    .bind(src, id, season).first());
  if (live){
    if (!live.users.includes(user)){
      await d.prepare('UPDATE tj_req SET users = ?, rev = rev + 1, updated = ? WHERE id = ?').bind(JSON.stringify([...live.users, user].slice(-50)), t, live.id).run();
      live.users.push(user);
    }
    return json({ request: view(live), joined: 1 });
  }
  /* 刚失败过：一天之内用户不能重开（面板上随时能重试） */
  if (!admin){
    const last = rowOf(await d.prepare(`SELECT * FROM tj_req WHERE src = ? AND tmdb = ? AND season = ? AND stage = 'failed' ORDER BY id DESC LIMIT 1`)
      .bind(src, id, season).first());
    if (last && t - (last.updated || 0) < LIMIT.refail){
      if (!last.users.includes(user))
        await d.prepare('UPDATE tj_req SET users = ? WHERE id = ?').bind(JSON.stringify([...last.users, user].slice(-50)), last.id).run();
      return json({ request: view(last), failedRecently: 1 });
    }
    const mine = await d.prepare(`SELECT COUNT(*) AS n FROM tj_req WHERE stage NOT IN ('done','failed','cancelled','release')
      AND EXISTS (SELECT 1 FROM json_each(tj_req.users) WHERE value = ?)`).bind(user).first();
    if ((mine && mine.n) >= cfg.userCap) return json({ error: '你同时进行中的请求已经有 ' + cfg.userCap + ' 个了，等它们传完再来', cap: 'user' }, 429);
    const all = await d.prepare(`SELECT COUNT(*) AS n FROM tj_req WHERE stage NOT IN ('done','failed','cancelled','release')`).first();
    if ((all && all.n) >= cfg.globalCap) return json({ error: '现在排队的请求太多了，稍后再来', cap: 'global' }, 429);
  }
  /* 先问一遍影片库：有资源才收下（顺便拿到片名和海报） */
  const c = context(env, cfg, 6);
  let v;
  try { v = await lbVersions(c, src, id, season); }
  catch (e){
    if (e.status === 404) return json({ error: '影片库里没有这部片', none: 1 }, 404);
    return json({ error: '暂时连不上影片库，稍后再试' }, 503);
  }
  if (!(v.items || []).length) return json({ error: src === 'tv' ? '这一季还没有可用的整季资源' : '这部片还没有可用的资源', none: 1 }, 404);
  const data = { vers: v.items.map(x => ({ tid: x.tid, t: String(x.title || '').slice(0, 200), mb: x.mb || 0, size: x.size || '',
                   res: x.res || '', labels: (x.labels || []).slice(0, 6), total: x.total || 0 })), versAt: t, tried: [] };
  try {
    const res = await d.prepare(`INSERT INTO tj_req (src, tmdb, season, title, year, poster, users, stage, pct, note, data, created, updated, since, next)
      VALUES (?, ?, ?, ?, ?, ?, ?, 'queued', 0, ?, ?, ?, ?, ?, ?)`)
      .bind(src, id, season, v.title || '', String(v.year || ''), v.poster || '', JSON.stringify([user]), STAGE_TEXT.queued,
            JSON.stringify(data), t, t, t, t).run();
    const r = await getReq(env, res.meta.last_row_id);
    await logMsg(env, r.id, (admin ? '面板' : user) + ' 请求添加：' + (v.title || id) + (season ? ' 第 ' + season + ' 季' : ''));
    return json({ request: view(r), created: 1 });
  } catch (e){
    /* 两个人同时点：唯一索引挡住了后来的，跟上先来的那条 */
    const again = rowOf(await d.prepare(`SELECT * FROM tj_req WHERE src = ? AND tmdb = ? AND season = ? AND stage NOT IN ('done','failed','cancelled')`)
      .bind(src, id, season).first());
    if (again) return json({ request: view(again), joined: 1 });
    throw e;
  }
}

/* ══════════════════════════════════════════════════════════════════
   App 接口
   ══════════════════════════════════════════════════════════════════ */
function slimItem(x, src){
  return { id: x.id, src, title: x.title || '', year: x.year || '', poster: x.poster || '', vote: x.vote || 0,
           res: x.res || '', hb: x.hb || 0, rb: x.rb || 0, own: x.own ? 1 : 0 };
}
async function appCatalog(env, Q){
  const want = ['movie', 'tv', 'all'].includes(Q.get('src')) ? Q.get('src') : 'all';
  const q = (Q.get('q') || '').trim().slice(0, 80);
  const qs = new URLSearchParams({ own: Q.get('own') === 'hide' ? 'hide' : 'all',
    sort: ['new', 'vote', 'hot', 'spec'].includes(Q.get('sort')) ? Q.get('sort') : 'new',
    page: String(clamp(parseInt(Q.get('page') || '1', 10) || 1, 1, 500)),
    min: Q.get('min') != null ? String(Number(Q.get('min')) || 0) : (q ? '0' : '6') });
  if (q) qs.set('q', q);
  const c = context(env, CFG_DEF, 6);
  const srcs = want === 'all' ? ['movie', 'tv'] : [want];
  const pages = await Promise.all(srcs.map(s => lb(c, '/api/catalog?src=' + s + '&' + qs).then(j => ({ s, j })).catch(e => ({ s, e }))));
  if (pages.every(p => p.e)) return json({ error: '暂时连不上影片库' }, 503);
  const lists = pages.map(p => (p.j && p.j.items || []).map(x => slimItem(x, p.s)));
  /* 两个源交替排：搜索结果里电影和剧集都看得到 */
  const items = [];
  for (let i = 0; i < Math.max(0, ...lists.map(l => l.length)); i++) for (const l of lists) if (l[i]) items.push(l[i]);
  for (const s of srcs){
    const m = await latestFor(env, s, items.filter(x => x.src === s).map(x => x.id));
    for (const it of items) if (it.src === s){ const v = pickFor(m, it.id); if (v) it.req = v; }
  }
  const meta = pages.filter(p => p.j).map(p => p.j);
  return json({ items, page: +qs.get('page'), pages: Math.max(0, ...meta.map(m => m.pages || 0)),
                total: meta.reduce((s, m) => s + (m.total || 0), 0) }, 200, { 'cache-control': 'private, max-age=30' });
}
async function appDetail(env, Q){
  const src = Q.get('src') === 'tv' ? 'tv' : 'movie';
  const id = parseInt(Q.get('id') || '', 10) || 0;
  if (!id) return json({ error: '要 id（TMDB 编号）' }, 400);
  const season = src === 'tv' ? parseInt(Q.get('season') || '0', 10) || 0 : 0;
  const c = context(env, CFG_DEF, 4);
  let v;
  try { v = await lbVersions(c, src, id, season); }
  catch (e){
    if (e.status === 404) return json({ id, src, known: 0, count: 0, seasons: [], season: 0, req: null, reqs: {} });
    return json({ error: '暂时连不上影片库' }, 503);
  }
  const items = v.items || [];
  const m = await latestFor(env, src, [id]);
  const reqs = {};
  for (const [k, r] of m) reqs[k.split(':')[1]] = r;
  return json({ id, src, known: 1, title: v.title || '', original: v.original || '', year: String(v.year || ''), poster: v.poster || '',
    seasons: v.seasons || [], season: v.season || 0, count: items.length,
    req: reqs[String(src === 'tv' ? (v.season || season) : 0)] || null, reqs }, 200, { 'cache-control': 'private, max-age=15' });
}
/** 我的请求。带 ETag：App 每 30 秒问一次，没变就回 304（不带正文） */
async function appRequests(env, user, request){
  const t = now();
  const res = await (await db(env)).prepare(`SELECT * FROM tj_req WHERE EXISTS (SELECT 1 FROM json_each(tj_req.users) WHERE value = ?)
      AND (stage NOT IN ('done','failed','cancelled') OR updated > ?) ORDER BY id DESC LIMIT 60`).bind(user, t - 30 * DAY).all();
  const body = JSON.stringify({ items: (res.results || []).map(x => view(rowOf(x))) });
  const tag = 'W/"' + md5(body).slice(0, 20) + '"';
  const h = { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store', etag: tag };
  if (request && request.headers.get('if-none-match') === tag) return new Response(null, { status: 304, headers: h });
  return new Response(body, { headers: h });
}

/* ══════════════════════════════════════════════════════════════════
   控制面板接口
   ══════════════════════════════════════════════════════════════════ */
function safeEq(a, b){
  a = String(a || ''); b = String(b || '');
  if (!a || !b || a.length !== b.length) return false;
  let x = 0;
  for (let i = 0; i < a.length; i++) x |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return x === 0;
}
async function adminState(env){
  const d = await db(env);
  const cfg = await loadCfg(env);
  const reqs = ((await d.prepare('SELECT * FROM tj_req ORDER BY (stage IN (\'done\',\'failed\',\'cancelled\')), id DESC LIMIT 200').all()).results || [])
    .map(x => { const r = rowOf(x); return { ...view(r, true), users: r.users, item: r.d.item || '', cur: r.d.cur ? r.d.cur.t : '', tried: (r.d.tried || []).length,
      vers: (r.d.vers || []).length, next: r.next || 0, since: r.since || 0, errs: r.d.errs || 0, check: r.d.check || null }; });
  const logs = ((await d.prepare('SELECT * FROM tj_log ORDER BY id DESC LIMIT 200').all()).results || []);
  const tok = await kvGet(env, 'pk:tok');
  /* 排队位置：和定时任务同一套排序（每个人的第一个先上、人多的优先、先来后到） */
  const queued = schedule(((await d.prepare("SELECT * FROM tj_req WHERE stage = 'queued'").all()).results || []));
  const pos = new Map(queued.map((r, i) => [r.id, i + 1]));
  for (const r of reqs) if (pos.has(r.id)) r.pos = pos.get(r.id);
  const c = context(env, cfg, 1);
  const slots = await loadSlots(c);
  const health = await loadHealth(env);
  return { ver: VER, now: now(), health, slots, tick: await kvGet(env, 'tick:last'), queued: queued.length,
    cfg: { pkUser: mask(cfg.pkUser), pkSet: !!(cfg.pkUser && cfg.pkPass), tpl: cfg.tpl, lang: cfg.lang, grp: cfg.grp,
           userCap: cfg.userCap, globalCap: cfg.globalCap, paused: !!cfg.paused, pkToken: tok ? { exp: tok.exp } : null,
           pkSlots: cfg.pkSlots, vpsSlots: cfg.vpsSlots },
    env: { LB_GATE: !!env.LB_GATE, LINK_KEY: !!env.LINK_KEY, LB_BASE: base(env, 'LB_BASE', 'https://lb.cuven.us'),
           TRANSFER_BASE: base(env, 'TRANSFER_BASE', 'https://transfer.cuven.us'), AUTO_DIR: String(env.AUTO_DIR || 'auto') },
    reqs, logs };
}
async function adminReq(env, body){
  const r = await getReq(env, parseInt(body.id, 10) || 0);
  if (!r) return json({ error: '没有这条请求' }, 404);
  const act = String(body.act || '');
  const cfg = await loadCfg(env);
  const c = context(env, cfg, 20);
  if (act === 'delete'){
    await (await db(env)).prepare('DELETE FROM tj_req WHERE id = ?').bind(r.id).run();
    await logMsg(env, r.id, '面板：删除');
    return json({ ok: 1 });
  }
  if (act === 'cancel'){
    if (ENDED.includes(r.stage)) return json({ error: '已经结束了' }, 400);
    r.d.lastStage = r.stage;
    if (['download', 'clean', 'check'].includes(r.stage) && cfg.pkUser){
      if (r.d.task) await pkDelTasks(c, [r.d.task], true).catch(() => {});
      if (r.d.file) await pkTrash(c, [r.d.file]).catch(() => {});
    }
    r.stage = 'cancelled'; r.next = 0; r.note = '已取消';
  } else if (act === 'retry'){
    /* 失败 / 取消的：从出事的那一步重来（推送之前的就从头来，试过的规格清零） */
    const from = ENDED.includes(r.stage) ? (r.d.lastStage || 'queued') : r.stage;
    if (r.stage === 'done') return json({ error: '已经发行了' }, 400);
    const live = await (await db(env)).prepare(`SELECT id FROM tj_req WHERE src = ? AND tmdb = ? AND season = ? AND id != ? AND stage NOT IN ('done','failed','cancelled')`)
      .bind(r.src, r.tmdb, r.season, r.id).first();
    if (live) return json({ error: '同一部 / 同一季已经有一条在进行中（#' + live.id + '）' }, 409);
    if (from === 'queued'){ r.d.tried = []; delete r.d.versAt; }
    r.d.errs = 0; r.d.ctries = 0; r.d.rtries = 0; r.d.job = 0;
    r.stage = from; r.next = now(); r.since = now(); r.note = '面板：重试';
  } else if (act === 'skip'){
    if (!['download', 'clean', 'check', 'queued'].includes(r.stage)) return json({ error: '只有推送 / 下载 / 清洗阶段能换规格' }, 400);
    if (!cfg.pkUser) return json({ error: '先填 PikPak 账号' }, 400);
    await drop(c, r, '面板：换下一个规格');
  } else if (act === 'now'){
    r.next = 0;
  } else return json({ error: '未知操作' }, 400);
  if (r.stage === 'failed' || r.stage === 'cancelled') r.d.lastStage = r.d.lastStage || 'queued';
  const ok = await saveReq(env, r);
  await logMsg(env, r.id, '面板：' + act);
  return json({ ok: ok ? 1 : 0, request: view(r, true) });
}
async function adminPk(env){
  const cfg = await loadCfg(env);
  const c = context(env, cfg, 16);
  const out = { set: !!(cfg.pkUser && cfg.pkPass), user: mask(cfg.pkUser) };
  try {
    const a = await pkCall(c, 'GET', '/drive/v1/about');
    const q = (a && a.quota) || {};
    out.ok = 1; out.limit = Number(q.limit) || 0; out.usage = Number(q.usage) || 0;
    try {
      const auto = await autoFolder(c, true);
      const f = await pkFile(c, auto);
      out.auto = f ? { id: auto, name: f.name, same: 1 } : { id: auto, same: 0, hint: '影片库给的 /auto 在这个账号里找不到：两边配的不是同一个 PikPak 账号' };
    } catch (e){ out.auto = { err: e.message }; }
  } catch (e){ out.ok = 0; out.err = e.message; out.captcha = e.captcha ? 1 : 0; }
  return json(out);
}
async function adminLinks(env){
  const c = context(env, CFG_DEF, 6);
  const out = {};
  try { const s = await lb(c, '/api/pikpak?do=status'); out.lb = { ok: 1, pikpak: s.on ? (s.ok ? '已登录 ' + (s.user || '') : '登录失败：' + (s.err || '')) : '没配 PikPak' }; }
  catch (e){ out.lb = { ok: 0, err: e.message }; }
  try { const p = await tf(c, 'ping', {}); out.transfer = { ok: 1, rclone: p.version || '', core: p.core || '' }; }
  catch (e){ out.transfer = { ok: 0, err: e.message }; }
  return json(out);
}

/* ══════════════════════════════════════════════════════════════════
   路由
   ══════════════════════════════════════════════════════════════════ */
export default {
  async scheduled(event, env, ctx){
    ctx.waitUntil(tick(env).catch(e => console.error('tick 失败：', e && e.message)));
  },

  async fetch(request, env, ctx){
    const url = new URL(request.url), p = url.pathname, Q = url.searchParams;
    try {
      if (p === '/' || p === '/index.html')
        return new Response(PANEL, { headers: { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store',
          'x-content-type-options': 'nosniff', 'referrer-policy': 'no-referrer', 'x-frame-options': 'DENY' } });
      if (p === '/version') return json({ ver: VER });

      if (p.startsWith('/app/')){
        if (p === '/app/catalog' && request.method === 'GET') return await appCatalog(env, Q);
        if (p === '/app/detail' && request.method === 'GET') return await appDetail(env, Q);
        if (p === '/app/requests'){
          /* App 把用户名按 encodeURIComponent 编码后放进头里（头里只能放 ASCII） */
          let user = String(request.headers.get('x-cuven-user') || '').trim();
          try { user = decodeURIComponent(user); } catch {}
          if (!user) return json({ error: '要登录' }, 401);
          if (request.method === 'GET') return await appRequests(env, user, request);
          if (request.method === 'POST'){
            if (!(await userOK(env, user))) return json({ error: '账户核对不上，重新登录再试' }, 401);
            const body = await request.json().catch(() => null);
            if (!body) return json({ error: '正文是 { src, id, season }' }, 400);
            return await createReq(env, user, body, false);
          }
        }
        return json({ error: 'not found' }, 404);
      }

      if (p.startsWith('/admin/api/')){
        if (!env.ADMIN_KEY) return json({ error: '还没配 ADMIN_KEY（Worker 设置 → 变量和机密，类型选「密钥」）' }, 500);
        if (!safeEq(request.headers.get('x-admin-key'), env.ADMIN_KEY)){ await sleep(400); return json({ error: '口令不对' }, 401); }
        const body = request.method === 'POST' ? (await request.json().catch(() => ({}))) : {};
        const op = p.slice('/admin/api/'.length);
        if (op === 'state') return json(await adminState(env));
        if (op === 'cfg'){ await saveCfg(env, body || {}); return json(await adminState(env)); }
        if (op === 'pk') return await adminPk(env);
        if (op === 'links') return await adminLinks(env);
        if (op === 'req') return await adminReq(env, body || {});
        if (op === 'add') return await createReq(env, 'admin', body || {}, true);
        if (op === 'tick') return json(await tick(env, { force: true }));
        if (op === 'log'){
          const rid = parseInt(Q.get('id') || '0', 10) || 0;
          const rows = (await (await db(env)).prepare('SELECT * FROM tj_log WHERE rid = ? ORDER BY id DESC LIMIT 200').bind(rid).all()).results || [];
          return json({ items: rows });
        }
        return json({ error: 'not found' }, 404);
      }
      return new Response('Not found', { status: 404 });
    } catch (e){
      return json({ error: (e && e.message) || String(e) }, (e && e.status) || (e && e.conf ? 500 : 500));
    }
  },
};

/* ══════════════════════════════════════════════════════════════════
   控制面板
   ══════════════════════════════════════════════════════════════════ */
const PANEL = `<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Cuven 请求添加</title>
<style>
:root{--bg:#0b0c0f;--card:#15171c;--line:#262a33;--text:#e9ebf0;--dim:#8b91a0;--accent:#30d158;--warn:#ff9f0a;--bad:#ff453a;--blue:#0a84ff}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:14px/1.5 -apple-system,BlinkMacSystemFont,"PingFang SC","Segoe UI",sans-serif}
header{display:flex;align-items:center;gap:12px;padding:16px 20px;border-bottom:1px solid var(--line);position:sticky;top:0;background:rgba(11,12,15,.9);backdrop-filter:blur(12px);z-index:2}
h1{font-size:17px;margin:0}h2{font-size:15px;margin:0 0 12px}.ver{color:var(--dim);font-size:12px}
main{max-width:1180px;margin:0 auto;padding:20px;display:grid;gap:16px}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(300px,1fr));gap:16px}
.card{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:16px}
label{display:block;color:var(--dim);font-size:12px;margin:10px 0 4px}
input,select{width:100%;background:#0f1115;border:1px solid var(--line);color:var(--text);border-radius:9px;padding:8px 10px;font:inherit}
button{background:#232731;color:var(--text);border:1px solid var(--line);border-radius:9px;padding:7px 12px;font:inherit;cursor:pointer}
button:hover{border-color:#3a404c}button.pri{background:var(--accent);color:#04210d;border-color:transparent;font-weight:600}
button.small{padding:3px 8px;font-size:12px}.row{display:flex;gap:8px;flex-wrap:wrap;align-items:center}
.ok{color:var(--accent)}.bad{color:var(--bad)}.warn{color:var(--warn)}.dim{color:var(--dim)}
table{width:100%;border-collapse:collapse}th,td{text-align:left;padding:9px 8px;border-bottom:1px solid var(--line);vertical-align:top}
th{color:var(--dim);font-weight:500;font-size:12px}td .t{font-weight:600}.mono{font-family:ui-monospace,Menlo,monospace;font-size:12px}
.bar{display:flex;gap:3px;margin:4px 0 2px}.bar i{flex:1;height:6px;border-radius:3px;background:#2a2f39}.bar i.on{background:var(--accent)}
.bar i.cur{background:linear-gradient(90deg,var(--accent) var(--p),#2a2f39 var(--p))}
.pill{display:inline-block;padding:1px 8px;border-radius:99px;font-size:12px;background:#232731}
.pill.active{background:#0d3a1d;color:var(--accent)}.pill.failed{background:#3b1210;color:var(--bad)}.pill.done{background:#10263f;color:#64b5ff}
.log{max-height:360px;overflow:auto}.log div{padding:3px 0;border-bottom:1px dashed #1f232b}
#login{max-width:360px;margin:12vh auto}.hide{display:none!important}
@media (max-width:720px){td:nth-child(3),th:nth-child(3){display:none}main{padding:12px}}
</style></head><body>
<div id="login" class="card"><h2>Cuven 请求添加 · 控制面板</h2><label>口令（ADMIN_KEY）</label><input id="key" type="password" autocomplete="current-password">
<div class="row" style="margin-top:12px"><button class="pri" id="enter">进入</button><span id="lerr" class="bad"></span></div></div>
<div id="app" class="hide">
<header><h1>请求添加</h1><span class="ver" id="ver"></span><span style="flex:1"></span>
<button id="tick">立即跑一轮</button><button id="refresh">刷新</button><button id="logout">退出</button></header>
<main>
<div class="card"><h2>系统</h2><div id="sys" class="dim">—</div></div>
<div class="grid">
 <div class="card"><h2>PikPak（清洗用）</h2>
  <div id="pkline" class="dim">—</div>
  <label>账号（邮箱 / 手机号）</label><input id="pkUser" autocomplete="off" placeholder="不改就留空">
  <label>密码</label><input id="pkPass" type="password" autocomplete="new-password" placeholder="不改就留空">
  <div class="row" style="margin-top:12px"><button class="pri" id="savePk">保存</button><button id="testPk">测试登录</button><span id="pkres"></span></div>
  <p class="dim" style="font-size:12px;margin:10px 0 0">必须和影片库 Worker 的 PIKPAK_USER 是同一个账号。密码用 ADMIN_KEY 派生的密钥加密后存进 D1。</p>
 </div>
 <div class="card"><h2>连接</h2><div id="links" class="dim">—</div><div class="row" style="margin-top:12px"><button id="testLinks">测试影片库 / 传输</button></div>
  <h2 style="margin-top:18px">剧集命名</h2>
  <div class="row"><select id="tpl" style="flex:1"><option value="rel">发行名（rel）</option><option value="std">标准（std）</option><option value="season">季目录（season）</option><option value="nest">嵌套（nest）</option><option value="dot">点分（dot）</option></select>
  <select id="lang" style="flex:1"><option value="en">英文名</option><option value="cn">中文名</option><option value="cnen">中英</option></select></div>
  <label>发行组</label><input id="grp">
 </div>
 <div class="card"><h2>限额</h2>
  <label>每个用户同时进行中</label><input id="userCap" type="number" min="1" max="50">
  <label>全部同时进行中</label><input id="globalCap" type="number" min="1" max="500">
  <label>PikPak 同时云下载</label><input id="pkSlots" type="number" min="1" max="20">
  <label>VPS 同时传输（太多会把 rclone 内存吃满）</label><input id="vpsSlots" type="number" min="1" max="8">
  <label class="row" style="margin-top:12px;color:var(--text)"><input id="paused" type="checkbox" style="width:auto"> 暂停定时任务</label>
  <div class="row" style="margin-top:12px"><button class="pri" id="saveCfg">保存设置</button><span id="cfgres"></span></div>
  <h2 style="margin-top:18px">手动添加</h2>
  <div class="row"><select id="addSrc" style="width:90px"><option value="movie">电影</option><option value="tv">剧集</option></select>
  <input id="addId" placeholder="TMDB 编号" style="flex:1"><input id="addSeason" placeholder="季" style="width:60px"><button id="add">添加</button></div><div id="addres" class="dim"></div>
 </div>
</div>
<div class="card"><h2>请求</h2><table><thead><tr><th>影片</th><th>进度</th><th>规格 / 名字</th><th>用户</th><th></th></tr></thead><tbody id="reqs"></tbody></table></div>
<div class="card"><h2>日志</h2><div id="log" class="log mono"></div></div>
</main></div>
<script>
var KEY='';try{KEY=localStorage.getItem('tjkey')||''}catch(e){}
var $=function(id){return document.getElementById(id)};
function esc(s){return String(s==null?'':s).replace(/[&<>"']/g,function(c){return{'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]})}
function ago(t){if(!t)return'';var s=Math.round((Date.now()-t)/1000);if(s<60)return s+' 秒前';if(s<3600)return Math.round(s/60)+' 分钟前';if(s<86400)return Math.round(s/3600)+' 小时前';return Math.round(s/86400)+' 天前'}
function api(op,body){return fetch('/admin/api/'+op,{method:body?'POST':'GET',headers:{'x-admin-key':KEY,'content-type':'application/json'},body:body?JSON.stringify(body):undefined}).then(function(r){return r.json().then(function(j){if(!r.ok)throw new Error(j.error||('HTTP '+r.status));return j})})}
function show(on){$('login').classList.toggle('hide',on);$('app').classList.toggle('hide',!on)}
function bar(r){var h='<div class="bar">';for(var i=1;i<=5;i++){if(i<r.step||r.state==='done')h+='<i class="on"></i>';else if(i===r.step&&r.state==='active'){var p=Math.max(0,Math.min(100,(r.pct-(i-1)*20)*5));h+='<i class="cur" style="--p:'+p+'%"></i>'}else h+='<i></i>'}return h+'</div>'}
function render(s){
 $('ver').textContent=s.ver;var c=s.cfg;
 $('pkline').innerHTML=c.pkSet?'<span class="ok">已填</span> '+esc(c.pkUser)+(c.pkToken?' · 令牌到 '+new Date(c.pkToken.exp).toLocaleTimeString():''):'<span class="warn">还没填 PikPak 账号</span>';
 $('tpl').value=c.tpl;$('lang').value=c.lang;$('grp').value=c.grp;$('userCap').value=c.userCap;$('globalCap').value=c.globalCap;$('paused').checked=c.paused;
 $('pkSlots').value=c.pkSlots;$('vpsSlots').value=c.vpsSlots;
 var NAMES={lb:'影片库',vps:'传输（VPS）',pikpak:'PikPak',stream:'TMDB'};
 var hs=Object.keys(NAMES).map(function(k){var h=s.health[k]||{};var open=h.open&&h.open>s.now;
  return '<span class="pill '+(open?'failed':'active')+'">'+NAMES[k]+' '+(open?'熔断到 '+new Date(h.open).toLocaleTimeString():'正常')+'</span>'+
   (h.err&&h.bad&&s.now-h.bad<3600000?' <span class="dim">'+esc(h.err)+'（'+ago(h.bad)+'）</span>':'')}).join('<br>');
 var sl=s.slots||{pk:{},vps:{}};
 $('sys').innerHTML=hs+'<div style="margin-top:10px">PikPak 云下载 <b>'+sl.pk.used+' / '+sl.pk.max+'</b> · VPS 传输 <b>'+sl.vps.used+' / '+sl.vps.max+'</b> · 排队 <b>'+s.queued+'</b>'+
  (s.tick?' · 上一轮 '+ago(s.tick.at)+'，推进 '+s.tick.done+' / 到期 '+s.tick.due+'，子请求 '+s.tick.fetches+'，'+s.tick.ms+' ms':' · 定时任务还没跑过')+'</div>';
 var e=s.env;$('links').innerHTML='影片库 '+esc(e.LB_BASE)+(e.LB_GATE?'':' <span class="bad">缺 LB_GATE</span>')+'<br>传输 '+esc(e.TRANSFER_BASE)+(e.LINK_KEY?'':' <span class="bad">缺 LINK_KEY</span>')+'<br>目录 /'+esc(e.AUTO_DIR);
 $('reqs').innerHTML=s.reqs.map(function(r){
  var acts=r.state==='active'?'<button class="small" data-a="now" data-id="'+r.id+'">现在</button> <button class="small" data-a="skip" data-id="'+r.id+'">换规格</button> <button class="small" data-a="cancel" data-id="'+r.id+'">取消</button>':
   (r.state!=='done'?'<button class="small" data-a="retry" data-id="'+r.id+'">重试</button> ':'')+'<button class="small" data-a="delete" data-id="'+r.id+'">删除</button>';
  return '<tr><td><div class="t">'+esc(r.title||r.tmdb)+(r.season?' · 第 '+r.season+' 季':'')+'</div><div class="dim">#'+r.id+' · '+(r.src==='tv'?'剧集':'电影')+' '+r.tmdb+' · '+ago(r.created)+'</div></td>'+
   '<td style="min-width:200px"><span class="pill '+r.state+'">'+esc(r.state==='active'?('STEP '+r.step+' · '+r.label):r.state==='done'?'已发行':r.state==='failed'?'失败':'已取消')+'</span> <b>'+r.pct+'%</b>'+(r.pos?' <span class="dim">排队第 '+r.pos+' 位</span>':'')+bar(r)+'<div class="dim">'+esc(r.note)+(r.errs?' <span class="warn">（出错 '+r.errs+' 次）</span>':'')+'</div><div class="dim">'+(r.next&&r.state==='active'?'下次 '+new Date(r.next).toLocaleTimeString():'')+'</div></td>'+
   '<td class="mono" style="max-width:340px;word-break:break-all">'+esc(r.cur||'')+(r.item?'<div class="ok">'+esc(r.item)+'</div>':'')+'<div class="dim">规格 '+(r.tried+(r.cur?1:0))+' / '+r.vers+'</div></td>'+
   '<td>'+esc((r.users||[]).join('、'))+'</td><td style="white-space:nowrap"><button class="small" data-a="log" data-id="'+r.id+'">日志</button> '+acts+'</td></tr>'}).join('')||'<tr><td colspan="5" class="dim">还没有请求</td></tr>';
 $('log').innerHTML=s.logs.map(function(l){return '<div><span class="dim">'+new Date(l.at).toLocaleString()+'</span> '+(l.rid?'#'+l.rid+' ':'')+esc(l.msg)+'</div>'}).join('');
}
function load(){return api('state').then(function(s){show(true);render(s)}).catch(function(e){if(/口令/.test(e.message)){show(false);$('lerr').textContent=KEY?e.message:''}else alert(e.message)})}
$('enter').onclick=function(){KEY=$('key').value.trim();try{localStorage.setItem('tjkey',KEY)}catch(e){}load()};
$('key').onkeydown=function(e){if(e.key==='Enter')$('enter').click()};
$('logout').onclick=function(){KEY='';try{localStorage.removeItem('tjkey')}catch(e){}show(false)};
$('refresh').onclick=load;
$('tick').onclick=function(){this.disabled=true;var b=this;api('tick',{}).then(function(r){b.disabled=false;load()}).catch(function(e){b.disabled=false;alert(e.message)})};
$('savePk').onclick=function(){var u=$('pkUser').value.trim(),p=$('pkPass').value;if(!u&&!p)return;var body={};if(u)body.pkUser=u;if(p)body.pkPass=p;api('cfg',body).then(function(s){$('pkUser').value='';$('pkPass').value='';$('pkres').innerHTML='<span class="ok">已保存</span>';render(s)}).catch(function(e){$('pkres').innerHTML='<span class="bad">'+esc(e.message)+'</span>'})};
$('testPk').onclick=function(){$('pkres').textContent='…';api('pk',{}).then(function(r){$('pkres').innerHTML=r.ok?'<span class="ok">登录成功</span> '+(r.limit?(r.usage/1073741824).toFixed(1)+' / '+(r.limit/1073741824).toFixed(0)+' GB':'')+(r.auto?(r.auto.same?' · /auto 对得上':' <span class="bad">'+esc(r.auto.hint||r.auto.err||'')+'</span>'):''):'<span class="bad">'+esc(r.err||'')+'</span>'}).catch(function(e){$('pkres').innerHTML='<span class="bad">'+esc(e.message)+'</span>'})};
$('testLinks').onclick=function(){$('links').textContent='…';api('links',{}).then(function(r){$('links').innerHTML='影片库：'+(r.lb.ok?'<span class="ok">通</span> · PikPak '+esc(r.lb.pikpak):'<span class="bad">'+esc(r.lb.err)+'</span>')+'<br>传输：'+(r.transfer.ok?'<span class="ok">通</span> · rclone '+esc(r.transfer.rclone)+' · '+esc(r.transfer.core):'<span class="bad">'+esc(r.transfer.err)+'</span>')}).catch(function(e){$('links').textContent=e.message})};
$('saveCfg').onclick=function(){api('cfg',{tpl:$('tpl').value,lang:$('lang').value,grp:$('grp').value,userCap:$('userCap').value,globalCap:$('globalCap').value,pkSlots:$('pkSlots').value,vpsSlots:$('vpsSlots').value,paused:$('paused').checked}).then(function(s){$('cfgres').innerHTML='<span class="ok">已保存</span>';render(s)}).catch(function(e){$('cfgres').innerHTML='<span class="bad">'+esc(e.message)+'</span>'})};
$('add').onclick=function(){api('add',{src:$('addSrc').value,id:$('addId').value,season:$('addSeason').value}).then(function(r){$('addres').textContent=r.joined?'已经在进行中':'已添加';load()}).catch(function(e){$('addres').textContent=e.message})};
$('reqs').onclick=function(e){var b=e.target.closest('button[data-a]');if(!b)return;var a=b.dataset.a,id=+b.dataset.id;
 if(a==='log'){api('log?id='+id).then(function(r){alert(r.items.map(function(l){return new Date(l.at).toLocaleString()+'  '+l.msg}).join('\\n')||'没有日志')});return}
 if((a==='delete'||a==='cancel')&&!confirm(a==='delete'?'删除这条记录？':'取消这条请求？（PikPak 上下了一半的会删掉）'))return;
 api('req',{id:id,act:a}).then(load).catch(function(e){alert(e.message)})};
if(KEY)load();else show(false);
setInterval(function(){if(KEY&&!document.hidden&&!$('app').classList.contains('hide'))load()},15000);
</script></body></html>`;
