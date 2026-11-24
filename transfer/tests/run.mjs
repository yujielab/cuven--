// 传输 Worker 回归测试：node transfer/tests/run.mjs
// 不需要网络、不需要 VPS：rclone rc 全部模拟。四组各自换一套模拟的 fetch，所以分开跑
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
const here = path.dirname(fileURLToPath(import.meta.url));
let bad = 0;
for (const f of ['link.mjs', 'retry.mjs', 'verify.mjs', 'batch.mjs']) {
  try { process.stdout.write(execFileSync(process.execPath, [path.join(here, f)], { encoding: 'utf8' }).split('\n').filter(l => l.trim()).pop() + '\n'); }
  catch (e) { bad++; process.stdout.write((e.stdout || '') + (e.stderr || '')); }
}
process.exit(bad ? 1 : 0);
