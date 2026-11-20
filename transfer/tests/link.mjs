// /api/link/* 的基本功能：口令、整理、完整性核对、改名、作业、复制、删除、发行检查（模拟 rclone rc）
import { pathToFileURL, fileURLToPath } from 'node:url';
import path from 'node:path';
const worker = (await import(pathToFileURL(path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'worker.js')).href)).default;

let pass = 0, fail = 0;
const ok = (c, n, x) => { if (c) pass++; else { fail++; console.log('✗', n, x !== undefined ? JSON.stringify(x) : ''); } };
const calls = [];
const DIR = '恐怖前任大全.第2季[全4集][简繁英字幕].Worst.Ex.Ever.S02.2160p.NF.WEB-DL-BlackTV';
const FS = {
  ['pikpak:auto/' + DIR]: [
    { Path: 'E01.mkv', Name: 'Worst.Ex.Ever.S02E01.mkv', Size: 100 }, { Path: 'E02.mkv', Name: 'Worst.Ex.Ever.S02E02.mkv', Size: 100 },
    { Path: 'E03.mkv', Name: 'Worst.Ex.Ever.S02E03.mkv', Size: 100 }, { Path: 'sub/最新地址.txt', Name: '最新地址.txt', Size: 1 }],
};
globalThis.fetch = async (url, init) => {
  const p = new URL(url).pathname.slice(1), b = JSON.parse(init.body || '{}');
  calls.push([p, b]);
  if (init.headers.Authorization !== 'Basic ' + btoa('admin:pw')) return new Response('no', { status: 401 });
  const okj = (o) => new Response(JSON.stringify(o), { status: 200 });
  switch (p) {
    case 'core/version': return okj({ version: 'v1.68' });
    case 'operations/list': return okj({ list: FS[b.fs] || [] });
    case 'operations/deletefile': case 'operations/mkdir': case 'operations/purge': return okj({});
    case 'sync/move': case 'sync/copy': case 'operations/copyfile': return okj({ jobid: 7 });
    case 'job/status': return okj({ finished: true, success: true, error: '' });
    case 'core/stats': return okj({ bytes: 300, totalBytes: 300 });
    case 'operations/stat': return okj({ item: b.remote === 'gone.mkv' ? null : { Size: 42 } });
  }
  return new Response('{"error":"unknown"}', { status: 404 });
};
const env = { LINK_KEY: 'k', VPS_PASS: 'pw' };
const call = async (p, b, key = 'k') => {
  const r = await worker.fetch(new Request('https://transfer.cuven.us/api/link/' + p, { method: 'POST', headers: { 'x-cuven-link': key }, body: JSON.stringify(b || {}) }), env);
  return [r.status, await r.json()];
};

let [s, j] = await call('ping', {}, 'bad');
ok(s === 401, '口令不对：401');
[s, j] = await call('ping');
ok(s === 200 && j.ok === 1 && j.version === 'v1.68', 'ping', j);
const off = await worker.fetch(new Request('https://transfer.cuven.us/api/link/ping', { method: 'POST', headers: { 'x-cuven-link': 'k' }, body: '{}' }), {});
ok(off.status === 404, '没配 LINK_KEY：整组接口关着');
[s, j] = await call('organize', { dir: DIR });
ok(s === 200 && j.files === 4 && j.deleted.length === 1 && j.deleted[0] === 'sub/最新地址.txt', '整理：只删广告文件', j);
[s, j] = await call('check', { dir: DIR });
ok(s === 200 && j.k === 'short' && j.total === 4 && j.miss.join() === '4', '完整性：全 4 集缺第 4 集', j);
[s, j] = await call('rename', { dir: DIR });
ok(s === 200 && j.name === 'Worst.Ex.Ever.S02.2160p.[Full-4][CN-HK-EN]-Cuven®' && j.jobid === 7, '改名：发行命名', j);
const mv = calls.find(([p]) => p === 'sync/move');
ok(mv && mv[1].srcFs === 'pikpak:auto/' + DIR && mv[1].dstFs === 'pikpak:auto/' + j.name && mv[1]._async === true, '改名走 pikpak: 后端、异步', mv);
[s, j] = await call('rename', { dir: '../x' });
ok(s === 400, '名字里有 .. / 斜杠：拒绝', j);
[s, j] = await call('job', { jobid: 7 });
ok(s === 200 && j.finished && j.success && j.total === 300, '作业进度', j);
[s, j] = await call('copy', { item: 'X', kind: 'dir' });
const cp = calls.find(([p]) => p === 'sync/copy');
ok(s === 200 && j.jobid === 7 && cp[1].srcFs === 'webdav:auto/X' && cp[1].dstFs === 'dropbox:auto/X', '复制文件夹：webdav → dropbox', cp);
[s, j] = await call('copy', { item: 'm.mkv', kind: 'file' });
ok(s === 200 && calls.some(([p, b]) => p === 'operations/copyfile' && b.srcRemote === 'm.mkv' && b.dstFs === 'dropbox:auto'), '复制单个文件');
[s, j] = await call('purge', { item: 'm.mkv', kind: 'file' });
ok(s === 200 && calls.some(([p, b]) => p === 'operations/deletefile' && b.fs === 'pikpak:auto' && b.remote === 'm.mkv'), '删 PikPak 那份');
[s, j] = await call('exists', { item: 'gone.mkv' });
ok(s === 200 && j.exists === 0, '发行检查：不在了', j);
[s, j] = await call('exists', { item: 'm.mkv' });
ok(s === 200 && j.exists === 1, '发行检查：还在', j);
const v = await worker.fetch(new Request('https://transfer.cuven.us/version'), env);
ok(/909/.test(await v.text()), '版本号 909');

console.log(`\n传输 Worker /api/link 基本功能：${pass} 项通过，${fail} 项失败`);
process.exit(fail ? 1 : 0);
