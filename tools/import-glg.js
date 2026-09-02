#!/usr/bin/env node
/* ============================================================
   Golf League Guru → site data

     node tools/import-glg.js

   Put the CSV exports in  import/  and run this. It writes
   data/teams.json, then you run node build.js.

   Files are matched loosely on filename keywords:
     *teams*           rosters
     *score-history*   weekly scores
     *handicap*        player indexes
     *schedule*        matchups

   Anything Golf League Guru doesn't know about — colours,
   fonts, backdrops, moods, songs, bios, quotes — is kept from
   the existing data file. Re-running never wipes what people
   chose for themselves.
   ============================================================ */

const fs   = require('fs');
const path = require('path');

const ROOT   = path.join(__dirname, '..');
const IMPORT = path.join(ROOT, 'import');
const DATA   = path.join(ROOT, 'data');

const PALETTE = ['#C2410C','#2B3A67','#4D7C0F','#7A1F3D','#0E7490','#A16207',
  '#6D28D9','#B91C1C','#0F766E','#DB2777','#3F3F46','#7C2D12','#4338CA',
  '#86198F','#57534E','#1E3A8A','#B45309'];
const FACES = ['archivo','anton','dm-serif','space-mono','bungee'];
const BACKS = ['argyle','plaid','pinstripe','dots','grid','diagonal','check','turf'];

/* ---------- text ---------- */

/* The exports come out HTML-encoded — apostrophes and
   ampersands arrive as entities. */
function decode(s) {
  return String(s ?? '')
    .replace(/&#0?39;|&apos;|&rsquo;/g, "'")
    .replace(/&quot;/g, '"')
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&nbsp;/g, ' ')
    .replace(/&#(\d+);/g, (_, n) => String.fromCharCode(n))
    .trim();
}

const slugify = s => decode(s).toLowerCase().normalize('NFD')
  .replace(/[\u0300-\u036f]/g,'')
  .replace(/&/g,' and ')
  .replace(/['’]/g,'')
  .replace(/[^a-z0-9]+/g,'-').replace(/^-|-$/g,'');

/* Two characters that identify the team. Filler words are
   skipped; a leading number is kept, because "2 J's and a
   Hard R" really is 2J. */
function crestFor(name) {
  const skip = new Set(['the','a','an','and','of','my','&']);
  const words = decode(name).split(/[\s'’]+/).filter(w => w && !skip.has(w.toLowerCase()));
  if (!words.length) return decode(name).slice(0,2).toUpperCase();
  if (words.length === 1) return words[0].slice(0,2).toUpperCase();
  return (words[0][0] + words[1][0]).toUpperCase();
}

/* ---------- csv ---------- */
function readCSV(file) {
  const text = fs.readFileSync(file, 'utf8').replace(/^\uFEFF/, '');
  const rows = [];
  let row = [], cell = '', quoted = false;

  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (quoted) {
      if (c === '"' && text[i+1] === '"') { cell += '"'; i++; }
      else if (c === '"') quoted = false;
      else cell += c;
    } else if (c === '"') quoted = true;
    else if (c === ',') { row.push(cell.trim()); cell = ''; }
    else if (c === '\n') { row.push(cell.trim()); rows.push(row); row = []; cell = ''; }
    else if (c !== '\r') cell += c;
  }
  if (cell || row.length) { row.push(cell.trim()); rows.push(row); }

  /* the exports start with a blank line */
  return rows.filter(r => r.some(c => c !== ''));
}

function find(...keywords) {
  if (!fs.existsSync(IMPORT)) return null;
  const files = fs.readdirSync(IMPORT).filter(f => /\.csv$/i.test(f));
  for (const k of keywords) {
    const hit = files.find(f => f.toLowerCase().includes(k));
    if (hit) return path.join(IMPORT, hit);
  }
  return null;
}

const load = p => { try { return JSON.parse(fs.readFileSync(p,'utf8')); } catch { return null; } };

/* ============================================================
   ROSTERS
   The Teams report comes out as:  #, Team, then one column per
   player. The header claims the third column is "Points",
   which it isn't — so we go by position, not by header name.
   ============================================================ */
function readRosters() {
  const f = find('teams','roster');
  if (!f) return {};

  const rows = readCSV(f);
  const head = rows[0].map(h => h.toLowerCase());
  const iTeam = head.findIndex(h => h.includes('team'));
  if (iTeam < 0) { console.log('  teams: no team column found, skipping'); return {}; }

  /* is there a column that genuinely holds a player name? */
  const iPlayer = head.findIndex(h =>
    h.includes('player') || h.includes('golfer') || h.includes('competitor'));
  const iHcp = head.findIndex(h =>
    h.includes('handicap') || h.includes('index') || h === 'hcp');

  const out = {};

  if (iPlayer >= 0) {
    /* one row per player */
    for (const r of rows.slice(1)) {
      const team = decode(r[iTeam]), player = decode(r[iPlayer]);
      if (!team || !player) continue;
      (out[team] ??= []).push({
        name: player,
        hcp: iHcp >= 0 && r[iHcp] !== '' ? Number(r[iHcp]) : null
      });
    }
  } else {
    /* one row per team, players spread across the columns after it */
    for (const r of rows.slice(1)) {
      const team = decode(r[iTeam]);
      if (!team) continue;
      const players = r.slice(iTeam + 1)
        .map(decode)
        .filter(v => v && isNaN(Number(v)));       // skip stray numbers
      if (!players.length) continue;
      out[team] = players.map(name => ({ name, hcp: null }));
    }
  }

  const n = Object.values(out).reduce((a,r) => a + r.length, 0);
  console.log(`  rosters: ${Object.keys(out).length} teams, ${n} players`);
  return out;
}

/* ============================================================
   HANDICAPS — merged onto players by name
   ============================================================ */
function readHandicaps() {
  const f = find('handicap');
  if (!f) return {};

  const rows = readCSV(f);
  const head = rows[0].map(h => h.toLowerCase());
  const iName = head.findIndex(h =>
    h.includes('player') || h.includes('name') || h.includes('competitor') || h.includes('golfer'));
  const iHcp = head.findIndex(h =>
    h.includes('handicap') || h.includes('index') || h === 'hcp');

  if (iName < 0 || iHcp < 0) { console.log('  handicaps: columns unclear, skipping'); return {}; }

  const out = {};
  for (const r of rows.slice(1)) {
    const n = decode(r[iName]);
    const v = Number(r[iHcp]);
    if (n && !isNaN(v)) out[n.toLowerCase()] = v;
  }
  console.log(`  handicaps: ${Object.keys(out).length} players`);
  return out;
}

/* ============================================================
   LAST SEASON'S SCORES
   Kept as history, not as this season's standings. The format
   is changing, so last year's numbers mean something different.
   ============================================================ */
function readHistory() {
  const f = find('score-history','round-scores');
  if (!f) return null;

  const rows  = readCSV(f);
  const dates = rows[0].slice(1);
  const teams = {};
  for (const r of rows.slice(1)) {
    teams[decode(r[0])] = r.slice(1).map(v => v === '' ? null : Number(v));
  }
  console.log(`  history: ${Object.keys(teams).length} teams over ${dates.length} weeks`);
  return { dates, teams };
}

/* ============================================================
   BUILD
   ============================================================ */
console.log('Importing from', IMPORT);

if (!fs.existsSync(IMPORT)) {
  fs.mkdirSync(IMPORT, { recursive: true });
  console.log('\nMade an import/ folder. Put the CSVs in it and run again.');
  process.exit(0);
}

const rosters = readRosters();
const hcps    = readHandicaps();
const history = readHistory();

if (!Object.keys(rosters).length) {
  console.log('\nNo rosters found. Export the Teams report into import/ and try again.');
  process.exit(1);
}

const existing = load(path.join(DATA,'teams.json')) || [];
const prior = Object.fromEntries(existing.map(t => [t.slug, t]));

const names = Object.keys(rosters);

const teams = names.map((name, i) => {
  const slug = slugify(name);
  const old  = prior[slug] || {};
  const oldRoster = old.roster || [];

  const past = history ? (history.teams[name] || []).filter(v => v != null) : [];

  return {
    slug,
    name,
    crest:    old.crest    || crestFor(name),
    accent:   old.accent   || PALETTE[i % PALETTE.length],
    typeface: old.typeface || FACES[i % FACES.length],
    backdrop: old.backdrop || BACKS[i % BACKS.length],
    handicap: old.handicap ?? 0,
    bay:      old.bay      ?? ((i % 7) + 1),

    mood:          old.mood          || 'content',
    moodSentiment: old.moodSentiment || 'good',
    song: old.song || { title:'', artist:'', provider:'youtube', id:null },
    bio:  old.bio  || '',

    roster: rosters[name].map(p => {
      const kept = oldRoster.find(o => o.name === p.name) || {};
      return {
        name:  p.name,
        hcp:   p.hcp ?? hcps[p.name.toLowerCase()] ?? kept.hcp ?? 0,
        quote: kept.quote || ''
      };
    }),

    /* this season starts at zero — nothing has been played */
    points: 0, played: 0, won: 0, lost: 0,
    form: [], bestRound: null,

    /* last season, kept for reference only */
    lastSeason: past.length ? {
      played:  past.length,
      total:   past.reduce((a,b) => a+b, 0),
      average: +(past.reduce((a,b)=>a+b,0) / past.length).toFixed(1),
      best:    Math.min(...past),
      worst:   Math.max(...past)
    } : null
  };
});

fs.mkdirSync(DATA, { recursive: true });
fs.writeFileSync(path.join(DATA,'teams.json'), JSON.stringify(teams, null, 2) + '\n');

console.log(`\n  wrote data/teams.json — ${teams.length} teams, ` +
  `${teams.reduce((a,t)=>a+t.roster.length,0)} players`);

console.log('\nNotes:');
if (teams.length % 2) {
  console.log(`  · ${teams.length} teams is odd, so one sits out each week.`);
}
if (!Object.keys(hcps).length) {
  console.log('  · no handicaps found — every player is on 0. Export the Handicaps report.');
}
if (history) {
  console.log('  · last season\u2019s scores are under "lastSeason" on each team, not in the standings.');
}
console.log('  · colours, fonts and backdrops were assigned automatically. Teams can change');
console.log('    them in the editor, and re-running this will not overwrite their choices.');
console.log('\nNow run: node build.js');
