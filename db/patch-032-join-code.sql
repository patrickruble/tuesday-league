-- ============================================================
--  PATCH 032 — you need the code
--  Apply after patch-031.
--
--  Signing up was open to anyone, and the next screen listed
--  every unclaimed roster spot. Nothing stopped a stranger
--  becoming Shannon Chaisson.
--
--  Accounts stay open — that part's harmless, and Supabase
--  handles the email confirmation. What's gated is joining a
--  team, because an account with no team can't do anything:
--  no card, no team page, no contests.
--
--  Two ways in:
--    the email matches a roster spot Chris put in, or
--    you have the code he handed out.
-- ============================================================

alter table league_settings
  add column if not exists join_code text;

comment on column league_settings.join_code is
  'Handed out by the commissioner. Needed to claim a roster spot
   unless the account''s email already matches one. Null lets
   anyone claim, which is how it behaved before and is only
   sensible while testing.';

-- Something to start with. Change it in the admin.
update league_settings
   set join_code = 'KATY26'
 where id = 1 and join_code is null;

-- ------------------------------------------------------------
--  Claiming, with the code
-- ------------------------------------------------------------
create or replace function claim_spot(p_spot uuid, p_code text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  spot     roster_spots%rowtype;
  want     text;
  my_email text;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;

  select * into spot from roster_spots where id = p_spot for update;
  if spot.id is null then raise exception 'No such roster spot'; end if;
  if spot.claimed_by is not null then
    raise exception 'Someone has already claimed that spot';
  end if;
  if exists (select 1 from profiles where id = auth.uid() and team_id is not null) then
    raise exception 'You are already on a team';
  end if;

  select join_code into want from league_settings where id = 1;
  select email into my_email from auth.users where id = auth.uid();

  /* the email Chris put on the spot is proof enough */
  if want is not null
     and lower(coalesce(spot.email,'')) <> lower(coalesce(my_email,'~none~'))
     and lower(coalesce(p_code,'')) <> lower(want) then
    raise exception 'That code is not right. Ask Chris for it.';
  end if;

  update roster_spots
     set claimed_by = auth.uid(), claimed_at = now()
   where id = p_spot;

  update profiles
     set team_id     = spot.team_id,
         full_name   = coalesce(nullif(full_name,''), spot.full_name),
         hcp_index   = coalesce(hcp_index, spot.hcp_index),
         default_tee = coalesce(spot.default_tee, default_tee, 'blue')
   where id = auth.uid();
end;
$$;

grant execute on function claim_spot(uuid, text) to authenticated;

-- ------------------------------------------------------------
--  The picker shouldn't leak the roster to a stranger either.
--  Only someone signed in and not yet on a team sees it, and
--  they only see names — no email, no handicap.
-- ------------------------------------------------------------
drop view if exists open_spots;
create view open_spots as
select
  rs.id, rs.full_name, rs.spot, rs.default_tee,
  t.id as team_id, t.name as team_name, t.slug, t.accent, t.crest
from roster_spots rs
join teams t on t.id = rs.team_id
where rs.claimed_by is null
  and auth.uid() is not null
  and not exists (
    select 1 from profiles p where p.id = auth.uid() and p.team_id is not null
  )
order by t.name, rs.spot;

-- ------------------------------------------------------------
--  Whether this account needs the code, so the page can ask for
--  it only when it has to.
-- ------------------------------------------------------------
create or replace function needs_join_code()
returns boolean
language sql
security definer
set search_path = public
as $$
  select case
    when (select join_code from league_settings where id = 1) is null then false
    when exists (
      select 1 from roster_spots rs
       where rs.claimed_by is null
         and lower(rs.email) = lower((select email from auth.users where id = auth.uid()))
    ) then false
    else true
  end;
$$;

grant execute on function needs_join_code() to authenticated;
