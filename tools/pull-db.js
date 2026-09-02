#!/usr/bin/env node
/* ============================================================
   Pull live data from Supabase into data/teams.json

     node tools/pull-db.js

   Or, more usually, as part of a build:

     node build.js --from-db

   Reads the project URL and publishable key straight out of
   assets/db.js so there's only one place they live.

   Everything here is public data behind row level security —
   teams, profiles and roster spots are all readable without
   signing in, which is what makes the public site work.
   ============================================================ */

const fs   = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');

/* ---------- config, borrowed from the client module ---------- */
function readConfig() {
  const src = fs.readFileSync(path.join(ROOT,'assets','db.js'), 'utf8');
  const url = src.match(/SUPABASE_URL\s*=\s*'([^']+)'/);
  const key = src.match(/SUPABASE_KEY\s*=\s*'([^']+)'/);
  if (!url || !key) throw new Error('Could not find the Supabase settings in assets/db.js');
  return { url: url[1], key: key[1] };
}

const { url: URL_, key: KEY } = readConfig();

async function q(table, select, order) {
  const params = new URLSearchParams({ select });
  if (order) params.set('order', order);
  const res = await fetch(`${URL_}/rest/v1/${table}?${params}`, {
    headers: { apikey: KEY, Authorization: `Bearer ${KEY}` }
  });
  if (!res.ok) throw new Error(`${table}: ${res.status} ${await res.text()}`);
  return res.json();
}

const publicUrl = (bucket, p) =>
  p ? `${URL_}/storage/v1/object/public/${bucket}/${p}` : null;

/* ---------- keep anything the database doesn't hold ---------- */
const load = p => { try { return JSON.parse(fs.readFileSync(p,'utf8')); } catch { return null; } };

async function pull() {
  console.log('Pulling from', URL_);

  const [teams, profiles, spots, settings, matches, weekCfg, contests, bagRows] =
    await Promise.all([
    q('teams', '*', 'name.asc'),
    q('profiles', 'id,full_name,hcp_index,quote,avatar_url,team_id'),
    q('roster_spots', 'team_id,spot,full_name,hcp_index,claimed_by', 'spot.asc'),
    q('league_settings', '*').catch(() => []),
    q('matches', 'id,week,played_on,tee_time,bay,course_id,home_team,away_team', 'week.asc')
      .catch(() => []),
    q('week_settings', '*').catch(() => []),
    q('contest_tallies', '*').catch(() => []),
    q('bags', '*').catch(() => [])
  ]);

  /* side contest wins, per player, so a player page can show
     something real rather than a row of dashes */
  const wins = {};
  for (const c of contests) {
    (wins[c.profile_id] ??= {})[c.kind] = c.wins;
  }

  /* what's in each bag, already in club order from the view */
  const bags = {};
  for (const b of bagRows) {
    (bags[b.profile_id] ??= []).push({
      slot: b.slot, brand: b.brand, model: b.model, detail: b.detail
    });
  }

  console.log(`  ${teams.length} teams, ${profiles.length} profiles, ${spots.length} roster spots`);

  const dataPath = path.join(ROOT,'data','teams.json');
  const existing = load(dataPath) || [];
  const prior = Object.fromEntries(existing.map(t => [t.slug, t]));

  const out = teams.map(t => {
    const old = prior[t.slug] || {};

    /* Roster: prefer signed-up profiles, fall back to the roster
       spot so a team still shows names before anyone signs up. */
    const signed = profiles.filter(p => p.team_id === t.id);
    const mine   = spots.filter(s => s.team_id === t.id);

    const roster = mine.length
      ? mine.map(s => {
          const p = s.claimed_by ? signed.find(x => x.id === s.claimed_by) : null;
          return {
            name:  p ? p.full_name : s.full_name,
            hcp:   (p && p.hcp_index != null ? p.hcp_index : s.hcp_index) ?? 0,
            quote: p ? (p.quote || '') : '',
            photo: p ? publicUrl('avatars', p.avatar_url) : null,
            wins:  p ? (wins[p.id] || null) : null,
            bag:   p ? (bags[p.id] || null) : null
          };
        })
      : signed.map(p => ({
          name: p.full_name,
          hcp: p.hcp_index ?? 0,
          quote: p.quote || '',
          photo: publicUrl('avatars', p.avatar_url),
          wins: wins[p.id] || null,
          bag: bags[p.id] || null
        }));

    return {
      slug: t.slug,
      name: t.name,
      crest: t.crest,
      crestUrl: publicUrl('crests', t.crest_url),
      accent: t.accent,
      typeface: t.typeface || 'archivo',
      backdrop: t.backdrop || 'none',
      backdropColor: t.backdrop_color || null,
      backdropImage: publicUrl('backdrops', t.backdrop_image),
      backdropMode: t.backdrop_mode || 'tile',
      handicap: t.handicap ?? 0,
      bay: old.bay ?? null,

      mood: t.mood || 'content',
      moodSentiment: old.moodSentiment || 'good',
      song: {
        title: t.song_title || '',
        artist: t.song_artist || '',
        provider: t.song_provider || 'youtube',
        id: t.song_id || null,
        art: t.song_art || null
      },
      bio: t.bio || '',
      roster,

      /* season numbers stay wherever they were — they come from
         rounds, not from the teams table */
      points: old.points ?? 0,
      played: old.played ?? 0,
      bestRound: old.bestRound ?? null,
      lastSeason: old.lastSeason ?? null
    };
  });

  /* Spotify covers need a lookup. The editor does it when a
     link is pasted, but songs saved before that have none — so
     fill in anything missing here, once, at build time. */
  const needArt = out.filter(t =>
    t.song.id && t.song.provider === 'spotify' && !t.song.art);

  if (needArt.length) {
    console.log(`  looking up ${needArt.length} Spotify cover${needArt.length === 1 ? '' : 's'}`);
    await Promise.all(needArt.map(async t => {
      try {
        const url = `https://open.spotify.com/track/${t.song.id}`;
        const r = await fetch('https://open.spotify.com/oembed?url=' + encodeURIComponent(url), {
          headers: {
            /* a bare Node request sometimes gets refused */
            'User-Agent': 'Mozilla/5.0 (compatible; KatyGolfLeague/1.0)',
            'Accept': 'application/json'
          }
        });
        if (!r.ok) { console.log(`    ${t.name}: Spotify said ${r.status}`); return; }
        const j = await r.json();
        if (j.thumbnail_url) t.song.art = j.thumbnail_url;
      } catch { /* the song works without a picture */ }
    }));

    const still = needArt.filter(t => !t.song.art).length;
    if (still) {
      console.log(`    ${still} still without a cover — re-pasting the link in the`);
      console.log('    editor fetches it from the browser, which is more reliable.');
    }
  }

  /* moods table gives us the sentiment for each word */
  try {
    const moods = await q('moods', 'word,sentiment');
    const bySentiment = Object.fromEntries(moods.map(m => [m.word, m.sentiment]));
    out.forEach(t => { if (bySentiment[t.mood]) t.moodSentiment = bySentiment[t.mood]; });
  } catch { /* moods table is optional */ }

  fs.writeFileSync(dataPath, JSON.stringify(out, null, 2) + '\n');
  console.log(`  wrote data/teams.json`);

  const withSongs = out.filter(t => t.song.id).length;
  const withPhotos = out.reduce((a,t) => a + t.roster.filter(p => p.photo).length, 0);
  const customised = out.filter(t => t.bio || t.backdropImage || t.crestUrl).length;
  console.log(`  ${withSongs} songs · ${withPhotos} player photos · ${customised} teams customised`);

  if (settings.length) {
    fs.writeFileSync(path.join(ROOT,'data','settings.json'),
      JSON.stringify(settings[0], null, 2) + '\n');
    console.log('  wrote data/settings.json');
  }

  /* The schedule comes through the same anon key the public
     site uses, so a week whose draw hasn't gone public yet
     simply isn't in the result — nothing here has to know the
     rule, it just can't see them. */
  if (matches.length) {
    const courses = await q('courses', 'id,name,nine').catch(() => []);
    const byId = Object.fromEntries(courses.map(c => [c.id, c]));
    const cfg  = Object.fromEntries(weekCfg.map(w => [w.week, w]));
    const slugOf = Object.fromEntries(teams.map(t => [t.id, t.slug]));

    const weeks = {};
    for (const m of matches) {
      const c = byId[m.course_id] || {};
      const w = (weeks[m.week] ??= {
        week: m.week,
        date: m.played_on,
        label: new Date(m.played_on + 'T12:00:00')
          .toLocaleDateString('en-GB', { weekday:'short', day:'2-digit', month:'short' })
          .toUpperCase(),
        course: c.name || '',
        nine: c.nine ? c.nine.charAt(0).toUpperCase() + c.nine.slice(1) + ' 9' : '',
        status: 'final',
        ctpHole: cfg[m.week]?.ctp_hole ?? null,
        longPuttHole: cfg[m.week]?.long_putt_hole ?? null,
        conditions: (() => {
          const c = cfg[m.week] || {};
          const bits = [];
          if (c.wind === 'none')       bits.push('no wind');
          else if (c.wind)             bits.push(c.wind + ' wind');
          else if (c.wind_speed)       bits.push(c.wind_speed + ' mph wind');
          if (c.green_speed)           bits.push(c.green_speed + ' greens');
          if (c.gimme_ft === 0)        bits.push('putt everything out');
          else if (c.gimme_ft != null) bits.push(c.gimme_ft + 'ft concedes');
          if (c.conditions)            bits.push(c.conditions);
          return bits.join(' \u00b7 ') || null;
        })(),
        bays: []
      });
      w.bays.push({
        bay: m.bay,
        teams: [m.home_team, m.away_team].filter(Boolean).map(id => slugOf[id]).filter(Boolean)
      });
    }

    const today = new Date().toISOString().slice(0,10);
    const list = Object.values(weeks).sort((a,b) => b.week - a.week);
    const upcoming = list.filter(w => w.date >= today).sort((a,b) => a.week - b.week)[0];
    if (upcoming) upcoming.status = 'next';
    list.forEach(w => { if (w.date > today && w !== upcoming) w.status = 'later'; });
    list.forEach(w => w.bays.sort((a,b) => (a.bay||0) - (b.bay||0)));

    fs.writeFileSync(path.join(ROOT,'data','schedule.json'),
      JSON.stringify(list, null, 2) + '\n');
    console.log(`  wrote data/schedule.json — ${list.length} week${list.length===1?'':'s'} visible`);
  } else {
    console.log('  no visible weeks — the draw may not be public yet');
  }

  return out;
}

module.exports = { pull };

if (require.main === module) {
  pull().catch(e => { console.error('\n' + e.message); process.exit(1); });
}
