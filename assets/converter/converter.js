// 앱 안의 보이지 않는 WebView에서 실행된다.
// 127.0.0.1의 앱 내부 서버에서 문서를 받아 PDF로 바꾼 뒤 다시 앱으로 보낸다.
import { parseTextItems, countTextOverlaps, svgSize, buildPdf, OVERLAP_WARNING_CHARS } from './core.js';

const RENDER_SCALE = 2; // 96dpi 기준 2배. 올리면 선명해지지만 파일이 커진다.
const JPEG_QUALITY = 0.86;

async function svgToJpeg(svg) {
  const { width, height } = svgSize(svg);
  const url = URL.createObjectURL(new Blob([svg], { type: 'image/svg+xml' }));
  try {
    const img = new Image();
    await new Promise((resolve, reject) => {
      img.onload = resolve;
      img.onerror = () => reject(new Error('페이지 그림을 만들지 못했습니다'));
      img.src = url;
    });
    const canvas = document.createElement('canvas');
    canvas.width = Math.ceil(width * RENDER_SCALE);
    canvas.height = Math.ceil(height * RENDER_SCALE);
    const ctx = canvas.getContext('2d');
    ctx.fillStyle = '#fff';
    ctx.fillRect(0, 0, canvas.width, canvas.height);
    ctx.drawImage(img, 0, 0, canvas.width, canvas.height);
    const blob = await new Promise((r) => canvas.toBlob(r, 'image/jpeg', JPEG_QUALITY));
    return {
      jpeg: new Uint8Array(await blob.arrayBuffer()),
      pixelWidth: canvas.width,
      pixelHeight: canvas.height,
      widthPt: width * 0.75,
      heightPt: height * 0.75,
    };
  } finally {
    URL.revokeObjectURL(url);
  }
}

function installTextMeasure() {
  const ctx = document.createElement('canvas').getContext('2d');
  globalThis.measureTextWidth = (font, text) => {
    ctx.font = font;
    return ctx.measureText(text).width;
  };
}

function readText(doc, page) {
  try {
    return doc.getPageText(page);
  } catch {
    return '';
  }
}

export async function convert(rhwp, bytes, onProgress) {
  const doc = new rhwp.HwpDocument(bytes);
  try {
    const count = doc.pageCount();
    const pages = [];
    const pageTexts = [];
    const warningPages = [];
    for (let i = 0; i < count; i++) {
      const svg = doc.renderPageSvg(i);
      const { chars } = countTextOverlaps(parseTextItems(svg));
      if (chars >= OVERLAP_WARNING_CHARS) warningPages.push(i + 1);
      pages.push(await svgToJpeg(svg));
      pageTexts.push(readText(doc, i));
      onProgress?.(i + 1, count);
    }
    return { pdf: buildPdf(pages), meta: { pageCount: count, warningPages, pageTexts } };
  } finally {
    doc.free?.();
  }
}

async function main() {
  const report = (path, body) => fetch(path, { method: 'POST', body });
  try {
    installTextMeasure();
    const rhwp = await import('../rhwp/rhwp.js');
    await rhwp.default({ module_or_path: '../rhwp/rhwp_bg.wasm' });
    const res = await fetch('../doc');
    if (!res.ok) throw new Error('문서를 읽지 못했습니다');
    const bytes = new Uint8Array(await res.arrayBuffer());
    const { pdf, meta } = await convert(rhwp, bytes, (done, total) => {
      fetch(`../progress?done=${done}&total=${total}`, { method: 'POST' }).catch(() => {});
    });
    await report('../pdf', pdf);
    await report('../meta', JSON.stringify(meta));
  } catch (e) {
    await report('../error', String(e?.message ?? e)).catch(() => {});
  }
}

if (!globalThis.__CONVERTER_TEST__) main();
