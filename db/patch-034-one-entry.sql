-- ============================================================
--  PATCH 034 — one entry, three contests, and a carry
--  Apply after patch-033.
--
--  It's ten dollars a head for the night, not ten a contest.
--  That money splits across closest to the pin, long putt and
--  chip-in. Nobody chips in, that share rolls into next week.
-- ============================================================

-- ------------------------------------------------------------
--  Entering is per night, not per contest
-- ------------------------------------------------------------
-- the table may not exist yet; dropping it takes any trigger
-- with it, so there's nothing to drop separately
drop table if exists contest_entrants cascade;

create table contest_entrants (
  week         smallint not null,
  profile_id   uuid not null references profiles on delete cascade,

  declared_at  timestamptz not null default now(),
  paid         boolean not null default false,
  confirmed_by uuid references profiles,
  confirmed_at timestamptz,

  primary key (week, profile_id)
);

comment on table contest_entrants is
  'One row per person per week. Ten dollars covers all three
   contests, so there is nothing to record per contest.';

create index on contest_entrants (week, paid);

alter table contest_entrants enable row level security;

create policy read_entrants   on contest_entrants for select using (true);
create policy declare_self    on contest_entrants for insert to authenticated
  with check (profile_id = auth.uid() and not paid);
create policy undeclare_self  on contest_entrants for delete
  using (profile_id = auth.uid() and not paid);
create policy admin_entrants  on contest_entrants for all using (is_commissioner());

create or replace function guard_entrant_paid()
returns trigger
language plpgsql security definer
as $$
begin
  if new.paid is distinct from old.paid and not is_commissioner() then
    raise exception 'Only the commissioner confirms the money';
  end if;
  if new.paid and not old.paid then
    new.confirmed_by := auth.uid();
    new.confirmed_at := now();
  end if;
  return new;
end;
$$;

create trigger entrants_guard_paid
  before update on contest_entrants
  for each row execute function guard_entrant_paid();

-- ------------------------------------------------------------
--  The pot
--
--  One entry fee, one pot, split three ways. The share is a
--  fraction so it can be uneven if the league ever wants that;
--  by default it's a third each.
-- ------------------------------------------------------------
alter table league_settings
  add column if not exists entry_fee numeric(6,2) not null default 10;

comment on column league_settings.entry_fee is
  'What one person pays for the night, covering all three
   contests.';

drop table if exists contest_pots cascade;

create table contest_pots (
  week      smallint not null,
  kind      text not null check (kind in ('ctp','long_putt','chip_in')),
  share     numeric(4,3) not null default 0.333
             check (share >= 0 and share <= 1),
  carried   numeric(8,2) not null default 0,
  note      text,
  primary key (week, kind)
);

comment on column contest_pots.share is
  'This contest''s slice of the night''s pot. Thirds by default.';
comment on column contest_pots.carried is
  'Rolled in from a week nobody won it.';

alter table contest_pots enable row level security;
create policy read_pots  on contest_pots for select using (true);
create policy admin_pots on contest_pots for all using (is_commissioner());

-- ------------------------------------------------------------
--  What each contest is worth this week
-- ------------------------------------------------------------
create or replace view contest_money as
with heads as (
  select
    week,
    count(*) filter (where paid)     as entries,
    count(*) filter (where not paid) as waiting
  from contest_entrants group by week
),
fee as (select coalesce(entry_fee, 10) as amount from league_settings where id = 1)
select
  p.week,
  p.kind,
  p.share,
  p.carried,
  p.note,
  coalesce(h.entries, 0) as entries,
  coalesce(h.waiting, 0) as waiting,
  (select amount from fee) as per_entry,
  round(coalesce(h.entries,0) * (select amount from fee) * p.share) + p.carried as total
from contest_pots p
left join heads h on h.week = p.week;

-- ------------------------------------------------------------
--  A number can only go up against someone who paid that night
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
  if not any_ then return new; end if;   -- not being run that way this week

  if not exists (
    select 1 from contest_entrants
     where week = wk and profile_id = new.winner_id and paid
  ) then
    select full_name into who from profiles where id = new.winner_id;
    raise exception '% has not paid in this week', coalesce(who, 'That player');
  end if;

  return new;
end;
$$;

drop trigger if exists contests_guard_entrant on side_contests;
create trigger contests_guard_entrant
  before insert on side_contests
  for each row execute function guard_contest_entrant();

-- ------------------------------------------------------------
--  Closing a week
--
--  Anything nobody won rolls into the same contest next week.
--  In practice that's the chip-in — closest to the pin and the
--  long putt almost always have a winner, but the same rule
--  covers them if they don't.
--
--  Run once, after the cards are in. Safe to run twice: the
--  carry is written rather than added to.
-- ------------------------------------------------------------
create or replace function close_week(p_week smallint)
returns table (kind text, amount numeric, rolled boolean)
language plpgsql
security definer
set search_path = public
as $$
declare
  k       text;
  won     boolean;
  worth   numeric;
begin
  if not is_commissioner() then
    raise exception 'Only the commissioner closes a week';
  end if;

  foreach k in array array['ctp','long_putt','chip_in'] loop
    select exists (
      select 1 from side_contests sc
      join matches m on m.id = sc.match_id
      where m.week = p_week and sc.kind = k
    ) into won;

    select cm.total into worth
      from contest_money cm where cm.week = p_week and cm.kind = k;

    if worth is null then continue; end if;

    if won then
      /* somebody took it — next week starts clean */
      insert into contest_pots (week, kind, carried)
      values (p_week + 1, k, 0)
      on conflict (week, kind) do update set carried = 0;
    else
      insert into contest_pots (week, kind, carried)
      values (p_week + 1, k, worth)
      on conflict (week, kind) do update set carried = excluded.carried;
    end if;

    kind := k; amount := worth; rolled := not won;
    return next;
  end loop;
end;
$$;

grant execute on function close_week(smallint) to authenticated;

-- ------------------------------------------------------------
--  Who's in, for the pot list
-- ------------------------------------------------------------
create or replace view entrant_list as
select
  ce.week, ce.profile_id, ce.paid, ce.declared_at,
  pr.full_name,
  t.id as team_id, t.name as team_name, t.slug as team_slug, t.accent
from contest_entrants ce
join profiles pr on pr.id = ce.profile_id
left join teams t on t.id = pr.team_id
order by t.name, pr.full_name;
