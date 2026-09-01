-- ============================================================
--  PATCH 008 — GIFs on posts and replies
--  Apply after patch-007.
--
--  We store the URL, not the file. Giphy hosts it, we point at
--  it. Keeps storage empty and means no moderation burden on
--  uploads — the content filter is set on their side.
-- ============================================================

alter table clubhouse_posts
  add column gif_url      text,
  add column gif_provider text check (gif_provider in ('giphy','tenor')),
  add column gif_id       text,
  add column gif_alt      text;

alter table post_replies
  add column gif_url      text,
  add column gif_provider text check (gif_provider in ('giphy','tenor')),
  add column gif_id       text,
  add column gif_alt      text;

comment on column clubhouse_posts.gif_url is
  'Direct URL to the GIF on the provider''s CDN. Never a file we host.';

-- A reply can now be a GIF with no words, so relax the length rule.
alter table post_replies drop constraint post_replies_body_check;
alter table post_replies alter column body drop not null;
alter table post_replies add constraint post_replies_has_content
  check (
    (body is not null and char_length(body) between 1 and 1000)
    or gif_url is not null
  );

-- Same for posts.
alter table clubhouse_posts drop constraint clubhouse_posts_body_check;
alter table clubhouse_posts alter column body drop not null;
alter table clubhouse_posts add constraint clubhouse_posts_has_content
  check (
    (body is not null and char_length(body) between 1 and 2000)
    or gif_url is not null
  );

-- Rebuild the feed view with the GIF columns on the end.
drop view if exists clubhouse_feed;
create view clubhouse_feed as
select
  cp.id, cp.kind, cp.title, cp.body, cp.price, cp.condition, cp.sold,
  cp.pinned, cp.created_at, cp.edited_at,
  p.id        as author_id,
  p.full_name as author_name,
  p.avatar_url,
  t.name      as team_name,
  t.slug      as team_slug,
  t.accent    as team_accent,
  t.crest     as team_crest,
  tt.name     as target_name,
  tt.accent   as target_accent,
  (select count(*) from post_replies r where r.post_id = cp.id) as reply_count,
  cp.gif_url, cp.gif_alt
from clubhouse_posts cp
join profiles p on p.id = cp.author_id
left join teams t  on t.id = cp.team_id
left join teams tt on tt.id = cp.target_team
order by cp.pinned desc, cp.created_at desc;
