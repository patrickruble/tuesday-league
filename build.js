#!/usr/bin/env node
/* ============================================================
   Katy Golf League — site generator

     node build.js

   Format: every team plays its own 9-hole scramble off its own
   team handicap. There are no matchups. Standings are the sum
   of Stableford points. Bays are shared for logistics, and the
   team beside you signs off your card.
   ============================================================ */

const fs   = require('fs');
const path = require('path');

const ROOT = __dirname;
const DATA = p => JSON.parse(fs.readFileSync(path.join(ROOT,'data',p),'utf8'));
const OUT  = (p, html) => {
  const full = path.join(ROOT, p);
  fs.mkdirSync(path.dirname(full), { recursive: true });
  fs.writeFileSync(full, html.trim() + '\n');
  console.log('  wrote', p);
};

/* node build.js --from-db  refreshes data/teams.json from
   Supabase first, so the pages carry whatever teams have set
   for themselves. Without the flag it builds from the file as
   it stands, which is faster and works offline. */
async function refresh() {
  if (!process.argv.includes('--from-db')) return;
  const { pull } = require('./tools/pull-db.js');
  await pull();
  console.log('');
}


let league, teams, schedule, bySlug, bags, moodLog, sponsors;

function loadData() {
  league   = DATA('league.json');
  teams    = DATA('teams.json');
  schedule = DATA('schedule.json');
  bySlug   = Object.fromEntries(teams.map(t => [t.slug, t]));

  const optional = f => { try { return DATA(f); } catch { return {}; } };

  /* typefaces, patterns and the palette live in one shared file
     so the editor and the generator always agree */
  const looks = optional('looks.json');
  if (looks.typefaces) league.typefaces = looks.typefaces;

  bags     = optional('bags.json');
  moodLog  = optional('mood-history.json');
  sponsors = optional('sponsors.json');
}

/* ---------- helpers ---------- */
const esc = s => String(s == null ? '' : s)
  .replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');

const rgba = (hex,a) => {
  const n = parseInt(hex.slice(1),16);
  return `rgba(${n>>16},${(n>>8)&255},${n&255},${a})`;
};

const ordinal = n => {
  const s = ['th','st','nd','rd'], v = n % 100;
  return n + (s[(v-20)%10] || s[v] || s[0]);
};

const slugify = s => s.toLowerCase().normalize('NFD')
  .replace(/[\u0300-\u036f]/g,'').replace(/['’]/g,'')
  .replace(/&/g,' and ')
  .replace(/[^a-z0-9]+/g,'-').replace(/^-|-$/g,'');

const initials = s => s.split(/\s+/).map(w => w[0]).join('').slice(0,2).toUpperCase();

/* teeTime is stored as 24 hour so the calendar file is
   unambiguous; pages show it the way people say it. */
function clock(t) {
  const [h, m] = String(t || '19:30').split(':').map(Number);
  const h12 = h % 12 || 12;
  return `${h12}:${String(m).padStart(2,'0')}`;
}

/* A dark background needs the text panels turned up so nothing
   becomes hard to read. */
/* Photos from the database are absolute Supabase URLs; ones
   from teams.json are repo-relative. Handle both. */
function assetUrl(p, depth = 1) {
  if (!p) return null;
  return /^https?:\/\//.test(p) ? p : '../'.repeat(depth) + p;
}

function isDark(hex) {
  const n = parseInt(hex.slice(1), 16);
  const lum = 0.299*(n>>16) + 0.587*((n>>8)&255) + 0.114*(n&255);
  return lum < 128;
}

/* Accent colours are all dark enough to carry white text, which
   makes them unreadable as headings on a dark page. Mix toward
   white so the team colour still reads as theirs. */
function lighten(hex, amount = 0.5) {
  const n = parseInt(hex.slice(1), 16);
  const mix = c => Math.round(c + (255 - c) * amount);
  const r = mix(n>>16), g = mix((n>>8)&255), b = mix(n&255);
  return '#' + [r,g,b].map(v => v.toString(16).padStart(2,'0')).join('');
}

function embedUrl(song) {
  if (!song || !song.id) return null;
  if (song.provider === 'spotify')
    return `https://open.spotify.com/embed/track/${song.id}?utm_source=generator&theme=0`;
  return `https://www.youtube.com/embed/${song.id}?autoplay=1`;
}
const providerName = p => p === 'spotify' ? 'Spotify' : 'YouTube';

/* YouTube's cover can be worked out from the id. Spotify's is
   fetched once when the song is saved and stored on the team. */
function coverFor(song) {
  if (!song || !song.id) return null;
  if (song.art) return song.art;
  if (song.provider === 'spotify') return null;
  return `https://img.youtube.com/vi/${song.id}/mqdefault.jpg`;
}

/* ---------- derived ---------- */
let played, standings, players, nextWeek, bayOf, partnerOf;

function derive() {
  played = teams.some(t => t.played > 0);

  standings = [...teams].sort((a,b) =>
    (b.points||0) - (a.points||0) ||
    (b.played ? b.points/b.played : 0) - (a.played ? a.points/a.played : 0) ||
    (b.bestRound||0) - (a.bestRound||0) ||
    a.name.localeCompare(b.name));
  standings.forEach((t,i) => { t.rank = i + 1; });

  players = [];
  teams.forEach(t => t.roster.forEach((p,i) => {
    p.slug = slugify(p.name);
    players.push({ ...p, team: t, order: i + 1, initials: initials(p.name) });
  }));

  nextWeek  = schedule.find(w => w.status === 'next') || schedule[0];
  bayOf     = {};
  partnerOf = {};
  if (nextWeek) for (const b of nextWeek.bays || []) {
    for (const slug of b.teams) {
      bayOf[slug] = b.bay;
      const other = b.teams.find(s => s !== slug);
      if (other) partnerOf[slug] = other;
    }
  }
}

/* every week a team has played, for the results list */
function weeksFor(slug) {
  return schedule
    .filter(w => w.status === 'final')
    .map(w => {
      const b = (w.bays||[]).find(x => x.teams.includes(slug));
      if (!b) return null;
      const sc = (b.scores || {})[slug];
      return sc == null ? null : { week: w, bay: b.bay, points: sc,
        roundId: (b.rounds || {})[slug] || null,
        partner: b.teams.find(s => s !== slug) };
    })
    .filter(Boolean);
}

/* ---------- layout ---------- */
function sponsorFooter() {
  const list = sponsors.supporters || [];
  if (!list.length && !sponsors.title) return '';
  const one = s => s.url
    ? `<a href="${esc(s.url)}" rel="noopener">${esc(s.name)}</a>${s.blurb ? ` <span>${esc(s.blurb)}</span>` : ''}`
    : `<b>${esc(s.name)}</b>${s.blurb ? ` <span>${esc(s.blurb)}</span>` : ''}`;
  return `
<div class="sponsors">
  <div class="inner">
    <span class="lede">${sponsors.title ? 'Presented by' : 'Supported by'}</span>
    ${sponsors.title ? `<div class="slot title">${one(sponsors.title)}</div>` : ''}
    ${list.map(s => `<div class="slot">${one(s)}</div>`).join('')}
  </div>
</div>`;
}

function layout({ title, current, depth = 0, head = '', body }) {
  const up = depth ? '../' : '';
  const link = n =>
    `<a href="${up}${n.href}"${n.href === current ? ' aria-current="page"' : ''}>${esc(n.label)}</a>`;

  const nav = league.nav.map(link).join('\n      ');
  const more = (league.navMore || []).length ? `
      <div class="more">
        <button type="button" id="morebtn" aria-expanded="false" aria-controls="morelist">More</button>
        <div class="morelist" id="morelist">
          ${league.navMore.map(link).join('\n          ')}
        </div>
      </div>` : '';

  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(title)} — ${esc(league.name)}</title>
<link rel="icon" href="${up}favicon.svg" type="image/svg+xml">
<link rel="icon" href="${up}favicon-32.png" sizes="32x32">
<link rel="apple-touch-icon" href="${up}apple-touch-icon.png">
<meta name="theme-color" content="#007041">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Archivo:wdth,wght@100..125,400..800&family=Instrument+Sans:wght@400;500;600&family=Martian+Mono:wght@400;600&display=swap" rel="stylesheet">
<link rel="stylesheet" href="${up}assets/site.css">
<link rel="stylesheet" href="${up}assets/extra.css">
<link rel="stylesheet" href="${up}assets/patterns.css">
${head}
</head>
<body>

<header class="masthead">
  <div class="inner">
    <a class="mark" href="${up}index.html">${esc(league.wordmark[0])} <em>·</em> ${esc(league.wordmark[1])}</a>
    <button class="navtoggle" id="navtoggle" aria-expanded="false" aria-controls="nav">MENU</button>
    <nav id="nav">
      ${nav}${more}
      <span id="authslot" class="authslot"></span>
    </nav>
  </div>
</header>

${body}

${sponsorFooter()}

<footer>
  <div class="inner">
    <span>${esc(league.name)}</span>
    <span>${teams.length} teams · ${esc(league.format)}</span>
  </div>
</footer>

<script>
(function(){
  var b=document.getElementById('navtoggle'),n=document.getElementById('nav');
  if(b) b.addEventListener('click',function(){
    var open=n.classList.toggle('open');
    b.setAttribute('aria-expanded',open);
    b.textContent=open?'CLOSE':'MENU';
  });

  var mb=document.getElementById('morebtn');
  if(mb){
    mb.addEventListener('click',function(e){
      e.stopPropagation();
      var open=mb.parentNode.classList.toggle('open');
      mb.setAttribute('aria-expanded',open);
    });
    document.addEventListener('click',function(){
      mb.parentNode.classList.remove('open');
      mb.setAttribute('aria-expanded','false');
    });
  }
})();
</script>
<script type="module">
  import { paintAuthSlot } from '${up || './'}assets/db.js';
  paintAuthSlot(${depth});
</script>
</body>
</html>`;
}

/* ============================================================
   LEADERBOARD
   ============================================================ */
function buildLeaderboard() {
  const rows = standings.map(t => `
  <a class="team" style="--c:${t.accent}" href="teams/${t.slug}.html">
    <div class="row">
      <div class="pos">${t.rank}</div>
      <div><div class="crest">${esc(t.crest)}</div></div>
      <div class="name"><b>${esc(t.name)}</b>
        <div class="players">${t.roster.map(p => esc(p.name.split(' ').pop())).join(' · ')}</div></div>
      <div class="pld">${t.played || '—'}</div>
      <div class="pts">${t.points || '—'}</div>
      <div class="avg">${t.played ? (t.points/t.played).toFixed(1) : '—'}</div>
      <div class="go">→</div>
    </div>
  </a>`).join('');

  return layout({
    title:'Leaderboard', current:'index.html',
    body:`
<div class="title">
  <div class="inner">
    <div><div class="eyebrow">${esc(league.season)} · Stableford</div><h1>Leaderboard</h1></div>
    <div class="aside">
      ${played ? `THROUGH <b>WEEK ${league.currentWeek}</b> OF ${league.weeks}` : `<b>SEASON STARTS</b>`}<br>
      ${nextWeek ? `${played ? 'NEXT ROUND' : 'FIRST ROUND'} <b>${esc(nextWeek.label)}</b> · ${clock(league.teeTime)}` : ''}
    </div>
  </div>
</div>
<div class="colhead">
  <div class="row">
    <span>POS</span><span></span><span>TEAM</span>
    <span class="c-hide">ROUNDS</span><span>POINTS</span>
    <span class="c-hide">AVG</span><span class="c-hide"></span>
  </div>
</div>
<div class="board">${rows}
</div>
<div class="notes">
  <div class="inner">
    <span>${esc(league.scoringNote)}</span>
    <span>Every team plays its own scramble off its own handicap</span>
    <span>${esc(league.tiebreak)}</span>
  </div>
</div>`
  });
}

/* ============================================================
   TEAMS
   ============================================================ */
function buildTeams() {
  const cards = [...teams].sort((a,b) => a.name.localeCompare(b.name)).map(t => `
    <a class="card" style="--c:${t.accent}" href="teams/${t.slug}.html">
      <div class="cap"><div class="tile">${esc(t.crest)}</div><b>${esc(t.name)}</b></div>
      <div class="body"><div class="who">${t.roster.map(p => `<span>${esc(p.name)}</span>`).join('')}</div></div>
      <div class="foot">
        <span class="pts">${t.points || '—'}</span>
        <span style="color:var(--dim)">${t.played ? (t.points/t.played).toFixed(1) + ' avg' : 'no rounds yet'}</span>
        <span style="margin-left:auto;color:var(--dim)">${played ? ordinal(t.rank) : ''}</span>
      </div>
    </a>`).join('');

  return layout({
    title:'Teams', current:'teams.html',
    body:`
<div class="title">
  <div class="inner">
    <div><div class="eyebrow">${teams.length} teams · ${players.length} players</div><h1>Teams</h1></div>
  </div>
</div>
<div class="wrap"><div class="grid">${cards}
  </div>
</div>`
  });
}

/* ============================================================
   SCHEDULE — bay assignments, not matchups
   ============================================================ */
function buildSchedule() {
  const weeks = schedule.map(wk => {
    const rows = (wk.bays||[]).map(b => {
      const list = b.teams.map(s => bySlug[s]).filter(Boolean);
      const scores = b.scores || {};
      return `
    <div class="baytile">
      <div class="baytag"><b>${b.bay}</b><span>BAY</span></div>
      <div class="sharing">
        ${list.map(t => `
        <a class="vs" href="teams/${t.slug}.html">
          <i style="background:${t.accent}"></i>
          <b>${esc(t.name)}</b>
          ${scores[t.slug] != null ? `<span class="sc">${scores[t.slug]}</span>` : ''}
        </a>`).join('')}
        ${list.length === 1 ? '<span class="alone">bay to themselves</span>' : ''}
      </div>
    </div>`;
    }).join('');

    return `
  <section class="week">
    <div class="whead">
      <h2>Week ${wk.week}</h2>
      <span class="date">${esc(wk.label)}${wk.status==='next' ? ' · '+clock(league.teeTime) : ''}
        · ${esc(wk.course)} ${esc(wk.nine)}</span>
      <span class="flag ${wk.status==='next' ? 'next">NEXT UP' : 'done">FINAL'}</span>
    </div>${rows}
  </section>`;
  }).join('');

  return layout({
    title:'Schedule', current:'schedule.html',
    body:`
<div class="title">
  <div class="inner">
    <div><div class="eyebrow">${esc(league.season)} · ${league.weeks} weeks · ${league.bays} bays</div>
    <h1>Schedule</h1></div>
    <a class="ics" href="league.ics">Add to your calendar</a>
  </div>
</div>
<div class="wrap">
  <p class="lede2">Everyone plays their own scramble. Bays are shared two teams to a
    bay, and the team next to you signs off your card at the end of the night.</p>
  ${weeks}
  <div style="height:50px"></div>
</div>`
  });
}

/* ============================================================
   PLAYLIST
   ============================================================ */
function buildPlaylist() {
  const withSongs = standings.filter(t => t.song && t.song.id);

  const tracks = withSongs.map((t,i) => `
    <div class="track" style="--c:${t.accent}"
         data-src="${esc(embedUrl(t.song))}"
         data-h="${t.song.provider === 'spotify' ? 152 : 80}">
      <div class="num">${String(i+1).padStart(2,'0')}</div>
      <div class="art${coverFor(t.song) ? '' : ' empty'}" style="background:${t.accent}">
        ${coverFor(t.song) ? `<img src="${esc(coverFor(t.song))}" alt="" loading="lazy">` : ''}
        <button class="play" aria-label="Play ${esc(t.song.title)}">▶</button>
      </div>
      <div class="info"><b>${esc(t.song.title)}</b><span>${esc(t.song.artist)}</span></div>
      <div class="by">
        <a href="teams/${t.slug}.html" style="color:${t.accent}">${esc(t.name)}</a>
        <span>${providerName(t.song.provider)}</span>
      </div>
    </div>`).join('');

  const leaguePlaylist = league.spotifyPlaylist ? `
  <div class="wholething">
    <div class="head"><h2>The whole thing</h2>
      <span class="note">Every walk-up song in one playlist</span></div>
    <iframe src="https://open.spotify.com/embed/playlist/${esc(league.spotifyPlaylist)}?utm_source=generator&theme=0"
            width="100%" height="352" frameborder="0" loading="lazy"
            allow="autoplay; clipboard-write; encrypted-media; fullscreen; picture-in-picture"
            title="League playlist"></iframe>
  </div>` : '';

  return layout({
    title:'Playlist', current:'playlist.html',
    body:`
<div class="title">
  <div class="inner">
    <div><div class="eyebrow">${withSongs.length} of ${teams.length} teams have picked</div>
    <h1>The Playlist</h1></div>
  </div>
</div>
<div class="wrap narrow">
  ${leaguePlaylist}
  ${withSongs.length ? `
  <div class="head" style="margin-top:34px"><h2>By team</h2><span class="note">In league order</span></div>
  <div class="tracklist">${tracks}
  </div>` : `
  <div class="empty2" style="margin-top:28px">
    <b>No songs yet</b>
    Every team picks a walk-up song on their team page. Nothing here until they do.
  </div>`}
  <p class="fineprint">
    Spotify plays the full track if you're signed in, and a 30 second preview if
    you're not. YouTube plays the lot either way. Set yours on your
    <a href="edit-team.html">team page</a>.
  </p>
</div>
<div id="player" class="dock">
  <div class="dockinner">
    <button id="closedock" aria-label="Stop">✕</button>
    <iframe id="frame" allow="autoplay; encrypted-media" title="Player"></iframe>
  </div>
</div>
<script>
var frame=document.getElementById('frame'),dock=document.getElementById('player'),cur=null;
function stop(){frame.src='';dock.classList.remove('up');
  if(cur){cur.querySelector('.play').textContent='▶';cur.classList.remove('on');cur=null;}}
document.getElementById('closedock').addEventListener('click',stop);
document.querySelectorAll('.track').forEach(function(t){
  t.querySelector('.play').addEventListener('click',function(){
    if(cur===t){stop();return;}
    if(cur){cur.querySelector('.play').textContent='▶';cur.classList.remove('on');}
    t.classList.add('on');t.querySelector('.play').textContent='❚❚';
    frame.style.height=t.dataset.h+'px';frame.src=t.dataset.src;
    dock.classList.add('up');cur=t;
  });
});
</script>`
  });
}

/* ============================================================
   RECORDS
   ============================================================ */
function buildRecords() {
  const card = (label,value,who,accent,href) => `
    <div style="background:var(--card);border:1px solid var(--rule);padding:20px;
         border-left:5px solid ${accent}">
      <div style="font-size:10px;letter-spacing:.14em;text-transform:uppercase;color:var(--dim)">${esc(label)}</div>
      <div style="font-family:var(--data);font-size:34px;font-weight:600;letter-spacing:-.04em;margin:8px 0 4px">${esc(value)}</div>
      <div style="font-size:13px">${href ? `<a href="${href}" style="color:inherit">${esc(who)}</a>` : esc(who)}</div>
    </div>`;

  if (!played) {
    return layout({
      title:'Records', current:'records.html',
      body:`
<div class="title">
  <div class="inner">
    <div><div class="eyebrow">${esc(league.season)}</div><h1>Records</h1></div>
  </div>
</div>
<div class="wrap">
  <div class="empty2" style="margin:28px 0 20px">
    <b>Nothing to record yet</b>
    Best round, most eagles, closest to the pin and the rest fill in as the
    season runs. First round is ${nextWeek ? esc(nextWeek.label) : 'soon'}.
  </div>
  <div style="display:grid;grid-template-columns:repeat(auto-fill,minmax(240px,1fr));gap:14px;margin-bottom:50px">
    ${card('Best round','—','Waiting','#007041')}
    ${card('Most points','—','Waiting','#007041')}
    ${card('Closest to pin','—','Waiting','#007041')}
    ${card('Long putt','—','Waiting','#007041')}
    ${card('Chip-ins','—','Waiting','#007041')}
    ${card('Lowest handicap','—','Waiting','#007041')}
  </div>
</div>`
    });
  }

  const best  = [...teams].filter(t=>t.bestRound).sort((a,b) => b.bestRound - a.bestRound)[0];
  const top   = standings[0];
  const lowHcp = [...teams].sort((a,b) => a.handicap - b.handicap)[0];
  const lowIdx = [...players].filter(p=>p.hcp).sort((a,b) => a.hcp - b.hcp)[0];

  return layout({
    title:'Records', current:'records.html',
    body:`
<div class="title">
  <div class="inner">
    <div><div class="eyebrow">${esc(league.season)} · through week ${league.currentWeek}</div><h1>Records</h1></div>
  </div>
</div>
<div class="wrap">
  <div style="display:grid;grid-template-columns:repeat(auto-fill,minmax(240px,1fr));gap:14px;margin:28px 0 20px">
    ${best ? card('Best round', best.bestRound+' pts', best.name, best.accent, 'teams/'+best.slug+'.html') : ''}
    ${card('Most points', top.points, top.name, top.accent, 'teams/'+top.slug+'.html')}
    ${card('Best average', (top.points/top.played).toFixed(1), top.name, top.accent, 'teams/'+top.slug+'.html')}
    ${card('Lowest team handicap', lowHcp.handicap, lowHcp.name, lowHcp.accent, 'teams/'+lowHcp.slug+'.html')}
    ${lowIdx ? card('Lowest index', lowIdx.hcp, lowIdx.name, lowIdx.team.accent, 'players/'+lowIdx.slug+'.html') : ''}
  </div>
  <div id="awards"></div>

  <p style="color:var(--dim);font-size:13px;max-width:56ch;padding-bottom:50px">
    Most improved needs four rounds before it means anything. Closest to the pin,
    long putt and chip-ins appear once side contests are being recorded.
  </p>
</div>
<script type="module" src="assets/awards.js"></script>`
  });
}

/* ============================================================
   TEAM PAGE
   ============================================================ */
function buildTeamPage(t) {
  const face = league.typefaces[t.typeface] || league.typefaces.archivo;
  const mood = league.moodSentiment[t.moodSentiment] || '#B8EB7A';

  const head = `
<link href="https://fonts.googleapis.com/css2?family=${face.google}&display=swap" rel="stylesheet">
<style>
  :root{
    --accent:${t.accent};
    --pat:${rgba(t.accent,.15)};
    --mood:${mood};
    --team-display:${face.stack};
    --team-wdth:${face.wdth};
  }
${t.backdropColor ? `  .sheet{background-color:${t.backdropColor}}` : ''}
${t.backdropImage ? `  .sheet{
    background-image:${t.backdrop && t.backdrop !== 'none' ? 'var(--pattern),' : ''}url("${assetUrl(t.backdropImage)}");
    background-repeat:${t.backdropMode === 'tile' ? 'repeat' : 'no-repeat'};
    background-size:${t.backdropMode === 'tile' ? 'auto' : 'cover'};
    background-position:center;
    background-attachment:${t.backdropMode === 'fixed' ? 'fixed' : 'scroll'};
  }` : ''}
${t.backdropColor && isDark(t.backdropColor) ? `
  /* dark background — invert the type rather than floating
     white boxes on it */
  .sheet{
    --ink:#F3F5F3;
    --dim:rgba(255,255,255,.56);
    --rule:rgba(255,255,255,.15);
    --card:rgba(255,255,255,.055);
    --pat:${rgba(lighten(t.accent,.4), .22)};
    color:#F3F5F3;
  }
  .sheet .panel,.sheet .h2h,.sheet .player,.sheet .match,
  .sheet .run,.sheet .statgrid > div,.sheet .bag,.sheet .item{
    background:rgba(255,255,255,.055);
    border-color:rgba(255,255,255,.15);
    color:#F3F5F3;
  }
  .sheet .roster{background:rgba(255,255,255,.15)}
  .sheet .head h2{color:${lighten(t.accent,.45)}}
  .sheet .hcp{color:${lighten(t.accent,.45)}}
  .sheet .said,.sheet .idx,.sheet .pld,.sheet .note,
  .sheet .course,.sheet small{color:rgba(255,255,255,.56)}
  .sheet .mid .sc{color:#F3F5F3}
  .sheet a{color:${lighten(t.accent,.5)}}
  .sheet section + section{border-top-color:rgba(255,255,255,.14)}` : ''}
</style>`;

  const roster = t.roster.map((p,i) => `
      <article class="player">
        <div class="face${p.photo ? ' has-img' : ''}">${
          p.photo ? `<img src="${esc(assetUrl(p.photo))}" alt="${esc(p.name)}" loading="lazy">` : esc(initials(p.name))
        }</div>
        <div class="idx">${String(i+1).padStart(2,'0')}${i===0?' · CAPTAIN':''}</div>
        <h3><a href="../players/${p.slug}.html" style="color:inherit;text-decoration:none">${esc(p.name)}</a></h3>
        <div class="hcp">${p.hcp ? 'HCP INDEX ' + p.hcp : 'INDEX TBC'}</div>
        ${p.quote ? `<p class="said">“${esc(p.quote)}”</p>` : ''}
      </article>`).join('');

  /* who you're sharing with next week */
  const partner = partnerOf[t.slug] ? bySlug[partnerOf[t.slug]] : null;
  const bay = bayOf[t.slug];
  const nextBlock = nextWeek ? `
    <section>
      <div class="head"><h2>Next round</h2>
        <span class="note">${esc(nextWeek.label)} · ${esc(nextWeek.course)} ${esc(nextWeek.nine)}</span>
      </div>
      <div class="h2h">
        <div class="baytag"><b>${bay ?? '—'}</b><span>BAY</span></div>
        <div class="txt">
          ${partner ? `<b>Sharing with ${esc(partner.name)}</b>
            They'll sign off your card, and you'll sign off theirs.`
                    : `<b>Bay to yourselves</b>
            Nobody beside you this week — Chris will sign your card.`}
        </div>
      </div>
    </section>` : '';

  const runs = moodLog[t.slug] || [];
  const run  = runs[0];
  const moodExtra = run && run.days >= 7 ? ` <span class="runfor">for ${run.days} days</span>` : '';
  const moodStrip = runs.length > 1 ? `
    <section>
      <div class="head"><h2>Mood history</h2><span class="note">Since the season started</span></div>
      <div class="moodruns">${runs.map(r => `
        <div class="run s-${r.sentiment}"><b>${esc(r.word)}</b>
          <span>${r.days} day${r.days===1?'':'s'}</span></div>`).join('')}
      </div>
    </section>` : '';

  const rounds = weeksFor(t.slug);
  const results = rounds.length ? `
    <section>
      <div class="head"><h2>Rounds</h2></div>
      ${rounds.map(r => `
      <a class="match" href="${r.roundId ? '../card.html?round=' + r.roundId : '#'}"
         style="grid-template-columns:74px 1fr auto;text-decoration:none;color:inherit">
        <div class="pld">${esc(r.week.label)}</div>
        <div class="vs"><b>${esc(r.week.course)} ${esc(r.week.nine)}</b>
          ${r.partner ? `<span style="color:var(--dim);font-size:12px">bay ${r.bay} with ${esc(bySlug[r.partner]?.name||'')}</span>` : ''}</div>
        <div class="mid"><span class="sc">${r.points}</span>
          <span style="font-size:9px;display:block">POINTS</span></div>
      </a>`).join('')}
    </section>` : '';

  const last = t.lastSeason ? `
    <section>
      <div class="head"><h2>Last season</h2>
        <span class="note">Different format — kept for reference</span></div>
      <div class="statgrid">
        <div><b>${t.lastSeason.average}</b><span>Average</span><small>over ${t.lastSeason.played} rounds</small></div>
        <div><b>${t.lastSeason.best}</b><span>Best</span></div>
        <div><b>${t.lastSeason.worst}</b><span>Worst</span></div>
      </div>
    </section>` : '';

  const crest = t.crestUrl
    ? `<img src="${esc(assetUrl(t.crestUrl))}" alt="${esc(t.name)} crest">` : esc(t.crest);

  return layout({
    title:t.name, current:'teams.html', depth:1, head,
    body:`
<div class="hero">
  <div class="inner">
    <div class="eyebrow">${played ? ordinal(t.rank) + ' of ' + teams.length : esc(league.season)}</div>
    <h1>${esc(t.name)}</h1>
    <div class="underline">
      <div class="crest-sm${t.crestUrl ? ' has-img' : ''}">${crest}</div>
      <span class="meta">${bay ? 'Bay ' + bay + ' · ' : ''}${esc(league.night)} ${clock(league.teeTime)}${t.handicap ? ' · handicap ' + (t.handicap > 0 ? '+' : '') + t.handicap : ''}</span>
      <span class="tally"><b>${t.points || '—'}</b> season points</span>
    </div>
  </div>
</div>

<div class="status">
  <div class="inner">
    <div class="moodline"><span class="lbl">Mood</span><i class="dot2"></i><b>${esc(t.mood)}</b>${moodExtra}</div>
    ${t.song && t.song.id ? `
    <div class="song">
      <span class="lbl">Walk-up</span>
      <div class="art${coverFor(t.song) ? '' : ' empty'}">
        ${coverFor(t.song) ? `<img src="${esc(coverFor(t.song))}" alt="" loading="lazy">` : ''}
        <button class="play" id="play" aria-label="Play ${esc(t.song.title)}">▶</button>
      </div>
      <div class="song-meta"><b>${esc(t.song.title)}</b><span>${esc(t.song.artist)}</span></div>
    </div>` : `
    <div class="song"><span class="lbl">Walk-up</span>
      <span style="font-size:12px;color:rgba(255,255,255,.45)">not picked yet</span></div>`}
  </div>
</div>

<div id="player" class="dock">
  <div class="dockinner">
    <button id="closedock" aria-label="Stop">✕</button>
    <iframe id="frame" allow="autoplay; encrypted-media" title="Walk-up song"></iframe>
  </div>
</div>

<div class="numbers">
  <div class="inner">
    ${t.played ? `
      <span><b>${(t.points/t.played).toFixed(1)}</b> a round</span>
      <span><b>${t.bestRound || '—'}</b> best</span>
      <span><b>${t.played}</b> round${t.played === 1 ? '' : 's'}</span>
      <span><b>${ordinal(t.rank)}</b> of ${teams.length}</span>
      ${t.handicap ? `<span><b>${t.handicap > 0 ? '+' : ''}${t.handicap}</b> handicap</span>` : ''}`
    : `<span class="waiting">No rounds played yet — first one ${nextWeek ? esc(nextWeek.label) : 'soon'}</span>`}
  </div>
</div>

<div class="sheet bg-${t.backdrop}">
  <div class="wrap">
    ${t.bio ? `<section>
      <div class="head"><h2>The Team</h2></div>
      <div class="panel blurb">${esc(t.bio)}</div>
    </section>` : ''}
    <section>
      <div class="head"><h2>Roster</h2></div>
      <div class="roster">${roster}
      </div>
    </section>
${nextBlock}${moodStrip}${results}${last}
    <div style="height:30px"></div>
  </div>
</div>

<script>
(function(){
  var b=document.getElementById('play');
  if(!b) return;
  var dock=document.getElementById('player'),frame=document.getElementById('frame'),
      src=${JSON.stringify(embedUrl(t.song) || '')},
      h=${t.song && t.song.provider === 'spotify' ? 152 : 80}, on=false;
  function stop(){frame.src='';dock.classList.remove('up');b.textContent='▶';on=false;}
  document.getElementById('closedock').addEventListener('click',stop);
  b.addEventListener('click',function(){
    if(!src) return;
    if(on){stop();return;}
    frame.style.height=h+'px';frame.src=src;dock.classList.add('up');
    b.textContent='❚❚';on=true;
  });
})();
</script>
<script type="module">
/* The mood is the one thing that should be current rather than
   whatever it was at build time. Everything else on the page is
   already rendered, so this just swaps a word. */
import { supabase } from '../assets/db.js';
const SENT = ${JSON.stringify(league.moodSentiment)};
try {
  const { data } = await supabase.from('teams')
    .select('mood, moods(sentiment)')
    .eq('slug', ${JSON.stringify(t.slug)})
    .maybeSingle();
  if (data && data.mood) {
    const el = document.querySelector('.moodline b');
    if (el && el.textContent !== data.mood) {
      el.textContent = data.mood;
      const s = data.moods && data.moods.sentiment;
      if (s && SENT[s]) document.documentElement.style.setProperty('--mood', SENT[s]);
      const run = document.querySelector('.runfor');
      if (run) run.remove();          // the count is stale once it changes
    }
  }
} catch (e) { /* the page is fine without this */ }
</script>`
  });
}

/* ============================================================
   PLAYER PAGE
   ============================================================ */
function buildPlayerPage(p) {
  const t = p.team;
  const mates = t.roster.filter(m => m.slug !== p.slug).map(m => `
      <a href="${m.slug}.html">
        <div class="mini${m.photo ? ' has-img' : ''}">${
          m.photo ? `<img src="${esc(assetUrl(m.photo))}" alt="" loading="lazy">` : initials(m.name)
        }</div>
        <div><b>${esc(m.name)}</b><span>${m.hcp ? 'HCP ' + m.hcp : 'index TBC'}</span></div>
      </a>`).join('');

  const kit = bags[p.slug] || [];
  const bagBlock = kit.length ? `
  <section>
    <div class="head"><h2>What's in the bag</h2>
      <span class="note">${kit.filter(i => i.forSale).length ? 'Something here is for sale' : ''}</span></div>
    <div class="bag">${kit.map(i => `
      <div class="item${i.forSale ? ' selling' : ''}">
        <div class="cat">${esc(i.category)}</div>
        <div class="what">
          <b>${esc([i.brand, i.model].filter(Boolean).join(' '))}</b>
          ${i.spec ? `<span>${esc(i.spec)}</span>` : ''}
          ${i.note ? `<p>${esc(i.note)}</p>` : ''}
        </div>
        ${i.forSale ? `<div class="tag">FOR SALE${i.asking ? ` · $${i.asking}` : ''}</div>` : ''}
      </div>`).join('')}
    </div>
  </section>` : '';

  return layout({
    title:p.name, current:'teams.html', depth:1,
    head:`<style>:root{--accent:${t.accent}}</style>`,
    body:`
<div class="phead">
  <div class="inner">
    <div class="avatar${p.photo ? ' has-img' : ''}">${
      p.photo ? `<img src="${esc(assetUrl(p.photo))}" alt="${esc(p.name)}">` : esc(p.initials)
    }</div>
    <div>
      <div class="eyebrow">Player ${String(p.order).padStart(2,'0')}${p.order===1?' · Captain':''}</div>
      <h1>${esc(p.name)}</h1>
      <div class="team">Plays for <a href="../teams/${t.slug}.html">${esc(t.name)}</a></div>
    </div>
    <div class="idxbox"><b>${p.hcp || '—'}</b><span>HANDICAP INDEX</span></div>
  </div>
</div>

${p.quote ? `<div class="quotebar"><div class="inner"><span class="lbl">Says</span><q>${esc(p.quote)}</q></div></div>` : ''}

<div class="wrap">
  <section>
    <div class="head"><h2>This season</h2>
      <span class="note">Scramble — most stats belong to the team</span></div>
    <div class="statgrid">
      <div><b>—</b><span>Drives used</span><small>Recorded from week 1</small></div>
      <div><b>—</b><span>Closest to pin</span><small>Side contest wins</small></div>
      <div><b>—</b><span>Long putts</span><small>Side contest wins</small></div>
      <div><b>—</b><span>Chip-ins</span><small>From off the green</small></div>
    </div>
  </section>
${bagBlock}
  <section>
    <div class="head"><h2>Teammates</h2></div>
    <div class="teammates">${mates}
    </div>
  </section>
  <div style="height:40px"></div>
</div>`
  });
}

/* ============================================================
   CALENDAR
   One file, every Tuesday, with the bay in the location so it's
   on the phone screen without opening anything.
   ============================================================ */
function buildICS() {
  const stamp = d => d.toISOString().replace(/[-:]/g,'').split('.')[0] + 'Z';
  const now = stamp(new Date());

  /* Floating local times — no Z. The league always plays in one
     place, so "7:30pm" should read as 7:30pm on every phone
     regardless of where it thinks it is. */
  const pad = n => String(n).padStart(2,'0');
  const local = (y,m,d,hh,mm) => `${y}${pad(m)}${pad(d)}T${pad(hh)}${pad(mm)}00`;

  const events = schedule.map(wk => {
    const [y,m,d] = wk.date.split('-').map(Number);
    const [hh,mm] = (league.teeTime || '19:30').replace(/[^0-9:]/g,'').split(':').map(Number);
    const sh = hh || 19, sm = mm || 30;
    const eh = (sh + 2) % 24;

    const bays = (wk.bays || []).map(b =>
      `Bay ${b.bay}: ${b.teams.map(s => bySlug[s]?.name || s).join(' and ')}`).join('\\n');

    return [
      'BEGIN:VEVENT',
      `UID:week-${wk.week}@${league.domain || 'katygolfleague.com'}`,
      `DTSTAMP:${now}`,
      `DTSTART:${local(y,m,d,sh,sm)}`,
      `DTEND:${local(y,m,d,eh,sm)}`,
      `SUMMARY:${league.name} — week ${wk.week}`,
      `LOCATION:${wk.course || ''} ${wk.nine || ''}`.trim(),
      `DESCRIPTION:${wk.course} ${wk.nine}\\n\\n${bays}`,
      'BEGIN:VALARM',
      'TRIGGER:-PT2H',
      'ACTION:DISPLAY',
      'DESCRIPTION:Golf tonight',
      'END:VALARM',
      'END:VEVENT'
    ].join('\r\n');
  }).join('\r\n');

  return [
    'BEGIN:VCALENDAR',
    'VERSION:2.0',
    `PRODID:-//${league.name}//EN`,
    'CALSCALE:GREGORIAN',
    'METHOD:PUBLISH',
    `X-WR-CALNAME:${league.name}`,
    events,
    'END:VCALENDAR'
  ].join('\r\n');
}

/* ============================================================ */
main();

async function main() {
await refresh();
loadData();
derive();

console.log('Building', league.name);

/* clear generated pages so renamed or departed teams don't linger */
for (const dir of ['teams','players']) {
  const d = path.join(ROOT, dir);
  if (fs.existsSync(d)) {
    fs.readdirSync(d).filter(f => f.endsWith('.html'))
      .forEach(f => fs.unlinkSync(path.join(d, f)));
  }
}

OUT('index.html',    buildLeaderboard());
OUT('teams.html',    buildTeams());
OUT('schedule.html', buildSchedule());
OUT('playlist.html', buildPlaylist());
OUT('records.html',  buildRecords());
teams.forEach(t   => OUT(`teams/${t.slug}.html`,   buildTeamPage(t)));
players.forEach(p => OUT(`players/${p.slug}.html`, buildPlayerPage(p)));
OUT('league.ics', buildICS());
console.log(`Done. ${5 + teams.length + players.length} pages.`);
}
