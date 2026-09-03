-- ============================================================
--  PATCH 035 — faces in the clubhouse
--  Apply after patch-034.
--
--  The feed was built before avatars existed, so it only ever
--  had a name to work with and fell back to initials for
--  everyone.
-- ============================================================

drop view if exists clubhouse_feed;

create view clubhouse_feed as
select
  cp.id,
  cp.kind,
  cp.body,
  cp.gif_url,
  cp.gif_alt,
  cp.price,
  cp.pinned,
  cp.created_at,
  cp.author_id,
  p.full_name  as author_name,
  p.avatar_url as author_avatar,
  t.id         as team_id,
  t.name       as team_name,
  t.slug       as team_slug,
  t.accent,
  t.crest,
  (select count(*) from post_replies r where r.post_id = cp.id) as replies
from clubhouse_posts cp
join profiles p on p.id = cp.author_id
left join teams t on t.id = p.team_id
order by cp.pinned desc, cp.created_at desc;
