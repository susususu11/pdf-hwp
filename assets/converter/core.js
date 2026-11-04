// DOM에 의존하지 않는 순수 로직. 앱(WebView)과 Node 시험에서 함께 쓴다.

const TEXT_RE = /<text\b([^>]*)>([^<]*)<\/text>/g;
const attr = (s, n) => {
  const m = s.match(new RegExp(`\\b${n}="([^"]*)"`));
  return m ? m[1] : null;
};

/** SVG 문자열에서 글자 위치 목록을 뽑는다. 회전된 글자는 위치를 알 수 없어 제외한다. */
export function parseTextItems(svg) {
  const items = [];
  for (const m of svg.matchAll(TEXT_RE)) {
    const [, a, raw] = m;
    const ch = raw.trim();
    if (!ch || attr(a, 'transform')) continue;
    const x = parseFloat(attr(a, 'x'));
    const y = parseFloat(attr(a, 'y'));
    const fs = parseFloat(attr(a, 'font-size'));
    if (![x, y, fs].every(Number.isFinite) || fs <= 0) continue;
    items.push({ x, y, fs, ch });
  }
  return items;
}

const glyphWidth = (it) => (it.ch.charCodeAt(0) < 0x2e80 ? it.fs * 0.5 : it.fs);

/**
 * 서로 다른 줄의 글자가 포개진 쌍을 센다.
 * 줄 간격이 좁은 정상 문서를 건너뛰도록 가로·세로 모두 절반 이상 겹칠 때만 인정한다.
 */
export function countTextOverlaps(items, cellSize = 24) {
  const grid = new Map();
  const key = (cx, cy) => `${cx}:${cy}`;
  items.forEach((it, i) => {
    const k = key(Math.floor(it.x / cellSize), Math.floor(it.y / cellSize));
    if (!grid.has(k)) grid.set(k, []);
    grid.get(k).push(i);
  });
  let pairs = 0;
  const hit = new Set();
  items.forEach((a, i) => {
    const cx = Math.floor(a.x / cellSize);
    const cy = Math.floor(a.y / cellSize);
    for (let dx = -1; dx <= 1; dx++) {
      for (let dy = -1; dy <= 1; dy++) {
        for (const j of grid.get(key(cx + dx, cy + dy)) ?? []) {
          if (j <= i) continue;
          const b = items[j];
          if (Math.abs(a.y - b.y) < 0.5) continue; // 같은 줄
          const w = Math.min(a.x + glyphWidth(a), b.x + glyphWidth(b)) - Math.max(a.x, b.x);
          const h = Math.min(a.y + a.fs * 0.2, b.y + b.fs * 0.2) - Math.max(a.y - a.fs * 0.8, b.y - b.fs * 0.8);
          if (w > Math.min(glyphWidth(a), glyphWidth(b)) * 0.5 && h > Math.min(a.fs, b.fs) * 0.5) {
            pairs++;
            hit.add(i);
            hit.add(j);
          }
        }
      }
    }
  });
  return { pairs, chars: hit.size };
}

/** 겹친 글자가 몇 자 이상이면 "내용이 가려졌을 수 있다"고 알린다. */
export const OVERLAP_WARNING_CHARS = 6;

export function svgSize(svg) {
  const head = svg.slice(0, 400);
  return { width: parseFloat(attr(head, 'width')), height: parseFloat(attr(head, 'height')) };
}

/**
 * JPEG 페이지들을 묶어 PDF를 만든다. 의존성이 없도록 직접 작성했다.
 * pages: [{ jpeg: Uint8Array, pixelWidth, pixelHeight, widthPt, heightPt }]
 */
export function buildPdf(pages) {
  const enc = new TextEncoder();
  const chunks = [];
  const offsets = [];
  let pos = 0;
  const push = (d) => {
    const b = typeof d === 'string' ? enc.encode(d) : d;
    chunks.push(b);
    pos += b.length;
  };
  const obj = (id, body) => {
    offsets[id] = pos;
    push(`${id} 0 obj\n`);
    body();
    push('\nendobj\n');
  };
  const num = (v) => Number(v.toFixed(2)).toString();

  push('%PDF-1.4\n');
  const pageId = (i) => 3 + i * 3;
  const count = pages.length;
  obj(1, () => push('<< /Type /Catalog /Pages 2 0 R >>'));
  obj(2, () => {
    const kids = pages.map((_, i) => `${pageId(i)} 0 R`).join(' ');
    push(`<< /Type /Pages /Count ${count} /Kids [${kids}] >>`);
  });
  pages.forEach((p, i) => {
    const id = pageId(i);
    obj(id, () =>
      push(
        `<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ${num(p.widthPt)} ${num(p.heightPt)}] ` +
          `/Resources << /XObject << /Im0 ${id + 1} 0 R >> >> /Contents ${id + 2} 0 R >>`,
      ),
    );
    obj(id + 1, () => {
      push(
        `<< /Type /XObject /Subtype /Image /Width ${p.pixelWidth} /Height ${p.pixelHeight} ` +
          `/ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode /Length ${p.jpeg.length} >>\nstream\n`,
      );
      push(p.jpeg);
      push('\nendstream');
    });
    const content = `q ${num(p.widthPt)} 0 0 ${num(p.heightPt)} 0 0 cm /Im0 Do Q`;
    obj(id + 2, () => push(`<< /Length ${content.length} >>\nstream\n${content}\nendstream`));
  });
  const size = pageId(count);
  const xref = pos;
  push(`xref\n0 ${size}\n0000000000 65535 f \n`);
  for (let i = 1; i < size; i++) push(`${String(offsets[i]).padStart(10, '0')} 00000 n \n`);
  push(`trailer\n<< /Size ${size} /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`);

  const out = new Uint8Array(pos);
  let at = 0;
  for (const c of chunks) {
    out.set(c, at);
    at += c.length;
  }
  return out;
}
