-- ============================================================
--  PATCH 013 — animated avatars become a perk
--  Apply after patch-012.
--
--  Hiding the option in the editor isn't enough on its own —
--  anyone can craft the request by hand. The trigger is what
--  actually enforces it.
-- ============================================================

alter table profiles
  add column can_animate boolean not null default false;

comment on column profiles.can_animate is
  'Whether this player may use an animated avatar. Granted by
   the commissioner. Enforced by the guard_animated_avatar
   trigger, not just by the editor hiding the option.';

-- ------------------------------------------------------------
--  The actual enforcement
-- ------------------------------------------------------------
create or replace function guard_animated_avatar()
returns trigger
language plpgsql
as $$
begin
  if new.avatar_url is not null
     and new.avatar_url ilike '%.gif'
     and not coalesce(new.can_animate, false) then
    raise exception 'Animated avatars are handed out by the commissioner';
  end if;
  return new;
end;
$$;

create trigger profiles_guard_gif
  before insert or update on profiles
  for each row execute function guard_animated_avatar();

-- Nobody can grant it to themselves — can_animate is only
-- writable through the commissioner's admin policy.
create or replace function guard_own_perks()
returns trigger
language plpgsql
security definer
as $$
begin
  if not is_commissioner()
     and new.can_animate is distinct from old.can_animate then
    raise exception 'You cannot grant yourself that';
  end if;
  return new;
end;
$$;

create trigger profiles_guard_perks
  before update on profiles
  for each row execute function guard_own_perks();

-- ------------------------------------------------------------
--  Surface it so the editor knows whether to offer the option
-- ------------------------------------------------------------
drop view if exists me;
create view me as
select
  p.id, p.full_name, p.hcp_index, p.role, p.default_tee, p.quote, p.avatar_url,
  p.can_animate,
  t.id as team_id, t.slug as team_slug, t.name as team_name,
  t.accent, t.crest, t.crest_url, t.typeface, t.backdrop, t.mood,
  t.backdrop_color, t.backdrop_image, t.backdrop_mode,
  (p.role = 'commissioner') as is_admin
from profiles p
left join teams t on t.id = p.team_id
where p.id = auth.uid();

-- ------------------------------------------------------------
--  Grant it to yourself, since you already have one.
--  To hand it to someone else later:
--    update profiles set can_animate = true where full_name = 'Their Name';
-- ------------------------------------------------------------
update profiles set can_animate = true where full_name = 'Patrick Ruble';
