-- ============================================================
--  PATCH 041 — paid, then you can post
--  Apply after patch-040.
--
--  Putting your name down isn't enough. Chris confirms the
--  money, and only then can a number go up against you —
--  otherwise the pot pays out to people who never paid in.
-- ============================================================

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

  -- nobody entered at all: the pot isn't being run that way
  select exists (select 1 from contest_entrants where week = wk) into any_;
  if not any_ then return new; end if;

  if not exists (
    select 1 from contest_entrants
     where week = wk and profile_id = new.winner_id and paid
  ) then
    select full_name into who from profiles where id = new.winner_id;
    raise exception '% has not been confirmed in the pot yet', coalesce(who, 'That player');
  end if;

  return new;
end;
$$;

drop trigger if exists contests_guard_entrant on side_contests;
create trigger contests_guard_entrant
  before insert on side_contests
  for each row execute function guard_contest_entrant();
