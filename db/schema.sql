-- ============================================================
--  X-Golf Tuesday League — Supabase schema
--  Run this in the Supabase SQL editor.
--
--  Trust model: a team enters its own card, the OPPOSING team
--  signs it off. Nothing reaches the leaderboard until it is
--  confirmed. The commissioner can override anything.
-- ============================================================

-- ------------------------------------------------------------
--  COURSES
--  Par and stroke index per hole. Entered once, reused forever.
--  Arrays are 9 long, index 0 = hole 1.
-- ------------------------------------------------------------
create table courses (
  id            uuid primary key default gen_random_uuid(),
  name          text not null,
  tee           text not null check (tee in ('front','back')),
  pars          smallint[] not null check (array_length(pars,1) = 9),
  stroke_index  smallint[] not null check (array_length(stroke_index,1) = 9),
  created_at    timestamptz not null default now(),
  unique (name, tee)
);

-- ------------------------------------------------------------
--  TEAMS
--  Everything on the public team page lives here.
-- ------------------------------------------------------------
create table teams (
  id            uuid primary key default gen_random_uuid(),
  slug          text not null unique,
  name          text not null,
  crest         text not null,                    -- 2-letter monogram
  accent        text not null default '#0F766E',  -- hex, per-team
  handicap      smallint not null default 0,      -- team strokes per round
  bio           text,

  -- the personal layer
  mood          text,
  mood_at       timestamptz,
  song_title    text,
  song_artist   text,
  song_provider text check (song_provider in ('youtube','spotify','soundcloud')),
  song_id       text,

  created_at    timestamptz not null default now()
);

-- ------------------------------------------------------------
--  PROFILES
--  One row per signed-in human, linked to Supabase auth.
--  role decides who is the commissioner.
-- ------------------------------------------------------------
create table profiles (
  id          uuid primary key references auth.users on delete cascade,
  full_name   text not null,
  team_id     uuid references teams on delete set null,
  hcp_index   numeric(4,1),
  quote       text,
  role        text not null default 'player' check (role in ('player','commissioner')),
  created_at  timestamptz not null default now()
);

-- ------------------------------------------------------------
--  MATCHES
--  One row per fixture. The QR code encodes this id.
-- ------------------------------------------------------------
create table matches (
  id          uuid primary key default gen_random_uuid(),
  week        smallint not null,
  played_on   date not null,
  tee_time    time,
  bay         text,
  course_id   uuid not null references courses,
  home_team   uuid not null references teams,
  away_team   uuid not null references teams,
  created_at  timestamptz not null default now(),
  check (home_team <> away_team)
);

-- ------------------------------------------------------------
--  ROUNDS
--  One row per team per match. gross[] is the only thing a
--  player types; net and points are computed, never entered.
--
--  status flow:
--    draft      -> being filled in
--    submitted  -> waiting on the opponent
--    confirmed  -> counts toward the leaderboard
--    disputed   -> opponent rejected it, commissioner decides
-- ------------------------------------------------------------
create table rounds (
  id            uuid primary key default gen_random_uuid(),
  match_id      uuid not null references matches on delete cascade,
  team_id       uuid not null references teams,

  gross         smallint[] check (array_length(gross,1) = 9),
  photo_path    text,                       -- Supabase Storage object path
  drives_used   jsonb,                      -- { "<profile_id>": 4, ... }

  status        text not null default 'draft'
                check (status in ('draft','submitted','confirmed','disputed')),

  submitted_by  uuid references profiles,
  submitted_at  timestamptz,
  attested_by   uuid references profiles,   -- must be on the OTHER team
  attested_at   timestamptz,
  dispute_note  text,

  created_at    timestamptz not null default now(),
  unique (match_id, team_id)
);

-- ------------------------------------------------------------
--  TRASH TALK
-- ------------------------------------------------------------
create table trash_talk (
  id          uuid primary key default gen_random_uuid(),
  from_team   uuid not null references teams on delete cascade,
  to_team     uuid not null references teams on delete cascade,
  author_id   uuid not null references profiles,
  body        text not null check (char_length(body) <= 280),
  created_at  timestamptz not null default now()
);

-- ============================================================
--  SCORING
--  Stableford off net: bogey+ = 0, par = 1, birdie = 2, eagle = 3.
--  Handicap strokes go to the lowest stroke-index holes.
-- ============================================================

create or replace function stableford_points(
  p_gross        smallint[],
  p_pars         smallint[],
  p_stroke_index smallint[],
  p_handicap     smallint
) returns smallint[]
language plpgsql immutable as $$
declare
  pts smallint[] := '{}';
  i   int;
  net int;
  diff int;
  strokes int;
begin
  if p_gross is null then return null; end if;

  for i in 1..9 loop
    -- one stroke per handicap point, allocated by stroke index;
    -- a handicap above 9 loops round and gives a second stroke
    strokes := floor(p_handicap / 9)
             + case when p_stroke_index[i] <= (p_handicap % 9) then 1 else 0 end;

    net  := p_gross[i] - strokes;
    diff := net - p_pars[i];

    pts := pts || case
      when diff <= -2 then 3::smallint   -- eagle or better
      when diff  = -1 then 2::smallint   -- birdie
      when diff  =  0 then 1::smallint   -- par
      else                 0::smallint   -- bogey or worse
    end;
  end loop;

  return pts;
end;
$$;

-- Convenience view: everything the public pages need, already scored.
create or replace view round_scores as
select
  r.id,
  r.match_id,
  r.team_id,
  r.status,
  r.photo_path,
  m.week,
  m.played_on,
  c.name  as course_name,
  c.tee,
  r.gross,
  stableford_points(r.gross, c.pars, c.stroke_index, t.handicap) as points,
  (select sum(p) from unnest(
      stableford_points(r.gross, c.pars, c.stroke_index, t.handicap)
   ) p) as total_points
from rounds r
join matches m on m.id = r.match_id
join courses c on c.id = m.course_id
join teams   t on t.id = r.team_id;

-- ============================================================
--  HELPERS
-- ============================================================

create or replace function is_commissioner() returns boolean
language sql stable security definer as $$
  select exists (
    select 1 from profiles
    where id = auth.uid() and role = 'commissioner'
  );
$$;

create or replace function my_team() returns uuid
language sql stable security definer as $$
  select team_id from profiles where id = auth.uid();
$$;

-- Is the current user on the team that this round is played AGAINST?
create or replace function can_attest(p_round uuid) returns boolean
language sql stable security definer as $$
  select exists (
    select 1
    from rounds r
    join matches m on m.id = r.match_id
    where r.id = p_round
      and r.team_id <> my_team()                        -- not your own card
      and my_team() in (m.home_team, m.away_team)       -- but you were there
  );
$$;

-- ============================================================
--  ROW LEVEL SECURITY
-- ============================================================
alter table courses    enable row level security;
alter table teams      enable row level security;
alter table profiles   enable row level security;
alter table matches    enable row level security;
alter table rounds     enable row level security;
alter table trash_talk enable row level security;

-- Anyone, signed in or not, can read the public stuff.
create policy read_courses on courses for select using (true);
create policy read_teams   on teams   for select using (true);
create policy read_matches on matches for select using (true);
create policy read_talk    on trash_talk for select using (true);

-- Profiles are readable (names appear on team pages) but only
-- editable by their owner.
create policy read_profiles   on profiles for select using (true);
create policy update_own_profile on profiles for update
  using (id = auth.uid()) with check (id = auth.uid());

-- Rounds: everyone sees confirmed ones. You also see your own
-- team's in-progress cards, and cards you are being asked to sign.
create policy read_rounds on rounds for select using (
  status = 'confirmed'
  or team_id = my_team()
  or can_attest(id)
  or is_commissioner()
);

-- Only players on the team can create/edit their own card, and
-- only while it is still unconfirmed.
create policy insert_own_round on rounds for insert
  with check (team_id = my_team());

create policy update_own_round on rounds for update
  using (team_id = my_team() and status in ('draft','disputed'))
  with check (team_id = my_team());

-- The opponent can sign off or dispute — but cannot change scores.
-- Enforce the "no score edits" part in a trigger, below.
create policy attest_round on rounds for update
  using (can_attest(id) and status = 'submitted');

-- Team page edits (mood, song, bio) by anyone on that team.
create policy update_own_team on teams for update
  using (id = my_team()) with check (id = my_team());

-- Trash talk: post as your own team only.
create policy post_talk on trash_talk for insert
  with check (from_team = my_team() and author_id = auth.uid());

-- Commissioner override on everything.
create policy admin_teams   on teams   for all using (is_commissioner());
create policy admin_rounds  on rounds  for all using (is_commissioner());
create policy admin_matches on matches for all using (is_commissioner());
create policy admin_courses on courses for all using (is_commissioner());
create policy admin_talk    on trash_talk for all using (is_commissioner());
create policy admin_profiles on profiles for all using (is_commissioner());

-- ------------------------------------------------------------
--  Guard: an attesting opponent may only change status fields,
--  never the scores or the photo.
-- ------------------------------------------------------------
create or replace function guard_attestation() returns trigger
language plpgsql security definer as $$
begin
  if is_commissioner() then return new; end if;

  if new.team_id <> my_team() then
    if new.gross is distinct from old.gross
       or new.photo_path is distinct from old.photo_path
       or new.drives_used is distinct from old.drives_used then
      raise exception 'An opposing player cannot change the scorecard';
    end if;
    if new.status not in ('confirmed','disputed') then
      raise exception 'An opposing player can only confirm or dispute';
    end if;
    new.attested_by := auth.uid();
    new.attested_at := now();
  end if;

  return new;
end;
$$;

create trigger rounds_guard
  before update on rounds
  for each row execute function guard_attestation();

-- ------------------------------------------------------------
--  Stamp the submitter when a card moves to 'submitted'.
-- ------------------------------------------------------------
create or replace function stamp_submission() returns trigger
language plpgsql security definer as $$
begin
  if new.status = 'submitted' and old.status is distinct from 'submitted' then
    new.submitted_by := auth.uid();
    new.submitted_at := now();
    if new.photo_path is null then
      raise exception 'A scorecard photo is required before submitting';
    end if;
  end if;
  return new;
end;
$$;

create trigger rounds_stamp
  before update on rounds
  for each row execute function stamp_submission();

-- ------------------------------------------------------------
--  Keep mood_at honest.
-- ------------------------------------------------------------
create or replace function touch_mood() returns trigger
language plpgsql as $$
begin
  if new.mood is distinct from old.mood then
    new.mood_at := now();
  end if;
  return new;
end;
$$;

create trigger teams_touch_mood
  before update on teams
  for each row execute function touch_mood();
