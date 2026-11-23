// tv.cuven.us（Worker：cuven-tv）：页面 + 光学配对的脚本和密度校正图。
// 三个文件作为模块打进 Worker（index.html / pair.js 是文本模块，pair-density.png 是二进制模块），
// 其余任何路径都回 index.html（和以前一样，单页应用）。
import HTML from './index.html';
import PAIR_JS from './pair.txt';
import DENSITY from './pair-density.png';

export default {
  async fetch(request) {
    const path = new URL(request.url).pathname;
    if (path === '/pair.js')
      return new Response(PAIR_JS, { headers: { 'content-type': 'text/javascript; charset=utf-8', 'cache-control': 'public, max-age=300' } });
    if (path === '/pair-density.png')
      return new Response(DENSITY, { headers: { 'content-type': 'image/png', 'cache-control': 'public, max-age=86400' } });
    return new Response(HTML, { headers: { 'content-type': 'text/html;charset=utf-8', 'cache-control': 'no-store' } });
  },
};
