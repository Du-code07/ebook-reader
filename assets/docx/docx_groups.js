// FReader: Word의 '그룹'(그림 + 도형을 묶은 것)은 문서 엔진이 그리지 못해 사진이 빠지고 자리도 비지 않는다.
// 문서를 열기 전에 그룹 안의 사진을 보통 사진(같은 자리·같은 크기·같은 글 감싸기)으로 바꾸고,
// 그룹 안의 도형(테두리 상자 등)은 그 위에 따로 얹는다. 원본 파일은 바꾸지 않는다 (기기 안 메모리에서만).

const CRC_TABLE = (() => {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c >>> 0;
  }
  return t;
})();
function crc32(bytes) {
  let c = 0xFFFFFFFF;
  for (let i = 0; i < bytes.length; i++) c = CRC_TABLE[(c ^ bytes[i]) & 0xFF] ^ (c >>> 8);
  return (c ^ 0xFFFFFFFF) >>> 0;
}
async function inflateRaw(data) {
  const stream = new Blob([data]).stream().pipeThrough(new DecompressionStream('deflate-raw'));
  return new Uint8Array(await new Response(stream).arrayBuffer());
}

/** zip 목록 (중앙 목록 기준). zip64 등 다루지 않는 모양이면 null */
function readEntries(bytes) {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  let eocd = -1;
  for (let i = bytes.length - 22; i >= Math.max(0, bytes.length - 22 - 65535); i--) {
    if (view.getUint32(i, true) === 0x06054b50) { eocd = i; break; }
  }
  if (eocd < 0) return null;
  const total = view.getUint16(eocd + 10, true), cdSize = view.getUint32(eocd + 12, true), cdOffset = view.getUint32(eocd + 16, true);
  if (cdOffset === 0xFFFFFFFF || cdSize === 0xFFFFFFFF || total === 0xFFFF) return null;
  const entries = [];
  let p = cdOffset;
  for (let n = 0; n < total; n++) {
    if (view.getUint32(p, true) !== 0x02014b50) return null;
    const flags = view.getUint16(p + 8, true), method = view.getUint16(p + 10, true);
    const time = view.getUint16(p + 12, true), date = view.getUint16(p + 14, true);
    const crc = view.getUint32(p + 16, true), compSize = view.getUint32(p + 20, true), size = view.getUint32(p + 24, true);
    const nameLen = view.getUint16(p + 28, true), extraLen = view.getUint16(p + 30, true), commentLen = view.getUint16(p + 32, true);
    const localOffset = view.getUint32(p + 42, true);
    if (compSize === 0xFFFFFFFF || size === 0xFFFFFFFF || localOffset === 0xFFFFFFFF) return null;
    const nameBytes = bytes.subarray(p + 46, p + 46 + nameLen);
    const name = new TextDecoder().decode(nameBytes);
    if (view.getUint32(localOffset, true) !== 0x04034b50) return null;
    const dataStart = localOffset + 30 + view.getUint16(localOffset + 26, true) + view.getUint16(localOffset + 28, true);
    entries.push({ name, nameBytes: nameBytes.slice(), flags, method, time, date, crc, compSize, size, data: bytes.subarray(dataStart, dataStart + compSize) });
    p += 46 + nameLen + extraLen + commentLen;
  }
  return entries;
}
function writeZip(entries) {
  let total = 22;
  for (const e of entries) total += 30 + e.nameBytes.length + e.data.length + 46 + e.nameBytes.length;
  const out = new Uint8Array(total), view = new DataView(out.buffer);
  let p = 0;
  const offsets = [];
  for (const e of entries) {
    offsets.push(p);
    view.setUint32(p, 0x04034b50, true); view.setUint16(p + 4, 20, true); view.setUint16(p + 6, e.flags & 0x0800, true);
    view.setUint16(p + 8, e.method, true); view.setUint16(p + 10, e.time, true); view.setUint16(p + 12, e.date, true);
    view.setUint32(p + 14, e.crc, true); view.setUint32(p + 18, e.data.length, true); view.setUint32(p + 22, e.size, true);
    view.setUint16(p + 26, e.nameBytes.length, true); view.setUint16(p + 28, 0, true);
    out.set(e.nameBytes, p + 30); p += 30 + e.nameBytes.length;
    out.set(e.data, p); p += e.data.length;
  }
  const cdStart = p;
  entries.forEach((e, i) => {
    view.setUint32(p, 0x02014b50, true); view.setUint16(p + 4, 20, true); view.setUint16(p + 6, 20, true);
    view.setUint16(p + 8, e.flags & 0x0800, true); view.setUint16(p + 10, e.method, true);
    view.setUint16(p + 12, e.time, true); view.setUint16(p + 14, e.date, true);
    view.setUint32(p + 16, e.crc, true); view.setUint32(p + 20, e.data.length, true); view.setUint32(p + 24, e.size, true);
    view.setUint16(p + 28, e.nameBytes.length, true); view.setUint16(p + 30, 0, true); view.setUint16(p + 32, 0, true);
    view.setUint16(p + 34, 0, true); view.setUint16(p + 36, 0, true); view.setUint32(p + 38, 0, true);
    view.setUint32(p + 42, offsets[i], true);
    out.set(e.nameBytes, p + 46); p += 46 + e.nameBytes.length;
  });
  view.setUint32(p, 0x06054b50, true); view.setUint16(p + 4, 0, true); view.setUint16(p + 6, 0, true);
  view.setUint16(p + 8, entries.length, true); view.setUint16(p + 10, entries.length, true);
  view.setUint32(p + 12, p - cdStart, true); view.setUint32(p + 16, cdStart, true); view.setUint16(p + 20, 0, true);
  return out.subarray(0, p + 22);
}

function attr(tag, name) {
  const m = new RegExp(`\\s${name}="([^"]*)"`).exec(tag);
  return m ? Number(m[1]) : 0;
}
function xfrmOf(xml) {
  const off = /<a:off\b[^>]*>/.exec(xml)?.[0] || '', ext = /<a:ext\b[^>]*cx="[^>]*>/.exec(xml)?.[0] || '';
  const chOff = /<a:chOff\b[^>]*>/.exec(xml)?.[0] || '', chExt = /<a:chExt\b[^>]*>/.exec(xml)?.[0] || '';
  return {
    x: attr(off, 'x'), y: attr(off, 'y'), cx: attr(ext, 'cx'), cy: attr(ext, 'cy'),
    chx: attr(chOff, 'x'), chy: attr(chOff, 'y'), chcx: attr(chExt, 'cx'), chcy: attr(chExt, 'cy'),
  };
}
/** 그룹 바로 아래의 사진·도형 (안쪽 그룹은 건너뜀) */
function topChildren(inner) {
  const out = [];
  const re = /<(pic:pic|wps:wsp|wpg:grpSp)\b[\s\S]*?<\/\1>/g;
  for (let m = re.exec(inner); m; m = re.exec(inner)) out.push({ kind: m[1], xml: m[0] });
  return out;
}
function setPos(anchorHead, axis, delta) {
  const tag = axis === 'H' ? 'wp:positionH' : 'wp:positionV';
  const re = new RegExp(`(<${tag}\\b[^>]*>\\s*<wp:posOffset>)(-?\\d+)(</wp:posOffset>)`);
  return anchorHead.replace(re, (_, a, v, b) => `${a}${Math.round(Number(v) + delta)}${b}`);
}
function setExtent(head, cx, cy) {
  return head.replace(/<wp:extent\b[^>]*\/>/, `<wp:extent cx="${Math.round(cx)}" cy="${Math.round(cy)}"/>`);
}
function setChildXfrm(xml, cx, cy) {
  // 그림 자체의 위치·크기: 그룹 안 좌표 대신 (0,0)과 새 크기로
  return xml.replace(/<a:xfrm\b([^>]*)>[\s\S]*?<\/a:xfrm>/, (_, attrs) => `<a:xfrm${attrs}><a:off x="0" y="0"/><a:ext cx="${Math.round(cx)}" cy="${Math.round(cy)}"/></a:xfrm>`);
}
let docPrSerial = 900000000;
let shapeJobs = [];
/** 간단한 도형(네모·둥근 네모·타원, 단색 선·채우기)을 사진으로 그릴 준비. 못 그리는 도형이면 null */
function shapeJob(xml, cx, cy) {
  const spPr = /<wps:spPr\b[\s\S]*?<\/wps:spPr>/.exec(xml)?.[0] || '';
  const prst = /<a:prstGeom\b[^>]*prst="([^"]+)"/.exec(spPr)?.[1] || '';
  if (!['rect', 'roundRect', 'ellipse'].includes(prst)) return null;
  if (/<wps:txbx\b/.test(xml)) return null; // 글이 든 상자는 그리지 않음
  const ln = /<a:ln\b[^>]*>[\s\S]*?<\/a:ln>/.exec(spPr)?.[0] || '';
  const lineColor = /<a:solidFill>\s*<a:srgbClr val="([0-9A-Fa-f]{6})"/.exec(ln)?.[1] || null;
  const lineW = Number(/<a:ln\b[^>]*\sw="(\d+)"/.exec(ln)?.[1] || 12700);
  const body = spPr.replace(ln, '');
  const fillColor = /<a:noFill\s*\/>/.test(body) ? null : (/<a:solidFill>\s*<a:srgbClr val="([0-9A-Fa-f]{6})"/.exec(body)?.[1] || null);
  if (!lineColor && !fillColor) return null;
  const job = { id: `rIdFReaderShape${shapeJobs.length + 1}`, file: `media/freader_shape_${shapeJobs.length + 1}.png`, prst, cx, cy, lineColor, lineW, fillColor };
  shapeJobs.push(job);
  return job;
}
function pictureFor(job) {
  return `<pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:nvPicPr><pic:cNvPr id="${++docPrSerial}" name="shape"/><pic:cNvPicPr/></pic:nvPicPr>`
    + `<pic:blipFill><a:blip r:embed="${job.id}"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>`
    + `<pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="${Math.round(job.cx)}" cy="${Math.round(job.cy)}"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic>`;
}
async function renderShape(job) {
  if (typeof OffscreenCanvas !== 'function') return null;
  const PX = 96 / 914400 * 2; // EMU → 화면 점(두 배로 선명하게)
  const w = Math.max(2, Math.round(job.cx * PX)), h = Math.max(2, Math.round(job.cy * PX));
  if (w * h > 4096 * 4096) return null;
  const canvas = new OffscreenCanvas(w, h), ctx = canvas.getContext('2d');
  const lw = job.lineColor ? Math.max(1, job.lineW * PX) : 0;
  const x = lw / 2, y = lw / 2, rw = w - lw, rh = h - lw;
  ctx.beginPath();
  if (job.prst === 'ellipse') ctx.ellipse(w / 2, h / 2, rw / 2, rh / 2, 0, 0, Math.PI * 2);
  else if (job.prst === 'roundRect' && ctx.roundRect) ctx.roundRect(x, y, rw, rh, Math.min(rw, rh) * 0.1667);
  else ctx.rect(x, y, rw, rh);
  if (job.fillColor) { ctx.fillStyle = `#${job.fillColor}`; ctx.fill(); }
  if (job.lineColor) { ctx.strokeStyle = `#${job.lineColor}`; ctx.lineWidth = lw; ctx.stroke(); }
  const blob = await canvas.convertToBlob({ type: 'image/png' });
  return new Uint8Array(await blob.arrayBuffer());
}
function convertDrawing(drawing) {
  const g = /<a:graphicData\b[^>]*wordprocessingGroup[^>]*>([\s\S]*?)<\/a:graphicData>/.exec(drawing);
  if (!g) return drawing;
  const wgp = /<wpg:wgp\b[^>]*>([\s\S]*)<\/wpg:wgp>/.exec(g[1]);
  if (!wgp) return drawing;
  const grpXfrm = xfrmOf(/<wpg:grpSpPr\b[\s\S]*?<\/wpg:grpSpPr>/.exec(wgp[1])?.[0] || '');
  const sx = grpXfrm.chcx > 0 ? grpXfrm.cx / grpXfrm.chcx : 1, sy = grpXfrm.chcy > 0 ? grpXfrm.cy / grpXfrm.chcy : 1;
  const children = topChildren(wgp[1]).map(c => {
    const x = xfrmOf(/<(?:pic:spPr|wps:spPr)\b[\s\S]*?<\/(?:pic:spPr|wps:spPr)>/.exec(c.xml)?.[0] || '');
    return { ...c, dx: (x.x - grpXfrm.chx) * sx, dy: (x.y - grpXfrm.chy) * sy, cx: x.cx * sx, cy: x.cy * sy };
  });
  const pics = children.filter(c => c.kind === 'pic:pic' && c.cx > 0 && c.cy > 0);
  if (!pics.length) return drawing;
  pics.sort((a, b) => b.cx * b.cy - a.cx * a.cy);
  const main = pics[0];
  const isAnchor = /<wp:anchor\b/.test(drawing);
  const before = drawing.slice(0, g.index), after = drawing.slice(g.index + g[0].length);
  let head = setExtent(before, main.cx, main.cy);
  if (isAnchor) { head = setPos(head, 'H', main.dx); head = setPos(head, 'V', main.dy); }
  // 그룹 이름 대신 그림으로 (엔진이 그림 틀로 알아보게)
  head = head.replace(/<wp:cNvGraphicFramePr\s*\/>/, '<wp:cNvGraphicFramePr><a:graphicFrameLocks xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" noChangeAspect="1"/></wp:cNvGraphicFramePr>');
  const picXml = setChildXfrm(main.xml, main.cx, main.cy);
  let out = `${head}<a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">${picXml}</a:graphicData>${after}`;
  // 나머지(다른 사진·도형)는 글을 밀지 않고 그 자리에 얹음 (떠 있는 그림만 가능)
  if (isAnchor) {
    for (const extra of children) {
      if (extra === main || extra.cx <= 0 || extra.cy <= 0 || extra.kind === 'wpg:grpSp') continue;
      let h = setExtent(before, extra.cx, extra.cy);
      h = setPos(h, 'H', extra.dx); h = setPos(h, 'V', extra.dy);
      h = h.replace(/<wp:wrap(?:None|Square|Tight|Through|TopAndBottom)\b[\s\S]*?(?:\/>|<\/wp:wrap\w+>)/, '<wp:wrapNone/>');
      h = h.replace(/relativeHeight="(\d+)"/, (_, v) => `relativeHeight="${Number(v) + 1}"`);
      h = h.replace(/(<wp:docPr\b[^>]*\sid=")(\d+)"/, (_, a) => `${a}${++docPrSerial}"`);
      // 사진은 그대로, 도형은 사진으로 그려 얹음 (엔진이 그룹 안 도형을 못 그려 '그림을 표시할 수 없음'이 뜨던 것)
      let content;
      if (extra.kind === 'pic:pic') content = setChildXfrm(extra.xml, extra.cx, extra.cy);
      else {
        const job = shapeJob(extra.xml, extra.cx, extra.cy);
        if (!job) continue;
        content = pictureFor(job);
      }
      h = h.replace(/<wp:cNvGraphicFramePr\s*\/>/, '<wp:cNvGraphicFramePr><a:graphicFrameLocks xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" noChangeAspect="1"/></wp:cNvGraphicFramePr>');
      out += `${h}<a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">${content}</a:graphicData>${after}`;
    }
  }
  return out;
}

/** [tag] 덩어리(안에 같은 것이 겹쳐 있어도 짝을 맞춰)마다 [fn]으로 바꿈 */
function replaceBlocks(xml, tag, fn) {
  const open = `<${tag}`, close = `</${tag}>`;
  let out = '', i = 0;
  for (;;) {
    const start = xml.indexOf(open, i);
    if (start < 0) break;
    let depth = 0, j = start, end = -1;
    while (j < xml.length) {
      const o = xml.indexOf(open, j), c = xml.indexOf(close, j);
      if (c < 0) break;
      if (o >= 0 && o < c) { depth++; j = o + open.length; continue; }
      depth--; j = c + close.length;
      if (depth === 0) { end = j; break; }
    }
    if (end < 0) break;
    out += xml.slice(i, start) + fn(xml.slice(start, end));
    i = end;
  }
  return out + xml.slice(i);
}

/** 그룹이 있으면 그룹을 풀어 둔 새 docx 바이트, 없으면(또는 다룰 수 없으면) null */
export async function flattenDrawingGroups(bytes) {
  if (!(bytes?.length > 4) || bytes[0] !== 0x50 || bytes[1] !== 0x4B) return null;
  if (typeof DecompressionStream !== 'function') return null;
  const entries = readEntries(bytes);
  if (!entries) return null;
  const doc = entries.find(e => e.name === 'word/document.xml');
  if (!doc || (doc.method !== 0 && doc.method !== 8)) return null;
  const raw = doc.method === 8 ? await inflateRaw(doc.data) : doc.data;
  let xml = new TextDecoder().decode(raw);
  if (!xml.includes('wordprocessingGroup')) return null;
  let changed = false;
  shapeJobs = [];
  // 대체 내용(mc:AlternateContent)으로 싸인 그룹: 엔진은 그룹을 몰라 대체본(VML)을 그리는데, 거기서도 사진이 빠짐.
  // 그룹을 푼 본래 내용만 남김
  xml = replaceBlocks(xml, 'mc:AlternateContent', block => {
    const choice = /^<mc:AlternateContent\b[^>]*>\s*<mc:Choice\b[^>]*>([\s\S]*?)<\/mc:Choice>/.exec(block);
    if (!choice || !choice[1].includes('wordprocessingGroup') || choice[1].includes('<mc:AlternateContent')) return block;
    let converted = choice[1];
    try {
      converted = converted.replace(/<w:drawing>[\s\S]*?<\/w:drawing>/g, d => (d.includes('wordprocessingGroup') ? convertDrawing(d) : d));
    } catch (_) { return block; }
    if (converted.includes('wordprocessingGroup')) return block;
    changed = true;
    return converted;
  });
  xml = xml.replace(/<w:drawing>[\s\S]*?<\/w:drawing>/g, d => {
    if (!d.includes('wordprocessingGroup')) return d;
    try {
      const c = convertDrawing(d);
      if (c !== d) changed = true;
      return c;
    } catch (_) { return d; }
  });
  if (!changed) return null;
  const stored = (base, data) => ({ ...base, method: 0, flags: base.flags & 0x0800, crc: crc32(data), size: data.length, data });
  let list = entries.map(e => e);
  // 도형 그림: 그려서 문서에 넣고, 문서가 그 그림을 찾을 수 있게 연결
  const rels = list.find(e => e.name === 'word/_rels/document.xml.rels');
  const drawn = [];
  if (shapeJobs.length && rels && (rels.method === 0 || rels.method === 8)) {
    for (const job of shapeJobs) {
      try { const png = await renderShape(job); if (png) drawn.push({ job, png }); } catch (_) {}
    }
  }
  const okIds = new Set(drawn.map(d => d.job.id));
  // 그리지 못한 도형은 빼기 (빈 '그림 표시 못 함' 자리가 생기지 않게)
  for (const job of shapeJobs) {
    if (okIds.has(job.id)) continue;
    xml = xml.replace(new RegExp(`<w:drawing>(?:(?!<w:drawing>)[\\s\\S])*?r:embed="${job.id}"[\\s\\S]*?<\\/w:drawing>`), '');
  }
  if (drawn.length) {
    let relXml = new TextDecoder().decode(rels.method === 8 ? await inflateRaw(rels.data) : rels.data);
    const add = drawn.map(d => `<Relationship Id="${d.job.id}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="${d.job.file}"/>`).join('');
    relXml = relXml.replace('</Relationships>', `${add}</Relationships>`);
    list = list.map(e => (e === rels ? stored(rels, new TextEncoder().encode(relXml)) : e));
    const types = list.find(e => e.name === '[Content_Types].xml');
    if (types && (types.method === 0 || types.method === 8)) {
      let t = new TextDecoder().decode(types.method === 8 ? await inflateRaw(types.data) : types.data);
      if (!/Extension="png"/i.test(t)) {
        t = t.replace(/(<Types\b[^>]*>)/, '$1<Default Extension="png" ContentType="image/png"/>');
        list = list.map(e => (e === types ? stored(types, new TextEncoder().encode(t)) : e));
      }
    }
    for (const d of drawn) {
      list.push(stored({ name: `word/${d.job.file}`, nameBytes: new TextEncoder().encode(`word/${d.job.file}`), flags: 0, time: doc.time, date: doc.date }, d.png));
    }
  }
  const data = new TextEncoder().encode(xml);
  list = list.map(e => (e === doc ? stored(doc, data) : e));
  return writeZip(list);
}
