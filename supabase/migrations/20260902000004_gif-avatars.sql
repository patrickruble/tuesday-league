-- ============================================================
--  PATCH 012 — animated avatars
--  Apply after patch-011.
-- ============================================================

update storage.buckets
   set allowed_mime_types = array['image/png','image/jpeg','image/webp','image/gif'],
       file_size_limit    = 3145728          -- 3 MB, enough for a short loop
 where id = 'avatars';

-- ------------------------------------------------------------
--  Optional: make it something the commissioner hands out
--  rather than something everyone has. Uncomment if you'd
--  rather it be a perk.
--
--    alter table profiles
--      add column can_animate boolean not null default false;
--
--  The editor would then check it before offering GIF upload,
--  and you'd grant it with:
--
--    update profiles set can_animate = true
--     where full_name = 'Patrick Ruble';
-- ------------------------------------------------------------

comment on column profiles.avatar_url is
  'Object path in the avatars bucket. GIFs are uploaded whole so
   the animation survives; everything else is squared and
   resized in the browser before it goes up.';
