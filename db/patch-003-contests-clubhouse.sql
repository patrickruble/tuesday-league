-- ============================================================
--  PATCH 003 — contests, head-to-head, standings, clubhouse
--  Apply after patch-002.
--
--  Replaces the earlier 003/004/005 files. RSVP, badges and
--  playoff odds are deliberately left out — they come later
--  and nothing here depends on them.
-- ============================================================

-- ------------------------------------------------------------
--  1. SIDE CONTESTS
--     Closest to the pin, long putt, chip in from off the green.
--     Value is a distance for the first two; a chip-in either
--     went in or it did not.
-- ------------------------------------------------------------
create table side_contests (
  id          uuid primary key default gen_random_uuid(),
  match_id    uuid not null references matches on delete cascade,
  kind        text not null check (kind in ('ctp','long_putt','chip_in','ace')),
  hole        smallint check (hole between 1 and 9),
  winner_id   uuid references profiles on delete set null,
  team_id     uuid references teams on delete set null,
  value       numeric(6,2),
  unit        text check (unit in ('ft','in','yds','m')),
  recorded_by uuid references profiles,
  recorded_at timestamptz not null default now(),
  unique (match_id, kind, hole)
);

create index on side_contests (winner_id, kind);
create index on side_contests (team_id, kind);

alter table side_contests enable row level security;

create policy read_contests on side_contests for select using (true);

create policy record_contests on side_contests for insert with check (
  exists (
    select 1 from matches m
    where m.id = match_id and my_team() in (m.home_team, m.away_team)
  )
);

create policy admin_contests on side_contests for all using (is_commissioner());

-- Season leaders. Individual winner is recorded for the record
-- book; team_id is what any future team badge would count.
create or replace view contest_leaders as
select
  sc.kind,
  p.id       as profile_id,
  p.full_name,
  t.id       as team_id,
  t.name     as team_name,
  t.accent,
  count(*)   as wins,
  min(sc.value) filter (where sc.kind = 'ctp')       as best_ctp,
  max(sc.value) filter (where sc.kind = 'long_putt') as best_putt
from side_contests sc
left join profiles p on p.id = sc.winner_id
left join teams    t on t.id = coalesce(sc.team_id, p.team_id)
group by sc.kind, p.id, p.full_name, t.id, t.name, t.accent
order by sc.kind, wins desc;

-- ------------------------------------------------------------
--  2. STANDINGS
--     Points per round alongside the total, so a team with a
--     missed week isn't unfairly buried.
-- ------------------------------------------------------------
create or replace view standings as
with scored as (
  select
    rs.team_id,
    rs.week,
    rs.total_points,
    opp.total_points as opp_points
  from round_scores rs
  left join round_scores opp
         on opp.match_id = rs.match_id
        and opp.team_id  <> rs.team_id
        and opp.status = 'confirmed'
  where rs.status = 'confirmed'
)
select
  t.id                             as team_id,
  t.slug, t.name, t.crest, t.accent, t.mood, t.mood_at,
  count(s.week)                    as played,
  coalesce(sum(s.total_points), 0) as points,
  round(avg(s.total_points), 1)    as ppr,
  count(*) filter (where s.total_points > s.opp_points) as won,
  count(*) filter (where s.total_points < s.opp_points) as lost,
  count(*) filter (where s.total_points = s.opp_points) as tied,
  max(s.total_points)              as best_round
from teams t
left join scored s on s.team_id = t.id
group by t.id, t.slug, t.name, t.crest, t.accent, t.mood, t.mood_at
order by points desc, best_round desc;

-- ------------------------------------------------------------
--  3. HEAD TO HEAD
--     Both directions of every pairing. Feeds the "0–4 vs Night
--     Shift" line next to the upcoming opponent.
-- ------------------------------------------------------------
create or replace view head_to_head as
select
  a.team_id                                              as team_id,
  b.team_id                                              as opponent_id,
  count(*)                                               as meetings,
  count(*) filter (where a.total_points > b.total_points) as won,
  count(*) filter (where a.total_points < b.total_points) as lost,
  count(*) filter (where a.total_points = b.total_points) as tied,
  round(avg(a.total_points), 1)                          as avg_for,
  round(avg(b.total_points), 1)                          as avg_against,
  max(a.played_on)                                       as last_met
from round_scores a
join round_scores b
  on b.match_id = a.match_id and b.team_id <> a.team_id
where a.status = 'confirmed' and b.status = 'confirmed'
group by a.team_id, b.team_id;

-- ------------------------------------------------------------
--  4. SCORING DETAIL — per-round eagle and birdie counts
-- ------------------------------------------------------------
create or replace view eagle_counts as
select
  rs.team_id, rs.week, rs.played_on,
  count(*) filter (where p.pt = 3) as eagles,
  count(*) filter (where p.pt = 2) as birdies,
  count(*) filter (where p.pt = 0) as blanks
from round_scores rs,
     lateral unnest(rs.points) as p(pt)
where rs.status = 'confirmed'
group by rs.team_id, rs.week, rs.played_on;

-- ------------------------------------------------------------
--  5. LEAGUE PLAYLIST
-- ------------------------------------------------------------
create or replace view league_playlist as
select
  t.slug, t.name, t.accent, t.crest,
  t.song_title, t.song_artist, t.song_provider, t.song_id
from teams t
where t.song_id is not null
order by t.name;

-- ------------------------------------------------------------
--  6. CLUBHOUSE
--     One feed, many kinds. Separate tabs for talk, gear and
--     announcements would each sit near-empty with 42 people.
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

  price        numeric(8,2),
  condition    text check (condition in ('new','like_new','good','beat_up')),
  sold         boolean not null default false,

  target_team  uuid references teams on delete set null,
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

-- Fold the old trash talk in, then retire that table.
insert into clubhouse_posts (author_id, team_id, kind, body, target_team, created_at)
select author_id, from_team, 'talk', body, to_team, created_at
from trash_talk;

drop table if exists trash_talk;

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

-- Everything the feed page needs, in one query.
create or replace view clubhouse_feed as
select
  cp.id, cp.kind, cp.title, cp.body, cp.price, cp.condition, cp.sold,
  cp.pinned, cp.created_at, cp.edited_at,
  p.id        as author_id,
  p.full_name as author_name,
  t.name      as team_name,
  t.slug      as team_slug,
  t.accent    as team_accent,
  t.crest     as team_crest,
  tt.name     as target_name,
  tt.accent   as target_accent,
  (select count(*) from post_replies r where r.post_id = cp.id) as reply_count
from clubhouse_posts cp
join profiles p on p.id = cp.author_id
left join teams t  on t.id = cp.team_id
left join teams tt on tt.id = cp.target_team
order by cp.pinned desc, cp.created_at desc;

-- ------------------------------------------------------------
--  7. MOOD — constrain to the picker's list
--     Free text became a dropdown, so the column should agree.
--     Adding a mood later is one line here.
-- ------------------------------------------------------------
create table moods (
  word      text primary key,
  sentiment text not null check (sentiment in ('hot','good','cold','bad','odd')),
  sort      smallint not null default 100
);

alter table moods enable row level security;
create policy read_moods  on moods for select using (true);
create policy admin_moods on moods for all using (is_commissioner());

insert into moods (word, sentiment, sort) values
  ('striping it','hot',1),('dialed','hot',2),('pured','hot',3),
  ('due','hot',4),('streaky','hot',5),('grinding','hot',6),
  ('rusty','cold',10),('shanking','cold',11),('chunking it','cold',12),
  ('lipping out','cold',13),('gassed','cold',14),('wristy','cold',15),
  ('sandbagging','odd',20),('suspicious','odd',21),

  ('accomplished','good',30),('amped','good',31),('blissful','good',32),
  ('bouncy','good',33),('chipper','good',34),('content','good',35),
  ('ecstatic','good',36),('giddy','good',37),('grateful','good',38),
  ('hopeful','good',39),('jubilant','good',40),('optimistic','good',41),
  ('relaxed','good',42),('relieved','good',43),('smug','good',44),

  ('aggravated','bad',50),('annoyed','bad',51),('bitter','bad',52),
  ('blah','bad',53),('cranky','bad',54),('crushed','bad',55),
  ('defeated','bad',56),('deflated','bad',57),('gloomy','bad',58),
  ('grumpy','bad',59),('irate','bad',60),('jealous','bad',61),
  ('moody','bad',62),('salty','bad',63),('sore','bad',64),('tilted','bad',65),

  ('bewildered','odd',70),('confused','odd',71),('devious','odd',72),
  ('dorky','odd',73),('feral','odd',74),('geeky','odd',75),
  ('indescribable','odd',76),('mischievous','odd',77),('ominous','odd',78),
  ('quixotic','odd',79),('restless','odd',80),('sneaky','odd',81),
  ('unhinged','odd',82),('weird','odd',83);

alter table teams
  add constraint teams_mood_fk foreign key (mood) references moods(word);

-- Optional: keep a history so "tilted for three weeks" is visible.
create table mood_history (
  id       bigserial primary key,
  team_id  uuid not null references teams on delete cascade,
  word     text not null references moods(word),
  set_by   uuid references profiles,
  set_at   timestamptz not null default now()
);

create index on mood_history (team_id, set_at desc);

alter table mood_history enable row level security;
create policy read_mood_history on mood_history for select using (true);

create or replace function log_mood() returns trigger
language plpgsql security definer as $$
begin
  if new.mood is distinct from old.mood and new.mood is not null then
    insert into mood_history (team_id, word, set_by)
    values (new.id, new.mood, auth.uid());
  end if;
  return new;
end;
$$;

create trigger teams_log_mood
  after update on teams
  for each row execute function log_mood();
