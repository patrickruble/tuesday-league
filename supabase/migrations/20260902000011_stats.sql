-- ============================================================
--  PATCH 019 — hole photos and the week's numbers
--  Apply after patch-018.
-- ============================================================

-- ------------------------------------------------------------
--  1. HOLE PHOTOS
--     Photographs of Pebble and Oakmont belong to whoever took
--     them. A photo of the simulator screen, taken in the bay,
--     belongs to the league — and it's the hole as you actually
--     played it, which is more use anyway.
--
--     First good photo of a hole becomes the one the card
--     shows; the commissioner can pick a different one.
-- ------------------------------------------------------------
create table hole_photos (
  id           uuid primary key default gen_random_uuid(),
  course_id    uuid not null references courses on delete cascade,
  hole         smallint not null check (hole between 1 and 9),
  storage_path text not null,
  taken_by     uuid references profiles on delete set null,
  taken_at     timestamptz not null default now(),
  featured     boolean not null default false,
  caption      text
);

create index on hole_photos (course_id, hole, featured desc, taken_at desc);

alter table hole_photos enable row level security;

create policy read_hole_photos on hole_photos for select using (true);

create policy add_hole_photo on hole_photos for insert to authenticated
  with check (taken_by = auth.uid());

create policy own_hole_photo on hole_photos for update
  using (taken_by = auth.uid()) with check (taken_by = auth.uid());

create policy admin_hole_photos on hole_photos for all using (is_commissioner());

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('holes','holes', true, 3145728,
        array['image/png','image/jpeg','image/webp'])
on conflict (id) do nothing;

create policy "read hole photos"
  on storage.objects for select using (bucket_id = 'holes');

create policy "upload hole photo"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'holes');

-- One photo per hole, the featured one if somebody picked it.
create or replace view hole_photo_current as
select distinct on (course_id, hole)
  course_id, hole, storage_path, caption, taken_at,
  taken_by
from hole_photos
order by course_id, hole, featured desc, taken_at desc;

-- ------------------------------------------------------------
--  2. HOW THE FIELD PLAYED EACH HOLE
--
--     Only counts confirmed cards, so a week reads as final
--     rather than shifting while sign-offs trickle in.
-- ------------------------------------------------------------
create or replace view hole_stats as
select
  m.week,
  m.course_id,
  c.name  as course_name,
  c.nine,
  h.hole,
  c.pars[h.hole]         as par,
  c.stroke_index[h.hole] as stroke_index,
  count(*)                                      as cards,
  round(avg(r.gross[h.hole]), 2)                as avg_gross,
  round(avg(r.gross[h.hole]) - c.pars[h.hole], 2) as avg_to_par,
  min(r.gross[h.hole])                          as best,
  max(r.gross[h.hole])                          as worst,
  count(*) filter (where r.gross[h.hole] <  c.pars[h.hole] - 1) as eagles,
  count(*) filter (where r.gross[h.hole] =  c.pars[h.hole] - 1) as birdies,
  count(*) filter (where r.gross[h.hole] =  c.pars[h.hole])     as pars,
  count(*) filter (where r.gross[h.hole] =  c.pars[h.hole] + 1) as bogeys,
  count(*) filter (where r.gross[h.hole] >  c.pars[h.hole] + 1) as worse
from rounds r
join matches m on m.id = r.match_id
join courses c on c.id = m.course_id
cross join generate_series(1,9) as h(hole)
where r.status = 'confirmed' and r.gross is not null
group by m.week, m.course_id, c.name, c.nine, h.hole,
         c.pars[h.hole], c.stroke_index[h.hole];

-- ------------------------------------------------------------
--  3. THE WEEK IN ONE ROW
-- ------------------------------------------------------------
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
  round(avg((select sum(g) from unnest(rs.gross) g)), 1) as avg_gross
from round_scores rs
where rs.status = 'confirmed'
group by rs.week, rs.played_on, rs.course_name, rs.nine
order by rs.week desc;

-- Whether every card is in yet, so a page can say "final" or
-- "still coming in" honestly.
create or replace view week_progress as
select
  m.week,
  count(*) filter (where r.status = 'confirmed') as confirmed,
  count(*) filter (where r.status = 'submitted') as waiting,
  count(*) filter (where r.status = 'disputed')  as disputed,
  count(distinct t.id)                           as teams_expected
from matches m
cross join teams t
left join rounds r on r.match_id = m.id and r.team_id = t.id
group by m.week;

-- ------------------------------------------------------------
--  4. BIRDIE RUNS
--     Consecutive holes under par on one card. The thing people
--     actually talk about afterwards.
-- ------------------------------------------------------------
create or replace function birdie_runs(p_round uuid)
returns table (start_hole int, length int)
language plpgsql stable as $$
declare
  r      rounds%rowtype;
  pars   smallint[];
  i      int;
  run    int := 0;
  begins int := 0;
begin
  select * into r from rounds where id = p_round;
  if r.gross is null then return; end if;

  select c.pars into pars
    from matches m join courses c on c.id = m.course_id
   where m.id = r.match_id;

  for i in 1..9 loop
    if r.gross[i] < pars[i] then
      if run = 0 then begins := i; end if;
      run := run + 1;
    else
      if run >= 2 then start_hole := begins; length := run; return next; end if;
      run := 0;
    end if;
  end loop;

  if run >= 2 then start_hole := begins; length := run; return next; end if;
end;
$$;
