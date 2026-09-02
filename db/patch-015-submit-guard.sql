-- ============================================================
--  PATCH 015 — submission guard looks in the right place
--  Apply after patch-014.
--
--  The guard from schema.sql checks rounds.photo_path, which
--  patch-002 replaced with the append-only round_photos table.
--  Photos have been landing correctly and the trigger has been
--  looking at a column nothing writes to.
-- ============================================================

create or replace function stamp_submission()
returns trigger
language plpgsql
security definer
as $$
begin
  if new.status = 'submitted' and old.status is distinct from 'submitted' then

    if not exists (
      select 1 from round_photos
       where round_id = new.id and not superseded
    ) then
      raise exception 'A photo of the screen is needed before submitting';
    end if;

    if new.gross is null or array_length(new.gross,1) <> 9
       or exists (select 1 from unnest(new.gross) g where g is null) then
      raise exception 'All nine holes need a score';
    end if;

    new.submitted_by := auth.uid();
    new.submitted_at := now();
  end if;

  return new;
end;
$$;


-- round_scores selected the old column, so it has to be rebuilt
-- before the drop can take. Recreated here without it.
drop view if exists round_scores cascade;
create view round_scores as
select
  r.id,
  r.match_id,
  r.team_id,
  r.status,
  r.tees,
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

-- Now the column can go.
alter table rounds drop column if exists photo_path;

-- The three views that sit on round_scores, rebuilt after the
-- cascade took them with it.
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
