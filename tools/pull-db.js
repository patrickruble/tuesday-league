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

  const [teams, profiles, spots, settings] = await Promise.all([
    q('teams', '*', 'name.asc'),
    q('profiles', 'id,full_name,hcp_index,quote,avatar_url,team_id'),
    q('roster_spots', 'team_id,spot,full_name,hcp_index,claimed_by', 'spot.asc'),
    q('league_settings', '*').catch(() => [])
  ]);

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
            photo: p ? publicUrl('avatars', p.avatar_url) : null
          };
        })
      : signed.map(p => ({
          name: p.full_name,
          hcp: p.hcp_index ?? 0,
          quote: p.quote || '',
          photo: publicUrl('avatars', p.avatar_url)
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

  return out;
}

module.exports = { pull };

if (require.main === module) {
  pull().catch(e => { console.error('\n' + e.message); process.exit(1); });
}
