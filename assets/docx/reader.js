import { applyDocxLayout, finalizeDocxLayout, fitDocxContent, settleDocxPageBreaks } from './docx_layout.js';
// Read-only adapter for OpenDocument.core. All assets and documents stay local.
const host = document.getElementById('pages');
const measure = document.getElementById('measure');
const MAX_BYTES = 256 * 1024 * 1024;
let incoming, received = 0, page = 0, pages = [], disposed = false;
let outlineBlockCache = null; // 목차용 문단 목록 (쪽을 다시 나누면 비움)
const IMAGE_CACHE_BYTES = 32 * 1024 * 1024;
const imageCache = new Map(), imageJobs = new Map(), brokenImages = new Set();
let resourceIndex = new Map(), originalSources = new Set(), resourceSession = 0;
let imageCacheBytes = 0, activeImagePaths = new Set(), renderSerial = 0;
let ready = false, requestId = 0, generation = 0, awaitingPassword = false, unavailableImages = 0;
let detectedFormat = 'docx';
let options = { format: 'docx', theme: 'white', spread: false, rtl: false, position: null, progress: 0 };
const requests = new Map(), fonts = new Map();
let pendingEvents = [], flushing = false;

function emit(type, data = {}) { pendingEvents.push({ type, ...data }); void flush(); retryBridge(); }
async function flush() {
  if (!window.flutter_inappwebview?.callHandler || flushing || disposed) return;
  flushing = true;
  try {
    while (pendingEvents.length && !disposed) {
      await window.flutter_inappwebview.callHandler('freaderDocx', pendingEvents[0]);
      pendingEvents.shift();
    }
  } catch (_) { /* Retry when the Android bridge becomes ready. */ }
  finally { flushing = false; }
}
// FReader(배터리): 보낼 알림이 남아 있을 때만 0.15초마다 다시 시도한다 (예전에는 책을 펴 둔 내내 계속 깨어 있었음)
let bridgeTimer = 0;
function retryBridge() {
  if (bridgeTimer || disposed) return;
  bridgeTimer = setInterval(() => {
    if (disposed || !pendingEvents.length) { clearInterval(bridgeTimer); bridgeTimer = 0; return; }
    void flush();
  }, 150);
}
window.addEventListener('flutterInAppWebViewPlatformReady', flush);
function fail(error) { emit('error', { message: String(error?.message || error).slice(0, 600) }); return false; }

const worker = new Worker('./worker.js', { type: 'module' });
worker.onmessage = ({ data }) => {
  if (disposed) return;
  if (data.id) { requests.get(data.id)?.(data); requests.delete(data.id); }
  else if (data.type === 'ready') { ready = true; emit('ready', { version: data.version }); }
  else if (data.type === 'error') fail(data.message);
};
worker.onerror = event => fail(event.message || 'Word 문서 엔진을 시작하지 못했습니다');
function request(action, data = {}, transfer = []) {
  return new Promise(resolve => {
    const id = ++requestId; requests.set(id, resolve);
    worker.postMessage({ id, action, ...data }, transfer);
  });
}
// FReader: 문서를 다 읽어 쪽을 모두 만든 뒤에만 스크롤 보기를 켜고 끔
// (읽는 도중에 켜면 그때까지 만든 쪽만으로 스크롤 화면이 만들어져 스크롤이 중간에서 막혔음)
let docReady = false;
function clearPages() {
  docReady = false;
  renderSerial++;
  if (vertical) {
    vertical = false; vResize.disconnect(); vMounted.clear(); vOwner.clear();
    vhost?.remove(); vhost = null; vSlots = []; vTops = []; host.style.display = '';
  }
  for (const item of imageCache.values()) URL.revokeObjectURL(item.url);
  imageCache.clear(); imageJobs.clear(); brokenImages.clear();
  resourceIndex.clear(); originalSources.clear(); activeImagePaths.clear(); imageCacheBytes = 0;
  pages = []; page = 0; unavailableImages = 0; host.replaceChildren(); measure.replaceChildren();
  searchState = { query: '', results: [], current: -1 }; applySearchHighlights();
  document.querySelectorAll('style[data-document]').forEach(el => el.remove());
}
function beginDocument(length, config) {
  if (!Number.isSafeInteger(length) || length < 1 || length > MAX_BYTES) throw new Error('열 수 있는 문서 크기는 256MB 이하입니다');
  generation++; clearPages();
  if (incoming) incoming.fill(0);
  incoming = new Uint8Array(length); received = 0; awaitingPassword = false;
  imageStorePromise = null;
  configure(config);
}
function appendChunk(offset, encoded) {
  if (!incoming || offset !== received) throw new Error('문서 전송 순서가 올바르지 않습니다');
  const binary = atob(encoded);
  if (received + binary.length > incoming.length) throw new Error('문서 전송 크기가 일치하지 않습니다');
  for (let i = 0; i < binary.length; i++) incoming[received + i] = binary.charCodeAt(i);
  received += binary.length;
}
async function openDocument(password = null) {
  const current = generation;
  try {
    let result;
    if (awaitingPassword) result = await request('password', { password });
    else {
      if (!incoming || received !== incoming.length) throw new Error('문서 데이터를 모두 받지 못했습니다');
      const bytes = incoming; incoming = null; received = 0;
      result = await request('open', { bytes, password, format: options.format }, [bytes.buffer]);
    }
    password = null;
    if (disposed || current !== generation) return false;
    if (result.type === 'password') { awaitingPassword = true; emit('password', { incorrect: result.incorrect }); return false; }
    awaitingPassword = false;
    if (result.type === 'error') return fail(result.message);
    detectedFormat = result.format || 'docx';
    resourceSession = result.session;
    resourceIndex = new Map((result.resources || []).map(r => [r.path, r]));
    await preparePages(result.html, current);
    if (disposed || current !== generation) return false;
    const saved = /^(?:docx|doc):(\d+)$/.exec(options.position || '');
    page = clampPage(saved ? Number(saved[1]) : Math.round(Number(options.progress || 0) * (pages.length - 1)));
    // 읽는 동안 바뀐 보기 설정(스크롤/쪽 넘김)을 여기서 한 번에 맞춤
    if (vertical) setVertical(false);
    if (options.vertical) setVertical(true); else await render();
    docReady = true;
    emit('loaded', { pageCount: pages.length, unavailableImages }); reportLocation();
    return true;
  } catch (error) { return fail(error); }
  finally { password = null; }
}

// 같은 크기(글자 폭)로 만든 무료 글꼴 (영문 부분만)
const METRIC_FONTS = [
  [/^(arial|helvetica|arimo|liberation sans)$/i, 'LiberationSans'],
  [/^(times new roman|times|tinos|liberation serif)$/i, 'LiberationSerif'],
  [/^(courier new|courier|cousine|liberation mono)$/i, 'LiberationMono'],
  [/^(calibri|carlito)$/i, 'Carlito'],
  [/^(cambria|caladea)$/i, 'Caladea'],
];
const LATIN_RANGE = 'U+0000-024F, U+2000-206F, U+20A0-20CF, U+2100-214F';
function metricFont(name) {
  const n = String(name).trim();
  for (const [re, base] of METRIC_FONTS) if (re.test(n)) return base;
  return null;
}
// 앱에 들어 있는 무료 한글 글꼴 (문서가 이 이름을 쓰면 원본 글꼴로 보여 줌)
const FREE_FONTS = [
  [/^(나눔고딕|nanumgothic|nanum gothic)$/i, 'NanumGothic', true],
  [/^(나눔명조|nanummyeongjo|nanum myeongjo)$/i, 'NanumMyeongjo', true],
  [/^(나눔고딕코딩|nanumgothiccoding|nanum gothic coding)$/i, 'NanumGothicCoding', true],
  [/^(고운바탕|gowunbatang|gowun batang)$/i, 'GowunBatang', true],
  [/^(고운돋움|gowundodum|gowun dodum)$/i, 'GowunDodum', false],
];
function freeFont(name) {
  const n = String(name).replace(/^DOCX /, '').trim();
  for (const [re, base, bold] of FREE_FONTS) if (re.test(n)) return { base, bold };
  return null;
}
async function addFreeFaces(name, free, dir) {
  await Promise.all((free.bold ? [400, 700] : [400]).map(async w => {
    try {
      const face = new FontFace(name, `url(${dir}/${free.base}-${w === 700 ? 'Bold' : 'Regular'}.woff2)`, { weight: String(w) });
      await face.load(); document.fonts.add(face);
    } catch (e) {}
  }));
}
// 한컴바탕·한컴돋움이 없으면 사용자가 넣은 함초롬바탕·함초롬돋움으로 대신 보여 줌
const USER_FONT_ALIASES = [
  [/^(한컴\s?바탕|hancom\s?batang|haansoft\s?batang)$/i, ['함초롬바탕', 'hcr batang', '함초롬 바탕']],
  [/^(한컴\s?돋움|hancom\s?dotum|haansoft\s?dotum)$/i, ['함초롬돋움', 'hcr dotum', '함초롬 돋움']],
];
function userFontFacesExact(n) {
  return (options.userFonts || []).filter(f => (f.n || []).some(x => String(x).trim().toLowerCase() === n));
}
function userFontFaces(name) {
  const n = String(name).trim().toLowerCase();
  const own = userFontFacesExact(n);
  if (own.length) return own;
  for (const [re, targets] of USER_FONT_ALIASES) {
    if (!re.test(n)) continue;
    for (const t of targets) {
      const faces = userFontFacesExact(t);
      if (faces.length) return faces;
    }
  }
  return [];
}
function fontKind(name) {
  if (/math|equation|수식/i.test(name)) return 'math';
  return /바탕|명조|궁서|batang|myeong|serif|times|cambria/i.test(name) ? 'serif' : 'sans';
}
async function loadFonts(root) {
  // Keep DOCX substitutions separate from the established DOC/RTF font aliases.
  if (detectedFormat === 'docx' && options.docxLayout?.version === 1) {
    for (const el of root.querySelectorAll('[style]')) {
      if (el.style.fontFamily) el.style.fontFamily = el.style.fontFamily.split(',').map(part => {
        const name = part.trim().replace(/^['"]|['"]$/g, '');
        return /^(sans-serif|serif|monospace|inherit|initial)$/i.test(name) ? name : JSON.stringify('DOCX ' + name);
      }).join(',');
    }
  }
  const names = new Set(['FReaderSans', 'FReaderSerif', '맑은 고딕', '바탕', '굴림', '돋움', 'Calibri', 'Arial', 'Times New Roman']);
  for (const el of root.querySelectorAll('[style]')) {
    for (const part of el.style.fontFamily.split(',')) {
      const name = part.trim().replace(/^['"]|['"]$/g, '');
      if (name && !/^(sans-serif|serif|monospace|inherit|initial)$/i.test(name)) names.add(name);
    }
  }
  await Promise.all([...names].slice(0, 128).map(async name => {
    if (fonts.has(name)) return fonts.get(name);
    if (name.length > 160 || /[\x00-\x1f]/.test(name)) return;
    const localName = name.startsWith('DOCX ') ? name.slice(5) : name;
    // 사용자가 넣은 글꼴이 있으면 그것을 씀 (기기에 없는 원래 글꼴 대신)
    const user = userFontFaces(localName);
    if (user.length) {
      const job = Promise.all(user.map(async f => {
        try {
          const face = new FontFace(name, `url(/userfonts/${encodeURIComponent(f.f)})`, { weight: String(f.w || 400), style: f.i ? 'italic' : 'normal' });
          await face.load(); document.fonts.add(face);
        } catch (e) {}
      }));
      fonts.set(name, job); return job;
    }
    const free = freeFont(localName);
    if (free) {
      const job = addFreeFaces(name, free, './fonts/free');
      fonts.set(name, job); return job;
    }
    const kind = fontKind(localName), base = kind === 'math' ? 'LatinModernMath' : kind === 'serif' ? 'NotoSerifKR' : 'NotoSansKR';
    const metric = kind === 'math' ? null : metricFont(localName);
    const job = Promise.all((kind === 'math' ? [400] : [400, 700]).map(async weight => {
      const suffix = weight === 700 ? 'Bold' : 'Regular';
      const face = new FontFace(name, `local(${JSON.stringify(localName)}), url(../hwp/fonts/${base}-${suffix}.woff2)`, { weight: String(weight) });
      await face.load(); document.fonts.add(face);
      if (kind !== 'math') {
        const symbols = new FontFace(name, `url(./fonts/${base}-Symbols-${suffix}.ttf)`, { weight: String(weight), unicodeRange: 'U+3000-303F' });
        await symbols.load(); document.fonts.add(symbols);
        if (metric) {
          // Arial·Times New Roman·Calibri 등: 글자 폭이 같은 무료 글꼴로 영문을 그려 줄바꿈·배치가 원본과 같게
          // 없어도 문서는 계속 보이게 (기본 글꼴로)
          try {
            const latin = new FontFace(name, `local(${JSON.stringify(localName)}), url(./fonts/metric/${metric}-${suffix}.woff2)`, { weight: String(weight), unicodeRange: LATIN_RANGE });
            await latin.load(); document.fonts.add(latin);
          } catch (e) {}
        } else if (name.startsWith('DOCX ')) {
        const latin = new FontFace(name, `local(${JSON.stringify(localName)}), url(./fonts/Noto${kind === 'serif' ? 'Serif' : 'Sans'}-Latin-${suffix}.ttf)`, { weight: String(weight), unicodeRange: 'U+0000-024F' });
        await latin.load(); document.fonts.add(latin);
        }
      }
    }));
    fonts.set(name, job); return job;
  }));
  await Promise.all(['400 16px FReaderSans', '700 16px FReaderSans', '400 16px FReaderSerif', '700 16px FReaderSerif', '400 16px FReaderMath'].map(font => document.fonts.load(font)));
}
function sanitize(parsed) {
  for (const img of parsed.querySelectorAll('img')) {
    const path = img.getAttribute('src');
    if (resourceIndex.has(path)) { img.dataset.resource = path; img.removeAttribute('src'); }
  }
  parsed.querySelectorAll('script,link,meta,base,iframe,object,embed,form').forEach(el => el.remove());
  for (const el of parsed.querySelectorAll('*')) {
    for (const attr of [...el.attributes]) {
      const name = attr.localName.toLowerCase();
      if (name.startsWith('on') || name === 'contenteditable' || name === 'srcdoc') el.removeAttributeNode(attr);
      else if (['href', 'src', 'srcset', 'action'].includes(name) &&
          !(name === 'src' && el.localName === 'img' && /^data:image\/(png|jpeg|jpg|gif|webp|bmp|svg\+xml)[;,]/i.test(attr.value))) el.removeAttributeNode(attr);
    }
  }
}
function applyPageBreaks(parsed) {
  const paragraphs = [...parsed.querySelectorAll('.odr-page-inner x-p')];
  for (const hint of options.pageBreaks || []) {
    const paragraph = paragraphs[hint.index];
    // A model difference must not split a different paragraph's contents.
    if (!paragraph || paragraph.textContent !== hint.text) continue;
    for (const offset of [...hint.offsets].sort((a, b) => b - a)) {
      if (offset === 0) { paragraph.style.breakBefore = 'column'; continue; }
      const walker = parsed.createTreeWalker(paragraph, NodeFilter.SHOW_TEXT);
      let node, remaining = offset;
      while ((node = walker.nextNode())) {
        if (remaining > node.length) { remaining -= node.length; continue; }
        const range = parsed.createRange();
        range.setStart(node, remaining); range.setEnd(paragraph, paragraph.childNodes.length);
        const continuation = paragraph.cloneNode(false);
        continuation.appendChild(range.extractContents());
        continuation.style.breakBefore = 'column';
        paragraph.after(continuation);
        break;
      }
    }
  }
}
async function preparePages(html, current) {
  const parsed = new DOMParser().parseFromString(html, 'text/html');
  sanitize(parsed);
  if (detectedFormat !== 'docx' || !applyDocxLayout(parsed, options.docxLayout)) applyPageBreaks(parsed);
  const sources = [...parsed.querySelectorAll('.odr-pages > .odr-page-outer')];
  if (!sources.length) throw new Error('Word 문서에서 표시할 본문을 찾지 못했습니다');
  for (const style of parsed.head.querySelectorAll('style')) {
    const copy = document.createElement('style'); copy.dataset.document = '';
    copy.textContent = style.textContent; document.head.insertBefore(copy, document.querySelector('link'));
  }
  await loadFonts(parsed);
  if (disposed || current !== generation) return;
  for (const source of sources) {
    source.style.height = source.style.minHeight || '297mm';
    source.style.width ||= '210mm';
    if (detectedFormat === 'doc' || detectedFormat === 'rtf') {
      // The legacy/RTF parser has no paper/margin information. Use a readable
      // fallback while preserving its paragraphs and explicit page breaks.
      const inner = source.querySelector(':scope > .odr-page-inner');
      if (inner && !inner.style.margin) inner.style.margin = '20mm';
    }
    measure.appendChild(document.importNode(source, true));
  }
  finalizeDocxLayout(measure, options.docxLayout);
  originalSources = new Set(measure.children);
  // OOXML specifies the display extents. Reserve them without decoding every
  // photograph. Only unusual images without extents need an intrinsic-size probe.
  for (const img of measure.querySelectorAll('img')) {
    // FReader: 변환 엔진이 모든 그림에 붙이는 'Error: image not found' 대체 글자가
    // 그림을 불러오는 동안 보이지 않게 한다 (실제로 못 읽은 그림은 아래 missingImage가 따로 표시)
    if (/image not found/i.test(img.alt || '')) img.alt = '';
    if (!img.dataset.resource && !img.getAttribute('src')) { missingImage(img); continue; }
    if (!(parseFloat(img.style.width || img.getAttribute('width')) > 0) ||
        !(parseFloat(img.style.height || img.getAttribute('height')) > 0)) {
      try {
        const item = img.dataset.resource ? await imageFor(img.dataset.resource) : { url: img.src };
        if (disposed || current !== generation) return;
        const probe = new Image(); probe.src = item.url; await probe.decode();
        if (!img.style.width && !img.hasAttribute('width')) img.style.width = `${probe.naturalWidth}px`;
        if (!img.style.height && !img.hasAttribute('height')) img.style.height = `${probe.naturalHeight}px`;
        probe.src = ''; trimImages();
      } catch (_) { missingImage(img); }
    }
  }
  const result = [];
  for (const source of measure.children) {
    const inner = source.querySelector(':scope > .odr-page-inner');
    if (!inner) throw new Error('Word 문서 본문 구조가 올바르지 않습니다');
    if (source.classList.contains('rtf-paper')) {
      // Office reserves space for page furniture even when the saved margins
      // would otherwise overlap it. Measure after fonts and image extents load.
      for (const kind of ['header', 'footer']) {
        const furniture = source.querySelector('.rtf-page-' + kind);
        if (!furniture?.children.length) continue;
        let height = 0;
        for (const story of furniture.children) {
          for (const other of furniture.children) other.style.display = other === story ? 'block' : 'none';
          height = Math.max(height, furniture.getBoundingClientRect().height);
        }
        const edge = kind === 'header' ? 'Top' : 'Bottom';
        const offset = parseFloat(furniture.style[kind === 'header' ? 'top' : 'bottom']) || 0;
        inner.style['margin' + edge] = Math.max(parseFloat(inner.style['margin' + edge]) || 0, offset + height) + 'px';
      }
    }
    const bounds = source.getBoundingClientRect(), css = getComputedStyle(inner);
    const width = bounds.width, height = bounds.height;
    if (!(width > 0 && height > 0 && width < 20000 && height < 20000)) throw new Error('Word 문서 페이지 크기가 올바르지 않습니다');
    const margin = ['Top', 'Right', 'Bottom', 'Left'].map(side => parseFloat(css['margin' + side]) || 0);
    const bodyWidth = Math.max(32, width - margin[1] - margin[3]);
    const bodyHeight = Math.max(32, height - margin[0] - margin[2]);
    if (inner.classList.contains('docx-layout')) {
      fitDocxContent(inner, bodyWidth, bodyHeight);
      // Chromium can fragment a short merged-cell table and leave border-only
      // fragments in later columns. Keep a table together if it fits one page;
      // long tables still paginate row by row without clipping their contents.
      for (const table of inner.querySelectorAll('table')) {
        if (table.getBoundingClientRect().height <= bodyHeight) table.style.breakInside = 'avoid';
      }
      for (const img of inner.querySelectorAll('img')) {
        const frame = img.parentElement;
        if (frame?.localName === 'div' && frame.getBoundingClientRect().height <= bodyHeight) frame.style.breakInside = 'avoid';
      }
    }

    const clip = document.createElement('div'); clip.className = 'freader-content';
    Object.assign(clip.style, { left: `${margin[3]}px`, top: `${margin[0]}px`, width: `${bodyWidth}px`, height: `${bodyHeight}px` });
    inner.replaceWith(clip); clip.appendChild(inner);
    inner.classList.add('freader-columns');
    // Separate virtual pages so overflow ink from one column cannot be painted
    // onto the next. Tables/images are fitted above; the gap is never displayed.
    const columnGap = inner.classList.contains('docx-layout') ? bodyWidth : 0;
    const columnStride = bodyWidth + columnGap;
    Object.assign(inner.style, { width: `${bodyWidth}px`, height: `${bodyHeight}px`, columnWidth: `${bodyWidth}px`, columnGap: `${columnGap}px` });
    if (inner.classList.contains('docx-layout')) settleDocxPageBreaks(inner, columnStride);
    const columns = Math.max(1, Math.ceil((inner.scrollWidth + columnGap - 1) / columnStride));
    if (result.length + columns > 10000) throw new Error('표시할 Word 문서 페이지 수가 너무 많습니다');
    // FReader: 쪽마다 들어 있는 그림 목록 (다음·이전 쪽 그림을 미리 불러오는 데 사용)
    const columnImages = Array.from({ length: columns }, () => new Set());
    const innerLeft = inner.getBoundingClientRect().left;
    for (const img of inner.querySelectorAll('img[data-resource]')) {
      for (const r of img.getClientRects()) {
        if (!(r.width > 0 && r.height > 0)) continue;
        const first = Math.floor((r.left - innerLeft + 0.5) / columnStride), last = Math.floor((r.right - innerLeft - 0.5) / columnStride);
        for (let c = Math.max(0, first); c <= Math.min(columns - 1, last); c++) columnImages[c].add(img.dataset.resource);
      }
    }
    for (let column = 0; column < columns; column++) result.push({ source, column, width, height, bodyWidth, columnStride, sectionPageCount: columns, images: [...columnImages[column]] });
  }
  pages = result; outlineBlockCache = null;
}
function clampPage(value) { return Math.max(0, Math.min(pages.length - 1, Number.isFinite(value) ? Math.trunc(value) : 0)); }
function reportLocation() { emit('location', { page, pageCount: pages.length, position: `${options.format === 'doc' ? 'doc' : 'docx'}:${page}`, progress: pages.length > 1 ? page / (pages.length - 1) : 1 }); }
function trimImages() {
  for (const [path, item] of imageCache) {
    if (imageCacheBytes <= IMAGE_CACHE_BYTES && imageCache.size <= 24) break;
    if (activeImagePaths.has(path)) continue;
    imageCache.delete(path); imageCacheBytes -= item.size; URL.revokeObjectURL(item.url);
  }
}
// ── 변환된 그림 저장소 (기기 안 Cache Storage, 문서마다 따로) ──
// 열쇠(cacheKey)는 앱이 파일 경로·크기·수정 시각으로 만들어 넘긴다. 문서가 바뀌면 열쇠도 바뀐다.
const IMAGE_STORE_PREFIX = 'freader-docx-img-v1-';
const IMAGE_STORE_KEEP = 40; // 최근 문서 40개까지만 보관
let imageStorePromise = null;
function imageStore() {
  if (!options.cacheKey || typeof caches === 'undefined') return Promise.resolve(null);
  if (!imageStorePromise) {
    const name = IMAGE_STORE_PREFIX + options.cacheKey;
    imageStorePromise = caches.open(name).then(store => { void pruneImageStores(name); return store; }).catch(() => null);
  }
  return imageStorePromise;
}
async function pruneImageStores(current) {
  try {
    let order = [];
    try { order = JSON.parse(localStorage.getItem('freaderDocxImgOrder') || '[]'); } catch (_) {}
    order = [current, ...order.filter(name => name !== current)];
    const keep = new Set(order.slice(0, IMAGE_STORE_KEEP));
    for (const name of await caches.keys()) if (name.startsWith(IMAGE_STORE_PREFIX) && !keep.has(name)) await caches.delete(name);
    try { localStorage.setItem('freaderDocxImgOrder', JSON.stringify([...keep])); } catch (_) {}
  } catch (_) {}
}
const storeUrl = path => `https://freader.local/img/${encodeURIComponent(path)}`;
async function storedImage(path) {
  try {
    const store = await imageStore(); if (!store) return null;
    const hit = await store.match(storeUrl(path)); if (!hit) return null;
    const blob = await hit.blob();
    return blob.size ? blob : null;
  } catch (_) { return null; }
}
async function storeImage(path, blob) {
  try {
    const store = await imageStore(); if (!store) return;
    await store.put(storeUrl(path), new Response(blob, { headers: { 'content-type': blob.type || 'application/octet-stream' } }));
  } catch (_) {}
}
async function imageFor(path) {
  if (brokenImages.has(path)) throw new Error('Unsupported image');
  if (imageCache.has(path)) {
    const item = imageCache.get(path); imageCache.delete(path); imageCache.set(path, item); return item;
  }
  if (imageJobs.has(path)) return imageJobs.get(path);
  const current = generation, requestedSession = resourceSession;
  const job = (async () => {
    // FReader: 한 번 꺼내고 변환한 그림은 기기에 저장해 두고 다음에 열 때 바로 쓴다
    const stored = await storedImage(path);
    let blob;
    if (stored) blob = stored;
    else {
      const result = await request('resource', { path, session: requestedSession });
      if (disposed || current !== generation || requestedSession !== resourceSession) throw new Error('Expired image');
      if (result.type !== 'resource' || !result.bytes) throw new Error(result.message || 'Missing image');
      blob = new Blob([result.bytes], { type: result.mimeType });
      void storeImage(path, blob);
    }
    if (disposed || current !== generation || requestedSession !== resourceSession) throw new Error('Expired image');
    const item = { url: URL.createObjectURL(blob), size: blob.size };
    imageCache.set(path, item); imageCacheBytes += item.size; return item;
  })();
  imageJobs.set(path, job);
  try { return await job; }
  finally { if (imageJobs.get(path) === job) imageJobs.delete(path); }
}
function missingImage(img, reason) {
  const key = img.dataset.resource || img.getAttribute('src') || 'missing';
  if (!brokenImages.has(key)) { brokenImages.add(key); unavailableImages++; }
  const notice = document.createElement('span');
  notice.className = 'freader-missing-image'; notice.dataset.resource = key; if (reason) notice.dataset.reason = String(reason); notice.style.cssText = img.style.cssText;
  notice.textContent = '이 그림은 표시할 수 없습니다'; img.replaceWith(notice);
}
function preparePageSource(source, entry, index) {
    source.querySelector('.freader-columns').style.transform = `translateX(${-entry.column * entry.columnStride}px)`;
    if (source.classList.contains('rtf-paper')) {
      const start = Number(source.dataset.rtfStart), number = start > 0 ? start + entry.column : index + 1;
      for (const field of source.querySelectorAll('[data-rtf-field]')) {
        field.textContent = String(field.dataset.rtfField === 'NUMPAGES' ? pages.length : field.dataset.rtfField === 'SECTIONPAGES' ? entry.sectionPageCount : number);
      }
      for (const kind of ['header', 'footer']) {
        const furniture = source.querySelector('.rtf-page-' + kind); if (!furniture) continue;
        const suffix = source.dataset.rtfFirst === 'true' && entry.column === 0 ? 'f'
          : source.dataset.rtfFacing === 'true' ? (number % 2 ? 'r' : 'l') : '';
        const selected = furniture.querySelector(`[data-rtf-story="${kind + suffix}"]`)
          || (suffix !== 'f' ? furniture.querySelector(`[data-rtf-story="${kind}"]`) : null);
        for (const story of furniture.children) story.style.display = story === selected ? 'block' : 'none';
      }
    }
}
async function render() {
  if (!pages.length || disposed) return;
  if (vertical) return;
  const serial = ++renderSerial;
  // Reuse the original layout tree in single-page mode. A spread only needs
  // one extra tree when both displayed pages belong to the same section.
  for (const frame of host.children) {
    for (const img of frame.querySelectorAll('img[data-resource]')) img.removeAttribute('src');
    const source = frame.firstElementChild;
    if (originalSources.has(source)) measure.appendChild(source);
  }
  const fragment = document.createDocumentFragment(), used = new Set();
  for (let index = page; index < Math.min(pages.length, page + (options.spread ? 2 : 1)); index++) {
    const entry = pages[index], frame = document.createElement('section');
    frame.className = 'page'; frame.dataset.page = String(index);
    frame.dataset.width = String(entry.width); frame.dataset.height = String(entry.height);
    frame.setAttribute('aria-label', `${index + 1} / ${pages.length}`);
    const source = used.has(entry.source) ? entry.source.cloneNode(true) : entry.source; used.add(entry.source);
    preparePageSource(source, entry, index);
    frame.appendChild(source); fragment.appendChild(frame);
  }
  host.replaceChildren(fragment); fitPages();
  renderNoteAreas();
  applySearchHighlights();
  const visible = [...host.querySelectorAll('img[data-resource]')].filter(img => {
    const clip = (img.closest('.freader-content') || img.closest('.page')).getBoundingClientRect();
    return [...img.getClientRects()].some(r => r.width > 0 && r.height > 0 && r.right > clip.left + .1 && r.left < clip.right - .1 && r.bottom > clip.top + .1 && r.top < clip.bottom - .1);
  });
  activeImagePaths = new Set(visible.map(img => img.dataset.resource));
  trimImages();
  // FReader: 글자는 바로 보이게 하고(쪽 위치도 바로 알림), 사진은 이어서 채운다.
  // 사진까지 다 채워지면 'pageReady'를 알린다 (앱은 이때 이 쪽의 화면을 저장해 다음에 먼저 띄움).
  void loadVisibleImages(serial, visible);
}
async function loadVisibleImages(serial, visible) {
  // Bounded decoding keeps temporary pixel buffers small for photo-heavy files.
  // FReader: 두 장씩 함께 불러와 사진이 많은 쪽도 빨리 채운다.
  const queue = [...visible];
  const worker = async () => {
    while (queue.length) {
      const img = queue.shift();
      if (disposed || serial !== renderSerial) return;
      try {
        const item = await imageFor(img.dataset.resource);
        if (disposed || serial !== renderSerial) return;
        img.loading = 'eager'; img.src = item.url; await img.decode();
      } catch (error) { if (!disposed && serial === renderSerial) missingImage(img, error); }
    }
  };
  await Promise.all([worker(), worker()]);
  if (disposed || serial !== renderSerial) return;
  trimImages();
  await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
  if (disposed || serial !== renderSerial) return;
  emit('pageReady', { page, position: `${options.format === 'doc' ? 'doc' : 'docx'}:${page}` });
  prefetchNearby(serial);
}
// FReader: 지금 쪽을 다 그린 뒤 다음 쪽(두 쪽 보기면 두 쪽)과 이전 쪽의 그림을 미리 준비해 둔다.
// 그림 변환(벡터 그림 등)은 오래 걸리므로 넘기는 순간 빈 칸으로 보이지 않게 한다.
async function prefetchNearby(serial) {
  const span = options.spread ? 2 : 1;
  const order = [page + span, page + span + 1, page - 1, page + 2 * span, page - span - 1];
  const wanted = [];
  for (const index of order) {
    if (index < 0 || index >= pages.length || index === page) continue;
    for (const path of pages[index].images || []) if (!wanted.includes(path)) wanted.push(path);
  }
  for (const path of wanted.slice(0, 16)) {
    if (disposed || serial !== renderSerial) return;
    if (imageCache.has(path) || brokenImages.has(path)) continue;
    try {
      const item = await imageFor(path);
      // 사진은 미리 풀어 두면 넘길 때 바로 보인다 (크기가 큰 것은 메모리를 아끼기 위해 건너뜀)
      if (item.size < 6 * 1024 * 1024 && serial === renderSerial) {
        const probe = new Image(); probe.src = item.url; await probe.decode().catch(() => {});
      }
    } catch (_) {}
    if (imageCacheBytes > IMAGE_CACHE_BYTES * 0.9) break;
  }
}
// FReader: 이 쪽에 보이는 각주 번호의 본문을 쪽 아래에 표시 (Word처럼 본문 아래, 자리가 없으면 아래 여백)
function renderNoteAreas(frames = [...host.children]) {
  const notes = options.docxLayout?.notes;
  for (const frame of frames) {
    const source = frame.firstElementChild; if (!source) continue;
    for (const old of source.querySelectorAll(':scope > .docx-note-area')) old.remove();
    if (!notes) continue;
    const clipEl = source.querySelector(':scope > .freader-content'); if (!clipEl) continue;
    const clip = clipEl.getBoundingClientRect();
    const inside = r => r.width > 0 && r.height > 0 && r.right > clip.left + .1 && r.left < clip.right - .1 && r.bottom > clip.top + .1 && r.top < clip.bottom - .1;
    const seen = new Set(), items = [];
    for (const ref of clipEl.querySelectorAll('sup.docx-note-ref')) {
      if (![...ref.getClientRects()].some(inside)) continue;
      const key = ref.dataset.noteKey; if (seen.has(key) || notes[key] == null) continue;
      seen.add(key); items.push([ref.dataset.note, notes[key]]);
    }
    if (!items.length) continue;
    const scale = frame.getBoundingClientRect().width / Number(frame.dataset.width) || 1;
    let contentBottom = clip.top;
    for (const el of clipEl.querySelectorAll('x-p, table, img')) {
      for (const r of el.getClientRects()) if (inside(r)) contentBottom = Math.max(contentBottom, Math.min(r.bottom, clip.bottom));
    }
    const area = document.createElement('div'); area.className = 'docx-note-area';
    const left = parseFloat(clipEl.style.left) || 0, top0 = parseFloat(clipEl.style.top) || 0;
    const bodyHeight = parseFloat(clipEl.style.height) || 0, pageHeight = Number(frame.dataset.height);
    Object.assign(area.style, { left: `${left}px`, width: clipEl.style.width });
    for (const [label, text] of items) {
      const row = document.createElement('div'); row.className = 'docx-note';
      const mark = document.createElement('sup'); mark.textContent = label;
      row.append(mark, document.createTextNode(' ' + text)); area.appendChild(row);
    }
    source.appendChild(area);
    const h = area.getBoundingClientRect().height / scale;
    const usedBottom = top0 + (contentBottom - clip.top) / scale, bodyBottom = top0 + bodyHeight;
    let top = bodyBottom - h;
    if (top < usedBottom + 6) top = Math.min(bodyBottom + 4, pageHeight - h - 2);
    area.style.top = `${Math.max(0, top)}px`;
  }
}
// 지금 보이는 쪽(들)이 화면에서 차지하는 자리 (화면 크기 대비 0~1) — 스크롤 보기용 쪽 그림 자르기
function pageRect() {
  const frames = [...host.children]; if (!frames.length) return null;
  let l = 1e9, t = 1e9, r = -1e9, b = -1e9;
  for (const f of frames) { const q = f.getBoundingClientRect(); l = Math.min(l, q.left); t = Math.min(t, q.top); r = Math.max(r, q.right); b = Math.max(b, q.bottom); }
  const W = window.innerWidth || 1, H = window.innerHeight || 1;
  if (!(r > l && b > t)) return null;
  return { x: Math.max(0, l / W), y: Math.max(0, t / H), w: Math.min(1, (r - l) / W), h: Math.min(1, (b - t) / H) };
}
// FReader: 모든 쪽의 크기 [너비, 높이] (스크롤 보기에서 쪽 자리를 먼저 잡아 두고 그림은 차례로 채움)
function pageSizes() { return pages.map(p => [Number(p.width) || 0, Number(p.height) || 0]); }
function fitPages() {
  const frames = [...host.children]; if (!frames.length) return;
  const totalWidth = frames.reduce((sum, f) => sum + Number(f.dataset.width), 0);
  const height = Math.max(...frames.map(f => Number(f.dataset.height)));
  const scale = Math.max(0.01, Math.min((host.clientWidth - 8 * (frames.length - 1)) / totalWidth, host.clientHeight / height));
  for (const frame of frames) {
    frame.style.width = `${Number(frame.dataset.width) * scale}px`;
    frame.style.height = `${Number(frame.dataset.height) * scale}px`;
    frame.firstElementChild.style.transform = `scale(${scale})`;
  }
}
// FReader: 쪽 뒤 바탕 = 문서 자체 배경색(있으면) > 앱 테마 색(흰색/검은색). 쪽 사이 간격 줄은 고정 색
function applyBackdrop() {
  const root = document.documentElement.style;
  const fileBg = options.docxLayout?.pageBackground;
  if (fileBg) root.setProperty('--file-page', fileBg); else root.removeProperty('--file-page');
  const backdrop = fileBg || options.backdrop;
  if (backdrop) root.setProperty('--backdrop', backdrop); else root.removeProperty('--backdrop');
}
function configure(next = {}) {
  const oldSpread = options.spread; options = { ...options, ...next };
  document.body.dataset.theme = ['white', 'sepia', 'dark'].includes(options.theme) ? options.theme : 'white';
  applyBackdrop();
  host.classList.toggle('rtl', !!options.rtl);
  if (docReady && pages.length && 'vertical' in next && !!next.vertical !== vertical) return setVertical(!!next.vertical);
  if (!docReady) return;
  if (vertical) return;
  if (oldSpread !== options.spread) return render();
  fitPages();
}
async function display(position) {
  if (!pages.length) return;
  const saved = /^(?:docx|doc):(\d+)$/.exec(String(position));
  page = clampPage(saved ? Number(saved[1]) : Number(position));
  if (vertical) { vGoto(page); reportLocation(); return; }
  await render(); reportLocation();
}
function next() { if (vertical) return vScrollBy(1); return display(page + (options.spread ? 2 : 1)); }
function previous() { if (vertical) return vScrollBy(-1); return display(page - (options.spread ? 2 : 1)); }
function progress(value) { return display(Math.round(Math.max(0, Math.min(1, Number(value))) * (pages.length - 1))); }
function highlightSelection() {
  const selection = window.getSelection();
  if (!selection?.rangeCount || selection.isCollapsed) return;
  for (const frame of pageFrames()) {
    const bounds = frame.getBoundingClientRect();
    for (const rect of selection.getRangeAt(0).getClientRects()) {
      if (rect.width < 1 || rect.height < 1 || rect.left < bounds.left - 1 || rect.right > bounds.right + 1 || rect.top < bounds.top - 1 || rect.bottom > bounds.bottom + 1) continue;
      const mark = document.createElement('span');
      Object.assign(mark.style, { position: 'absolute', pointerEvents: 'none', background: '#ffc107', opacity: '.35', left: `${rect.left - bounds.left}px`, top: `${rect.top - bounds.top}px`, width: `${rect.width}px`, height: `${rect.height}px` });
      frame.appendChild(mark);
    }
  }
  selection.removeAllRanges();
}
function destroy() {
  disposed = true; generation++; clearInterval(bridgeTimer); resizeObserver.disconnect();
  worker.terminate(); requests.forEach(resolve => resolve({ type: 'closed' })); requests.clear();
  if (incoming) incoming.fill(0); incoming = null; received = 0;
  clearPages(); pendingEvents = [];
}
const resizeObserver = new ResizeObserver(fitPages); resizeObserver.observe(host);
// ── FReader: 스크롤 보기 — 쪽을 그대로 세로로 늘어놓고 쪽 사이를 살짝 띄움 (보이는 쪽 근처만 그림) ──
let vertical = false, vhost = null, vSlots = [], vTops = [], vRaf = 0, vMetricsTimer = 0, vSerial = 0;
const vMounted = new Map(); // 쪽 번호 → { frame, source, original, entry }
const vOwner = new Map(); // 원래 글 덩어리 → 그것을 쓰고 있는 쪽 번호 (다른 쪽은 복사본)
const V_GAP = 12;
function pageFrames() { return vertical ? [...vMounted.values()].map(m => m.frame) : [...host.children]; }
const vResize = new ResizeObserver(() => { if (vertical) vLayout(true); });
function setVertical(on) {
  on = !!on;
  if (on === vertical) return;
  if (on) {
    vertical = true;
    renderSerial++;
    for (const frame of host.children) {
      for (const img of frame.querySelectorAll('img[data-resource]')) img.removeAttribute('src');
      const source = frame.firstElementChild;
      if (originalSources.has(source)) measure.appendChild(source);
    }
    host.replaceChildren(); host.style.display = 'none';
    vhost = document.createElement('div'); vhost.id = 'vpages';
    document.body.appendChild(vhost);
    vhost.addEventListener('scroll', vSchedule, { passive: true });
    vResize.observe(vhost);
    vZoomListen(vhost);
    vLayout(false);
    vGoto(page);
  } else {
    vertical = false;
    vResize.disconnect();
    for (const index of [...vMounted.keys()]) vUnmount(index);
    vhost?.remove(); vhost = null; vSlots = []; vTops = []; vZoom = 1; vPinch = null;
    host.style.display = '';
    void render().then(reportLocation);
  }
}
// ── FReader: 스크롤 보기 두 손가락 확대·축소 (줄이면 쪽이 작아져 가운데에, 늘리면 옆으로도 움직일 수 있음) ──
let vZoom = 1, vPinch = null;
const V_ZOOM_MIN = 0.5, V_ZOOM_MAX = 3;
function vTouchInfo(t) {
  return { d: Math.hypot(t[0].clientX - t[1].clientX, t[0].clientY - t[1].clientY), x: (t[0].clientX + t[1].clientX) / 2, y: (t[0].clientY + t[1].clientY) / 2 };
}
function vPinchStart(e) {
  if (!vertical || !vhost || e.touches.length !== 2) return;
  const t = vTouchInfo(e.touches);
  vPinch = { d0: Math.max(1, t.d), z0: vZoom, fx: t.x, fy: t.y, dx: 0, dy: 0, z: vZoom };
  vhost.style.transformOrigin = `${t.x}px ${t.y}px`;
  e.preventDefault();
}
function vPinchMove(e) {
  if (!vPinch || !vhost) return;
  e.preventDefault();
  if (e.touches.length !== 2) return;
  const t = vTouchInfo(e.touches);
  vPinch.z = Math.max(V_ZOOM_MIN, Math.min(V_ZOOM_MAX, vPinch.z0 * t.d / vPinch.d0));
  vPinch.dx = t.x - vPinch.fx; vPinch.dy = t.y - vPinch.fy;
  vhost.style.transform = `translate(${vPinch.dx}px, ${vPinch.dy}px) scale(${vPinch.z / vPinch.z0})`;
}
function vPinchEnd(e) {
  if (!vPinch || !vhost) return;
  if (e.touches.length >= 2) return;
  const p = vPinch; vPinch = null;
  // 손가락 가운데 있던 글 자리를 기억해 두었다가, 새 크기로 다시 놓은 뒤 같은 자리에 오게
  const cy = vhost.scrollTop + p.fy, i = vIndexAt(cy), slot = vSlots[i];
  const sh = Math.max(1, slot ? slot.offsetHeight : 1), sw = Math.max(1, slot ? slot.offsetWidth : 1);
  const fy = (cy - vTops[i]) / sh, fx = (vhost.scrollLeft + p.fx - (slot ? slot.offsetLeft : 0)) / sw;
  vhost.style.transform = ''; vhost.style.transformOrigin = '';
  let z = p.z; if (Math.abs(z - 1) < 0.05) z = 1;
  if (z === vZoom) return;
  vZoom = z;
  vLayout(true);
  const s2 = vSlots[i];
  if (!s2) return;
  vhost.scrollTop = vTops[i] + fy * s2.offsetHeight - (p.fy + p.dy);
  vhost.scrollLeft = s2.offsetLeft + fx * s2.offsetWidth - (p.fx + p.dx);
  vUpdate(); vReportMetrics();
}
function vZoomListen(el) {
  el.addEventListener('touchstart', vPinchStart, { passive: false });
  el.addEventListener('touchmove', vPinchMove, { passive: false });
  el.addEventListener('touchend', vPinchEnd);
  el.addEventListener('touchcancel', vPinchEnd);
}
/** 확대 배율에 맞춘 쪽 너비 */
function vPageWidth() { return (innerWidth || vhost.clientWidth) * vZoom; }
/** 화면보다 좁게 줄였으면 쪽을 가로 가운데에 */
function vPlaceSlot(slot, W) {
  const VW = innerWidth || vhost.clientWidth;
  slot.style.marginLeft = W < VW - 0.5 ? `${Math.floor((VW - W) / 2)}px` : '';
}
function vLayout(keep) {
  if (!vhost || !pages.length) return;
  const W = vPageWidth();
  vhost.style.overflowX = vZoom > 1.001 ? 'auto' : 'hidden';
  let anchor = page, frac = 0;
  if (keep && vTops.length) {
    const st = vhost.scrollTop;
    anchor = vIndexAt(st);
    frac = (st - vTops[anchor]) / Math.max(1, vTops[anchor + 1] - vTops[anchor]);
  }
  for (const index of [...vMounted.keys()]) vUnmount(index);
  if (vSlots.length !== pages.length) {
    vhost.replaceChildren();
    vSlots = [];
    for (let i = 0; i < pages.length; i++) {
      const slot = document.createElement('div'); slot.className = 'vslot'; slot.dataset.page = String(i);
      vhost.appendChild(slot); vSlots.push(slot);
    }
  }
  vTops = []; let y = 0;
  pages.forEach((entry, i) => {
    const sh = entry.width > 0 ? W * entry.height / entry.width : W * 1.414;
    vSlots[i].style.width = `${W}px`; vSlots[i].style.height = `${sh}px`; vPlaceSlot(vSlots[i], W);
    vTops.push(y); y += sh + V_GAP;
  });
  vTops.push(y);
  // 쪽이 화면보다 짧으면(1쪽뿐인 문서 등) 위에 붙이지 않고 화면 가운데에
  const total = y - V_GAP, viewH = innerHeight || vhost.clientHeight;
  const pad = total < viewH ? Math.floor((viewH - total) / 2) : 0;
  if (vSlots.length) {
    vSlots[0].style.marginTop = pad ? `${pad}px` : '';
    vSlots[vSlots.length - 1].style.marginBottom = pad ? '0px' : '';
  }
  if (pad) for (let i = 0; i < vTops.length; i++) vTops[i] += pad;
  vhost.scrollTop = vTops[anchor] + frac * (vTops[anchor + 1] - vTops[anchor]);
  vUpdate();
}
function vIndexAt(y) {
  let lo = 0, hi = pages.length - 1;
  while (lo < hi) { const mid = (lo + hi + 1) >> 1; if (vTops[mid] <= y) lo = mid; else hi = mid - 1; }
  return lo;
}
function vGoto(index) {
  if (!vhost || !vTops.length) return;
  vhost.scrollTop = vTops[clampPage(index)];
  vUpdate();
}
function vScrollBy(dir) { vhost?.scrollBy({ top: dir * (innerHeight || vhost.clientHeight) * 0.9, behavior: 'smooth' }); }
function vScrollToRatio(t) {
  if (!vhost) return;
  vhost.scrollTop = Math.max(0, Math.min(1, Number(t) || 0)) * Math.max(0, vhost.scrollHeight - vhost.clientHeight);
}
function vSchedule() {
  if (!vRaf) vRaf = requestAnimationFrame(() => { vRaf = 0; vUpdate(); });
  if (!vMetricsTimer) vMetricsTimer = setTimeout(() => { vMetricsTimer = 0; vReportMetrics(); }, 30);
}
function vReportMetrics() {
  if (vhost) emit('scrollMetrics', { top: vhost.scrollTop, height: vhost.scrollHeight, client: vhost.clientHeight });
}
function vMount(index) {
  if (vMounted.has(index) || !pages[index]) return;
  const entry = pages[index];
  const original = !vOwner.has(entry.source);
  const source = original ? entry.source : entry.source.cloneNode(true);
  if (original) vOwner.set(entry.source, index);
  preparePageSource(source, entry, index);
  const slot = vSlots[index], W = parseFloat(slot.style.width) || vhost.clientWidth, scale = W / entry.width;
  const frame = document.createElement('section');
  frame.className = 'page'; frame.dataset.page = String(index);
  frame.dataset.width = String(entry.width); frame.dataset.height = String(entry.height);
  frame.style.width = `${entry.width * scale}px`; frame.style.height = `${entry.height * scale}px`;
  source.style.transform = `scale(${scale})`;
  frame.appendChild(source); slot.appendChild(frame);
  vMounted.set(index, { frame, source, original, entry });
  renderNoteAreas([frame]);
  void vLoadImages(frame, vSerial);
}
function vUnmount(index) {
  const m = vMounted.get(index); if (!m) return;
  for (const img of m.frame.querySelectorAll('img[data-resource]')) img.removeAttribute('src');
  if (m.original) { measure.appendChild(m.source); vOwner.delete(m.entry.source); }
  m.frame.remove(); vMounted.delete(index);
}
/** 이 쪽이 원래 글 덩어리를 쓰게 (찾은 낱말 형광펜은 원래 글에만 칠해짐) */
function vEnsureOriginal(index) {
  const m = vMounted.get(index); if (!m || m.original) return;
  const owner = vOwner.get(m.entry.source);
  if (owner != null) vUnmount(owner);
  vUnmount(index); vMount(index);
  if (owner != null) vMount(owner);
}
async function vLoadImages(frame, serial) {
  const imgs = [...frame.querySelectorAll('img[data-resource]')].filter(img => {
    const clip = (img.closest('.freader-content') || img.closest('.page')).getBoundingClientRect();
    return [...img.getClientRects()].some(r => r.width > 0 && r.height > 0 && r.right > clip.left + .1 && r.left < clip.right - .1 && r.bottom > clip.top + .1 && r.top < clip.bottom - .1);
  });
  for (const img of imgs) activeImagePaths.add(img.dataset.resource);
  for (const img of imgs) {
    if (!frame.isConnected || serial !== vSerial || disposed) return;
    try {
      const item = await imageFor(img.dataset.resource);
      if (!frame.isConnected) return;
      img.loading = 'eager'; img.src = item.url;
    } catch (error) { if (frame.isConnected) missingImage(img, error); }
  }
}
function vUpdate() {
  if (!vhost || !vTops.length || disposed) return;
  const st = vhost.scrollTop, H = vhost.clientHeight || innerHeight;
  const first = vIndexAt(st), last = vIndexAt(st + H);
  const current = vIndexAt(st + H * 0.33);
  if (current !== page) { page = current; reportLocation(); }
  let removed = false;
  for (const index of [...vMounted.keys()]) if (index < first - 3 || index > last + 3) { vUnmount(index); removed = true; }
  if (removed) {
    activeImagePaths = new Set();
    for (const m of vMounted.values()) for (const img of m.frame.querySelectorAll('img[data-resource][src]')) activeImagePaths.add(img.dataset.resource);
    trimImages();
  }
  const want = [];
  for (let i = Math.max(0, first - 1); i <= Math.min(pages.length - 1, last + 1); i++) if (!vMounted.has(i)) want.push(i);
  want.sort((a, b) => (a >= first && a <= last ? 0 : 1) - (b >= first && b <= last ? 0 : 1));
  let made = 0;
  for (const i of want) {
    if (made >= 2) { vSchedule(); break; }
    try { vMount(i); made++; } catch (error) { console.warn(error); }
  }
  if (made) applySearchHighlights();
}
// ── 파일 내 단어 검색: 찾은 곳은 노란 형광펜(CSS Highlight), 지금 보는 결과는 조금 진하게 ──
let searchState = { query: '', results: [], current: -1 };
function searchNorm(text) { return text.replace(/\u00a0/g, ' ').toLowerCase(); }
function textBlocksOf(root) {
  const blocks = []; let current = null;
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
    acceptNode(node) {
      const el = node.parentElement;
      if (!el || !node.data) return NodeFilter.FILTER_REJECT;
      if (el.closest('.docx-note-area, .odr-list-marker, style, script, .freader-missing-image')) return NodeFilter.FILTER_REJECT;
      return NodeFilter.FILTER_ACCEPT;
    },
  });
  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    const key = node.parentElement.closest('x-p, li, td, th') || node.parentElement;
    if (!current || current.key !== key) { current = { key, nodes: [], text: '' }; blocks.push(current); }
    current.nodes.push({ node, start: current.text.length });
    current.text += node.data;
  }
  return blocks;
}
function pointAt(block, index) {
  let lo = 0;
  for (let i = 0; i < block.nodes.length; i++) if (block.nodes[i].start <= index) lo = i;
  const item = block.nodes[lo];
  return { node: item.node, offset: Math.min(item.node.data.length, index - item.start) };
}
async function search(query) {
  const q = searchNorm(String(query || '').trim());
  searchState = { query: q, results: [], current: -1 };
  if (!q || !pages.length) { applySearchHighlights(); return { count: 0, pages: [] }; }
  const pageOf = new Map();
  pages.forEach((entry, index) => {
    if (!pageOf.has(entry.source)) pageOf.set(entry.source, []);
    pageOf.get(entry.source)[entry.column] = index;
  });
  const results = [];
  for (const [source, columns] of pageOf) {
    const inner = source.querySelector('.freader-columns') || source.querySelector('.odr-page-inner');
    if (!inner) continue;
    const entry = pages[columns.find(i => i != null)];
    const innerRect = inner.getBoundingClientRect();
    const scale = inner.offsetWidth ? innerRect.width / inner.offsetWidth : 1;
    const stride = (entry.columnStride || entry.bodyWidth || inner.offsetWidth) * (scale || 1);
    for (const block of textBlocksOf(inner)) {
      const hay = searchNorm(block.text);
      for (let at = hay.indexOf(q); at >= 0; at = hay.indexOf(q, at + q.length)) {
        const start = pointAt(block, at), end = pointAt(block, at + q.length);
        const range = document.createRange();
        try { range.setStart(start.node, start.offset); range.setEnd(end.node, end.offset); } catch (_) { continue; }
        const rect = [...range.getClientRects()].find(r => r.width > 0 || r.height > 0);
        let column = 0;
        if (rect && stride > 0) column = Math.max(0, Math.floor((rect.left - innerRect.left + 0.5) / stride));
        const pageIndex = columns[Math.min(column, columns.length - 1)] ?? columns.find(i => i != null);
        if (pageIndex == null) continue;
        results.push({ page: pageIndex, start, end });
      }
    }
  }
  results.sort((a, b) => a.page - b.page);
  searchState.results = results;
  applySearchHighlights();
  return { count: results.length, pages: results.map(r => r.page) };
}
async function showSearchResult(index) {
  const r = searchState.results[index]; if (!r) return;
  searchState.current = index;
  if (vertical) { page = r.page; vGoto(r.page); vEnsureOriginal(r.page); applySearchHighlights(); reportLocation(); return; }
  const shown = [...host.children].some(frame => Number(frame.dataset.page) === r.page);
  if (shown) { applySearchHighlights(); return; }
  await display(r.page);
}
function clearSearch() { searchState = { query: '', results: [], current: -1 }; applySearchHighlights(); }
function applySearchHighlights() {
  if (typeof CSS === 'undefined' || !CSS.highlights || typeof Highlight === 'undefined') return;
  CSS.highlights.delete('freader-search'); CSS.highlights.delete('freader-search-current');
  if (!searchState.results.length) return;
  const container = vertical && vhost ? vhost : host;
  const visible = new Set(pageFrames().map(frame => Number(frame.dataset.page)));
  const all = [], current = [];
  searchState.results.forEach((r, i) => {
    if (!visible.has(r.page) || !r.start.node.isConnected || !container.contains(r.start.node)) return;
    const range = document.createRange();
    try { range.setStart(r.start.node, r.start.offset); range.setEnd(r.end.node, r.end.offset); } catch (_) { return; }
    (i === searchState.current ? current : all).push(range);
  });
  if (all.length) CSS.highlights.set('freader-search', new Highlight(...all));
  if (current.length) CSS.highlights.set('freader-search-current', new Highlight(...current));
}
/** 문단(글 덩어리)마다 글, 쪽, 굵기(전체/비율), 가운데 정렬, 글자 크기, 표 안인지 */
function outlineBlocks() {
  const pageOf = new Map(), blocks = [];
  pages.forEach((entry, index) => {
    if (!pageOf.has(entry.source)) pageOf.set(entry.source, []);
    pageOf.get(entry.source)[entry.column] = index;
  });
  for (const [source, columns] of pageOf) {
    const inner = source.querySelector('.freader-columns') || source.querySelector('.odr-page-inner');
    if (!inner) continue;
    const entry = pages[columns.find(i => i != null)];
    const innerRect = inner.getBoundingClientRect();
    const scale = inner.offsetWidth ? innerRect.width / inner.offsetWidth : 1;
    const stride = (entry.columnStride || entry.bodyWidth || inner.offsetWidth) * (scale || 1);
    for (const block of textBlocksOf(inner)) {
      let text = block.text.replace(/\s+/g, ' ').trim();
      if (!text) continue;
      // 자동 번호(1. 2. …)는 글이 아니라 따로 붙은 표시라서 앞에 붙여 줌 (목차의 '번호로 시작하는 줄' 판단용)
      const marker = block.key instanceof Element ? block.key.querySelector(':scope > .odr-list-marker')?.textContent?.trim() : '';
      if (marker && !text.startsWith(marker)) text = `${marker} ${text}`;
      let chars = 0, bold = 0, column = 0, fs = 0;
      for (const { node } of block.nodes) {
        const n = node.data.trim().length;
        if (!n) continue;
        chars += n;
        const cs = getComputedStyle(node.parentElement);
        fs = Math.max(fs, parseFloat(cs.fontSize) || 0);
        if ((parseInt(cs.fontWeight, 10) || 400) >= 600) bold += n;
      }
      if (!chars) continue;
      const range = document.createRange();
      try { range.selectNodeContents(block.nodes[0].node); } catch (_) {}
      const rect = [...range.getClientRects()].find(r => r.width > 0 || r.height > 0);
      if (rect && stride > 0) column = Math.max(0, Math.floor((rect.left - innerRect.left + 0.5) / stride));
      const page = columns[Math.min(column, columns.length - 1)] ?? columns.find(i => i != null);
      if (page == null) continue;
      let centered = false;
      try { centered = block.key instanceof Element && getComputedStyle(block.key).textAlign === 'center'; } catch (_) {}
      // 한 문단 안에서 줄을 바꿔(Shift+Enter) 붙인 부제목은 목차 제목에서 뺌: 첫 줄만
      let head = text;
      const br = block.key instanceof Element ? block.key.querySelector('br') : null;
      if (br) {
        const first = block.nodes.filter(({ node }) => node.compareDocumentPosition(br) & Node.DOCUMENT_POSITION_FOLLOWING)
          .map(({ node }) => node.data).join('').replace(/\s+/g, ' ').trim();
        if (first) head = marker && !first.startsWith(marker) ? `${marker} ${first}` : first;
      }
      blocks.push({ text, head, page, chars, fs, bold: bold >= chars * 0.9, boldRatio: bold / chars, centered, cell: !!block.key.closest?.('td, th') });
    }
  }
  return blocks;
}
/** 지금 화면에 보이는 글(낱말)과 그 위치 (화면 크기 대비 0~1) — 내보낸 PDF에 보이지 않는 글자 층을 넣는 데 씀 */
function visibleTextBoxes() {
  const W = innerWidth || 1, H = innerHeight || 1, out = [];
  const walker = document.createTreeWalker(host, NodeFilter.SHOW_TEXT), range = document.createRange();
  for (let node = walker.nextNode(); node && out.length < 20000; node = walker.nextNode()) {
    const data = node.data;
    if (!data.trim() || !node.parentElement) continue;
    const word = /\S+/g;
    for (let m = word.exec(data); m; m = word.exec(data)) {
      try { range.setStart(node, m.index); range.setEnd(node, m.index + m[0].length); } catch (_) { continue; }
      const r = [...range.getClientRects()].find(rect => rect.width >= 0.5 && rect.height >= 0.5);
      if (!r || r.right <= 0 || r.bottom <= 0 || r.left >= W || r.top >= H) continue;
      out.push({ t: m[0], x: r.left / W, y: r.top / H, w: r.width / W, h: r.height / H });
    }
  }
  return out;
}
/** 쪽마다의 글 (문단마다 줄바꿈) — 앱이 '목차' 쪽을 찾는 데 씀 */
function pageText(from, to) {
  if (!pages.length) return [];
  if (!outlineBlockCache) outlineBlockCache = outlineBlocks();
  const end = Math.min(pages.length, Math.max(0, to | 0));
  const out = [];
  for (let i = Math.max(0, from | 0); i < end; i++) out.push([]);
  for (const b of outlineBlockCache) if (b.page >= from && b.page < end) out[b.page - from].push(b.text);
  return out.map(lines => lines.join('\n'));
}
// ── 목차 후보: 번호로 시작하거나 굵은 글씨가 있는 짧은 문단 {title, page, bold, boldRatio, centered, fs} (표 안 제외)
// 앱이 '목차 쪽 → 번호 → 굵은 글씨(가운데 정렬 또는 전체 굵게)' 순서로 고른다 ──
const NUMBERED_START = /^\s*(?:[ⅠⅡⅢⅣⅤⅥⅦⅧⅨⅩⅪⅫ]|[IVX]{1,5}\s*[.)]|\(\s*\d|\d)/;
function headingCandidates() {
  if (!pages.length) return [];
  if (!outlineBlockCache) outlineBlockCache = outlineBlocks();
  // 본문 글자 크기 = 문서 전체에서 가장 많이 쓴 크기 (글자 수 기준)
  const sizeChars = new Map();
  for (const b of outlineBlockCache) if (b.fs > 0) sizeChars.set(b.fs, (sizeChars.get(b.fs) || 0) + b.chars);
  let body = 0, most = -1;
  for (const [k, n] of sizeChars) if (n > most) { most = n; body = k; }
  return outlineBlockCache.filter(b => !b.cell && (b.head || b.text).length <= 100 && (NUMBERED_START.test(b.head || b.text) || b.boldRatio >= 0.5))
    .slice(0, 3000).map(b => ({ title: b.head || b.text, page: b.page, bold: b.bold, boldRatio: b.boldRatio, centered: b.centered, fs: b.fs, body }));
}
window.freaderDocx = { beginDocument, appendChunk, openDocument, configure, display, next, previous, progress, highlightSelection, destroy, setVertical, scrollToRatio: vScrollToRatio,
  search, showSearchResult, clearSearch, headingCandidates, pageText, visibleTextBoxes, pageRect, pageSizes,
  getState: () => ({ ready, page, count: pages.length, received, spread: options.spread, awaitingPassword, unavailableImages, imageCacheBytes, cachedImages: imageCache.size, visibleImages: activeImagePaths.size, maxBytes: MAX_BYTES, format: detectedFormat }) };
window.addEventListener('pagehide', destroy, { once: true });
