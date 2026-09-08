-- ============================================================
--  PATCH 040 — the money settles afterwards
--  Apply after patch-034.
--
--  Putting a number on the board shouldn't wait on Chris having
--  taken a tenner. Anyone who's put their name down can post;
--  he ticks off who's paid whenever it suits, and the board
--  shows who still owes.
-- ============================================================

-- These come from patch 034. Add them if that didn't land.
create table if not exists contest_entrants (
  week         smallint not null,
  profile_id   uuid not null references profiles on delete cascade,
  declared_at  timestamptz not null default now(),
  paid         boolean not null default false,
  confirmed_by uuid references profiles,
  confirmed_at timestamptz,
  primary key (week, profile_id)
);

alter table contest_entrants enable row level security;

drop policy if exists read_entrants  on contest_entrants;
drop policy if exists declare_self   on contest_entrants;
drop policy if exists undeclare_self on contest_entrants;
drop policy if exists admin_entrants on contest_entrants;

create policy read_entrants  on contest_entrants for select using (true);
create policy declare_self   on contest_entrants for insert to authenticated
  with check (profile_id = auth.uid());
create policy undeclare_self on contest_entrants for delete
  using (profile_id = auth.uid() and not paid);
create policy admin_entrants on contest_entrants for all using (is_commissioner());

-- ------------------------------------------------------------
--  The gate: your name down, not your money in.
-- ------------------------------------------------------------
create or replace function guard_contest_entrant()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  wk   smallint;
  any_ boolean;
  who  text;
begin
  select week into wk from matches where id = new.match_id;

  select exists (select 1 from contest_entrants where week = wk) into any_;
  if not any_ then return new; end if;

  if not exists (
    select 1 from contest_entrants where week = wk and profile_id = new.winner_id
  ) then
    select full_name into who from profiles where id = new.winner_id;
    raise exception '% is not in the pot this week', coalesce(who, 'That player');
  end if;

  return new;
end;
$$;

drop trigger if exists contests_guard_entrant on side_contests;
create trigger contests_guard_entrant
  before insert on side_contests
  for each row execute function guard_contest_entrant();

-- ------------------------------------------------------------
--  Who still owes, so it can be settled at the end of the night
-- ------------------------------------------------------------
create or replace view pot_owing as
select
  ce.week,
  pr.full_name,
  t.name as team_name,
  ce.declared_at,
  (select coalesce(entry_fee, 10) from league_settings where id = 1) as owes
from contest_entrants ce
join profiles pr on pr.id = ce.profile_id
left join teams t on t.id = pr.team_id
where not ce.paid
order by ce.week desc, t.name, pr.full_name;
