-- ============================================================
--  PATCH 005 — auth plumbing
--  Apply after patch-004.
--
--  A Supabase signup creates a row in auth.users. Nothing in
--  our schema knows about it until this trigger runs, so
--  without this every new account has no profile and every
--  policy that calls my_team() returns null.
-- ============================================================

-- ------------------------------------------------------------
--  1. ROSTER SPOTS
--     Chris's export gives us names and emails before anyone
--     signs up. Seed this table from it; a player claims their
--     spot on first login and inherits the team.
-- ------------------------------------------------------------
create table roster_spots (
  id         uuid primary key default gen_random_uuid(),
  team_id    uuid not null references teams on delete cascade,
  full_name  text not null,
  email      text,
  hcp_index  numeric(4,1),
  spot       smallint not null check (spot between 1 and 3),
  claimed_by uuid references profiles on delete set null,
  claimed_at timestamptz,
  unique (team_id, spot)
);

create index on roster_spots (lower(email));

alter table roster_spots enable row level security;

create policy read_spots  on roster_spots for select using (true);
create policy admin_spots on roster_spots for all using (is_commissioner());

-- ------------------------------------------------------------
--  2. PROFILE ON SIGNUP
--     If the signup email matches a roster spot, the player is
--     put straight on their team. Otherwise they land with no
--     team and the commissioner sorts it out.
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

  insert into public.profiles (id, full_name, team_id, hcp_index)
  values (new.id, nm, spot.team_id, spot.hcp_index);

  if spot.id is not null then
    update roster_spots
       set claimed_by = new.id, claimed_at = now()
     where id = spot.id;
  end if;

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_user();

-- ------------------------------------------------------------
--  3. CLAIMING A SPOT AFTER THE FACT
--     For anyone who signs up with a different email than the
--     one Chris has. They pick their name from the roster.
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
  if auth.uid() is null then
    raise exception 'Not signed in';
  end if;

  select * into spot from roster_spots where id = p_spot for update;

  if spot.id is null then
    raise exception 'No such roster spot';
  end if;
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
     set team_id   = spot.team_id,
         full_name = coalesce(nullif(full_name,''), spot.full_name),
         hcp_index = coalesce(hcp_index, spot.hcp_index)
   where id = auth.uid();
end;
$$;

grant execute on function claim_spot(uuid) to authenticated;

-- ------------------------------------------------------------
--  4. Unclaimed spots, for the picker
-- ------------------------------------------------------------
create or replace view open_spots as
select
  rs.id, rs.full_name, rs.spot, rs.hcp_index,
  t.id as team_id, t.name as team_name, t.slug, t.accent, t.crest
from roster_spots rs
join teams t on t.id = rs.team_id
where rs.claimed_by is null
order by t.name, rs.spot;

-- ------------------------------------------------------------
--  5. Handy: who is signed in and what can they do
-- ------------------------------------------------------------
create or replace view me as
select
  p.id, p.full_name, p.hcp_index, p.role, p.default_tee,
  t.id as team_id, t.slug as team_slug, t.name as team_name,
  t.accent, t.crest, t.typeface, t.backdrop, t.mood,
  (p.role = 'commissioner') as is_admin
from profiles p
left join teams t on t.id = p.team_id
where p.id = auth.uid();
