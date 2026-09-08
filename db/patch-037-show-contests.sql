-- ============================================================
--  PATCH 037 — showing the contests
--  Apply after patch-035. Independent of 036.
--
--  The board works. Everything around it was missing: a night's
--  results appeared nowhere except a line at the bottom of the
--  records page.
-- ============================================================

-- ------------------------------------------------------------
--  A week's three results, settled, with what each was worth.
--  One row per contest whether or not anybody won it — a
--  chip-in nobody made still needs to say so, because that's
--  the money that rolls over.
-- ------------------------------------------------------------
create or replace view week_contests as
with kinds as (
  select unnest(array['ctp','long_putt','chip_in']) as kind
),
weeks as (
  select distinct week from matches
),
best as (
  select distinct on (m.week, sc.kind)
    m.week,
    sc.kind,
    sc.hole,
    sc.value,
    sc.unit,
    sc.confirmed,
    m.bay,
    p.id    as profile_id,
    p.full_name,
    p.avatar_url,
    t.name  as team_name,
    t.slug  as team_slug,
    t.accent
  from side_contests sc
  join matches m on m.id = sc.match_id
  left join profiles p on p.id = sc.winner_id
  left join teams    t on t.id = coalesce(sc.team_id, p.team_id)
  order by
    m.week, sc.kind,
    case when sc.kind = 'ctp'       then sc.value end asc  nulls last,
    case when sc.kind = 'long_putt' then sc.value end desc nulls last,
    sc.recorded_at asc
)
select
  w.week,
  k.kind,
  b.hole,
  b.value,
  b.unit,
  b.confirmed,
  b.bay,
  b.profile_id,
  b.full_name,
  b.avatar_url,
  b.team_name,
  b.team_slug,
  b.accent,
  (b.profile_id is not null) as won,
  cm.total as pot,
  cm.carried
from weeks w
cross join kinds k
left join best b on b.week = w.week and b.kind = k.kind
left join contest_money cm on cm.week = w.week and cm.kind = k.kind
order by w.week desc,
  case k.kind when 'ctp' then 1 when 'long_putt' then 2 else 3 end;

-- ------------------------------------------------------------
--  What a player has won all season, for their own page.
-- ------------------------------------------------------------
create or replace view player_contests as
select
  wc.profile_id,
  wc.kind,
  count(*)                                              as wins,
  min(case when wc.kind = 'ctp' then wc.value end)      as closest,
  max(case when wc.kind = 'long_putt' then wc.value end) as longest,
  sum(wc.pot)                                           as won_total
from week_contests wc
where wc.profile_id is not null
group by wc.profile_id, wc.kind;

-- ------------------------------------------------------------
--  The season's best single efforts, for the records page.
-- ------------------------------------------------------------
create or replace view contest_records as
select 'ctp' as kind, sc.value, sc.unit, m.week, sc.hole,
       p.full_name, t.name as team_name, t.slug as team_slug, t.accent
  from side_contests sc
  join matches m on m.id = sc.match_id
  join profiles p on p.id = sc.winner_id
  left join teams t on t.id = coalesce(sc.team_id, p.team_id)
 where sc.kind = 'ctp' and sc.value is not null
 order by sc.value asc
 limit 1;
