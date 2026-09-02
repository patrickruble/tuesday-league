-- ============================================================
--  PATCH 024 — the pot, the whiteboard, and being told
--  Apply after patch-023.
--
--  The whiteboard on the wall stays. This mirrors it so the
--  other six bays can see where the number sits without walking
--  over, and so whoever held it finds out the moment it goes.
-- ============================================================

-- ------------------------------------------------------------
--  1. WHAT'S IN THE POT
--     Entries and money, set before the round. A contest with
--     no pot row still runs, it just doesn't say what's on it.
-- ------------------------------------------------------------
create table contest_pots (
  week       smallint not null,
  kind       text not null check (kind in ('ctp','long_putt','chip_in')),
  entries    smallint,
  per_entry  numeric(6,2),
  pot        numeric(8,2),
  carried    numeric(8,2) not null default 0,
  note       text,
  set_by     uuid references profiles,
  set_at     timestamptz not null default now(),
  primary key (week, kind)
);

comment on column contest_pots.carried is
  'Anything rolled over from a week nobody won.';
comment on column contest_pots.pot is
  'Total on it. Left null it works out as entries times per_entry
   plus whatever carried over.';

alter table contest_pots enable row level security;
create policy read_pots  on contest_pots for select using (true);
create policy admin_pots on contest_pots for all using (is_commissioner());

create or replace view contest_money as
select
  week, kind, entries, per_entry, carried, note,
  coalesce(pot, coalesce(entries,0) * coalesce(per_entry,0)) + carried as total
from contest_pots;

-- ------------------------------------------------------------
--  2. WHAT'S ON THE BOARD
--
--  Anyone in a bay can post a mark. It's a copy of the
--  whiteboard, not a ruling — so it starts unconfirmed and
--  Chris ticks it off at the end of the night.
-- ------------------------------------------------------------
alter table side_contests
  add column confirmed   boolean not null default false,
  add column confirmed_by uuid references profiles,
  add column confirmed_at timestamptz;

comment on column side_contests.confirmed is
  'Chris has checked it against the whiteboard. Unconfirmed
   marks still show — they just say so.';

-- Only the commissioner can tick one off.
create or replace function guard_contest_confirm()
returns trigger
language plpgsql
security definer
as $$
begin
  if new.confirmed is distinct from old.confirmed and not is_commissioner() then
    raise exception 'Only the commissioner confirms these';
  end if;
  if new.confirmed and not old.confirmed then
    new.confirmed_by := auth.uid();
    new.confirmed_at := now();
  end if;
  return new;
end;
$$;

create trigger contests_guard_confirm
  before update on side_contests
  for each row execute function guard_contest_confirm();

-- Anyone in the match can correct a mark that hasn't been
-- confirmed yet — fat fingers happen.
create policy fix_contests on side_contests for update using (
  not confirmed
  and exists (
    select 1 from matches m
     where m.id = side_contests.match_id
       and my_team() in (m.home_team, m.away_team)
  )
);

create policy clear_contests on side_contests for delete using (
  not confirmed
  and exists (
    select 1 from matches m
     where m.id = side_contests.match_id
       and my_team() in (m.home_team, m.away_team)
  )
);

-- ------------------------------------------------------------
--  3. WHERE THE NUMBER STANDS RIGHT NOW
--     Every mark posted this week, best first, so a phone can
--     show the board without working anything out.
-- ------------------------------------------------------------
create or replace view contest_board as
select
  m.week,
  sc.kind,
  sc.id,
  sc.hole,
  sc.value,
  sc.unit,
  sc.confirmed,
  sc.recorded_at,
  m.bay,
  p.id    as profile_id,
  p.full_name,
  t.id    as team_id,
  t.name  as team_name,
  t.slug  as team_slug,
  t.accent,
  row_number() over (
    partition by m.week, sc.kind
    order by
      case when sc.kind = 'ctp'       then sc.value end asc  nulls last,
      case when sc.kind = 'long_putt' then sc.value end desc nulls last,
      sc.recorded_at asc
  ) as standing
from side_contests sc
join matches m on m.id = sc.match_id
left join profiles p on p.id = sc.winner_id
left join teams    t on t.id = coalesce(sc.team_id, p.team_id)
order by m.week desc, sc.kind, standing;

-- ------------------------------------------------------------
--  4. LIVE
--     Push changes to anyone watching, so a phone in bay 6
--     knows the moment bay 2 posts a better number.
-- ------------------------------------------------------------
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
     where pubname = 'supabase_realtime' and tablename = 'side_contests'
  ) then
    alter publication supabase_realtime add table side_contests;
  end if;
end $$;

alter table side_contests replica identity full;
