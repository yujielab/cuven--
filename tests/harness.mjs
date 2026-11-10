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
export const stats = { fetches: 0, bytes: 0 };

class MemCache {
  constructor() { this.m = new Map(); }
  key(r) { return typeof r === 'string' ? r : r.url; }
  async match(r) { const e = this.m.get(this.key(r)); return e ? new Response(e.body.slice(0), { status: e.status, headers: e.headers }) : undefined; }
  async put(r, res) { this.m.set(this.key(r), { body: await res.arrayBuffer(), status: res.status, headers: [...res.headers] }); }
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
  if (u.host === 'api.dropboxapi.com' && u.pathname === '/2/files/list_folder') {
    const { path: p } = await req.json();
    const dir = localPath(p || '/Movies');
    const entries = fs.readdirSync(dir).filter(f => fs.statSync(path.join(dir, f)).isFile())
      .map(f => ({ '.tag': 'file', ...meta(`${p || '/Movies'}/${f}`) }));
    return Response.json({ entries, has_more: false, cursor: 'c' });
  }
  if (u.host === 'dl.mock') {
    const file = localPath(u.searchParams.get('p'));
    const size = fs.statSync(file).size;
    const m = /bytes=(\d+)-(\d*)/.exec(req.headers.get('Range') || '');
    const start = m ? +m[1] : 0, end = m && m[2] ? Math.min(size - 1, +m[2]) : size - 1;
    stats.fetches++; stats.bytes += end - start + 1;
    const body = Readable.toWeb(fs.createReadStream(file, { start, end, highWaterMark: 65536 }));
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
export const call = (url, method = 'GET', headers = {}) =>
  worker.fetch(new Request('https://w.test' + url, { method, headers }), env, ctx);

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
