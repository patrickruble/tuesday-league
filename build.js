#!/usr/bin/env node
/* ============================================================
   Katy Golf League — site generator

     node build.js

   Reads  data/league.json, data/teams.json, data/schedule.json
   Writes index.html, teams.html, schedule.html, playlist.html,
          records.html and teams/<slug>.html for every team.

   Nothing else in the repo should be hand-edited. Change the
   data, run this, push.
   ============================================================ */

const fs   = require('fs');
const path = require('path');

const ROOT  = __dirname;
const DATA  = p => JSON.parse(fs.readFileSync(path.join(ROOT,'data',p),'utf8'));
const OUT   = (p, html) => {
  const full = path.join(ROOT, p);
  fs.mkdirSync(path.dirname(full), { recursive: true });
  fs.writeFileSync(full, html.trim() + '\n');
  console.log('  wrote', p);
};

const league   = DATA('league.json');
const teams    = DATA('teams.json');
const schedule = DATA('schedule.json');

const bySlug = Object.fromEntries(teams.map(t => [t.slug, t]));

/* ---------- helpers ---------- */
const esc = s => String(s == null ? '' : s)
  .replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');

const rgba = (hex, a) => {
  const n = parseInt(hex.slice(1), 16);
  return `rgba(${n>>16},${(n>>8)&255},${n&255},${a})`;
};

const ordinal = n => {
  const s = ['th','st','nd','rd'], v = n % 100;
  return n + (s[(v-20)%10] || s[v] || s[0]);
};

/* standings, derived rather than stored */
const standings = [...teams].sort((a,b) =>
  b.points - a.points || b.bestRound - a.bestRound);
standings.forEach((t,i) => { t.rank = i + 1; });

/* head to head, derived from played matches */
const h2h = {};
for (const wk of schedule) {
  if (wk.status !== 'final') continue;
  for (const m of wk.matches) {
    const pair = (a,b,af,bf) => {
      h2h[a] ??= {};
      h2h[a][b] ??= { w:0, l:0, t:0, for:0, against:0, met:0 };
      const r = h2h[a][b];
      r.met++; r.for += af; r.against += bf;
      if (af > bf) r.w++; else if (af < bf) r.l++; else r.t++;
    };
    pair(m.home, m.away, m.homeScore, m.awayScore);
    pair(m.away, m.home, m.awayScore, m.homeScore);
  }
}

/* next opponent for each team */
const nextWeek = schedule.find(w => w.status === 'next');
const nextOpp = {};
if (nextWeek) for (const m of nextWeek.matches) {
  nextOpp[m.home] = { slug: m.away, bay: m.bay };
  nextOpp[m.away] = { slug: m.home, bay: m.bay };
}

/* ---------- layout ---------- */
function nav(current, depth) {
  const up = depth ? '../' : '';
  return league.nav.map(n =>
    `<a href="${up}${n.href}"${n.href === current ? ' aria-current="page"' : ''}>${esc(n.label)}</a>`
  ).join('\n      ');
}

function layout({ title, current, depth = 0, head = '', body, bodyClass = '' }) {
  const up = depth ? '../' : '';
  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(title)} — ${esc(league.name)}</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Archivo:wdth,wght@100..125,400..800&family=Instrument+Sans:wght@400;500;600&family=Martian+Mono:wght@400;600&display=swap" rel="stylesheet">
<link rel="stylesheet" href="${up}assets/site.css">
${head}
</head>
<body${bodyClass ? ` class="${bodyClass}"` : ''}>

<header class="masthead">
  <div class="inner">
    <a class="mark" href="${up}index.html">${esc(league.wordmark[0])} <em>·</em> ${esc(league.wordmark[1])}</a>
    <nav>
      ${nav(current, depth)}
    </nav>
  </div>
</header>

${body}

<footer>
  <div class="inner">
    <span>${esc(league.name)}</span>
    <span>${teams.length} teams · ${esc(league.format)}</span>
  </div>
</footer>

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
      <div class="pld">${t.played}</div>
      <div class="pts">${t.points}</div>
      <div class="form">${t.form.map(f => `<i class="dot${f ? ' w' : ''}"></i>`).join('')}</div>
      <div class="go">→</div>
    </div>
  </a>`).join('');

  return layout({
    title: 'Leaderboard', current: 'index.html',
    body: `
<div class="title">
  <div class="inner">
    <div>
      <div class="eyebrow">${esc(league.season)} · Stableford</div>
      <h1>Leaderboard</h1>
    </div>
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

/* ============================================================
   TEAMS GRID
   ============================================================ */
function buildTeams() {
  const cards = [...teams].sort((a,b) => a.name.localeCompare(b.name)).map(t => `
    <a class="card" style="--c:${t.accent}" href="teams/${t.slug}.html">
      <div class="cap"><div class="tile">${esc(t.crest)}</div><b>${esc(t.name)}</b></div>
      <div class="body"><div class="who">${
        t.roster.map(p => `<span>${esc(p.name)}</span>`).join('')
      }</div></div>
      <div class="foot">
        <span class="pts">${t.points}</span>
        <span style="color:var(--dim)">${t.won}–${t.lost}</span>
        <span style="margin-left:auto;color:var(--dim)">${ordinal(t.rank)}</span>
      </div>
    </a>`).join('');

  return layout({
    title: 'Teams', current: 'teams.html',
    body: `
<div class="title">
  <div class="inner">
    <div>
      <div class="eyebrow">${teams.length} teams · ${teams.length * 3} players</div>
      <h1>Teams</h1>
    </div>
  </div>
</div>
<div class="wrap"><div class="grid">${cards}
  </div>
</div>`
  });
}

/* ============================================================
   SCHEDULE
   ============================================================ */
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
      <span class="date">${esc(wk.label)}${wk.status === 'next' ? ' · ' + esc(league.teeTime) : ''}</span>
      <span class="flag ${wk.status === 'next' ? 'next">NEXT UP' : 'done">FINAL'}</span>
    </div>${matches}
  </section>`;
  }).join('');

  return layout({
    title: 'Schedule', current: 'schedule.html',
    body: `
<div class="title">
  <div class="inner">
    <div>
      <div class="eyebrow">${esc(league.season)} · ${league.weeks} weeks · ${league.bays} bays</div>
      <h1>Schedule</h1>
    </div>
  </div>
</div>
<div class="wrap">${weeks}
  <div style="height:50px"></div>
</div>`
  });
}

/* ============================================================
   PLAYLIST
   ============================================================ */
function buildPlaylist() {
  const tracks = standings.filter(t => t.song && t.song.id).map((t,i) => `
    <div class="match" style="--c:${t.accent};grid-template-columns:44px 46px 1fr auto"
         data-id="${esc(t.song.id)}">
      <div class="pld" style="text-align:center">${String(i+1).padStart(2,'0')}</div>
      <button class="play" style="background:${t.accent}" aria-label="Play">▶</button>
      <div>
        <b style="display:block;font-family:var(--display);font-weight:800;font-size:16px">${esc(t.song.title)}</b>
        <span style="font-size:13px;color:var(--dim)">${esc(t.song.artist)}</span>
      </div>
      <div style="text-align:right">
        <a href="teams/${t.slug}.html" style="color:${t.accent};text-decoration:none;font-weight:600;font-size:12px">${esc(t.name)}</a>
        <span style="display:block;font-family:var(--data);font-size:10px;color:var(--dim)">${ordinal(t.rank).toUpperCase()}</span>
      </div>
    </div>`).join('');

  return layout({
    title: 'Playlist', current: 'playlist.html',
    body: `
<div class="title">
  <div class="inner">
    <div>
      <div class="eyebrow">${teams.length} teams · ${teams.length} songs</div>
      <h1>The Playlist</h1>
    </div>
  </div>
</div>
<div class="wrap narrow">
  <div style="margin:26px 0 50px;border:1px solid var(--rule);background:var(--card)">${tracks}
  </div>
</div>
<div id="player" style="position:fixed;left:0;right:0;bottom:0;background:var(--green-deep);
     transform:translateY(100%);transition:transform .2s ease">
  <div style="max-width:820px;margin:0 auto;padding:10px 24px">
    <iframe id="frame" style="width:100%;height:80px;border:0;display:block"
            allow="autoplay" title="Player"></iframe>
  </div>
</div>
<script>
var frame=document.getElementById('frame'),player=document.getElementById('player'),cur=null;
document.querySelectorAll('[data-id]').forEach(function(t){
  t.querySelector('.play').addEventListener('click',function(){
    if(cur===t){frame.src='';player.style.transform='translateY(100%)';
      t.querySelector('.play').textContent='▶';cur=null;return;}
    if(cur) cur.querySelector('.play').textContent='▶';
    t.querySelector('.play').textContent='❚❚';
    frame.src='https://www.youtube.com/embed/'+t.dataset.id+'?autoplay=1';
    player.style.transform='translateY(0)';cur=t;
  });
});
</script>`
  });
}

/* ============================================================
   RECORDS
   ============================================================ */
function buildRecords() {
  const best   = [...teams].sort((a,b) => b.bestRound - a.bestRound)[0];
  const streak = standings[0];
  const worst  = standings[standings.length - 1];

  const card = (label, value, who, accent) => `
    <div style="background:var(--card);border:1px solid var(--rule);padding:20px;
         border-left:5px solid ${accent}">
      <div style="font-size:10px;letter-spacing:.14em;text-transform:uppercase;color:var(--dim)">${esc(label)}</div>
      <div style="font-family:var(--data);font-size:34px;font-weight:600;letter-spacing:-.04em;
           margin:8px 0 4px">${esc(value)}</div>
      <div style="font-size:13px">${esc(who)}</div>
    </div>`;

  return layout({
    title: 'Records', current: 'records.html',
    body: `
<div class="title">
  <div class="inner">
    <div>
      <div class="eyebrow">${esc(league.season)} · through week ${league.currentWeek}</div>
      <h1>Records</h1>
    </div>
  </div>
</div>
<div class="wrap">
  <div style="display:grid;grid-template-columns:repeat(auto-fill,minmax(240px,1fr));
       gap:14px;margin:28px 0 50px">
    ${card('Best round', best.bestRound + ' pts', best.name, best.accent)}
    ${card('Most points', streak.points, streak.name, streak.accent)}
    ${card('Best record', streak.won + '–' + streak.lost, streak.name, streak.accent)}
    ${card('Lowest handicap', Math.min(...teams.map(t => t.handicap)), teams.find(t => t.handicap === Math.min(...teams.map(x => x.handicap))).name, '#007041')}
    ${card('Still trying', worst.won + '–' + worst.lost, worst.name, worst.accent)}
  </div>
  <p style="color:var(--dim);font-size:13px;max-width:56ch;padding-bottom:50px">
    Closest to the pin, long putt and chip-in records appear here once side
    contests are being recorded each week.
  </p>
</div>`
  });
}

/* ============================================================
   TEAM PAGES — each with its own typeface and backdrop
   ============================================================ */
function buildTeamPage(t) {
  const face = league.typefaces[t.typeface] || league.typefaces.archivo;
  const mood = league.moodSentiment[t.moodSentiment] || '#B8EB7A';
  const opp  = nextOpp[t.slug] ? bySlug[nextOpp[t.slug].slug] : null;
  const rec  = opp ? (h2h[t.slug]?.[opp.slug]) : null;

  const head = `
<link href="https://fonts.googleapis.com/css2?family=${face.google}&display=swap" rel="stylesheet">
<style>
  :root{
    --accent:${t.accent};
    --pat:${rgba(t.accent, .15)};
    --mood:${mood};
    --team-display:${face.stack};
    --team-wdth:${face.wdth};
  }
</style>`;

  const roster = t.roster.map((p,i) => `
      <article class="player">
        <div class="idx">${String(i+1).padStart(2,'0')}${i === 0 ? ' · CAPTAIN' : ''}</div>
        <h3>${esc(p.name)}</h3>
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
      <div class="txt">
        <b>${esc(opp.name)}</b>
        ${rec ? `${rec.met} previous meeting${rec.met === 1 ? '' : 's'}` : 'First meeting of the season'}
      </div>
      ${rec ? `<div class="rec" style="margin-left:auto">${rec.w}–${rec.l}${rec.t ? '–' + rec.t : ''}</div>` : ''}
    </div>
  </section>` : '';

  const results = schedule.filter(w => w.status === 'final').map(wk => {
    const m = wk.matches.find(x => x.home === t.slug || x.away === t.slug);
    if (!m) return '';
    const home = m.home === t.slug;
    const other = bySlug[home ? m.away : m.home];
    const mine = home ? m.homeScore : m.awayScore;
    const theirs = home ? m.awayScore : m.homeScore;
    const tag = mine > theirs ? 'WON' : mine < theirs ? 'LOST' : 'TIED';
    return `
      <div class="match" style="grid-template-columns:74px 1fr auto">
        <div class="pld">${esc(wk.label)}</div>
        <div class="vs"><i style="background:${other.accent}"></i><b>${esc(other.name)}</b></div>
        <div class="mid"><span class="sc">${mine}–${theirs}</span>
          <span style="font-size:9px;display:block">${tag}</span></div>
      </div>`;
  }).join('');

  return layout({
    title: t.name, current: 'teams.html', depth: 1, head,
    body: `
<div class="hero">
  <div class="inner">
    <div class="crest-lg">${esc(t.crest)}</div>
    <div>
      <div class="eyebrow">${ordinal(t.rank)} of ${teams.length}</div>
      <h1>${esc(t.name)}</h1>
      <div class="meta">Bay ${t.bay} · ${esc(league.night)} ${esc(league.teeTime)} · Team handicap ${t.handicap}</div>
    </div>
    <div class="tally"><b>${t.points}</b><span>SEASON POINTS · ${t.won}–${t.lost}</span></div>
  </div>
</div>

<div class="status" id="status">
  <div class="inner">
    <div class="moodline">
      <span class="lbl">Mood</span><i class="dot2"></i><b>${esc(t.mood)}</b>
    </div>
    <div class="song">
      <span class="lbl">Walk-up</span>
      <button class="play" id="play" aria-label="Play walk-up song">▶</button>
      <div class="song-meta"><b>${esc(t.song.title)}</b><span>${esc(t.song.artist)}</span></div>
    </div>
  </div>
</div>

<div class="numbers">
  <div class="inner">
    <div><b>${(t.points / t.played).toFixed(1)}</b><span>Points per round</span></div>
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
    <section>
      <div class="head"><h2>Results</h2></div>
      ${results}
    </section>
    <div style="height:30px"></div>
  </div>
</div>

<script>
document.getElementById('play').addEventListener('click',function(){
  this.textContent = this.textContent === '▶' ? '❚❚' : '▶';
});
</script>`
  });
}

/* ============================================================
   RUN
   ============================================================ */
console.log('Building', league.name);
OUT('index.html',    buildLeaderboard());
OUT('teams.html',    buildTeams());
OUT('schedule.html', buildSchedule());
OUT('playlist.html', buildPlaylist());
OUT('records.html',  buildRecords());
teams.forEach(t => OUT(`teams/${t.slug}.html`, buildTeamPage(t)));
console.log(`Done. ${5 + teams.length} pages.`);
