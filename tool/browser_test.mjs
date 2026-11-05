// rhwp CLI가 만든 SVG로 WASM을 흉내 내어 변환 흐름을 Chromium에서 검사한다.
// 사용법: node tool/browser_test.mjs <svg폴더> <출력.pdf>
import { readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:http';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';
const require = createRequire('/opt/node22/lib/node_modules/');
const { chromium } = require('playwright');
const root = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'assets', 'converter');
const [svgDir, outPdf] = process.argv.slice(2);
const svgs = readdirSync(svgDir).filter((f) => f.endsWith('.svg')).sort().map((f) => readFileSync(path.join(svgDir, f), 'utf8'));
const server = createServer((q, r) => {
  const n = q.url.split('?')[0].replace('/app/', '');
  if (n === '/page.html') return r.writeHead(200, { 'content-type': 'text/html' }).end('<!doctype html><script>globalThis.__CONVERTER_TEST__=true</script>');
  if (n.startsWith('/svg/')) return r.writeHead(200, { 'content-type': 'text/plain; charset=utf-8' }).end(svgs[+n.slice(5)]);
  try { r.writeHead(200, { 'content-type': 'text/javascript' }).end(readFileSync(path.join(root, n))); } catch { r.writeHead(404).end(); }
}).listen(0, '127.0.0.1');
await new Promise((ok) => server.once('listening', ok));
const base = `http://127.0.0.1:${server.address().port}`;
const browser = await chromium.launch();
const page = await browser.newPage();
page.on('pageerror', (e) => console.log('pageerror', e.message));
await page.goto(`${base}/page.html`);
const out = await page.evaluate(async ({ base, n }) => {
  const { convert } = await import(`${base}/app/converter.js`);
  const texts = [];
  for (let i = 0; i < n; i++) texts.push(await (await fetch(`${base}/svg/${i}`)).text());
  const stub = { HwpDocument: class { pageCount() { return n; } renderPageSvg(i) { return texts[i]; } getPageTextLayout(i) { return JSON.stringify({ runs: [{ text: `page ${i + 1}`, x: 10, y: 10, w: 40, h: 12 }, { text: '표 안 글', x: 60, y: 10, w: 40, h: 12 }, { text: '다음 줄', x: 10, y: 30, w: 40, h: 12 }] }); } free() {} } };
  const progress = [];
  const t = performance.now();
  const { pdf, meta } = await convert(stub, new Uint8Array(1), (d, c) => progress.push(`${d}/${c}`));
  let bin = ''; for (let i = 0; i < pdf.length; i += 32768) bin += String.fromCharCode(...pdf.subarray(i, i + 32768));
  return { b64: btoa(bin), meta, progress, ms: Math.round(performance.now() - t) };
}, { base, n: svgs.length });
writeFileSync(outPdf, Buffer.from(out.b64, 'base64'));
console.log(JSON.stringify({ ms: out.ms, progress: out.progress, warningPages: out.meta.warningPages, pageTexts: out.meta.pageTexts }));
await browser.close();
server.close();
