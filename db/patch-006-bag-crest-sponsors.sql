-- ============================================================
--  PATCH 006 — bag, crests, sponsors, scrapbook
--  Apply after patch-005.
-- ============================================================

-- ------------------------------------------------------------
--  1. WHAT'S IN THE BAG
--     Golfers list their setup unprompted, which makes this one
--     of the few features that fills itself in. It also feeds
--     the classifieds: someone sees your 3-wood, asks about it,
--     you flip `for_sale` and it shows up in the clubhouse.
-- ------------------------------------------------------------
create table bag_items (
  id         uuid primary key default gen_random_uuid(),
  profile_id uuid not null references profiles on delete cascade,

  category   text not null check (category in
                ('driver','wood','hybrid','iron','wedge','putter','ball','bag','other')),
  brand      text,
  model      text not null,
  spec       text,                       -- loft, shaft, flex, whatever
  year       smallint,
  note       text,

  for_sale   boolean not null default false,
  asking     numeric(8,2),

  sort       smallint not null default 100,
  created_at timestamptz not null default now()
);

create index on bag_items (profile_id, sort);
create index on bag_items (for_sale) where for_sale;

alter table bag_items enable row level security;
create policy read_bag  on bag_items for select using (true);
create policy own_bag   on bag_items for all
  using (profile_id = auth.uid()) with check (profile_id = auth.uid());
create policy admin_bag on bag_items for all using (is_commissioner());

-- Anything up for sale, ready for the clubhouse feed.
create or replace view bag_for_sale as
select
  b.id, b.category, b.brand, b.model, b.spec, b.asking, b.note,
  p.id as profile_id, p.full_name,
  t.name as team_name, t.slug as team_slug, t.accent
from bag_items b
join profiles p on p.id = b.profile_id
left join teams t on t.id = p.team_id
where b.for_sale
order by b.created_at desc;

-- ------------------------------------------------------------
--  2. TEAM CRESTS
--     Monogram tiles stay as the fallback — a team that uploads
--     nothing still looks deliberate rather than broken.
-- ------------------------------------------------------------
alter table teams add column crest_url text;

comment on column teams.crest_url is
  'Object path in the crests bucket. Null means fall back to the
   two-letter monogram.';

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('crests','crests', true, 2097152,
        array['image/png','image/jpeg','image/webp','image/svg+xml'])
on conflict (id) do nothing;

-- Crests are public: they appear on the leaderboard, which needs
-- no login. Upload is restricted to the team that owns them.
create policy "read crests"
  on storage.objects for select
  using (bucket_id = 'crests');

create policy "upload own crest"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'crests'
    and (storage.foldername(name))[1] = my_team()::text
  );

create policy "replace own crest"
  on storage.objects for update to authenticated
  using (
    bucket_id = 'crests'
    and (storage.foldername(name))[1] = my_team()::text
  );

-- ------------------------------------------------------------
--  3. SPONSORS
--     A local shop paying for a footer slot is real money for
--     the league. Kept as data so Chris can add one without a
--     deploy.
-- ------------------------------------------------------------
create table sponsors (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  blurb      text,
  url        text,
  logo_url   text,
  tier       text not null default 'supporter'
             check (tier in ('title','bay','supporter')),
  bay        smallint check (bay between 1 and 8),   -- for bay-specific slots
  active     boolean not null default true,
  starts_on  date,
  ends_on    date,
  sort       smallint not null default 100
);

alter table sponsors enable row level security;
create policy read_sponsors  on sponsors for select using (active);
create policy admin_sponsors on sponsors for all using (is_commissioner());

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('sponsors','sponsors', true, 2097152,
        array['image/png','image/jpeg','image/webp','image/svg+xml'])
on conflict (id) do nothing;

create policy "read sponsor logos"
  on storage.objects for select using (bucket_id = 'sponsors');

create policy "admin sponsor logos"
  on storage.objects for all to authenticated
  using (bucket_id = 'sponsors' and is_commissioner());

-- ------------------------------------------------------------
--  4. SCRAPBOOK
--     The photo archive already exists. This just makes it
--     browsable, and lets people caption a shot after the fact.
-- ------------------------------------------------------------
alter table round_photos add column caption text;

create or replace view scrapbook as
select
  rp.id,
  rp.storage_path,
  rp.caption,
  rp.uploaded_at,
  m.week,
  m.played_on,
  c.name  as course_name,
  c.nine,
  t.id    as team_id,
  t.name  as team_name,
  t.slug  as team_slug,
  t.accent,
  t.crest,
  p.full_name as uploaded_by
from round_photos rp
join rounds   r on r.id = rp.round_id
join matches  m on m.id = r.match_id
join courses  c on c.id = m.course_id
join teams    t on t.id = r.team_id
left join profiles p on p.id = rp.uploaded_by
where r.status = 'confirmed'
order by m.played_on desc, rp.uploaded_at desc;

-- Captions: your own team's photos only.
create policy caption_own_photos on round_photos for update
  using (
    exists (select 1 from rounds r
            where r.id = round_photos.round_id and r.team_id = my_team())
  );

-- ------------------------------------------------------------
--  5. MOOD HISTORY — the display side
--     The trigger from patch-003 already logs every change.
--     This works out how long the current mood has been running,
--     which is the funny part.
-- ------------------------------------------------------------
create or replace view mood_runs as
with h as (
  select
    team_id, word, set_at,
    lead(set_at) over (partition by team_id order by set_at) as ended_at
  from mood_history
)
select
  h.team_id,
  t.name as team_name,
  t.slug,
  t.accent,
  h.word,
  m.sentiment,
  h.set_at,
  coalesce(h.ended_at, now()) as ended_at,
  extract(day from coalesce(h.ended_at, now()) - h.set_at)::int as days,
  (h.ended_at is null) as current
from h
join teams t on t.id = h.team_id
left join moods m on m.word = h.word
order by h.team_id, h.set_at desc;

-- How long has each team been in its current mood?
create or replace view current_mood as
select team_id, team_name, slug, accent, word, sentiment, set_at, days
from mood_runs
where current;
