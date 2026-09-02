-- ============================================================
--  PATCH 018 — tee follows the player
--  Apply after patch-017.
--
--  Chris knows who plays which tee before anyone signs up, so
--  it belongs on the roster spot. It carries into the profile
--  when the account is created or the spot is claimed, and the
--  player can change it themselves after that.
-- ============================================================

alter table roster_spots
  add column default_tee text
    check (default_tee is null or default_tee in ('black','blue','white','red'));

comment on column roster_spots.default_tee is
  'Which tee this player uses. Set by the commissioner when the
   roster goes in, so yardages are right before anyone has
   touched their own settings.';

-- Everyone starts on blue unless told otherwise.
alter table profiles alter column default_tee set default 'blue';
update profiles set default_tee = 'blue' where default_tee is null;

-- ------------------------------------------------------------
--  Signup carries it across
-- ------------------------------------------------------------
create or replace function handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  spot roster_spots%rowtype;
  nm   text;
begin
  select * into spot
    from roster_spots
   where lower(email) = lower(new.email)
     and claimed_by is null
   limit 1;

  nm := coalesce(
    new.raw_user_meta_data ->> 'full_name',
    spot.full_name,
    split_part(new.email, '@', 1)
  );

  insert into public.profiles (id, full_name, team_id, hcp_index, default_tee)
  values (new.id, nm, spot.team_id, spot.hcp_index,
          coalesce(spot.default_tee, 'blue'));

  if spot.id is not null then
    update roster_spots
       set claimed_by = new.id, claimed_at = now()
     where id = spot.id;
  end if;

  return new;
end;
$$;

-- ------------------------------------------------------------
--  So does claiming a spot after the fact
-- ------------------------------------------------------------
create or replace function claim_spot(p_spot uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  spot roster_spots%rowtype;
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

-- ------------------------------------------------------------
--  The picker on the login page shows the tee too, so people
--  can recognise themselves by more than a name.
-- ------------------------------------------------------------
create or replace view open_spots as
select
  rs.id, rs.full_name, rs.spot, rs.hcp_index, rs.default_tee,
  t.id as team_id, t.name as team_name, t.slug, t.accent, t.crest
from roster_spots rs
join teams t on t.id = rs.team_id
where rs.claimed_by is null
order by t.name, rs.spot;
