-- ============================================================
--  PATCH 001 — tee boxes, and scoring rules as DATA not code
--  Apply after schema.sql. If you haven't run schema.sql yet,
--  run it first, then this.
-- ============================================================

-- ------------------------------------------------------------
--  1. Fix the naming collision.
--     'tee' meant front/back nine. That's the NINE. The tee box
--     is a separate thing (red/white/blue/black).
-- ------------------------------------------------------------
alter table courses rename column tee to nine;
alter table courses rename constraint courses_tee_check to courses_nine_check;

-- ------------------------------------------------------------
--  2. TEE BOXES
--     Yardage, rating and slope differ per tee. You need these
--     the moment handicaps account for which tee someone played.
--     Add rows only for the tees your league actually uses.
-- ------------------------------------------------------------
create table course_tees (
  id         uuid primary key default gen_random_uuid(),
  course_id  uuid not null references courses on delete cascade,
  color      text not null check (color in ('red','white','blue','black','gold','green')),
  yardage    int,
  rating     numeric(4,1),   -- course rating for these tees
  slope      smallint,       -- 55–155
  unique (course_id, color)
);

alter table course_tees enable row level security;
create policy read_course_tees  on course_tees for select using (true);
create policy admin_course_tees on course_tees for all using (is_commissioner());

-- ------------------------------------------------------------
--  3. WHO PLAYED WHICH TEE
--     In a scramble every player tees off from their own box,
--     so this is per player, not per team. Default lives on the
--     profile; the round records what was actually played, so
--     history stays accurate if someone changes tees later.
-- ------------------------------------------------------------
alter table profiles add column default_tee text
  check (default_tee in ('red','white','blue','black','gold','green'));

alter table rounds add column tees jsonb;
comment on column rounds.tees is
  'Tee played by each player this round: { "<profile_id>": "blue", ... }';

-- ------------------------------------------------------------
--  4. LEAGUE SETTINGS
--     One row. Everything Chris might change lives here so a
--     rule change is an UPDATE, not a redeploy.
--
--     scoring: net score relative to par -> points.
--     Keys outside the range are clamped to the nearest key, so
--     '{"-2":3,"-1":2,"0":1,"1":0}' gives an albatross 3 and a
--     quadruple 0 without listing every case.
-- ------------------------------------------------------------
create table league_settings (
  id                    int primary key default 1 check (id = 1),
  season                text not null default 'Season 3',
  holes                 smallint not null default 9,

  scoring               jsonb not null default '{"-2":3,"-1":2,"0":1,"1":0}',

  -- how team handicap strokes are spread across the holes
  stroke_allocation     text not null default 'stroke_index'
                        check (stroke_allocation in ('stroke_index','even','none')),

  -- how a team handicap is derived from the three player indexes.
  -- 'manual' = commissioner types a number on the team row.
  -- 'weighted' = percentages below, applied low index first.
  handicap_method       text not null default 'manual'
                        check (handicap_method in ('manual','weighted')),
  handicap_weights      numeric[] not null default '{0.25,0.15,0.10}',

  -- attestation
  attest_window_hours   smallint not null default 48,
  attest_who            text not null default 'any_player'
                        check (attest_who in ('any_player','captain_only')),
  show_pending          boolean not null default true,  -- grey out unconfirmed
                                                        -- rather than hiding

  min_drives_per_player smallint not null default 2,
  updated_at            timestamptz not null default now()
);

insert into league_settings (id) values (1);

alter table league_settings enable row level security;
create policy read_settings  on league_settings for select using (true);
create policy admin_settings on league_settings for all using (is_commissioner());

-- ------------------------------------------------------------
--  5. SCORING FUNCTION — now reads the config
-- ------------------------------------------------------------
create or replace function stableford_points(
  p_gross        smallint[],
  p_pars         smallint[],
  p_stroke_index smallint[],
  p_handicap     smallint
) returns smallint[]
language plpgsql stable as $$
declare
  cfg      jsonb;
  alloc    text;
  pts      smallint[] := '{}';
  keys     int[];
  lo       int;
  hi       int;
  i        int;
  strokes  int;
  diff     int;
begin
  if p_gross is null then return null; end if;

  select scoring, stroke_allocation
    into cfg, alloc
    from league_settings where id = 1;

  select array_agg(k::int order by k::int)
    into keys
    from jsonb_object_keys(cfg) k;

  lo := keys[1];
  hi := keys[array_length(keys,1)];

  for i in 1..9 loop
    strokes := case alloc
      when 'none' then 0
      when 'even' then floor(p_handicap / 9.0)
      else            floor(p_handicap / 9)
                    + case when p_stroke_index[i] <= (p_handicap % 9)
                           then 1 else 0 end
    end;

    diff := (p_gross[i] - strokes) - p_pars[i];
    diff := greatest(lo, least(hi, diff));      -- clamp to configured range

    pts := pts || (cfg ->> diff::text)::smallint;
  end loop;

  return pts;
end;
$$;

-- ------------------------------------------------------------
--  6. Surface the course and tees on the scores view
-- ------------------------------------------------------------
create or replace view round_scores as
select
  r.id,
  r.match_id,
  r.team_id,
  r.status,
  r.photo_path,
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
