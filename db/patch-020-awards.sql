-- ============================================================
--  PATCH 020 — drop hole photos, add the awards
--  Apply after patch-019.
-- ============================================================

-- ------------------------------------------------------------
--  Hole photos aren't wanted. Taking them out rather than
--  leaving an unused table sitting there.
-- ------------------------------------------------------------
drop view  if exists hole_photo_current;
drop table if exists hole_photos;
delete from storage.objects where bucket_id = 'holes';
delete from storage.buckets where id = 'holes';
drop policy if exists "read hole photos"   on storage.objects;
drop policy if exists "upload hole photo"  on storage.objects;

-- ------------------------------------------------------------
--  Every confirmed round a team has played, numbered, so the
--  awards can talk about early and late in the season.
-- ------------------------------------------------------------
create or replace view team_rounds as
select
  rs.team_id,
  rs.week,
  rs.played_on,
  rs.total_points,
  (select sum(g) from unnest(rs.gross) g) as gross,
  (select sum(p) from unnest(c.pars) p)   as par,
  row_number() over (partition by rs.team_id order by rs.played_on)      as nth,
  count(*)     over (partition by rs.team_id)                            as of_n
from round_scores rs
join matches m on m.id = rs.match_id
join courses c on c.id = m.course_id
where rs.status = 'confirmed';

-- ------------------------------------------------------------
--  MOST IMPROVED
--
--  First half of a team's rounds against their second half,
--  measured in points. Needs at least four rounds before it
--  means anything, so teams below that are left out rather than
--  shown with a wild number.
-- ------------------------------------------------------------
create or replace view most_improved as
with halves as (
  select
    team_id,
    of_n,
    avg(total_points) filter (where nth <= of_n / 2.0) as early,
    avg(total_points) filter (where nth >  of_n / 2.0) as late
  from team_rounds
  group by team_id, of_n
)
select
  h.team_id,
  t.name, t.slug, t.accent, t.crest,
  round(h.early, 1)          as early_avg,
  round(h.late, 1)           as late_avg,
  round(h.late - h.early, 1) as gain,
  h.of_n                     as rounds
from halves h
join teams t on t.id = h.team_id
where h.of_n >= 4 and h.early is not null and h.late is not null
order by gain desc;

-- ------------------------------------------------------------
--  MOST CONSISTENT — smallest spread between best and worst
-- ------------------------------------------------------------
create or replace view most_consistent as
select
  tr.team_id,
  t.name, t.slug, t.accent, t.crest,
  count(*)                        as rounds,
  round(avg(tr.total_points), 1)  as avg_points,
  max(tr.total_points)            as best,
  min(tr.total_points)            as worst,
  max(tr.total_points) - min(tr.total_points) as spread,
  round(stddev_pop(tr.total_points), 2)       as sd
from team_rounds tr
join teams t on t.id = tr.team_id
group by tr.team_id, t.name, t.slug, t.accent, t.crest
having count(*) >= 4
order by sd asc;

-- ------------------------------------------------------------
--  SEASON TOTALS — birdies, eagles, blanks per team
-- ------------------------------------------------------------
create or replace view season_tallies as
select
  rs.team_id,
  t.name, t.slug, t.accent, t.crest,
  count(distinct rs.week)                    as rounds,
  sum(rs.total_points)                       as points,
  round(avg(rs.total_points), 1)             as ppr,
  max(rs.total_points)                       as best_round,
  count(*) filter (where p.pt = 3)           as eagles,
  count(*) filter (where p.pt = 2)           as birdies,
  count(*) filter (where p.pt = 1)           as pars,
  count(*) filter (where p.pt = 0)           as blanks
from round_scores rs
join teams t on t.id = rs.team_id,
     lateral unnest(rs.points) as p(pt)
where rs.status = 'confirmed'
group by rs.team_id, t.name, t.slug, t.accent, t.crest;

-- ------------------------------------------------------------
--  SIDE CONTEST LEADERS — already a view, restated here so
--  everything the awards page needs is in one place.
-- ------------------------------------------------------------
create or replace view contest_tallies as
select
  sc.kind,
  p.id   as profile_id,
  p.full_name,
  t.name as team_name,
  t.slug as team_slug,
  t.accent,
  count(*) as wins
from side_contests sc
join profiles p on p.id = sc.winner_id
left join teams t on t.id = coalesce(sc.team_id, p.team_id)
group by sc.kind, p.id, p.full_name, t.name, t.slug, t.accent
order by sc.kind, wins desc;
