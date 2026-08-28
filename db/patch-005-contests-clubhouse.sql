-- ============================================================
--  PATCH 005 — contest kinds, clubhouse feed
--  Apply after patch-004.
-- ============================================================

-- ------------------------------------------------------------
--  1. SIDE CONTESTS — the three you actually run
--     Closest to the pin, long putt, chip in from off the green.
-- ------------------------------------------------------------
alter table side_contests drop constraint side_contests_kind_check;
alter table side_contests add constraint side_contests_kind_check
  check (kind in ('ctp','long_putt','chip_in','ace'));

-- chip-ins are counted, not measured, so value/unit can be null
comment on column side_contests.value is
  'Distance for ctp and long_putt. Null for chip_in — it either went in or it did not.';

-- Retire the long drive badges, add the chip-in family.
delete from badges where family = 'bomber';

insert into badges (slug, name, blurb, family, tier, scope, metric, threshold, accent, sort) values
  ('houdini-1','Houdini','Two chip-ins from off the green.','houdini',1,'player','chip_in_wins',2,'#C2410C',30),
  ('houdini-2','Houdini II','Five chip-ins. From anywhere.','houdini',2,'player','chip_in_wins',5,'#C2410C',31),
  ('houdini-3','Houdini III','Eight chip-ins. Nobody believes you.','houdini',3,'player','chip_in_wins',8,'#B8860B',32);

-- Metrics view picks up the new kind.
create or replace view player_metrics as
select
  p.id as profile_id,
  count(*) filter (where sc.kind = 'ctp')       as ctp_wins,
  count(*) filter (where sc.kind = 'long_putt') as long_putt_wins,
  count(*) filter (where sc.kind = 'chip_in')   as chip_in_wins,
  count(*) filter (where sc.kind = 'ace')       as aces,
  coalesce((
    select sum((r.drives_used ->> p.id::text)::int)
    from rounds r
    where r.team_id = p.team_id and r.status = 'confirmed'
      and r.drives_used ? p.id::text
  ), 0) as drives_used,
  coalesce((
    select count(*) from availability a
    where a.profile_id = p.id and a.status = 'in'
  ), 0) as weeks_in
from profiles p
left join side_contests sc on sc.winner_id = p.id
group by p.id, p.team_id;

-- Season leaders per contest, for the records page.
create or replace view contest_leaders as
select
  sc.kind,
  p.id            as profile_id,
  p.full_name,
  t.name          as team_name,
  t.accent,
  count(*)        as wins,
  min(sc.value) filter (where sc.kind = 'ctp')       as best_ctp,
  max(sc.value) filter (where sc.kind = 'long_putt') as best_putt
from side_contests sc
join profiles p on p.id = sc.winner_id
left join teams t on t.id = p.team_id
group by sc.kind, p.id, p.full_name, t.name, t.accent
order by sc.kind, wins desc;

-- ------------------------------------------------------------
--  2. CLUBHOUSE
--     One feed, many kinds. Separate tabs for trash talk, a
--     marketplace and announcements would each sit near-empty
--     with 42 people; together they make a feed worth opening.
-- ------------------------------------------------------------
create table clubhouse_posts (
  id           uuid primary key default gen_random_uuid(),
  author_id    uuid not null references profiles on delete cascade,
  team_id      uuid references teams on delete set null,

  kind         text not null check (kind in
                 ('talk','for_sale','wanted','sub_needed',
                  'question','announcement','brag')),

  title        text,
  body         text not null check (char_length(body) between 1 and 2000),

  -- for_sale / wanted
  price        numeric(8,2),
  condition    text check (condition in ('new','like_new','good','beat_up')),
  sold         boolean not null default false,

  -- talk aimed at a particular team
  target_team  uuid references teams on delete set null,

  -- sub_needed
  match_id     uuid references matches on delete cascade,

  pinned       boolean not null default false,
  created_at   timestamptz not null default now(),
  edited_at    timestamptz
);

create index on clubhouse_posts (created_at desc);
create index on clubhouse_posts (kind, created_at desc);

create table post_replies (
  id         uuid primary key default gen_random_uuid(),
  post_id    uuid not null references clubhouse_posts on delete cascade,
  author_id  uuid not null references profiles on delete cascade,
  body       text not null check (char_length(body) between 1 and 1000),
  created_at timestamptz not null default now()
);

create index on post_replies (post_id, created_at);

-- Move the old trash talk in, then retire that table.
insert into clubhouse_posts (author_id, team_id, kind, body, target_team, created_at)
select author_id, from_team, 'talk', body, to_team, created_at
from trash_talk
on conflict do nothing;

drop table if exists trash_talk;

-- ------------------------------------------------------------
--  3. RLS
-- ------------------------------------------------------------
alter table clubhouse_posts enable row level security;
alter table post_replies    enable row level security;

create policy read_posts   on clubhouse_posts for select using (true);
create policy read_replies on post_replies    for select using (true);

create policy write_post on clubhouse_posts for insert
  with check (author_id = auth.uid());

create policy edit_own_post on clubhouse_posts for update
  using (author_id = auth.uid()) with check (author_id = auth.uid());

create policy delete_own_post on clubhouse_posts for delete
  using (author_id = auth.uid());

create policy write_reply on post_replies for insert
  with check (author_id = auth.uid());

create policy delete_own_reply on post_replies for delete
  using (author_id = auth.uid());

create policy admin_posts   on clubhouse_posts for all using (is_commissioner());
create policy admin_replies on post_replies    for all using (is_commissioner());

-- ------------------------------------------------------------
--  4. FEED VIEW — everything the page needs in one query
-- ------------------------------------------------------------
create or replace view clubhouse_feed as
select
  cp.id, cp.kind, cp.title, cp.body, cp.price, cp.condition, cp.sold,
  cp.pinned, cp.created_at, cp.edited_at,
  p.id            as author_id,
  p.full_name     as author_name,
  t.name          as team_name,
  t.slug          as team_slug,
  t.accent        as team_accent,
  t.crest         as team_crest,
  tt.name         as target_name,
  tt.accent       as target_accent,
  (select count(*) from post_replies r where r.post_id = cp.id) as reply_count
from clubhouse_posts cp
join profiles p on p.id = cp.author_id
left join teams t  on t.id = cp.team_id
left join teams tt on tt.id = cp.target_team
order by cp.pinned desc, cp.created_at desc;
