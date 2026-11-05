// Word, Excel, PowerPoint 문서를 앱 안의 WebView에 표시한다. 문서는 기기 밖으로 나가지 않는다.
(function () {
  const MAX_ROWS = 3000;
  const root = document.getElementById('root');
  const status = document.getElementById('status');

  /** 고정 폭 문서를 화면 폭에 맞춘다. 사용자는 이후 두 손가락으로 확대할 수 있다. */
  function fitWidth(contentWidth) {
    const available = document.documentElement.clientWidth;
    if (!available || contentWidth <= available) return;
    const scale = available / contentWidth;
    root.style.zoom = String(scale);
  }

  async function showDocx(buffer) {
    await window.docx.renderAsync(buffer, root, null, { inWrapper: false, ignoreLastRenderedPageBreak: true });
    const pages = [...root.querySelectorAll('section')];
    fitWidth(Math.max(...pages.map((page) => page.offsetWidth)));
  }

  function trimSheet(sheet) {
    const ref = sheet['!ref'];
    if (!ref) return false;
    const range = XLSX.utils.decode_range(ref);
    if (range.e.r - range.s.r < MAX_ROWS) return false;
    range.e.r = range.s.r + MAX_ROWS - 1;
    sheet['!ref'] = XLSX.utils.encode_range(range);
    return true;
  }

  function showXlsx(buffer) {
    const book = XLSX.read(buffer, { type: 'array', cellDates: true, dense: false, sheetStubs: false });
    const names = book.SheetNames;
    if (!names.length) throw new Error('시트가 없습니다');
    const tabs = document.createElement('div');
    tabs.className = 'sheet-tabs';
    const notice = document.createElement('div');
    notice.className = 'notice';
    notice.hidden = true;
    const body = document.createElement('div');
    body.className = 'sheet-body';
    const select = (name, button) => {
      const trimmed = trimSheet(book.Sheets[name]);
      notice.hidden = !trimmed;
      notice.textContent = `행이 많아 앞의 ${MAX_ROWS.toLocaleString()}행만 표시합니다.`;
      body.innerHTML = XLSX.utils.sheet_to_html(book.Sheets[name], { header: '', footer: '' });
      for (const b of tabs.children) b.classList.toggle('active', b === button);
      window.scrollTo(0, 0);
    };
    for (const name of names) {
      const button = document.createElement('button');
      button.textContent = name;
      button.addEventListener('click', () => select(name, button));
      tabs.append(button);
    }
    if (names.length > 1) root.append(tabs);
    root.append(notice, body);
    select(names[0], tabs.firstElementChild);
  }

  async function showPptx(buffer) {
    await window.renderPptx(buffer, root);
    fitWidth(window.PPTX_WIDTH);
  }

  async function main() {
    const query = new URLSearchParams(location.search);
    const kind = query.get('kind');
    const report = (route, body) => fetch(`../${route}?view=${encodeURIComponent(query.get('view'))}`, { method: 'POST', body }).catch(() => {});
    try {
      const response = await fetch(`../view-doc?view=${encodeURIComponent(query.get('view'))}`);
      if (!response.ok) throw new Error('문서를 읽지 못했습니다');
      const buffer = await response.arrayBuffer();
      if (kind === 'docx') await showDocx(buffer);
      else if (kind === 'xlsx') showXlsx(buffer);
      else if (kind === 'pptx') await showPptx(buffer);
      else throw new Error('지원하지 않는 형식입니다');
      status.textContent = '';
      await report('view-ok', root.innerText.replace(/\s+/g, ' ').slice(0, 80));
    } catch (error) {
      const message = String(error?.message ?? error);
      status.textContent = `문서를 열지 못했습니다: ${message}`;
      await report('view-fail', message);
    }
  }

  main();
})();
