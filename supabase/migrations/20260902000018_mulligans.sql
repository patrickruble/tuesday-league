-- ============================================================
--  PATCH 026 — mulligans
--  Apply after patch-025.
--
--  One number for the team, not per player — a scramble plays
--  one ball, so a mulligan belongs to the round.
-- ============================================================

alter table rounds
  add column mulligans smallint not null default 0
    check (mulligans between 0 and 20);

comment on column rounds.mulligans is
  'How many the team used. Recorded rather than enforced — the
   commissioner decides what to do about it.';

-- How many the league gives out, if it gives out any. Null
-- means the question is asked but no limit is stated.
alter table league_settings
  add column mulligans_allowed smallint;

comment on column league_settings.mulligans_allowed is
  'Null means unlimited or unstated. Zero means none are meant
   to be used, and the entry screen says so.';

-- Surface it wherever a round is read.
drop view if exists round_scores cascade;
create view round_scores as
select
  r.id,
  r.match_id,
  r.team_id,
  r.status,
  r.tees,
  r.mulligans,
  m.week,
  m.played_on,
  m.bay,
  c.name as course_name,
  c.nine,
  t.handicap,
  r.gross,
  stableford_points(r.gross, c.pars, c.stroke_index, t.handicap) as points,
  (select sum(p) from unnest(
      stableford_points(r.gross, c.pars, c.stroke_index, t.handicap)
   ) p) as total_points
from rounds r
join matches m on m.id = r.match_id
join courses c on c.id = m.course_id
join teams   t on t.id = r.team_id;

-- the views that sat on it
create or replace view standings as
with scored as (
  select rs.team_id, rs.week, rs.total_points
  from round_scores rs
  where rs.status = 'confirmed'
)
select
  t.id as team_id, t.slug, t.name, t.crest, t.accent, t.mood,
  count(s.week)                    as played,
  coalesce(sum(s.total_points), 0) as points,
  round(avg(s.total_points), 1)    as ppr,
  max(s.total_points)              as best_round
from teams t
left join scored s on s.team_id = t.id
group by t.id, t.slug, t.name, t.crest, t.accent, t.mood
order by points desc, best_round desc;

create or replace view eagle_counts as
select
  rs.team_id, rs.week, rs.played_on,
  count(*) filter (where p.pt = 3) as eagles,
  count(*) filter (where p.pt = 2) as birdies,
  count(*) filter (where p.pt = 0) as blanks
from round_scores rs,
     lateral unnest(rs.points) as p(pt)
where rs.status = 'confirmed'
group by rs.team_id, rs.week, rs.played_on;

create or replace view team_rounds as
select
  rs.team_id,
  rs.week,
  rs.played_on,
  rs.total_points,
  (select sum(g) from unnest(rs.gross) g) as gross,
  (select sum(p) from unnest(c.pars) p)   as par,
  row_number() over (partition by rs.team_id order by rs.played_on) as nth,
  count(*)     over (partition by rs.team_id)                       as of_n
from round_scores rs
join matches m on m.id = rs.match_id
join courses c on c.id = m.course_id
where rs.status = 'confirmed';

create or replace view season_tallies as
select
  rs.team_id,
  t.name, t.slug, t.accent, t.crest,
  count(distinct rs.week)          as rounds,
  sum(rs.total_points)             as points,
  round(avg(rs.total_points), 1)   as ppr,
  max(rs.total_points)             as best_round,
  sum(rs.mulligans)                as mulligans,
  count(*) filter (where p.pt = 3) as eagles,
  count(*) filter (where p.pt = 2) as birdies,
  count(*) filter (where p.pt = 1) as pars,
  count(*) filter (where p.pt = 0) as blanks
from round_scores rs
join teams t on t.id = rs.team_id,
     lateral unnest(rs.points) as p(pt)
where rs.status = 'confirmed'
group by rs.team_id, t.name, t.slug, t.accent, t.crest;

create or replace view week_summary as
select
  rs.week,
  rs.played_on,
  rs.course_name,
  rs.nine,
  count(*)                        as cards_in,
  round(avg(rs.total_points), 1)  as avg_points,
  max(rs.total_points)            as best_points,
  min(rs.total_points)            as worst_points,
  sum(rs.mulligans)               as mulligans,
  round(avg((select sum(g) from unnest(rs.gross) g)), 1) as avg_gross
from round_scores rs
where rs.status = 'confirmed'
group by rs.week, rs.played_on, rs.course_name, rs.nine
order by rs.week desc;
