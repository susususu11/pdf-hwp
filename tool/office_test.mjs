// Office 표시 페이지를 Chromium의 휴대폰 크기 화면에서 검사한다.
// 사용법: node tool/office_test.mjs <샘플폴더> <출력폴더>
import { existsSync, readFileSync } from 'node:fs';
import { createServer } from 'node:http';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';
const require = createRequire('/opt/node22/lib/node_modules/');
const { chromium } = require('playwright');
const root = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'assets');
const [sampleDir, outDir] = process.argv.slice(2);
const types = { html: 'text/html; charset=utf-8', js: 'text/javascript', css: 'text/css' };
let current = '';
const reports = [];
const server = createServer((q, r) => {
  const p = q.url.split('?')[0];
  if (p === '/app/view-doc') return r.end(readFileSync(path.join(sampleDir, current)));
  if (p === '/app/view-ok' || p === '/app/view-fail') {
    let b = ''; q.on('data', (c) => (b += c)); q.on('end', () => { reports.push(`${current} ${p.slice(5)}: ${b}`); r.end(); }); return;
  }
  try {
    const f = path.join(root, p.replace('/app/', ''));
    r.writeHead(200, { 'content-type': types[f.split('.').pop()] ?? 'application/octet-stream' }).end(readFileSync(f));
  } catch { r.writeHead(404).end(); }
}).listen(0, '127.0.0.1');
await new Promise((ok) => server.once('listening', ok));
const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 390, height: 780 } });
page.on('pageerror', (e) => console.log('pageerror', e.message));
page.on('console', (m) => m.type() === 'error' && console.log('console', m.text().slice(0, 160)));
const cases = [['sample.docx', 'docx'], ['sample.xlsx', 'xlsx'], ['sample.pptx', 'pptx'], ['old.xls', 'xlsx'], ['big.xlsx', 'xlsx']].filter(([f]) => existsSync(path.join(sampleDir, f)));
for (const [file, kind] of cases) {
  current = file;
  await page.goto(`http://127.0.0.1:${server.address().port}/app/viewer/office.html?kind=${kind}&view=test`);
  await page.waitForFunction(() => document.getElementById('status').textContent !== '문서를 여는 중입니다');
  await page.waitForTimeout(300);
  const noScroll = await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1);
  console.log(kind, 'fitsWidth', noScroll);
  await page.screenshot({ path: path.join(outDir, `${file}.png`), fullPage: true });
}
console.log(reports.join('\n'));
await browser.close();
server.close();
