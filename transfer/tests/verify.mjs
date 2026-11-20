import { pathToFileURL, fileURLToPath } from 'node:url';
import path from 'node:path';
const worker = (await import(pathToFileURL(path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'worker.js')).href)).default;
let pass = 0, fail = 0;
const ok = (c, n, x) => { if (c) pass++; else { fail++; console.log('✗', n, x !== undefined ? JSON.stringify(x) : ''); } };
const calls = [];
let TREE = {}, DOWN = {};
const okj = (o) => new Response(JSON.stringify(o), { status: 200 });
globalThis.fetch = async (url, init) => {
  const u = new URL(url), path = u.pathname.slice(1), b = JSON.parse(init.body || '{}');
  calls.push([path, b]);
  if (path === 'operations/list'){
    if (DOWN[b.fs]) return new Response('<html>523 cloudflare</html>', { status: DOWN[b.fs] });
    if (!(b.fs in TREE)) return new Response('{"error":"directory not found","status":404}', { status: 404 });
    return okj({ list: TREE[b.fs].map(([p, size]) => ({ Path: p, Name: p.split('/').pop(), Size: size })) });
  }
  if (path === 'operations/stat'){
    const all = TREE[b.fs] || [];
    const hit = all.find(([p]) => p === b.remote);
    return okj({ item: hit ? { Path: hit[0], Size: hit[1] } : null });
  }
  if (path === 'operations/mkdir') return okj({});
  if (path === 'sync/copy' || path === 'operations/copyfile') return okj({ jobid: 9 });
  return new Response('{"error":"nope"}', { status: 404 });
};
const env = { LINK_KEY: 'k', VPS_PASS: 'pw' };
const call = async (p, b) => {
  const r = await worker.fetch(new Request('https://transfer.cuven.us/api/link/' + p, { method: 'POST', headers: { 'x-cuven-link': 'k' }, body: JSON.stringify(b || {}) }), env);
  return [r.status, await r.json()];
};
const S = 'pikpak:auto/Show.S01', D = 'dropbox:auto/Show.S01';

/* 一致：大小写、Unicode 写法不同，Dropbox 多一个文件、少了系统文件和临时文件，都算一致 */
TREE = {
  [S]: [['Show.S01E01.mkv', 100], ['Show.S01E02.mkv', 200], ['Subs/Café.srt', 5], ['desktop.ini', 1], ['Show.S01E03.mkv.part', 7]],
  [D]: [['show.s01e01.mkv', 100], ['Show.S01E02.mkv', 200], ['Subs/Café.srt', 5], ['extra.nfo', 3]],
};
calls.length = 0;
let [s, j] = await call('verify', { item: 'Show.S01', kind: 'dir' });
ok(s === 200 && j.ok === 1 && j.extra === 1 && j.src.count === 3 && j.via === 'pikpak:', '大小写 / NFC 不同、Dropbox 多文件、系统 / 临时文件：一致', j);
ok(calls.some(([p, b]) => p === 'operations/list' && b.fs === S), '源头用原生 pikpak 后端列（不走 WebDAV）', calls.map(c => c[1].fs));
ok(!calls.some(([p]) => p === 'operations/size'), '不再用 operations/size 只比总数');

/* 缺文件、大小不对：说清楚是哪个 */
TREE[D] = [['Show.S01E01.mkv', 100], ['Subs/Café.srt', 4]];
[s, j] = await call('verify', { item: 'Show.S01', kind: 'dir' });
ok(s === 200 && j.ok === 0 && j.missingCount === 1 && j.missing[0] === 'Show.S01E02.mkv' && j.differCount === 1 && j.differ[0].src === 5 && j.differ[0].dst === 4,
   '缺了哪个、哪个大小不对都回出来', j);

/* Dropbox 那边还没有这个文件夹：全缺（不是出错） */
delete TREE[D];
[s, j] = await call('verify', { item: 'Show.S01', kind: 'dir' });
ok(s === 200 && j.ok === 0 && j.missingCount === 3, 'Dropbox 那边还没有：全缺', j);

/* 列失败：回 502（没核对成），不回 ok: 0 */
TREE[D] = [['Show.S01E01.mkv', 100]];
DOWN[D] = 523;
[s, j] = await call('verify', { item: 'Show.S01', kind: 'dir' });
ok(s === 502 && j.side === 'dst' && j.ok === undefined, 'Dropbox 那边一直列不出（523）：502 没核对成，不算不一致', { s, j });
DOWN = { [S]: 524 };
[s, j] = await call('verify', { item: 'Show.S01', kind: 'dir' });
ok(s === 502 && j.side === 'src', 'PikPak 那边列不出：502', { s, j });
DOWN = {};
delete TREE[S];
[s, j] = await call('verify', { item: 'Show.S01', kind: 'dir' });
ok(s === 422 && j.side === 'src', 'PikPak 那边文件夹不在了：422（逻辑错，不是网络）', { s, j });

/* 单个文件 */
TREE = { 'pikpak:auto': [['M.mkv', 900]], 'dropbox:auto': [['M.mkv', 900]] };
[s, j] = await call('verify', { item: 'M.mkv', kind: 'file' });
ok(s === 200 && j.ok === 1, '单个文件：大小一样就一致', j);
TREE['dropbox:auto'] = [['M.mkv', 899]];
[s, j] = await call('verify', { item: 'M.mkv', kind: 'file' });
ok(s === 200 && j.ok === 0 && j.differCount === 1, '单个文件：大小不对', j);
TREE['dropbox:auto'] = [];
[s, j] = await call('verify', { item: 'M.mkv', kind: 'file' });
ok(s === 200 && j.ok === 0 && j.missingCount === 1, '单个文件：Dropbox 那边没有', j);

/* 补传：改从原生 pikpak 后端、只按大小 */
calls.length = 0;
[s, j] = await call('copy', { item: 'Show.S01', kind: 'dir', from: 'pikpak', sizeOnly: 1 });
const sc = calls.find(([p]) => p === 'sync/copy');
ok(s === 200 && j.from === 'pikpak' && sc[1].srcFs === 'pikpak:auto/Show.S01' && sc[1]._config.SizeOnly === true, '补传：从原生 pikpak 后端、只按大小', sc);
calls.length = 0;
[s, j] = await call('copy', { item: 'Show.S01', kind: 'dir' });
const sc2 = calls.find(([p]) => p === 'sync/copy');
ok(sc2[1].srcFs === 'webdav:auto/Show.S01' && !sc2[1]._config, '平常还是从 WebDAV 传', sc2);

console.log(`\n传输 Worker 909 核对：${pass} 项通过，${fail} 项失败`);
process.exit(fail ? 1 : 0);
