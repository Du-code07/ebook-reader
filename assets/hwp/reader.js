// Thin, read-only FReader host. The vendored rhwp engine is unmodified.
const host = document.getElementById('pages');
const MAX_BYTES = 256 * 1024 * 1024;
const CACHE_BYTES = 12 * 1024 * 1024;
const cache = new Map();
const fonts = new Map();
let activeEntries = new Set();
let cachedBytes = 0;
let engine, doc, incoming, received = 0;
let page = 0, count = 0, renderSerial = 0, disposed = false;
let options = { theme: 'white', spread: false, rtl: false, position: null, progress: 0 };
let readyReported = false;
let pendingEvents = [];
let flushingEvents = false;

function bridge() {
  return window.flutter_inappwebview?.callHandler ? window.flutter_inappwebview : null;
}
function emit(type, data = {}) {
  pendingEvents.push({ type, ...data });
  void flushEvents();
  retryBridge();
}
async function flushEvents() {
  if (!bridge() || flushingEvents || disposed) return;
  flushingEvents = true;
  try {
    while (pendingEvents.length && !disposed) {
      // A handler can exist before Android's platform bridge is ready. Keep
      // the event until native acknowledges it, including the initial ready.
      await bridge().callHandler('freaderHwp', pendingEvents[0]);
      pendingEvents.shift();
    }
  } catch (_) {
    // The platform-ready event or interval retries without losing ordering.
  } finally { flushingEvents = false; }
}
window.addEventListener('flutterInAppWebViewPlatformReady', flushEvents);
// FReader(배터리): 보낼 알림이 남아 있을 때만 0.15초마다 다시 시도한다 (예전에는 책을 펴 둔 내내 계속 깨어 있었음)
let bridgeTimer = 0;
function retryBridge() {
  if (bridgeTimer || disposed) return;
  bridgeTimer = setInterval(() => {
    if (disposed || !pendingEvents.length) { clearInterval(bridgeTimer); bridgeTimer = 0; return; }
    void flushEvents();
  }, 150);
}

function fail(error) {
  const message = String(error?.message || error).slice(0, 600);
  emit('error', { message });
  return false;
}
function fontKind(name) {
  if (/equation|hwp.?eq|hancom.?eq|math|수식/i.test(name)) return 'math';
  return /바탕|명조|궁서|batang|myeong|serif|times|cambria/i.test(name) ? 'serif' : 'sans';
}
// 같은 크기(글자 폭)로 만든 무료 글꼴 (Arial·Times New Roman·Courier New·Calibri·Cambria 대신, 영문 부분만)
const METRIC_FONTS = [
  [/^(arial|helvetica|arimo|liberation sans)$/i, 'LiberationSans'],
  [/^(times new roman|times|tinos|liberation serif)$/i, 'LiberationSerif'],
  [/^(courier new|courier|cousine|liberation mono)$/i, 'LiberationMono'],
  [/^(calibri|carlito)$/i, 'Carlito'],
  [/^(cambria|caladea)$/i, 'Caladea'],
];
const LATIN_RANGE = 'U+0000-024F, U+2000-206F, U+20A0-20CF, U+2100-214F';
function metricFont(name) {
  const n = String(name).replace(/^DOCX /, '').trim();
  for (const [re, base] of METRIC_FONTS) if (re.test(n)) return base;
  return null;
}
// 사용자가 넣은 글꼴 중 이 이름의 것 (기기에 없는 원래 글꼴 대신 씀)
// 한컴바탕·한컴돋움이 없으면 사용자가 넣은 함초롬바탕·함초롬돋움으로 대신 보여 줌
const USER_FONT_ALIASES = [
  [/^(한컴\s?바탕|hancom\s?batang|haansoft\s?batang)$/i, ['함초롬바탕', 'hcr batang', '함초롬 바탕']],
  [/^(한컴\s?돋움|hancom\s?dotum|haansoft\s?dotum)$/i, ['함초롬돋움', 'hcr dotum', '함초롬 돋움']],
];
function userFontFacesExact(n) {
  return (options.userFonts || []).filter(f => (f.n || []).some(x => String(x).trim().toLowerCase() === n));
}
function userFontFaces(name) {
  const n = String(name).replace(/^DOCX /, '').trim().toLowerCase();
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
async function addUserFaces(name, faces) {
  await Promise.all(faces.map(async f => {
    try {
      const face = new FontFace(name, `url(/userfonts/${encodeURIComponent(f.f)})`, { weight: String(f.w || 400), style: f.i ? 'italic' : 'normal' });
      await face.load(); document.fonts.add(face);
    } catch (e) {}
  }));
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
async function loadFontAliases(names) {
  await Promise.all([...new Set(names)].slice(0, 128).map(async raw => {
    const name = String(raw).trim();
    if (!name || name.length > 160 || fonts.has(name)) return;
    const user = userFontFaces(name);
    if (user.length) {
      // 사용자 글꼴: 굵은 글꼴이 없으면 브라우저가 굵게 만들어 그림
      const job = addUserFaces(name, user);
      fonts.set(name, job);
      await job;
      return;
    }
    const free = freeFont(name);
    if (free) {
      const job = addFreeFaces(name, free, '../docx/fonts/free');
      fonts.set(name, job);
      await job;
      return;
    }
    const kind = fontKind(name);
    const basename = kind === 'math' ? 'LatinModernMath' : kind === 'serif' ? 'NotoSerifKR' : 'NotoSansKR';
    const metric = kind === 'math' ? null : metricFont(name);
    const job = Promise.all((kind === 'math' ? [400] : [400, 700]).map(async weight => {
      const suffix = weight === 700 ? 'Bold' : 'Regular';
      const face = new FontFace(name, `url(fonts/${basename}-${suffix}.woff2)`, { weight: String(weight) });
      await face.load(); document.fonts.add(face);
      if (metric) {
        // 나중에 넣은 글꼴부터 쓰므로 영문은 같은 폭 글꼴, 한글은 본고딕/본명조
        const latin = new FontFace(name, `url(../docx/fonts/metric/${metric}-${suffix}.woff2)`, { weight: String(weight), unicodeRange: LATIN_RANGE });
        try { await latin.load(); document.fonts.add(latin); } catch (e) {}
      }
    }));
    fonts.set(name, job);
    await job;
  }));
}
function installFontMeasurement() {
  const ctx = document.createElement('canvas').getContext('2d');
  if (!ctx) throw new Error('문서 표시용 Canvas를 초기화하지 못했어요');
  globalThis.measureTextWidth = (font, text) => {
    const fallback = fontKind(font) === 'serif' ? 'FReaderSerif' : fontKind(font) === 'math' ? 'FReaderMath' : 'FReaderSans';
    ctx.font = `${font}, ${fallback}`;
    return ctx.measureText(text).width;
  };
}
let docReady = false;
function configure(next = {}) {
  const previousSpread = options.spread;
  options = { ...options, ...next };
  document.body.dataset.theme = ['white', 'sepia', 'dark'].includes(options.theme) ? options.theme : 'white';
  // FReader: 쪽 뒤 바탕 = 앱 테마 색 (흰색/검은색). 쪽 사이 간격 줄은 고정 색
  if (options.backdrop) document.documentElement.style.setProperty('--backdrop', options.backdrop);
  else document.documentElement.style.removeProperty('--backdrop');
  host.classList.toggle('rtl', !!options.rtl);
  // FReader: 문서를 다 연 뒤에만 스크롤 보기를 켜고 끔 (여는 도중이면 열 때 한 번에 맞춤)
  if (!docReady) return;
  if (doc && 'vertical' in next && !!next.vertical !== vertical) return setVertical(!!next.vertical);
  if (vertical) return;
  if (doc && previousSpread !== options.spread) return render();
  fitPages();
}
function beginDocument(length, config) {
  if (!Number.isSafeInteger(length) || length < 1 || length > MAX_BYTES) throw new Error('열 수 있는 문서 크기는 256MB 이하예요');
  releaseDocument();
  incoming = new Uint8Array(length); received = 0;
  configure(config);
  return true;
}
function appendChunk(offset, encoded) {
  if (!incoming || offset !== received) throw new Error('문서 전송 순서가 올바르지 않아요');
  const binary = atob(encoded);
  if (received + binary.length > incoming.length) throw new Error('문서 전송 크기가 일치하지 않아요');
  for (let i = 0; i < binary.length; i++) incoming[received + i] = binary.charCodeAt(i);
  received += binary.length;
  return received;
}
async function openDocument(password = null) {
  let candidate;
  try {
    if (disposed) return false;
    if (!incoming || received !== incoming.length) throw new Error('문서 데이터를 모두 받지 못했어요');
    candidate = password === null ? new engine.HwpDocument(incoming) : engine.HwpDocument.openWithPassword(incoming, password);
    password = null;
    const info = JSON.parse(candidate.getDocumentInfo());
    await loadFontAliases(info.fontsUsed || []);
    if (disposed) { candidate.free(); return false; }
    doc = candidate; candidate = null;
    count = doc.pageCount();
    if (count < 1) throw new Error('표시할 페이지가 없는 문서예요');
    const saved = /^hwp:(\d+)$/.exec(options.position || '');
    page = clampPage(saved ? Number(saved[1]) : Math.round(Number(options.progress || 0) * (count - 1)));
    incoming.fill(0); incoming = null; received = 0;
    if (vertical) setVertical(false);
    if (options.vertical) setVertical(true); else await render();
    if (disposed) return false;
    docReady = true;
    emit('loaded', { pageCount: count });
    reportLocation();
    return true;
  } catch (error) {
    if (candidate) candidate.free();
    const message = String(error?.message || error);
    if (message.includes('비밀번호가 필요한') || message.includes('비밀번호가 일치하지')) {
      emit('password', { incorrect: password !== null });
      return false;
    }
    if (/DRM/.test(message)) return fail('DRM으로 보호된 문서는 이 뷰어에서 열 수 없어요');
    return fail(error);
  } finally { password = null; }
}
function clampPage(value) { return Math.max(0, Math.min(count - 1, Number.isFinite(value) ? Math.trunc(value) : 0)); }
function reportLocation() { emit('location', { page, pageCount: count, position: `hwp:${page}`, progress: count > 1 ? page / (count - 1) : 1 }); }
async function display(position) {
  if (!doc) return;
  const match = /^hwp:(\d+)$/.exec(String(position));
  const target = clampPage(match ? Number(match[1]) : Number(position));
  page = target;
  if (vertical) { vGoto(page); reportLocation(); return; }
  try { await render(); reportLocation(); } catch (error) { fail(error); }
}
function next() { if (vertical) return vScrollBy(1); return display(page + (options.spread ? 2 : 1)); }
function previous() { if (vertical) return vScrollBy(-1); return display(page - (options.spread ? 2 : 1)); }
function progress(value) { return display(Math.round(Math.max(0, Math.min(1, Number(value))) * (count - 1))); }
function releaseEntry(entry) {
  for (const url of entry.urls) URL.revokeObjectURL(url);
  entry.urls = [];
}
function releaseIfUnused(entry) {
  if (!activeEntries.has(entry) && cache.get(entry.index) !== entry) releaseEntry(entry);
}
function svgForPage(index) {
  let entry = cache.get(index);
  if (entry) { cache.delete(index); cache.set(index, entry); return entry; }
  const source = doc.renderPageSvg(index), template = safeSvg(source), urls = [];
  let size = source.length * 2;
  try {
    for (const img of template.querySelectorAll('image')) {
      for (const attr of [...img.attributes]) {
        if (attr.localName !== 'href' || !attr.value.startsWith('data:image/')) continue;
        const uri = attr.value, comma = uri.indexOf(',');
        if (comma < 0) continue;
        const header = uri.slice(5, comma), mime = header.split(';')[0];
        let data;
        if (/;base64/i.test(header)) {
          const binary = atob(uri.slice(comma + 1));
          data = new Uint8Array(binary.length);
          for (let i = 0; i < binary.length; i++) data[i] = binary.charCodeAt(i);
        } else data = new TextEncoder().encode(decodeURIComponent(uri.slice(comma + 1)));
        const blob = new Blob([data], { type: mime }), url = URL.createObjectURL(blob);
        urls.push(url); attr.value = url; size += blob.size - uri.length * 2 + url.length * 2;
      }
    }
  } catch (error) { for (const url of urls) URL.revokeObjectURL(url); throw error; }
  entry = { index, template, urls, size: Math.max(0, size) };
  // Keep only recent pages. A single very large page is displayable, but is
  // released on navigation instead of expanding the cache indefinitely.
  if (entry.size <= CACHE_BYTES) {
    while (cache.size && (cache.size >= 4 || cachedBytes + entry.size > CACHE_BYTES)) {
      const oldest = cache.keys().next().value, removed = cache.get(oldest);
      cachedBytes -= removed.size; cache.delete(oldest); releaseIfUnused(removed);
    }
    cache.set(index, entry); cachedBytes += entry.size;
  }
  return entry;
}
function safeSvg(source) {
  const parsed = new DOMParser().parseFromString(source, 'image/svg+xml');
  const svg = parsed.documentElement;
  if (svg.localName !== 'svg' || parsed.querySelector('parsererror')) throw new Error('페이지를 표시할 SVG 데이터가 올바르지 않아요');
  for (const el of svg.querySelectorAll('*')) {
    if (['script', 'foreignObject', 'iframe', 'object', 'embed', 'style'].includes(el.localName)) { el.remove(); continue; }
    for (const attr of [...el.attributes]) {
      const name = attr.localName.toLowerCase();
      if (name.startsWith('on')) el.removeAttributeNode(attr);
      else if (name === 'href' && !attr.value.startsWith('#') &&
          !(el.localName === 'image' && /^data:image\/(png|jpeg|jpg|gif|webp|bmp|svg\+xml)[;,]/i.test(attr.value))) el.removeAttributeNode(attr);
    }
  }
  for (const attr of [...svg.attributes]) if (attr.localName.toLowerCase().startsWith('on')) svg.removeAttributeNode(attr);
  return document.importNode(svg, true);
}
async function render() {
  if (!doc || disposed) return;
  const serial = ++renderSerial;
  const fragment = document.createDocumentFragment(), nextEntries = new Set();
  const pages = options.spread && page + 1 < count ? [page, page + 1] : [page];
  for (const index of pages) {
    const entry = svgForPage(index); nextEntries.add(entry);
    const svg = entry.template.cloneNode(true);
    const box = svg.getAttribute('viewBox')?.trim().split(/[\s,]+/).map(Number);
    const width = box?.[2] || parseFloat(svg.getAttribute('width'));
    const height = box?.[3] || parseFloat(svg.getAttribute('height'));
    if (!(width > 0 && height > 0 && Number.isFinite(width + height))) throw new Error('문서 페이지 크기가 올바르지 않아요');
    const frame = document.createElement('section');
    frame.className = 'page'; frame.dataset.page = String(index);
    frame.dataset.width = String(width); frame.dataset.height = String(height);
    frame.setAttribute('aria-label', `${index + 1} / ${count}`);
    frame.appendChild(svg); fragment.appendChild(frame);
  }
  // FReader: 두 쪽 보기에서 마지막 쪽이 홀로 남으면 책처럼 왼쪽에 두고 오른쪽은 비워 둠
  if (options.spread && fragment.childElementCount === 1) {
    const only = fragment.firstElementChild, spacer = document.createElement('div');
    spacer.className = 'page-spacer'; spacer.dataset.width = only.dataset.width; spacer.dataset.height = only.dataset.height;
    Object.assign(spacer.style, { flex: 'none', visibility: 'hidden' });
    fragment.appendChild(spacer);
  }
  if (serial !== renderSerial || disposed) return;
  host.replaceChildren(fragment);
  const previousEntries = activeEntries; activeEntries = nextEntries;
  for (const entry of previousEntries) releaseIfUnused(entry);
  fitPages();
  applySearchHighlights();
  await new Promise(resolve => requestAnimationFrame(resolve));
  void finishPage(serial, [...nextEntries]);
}
// FReader: 쪽 안 그림을 다 풀면 'pageReady'를 알리고(앱이 이 쪽 화면을 저장해 다음에 먼저 띄움),
// 잠시 뒤 다음 쪽을 미리 만들어 둔다 (그림이 많은 쪽은 만드는 데 오래 걸림).
function decodeEntry(entry) {
  return Promise.all(entry.urls.map(url => { const probe = new Image(); probe.src = url; return probe.decode().catch(() => {}); }));
}
async function finishPage(serial, entries) {
  await Promise.all(entries.map(decodeEntry));
  await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
  if (disposed || serial !== renderSerial) return;
  emit('pageReady', { page, position: `hwp:${page}` });
  // FReader: 넘기기 전에 다음 쪽(두 쪽 보기면 두 쪽)과 이전 쪽을 미리 만들어 둠 → 넘길 때 빈 화면이 덜 보임
  setTimeout(() => {
    if (disposed || serial !== renderSerial || !doc) return;
    const span = options.spread ? 2 : 1;
    const order = [];
    for (let i = 0; i < span; i++) order.push(page + span + i);
    for (let i = 1; i <= span; i++) order.push(page - i);
    try {
      for (const index of order) {
        if (index >= 0 && index < count && !cache.has(index)) void decodeEntry(svgForPage(index));
      }
    } catch (_) {}
  }, 120);
}
// 지금 보이는 쪽(들)이 화면에서 차지하는 자리 (화면 크기 대비 0~1) — 스크롤 보기용 쪽 그림 자르기
// FReader: 두 쪽 보기의 홀수 마지막 쪽은 왼쪽에 놓고 오른쪽은 빈 자리(page-spacer)로 채움 → 실제 쪽만 셈
function realFrames() { return [...host.children].filter(f => f.classList.contains('page')); }
function pageRect() {
  const frames = realFrames(); if (!frames.length) return null;
  let l = 1e9, t = 1e9, r = -1e9, b = -1e9;
  const W = window.innerWidth || 1, H = window.innerHeight || 1, list = [];
  for (const f of frames) {
    const q = f.getBoundingClientRect(); l = Math.min(l, q.left); t = Math.min(t, q.top); r = Math.max(r, q.right); b = Math.max(b, q.bottom);
    list.push({ x: q.left / W, y: q.top / H, w: q.width / W, h: q.height / H });
  }
  if (!(r > l && b > t)) return null;
  return { x: Math.max(0, l / W), y: Math.max(0, t / H), w: Math.min(1, (r - l) / W), h: Math.min(1, (b - t) / H), frames: list };
}
// FReader: 앱에서 고른 글에 형광펜 (화면 크기 대비 0~1 네모들)
function highlightBoxes(boxes) {
  const W = window.innerWidth || 1, H = window.innerHeight || 1;
  markRects((boxes || []).map(b => ({ left: b.x * W, top: b.y * H, width: b.w * W, height: b.h * H, right: (b.x + b.w) * W, bottom: (b.y + b.h) * H })));
}
function fitPages() {
  const frames = [...host.children];
  if (!frames.length) return;
  const width = host.clientWidth, height = host.clientHeight;
  const totalWidth = frames.reduce((total, frame) => total + Number(frame.dataset.width), 0);
  const maxHeight = Math.max(...frames.map(frame => Number(frame.dataset.height)));
  const scale = Math.max(0.01, Math.min((width - (frames.length - 1) * 8) / totalWidth, height / maxHeight));
  for (const frame of frames) {
    frame.style.width = `${Number(frame.dataset.width) * scale}px`;
    frame.style.height = `${Number(frame.dataset.height) * scale}px`;
  }
}
function highlightSelection() {
  const selection = window.getSelection();
  if (!selection?.rangeCount || selection.isCollapsed) return;
  markRects([...selection.getRangeAt(0).getClientRects()]);
  selection.removeAllRanges();
}
function markRects(rects) {
  for (const frame of pageFrames()) {
    const svg = frame.firstElementChild, bounds = svg.getBoundingClientRect();
    const scale = Number(frame.dataset.width) / bounds.width;
    for (const box of rects) {
      if (box.width < 1 || box.height < 1 || box.left < bounds.left - 1 || box.right > bounds.right + 1 || box.top < bounds.top - 1 || box.bottom > bounds.bottom + 1) continue;
      const rect = document.createElementNS('http://www.w3.org/2000/svg', 'rect');
      for (const [key, value] of Object.entries({ x: (box.left - bounds.left) * scale, y: (box.top - bounds.top) * scale, width: box.width * scale, height: box.height * scale, fill: '#ffc107', opacity: 0.35, 'pointer-events': 'none' })) rect.setAttribute(key, String(value));
      svg.appendChild(rect);
    }
  }
}
function releaseDocument() {
  renderSerial++;
  docReady = false;
  if (vertical) {
    vertical = false; vResize.disconnect(); vMounted.clear();
    vhost?.remove(); vhost = null; vSlots = []; vTops = []; host.style.display = '';
  }
  if (doc) { doc.free(); doc = null; }
  layoutCache.clear(); searchState = { query: '', results: [], current: -1 };
  if (incoming) incoming.fill(0);
  incoming = null; received = 0; count = 0; page = 0;
  for (const entry of new Set([...cache.values(), ...activeEntries])) releaseEntry(entry);
  cache.clear(); activeEntries.clear(); cachedBytes = 0; host.replaceChildren();
}
function destroy() {
  disposed = true; clearInterval(bridgeTimer); resizeObserver.disconnect(); releaseDocument(); pendingEvents = [];
}
const resizeObserver = new ResizeObserver(fitPages); resizeObserver.observe(host);
// ── FReader: 스크롤 보기 — 쪽을 그대로 세로로 늘어놓고 쪽 사이를 살짝 띄움 (보이는 쪽 근처만 그림) ──
let vertical = false, vhost = null, vSlots = [], vTops = [], vRaf = 0, vMetricsTimer = 0;
const vMounted = new Map(); // 쪽 번호 → { frame, entry }
const V_GAP = 12;
function pageFrames() { return vertical ? [...vMounted.values()].map(m => m.frame) : realFrames(); }
const vResize = new ResizeObserver(() => { if (vertical) vLayout(true); });
function setVertical(on) {
  on = !!on;
  if (on === vertical) return;
  if (on) {
    vertical = true;
    renderSerial++;
    host.replaceChildren(); host.style.display = 'none';
    const old = activeEntries; activeEntries = new Set();
    for (const entry of old) releaseIfUnused(entry);
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
    void render().then(reportLocation).catch(fail);
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
  if (!vhost || !doc) return;
  const W = vPageWidth();
  vhost.style.overflowX = vZoom > 1.001 ? 'auto' : 'hidden';
  let anchor = page, frac = 0;
  if (keep && vTops.length) {
    const st = vhost.scrollTop;
    anchor = vIndexAt(st);
    frac = (st - vTops[anchor]) / Math.max(1, vTops[anchor + 1] - vTops[anchor]);
  }
  if (vSlots.length !== count) {
    for (const index of [...vMounted.keys()]) vUnmount(index);
    vhost.replaceChildren();
    vSlots = [];
    for (let i = 0; i < count; i++) {
      const slot = document.createElement('div'); slot.className = 'vslot'; slot.dataset.page = String(i);
      vhost.appendChild(slot); vSlots.push(slot);
    }
  }
  const sizes = pageSizes();
  vTops = []; let y = 0;
  for (let i = 0; i < count; i++) {
    const [w, h] = sizes[i] || [0, 0];
    const sh = w > 0 && h > 0 ? W * h / w : W * 1.414;
    vSlots[i].style.width = `${W}px`; vSlots[i].style.height = `${sh}px`; vPlaceSlot(vSlots[i], W);
    vTops.push(y); y += sh + V_GAP;
  }
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
  let lo = 0, hi = count - 1;
  while (lo < hi) { const mid = (lo + hi + 1) >> 1; if (vTops[mid] <= y) lo = mid; else hi = mid - 1; }
  return lo;
}
function vGoto(index) {
  if (!vhost || !vTops.length) return;
  vhost.scrollTop = vTops[clampPage(index)];
  vUpdate();
}
function vScrollBy(dir) {
  if (!vhost) return;
  vhost.scrollBy({ top: dir * (innerHeight || vhost.clientHeight) * 0.9, behavior: 'smooth' });
}
function vScrollToRatio(t) {
  if (!vhost) return;
  vhost.scrollTop = Math.max(0, Math.min(1, Number(t) || 0)) * Math.max(0, vhost.scrollHeight - vhost.clientHeight);
}
function vSchedule() {
  if (vRaf) return;
  vRaf = requestAnimationFrame(() => { vRaf = 0; vUpdate(); });
  if (!vMetricsTimer) vMetricsTimer = setTimeout(() => { vMetricsTimer = 0; vReportMetrics(); }, 30);
}
function vReportMetrics() {
  if (!vhost) return;
  emit('scrollMetrics', { top: vhost.scrollTop, height: vhost.scrollHeight, client: vhost.clientHeight });
}
function vMount(index) {
  if (vMounted.has(index) || !doc) return;
  const entry = svgForPage(index);
  const svg = entry.template.cloneNode(true);
  const box = svg.getAttribute('viewBox')?.trim().split(/[\s,]+/).map(Number);
  const frame = document.createElement('section');
  frame.className = 'page'; frame.dataset.page = String(index);
  frame.dataset.width = String(box?.[2] || parseFloat(svg.getAttribute('width')) || 1);
  frame.dataset.height = String(box?.[3] || parseFloat(svg.getAttribute('height')) || 1);
  frame.appendChild(svg);
  vSlots[index].appendChild(frame);
  activeEntries.add(entry);
  vMounted.set(index, { frame, entry });
}
function vUnmount(index) {
  const m = vMounted.get(index); if (!m) return;
  m.frame.remove(); vMounted.delete(index);
  if (![...vMounted.values()].some(o => o.entry === m.entry)) { activeEntries.delete(m.entry); releaseIfUnused(m.entry); }
}
function vUpdate() {
  if (!vhost || !vTops.length || disposed) return;
  const st = vhost.scrollTop, H = vhost.clientHeight || innerHeight;
  const first = vIndexAt(st), last = vIndexAt(st + H);
  // 지금 쪽: 화면 위에서 3분의 1 지점에 걸친 쪽
  const current = vIndexAt(st + H * 0.33);
  if (current !== page) { page = current; reportLocation(); }
  for (const index of [...vMounted.keys()]) if (index < first - 3 || index > last + 3) vUnmount(index);
  // 보이는 쪽부터, 한 번에 두 쪽까지만 새로 그림 (빨리 넘길 때도 끊기지 않게)
  const want = [];
  for (let i = Math.max(0, first - 1); i <= Math.min(count - 1, last + 1); i++) if (!vMounted.has(i)) want.push(i);
  want.sort((a, b) => (a >= first && a <= last ? 0 : 1) - (b >= first && b <= last ? 0 : 1));
  let made = 0;
  for (const i of want) {
    if (made >= 2) { vSchedule(); break; }
    try { vMount(i); made++; } catch (error) { console.warn(error); }
  }
  if (made) applySearchHighlights();
}
// ── 파일 내 단어 검색: 엔진이 알려 주는 쪽별 글자 위치로 노란 형광펜을 그린다 ──
let searchState = { query: '', results: [], current: -1 };
const layoutCache = new Map();
function searchNorm(text) { return text.replace(/\u00a0/g, ' ').toLowerCase(); }
function pageRuns(index) {
  if (layoutCache.has(index)) return layoutCache.get(index);
  let runs = [];
  try { runs = (JSON.parse(doc.getPageTextLayout(index)).runs || []).filter(r => r && typeof r.text === 'string' && r.text.length); } catch (_) {}
  layoutCache.set(index, runs);
  if (layoutCache.size > 60) layoutCache.delete(layoutCache.keys().next().value);
  return runs;
}
/** 한 쪽에서 찾은 곳들: 찾은 곳마다 쪽 좌표의 사각형 목록 */
function pageMatches(index, q) {
  const runs = pageRuns(index), owner = [];
  let text = '';
  runs.forEach((run, r) => { for (let c = 0; c < run.text.length; c++) owner.push([r, c]); text += run.text; });
  const hay = searchNorm(text), found = [];
  for (let at = hay.indexOf(q); at >= 0; at = hay.indexOf(q, at + q.length)) {
    const rects = [];
    for (let i = at; i < at + q.length && i < owner.length; i++) {
      const [r, c] = owner[i], run = runs[r], xs = run.charX || [];
      const x0 = run.x + (xs[c] ?? 0), x1 = run.x + (xs[c + 1] ?? xs[c] ?? run.w);
      const last = rects[rects.length - 1];
      if (last && last.run === r && Math.abs(last.x + last.w - x0) < 0.5) last.w = x1 - last.x;
      else rects.push({ run: r, x: x0, y: run.y, w: Math.max(0.5, x1 - x0), h: run.h });
    }
    found.push(rects);
  }
  return found;
}
async function search(query) {
  const q = searchNorm(String(query || '').trim());
  searchState = { query: q, results: [], current: -1 };
  if (!q || !doc) { applySearchHighlights(); return { count: 0, pages: [] }; }
  const results = [];
  for (let i = 0; i < count; i++) {
    const found = pageMatches(i, q);
    for (let k = 0; k < found.length; k++) results.push({ page: i, k });
    if (i % 15 === 14) await new Promise(resolve => setTimeout(resolve, 0)); // 긴 문서에서도 화면이 멈추지 않게
    if (searchState.query !== q) return { count: 0, pages: [] }; // 그 사이 다른 검색이 시작됨
  }
  searchState.results = results;
  applySearchHighlights();
  return { count: results.length, pages: results.map(r => r.page) };
}
async function showSearchResult(index) {
  const r = searchState.results[index]; if (!r) return;
  searchState.current = index;
  if (vertical) { page = r.page; vGoto(r.page); applySearchHighlights(); reportLocation(); return; }
  const shown = [...host.children].some(frame => Number(frame.dataset.page) === r.page);
  if (shown) { applySearchHighlights(); return; }
  await display(r.page);
}
function clearSearch() { searchState = { query: '', results: [], current: -1 }; applySearchHighlights(); }
function applySearchHighlights() {
  for (const old of document.querySelectorAll('.freader-search-mark')) old.remove();
  if (!searchState.query || !searchState.results.length || !doc) return;
  const current = searchState.results[searchState.current];
  for (const frame of pageFrames()) {
    const index = Number(frame.dataset.page), svg = frame.firstElementChild;
    if (!svg || !searchState.results.some(r => r.page === index)) continue;
    const found = pageMatches(index, searchState.query);
    found.forEach((rects, k) => {
      const isCurrent = current && current.page === index && current.k === k;
      for (const box of rects) {
        const rect = document.createElementNS('http://www.w3.org/2000/svg', 'rect');
        rect.setAttribute('class', 'freader-search-mark');
        for (const [key, value] of Object.entries({ x: box.x, y: box.y, width: box.w, height: box.h, fill: isCurrent ? '#ffb300' : '#ffeb3b', opacity: isCurrent ? 0.6 : 0.45, 'pointer-events': 'none' })) rect.setAttribute(key, String(value));
        rect.style.mixBlendMode = 'multiply';
        svg.appendChild(rect);
      }
    });
  }
}
/** 지금 화면에 보이는 글과 그 위치 (화면 크기 대비 0~1) — 내보낸 PDF에 보이지 않는 글자 층을 넣는 데 씀 */
function visibleTextBoxes() {
  const W = innerWidth || 1, H = innerHeight || 1, out = [];
  for (const frame of pageFrames()) {
    const index = Number(frame.dataset.page), svg = frame.firstElementChild;
    if (!svg || !Number.isFinite(index)) continue;
    const r = svg.getBoundingClientRect(), vw = Number(frame.dataset.width) || r.width;
    const s = vw > 0 ? r.width / vw : 1;
    for (const run of pageRuns(index)) {
      if (!run.text || !run.text.trim() || !(run.w > 0 && run.h > 0)) continue;
      out.push({ t: run.text, x: (r.left + run.x * s) / W, y: (r.top + run.y * s) / H, w: run.w * s / W, h: run.h * s / H });
    }
  }
  return out;
}
/** 쪽마다의 글 (문단마다 줄바꿈) — 앱이 '목차' 쪽을 찾는 데 씀 */
async function pageText(from, to) {
  if (!doc) return [];
  const out = [], current = doc, end = Math.min(count, Math.max(0, to | 0));
  for (let i = Math.max(0, from | 0); i < end; i++) {
    let text = '', key = null;
    for (const run of pageRuns(i)) {
      const k = run.paraIdx == null ? `c${run.y ?? ''}` : `${run.secIdx}:${run.paraIdx}`;
      if (key !== null && k !== key) text += '\n';
      text += run.text; key = k;
    }
    out.push(text);
    if (i % 20 === 19) await new Promise(resolve => setTimeout(resolve, 0));
    if (doc !== current) return [];
  }
  return out;
}
// ── 목차 후보: 번호로 시작하거나 굵은 글씨가 있는 짧은 문단 {title, page, bold, boldRatio, centered, fs}
// 앱이 '목차 쪽 → 번호 → 굵은 글씨(가운데 정렬 또는 전체 굵게)' 순서로 고른다. [from, to) 쪽만 (진행률 표시용) ──
const NUMBERED_START = /^\s*(?:[ⅠⅡⅢⅣⅤⅥⅦⅧⅨⅩⅪⅫ]|[IVX]{1,5}\s*[.)]|\(\s*\d|\d)/;
async function headingCandidates(from = 0, to = 1e9) {
  if (!doc) return [];
  const out = [], current = doc, end = Math.min(count, to);
  const sizeChars = new Map(); // 본문 글자 크기 = 이 쪽들에서 가장 많이 쓴 크기
  for (let i = Math.max(0, from); i < end; i++) {
    const runs = pageRuns(i);
    for (const run of runs) {
      const k = Math.round((run.fontSize || 0) * 10) / 10;
      if (k > 0) sizeChars.set(k, (sizeChars.get(k) || 0) + run.text.trim().length);
    }
    // 쪽의 글 영역 (가운데 정렬 가늠용)
    let L = Infinity, R = -Infinity;
    for (const run of runs) { L = Math.min(L, run.x); R = Math.max(R, run.x + (run.w || 0)); }
    const paras = new Map();
    for (const run of runs) {
      if (run.secIdx == null || run.paraIdx == null) continue; // 표 안 글자 등
      const key = `${run.secIdx}:${run.paraIdx}`;
      let b = paras.get(key);
      if (!b) { b = { text: '', bold: 0, chars: 0, fs: 0, x0: Infinity, x1: -Infinity }; paras.set(key, b); }
      b.text += run.text;
      const n = run.text.trim().length;
      b.chars += n; if (run.bold) b.bold += n;
      b.fs = Math.max(b.fs, run.fontSize || 0);
      if (n) { b.x0 = Math.min(b.x0, run.x); b.x1 = Math.max(b.x1, run.x + (run.w || 0)); }
    }
    const width = R - L;
    for (const b of paras.values()) {
      const text = b.text.replace(/\s+/g, ' ').trim();
      if (!text || !b.chars || text.length > 100) continue;
      const boldRatio = b.bold / b.chars;
      if (!NUMBERED_START.test(text) && boldRatio < 0.5) continue;
      const centered = width > 0 && b.x1 - b.x0 < width * 0.85 && Math.abs((b.x0 - L) - (R - b.x1)) < width * 0.06 + 2;
      out.push({ title: text, page: i, bold: boldRatio >= 0.9, boldRatio, centered, fs: b.fs });
    }
    if (i % 10 === 9) await new Promise(resolve => setTimeout(resolve, 0));
    if (doc !== current) return [];
  }
  let body = 0, most = -1;
  for (const [k, n] of sizeChars) if (n > most) { most = n; body = k; }
  return out.slice(0, 3000).map(c => ({ ...c, body }));
}
// FReader: 모든 쪽의 크기 [너비, 높이] (스크롤 보기에서 쪽 자리를 먼저 잡아 두고 그림은 차례로 채움)
function pageSizes() {
  const out = [];
  for (let i = 0; i < count; i++) {
    let w = 0, h = 0;
    try { const info = JSON.parse(doc.getPageInfo(i)); w = Number(info.width) || 0; h = Number(info.height) || 0; } catch (e) {}
    out.push([w, h]);
  }
  return out;
}
window.freaderHwp = { highlightBoxes, beginDocument, pageSizes, setVertical, scrollToRatio: vScrollToRatio, appendChunk, openDocument, configure, display, next, previous, progress, highlightSelection, destroy,
  search, showSearchResult, clearSearch, headingCandidates, pageText, visibleTextBoxes, pageRect,
  getState: () => ({ ready: readyReported, page, count, cachedPages: cache.size, cachedBytes, received, spread: options.spread, maxBytes: MAX_BYTES }) };
window.addEventListener('pagehide', destroy, { once: true });

(async () => {
  try {
    engine = await import('./rhwp.js');
    // ArrayBuffer init works even when Android's asset MIME database does not
    // recognize .wasm; it does not depend on instantiateStreaming MIME rules.
    const response = await fetch('./rhwp_bg.wasm');
    if (!response.ok) throw new Error('HWP 엔진 파일을 읽지 못했어요');
    await engine.default({ module_or_path: await response.arrayBuffer() });
    await Promise.all(['400 16px FReaderSans', '700 16px FReaderSans', '400 16px FReaderSerif', '700 16px FReaderSerif', '400 16px FReaderMath'].map(font => document.fonts.load(font)));
    await loadFontAliases(['함초롬돋움', '함초롬바탕', '함초롱돋움', '함초롱바탕', '한컴돋움', '한컴바탕', '맑은 고딕', '돋움', '굴림', '바탕', 'HY신명조', '한양신명조', 'HancomEQN']);
    installFontMeasurement();
    if (!disposed) { readyReported = true; emit('ready', { version: engine.version() }); }
  } catch (error) { fail(error); }
})();
