-- ============================================================
--  PATCH 007 — player photos
--  Apply after patch-006.
-- ============================================================

alter table profiles add column avatar_url text;

comment on column profiles.avatar_url is
  'Object path in the avatars bucket. Null means fall back to
   initials on the team colour, which is the default and looks
   deliberate rather than broken.';

-- Public bucket: photos appear on roster cards and the clubhouse
-- feed, both of which are readable without signing in.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('avatars','avatars', true, 3145728,
        array['image/png','image/jpeg','image/webp'])
on conflict (id) do nothing;

create policy "read avatars"
  on storage.objects for select
  using (bucket_id = 'avatars');

-- You can only write to a folder named after your own user id.
create policy "upload own avatar"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy "replace own avatar"
  on storage.objects for update to authenticated
  using (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy "delete own avatar"
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- Surface it on the `me` view so pages get it in one query.
drop view if exists me;
create view me as
select
  p.id, p.full_name, p.hcp_index, p.role, p.default_tee, p.quote, p.avatar_url,
  t.id as team_id, t.slug as team_slug, t.name as team_name,
  t.accent, t.crest, t.crest_url, t.typeface, t.backdrop, t.mood,
  (p.role = 'commissioner') as is_admin
from profiles p
left join teams t on t.id = p.team_id
where p.id = auth.uid();

-- Roster with photos, for the team pages.
create or replace view team_roster as
select
  p.id, p.full_name, p.hcp_index, p.quote, p.avatar_url, p.default_tee,
  t.id as team_id, t.slug as team_slug, t.name as team_name, t.accent,
  rs.spot
from profiles p
join teams t on t.id = p.team_id
left join roster_spots rs on rs.claimed_by = p.id
order by t.name, coalesce(rs.spot, 9);

