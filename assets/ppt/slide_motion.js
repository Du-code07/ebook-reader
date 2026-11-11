// FReader: PowerPoint 애니메이션·슬라이드 전환을 그림으로 흉내 냄.
// 슬라이드는 한 장의 그림(canvas)으로 그려지므로, 바뀌기 전/후 그림을 비교해 움직이는 도형만 떼어 내
// 날아오기·나타나기·확대·닦아내기·회전·튕기기·강조·이동 경로·사라지기와 전환 효과(밀어내기·덮기 등)를 그린다.

const ease = {
  out: t => 1 - Math.pow(1 - t, 3),
  in: t => t * t * t,
  inOut: t => (t < .5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2),
  bounce: t => {
    const n = 7.5625, d = 2.75;
    if (t < 1 / d) return n * t * t;
    if (t < 2 / d) return n * (t -= 1.5 / d) * t + .75;
    if (t < 2.5 / d) return n * (t -= 2.25 / d) * t + .9375;
    return n * (t -= 2.625 / d) * t + .984375;
  },
};

let current = null; // 지금 움직이는 중인 것 { cancel() }

/** 진행 중인 움직임을 끝냄 (다른 쪽으로 넘기는 등) */
export function stopMotion() {
  if (current) { current.cancel(); current = null; }
}

function copyCanvas(src) {
  const c = document.createElement('canvas');
  c.width = src.width; c.height = src.height;
  c.getContext('2d').drawImage(src, 0, 0);
  return c;
}

/** 두 그림에서 다른 점(= 그 도형)만 떼어 냄 → { img, x, y, w, h } */
function diffPiece(src, ref) {
  const W = src.width, H = src.height;
  if (!W || !H || ref.width !== W || ref.height !== H) return null;
  const a = src.getContext('2d', { willReadFrequently: true }).getImageData(0, 0, W, H).data;
  const b = ref.getContext('2d', { willReadFrequently: true }).getImageData(0, 0, W, H).data;
  let x0 = W, y0 = H, x1 = -1, y1 = -1;
  const mask = new Uint8Array(W * H);
  for (let i = 0, p = 0; p < W * H; p++, i += 4) {
    if (Math.abs(a[i] - b[i]) > 6 || Math.abs(a[i + 1] - b[i + 1]) > 6 || Math.abs(a[i + 2] - b[i + 2]) > 6 || Math.abs(a[i + 3] - b[i + 3]) > 6) {
      mask[p] = 1;
      const x = p % W, y = (p / W) | 0;
      if (x < x0) x0 = x; if (x > x1) x1 = x; if (y < y0) y0 = y; if (y > y1) y1 = y;
    }
  }
  if (x1 < 0) return null;
  const w = x1 - x0 + 1, h = y1 - y0 + 1;
  const img = document.createElement('canvas'); img.width = w; img.height = h;
  const ctx = img.getContext('2d');
  const out = ctx.createImageData(w, h);
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const p = (y0 + y) * W + (x0 + x);
      if (!mask[p]) continue;
      const si = p * 4, di = (y * w + x) * 4;
      out.data[di] = a[si]; out.data[di + 1] = a[si + 1]; out.data[di + 2] = a[si + 2]; out.data[di + 3] = a[si + 3];
    }
  }
  ctx.putImageData(out, 0, 0);
  return { img, x: x0, y: y0, w, h };
}

/** 이동 경로 "M 0 0 L 0.25 0 C ... E" → 점들 (슬라이드 크기 대비) */
function pathPoints(path) {
  const nums = String(path).replace(/[A-Za-z]/g, ' ').trim().split(/[\s,]+/).map(Number).filter(Number.isFinite);
  const pts = [];
  for (let i = 0; i + 1 < nums.length; i += 2) pts.push([nums[i], nums[i + 1]]);
  return pts.length ? pts : [[0, 0]];
}
function alongPath(pts, t) {
  if (pts.length === 1) return pts[0];
  t = Math.max(0, Math.min(1, t));
  const seg = Math.min(pts.length - 2, Math.floor(t * (pts.length - 1)));
  const local = t * (pts.length - 1) - seg;
  const [ax, ay] = pts[seg], [bx, by] = pts[seg + 1];
  return [ax + (bx - ax) * local, ay + (by - ay) * local];
}

const ZOOMS = new Set([23, 31, 53, 55, 51, 50, 17, 19, 40]);
const SPINS = new Set([49, 15, 35, 43, 45]);
const FLOATS = new Set([30, 37, 42, 47, 29]);
const REVEALS = new Set([4, 6, 8, 13, 16, 20, 21]);

/** 한 도형 조각을 t(0~1)에 맞게 그림 */
function drawPiece(ctx, piece, e, t, W, H) {
  const { img, x, y, w, h } = piece;
  const cx = x + w / 2, cy = y + h / 2;
  const cls = e.cls, preset = e.preset, sub = e.sub || 0;
  ctx.save();
  if (cls === 'entr' || cls === 'exit') {
    // 사라지기는 나타나기를 거꾸로
    const raw = cls === 'entr' ? t : 1 - t;
    const p = preset === 26 && cls === 'entr' ? ease.bounce(t) : (cls === 'entr' ? ease.out(t) : 1 - ease.in(t));
    if (preset === 2 || preset === 26 || preset === 12 || preset === 7) {
      // 날아오기/튕기기: 들어오는(나가는) 쪽 (1 위, 2 오른쪽, 4 아래, 8 왼쪽)
      const s = preset === 26 ? 1 : (sub || 4);
      let dx = 0, dy = 0;
      if (s & 8) dx = -(x + w); if (s & 2) dx = W - x; if (s & 1) dy = -(y + h); if (s & 4) dy = H - y;
      ctx.translate(dx * (1 - p), dy * (1 - p));
    } else if (preset === 22 || preset === 18 || preset === 3 || preset === 14) {
      // 닦아내기: 한쪽부터 드러남
      const s = sub || 4;
      const k = Math.max(0, Math.min(1, p));
      ctx.beginPath();
      if (s & 8) ctx.rect(x, y, w * k, h);
      else if (s & 2) ctx.rect(x + w * (1 - k), y, w * k, h);
      else if (s & 1) ctx.rect(x, y, w, h * k);
      else ctx.rect(x, y + h * (1 - k), w, h * k);
      ctx.clip();
    } else if (REVEALS.has(preset)) {
      ctx.beginPath();
      ctx.arc(cx, cy, Math.hypot(w, h) / 2 * Math.max(0, p), 0, Math.PI * 2);
      ctx.clip();
    } else if (ZOOMS.has(preset)) {
      const s = .05 + .95 * Math.max(0, p);
      ctx.translate(cx, cy); ctx.scale(s, s); ctx.translate(-cx, -cy);
      ctx.globalAlpha = Math.max(0, Math.min(1, raw * 1.5));
    } else if (SPINS.has(preset)) {
      const s = .2 + .8 * Math.max(0, p);
      ctx.translate(cx, cy); ctx.rotate((1 - p) * Math.PI * 2); ctx.scale(s, s); ctx.translate(-cx, -cy);
      ctx.globalAlpha = Math.max(0, Math.min(1, p));
    } else if (FLOATS.has(preset)) {
      const dir = preset === 47 ? -1 : 1;
      ctx.translate(0, dir * H * .08 * (1 - p));
      ctx.globalAlpha = Math.max(0, Math.min(1, p));
    } else {
      // 나타나기·서서히·그 밖의 효과: 투명도로
      ctx.globalAlpha = Math.max(0, Math.min(1, p));
    }
  } else if (cls === 'emph') {
    const p = ease.inOut(t);
    if (e.rotate || preset === 8) {
      const deg = e.rotate || 360;
      const a = e.autoRev ? Math.sin(t * Math.PI * 4) * deg * (1 - t) : deg * p;
      ctx.translate(cx, cy); ctx.rotate(a * Math.PI / 180); ctx.translate(-cx, -cy);
    } else if (preset === 6 || (e.scale && !e.autoRev)) {
      const s = 1 + ((e.scale || 1.5) - 1) * p;
      ctx.translate(cx, cy); ctx.scale(s, s); ctx.translate(-cx, -cy);
    } else if (preset === 9) {
      ctx.globalAlpha = 1 - .5 * p;
    } else {
      // 펄스: 살짝 커졌다 돌아옴
      const s = 1 + ((e.scale || 1.1) - 1) * Math.sin(t * Math.PI);
      ctx.translate(cx, cy); ctx.scale(s, s); ctx.translate(-cx, -cy);
    }
  } else if (cls === 'path') {
    const [px, py] = alongPath(pathPoints(e.path), ease.inOut(t));
    ctx.translate(px * W, py * H);
  }
  ctx.drawImage(img, x, y);
  ctx.restore();
}

function overlayFor(frame, canvas) {
  const o = document.createElement('canvas');
  o.width = canvas.width; o.height = canvas.height;
  o.style.cssText = `position:absolute;left:0;top:0;width:${canvas.style.width};height:${canvas.style.height};pointer-events:none;`;
  o.className = 'motion';
  frame.appendChild(o);
  return o;
}

function run(duration, drawFrame, done) {
  let raf = 0, cancelled = false;
  const start = performance.now();
  const tick = now => {
    if (cancelled) return;
    // 첫 장면의 시각이 시작보다 앞설 수 있어 0~1로 묶음
    const t = duration <= 0 ? 1 : Math.max(0, Math.min(1, (now - start) / duration));
    drawFrame(t);
    if (t < 1) raf = requestAnimationFrame(tick);
    else done(false);
  };
  raf = requestAnimationFrame(tick);
  return { cancel() { cancelled = true; cancelAnimationFrame(raf); done(true); } };
}

/**
 * 한 단계(클릭) 움직임.
 * effects: 이 단계의 효과들, oldCanvas: 바뀌기 전 그림, newCanvas: 바뀐 뒤 그림(이미 화면에 있음),
 * render(hiddenIds) → 그 도형들을 뺀 그림, prevHidden/newHidden: 앞·지금 단계에서 숨은 도형
 */
export async function playStep({ frame, oldCanvas, newCanvas, effects, render, prevHidden, newHidden }) {
  stopMotion();
  const overlay = overlayFor(frame, newCanvas);
  const octx = overlay.getContext('2d');
  octx.drawImage(oldCanvas, 0, 0); // 준비하는 동안 바뀌기 전 모습 그대로
  let alive = true;
  current = { cancel() { alive = false; overlay.remove(); } };
  const token = current;
  try {
    const moving = effects.filter(e => e.visible !== false);
    const baseHidden = new Set(newHidden);
    for (const e of moving) for (const id of e.ids) baseHidden.add(id);
    const base = moving.length ? await render(baseHidden) : newCanvas;
    const pieces = [];
    for (const e of effects) {
      if (!alive) return;
      let piece = null;
      if (e.visible === false) {
        const ref = await render(new Set([...prevHidden, ...e.ids]));
        piece = diffPiece(oldCanvas, ref);
      } else {
        const ref = await render(new Set([...newHidden, ...e.ids]));
        piece = diffPiece(newCanvas, ref);
      }
      if (piece) pieces.push({ e, piece });
    }
    if (!alive || current !== token) return;
    const W = newCanvas.width, H = newCanvas.height;
    const duration = Math.max(0, ...pieces.map(p => p.e.dur || 0));
    // 강조·이동 경로는 PowerPoint처럼 끝난 모습을 다음 단계까지 그대로
    const hold = pieces.some(p => p.e.cls === 'path' || (p.e.cls === 'emph' && (p.e.preset === 6 || p.e.preset === 9 || (p.e.scale && !p.e.autoRev))));
    current = run(duration, t => {
      octx.clearRect(0, 0, W, H);
      octx.drawImage(base, 0, 0);
      for (const { e, piece } of pieces) drawPiece(octx, piece, e, Math.min(1, duration ? t * duration / Math.max(1, e.dur) : 1), W, H);
    }, cancelled => {
      if (!hold || cancelled) overlay.remove();
      if (base !== newCanvas) { base.width = 0; base.height = 0; }
      for (const { piece } of pieces) { piece.img.width = 0; piece.img.height = 0; }
      if (current && !cancelled) current = hold ? { cancel() { overlay.remove(); } } : null;
    });
  } catch (_) {
    overlay.remove();
    if (current === token) current = null;
  }
}

/** 슬라이드 전환: 앞 슬라이드 그림 → 새 슬라이드 */
export function playTransition({ frame, oldCanvas, newCanvas, transition }) {
  stopMotion();
  if (!transition) return;
  const overlay = overlayFor(frame, newCanvas);
  const ctx = overlay.getContext('2d');
  const W = newCanvas.width, H = newCanvas.height;
  const old = copyCanvas(oldCanvas);
  ctx.drawImage(old, 0, 0); // 첫 장면 전까지 새 슬라이드가 번쩍 보이지 않게
  const type = transition.type, dir = transition.dir || '';
  // 방향: l 왼쪽, r 오른쪽, u 위, d 아래 (새 슬라이드가 들어오는 쪽 기준)
  const vec = { l: [-1, 0], r: [1, 0], u: [0, -1], d: [0, 1], lu: [-1, -1], ru: [1, -1], ld: [-1, 1], rd: [1, 1] }[dir] || [-1, 0];
  current = run(transition.dur || 700, t => {
    const p = ease.inOut(t);
    ctx.clearRect(0, 0, W, H);
    switch (type) {
      case 'push': {
        // 새 슬라이드가 [dir] 방향으로 밀고 들어옴: 들어오는 쪽은 dir 반대편에서
        const [vx, vy] = dir ? vec : [0, -1];
        ctx.drawImage(old, vx * W * p, vy * H * p);
        ctx.drawImage(newCanvas, vx * W * (p - 1), vy * H * (p - 1));
        break;
      }
      case 'cover': case 'pull': {
        const [vx, vy] = vec;
        if (type === 'cover') { ctx.drawImage(old, 0, 0); ctx.drawImage(newCanvas, -vx * W * (1 - p), -vy * H * (1 - p)); }
        else { ctx.drawImage(newCanvas, 0, 0); ctx.drawImage(old, vx * W * p, vy * H * p); }
        break;
      }
      case 'wipe': case 'randomBar': case 'blinds': case 'strips': case 'checker': {
        ctx.drawImage(old, 0, 0);
        ctx.save(); ctx.beginPath();
        if (dir === 'l') ctx.rect(W * (1 - p), 0, W * p, H);
        else if (dir === 'u') ctx.rect(0, H * (1 - p), W, H * p);
        else if (dir === 'd') ctx.rect(0, 0, W, H * p);
        else ctx.rect(0, 0, W * p, H);
        ctx.clip(); ctx.drawImage(newCanvas, 0, 0); ctx.restore();
        break;
      }
      case 'split': {
        ctx.drawImage(old, 0, 0);
        ctx.save(); ctx.beginPath();
        if (transition.orient === 'horz') ctx.rect(0, H / 2 * (1 - p), W, H * p);
        else ctx.rect(W / 2 * (1 - p), 0, W * p, H);
        ctx.clip(); ctx.drawImage(newCanvas, 0, 0); ctx.restore();
        break;
      }
      case 'circle': case 'diamond': case 'plus': case 'wheel': case 'wedge': case 'zoom': case 'newsflash': {
        ctx.drawImage(old, 0, 0);
        if (type === 'zoom' || type === 'newsflash') {
          const s = .3 + .7 * p;
          ctx.save(); ctx.globalAlpha = p;
          ctx.translate(W / 2, H / 2); ctx.scale(s, s);
          if (type === 'newsflash') ctx.rotate((1 - p) * Math.PI * 4);
          ctx.translate(-W / 2, -H / 2);
          ctx.drawImage(newCanvas, 0, 0); ctx.restore();
        } else {
          ctx.save(); ctx.beginPath(); ctx.arc(W / 2, H / 2, Math.hypot(W, H) / 2 * p, 0, Math.PI * 2); ctx.clip();
          ctx.drawImage(newCanvas, 0, 0); ctx.restore();
        }
        break;
      }
      default: {
        // 서서히(fade)·녹아내리기 등 그 밖의 전환은 겹쳐 바뀜
        ctx.drawImage(old, 0, 0);
        ctx.globalAlpha = p; ctx.drawImage(newCanvas, 0, 0); ctx.globalAlpha = 1;
      }
    }
  }, () => { overlay.remove(); old.width = 0; old.height = 0; current = null; });
}
