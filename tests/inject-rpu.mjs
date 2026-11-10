// 把一个 RPU（.bin，起始码 + 转义负载）注入 Annex-B HEVC 每个访问单元末尾
import fs from 'node:fs';
const [,, inHevc, rpuBin, outHevc] = process.argv;
const d = new Uint8Array(fs.readFileSync(inHevc));
const r = new Uint8Array(fs.readFileSync(rpuBin));
const rpu = r.subarray(4);                     // 去掉 00 00 00 01
const nals = [];
for (let i = 0; i + 3 < d.length; i++) {
  if (d[i] === 0 && d[i + 1] === 0 && d[i + 2] === 1) { nals.push(i + 3); i += 2; }
}
const units = nals.map((s, k) => { let e = k + 1 < nals.length ? nals[k + 1] - 3 : d.length; while (e > s && d[e - 1] === 0) e--; return d.subarray(s, e); });
const out = [];
const push = u => { out.push(new Uint8Array([0, 0, 0, 1])); out.push(u); };
const rpuNal = new Uint8Array([0x7C, 0x01, ...rpu]);
const elNal = process.argv[5] ? new Uint8Array([0x7E, 0x01, 0x40, 0x01, 0x0C, 0x01, 0xFF, 0xFF, 0x01, 0x60, 0x00, 0x00, 0x03, 0x00, 0xB0, 0x00]) : null;
let inPic = false;
for (const u of units) {
  const type = (u[0] >> 1) & 0x3F;
  const vcl = type < 32;
  const firstSlice = vcl && (u[2] & 0x80);
  if ((firstSlice || (!vcl && type >= 32 && type <= 40 && type !== 38)) && inPic) { if (elNal) push(elNal); push(rpuNal); inPic = false; }
  push(u);
  if (vcl) inPic = true;
}
if (inPic) { if (elNal) push(elNal); push(rpuNal); }
fs.writeFileSync(outHevc, Buffer.concat(out.map(x => Buffer.from(x))));
console.log('units', units.length, '→', outHevc);
