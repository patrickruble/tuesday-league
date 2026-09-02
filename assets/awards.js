/* ============================================================
   Season awards

   Read from the database rather than baked in at build time,
   because they move every week and the page shouldn't need
   rebuilding to stay right.
   ============================================================ */
import { supabase } from './db.js';

const slot = document.getElementById('awards');
if (slot) paint();

const esc = s => String(s ?? '').replace(/[&<>"]/g, c =>
  ({ '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;' }[c]));

const card = (label, value, who, accent, note, href) => `
  <div class="award" style="--c:${accent}">
    <div class="lab">${esc(label)}</div>
    <div class="val">${esc(value)}</div>
    <div class="who">${href ? `<a href="${href}">${esc(who)}</a>` : esc(who)}</div>
    ${note ? `<p>${esc(note)}</p>` : ''}
  </div>`;

async function paint() {
  const [imp, con, tal, con2] = await Promise.all([
    supabase.from('most_improved').select('*').limit(1),
    supabase.from('most_consistent').select('*').limit(1),
    supabase.from('season_tallies').select('*'),
    supabase.from('contest_tallies').select('*')
  ]);

  const out = [];

  if (imp.data?.length) {
    const t = imp.data[0];
    out.push(card('Most improved', (t.gain > 0 ? '+' : '') + t.gain, t.name, t.accent,
      `${t.early_avg} a round early on, ${t.late_avg} lately.`,
      'teams/' + t.slug + '.html'));
  }

  if (con.data?.length) {
    const t = con.data[0];
    out.push(card('Most consistent', t.spread + ' spread', t.name, t.accent,
      `Never below ${t.worst} or above ${t.best} across ${t.rounds} rounds.`,
      'teams/' + t.slug + '.html'));
  }

  if (tal.data?.length) {
    const top = (key) => [...tal.data].sort((a, b) => b[key] - a[key])[0];

    const eag = top('eagles');
    if (eag?.eagles) out.push(card('Most eagles', eag.eagles, eag.name, eag.accent,
      null, 'teams/' + eag.slug + '.html'));

    const bird = top('birdies');
    if (bird?.birdies) out.push(card('Most birdies', bird.birdies, bird.name, bird.accent,
      null, 'teams/' + bird.slug + '.html'));

    const blank = top('blanks');
    if (blank?.blanks) out.push(card('Most blanks', blank.blanks, blank.name, blank.accent,
      'Holes that scored nothing. Somebody has to.', 'teams/' + blank.slug + '.html'));
  }

  /* side contests, once anyone is recording them */
  const kinds = { ctp: 'Closest to the pin', long_putt: 'Long putts', chip_in: 'Chip-ins' };
  for (const [kind, label] of Object.entries(kinds)) {
    const best = (con2.data || []).filter(r => r.kind === kind)[0];
    if (best?.wins) {
      out.push(card(label, best.wins, best.full_name, best.accent || '#007041',
        best.team_name || null));
    }
  }

  if (!out.length) return;

  slot.innerHTML =
    `<h2 style="font-size:13px;letter-spacing:.14em;text-transform:uppercase;
       margin:34px 0 14px;font-family:var(--display);font-weight:800">Awards</h2>
     <div class="awards">${out.join('')}</div>`;
}
