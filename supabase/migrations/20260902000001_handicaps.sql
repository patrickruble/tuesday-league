-- ============================================================
--  PATCH 009 — handicaps, Katy style
--  Apply after patch-008.
--
--  The league uses standard plus-handicap notation:
--
--    "+7"  better than scratch — ADD 7 strokes to the gross
--    "3"   worse than scratch — SUBTRACT 3 strokes
--
--  Both bring a team back to level par. Dustin My Johnson
--  average 29.25 on a par 36, so +7 puts them at 36.
--  Shannannagans average 38.75, so 3 puts them at 36 too.
--
--  Stored here as a single signed number meaning "strokes
--  applied to the gross":
--      Dustin My Johnson   +7
--      Shannannagans       -3
--
--  Formula, matching Golf League Guru:
--      handicap = round(avg_par - avg_score over the last 4 rounds)
-- ============================================================

comment on column teams.handicap is
  'Strokes applied to the gross score. Positive is a plus handicap
   (better than scratch, strokes added). Negative means strokes
   come off. Recalculated from the last four confirmed rounds.';

-- ------------------------------------------------------------
--  How the strokes spread across the nine holes.
--
--  Stroke play never had to answer this — the handicap was one
--  number against a round total. Stableford scores hole by hole,
--  so seven strokes have to land somewhere specific, and which
--  holes they land on changes the points.
--
--  Configurable because it is a genuine league decision, not a
--  technical one.
--    'hardest'  strokes start at stroke index 1
--    'easiest'  strokes start at stroke index 9
-- ------------------------------------------------------------
alter table league_settings
  add column stroke_from text not null default 'hardest'
    check (stroke_from in ('hardest','easiest'));

comment on column league_settings.stroke_from is
  'Which end of the stroke index handicap strokes are allocated
   from. Ask the commissioner before trusting the default.';

-- ------------------------------------------------------------
--  Strokes applied to one hole. Returns a signed number:
--  positive adds to the gross, negative takes away.
-- ------------------------------------------------------------
create or replace function strokes_on_hole(
  p_stroke_index smallint,
  p_handicap     smallint,
  p_from         text default 'hardest'
) returns int
language sql stable as $$
  select case
    when p_handicap = 0 then 0
    else
      sign(p_handicap)::int * (
        (abs(p_handicap) / 9)
        + case
            when (case when p_from = 'easiest'
                       then 10 - p_stroke_index
                       else p_stroke_index end) <= (abs(p_handicap) % 9)
            then 1 else 0
          end
      )
  end;
$$;

-- ------------------------------------------------------------
--  Stableford. Net is gross PLUS the handicap strokes, because
--  a plus handicap makes the score worse on purpose.
-- ------------------------------------------------------------
create or replace function stableford_points(
  p_gross        smallint[],
  p_pars         smallint[],
  p_stroke_index smallint[],
  p_handicap     smallint
) returns smallint[]
language plpgsql stable as $$
declare
  cfg   jsonb;
  from_ text;
  keys  int[];
  lo    int;
  hi    int;
  pts   smallint[] := '{}';
  i     int;
  diff  int;
begin
  if p_gross is null then return null; end if;

  select scoring, stroke_from into cfg, from_
    from league_settings where id = 1;

  select array_agg(k::int order by k::int) into keys
    from jsonb_object_keys(cfg) k;
  lo := keys[1];
  hi := keys[array_length(keys,1)];

  for i in 1..9 loop
    diff := (p_gross[i] + strokes_on_hole(p_stroke_index[i], p_handicap, from_)) - p_pars[i];
    diff := greatest(lo, least(hi, diff));
    pts  := pts || (cfg ->> diff::text)::smallint;
  end loop;

  return pts;
end;
$$;

-- ------------------------------------------------------------
--  Recalculation, matching Golf League Guru: the last four
--  confirmed rounds, average score against average par.
-- ------------------------------------------------------------
create or replace function recalc_handicap(p_team uuid, p_rounds int default 4)
returns smallint
language plpgsql security definer as $$
declare
  avg_score numeric;
  avg_par   numeric;
  result    smallint;
begin
  select avg(g.total), avg(g.par)
    into avg_score, avg_par
  from (
    select
      (select sum(x) from unnest(r.gross) x) as total,
      (select sum(x) from unnest(c.pars)  x) as par
    from rounds r
    join matches m on m.id = r.match_id
    join courses c on c.id = m.course_id
    where r.team_id = p_team
      and r.status  = 'confirmed'
      and r.gross is not null
    order by m.played_on desc
    limit p_rounds
  ) g;

  if avg_score is null then return null; end if;

  result := round(avg_par - avg_score);
  update teams set handicap = result where id = p_team;
  return result;
end;
$$;

create or replace function recalc_all_handicaps(p_rounds int default 4)
returns table (team text, handicap smallint)
language plpgsql security definer as $$
declare
  t record;
  h smallint;
begin
  for t in select id, name from teams order by name loop
    h := recalc_handicap(t.id, p_rounds);
    if h is not null then
      team := t.name; handicap := h; return next;
    end if;
  end loop;
end;
$$;

-- ------------------------------------------------------------
--  A record of every change, so nobody has to take your word
--  for why their number moved.
-- ------------------------------------------------------------
create table handicap_history (
  id         bigserial primary key,
  team_id    uuid not null references teams on delete cascade,
  week       smallint,
  old_value  smallint,
  new_value  smallint,
  changed_at timestamptz not null default now()
);

create index on handicap_history (team_id, changed_at desc);

alter table handicap_history enable row level security;
create policy read_hcp_history  on handicap_history for select using (true);
create policy admin_hcp_history on handicap_history for all using (is_commissioner());

create or replace function log_handicap() returns trigger
language plpgsql as $$
begin
  if new.handicap is distinct from old.handicap then
    insert into handicap_history (team_id, old_value, new_value)
    values (new.id, old.handicap, new.handicap);
  end if;
  return new;
end;
$$;

create trigger teams_log_handicap
  after update on teams
  for each row execute function log_handicap();

-- ------------------------------------------------------------
--  Tees are recorded per player and they matter here — the
--  women's team plays red. Par is the same, so the handicap
--  formula already absorbs the difference: a team's number is
--  computed from its own scores on its own tees.
-- ------------------------------------------------------------
