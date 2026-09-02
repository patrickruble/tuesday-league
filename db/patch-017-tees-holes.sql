-- ============================================================
--  PATCH 017 — tees, and hole detail on courses
--  Apply after patch-016.
--
--  In practice the men play black or blue and the women play
--  red. White stays legal because somebody will want it, but
--  the picker only offers the three.
-- ============================================================

alter table profiles drop constraint if exists profiles_default_tee_check;
alter table profiles add constraint profiles_default_tee_check
  check (default_tee is null or default_tee in ('black','blue','white','red'));

alter table course_tees drop constraint if exists course_tees_color_check;
alter table course_tees add constraint course_tees_color_check
  check (color in ('black','blue','white','red'));

comment on column profiles.default_tee is
  'Which tee this player normally uses. Black or blue for most
   of the league, red for the women. Recorded per round as well,
   so history stays right if someone switches.';

-- ------------------------------------------------------------
--  Hole detail
--
--  Par and stroke index were enough for scoring. Yardages and a
--  shape let the card actually draw the hole, which is the
--  point of a scorecard you'd want to look at.
--
--  Held as jsonb rather than columns because it's descriptive,
--  varies by hole, and nothing queries inside it.
-- ------------------------------------------------------------
alter table courses
  add column holes jsonb;

comment on column courses.holes is
  'Optional per-hole detail for drawing the card: yardages by
   tee, bend (-1 hard left to 1 hard right), fairway width, and
   a list of hazards. Shaped like data/courses.json. The card
   falls back to par and stroke index when this is empty.';

-- Yardage totals, handy on a card header.
create or replace function course_yardage(p_course uuid, p_tee text default 'blue')
returns int
language sql stable as $$
  select sum(((h -> 'yards') ->> p_tee)::int)
    from courses c, jsonb_array_elements(c.holes) h
   where c.id = p_course;
$$;

