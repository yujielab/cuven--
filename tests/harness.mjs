// 本地测试台：真实 Worker 代码（../Stream_v25.js）+ 模拟 Dropbox / Cache API。
// 模拟的 Dropbox 把 /Movies/<文件> 映射到 tests/samples/<文件>，下载按 64KB 一块回传（与真实网络分块相近）。
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { Readable } from 'node:stream';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
export const SAMPLES = path.join(HERE, 'samples');
export const SECRET = 'test-secret';
export const stats = { fetches: 0, bytes: 0, ranges: [] };
/**
 * 上游替身的开关：chunkDelayMs 每 64KB 一块之间停顿多少毫秒（测预取、等待这类时序）；
 * fail(file, start, end) 返回 true 的 Range 交完第一块就断流（测半路失败）
 */
export const net = { chunkDelayMs: 0, fail: null };
/**
 * OpenSubtitles 替身：登录 / 搜索 / 下载。subs 是候选（按 moviehash / tmdb_id / query 命中），
 * files 是 file_id → { text } 或 { bytes }；quota=true 时下载回 406；calls 记下每一次请求
 */
export const os = { calls: [], subs: [], files: {}, quota: false, loginOk: true };
/**
 * 剧集目录替身：entries 是 Dropbox 风格的文件条目（path_display / name / size / server_modified），
 * 递归列 /ram2 时按 pageSize 分页（0 = 一页给完）；lists 记下 list_folder 被调了几次
 */
export const tv = { entries: [], pageSize: 0, lists: 0 };
/** TMDB 替身：shows = [{ id, name, original, first, seasons: [{ n, air, count, eps: [{ zh, en, overview, still }] }] }] */
export const tmdb = { calls: [], shows: [], movies: [] };

class MemCache {
  constructor() { this.m = new Map(); }
  key(r) { return typeof r === 'string' ? r : r.url; }
  async match(r) { const e = this.m.get(this.key(r)); return e ? new Response(e.body.slice(0), { status: e.status, headers: e.headers }) : undefined; }
  // 与 workerd 一致：body 中途出错时 put 报错，但已经写进去的那一截照样落进缓存
  async put(r, res) {
    const chunks = [];
    let err = null;
    try { if (res.body) for await (const c of res.body) chunks.push(Buffer.from(c)); } catch (e) { err = e; }
    const b = Buffer.concat(chunks);
    this.m.set(this.key(r), { body: b.buffer.slice(b.byteOffset, b.byteOffset + b.length), status: res.status, headers: [...res.headers] });
    if (err) throw err;
  }
  async delete(r) { return this.m.delete(this.key(r)); }
}
globalThis.caches = { default: new MemCache() };

const localPath = p => path.join(SAMPLES, p.replace(/^\/Movies\/?/, ''));
const meta = p => {
  const st = fs.statSync(localPath(p));
  return { name: path.basename(p), path_display: p, size: st.size, rev: 'r' + Math.floor(st.mtimeMs),
    content_hash: crypto.createHash('sha1').update(p + st.mtimeMs).digest('hex') };
};
globalThis.fetch = async (input, init = {}) => {
  const req = input instanceof Request ? input : new Request(input, init);
  const u = new URL(req.url);
  if (u.host === 'api.dropboxapi.com' && u.pathname === '/oauth2/token') return Response.json({ access_token: 'tok', expires_in: 14400 });
  if (u.host === 'api.dropboxapi.com' && u.pathname === '/2/files/get_temporary_link') {
    const { path: p } = await req.json();
    if (!fs.existsSync(localPath(p))) return new Response('not found', { status: 409 });
    return Response.json({ link: 'https://dl.mock/f?p=' + encodeURIComponent(p), metadata: meta(p) });
  }
  if (u.host === 'api.dropboxapi.com' && (u.pathname === '/2/files/list_folder' || u.pathname === '/2/files/list_folder/continue')) {
    const body = await req.clone().json();
    const tvPage = from => {
      const all = tv.entries.filter(e => e.path_display.toLowerCase().startsWith(tv.prefix));
      const n = tv.pageSize || all.length || 1;
      const entries = all.slice(from, from + n).map(e => ({ '.tag': 'file', size: 1000, server_modified: '2026-01-01T00:00:00Z', ...e, name: e.path_display.split('/').pop() }));
      return Response.json({ entries, has_more: from + n < all.length, cursor: 'tv:' + (from + n) });
    };
    if (u.pathname.endsWith('/continue')) { tv.lists++; return tvPage(+String(body.cursor).slice(3)); }
    if (body.recursive) {
      tv.lists++;
      tv.prefix = String(body.path || '').toLowerCase() + '/';
      if (!tv.entries.some(e => e.path_display.toLowerCase().startsWith(tv.prefix)))
        return Response.json({ error_summary: 'path/not_found/..', error: { '.tag': 'path', path: { '.tag': 'not_found' } } }, { status: 409 });
      return tvPage(0);
    }
  }
  if (u.host === 'api.dropboxapi.com' && u.pathname === '/2/files/list_folder') {
    const { path: p } = await req.json();
    const dir = localPath(p || '/Movies');
    const entries = fs.readdirSync(dir).filter(f => fs.statSync(path.join(dir, f)).isFile())
      .map(f => ({ '.tag': 'file', ...meta(`${p || '/Movies'}/${f}`) }));
    return Response.json({ entries, has_more: false, cursor: 'c' });
  }
  if (u.host === 'api.opensubtitles.com') {
    const p = u.pathname.replace(/^\/api\/v1/, '');
    const body = req.method === 'POST' ? await req.clone().json().catch(() => null) : null;
    os.calls.push({ method: req.method, path: p, search: u.search.slice(1), q: Object.fromEntries(u.searchParams), body,
      key: req.headers.get('api-key'), ua: req.headers.get('user-agent'), auth: req.headers.get('authorization') });
    if (!req.headers.get('api-key')) return Response.json({ message: 'missing api key' }, { status: 401 });
    if (p === '/login') {
      return os.loginOk ? Response.json({ token: 'tok-os', base_url: 'api.opensubtitles.com', user: { allowed_downloads: 100 } })
        : Response.json({ message: 'bad credentials' }, { status: 401 });
    }
    if (p === '/subtitles') {
      const q = Object.fromEntries(u.searchParams), langs = (q.languages || '').split(',');
      const data = os.subs.filter(x => langs.includes(x.language) && (
        (q.moviehash && x.moviehash === q.moviehash) || (q.tmdb_id && String(x.tmdb_id) === q.tmdb_id) ||
        (q.query && (x.query || '').toLowerCase() === q.query)))
        .map(x => ({ id: String(x.id), type: 'subtitle', attributes: {
          language: x.language, download_count: x.downloads || 0, fps: x.fps || 0, release: x.release || '',
          moviehash_match: !!(q.moviehash && x.moviehash === q.moviehash), machine_translated: !!x.mt, ai_translated: !!x.ai,
          from_trusted: !!x.trusted, foreign_parts_only: !!x.fpo, hearing_impaired: false, feature_details: x.feature || {},
          files: [{ file_id: x.file_id, file_name: (x.release || 'sub') + '.srt' }] } }));
      return Response.json({ total_count: data.length, total_pages: 1, page: 1, per_page: 60, data });
    }
    if (p === '/download') {
      if (os.quota) return Response.json({ message: 'You have downloaded your allowed 20 subtitles for 24h', reset_time_utc: new Date(Date.now() + 3600e3).toISOString() }, { status: 406 });
      return Response.json({ link: `https://dl.os.mock/${body && body.file_id}.srt`, file_name: 'sub.srt', requests: 1, remaining: 99, message: '', reset_time: '', reset_time_utc: '' });
    }
    return Response.json({ message: 'not found' }, { status: 404 });
  }
  if (u.host === 'api.themoviedb.org') {
    const p = u.pathname.replace(/^\/3/, ''), q = Object.fromEntries(u.searchParams);
    tmdb.calls.push({ path: p, q });
    if (!q.api_key) return Response.json({ status_message: 'Invalid API key' }, { status: 401 });
    const show = id => tmdb.shows.find(x => String(x.id) === String(id));
    const brief = x => ({ id: x.id, name: q.language === 'zh-CN' ? x.name : x.original, original_name: x.original, first_air_date: x.first,
      poster_path: `/p${x.id}.jpg`, backdrop_path: `/b${x.id}.jpg`, overview: '', vote_average: 8 });
    if (p === '/search/tv') {
      const ql = (q.query || '').toLowerCase();
      const res = tmdb.shows.filter(x => [x.name, x.original].some(n => n && n.toLowerCase() === ql) &&
        (!q.year || x.first.startsWith(q.year) || x.seasons.some(se => (se.air || '').startsWith(q.year))));
      return Response.json({ results: res.map(brief) });
    }
    if (p === '/search/movie') {
      const ql = (q.query || '').toLowerCase();
      return Response.json({ results: tmdb.movies.filter(x => x.title.toLowerCase() === ql)
        .map(x => ({ id: x.id, title: x.title, release_date: x.date, poster_path: '/m.jpg', overview: '', vote_average: 7 })) });
    }
    let m = /^\/tv\/(\d+)$/.exec(p);
    if (m && show(m[1])) {
      const x = show(m[1]);
      return Response.json({ ...brief(x), seasons: x.seasons.map(se => ({ season_number: se.n, air_date: se.air, episode_count: se.count })),
        genres: [{ name: '剧情' }], episode_run_time: [50], external_ids: { imdb_id: 'tt' + x.id } });
    }
    m = /^\/tv\/(\d+)\/season\/(\d+)$/.exec(p);
    if (m && show(m[1])) {
      const se = show(m[1]).seasons.find(z => z.n === +m[2]);
      if (!se) return Response.json({ status_message: 'not found' }, { status: 404 });
      const zh = q.language === 'zh-CN';
      return Response.json({ name: `第 ${se.n} 季`, episodes: (se.eps || []).map((e, i) => ({ episode_number: i + 1,
        name: zh ? e.zh : e.en, overview: zh ? (e.overview || '') : 'EN: ' + e.en, still_path: e.still || null, runtime: 50, air_date: se.air })) });
    }
    m = /^\/tv\/(\d+)\/images$/.exec(p);
    if (m && show(m[1])) return Response.json({ logos: [{ file_path: '/logo.png', iso_639_1: 'zh', aspect_ratio: 3 }],
      posters: [{ file_path: '/titled.jpg', iso_639_1: 'en', vote_average: 9 }, { file_path: '/clean.jpg', iso_639_1: null, vote_average: 5 }], backdrops: [] });
    m = /^\/tv\/(\d+)\/credits$/.exec(p);
    if (m && show(m[1])) return Response.json({ cast: [], crew: [] });
    return Response.json({ status_message: 'not found' }, { status: 404 });
  }
  if (u.host === 'dl.os.mock') {
    const f = os.files[u.pathname.slice(1).replace(/\.srt$/, '')];
    if (!f) return new Response('gone', { status: 404 });
    return new Response(f.bytes || f.text, { headers: { 'Content-Type': 'application/x-subrip' } });
  }
  if (u.host === 'dl.mock') {
    const file = localPath(u.searchParams.get('p'));
    const size = fs.statSync(file).size;
    const m = /bytes=(\d+)-(\d*)/.exec(req.headers.get('Range') || '');
    const start = m ? +m[1] : 0, end = m && m[2] ? Math.min(size - 1, +m[2]) : size - 1;
    stats.fetches++; stats.bytes += end - start + 1; stats.ranges.push([path.basename(file), start, end]);
    let body = Readable.toWeb(fs.createReadStream(file, { start, end, highWaterMark: 65536 }));
    if (net.chunkDelayMs > 0) {
      const ms = net.chunkDelayMs;
      body = body.pipeThrough(new TransformStream({ async transform(c, ctl) { await new Promise(r => setTimeout(r, ms)); ctl.enqueue(c); } }));
    }
    if (net.fail && net.fail(path.basename(file), start, end)) {
      let n = 0;
      body = body.pipeThrough(new TransformStream({ transform(c, ctl) { if (n++) ctl.error(new Error('injected upstream failure')); else ctl.enqueue(c); } }));
    }
    return new Response(body, { status: m ? 206 : 200, headers: { 'Content-Range': `bytes ${start}-${end}/${size}` } });
  }
  return new Response('blocked in test', { status: 404 });
};

export const env = { AUTH_SECRET: SECRET, DROPBOX_REFRESH_TOKEN: 'x', DROPBOX_APP_KEY: 'x', DROPBOX_APP_SECRET: 'x', ROOT_FOLDER: '/Movies' };
export const pending = [];
export const ctx = { waitUntil(p) { pending.push(Promise.resolve(p).catch(() => {})); }, passThroughOnException() {} };
export const worker = (await import(path.join(HERE, '..', 'Stream_v25.js'))).default;

export function token(p) {
  const exp = Math.floor(Date.now() / 1000) + 3600;
  const sig = crypto.createHmac('sha256', SECRET).update(`${p}|${exp}`).digest('hex');
  return `${exp}.${sig}.${Buffer.from(p).toString('base64url')}`;
}
export const call = (url, method = 'GET', headers = {}, host = 'w.test') =>
  worker.fetch(new Request(`https://${host}${url}`, { method, headers }), env, ctx);

/** 把 ../audio-tx 作为 Service Binding 挂上（tx.wasm 存在时） */
export async function bindAudioTx() {
  const dir = path.join(HERE, '..', 'audio-tx');
  globalThis.__TX_WASM = new WebAssembly.Module(fs.readFileSync(path.join(dir, 'tx.wasm')));
  const src = fs.readFileSync(path.join(dir, 'worker.js'), 'utf8').replace("import wasm from './tx.wasm';", 'const wasm = globalThis.__TX_WASM;');
  fs.writeFileSync(path.join(HERE, '_txworker.mjs'), src);
  const tx = (await import(path.join(HERE, '_txworker.mjs'))).default;
  env.AUDIO_TX = { fetch: (url, init) => tx.fetch(new Request(url, init)) };
}

/** 取一个文件的全部 HLS 产物：主列表、各媒体列表、init+分段拼成的 mp4、字幕 VTT */
export async function dump(file, out) {
  fs.rmSync(out, { recursive: true, force: true });
  fs.mkdirSync(out, { recursive: true });
  const base = `/hls/${token(file)}/`;
  const master = await (await call(base + 'master.m3u8')).text();
  fs.writeFileSync(path.join(out, 'master.m3u8'), master);
  const uris = [...master.matchAll(/URI="([^"]+)"/g)].map(m => m[1])
    .concat(master.split('\n').filter(l => l && !l.startsWith('#')));
  const result = { master, playlists: {} };
  for (const u of uris) {
    const pl = await (await call(base + u)).text();
    const dir = u.replace(/[^/]+$/, ''), name = u.split('/').pop().replace('.m3u8', '');
    const map = /#EXT-X-MAP:URI="([^"]+)"/.exec(pl);
    const segs = pl.split('\n').filter(l => l && !l.startsWith('#'));
    const parts = [];
    if (map) parts.push(Buffer.from(await (await call(base + dir + map[1])).arrayBuffer()));
    for (const s of segs) {
      const r = await call(base + dir + s);
      if (r.status !== 200) throw new Error(`${u} ${s}: HTTP ${r.status} ${await r.text()}`);
      const b = Buffer.from(await r.arrayBuffer());
      if (s.endsWith('.vtt')) fs.writeFileSync(path.join(out, `${name}_${s.split('/').pop()}`), b);
      else parts.push(b);
    }
    if (parts.length) fs.writeFileSync(path.join(out, `${name}.mp4`), Buffer.concat(parts));
    result.playlists[name] = { text: pl, segments: segs.length };
  }
  await Promise.all(pending);
  return result;
}

/** 从 Worker 源码里取内部函数（RPU 解析等），给单元测试用 */
export async function internals() {
  const vm = await import('node:vm');
  const src = fs.readFileSync(path.join(HERE, '..', 'Stream_v25.js'), 'utf8')
    .replace(/^export default \{/m, 'globalThis.__worker = {') + '\n;globalThis.__k = { HLS_VER, HLS_IDX_CACHE };';
  const c = vm.createContext({ TextDecoder, TextEncoder, btoa, atob, console, Request, Response, Headers, URL,
    URLSearchParams, crypto: globalThis.crypto, setTimeout, clearTimeout, AbortController, ReadableStream,
    DecompressionStream, Blob, caches: globalThis.caches, fetch: globalThis.fetch });
  vm.runInContext(src, c);
  return c;
}
