// FReader: EMF 변환 보정 (emf-converter 결과 SVG 후처리). 원본 변환기는 수정하지 않는다.
// EMF→SVG 변환 결과 보정: 이전 칸의 잘라내기 영역과 겹치는 부분이 전혀 없는 '연결된 잘라내기'를 끊는다.
export function fixDisjointClipChains(svg) {
  const defs = new Map();
  const re = /<clipPath id="([^"]+)"( clip-path="url\(#([^)]+)\)")?([^>]*)>([\s\S]*?)<\/clipPath>/g;
  let m;
  while ((m = re.exec(svg))) defs.set(m[1], { parent: m[3] || null, body: m[5] });
  const boxCache = new Map();
  function pathBox(d) {
    const tokens = d.match(/[MLHVZmlhvz]|-?\d*\.?\d+(?:e-?\d+)?/g);
    if (!tokens) return null;
    let x = 0, y = 0, cmd = null, i = 0, minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity, sx = 0, sy = 0;
    const add = () => { minX = Math.min(minX, x); minY = Math.min(minY, y); maxX = Math.max(maxX, x); maxY = Math.max(maxY, y); };
    while (i < tokens.length) {
      const t = tokens[i];
      if (/[A-Za-z]/.test(t)) { cmd = t; i++; if (cmd === 'Z' || cmd === 'z') { x = sx; y = sy; } continue; }
      const n = () => parseFloat(tokens[i++]);
      switch (cmd) {
        case 'M': x = n(); y = n(); sx = x; sy = y; cmd = 'L'; break;
        case 'm': x += n(); y += n(); sx = x; sy = y; cmd = 'l'; break;
        case 'L': x = n(); y = n(); break;
        case 'l': x += n(); y += n(); break;
        case 'H': x = n(); break;
        case 'h': x += n(); break;
        case 'V': y = n(); break;
        case 'v': y += n(); break;
        default: return null; // 곡선 등은 판단하지 않음
      }
      add();
    }
    return minX <= maxX ? [minX, minY, maxX, maxY] : null;
  }
  function ownBox(body) {
    const r = body.match(/^<rect x="([-\d.e]+)" y="([-\d.e]+)" width="([-\d.e]+)" height="([-\d.e]+)"[^>]*\/>$/);
    if (r) { const [x, y, w, h] = r.slice(1).map(Number); return [x, y, x + w, y + h]; }
    const p = body.match(/^<path d="([^"]+)"[^>]*\/>$/);
    if (p) return pathBox(p[1]);
    return null;
  }
  function box(id, depth = 0) {
    if (boxCache.has(id)) return boxCache.get(id);
    const def = defs.get(id); if (!def || depth > 64) return null;
    let b = ownBox(def.body);
    if (b && def.parent) {
      const pb = box(def.parent, depth + 1);
      if (pb) b = [Math.max(b[0], pb[0]), Math.max(b[1], pb[1]), Math.min(b[2], pb[2]), Math.min(b[3], pb[3])];
      else b = null;
    }
    boxCache.set(id, b); return b;
  }
  const broken = new Set();
  for (const [id, def] of defs) {
    if (!def.parent) continue;
    const own = ownBox(def.body), parent = box(def.parent);
    if (!own || !parent) continue;
    const empty = Math.min(own[2], parent[2]) <= Math.max(own[0], parent[0]) || Math.min(own[3], parent[3]) <= Math.max(own[1], parent[1]);
    if (empty) broken.add(id);
  }
  if (!broken.size) return svg;
  return svg.replace(/<clipPath id="([^"]+)" clip-path="url\(#[^)]+\)"/g, (all, id) => broken.has(id) ? `<clipPath id="${id}"` : all);
}
