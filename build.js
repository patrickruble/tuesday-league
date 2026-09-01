#!/usr/bin/env node
/* ============================================================
   Katy Golf League — site generator

     node build.js

   Reads  data/league.json, data/teams.json, data/schedule.json
   Writes every page in the site.

   Nothing generated should be hand-edited. Change the data,
   run this, push.
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

const league   = DATA('league.json');
const teams    = DATA('teams.json');
const schedule = DATA('schedule.json');
const bySlug   = Object.fromEntries(teams.map(t => [t.slug, t]));

/* optional data files — the site works without them */
const optional = f => {
  try { return DATA(f); } catch { return {}; }
};
const bags     = optional('bags.json');
const moodLog  = optional('mood-history.json');
const sponsors = optional('sponsors.json');

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
  .replace(/[\u0300-\u036f]/g,'').replace(/[^a-z0-9]+/g,'-').replace(/^-|-$/g,'');

const initials = s => s.split(/\s+/).map(w => w[0]).join('').slice(0,2).toUpperCase();

/* Build the right embed for whichever service a team picked.
   Spotify only plays full tracks for listeners signed into
   Spotify — everyone else gets a 30 second preview. YouTube
   plays the whole thing for anyone, so it's the safer default. */
function embedUrl(song) {
  if (!song || !song.id) return null;
  switch (song.provider) {
    case 'spotify':
      return `https://open.spotify.com/embed/track/${song.id}?utm_source=generator&theme=0`;
    case 'soundcloud':
      return `https://w.soundcloud.com/player/?url=${encodeURIComponent(song.id)}&color=%23007041&auto_play=true&show_artwork=false`;
    default:
      return `https://www.youtube.com/embed/${song.id}?autoplay=1`;
  }
}

const providerName = p =>
  p === 'spotify' ? 'Spotify' : p === 'soundcloud' ? 'SoundCloud' : 'YouTube';

/* ---------- derived data ---------- */
const standings = [...teams].sort((a,b) => b.points - a.points || b.bestRound - a.bestRound);
standings.forEach((t,i) => { t.rank = i + 1; });

const players = [];
teams.forEach(t => t.roster.forEach((p,i) => {
  p.slug = slugify(p.name);
  players.push({ ...p, team: t, order: i + 1, initials: initials(p.name) });
}));

const h2h = {};
for (const wk of schedule) {
  if (wk.status !== 'final') continue;
  for (const m of wk.matches) {
    const pair = (a,b,af,bf) => {
      h2h[a] ??= {};
      h2h[a][b] ??= { w:0,l:0,t:0,for:0,against:0,met:0 };
      const r = h2h[a][b];
      r.met++; r.for += af; r.against += bf;
      if (af > bf) r.w++; else if (af < bf) r.l++; else r.t++;
    };
    pair(m.home, m.away, m.homeScore, m.awayScore);
    pair(m.away, m.home, m.awayScore, m.homeScore);
  }
}

const nextWeek = schedule.find(w => w.status === 'next');
const nextOpp = {};
if (nextWeek) for (const m of nextWeek.matches) {
  nextOpp[m.home] = { slug: m.away, bay: m.bay };
  nextOpp[m.away] = { slug: m.home, bay: m.bay };
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
  const nav = league.nav.map(n =>
    `<a href="${up}${n.href}"${n.href === current ? ' aria-current="page"' : ''}>${esc(n.label)}</a>`
  ).join('\n      ');

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
${head}
</head>
<body>

<header class="masthead">
  <div class="inner">
    <a class="mark" href="${up}index.html">${esc(league.wordmark[0])} <em>·</em> ${esc(league.wordmark[1])}</a>
    <button class="navtoggle" id="navtoggle" aria-expanded="false" aria-controls="nav">MENU</button>
    <nav id="nav">
      ${nav}
      <span id="authslot" class="authslot"></span>
    </nav>
  </div>
</header>

${body}

${sponsorFooter(up)}

<footer>
  <div class="inner">
    <span>${esc(league.name)}</span>
    <span>${teams.length} teams · ${esc(league.format)}</span>
  </div>
</footer>

<script>
(function(){
  var b=document.getElementById('navtoggle'),n=document.getElementById('nav');
  if(!b) return;
  b.addEventListener('click',function(){
    var open=n.classList.toggle('open');
    b.setAttribute('aria-expanded',open);
    b.textContent=open?'CLOSE':'MENU';
  });
})();
</script>
<script type="module">
  import { paintAuthSlot } from '${up || './'}assets/db.js';
  paintAuthSlot(${depth});
</script>
</body>
</html>`;
}

/* ============================================================ */
function buildLeaderboard() {
  const rows = standings.map(t => `
  <a class="team" style="--c:${t.accent}" href="teams/${t.slug}.html">
    <div class="row">
      <div class="pos">${t.rank}</div>
      <div><div class="crest">${esc(t.crest)}</div></div>
      <div class="name"><b>${esc(t.name)}</b>
        <div class="players">${t.roster.map(p => esc(p.name.split(' ').pop())).join(' · ')}</div></div>
      <div class="pld">${t.played}</div>
      <div class="pts">${t.points}</div>
      <div class="form">${t.form.map(f => `<i class="dot${f?' w':''}"></i>`).join('')}</div>
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
      THROUGH <b>WEEK ${league.currentWeek}</b> OF ${league.weeks}<br>
      ${nextWeek ? `NEXT ROUND <b>${esc(nextWeek.label)}</b> · ${esc(league.teeTime)}` : ''}
    </div>
  </div>
</div>
<div class="colhead">
  <div class="row">
    <span>POS</span><span></span><span>TEAM</span>
    <span class="c-hide">PLAYED</span><span>POINTS</span>
    <span class="c-hide">LAST 5</span><span class="c-hide"></span>
  </div>
</div>
<div class="board">${rows}
</div>
<div class="notes">
  <div class="inner">
    <span>${esc(league.scoringNote)}</span>
    <span>${esc(league.format)} off team handicap</span>
    <span>${esc(league.tiebreak)}</span>
  </div>
</div>`
  });
}

/* ============================================================ */
function buildTeams() {
  const cards = [...teams].sort((a,b) => a.name.localeCompare(b.name)).map(t => `
    <a class="card" style="--c:${t.accent}" href="teams/${t.slug}.html">
      <div class="cap"><div class="tile">${esc(t.crest)}</div><b>${esc(t.name)}</b></div>
      <div class="body"><div class="who">${t.roster.map(p => `<span>${esc(p.name)}</span>`).join('')}</div></div>
      <div class="foot">
        <span class="pts">${t.points}</span>
        <span style="color:var(--dim)">${t.won}–${t.lost}</span>
        <span style="margin-left:auto;color:var(--dim)">${ordinal(t.rank)}</span>
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

/* ============================================================ */
function buildSchedule() {
  const weeks = schedule.map(wk => {
    const matches = wk.matches.map(m => {
      const h = bySlug[m.home], a = bySlug[m.away];
      const played = m.homeScore != null;
      return `
    <div class="match">
      <div class="baytag"><b>${m.bay}</b><span>BAY</span></div>
      <a class="vs" href="teams/${h.slug}.html"><i style="background:${h.accent}"></i><b>${esc(h.name)}</b></a>
      <div class="mid">${played ? `<span class="sc">${m.homeScore}–${m.awayScore}</span>` : 'vs'}</div>
      <a class="vs away" href="teams/${a.slug}.html"><b>${esc(a.name)}</b><i style="background:${a.accent}"></i></a>
      <div class="course"><b>${esc(wk.course)}</b>${esc(wk.nine)}</div>
    </div>`;
    }).join('');

    return `
  <section class="week">
    <div class="whead">
      <h2>Week ${wk.week}</h2>
      <span class="date">${esc(wk.label)}${wk.status==='next' ? ' · '+esc(league.teeTime) : ''}</span>
      <span class="flag ${wk.status==='next' ? 'next">NEXT UP' : 'done">FINAL'}</span>
    </div>${matches}
  </section>`;
  }).join('');

  return layout({
    title:'Schedule', current:'schedule.html',
    body:`
<div class="title">
  <div class="inner">
    <div><div class="eyebrow">${esc(league.season)} · ${league.weeks} weeks · ${league.bays} bays</div>
    <h1>Schedule</h1></div>
  </div>
</div>
<div class="wrap">${weeks}
  <div style="height:50px"></div>
</div>`
  });
}

/* ============================================================ */
function buildPlaylist() {
  const tracks = standings.filter(t => t.song && t.song.id).map((t,i) => `
    <div class="track" style="--c:${t.accent}"
         data-src="${esc(embedUrl(t.song))}"
         data-h="${t.song.provider === 'spotify' ? 152 : 80}">
      <div class="num">${String(i+1).padStart(2,'0')}</div>
      <button class="play" style="background:${t.accent}"
              aria-label="Play ${esc(t.song.title)}">▶</button>
      <div class="info">
        <b>${esc(t.song.title)}</b>
        <span>${esc(t.song.artist)}</span>
      </div>
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
    <div><div class="eyebrow">${teams.length} teams · ${teams.length} songs</div><h1>The Playlist</h1></div>
  </div>
</div>
<div class="wrap narrow">
  ${leaguePlaylist}
  <div class="head" style="margin-top:34px"><h2>By team</h2>
    <span class="note">In league order</span></div>
  <div class="tracklist">${tracks}
  </div>
  <p class="fineprint">
    Spotify plays the full track if you're signed in, and a 30 second preview
    if you're not. YouTube plays the lot either way. Change your team's song
    on your <a href="edit-team.html">team page</a>.
  </p>
</div>
<div id="player" class="dock">
  <div class="dockinner">
    <button id="closedock" aria-label="Stop">✕</button>
    <iframe id="frame" allow="autoplay; encrypted-media" title="Player"></iframe>
  </div>
</div>
<script>
var frame=document.getElementById('frame'),
    dock=document.getElementById('player'),cur=null;
function stop(){
  frame.src='';dock.classList.remove('up');
  if(cur){cur.querySelector('.play').textContent='▶';cur.classList.remove('on');cur=null;}
}
document.getElementById('closedock').addEventListener('click',stop);
document.querySelectorAll('.track').forEach(function(t){
  t.querySelector('.play').addEventListener('click',function(){
    if(cur===t){stop();return;}
    if(cur){cur.querySelector('.play').textContent='▶';cur.classList.remove('on');}
    t.classList.add('on');
    t.querySelector('.play').textContent='❚❚';
    frame.style.height=t.dataset.h+'px';
    frame.src=t.dataset.src;
    dock.classList.add('up');
    cur=t;
  });
});
</script>`
  });
}

/* ============================================================ */
function buildRecords() {
  const best   = [...teams].sort((a,b) => b.bestRound - a.bestRound)[0];
  const top    = standings[0];
  const worst  = standings[standings.length-1];
  const lowHcp = [...teams].sort((a,b) => a.handicap - b.handicap)[0];
  const lowIdx = [...players].sort((a,b) => a.hcp - b.hcp)[0];

  const card = (label,value,who,accent,href) => `
    <div style="background:var(--card);border:1px solid var(--rule);padding:20px;
         border-left:5px solid ${accent}">
      <div style="font-size:10px;letter-spacing:.14em;text-transform:uppercase;color:var(--dim)">${esc(label)}</div>
      <div style="font-family:var(--data);font-size:34px;font-weight:600;letter-spacing:-.04em;margin:8px 0 4px">${esc(value)}</div>
      <div style="font-size:13px">${href ? `<a href="${href}" style="color:inherit">${esc(who)}</a>` : esc(who)}</div>
    </div>`;

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
    ${card('Best round', best.bestRound+' pts', best.name, best.accent, 'teams/'+best.slug+'.html')}
    ${card('Most points', top.points, top.name, top.accent, 'teams/'+top.slug+'.html')}
    ${card('Best record', top.won+'–'+top.lost, top.name, top.accent, 'teams/'+top.slug+'.html')}
    ${card('Lowest team handicap', lowHcp.handicap, lowHcp.name, lowHcp.accent, 'teams/'+lowHcp.slug+'.html')}
    ${card('Lowest index', lowIdx.hcp, lowIdx.name, lowIdx.team.accent, 'players/'+lowIdx.slug+'.html')}
    ${card('Still trying', worst.won+'–'+worst.lost, worst.name, worst.accent, 'teams/'+worst.slug+'.html')}
  </div>
  <p style="color:var(--dim);font-size:13px;max-width:56ch;padding-bottom:50px">
    Closest to the pin, long putt and chip-in records appear here once side
    contests are being recorded each week.
  </p>
</div>`
  });
}

/* ============================================================ */
function buildTeamPage(t) {
  const face = league.typefaces[t.typeface] || league.typefaces.archivo;
  const mood = league.moodSentiment[t.moodSentiment] || '#B8EB7A';
  const opp  = nextOpp[t.slug] ? bySlug[nextOpp[t.slug].slug] : null;
  const rec  = opp && h2h[t.slug] ? h2h[t.slug][opp.slug] : null;

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
</style>`;

  const roster = t.roster.map((p,i) => `
      <article class="player">
        <div class="idx">${String(i+1).padStart(2,'0')}${i===0?' · CAPTAIN':''}</div>
        <h3><a href="../players/${p.slug}.html" style="color:inherit;text-decoration:none">${esc(p.name)}</a></h3>
        <div class="hcp">HCP INDEX ${p.hcp}</div>
        <p class="said">“${esc(p.quote)}”</p>
      </article>`).join('');

  const h2hBlock = opp ? `
    <section>
      <div class="head"><h2>Next up</h2>
        <span class="note">${esc(nextWeek.label)} · Bay ${nextOpp[t.slug].bay} · ${esc(nextWeek.course)}</span>
      </div>
      <div class="h2h">
        <i style="background:${opp.accent}"></i>
        <div class="txt"><b>${esc(opp.name)}</b>
          ${rec ? `${rec.met} previous meeting${rec.met===1?'':'s'} · ${rec.for} pts for, ${rec.against} against`
                : 'First meeting of the season'}</div>
        ${rec ? `<div class="rec" style="margin-left:auto">${rec.w}–${rec.l}${rec.t?'–'+rec.t:''}</div>` : ''}
      </div>
    </section>` : '';

  const results = schedule.filter(w => w.status==='final').map(wk => {
    const m = wk.matches.find(x => x.home===t.slug || x.away===t.slug);
    if (!m) return '';
    const home = m.home === t.slug;
    const other = bySlug[home ? m.away : m.home];
    const mine = home ? m.homeScore : m.awayScore;
    const theirs = home ? m.awayScore : m.homeScore;
    const tag = mine > theirs ? 'WON' : mine < theirs ? 'LOST' : 'TIED';
    return `
      <div class="match" style="grid-template-columns:74px 1fr auto">
        <div class="pld">${esc(wk.label)}</div>
        <div class="vs"><i style="background:${other.accent}"></i>
          <b><a href="${other.slug}.html" style="color:inherit;text-decoration:none">${esc(other.name)}</a></b></div>
        <div class="mid"><span class="sc">${mine}–${theirs}</span>
          <span style="font-size:9px;display:block">${tag}</span></div>
      </div>`;
  }).join('');

  const runs = moodLog[t.slug] || [];
  const run  = runs[0];
  const moodExtra = run && run.days >= 7
    ? ` <span class="runfor">for ${run.days} days</span>` : '';

  const moodStrip = runs.length > 1 ? `
    <section>
      <div class="head"><h2>Mood history</h2>
        <span class="note">Since the season started</span></div>
      <div class="moodruns">${runs.map(r => `
        <div class="run s-${r.sentiment}">
          <b>${esc(r.word)}</b>
          <span>${r.days} day${r.days === 1 ? '' : 's'}</span>
        </div>`).join('')}
      </div>
    </section>` : '';

  const crest = t.crestUrl
    ? `<img src="../${esc(t.crestUrl)}" alt="${esc(t.name)} crest">`
    : esc(t.crest);

  return layout({
    title:t.name, current:'teams.html', depth:1, head,
    body:`
<div class="hero">
  <div class="inner">
    <div class="crest-lg${t.crestUrl ? ' has-img' : ''}">${crest}</div>
    <div>
      <div class="eyebrow">${ordinal(t.rank)} of ${teams.length}</div>
      <h1>${esc(t.name)}</h1>
      <div class="meta">Bay ${t.bay} · ${esc(league.night)} ${esc(league.teeTime)} · Team handicap ${t.handicap}</div>
    </div>
    <div class="tally"><b>${t.points}</b><span>SEASON POINTS · ${t.won}–${t.lost}</span></div>
  </div>
</div>

<div class="status">
  <div class="inner">
    <div class="moodline"><span class="lbl">Mood</span><i class="dot2"></i><b>${esc(t.mood)}</b>${moodExtra}</div>
    <div class="song">
      <span class="lbl">Walk-up</span>
      <button class="play" id="play" aria-label="Play walk-up song">▶</button>
      <div class="song-meta"><b>${esc(t.song.title)}</b><span>${esc(t.song.artist)}</span></div>
    </div>
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
    <div><b>${(t.points/t.played).toFixed(1)}</b><span>Points per round</span></div>
    <div><b>${t.bestRound}</b><span>Best round</span></div>
    <div><b>${t.handicap}</b><span>Team handicap</span></div>
    <div><b>${t.played}</b><span>Rounds played</span></div>
    <div><b>${ordinal(t.rank)}</b><span>Standing</span></div>
  </div>
</div>

<div class="sheet bg-${t.backdrop}">
  <div class="wrap">
    <section>
      <div class="head"><h2>The Team</h2></div>
      <div class="panel blurb">${esc(t.bio)}</div>
    </section>
    <section>
      <div class="head"><h2>Roster</h2></div>
      <div class="roster">${roster}
      </div>
    </section>
${h2hBlock}
${moodStrip}
    <section>
      <div class="head"><h2>Results</h2></div>
      ${results}
    </section>
    <div style="height:30px"></div>
  </div>
</div>

<script>
(function(){
  var b=document.getElementById('play'),
      dock=document.getElementById('player'),
      frame=document.getElementById('frame'),
      src=${JSON.stringify(embedUrl(t.song) || '')},
      h=${t.song && t.song.provider === 'spotify' ? 152 : 80},
      on=false;

  function stop(){ frame.src=''; dock.classList.remove('up'); b.textContent='▶'; on=false; }
  document.getElementById('closedock').addEventListener('click',stop);

  b.addEventListener('click',function(){
    if(!src) return;
    if(on){ stop(); return; }
    frame.style.height=h+'px';
    frame.src=src;
    dock.classList.add('up');
    b.textContent='❚❚';
    on=true;
  });
})();
</script>`
  });
}

/* ============================================================ */
function buildPlayerPage(p) {
  const t = p.team;
  const mates = t.roster.filter(m => m.slug !== p.slug).map(m => `
      <a href="${m.slug}.html">
        <div class="mini">${initials(m.name)}</div>
        <div><b>${esc(m.name)}</b><span>HCP ${m.hcp}</span></div>
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
    <div class="avatar">${esc(p.initials)}</div>
    <div>
      <div class="eyebrow">Player ${String(p.order).padStart(2,'0')}${p.order===1?' · Captain':''}</div>
      <h1>${esc(p.name)}</h1>
      <div class="team">Plays for <a href="../teams/${t.slug}.html">${esc(t.name)}</a>
        · Bay ${t.bay} · ${ordinal(t.rank)} of ${teams.length}</div>
    </div>
    <div class="idxbox"><b>${p.hcp}</b><span>HANDICAP INDEX</span></div>
  </div>
</div>

<div class="quotebar">
  <div class="inner"><span class="lbl">Says</span><q>${esc(p.quote)}</q></div>
</div>

<div class="wrap">
  <section>
    <div class="head"><h2>This season</h2>
      <span class="note">Scramble — most stats belong to the team</span></div>
    <div class="statgrid">
      <div><b>—</b><span>Drives used</span><small>Recorded from week 1</small></div>
      <div><b>—</b><span>Closest to pin</span><small>Side contest wins</small></div>
      <div><b>—</b><span>Long putts</span><small>Side contest wins</small></div>
      <div><b>—</b><span>Chip-ins</span><small>From off the green</small></div>
      <div><b>${t.played}</b><span>Rounds</span><small>With ${esc(t.name)}</small></div>
      <div><b>${p.hcp}</b><span>Index</span><small>Updated weekly</small></div>
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

/* ============================================================ */
console.log('Building', league.name);
OUT('index.html',    buildLeaderboard());
OUT('teams.html',    buildTeams());
OUT('schedule.html', buildSchedule());
OUT('playlist.html', buildPlaylist());
OUT('records.html',  buildRecords());
teams.forEach(t   => OUT(`teams/${t.slug}.html`,   buildTeamPage(t)));
players.forEach(p => OUT(`players/${p.slug}.html`, buildPlayerPage(p)));
console.log(`Done. ${5 + teams.length + players.length} pages.`);

