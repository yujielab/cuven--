// 索引库 Worker 的本地测试台：真实 Worker 代码（../worker.js）+ 模拟 R2 / KV / 论坛 / TMDB / 总账。
// 每个 isolate() 是一个全新的 vm 上下文（模块级状态各自独立），可以共用同一套 R2 / KV —— 用来模拟
// 多个 isolate 并发、以及「被平台掐掉之后换一个 isolate 接着跑」。
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
export const SRC_FILE = path.join(HERE, '..', 'worker.js');

/* ── GBK 编码（论坛页面是 GBK）：用 TextDecoder('gbk') 反查出一张表 ── */
let GBK = null;
export function gbk(str) {
  if (!GBK) {
    GBK = new Map();
    const d = new TextDecoder('gbk');
    for (let l = 0x81; l <= 0xfe; l++) for (let t = 0x40; t <= 0xfe; t++) {
      if (t === 0x7f) continue;
      const ch = d.decode(new Uint8Array([l, t]));
      if (ch.length === 1 && ch !== '�' && !GBK.has(ch)) GBK.set(ch, [l, t]);
    }
  }
  const out = [];
  for (const ch of str) {
    const c = ch.codePointAt(0);
    if (c < 0x80) { out.push(c); continue; }
    const p = GBK.get(ch);
    if (p) out.push(p[0], p[1]); else out.push(0x3f);
  }
  return new Uint8Array(out);
}

/* ── R2 ──
   faults：
     putFail(key, n)  → 返回 true 时这次 put 抛错（模拟限流 / 网络）
     getFail(key)     → 返回 'get' 时 get 抛错；'body' 时 body 读到一半抛错
     dieAfter         → 第 N 次写（put / delete）之后整个「isolate」被掐：之后的写全部抛错 */
export class R2 {
  constructor() { this.m = new Map(); this.puts = 0; this.gets = 0; this.dels = 0; this.writes = 0; this.log = []; this.f = {}; this.dead = false; }
  _etag() { return crypto.randomBytes(8).toString('hex'); }
  async get(key) {
    this.gets++;
    const f = this.f.getFail && this.f.getFail(key);
    if (f === 'get') throw new Error('R2 get 网络错误（模拟）');
    const e = this.m.get(key);
    if (!e) return null;
    const body = e.body;
    return {
      key, etag: e.etag, size: body.length,
      async text() { if (f === 'body') throw new Error('R2 body 读取中断（模拟）'); return body; },
      async json() { if (f === 'body') throw new Error('R2 body 读取中断（模拟）'); return JSON.parse(body); },
      async arrayBuffer() { return new TextEncoder().encode(body).buffer; },
    };
  }
  async list(opt = {}) {
    const pre = opt.prefix || '', lim = Math.min(1000, opt.limit || 1000);
    const all = [...this.m.keys()].filter(k => k.startsWith(pre)).sort();
    const start = opt.cursor ? Number(opt.cursor) : 0;
    const page = all.slice(start, start + lim);
    return { objects: page.map(k => ({ key: k, uploaded: this.m.get(k).uploaded || new Date(0), size: this.m.get(k).body.length })),
             truncated: start + lim < all.length, cursor: String(start + lim) };
  }
  async head(key) { const e = this.m.get(key); return e ? { key, etag: e.etag, size: e.body.length } : null; }
  async put(key, body, opt) {
    this._write('put', key);
    this.puts++;
    if (this.f.putFail && this.f.putFail(key, this.puts)) throw new Error('Reduce your concurrent request rate for the same object. (10058)');
    const s = typeof body === 'string' ? body : new TextDecoder().decode(body);
    const cur = this.m.get(key);
    const oi = opt && opt.onlyIf;
    if (oi) {
      if (oi.etagMatches != null && (!cur || cur.etag !== oi.etagMatches)) return null;
      if (oi.etagDoesNotMatch === '*' && cur) return null;
    }
    const etag = this._etag();
    this.m.set(key, { body: s, etag, uploaded: new Date(Date.now() + (this.clockOff || 0)) });
    this.log.push(['put', key]);
    return { key, etag };
  }
  async delete(keys) {
    for (const k of Array.isArray(keys) ? keys : [keys]) { this._write('delete', k); this.dels++; this.m.delete(k); this.log.push(['del', k]); }
  }
  _write(op, key) {
    if (this.dead) throw new Error('isolate 已被平台掐掉（模拟），' + op + ' ' + key + ' 没有执行');
    this.writes++;
    if (this.f.dieAfter != null && this.writes > this.f.dieAfter) { this.dead = true; throw new Error('isolate 被平台掐掉（模拟，第 ' + this.writes + ' 次写）'); }
  }
  json(key) { const e = this.m.get(key); return e ? JSON.parse(e.body) : null; }
  keys(pre = '') { return [...this.m.keys()].filter(k => k.startsWith(pre)).sort(); }
  snapshot() { return new Map([...this.m].map(([k, v]) => [k, { ...v }])); }
}

export class KV {
  constructor() { this.m = new Map(); this.puts = 0; }
  async get(k) { const e = this.m.get(k); return e ? e.v : null; }
  async put(k, v) { this.puts++; this.m.set(k, { v: String(v) }); }
  async delete(k) { this.m.delete(k); }
}

class MemCache {
  constructor() { this.m = new Map(); }
  async match(r) { const e = this.m.get(typeof r === 'string' ? r : r.url); return e ? new Response(e.body, { status: e.status, headers: e.headers }) : undefined; }
  async put(r, res) { const body = await res.arrayBuffer(); this.m.set(typeof r === 'string' ? r : r.url, { body, status: res.status, headers: [...res.headers] }); }
}

/* ── 外部世界 ──
   forum：{ base, boards: { [fid]: { [ykey=yid]: [ {tid,title} ...] } }, threads: { tid: { attach: [{aid,name,bytes}], magnets: [] } }, perPage }
   tmdb：{ movie: [ {id,title,original_title,release_date,poster_path,popularity,vote_average,vote_count} ], tv: [...] }
   recv：{ base, meta, doc } */
export function world() {
  return {
    /* encByFid：某个版块的页面编码（'utf8' = UTF-8 并在响应头里声明；'utf8-bare' = UTF-8 但不声明；默认 GBK） */
    forum: { base: 'https://forum.test/', boards: {}, threads: {}, perPage: 20, calls: 0, fail: null, slow: 0, encByFid: {} },
    tmdb: { movie: [], tv: [], calls: 0, fail: null },
    /* recv：公开 R2 域名。总账（Stream v22）+ v25 的实时清单（files = file-list-v2.json、tv = tv/list-v1.json、ptr = lib-ptr.json）
       hits：按路径记的请求次数 */
    recv: { base: 'https://recv.test', meta: null, doc: null, files: null, tv: null, ptr: null, calls: 0, hits: {}, fail: null },
    /* stream：Stream v25 的接口（登录门后面）。key = AUTH_SECRET；files / tv / gen 同上 */
    stream: { base: 'https://stream.test', key: 'stream-secret', files: null, tv: null, gen: null, calls: 0, logins: 0, fail: null },
    img: { calls: 0, fail: false },
  };
}

const norm = s => String(s || '').normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase().replace(/[^a-z0-9一-龥]/g, '');
const pad = html => html + '<!--' + 'x'.repeat(1200) + '-->';

function forumPage(W, u) {
  const F = W.forum;
  const q = u.searchParams;
  if (u.pathname.endsWith('member.php')) {
    if (q.get('loginsubmit') === 'yes') {
      return new Response(gbk('<root><![CDATA[欢迎您回来，测试用户]]></root>'), { headers: { 'set-cookie': 'auth=ok; path=/' } });
    }
    return new Response(gbk(pad('<form><input name="formhash" value="fh123"><a href="x?loginhash=lh456">登录</a></form>')), { headers: { 'set-cookie': 'sid=1; path=/' } });
  }
  if (q.get('mod') === 'forumdisplay') {
    const fid = q.get('fid');
    const board = F.boards[fid] || {};
    const ykey = [...q.keys()].find(k => k in board) || Object.keys(board).find(k => q.get(k.split('=')[0]) === k.split('=')[1]);
    let list = [];
    for (const k of Object.keys(board)) { const [kk, vv] = k.split('='); if (q.get(kk) === vv) list = board[k]; }
    const pg = Number(q.get('page') || 1);
    const per = F.perPage;
    const last = Math.max(1, Math.ceil(list.length / per));
    const rows = list.slice((pg - 1) * per, pg * per);
    let html = '<div id="threadlist" class="th">forumdisplay';
    for (const r of rows) html += `<a href="${r.tid}_1.html" title="${r.title.replace(/"/g, '&quot;')}">x</a>\n`;
    html += `<a href="list_${fid}_${last}.html" class="last">... ${last}</a></div>`;
    void ykey;
    const enc = F.encByFid && F.encByFid[fid];
    if (enc === 'utf8') return new Response(new TextEncoder().encode(pad(html)), { headers: { 'content-type': 'text/html; charset=utf-8' } });
    if (enc === 'utf8-bare') return new Response(new TextEncoder().encode(pad(html)), { headers: { 'content-type': 'text/html' } });
    return new Response(gbk(pad(html)));
  }
  /* 论坛搜索（Discuz search.php）：srchtxt 是 GBK 百分号编码；空格 = AND；限频；302 到 searchid 结果页；每页 F.searchPer 条 */
  if (u.pathname.endsWith('search.php')) {
    F.searches = F.searches || {}; F.searchLog = F.searchLog || [];
    const per = F.searchPer || 20;
    if (q.get('searchid')) {
      const S = F.searches[q.get('searchid')];
      if (!S) return new Response(gbk(pad('<div id="messagetext"><p>指定的搜索不存在或已过期</p></div>')));
      const pg = Number(q.get('page') || 1), last = Math.max(1, Math.ceil(S.list.length / per));
      const hl = (t) => { const k = S.tok[0]; const i = k ? t.toLowerCase().indexOf(k.toLowerCase()) : -1; return i < 0 ? t : t.slice(0, i) + '<strong><font color="#ff0000">' + t.slice(i, i + k.length) + '</font></strong>' + t.slice(i + k.length); };
      let html = `<div class="tl"><div class="sttl mbn"><h2>结果: <em>找到 “<span class="emfont">${S.kw}</span>” 相关内容 ${S.list.length} 个</em></h2></div><div class="slst mtw" id="threadlist"><ul>`;
      if (!S.list.length) html += '<p class="emp xg2 xs2">对不起，没有找到匹配结果。</p>';
      for (const t of S.list.slice((pg - 1) * per, pg * per))
        html += `<li class="pbw" id="${t.tid}"><h3 class="xs3"><a href="forum.php?mod=viewthread&amp;tid=${t.tid}&amp;highlight=x" target="_blank" ><font color="#FF0000">${hl(t.title)}</font></a></h3><p class="xg1">0 个回复 - 679 次查看</p><p>◎标　　题　${t.title.slice(0, 8)} ◎年　　代　2026</p><p><span>2026-9-16 12:34</span> - <span><a href="home.php?mod=space&amp;uid=2" target="_blank">HDTV</a></span> - <span><a href="forum.php?mod=forumdisplay&amp;fid=${t.fid}" target="_blank" class="xi1">高清剧集网</a></span></p></li>`;
      html += '</ul></div><div class="pgs cl mbm"><div class="pg">';
      for (let i = 1; i <= last; i++) html += `<a href="search.php?mod=forum&amp;searchid=${q.get('searchid')}&amp;orderby=lastpost&amp;ascdesc=desc&amp;searchsubmit=yes&amp;page=${i}">${i}</a>`;
      return new Response(gbk(pad(html + '</div></div></div>')));
    }
    const raw = (/[?&]srchtxt=([^&]*)/.exec(u.search) || [])[1];
    if (raw != null && q.get('searchsubmit')) {
      const bytes = []; for (let i = 0; i < raw.length; i++) { if (raw[i] === '%') { bytes.push(parseInt(raw.slice(i + 1, i + 3), 16)); i += 2; } else bytes.push(raw.charCodeAt(i) === 43 ? 32 : raw.charCodeAt(i)); }
      const kw = new TextDecoder('gbk').decode(new Uint8Array(bytes));
      const now = Date.now();
      if (F.searchGap && now - (F.lastSearch || 0) < F.searchGap * 1000) {
        F.searchLog.push({ kw, blocked: 1 });
        return new Response(gbk(pad(`<div id="messagetext" class="alert_error"><p>抱歉，您在 ${F.searchGap} 秒内只能进行一次搜索</p></div>`)));
      }
      F.lastSearch = now; F.searchLog.push({ kw });
      const tok = kw.split(/\s+/).filter(Boolean);
      const all = [];
      for (const [fid, b] of Object.entries(F.boards)) for (const list of Object.values(b)) for (const t of list) all.push({ ...t, fid: Number(fid) });
      for (const t of F.searchOnly || []) all.push(t);
      const list = all.filter(t => tok.every(k => t.title.toLowerCase().includes(k.toLowerCase()))).sort((a, b) => b.tid - a.tid);
      const id = (F.sid = (F.sid || 24730) + 1);
      F.searches[id] = { kw, tok, list };
      return new Response('', { status: 302, headers: { location: 'search.php?mod=forum&searchid=' + id + '&orderby=lastpost&ascdesc=desc&searchsubmit=yes&kw=' + encodeURIComponent(kw) } });
    }
    return new Response(gbk(pad('<form id="scform">搜索</form>')));
  }
  if (q.get('mod') === 'viewthread') {
    const t = F.threads[q.get('tid')] || { attach: [], magnets: [] };
    let html = '<div class="t_f">◎文件大小 10 GB<br>';
    for (const a of t.attach || []) html += `<a href="forum.php?mod=attachment&amp;aid=${a.aid}" target="_blank">${a.name} (12 KB)</a>`;
    for (const m of t.magnets || []) html += ` ${m} `;
    return new Response(gbk(pad(html + '</div>')));
  }
  if (q.get('mod') === 'attachment') {
    for (const t of Object.values(F.threads)) for (const a of t.attach || []) if (String(a.aid) === q.get('aid')) return new Response(a.bytes);
    return new Response(gbk(pad('<p>附件不存在</p>')));
  }
  return new Response('not found', { status: 404 });
}

function tmdbApi(W, u) {
  const T = W.tmdb;
  const m = /^\/3\/(search\/)?(movie|tv)(?:\/(\d+))?/.exec(u.pathname);
  if (!m) return Response.json({ results: [] });
  const kind = m[2];
  const db = T[kind] || [];
  if (m[3]) {
    const it = db.find(x => String(x.id) === m[3]);
    return it ? Response.json({ ...it, overview: 'x', genres: [], external_ids: {} }) : new Response('{}', { status: 404 });
  }
  const q = norm(u.searchParams.get('query'));
  const yk = kind === 'movie' ? 'primary_release_year' : 'first_air_date_year';
  const yr = u.searchParams.get(yk);
  const en = /^en/.test(u.searchParams.get('language') || '');
  const res = db.filter(x => {
    /* noZh：TMDB 上没有中文译名 —— 中文名搜不到它，中文结果里的标题是原名 */
    const names = (x.noZh ? [x.original_title, x.original_name, x.en, ...(x.aka || [])] : [x.title, x.original_title, x.name, x.original_name, x.en, ...(x.aka || [])]).map(norm).filter(Boolean);
    /* strict：只认「查询串是某个名字的一部分」（真 TMDB 按词搜，「A/B」两个译名连在一起的查询搜不到） */
    if (!names.some(n => n.includes(q) || (!x.strict && q.includes(n) && n.length >= 2))) return false;
    if (yr) { const d = x.release_date || x.first_air_date || ''; if (d.slice(0, 4) !== yr) return false; }
    return true;
  });
  return Response.json({ results: res.slice(0, 20).map(x => (en && x.en) ? { ...x, title: x.en, name: x.en }
    : (!en && x.noZh) ? { ...x, title: x.original_title || x.title, name: x.original_name || x.name } : x) });
}
/** 公开 R2 域名上的对象（总账 + v25 实时清单） */
function recvObj(W, url) {
  const R = W.recv, p = url.pathname;
  R.hits[p] = (R.hits[p] || 0) + 1;
  const pick = p.endsWith('/lib-ptr.json') ? R.ptr : p.endsWith('/file-list-v2.json') ? R.files : p.endsWith('/tv/list-v1.json') ? R.tv
    : p.endsWith('Received.meta.json') || p.endsWith('/meta.json') ? R.meta : p.endsWith('Received.json') ? R.doc : null;
  return pick ? Response.json(pick) : new Response('nf', { status: 404 });
}
/** Stream v25：POST /auth 换 cookie，接口要 cookie */
function streamApiMock(W, url, init) {
  const S = W.stream;
  if (url.pathname === '/auth') {
    const body = String((init && init.body) || '');
    const key = new URLSearchParams(body).get('key');
    if (key === S.key) { S.logins++; return new Response(null, { status: 302, headers: { location: '/', 'set-cookie': 'auth=tok-' + S.logins + '; Path=/; HttpOnly' } }); }
    return new Response('bad key', { status: 401 });
  }
  const ck = String((init && init.headers && (init.headers.cookie || init.headers.Cookie)) || '');
  if (!/auth=tok-\d+/.test(ck)) return new Response('<html>login</html>', { status: 401, headers: { 'content-type': 'text/html' } });
  if (url.pathname === '/api/all') return S.files ? Response.json({ root: S.files.root, videos: S.files.videos, folders: [] }) : new Response('{}', { status: 503 });
  if (url.pathname === '/api/tv') return S.tv ? Response.json({ root: '/ram2', at: S.tv.at, series: S.tv.series }) : new Response('{}', { status: 503 });
  if (url.pathname === '/api/gen') return Response.json({ gen: S.gen || '', count: S.files ? S.files.videos.length : 0, ts: Date.now() });
  return new Response('nf', { status: 404 });
}

/** 模拟的外部世界（给真 workerd 测试用的本地 HTTP 服务也走这里）。返回 Response 或 null（不认识的主机） */
export async function worldFetch(W, url) {
  if (url.pathname.startsWith('/3/')) return tmdbApi(W, url);
  /* workerd 测试里论坛与总账挂在同一个本地端口上：先按论坛的路径前缀分 */
  if (url.href.startsWith(W.forum.base)) return forumPage(W, url);
  if (url.host === new URL(W.recv.base).host) return recvObj(W, url);
  if (url.host === new URL(W.forum.base).host) return forumPage(W, url);
  return null;
}

/** 一个全新的 isolate：vm 上下文 + 共享的 env / world */
export function isolate(env, W, opt = {}) {
  const clock = { off: 0 };
  class FakeDate extends Date {
    constructor(...a) { if (a.length) super(...a); else super(Date.now() + clock.off); }
    static now() { return Date.now() + clock.off; }
  }
  const fast = opt.realTime ? setTimeout : (fn, ms, ...a) => setTimeout(fn, Math.min(ms || 0, opt.maxSleep ?? 2), ...a);
  const fetchMock = async (input, init = {}) => {
    const url = new URL(typeof input === 'string' ? input : input.url);
    if (init.signal && init.signal.aborted) throw new DOMException('aborted', 'AbortError');
    if (url.host === new URL(W.forum.base).host) {
      W.forum.calls++;
      if (W.forum.fail) { let r = W.forum.fail(url, init); if (r && typeof r.then === 'function') r = await r; if (r) { if (r instanceof Response) return r; throw r; } }
      return forumPage(W, url);
    }
    if (url.host === 'api.themoviedb.org') {
      W.tmdb.calls++;
      if (W.tmdb.fail) { let r = W.tmdb.fail(url); if (r && typeof r.then === 'function') r = await r; if (r) { if (r instanceof Response) return r; throw r; } }
      return tmdbApi(W, url);
    }
    if (url.host === new URL(W.recv.base).host) {
      W.recv.calls++;
      if (W.recv.fail) { let r = W.recv.fail(url); if (r && typeof r.then === 'function') r = await r; if (r) { if (r instanceof Response) return r; throw r; } }
      return recvObj(W, url);
    }
    if (url.host === new URL(W.stream.base).host) {
      W.stream.calls++;
      if (W.stream.fail) { let r = W.stream.fail(url); if (r && typeof r.then === 'function') r = await r; if (r) { if (r instanceof Response) return r; throw r; } }
      return streamApiMock(W, url, init);
    }
    if (url.host === 'image.tmdb.org') {
      W.img.calls++;
      if (W.img.fail) throw new TypeError('fetch failed');
      return new Response(new Uint8Array([0xff, 0xd8, 0xff]), { headers: { 'content-type': 'image/jpeg' } });
    }
    throw new TypeError('fetch failed: 没有模拟 ' + url.host);
  };
  const caches = { default: opt.cache || new MemCache() };
  const ctxObj = {
    TextDecoder, TextEncoder, btoa, atob, console: opt.quiet === false ? console : { log() {}, error() {}, warn() {} },
    Request, Response, Headers, URL, URLSearchParams, crypto: globalThis.crypto, AbortController, AbortSignal,
    setTimeout: fast, clearTimeout, setInterval, clearInterval, queueMicrotask, structuredClone,
    Date: FakeDate, Math, JSON, Promise, Map, Set, WeakMap, Array, Object, String, Number, Boolean, RegExp, Error, TypeError,
    Uint8Array, Uint32Array, Int8Array, Int32Array, Float64Array, ArrayBuffer, DataView, Symbol, BigInt, Intl, DOMException,
    ReadableStream, Blob, performance, caches, fetch: fetchMock,
  };
  const c = vm.createContext(ctxObj);
  const src = fs.readFileSync(opt.file || SRC_FILE, 'utf8')
    .replace(/^export default \{/m, 'globalThis.__worker = {')
    + '\n;globalThis.__k = (() => { const o = {}; for (const n of ' + JSON.stringify(opt.expose || []) + ') { try { o[n] = eval(n); } catch {} } return o; })();'
    + '\n;globalThis.__set = (n, v) => eval(n + " = v");';
  vm.runInContext(src, c, { filename: 'worker.js' });
  const pending = [];
  const ctx = { waitUntil(p) { pending.push(Promise.resolve(p).catch(() => {})); }, passThroughOnException() {} };
  const call = async (pathq, init = {}) => {
    const req = new Request('https://idx.test' + pathq, init);
    return c.__worker.fetch(req, env, ctx);
  };
  const settle = async () => { while (pending.length) await Promise.all(pending.splice(0)); };
  return { c, X: c, k: c.__k, call, settle, ctx, clock, caches, cron: async () => { await c.__worker.scheduled({}, env, ctx); await settle(); } };
}

export function makeEnv(extra = {}) {
  const r2 = new R2(), kv = new KV();
  const W = world();
  const env = { R2: r2, KV: kv, SITE_USER: 'u', SITE_PASS: 'p', TMDB_KEY: 'k', SITE_BASE: W.forum.base, ...extra };
  return { env, r2, kv, W };
}

/* ── 种子（bencode）── */
export function benc(v) {
  if (typeof v === 'number') return Buffer.from('i' + v + 'e');
  if (Buffer.isBuffer(v)) return Buffer.concat([Buffer.from(v.length + ':'), v]);
  if (typeof v === 'string') { const b = Buffer.from(v); return Buffer.concat([Buffer.from(b.length + ':'), b]); }
  if (Array.isArray(v)) return Buffer.concat([Buffer.from('l'), ...v.map(benc), Buffer.from('e')]);
  const keys = Object.keys(v).sort();
  return Buffer.concat([Buffer.from('d'), ...keys.flatMap(k => [benc(k), benc(v[k])]), Buffer.from('e')]);
}
export function torrent(info, extra = {}) {
  const t = benc({ announce: 'udp://tracker.test:80/announce', ...extra, info });
  const ib = benc(info);
  return { bytes: new Uint8Array(t), btih: crypto.createHash('sha1').update(ib).digest('hex') };
}
