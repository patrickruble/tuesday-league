-- ============================================================
--  PATCH 010 — background colour and image
--  Apply after patch-009.
--
--  Patterns already tint themselves with the team accent. This
--  adds the two things people actually reach for: a background
--  colour of their own, and an image behind the page.
--
--  Text panels stay on a near-opaque white, so a loud
--  background can't make anything unreadable.
-- ============================================================

alter table teams
  add column backdrop_color text
    check (backdrop_color is null or backdrop_color ~ '^#[0-9A-Fa-f]{6}$'),
  add column backdrop_image text,
  add column backdrop_mode  text not null default 'tile'
    check (backdrop_mode in ('tile','cover','fixed'));

comment on column teams.backdrop_color is
  'Page background behind the pattern. Null falls back to the
   league default.';
comment on column teams.backdrop_image is
  'Object path in the backdrops bucket. Sits behind the pattern
   and the colour.';
comment on column teams.backdrop_mode is
  'tile repeats the image, cover scales it to fill, fixed keeps
   it still while the page scrolls.';

-- ------------------------------------------------------------
--  Bucket. Public, because team pages are readable without
--  signing in. Upload is limited to your own team's folder.
-- ------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('backdrops','backdrops', true, 4194304,
        array['image/png','image/jpeg','image/webp','image/gif'])
on conflict (id) do nothing;

create policy "read backdrops"
  on storage.objects for select
  using (bucket_id = 'backdrops');

create policy "upload own backdrop"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'backdrops'
    and (storage.foldername(name))[1] = my_team()::text
  );

create policy "replace own backdrop"
  on storage.objects for update to authenticated
  using (
    bucket_id = 'backdrops'
    and (storage.foldername(name))[1] = my_team()::text
  );

create policy "delete own backdrop"
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'backdrops'
    and (storage.foldername(name))[1] = my_team()::text
  );

-- ------------------------------------------------------------
--  Surface the new columns on the me view.
-- ------------------------------------------------------------
drop view if exists me;
create view me as
select
  p.id, p.full_name, p.hcp_index, p.role, p.default_tee, p.quote, p.avatar_url,
  t.id as team_id, t.slug as team_slug, t.name as team_name,
  t.accent, t.crest, t.crest_url, t.typeface, t.backdrop, t.mood,
  t.backdrop_color, t.backdrop_image, t.backdrop_mode,
  (p.role = 'commissioner') as is_admin
from profiles p
left join teams t on t.id = p.team_id
where p.id = auth.uid();
