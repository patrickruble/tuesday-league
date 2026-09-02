/* ============================================================
   Hole diagrams

   A yardage-book sketch of a hole, drawn from its data rather
   than surveyed. Tee at the bottom, green at the top, the
   fairway bending by the hole's `bend` value.

     import { holeSVG } from './assets/holes.js';
     el.innerHTML = holeSVG(hole, { tee: 'blue', accent: '#C2410C' });
   ============================================================ */

const W = 120, H = 260;
const TEE_Y = H - 20, GRN_Y = 46;

/* Centreline as a quadratic curve. The control point is pushed
   sideways by `bend`, which is what makes a dogleg look like
   one. */
function centre(t, bend) {
  /* tee and green sit off-centre in opposite directions, which
     is what makes a dogleg look like a dogleg rather than a
     slightly bent straight hole */
  const p0 = { x: W / 2 - bend * 20, y: TEE_Y };
  const p1 = { x: W / 2 + bend * 74, y: (TEE_Y + GRN_Y) / 2 + 14 };
  const p2 = { x: W / 2 + bend * 30, y: GRN_Y };
  const u = 1 - t;
  return {
    x: u*u*p0.x + 2*u*t*p1.x + t*t*p2.x,
    y: u*u*p0.y + 2*u*t*p1.y + t*t*p2.y
  };
}

/* Half-width of the fairway at t. Narrow off the tee, widest in
   the landing area, pinched again at the green. */
function halfWidth(t, width) {
  const base = 13 + width * 16;
  /* a little narrower at both ends, but not so much that it
     turns into a skittle */
  const taper = 0.78 + 0.22 * Math.sin(Math.PI * t);
  return base * taper;
}

function ribbon(bend, width) {
  const N = 26;
  const left = [], right = [];

  for (let i = 0; i <= N; i++) {
    const t = i / N;
    const p = centre(t, bend);
    const q = centre(Math.min(1, t + 0.01), bend);
    const dx = q.x - p.x, dy = q.y - p.y;
    const len = Math.hypot(dx, dy) || 1;
    const nx = -dy / len, ny = dx / len;      // normal
    const w = halfWidth(t, width);
    left.push(`${(p.x + nx*w).toFixed(1)} ${(p.y + ny*w).toFixed(1)}`);
    right.push(`${(p.x - nx*w).toFixed(1)} ${(p.y - ny*w).toFixed(1)}`);
  }
  return `M ${left.join(' L ')} L ${right.reverse().join(' L ')} Z`;
}

function spinePath(bend) {
  const pts = [];
  for (let i = 0; i <= 20; i++) {
    const p = centre(i / 20, bend);
    pts.push(`${p.x.toFixed(1)} ${p.y.toFixed(1)}`);
  }
  return `M ${pts.join(' L ')}`;
}

const bunker = (cx, cy, rx = 7, ry = 4.5, rot = 0) =>
  `<ellipse cx="${cx.toFixed(1)}" cy="${cy.toFixed(1)}" rx="${rx}" ry="${ry}"
    transform="rotate(${rot} ${cx.toFixed(1)} ${cy.toFixed(1)})" class="bunker"/>`;

function hazards(list, bend, width) {
  const land = centre(0.55, bend);            // landing area
  const grn  = centre(1, bend);
  const wLand = halfWidth(0.55, width);
  let out = '';

  for (const h of list || []) {
    switch (h) {
      case 'bunker-left-fairway':
        out += bunker(land.x - wLand - 6, land.y, 8, 5, -20); break;
      case 'bunker-right-fairway':
        out += bunker(land.x + wLand + 6, land.y, 8, 5, 20); break;
      case 'bunker-green-left':
        out += bunker(grn.x - 21, GRN_Y + 3, 7, 4.5, -30); break;
      case 'bunker-green-right':
        out += bunker(grn.x + 21, GRN_Y + 3, 7, 4.5, 30); break;
      case 'bunker-green-front':
        out += bunker(grn.x, GRN_Y + 19, 9, 4.5, 0); break;

      case 'ocean-right':
        out += `<path d="M ${W-20} 0 C ${W-14} ${H*0.3}, ${W-24} ${H*0.65}, ${W-16} ${H}
                 L ${W} ${H} L ${W} 0 Z" class="water"/>`;
        break;
      case 'water-left':
        out += `<path d="M 0 ${H*0.28} C 14 ${H*0.34}, 16 ${H*0.6}, 4 ${H*0.76}
                 L 0 ${H*0.76} Z" class="water"/>`;
        break;

      case 'church-pews-left': {
        const x = Math.min(land.x - wLand - 30, W - 34);
        for (let i = 0; i < 5; i++) {
          out += `<rect x="${Math.max(3, x).toFixed(1)}" y="${(H*0.38 + i*12).toFixed(1)}"
                   width="24" height="5" rx="2" class="bunker"/>`;
        }
        break;
      }
    }
  }
  return out;
}

export function holeSVG(hole, opts = {}) {
  const tee    = opts.tee || 'blue';
  const accent = opts.accent || '#007041';
  const bend   = Math.max(-1, Math.min(1, hole.bend ?? 0));
  const width  = hole.width ?? 0.65;
  const yards  = hole.yards ? (hole.yards[tee] ?? hole.yards.blue) : null;

  const t0  = centre(0, bend);
  const grn = centre(1, bend);

  return `
<svg viewBox="0 0 ${W} ${H}" xmlns="http://www.w3.org/2000/svg" class="holeplan"
     role="img" aria-label="Hole ${hole.hole}, par ${hole.par}${yards ? ', ' + yards + ' yards' : ''}">
  <style>
    .rough  { fill: color-mix(in srgb, ${accent} 8%,  transparent); }
    .fw     { fill: color-mix(in srgb, ${accent} 24%, transparent); }
    .green  { fill: color-mix(in srgb, ${accent} 46%, transparent); }
    .bunker { fill: color-mix(in srgb, ${accent} 26%, #ffffff); }
    .water  { fill: color-mix(in srgb, #0E7490 32%, transparent); }
    .tee    { fill: ${accent}; }
    .pin    { stroke: ${accent}; stroke-width: 1.5; }
    .flag   { fill: ${accent}; }
    .line   { stroke: ${accent}; stroke-width: 1; stroke-dasharray: 3 4;
              opacity: .4; fill: none; }
  </style>

  <rect width="${W}" height="${H}" class="rough"/>
  <path d="${ribbon(bend, width)}" class="fw"/>
  ${hazards(hole.hazards, bend, width)}

  <ellipse cx="${grn.x.toFixed(1)}" cy="${GRN_Y}" rx="17" ry="13" class="green"/>
  <path d="${spinePath(bend)}" class="line"/>

  <rect x="${(t0.x - 7).toFixed(1)}" y="${TEE_Y - 3}" width="14" height="6" rx="1.5" class="tee"/>

  <line x1="${grn.x.toFixed(1)}" y1="${GRN_Y}" x2="${grn.x.toFixed(1)}" y2="${GRN_Y - 15}" class="pin"/>
  <path d="M ${grn.x.toFixed(1)} ${GRN_Y - 15} L ${(grn.x + 9).toFixed(1)} ${GRN_Y - 11.5}
           L ${grn.x.toFixed(1)} ${GRN_Y - 8} Z" class="flag"/>
</svg>`;
}

/* Same drawing, hazards stripped back, for tight rows. */
export const holeThumb = (hole, opts = {}) =>
  holeSVG({ ...hole, hazards: (hole.hazards || [])
    .filter(h => h.startsWith('ocean') || h.startsWith('water')) }, opts);

export const yardsFor = (hole, tee) =>
  hole.yards ? (hole.yards[tee] ?? hole.yards.blue ?? null) : null;
