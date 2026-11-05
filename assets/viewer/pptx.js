// PPTX의 글상자, 그림, 표를 슬라이드 위치에 맞춰 HTML로 그린다.
// 애니메이션, 도형 채우기, 차트, 테마 색은 다루지 않는다.
(function (global) {
  const SLIDE_WIDTH = 820;
  const kids = (el, name) => (el ? [...el.children].filter((c) => c.localName === name) : []);
  const kid = (el, name) => kids(el, name)[0] ?? null;
  const all = (el, name) => (el ? [...el.getElementsByTagNameNS('*', name)] : []);
  const parseXml = (text) => new DOMParser().parseFromString(text, 'application/xml');

  const resolvePath = (base, target) => {
    if (target.startsWith('/')) return target.slice(1);
    const parts = base.split('/').slice(0, -1);
    for (const part of target.split('/')) {
      if (part === '..') parts.pop();
      else if (part !== '.') parts.push(part);
    }
    return parts.join('/');
  };

  async function readRels(zip, path) {
    const dir = path.split('/').slice(0, -1).join('/');
    const file = path.split('/').pop();
    const entry = zip.file(`${dir}/_rels/${file}.rels`);
    const map = new Map();
    if (!entry) return map;
    const xml = parseXml(await entry.async('string'));
    for (const rel of all(xml, 'Relationship')) {
      map.set(rel.getAttribute('Id'), {
        type: rel.getAttribute('Type') ?? '',
        path: resolvePath(path, rel.getAttribute('Target') ?? ''),
      });
    }
    return map;
  }

  function readBox(shape) {
    const xfrm = all(shape, 'xfrm')[0];
    const off = kid(xfrm, 'off');
    const ext = kid(xfrm, 'ext');
    if (!off || !ext) return null;
    return { x: +off.getAttribute('x'), y: +off.getAttribute('y'), w: +ext.getAttribute('cx'), h: +ext.getAttribute('cy') };
  }

  const placeholderOf = (shape) => {
    const ph = all(shape, 'ph')[0];
    return ph ? { type: ph.getAttribute('type') ?? 'body', idx: ph.getAttribute('idx') ?? '' } : null;
  };

  function layoutBox(layout, ph) {
    if (!layout || !ph) return null;
    const shapes = all(layout, 'sp');
    const match = (s) => {
      const p = placeholderOf(s);
      return p && ((ph.idx && p.idx === ph.idx) || p.type === ph.type);
    };
    const shape = shapes.find(match);
    return shape ? readBox(shape) : null;
  }

  const srgbFill = (el) => kid(kid(el, 'solidFill'), 'srgbClr')?.getAttribute('val') ?? null;

  /** 테마 색은 읽지 않으므로 배경을 모르는 칸의 밝은 글자는 안 보일 수 있어 기본색으로 둔다. */
  const isLight = (hex) => parseInt(hex.slice(0, 2), 16) + parseInt(hex.slice(2, 4), 16) + parseInt(hex.slice(4, 6), 16) > 660;

  function appendParagraphs(body, target, scale, ph, knownBackground) {
    const isTitle = ph?.type === 'title' || ph?.type === 'ctrTitle';
    const fallbackSize = isTitle ? 40 : 20;
    for (const para of kids(body, 'p')) {
      const p = document.createElement('p');
      const align = kid(para, 'pPr')?.getAttribute('algn');
      if (align) p.style.textAlign = { ctr: 'center', r: 'right', just: 'justify' }[align] ?? 'left';
      for (const node of [...para.children]) {
        if (node.localName === 'br') p.append(document.createElement('br'));
        if (node.localName !== 'r' && node.localName !== 'fld') continue;
        const span = document.createElement('span');
        span.textContent = kid(node, 't')?.textContent ?? '';
        const props = kid(node, 'rPr');
        const size = +(props?.getAttribute('sz') ?? 0) / 100 || fallbackSize;
        span.style.fontSize = `${size * 12700 * scale}px`;
        if (props?.getAttribute('b') === '1' || isTitle) span.style.fontWeight = '700';
        if (props?.getAttribute('i') === '1') span.style.fontStyle = 'italic';
        if (props?.getAttribute('u') && props.getAttribute('u') !== 'none') span.style.textDecoration = 'underline';
        const color = all(props, 'srgbClr')[0]?.getAttribute('val');
        if (color && (knownBackground || !isLight(color))) span.style.color = `#${color}`;
        p.append(span);
      }
      if (!p.childNodes.length) p.innerHTML = '&nbsp;';
      target.append(p);
    }
  }

  function place(el, box, scale) {
    el.style.left = `${box.x * scale}px`;
    el.style.top = `${box.y * scale}px`;
    el.style.width = `${box.w * scale}px`;
    el.style.height = `${box.h * scale}px`;
  }

  async function imageUrl(zip, path) {
    const entry = zip.file(path);
    if (!entry) return null;
    const ext = path.split('.').pop().toLowerCase();
    const mime = { jpg: 'image/jpeg', jpeg: 'image/jpeg', png: 'image/png', gif: 'image/gif', webp: 'image/webp', bmp: 'image/bmp', svg: 'image/svg+xml' }[ext];
    if (!mime) return null;
    return `data:${mime};base64,${await entry.async('base64')}`;
  }

  async function drawTree(tree, ctx) {
    const { slide, zip, rels, layout, scale, slideFill } = ctx;
    for (const node of [...tree.children]) {
      if (node.localName === 'sp') {
        const body = kid(node, 'txBody');
        const hasText = all(body, 't').some((t) => t.textContent.trim());
        const fill = srgbFill(kid(node, 'spPr'));
        if (!hasText && !fill) continue;
        const ph = placeholderOf(node);
        const box = readBox(node) ?? layoutBox(layout, ph);
        const el = document.createElement('div');
        el.className = box ? 'box' : 'flow';
        if (box) place(el, box, scale);
        if (fill) el.style.background = `#${fill}`;
        appendParagraphs(body, el, scale, ph, Boolean(fill || slideFill));
        slide.append(el);
      } else if (node.localName === 'pic') {
        const id = all(node, 'blip')[0]?.getAttributeNS('http://schemas.openxmlformats.org/officeDocument/2006/relationships', 'embed');
        const target = id ? rels.get(id) : null;
        const box = readBox(node);
        const url = target ? await imageUrl(zip, target.path) : null;
        if (url && box) {
          const img = document.createElement('img');
          img.src = url;
          img.alt = '';
          place(img, box, scale);
          slide.append(img);
        }
      } else if (node.localName === 'graphicFrame') {
        const tbl = all(node, 'tbl')[0];
        const box = readBox(node);
        if (!tbl || !box) continue;
        const wrap = document.createElement('div');
        wrap.className = 'box';
        place(wrap, box, scale);
        const table = document.createElement('table');
        for (const row of kids(tbl, 'tr')) {
          const tr = table.insertRow();
          for (const cell of kids(row, 'tc')) {
            if (cell.getAttribute('hMerge') === '1' || cell.getAttribute('vMerge') === '1') continue;
            const td = tr.insertCell();
            const span = cell.getAttribute('gridSpan');
            const rows = cell.getAttribute('rowSpan');
            if (span) td.colSpan = +span;
            if (rows) td.rowSpan = +rows;
            appendParagraphs(kid(cell, 'txBody'), td, scale, null, false);
          }
        }
        wrap.append(table);
        slide.append(wrap);
      } else if (node.localName === 'grpSp') {
        await drawTree(node, ctx);
      }
    }
  }

  async function renderPptx(buffer, root) {
    const zip = await global.JSZip.loadAsync(buffer);
    const presPath = 'ppt/presentation.xml';
    const entry = zip.file(presPath);
    if (!entry) throw new Error('PowerPoint 문서가 아닙니다');
    const pres = parseXml(await entry.async('string'));
    const presRels = await readRels(zip, presPath);
    const size = all(pres, 'sldSz')[0];
    const cx = +(size?.getAttribute('cx') ?? 12192000);
    const cy = +(size?.getAttribute('cy') ?? 6858000);
    const scale = SLIDE_WIDTH / cx;
    const R = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships';
    const ids = all(pres, 'sldId').map((s) => s.getAttributeNS(R, 'id'));
    let number = 0;
    for (const id of ids) {
      const path = presRels.get(id)?.path;
      const file = path ? zip.file(path) : null;
      if (!file) continue;
      number += 1;
      const xml = parseXml(await file.async('string'));
      const rels = await readRels(zip, path);
      const layoutRel = [...rels.values()].find((r) => r.type.endsWith('/slideLayout'));
      const layoutFile = layoutRel ? zip.file(layoutRel.path) : null;
      const layout = layoutFile ? parseXml(await layoutFile.async('string')) : null;
      const label = document.createElement('div');
      label.className = 'slide-number';
      label.textContent = `슬라이드 ${number}`;
      const slide = document.createElement('div');
      slide.className = 'slide';
      slide.style.width = `${SLIDE_WIDTH}px`;
      slide.style.height = `${cy * scale}px`;
      const slideFill = srgbFill(kid(all(xml, 'bg')[0], 'bgPr'));
      if (slideFill) slide.style.background = `#${slideFill}`;
      await drawTree(all(xml, 'spTree')[0], { slide, zip, rels, layout, scale, slideFill });
      root.append(label, slide);
    }
    if (!number) throw new Error('슬라이드를 찾지 못했습니다');
    return number;
  }

  global.renderPptx = renderPptx;
  global.PPTX_WIDTH = SLIDE_WIDTH;
})(globalThis);
