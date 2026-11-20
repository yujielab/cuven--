import { pathToFileURL, fileURLToPath } from 'node:url';
import path from 'node:path';
const worker = (await import(pathToFileURL(path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'worker.js')).href)).default;
let pass = 0, fail = 0;
const ok = (c, n, x) => { if (c) pass++; else { fail++; console.log('✗', n, x !== undefined ? JSON.stringify(x) : ''); } };
const calls = [];
let plan = {};            // path -> array of statuses to return in order (then 200)
const cf = (status) => new Response('<html><title>' + status + ' | Cloudflare</title>cloudflare</html>', { status });
globalThis.fetch = async (url, init) => {
  const u = new URL(url), path = u.pathname.slice(1), body = JSON.parse(init.body || '{}');
  calls.push(u.hostname + ' ' + path);
  const q = plan[path];
  if (q && q.length) { const st = q.shift(); if (st === 'throw') throw new TypeError('Network connection lost'); return cf(st); }
  const okj = (o) => new Response(JSON.stringify(o), { status: 200 });
  switch (path) {
    case 'core/version': return okj({ version: 'v1.68' });
    case 'operations/mkdir': return okj({});
    case 'sync/copy': return okj({ jobid: 7 });
    case 'job/status': return body.jobid === 8 ? new Response('{"error":"job not found","status":500}', { status: 500 }) : okj({ finished: false, success: false });
    case 'core/stats': return okj({ bytes: 50, totalBytes: 100, speed: 1048576 });
    case 'operations/list': return okj({ list: [{ Name: 'A.mkv' }, { Name: 'B Dir' }] });
    case 'operations/stat': return okj({ item: body.remote === 'A.mkv' ? { Size: 1 } : null });
  }
  return new Response('{"error":"nope"}', { status: 404 });
};
const env = { LINK_KEY: 'k', VPS_PASS: 'pw' };
const call = async (p, b, e = env) => {
  const r = await worker.fetch(new Request('https://transfer.cuven.us/api/link/' + p, { method: 'POST', headers: { 'x-cuven-link': 'k' }, body: JSON.stringify(b || {}) }), e);
  return [r.status, await r.json()];
};
const n = (path) => calls.filter(c => c.endsWith(' ' + path)).length;

plan = { 'core/version': [523, 523] }; calls.length = 0;
let [s, j] = await call('ping');
ok(s === 200 && j.ok === 1 && n('core/version') === 3, '523 两次后第三次通：照常成功（重试 2 次）', { s, j, calls });

plan = { 'core/version': [523, 523, 523] }; calls.length = 0;
[s, j] = await call('ping');
ok(s === 502 && /523/.test(j.error) && /已自动重试 2 次/.test(j.error) && !/IP 不对，或机器已不存在/.test(j.error), '一直 523：重试 2 次后报，说法不再是「机器不存在」', j);

plan = { 'sync/copy': [523] }; calls.length = 0;
[s, j] = await call('copy', { item: 'X', kind: 'dir' });
ok(s === 200 && j.jobid === 7 && n('sync/copy') === 2, '开传输遇到 523（请求没送到）：重试一次就开成了', { j, calls });

plan = { 'sync/copy': [520] }; calls.length = 0;
[s, j] = await call('copy', { item: 'X', kind: 'dir' });
ok(s === 502 && n('sync/copy') === 1, '开传输遇到 520（可能已经送到）：不重试，免得开两次', { s, j, calls });

plan = { 'sync/copy': ['throw'] }; calls.length = 0;
[s, j] = await call('copy', { item: 'X', kind: 'dir' });
ok(s === 502 && n('sync/copy') === 1, '开传输时连接中途断：不重试', { s, calls });

plan = { 'job/status': ['throw', 520] }; calls.length = 0;
[s, j] = await call('job', { jobid: 7 });
ok(s === 200 && j.finished === false && j.bytes === 50 && n('job/status') === 3, '查作业（只读）：断线 / 520 都重试', { j, calls });

plan = {}; calls.length = 0;
[s, j] = await call('jobs', { ids: [7, 8, 7] });
ok(s === 200 && j.jobs['7'].total === 100 && j.jobs['8'].missing === 1 && n('job/status') === 2, '一次问一批作业；没了的回 missing', j);

[s, j] = await call('job', { jobid: 8 });
ok(s === 200 && j.missing === 1, '单个作业没了：200 + missing（不当成 VPS 出错）', { s, j });

calls.length = 0;
[s, j] = await call('exists', { items: ['A.mkv', 'C.mkv', 'B Dir', '../x'] });
ok(s === 200 && j.exists['A.mkv'] === 1 && j.exists['C.mkv'] === 0 && j.exists['B Dir'] === 1 && !('../x' in j.exists) && n('operations/list') === 1, '一次看一批在不在（列一次目录）', j);

[s, j] = await call('exists', { item: 'A.mkv' });
ok(s === 200 && j.exists === 1, '单个 exists 照旧能用', { s, j });

/* 备用入口：主入口 523 时第二次走 VPS_ALT */
plan = { 'core/version': [523] }; calls.length = 0;
[s, j] = await call('ping', {}, { ...env, VPS_ALT: 'vps2-direct.cuven.us' });
ok(s === 200 && calls[0].startsWith('vps2.cuven.us ') && calls[1].startsWith('vps2-direct.cuven.us '), '主入口 523：重试走 VPS_ALT', calls);

console.log(`\n传输 Worker 908：${pass} 项通过，${fail} 项失败`);
process.exit(fail ? 1 : 0);
