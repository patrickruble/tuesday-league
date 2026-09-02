-- ============================================================
--  PATCH 021 — album art for the walk-up song
--  Apply after patch-020.
--
--  YouTube's thumbnail can be worked out from the video id, so
--  it needs nothing stored. Spotify's needs a lookup, so it
--  gets fetched once when the team saves the song rather than
--  on every page load.
-- ============================================================

alter table teams add column song_art text;

comment on column teams.song_art is
  'Cover image for the walk-up song. Derived from the video id
   for YouTube, fetched once from Spotify''s oEmbed endpoint
   otherwise. Null just means no art.';

drop view if exists league_playlist;
create view league_playlist as
select
  t.slug, t.name, t.accent, t.crest,
  t.song_title, t.song_artist, t.song_provider, t.song_id, t.song_art
from teams t
where t.song_id is not null
order by t.name;
