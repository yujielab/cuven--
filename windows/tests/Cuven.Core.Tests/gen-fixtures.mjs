// 用网页版 pair.js 本身算一份码纹理（第 0 个测试向量）+ 一份 PBKDF2（和网页版 keyOf 同一个算法），Windows 版的测试拿它比对
// node gen-fixtures.mjs  （仓库根目录下的 web/pair.js、pairing/model/cpc1-vectors.json）
import fs from 'node:fs';
import crypto from 'node:crypto';
import vm from 'node:vm';
const root = new URL('../../../', import.meta.url).pathname;
const src = fs.readFileSync(root + 'web/pair.js', 'utf8');
const ctx = { window: {}, Math, Float32Array, Uint8Array, Array };
vm.createContext(ctx); vm.runInContext(src, ctx);
const P = ctx.window.CuvenPair;
const v = JSON.parse(fs.readFileSync(root + 'pairing/model/cpc1-vectors.json', 'utf8'))[0];
const G = P.SPEC.codeGrid, m = P.modulationGrid(P.cellSigns(v.id, v.secret), G);
const px = Buffer.alloc(G * G);
for (let i = 0; i < m.length; i++) px[i] = Math.max(0, Math.min(255, Math.round(m[i] / P.SPEC.codeScale * 255)));
fs.writeFileSync('fixtures/grid0.bin', px);
const salt = crypto.randomBytes(16).toString('base64url');
const key = crypto.pbkdf2Sync('密码 Cuven-测试 123', Buffer.from(salt, 'base64url'), 310000, 32, 'sha256').toString('base64url');
fs.writeFileSync('fixtures/pbkdf2.json', JSON.stringify({ password: '密码 Cuven-测试 123', salt, iter: 310000, key }));
console.log('grid', G, 'pbkdf2', key);
