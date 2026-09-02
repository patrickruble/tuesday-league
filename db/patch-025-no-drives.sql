-- ============================================================
--  PATCH 025 — drives used isn't tracked
--  Apply after patch-024.
--
--  It was a reasonable guess for a scramble league, but this
--  one doesn't count them, so it was a field nobody would fill
--  in sitting on the entry screen.
-- ============================================================

alter table rounds          drop column if exists drives_used;
alter table league_settings drop column if exists min_drives_per_player;

-- player_metrics counted them too
drop view if exists player_metrics;
create view player_metrics as
select
  p.id as profile_id,
  count(*) filter (where sc.kind = 'ctp')       as ctp_wins,
  count(*) filter (where sc.kind = 'long_putt') as long_putt_wins,
  count(*) filter (where sc.kind = 'chip_in')   as chip_in_wins,
  count(*) filter (where sc.kind = 'ace')       as aces
from profiles p
left join side_contests sc on sc.winner_id = p.id
group by p.id;
