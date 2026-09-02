-- ============================================================
--  CATCH-UP — 014, 015, 019 and 028 in one
--
--  Three migrations never reached the migrations folder, so the
--  database is missing week_settings, the draw gate and the
--  media queue. Everything here is safe to run twice.
--
--  Replaces: 20260902000014, 15, 19, 20
-- ============================================================


-- ============================================================
--  FROM 014 — week settings and contests
-- ============================================================

create table if not exists week_settings (
  week            smallint primary key,
  ctp_hole        smallint check (ctp_hole between 1 and 9),
  long_putt_hole  smallint check (long_putt_hole between 1 and 9),
  chip_in_any     boolean not null default true,
  note            text
);

alter table week_settings enable row level security;

drop policy if exists read_week_settings  on week_settings;
drop policy if exists admin_week_settings on week_settings;
create policy admin_week_settings on week_settings for all using (is_commissioner());

create or replace view contest_winners as
with entries as (
  select
    m.week, sc.kind, sc.hole, sc.value, sc.unit,
    p.id as profile_id, p.full_name,
    t.id as team_id, t.name as team_name, t.slug as team_slug, t.accent,
    m.bay
  from side_contests sc
  join matches m on m.id = sc.match_id
  left join profiles p on p.id = sc.winner_id
  left join teams    t on t.id = coalesce(sc.team_id, p.team_id)
)
select distinct on (week, kind)
  week, kind, hole, value, unit,
  profile_id, full_name, team_id, team_name, team_slug, accent, bay
from entries
order by
  week, kind,
  case when kind = 'ctp'       then value end asc  nulls last,
  case when kind = 'long_putt' then value end desc nulls last,
  value nulls last;

create or replace view contest_entries as
select
  m.week, m.bay, sc.id, sc.kind, sc.hole, sc.value, sc.unit,
  p.full_name, t.name as team_name, t.slug as team_slug, t.accent,
  sc.recorded_at
from side_contests sc
join matches m on m.id = sc.match_id
left join profiles p on p.id = sc.winner_id
left join teams    t on t.id = coalesce(sc.team_id, p.team_id)
order by m.week desc, sc.kind, m.bay;

create or replace function players_in_bay(p_match uuid)
returns table (id uuid, full_name text, team_id uuid, team_name text, accent text)
language sql
security definer
set search_path = public
as $$
  select p.id, p.full_name, t.id, t.name, t.accent
    from matches m
    join teams t on t.id in (m.home_team, m.away_team)
    join profiles p on p.team_id = t.id
   where m.id = p_match
   order by t.name, p.full_name;
$$;

grant execute on function players_in_bay(uuid) to authenticated;


-- ============================================================
--  FROM 015 and 028 — settings, sign-off and the draw gate
-- ============================================================

alter table league_settings
  add column if not exists require_signoff   boolean not null default true,
  add column if not exists draw_public_at    time    not null default '11:00',
  add column if not exists instagram         text,
  add column if not exists media_note        text,
  add column if not exists mulligans_allowed smallint;

alter table league_settings alter column require_signoff set default true;
update league_settings set require_signoff = true where id = 1;

create or replace function draw_is_public(p_played_on date)
returns boolean
language sql stable
as $$
  select (p_played_on + coalesce(
            (select draw_public_at from league_settings where id = 1),
            time '11:00'))
         <= timezone('America/Chicago', now())::timestamp;
$$;

drop policy if exists read_matches on matches;
create policy read_matches on matches for select using (
  is_commissioner()
  or draw_is_public(played_on)
  or my_team() in (home_team, away_team)
);

-- now that draw_is_public exists, the week_settings read policy
create policy read_week_settings on week_settings for select using (
  is_commissioner()
  or exists (
    select 1 from matches m
     where m.week = week_settings.week and draw_is_public(m.played_on)
  )
);

-- submitting waits for a signature again
create or replace function stamp_submission()
returns trigger
language plpgsql
security definer
as $$
declare
  need boolean;
begin
  if new.status = 'submitted' and old.status is distinct from 'submitted' then

    if not exists (
      select 1 from round_photos where round_id = new.id and not superseded
    ) then
      raise exception 'A photo of the screen is needed before submitting';
    end if;

    if new.gross is null or array_length(new.gross,1) <> 9
       or exists (select 1 from unnest(new.gross) g where g is null) then
      raise exception 'All nine holes need a score';
    end if;

    new.submitted_by := auth.uid();
    new.submitted_at := now();

    select require_signoff into need from league_settings where id = 1;
    if not coalesce(need, true) then
      new.status          := 'confirmed';
      new.attested_method := 'commissioner';
      new.attested_at     := now();
    end if;
  end if;

  return new;
end;
$$;

create or replace function confirm_as_commissioner(p_round uuid, p_why text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  r rounds%rowtype;
begin
  if not is_commissioner() then
    raise exception 'Only the commissioner can do that';
  end if;

  select * into r from rounds where id = p_round;
  if r.id is null then raise exception 'No such card'; end if;
  if r.status = 'confirmed' then return; end if;

  update rounds
     set status          = 'confirmed',
         attested_by     = auth.uid(),
         attested_at     = now(),
         attested_method = 'commissioner',
         attested_name   = coalesce(
                             (select full_name from profiles where id = auth.uid()),
                             'Commissioner'),
         dispute_note    = coalesce(p_why, dispute_note)
   where id = p_round;
end;
$$;

grant execute on function confirm_as_commissioner(uuid, text) to authenticated;

create or replace view waiting_cards as
select
  r.id, m.week, m.played_on, m.bay,
  t.name as team_name, t.slug as team_slug, t.accent,
  o.name as waiting_on,
  r.submitted_at,
  round(extract(epoch from (now() - r.submitted_at)) / 3600.0, 1) as hours_waiting
from rounds r
join matches m on m.id = r.match_id
join teams   t on t.id = r.team_id
left join teams o on o.id = case when m.home_team = r.team_id
                                 then m.away_team else m.home_team end
where r.status = 'submitted'
order by r.submitted_at;

create or replace view last_bays as
select distinct on (t.id)
  t.id as team_id, t.name as team_name, m.bay, m.week
from teams t
join matches m on t.id in (m.home_team, m.away_team)
order by t.id, m.week desc;


-- ============================================================
--  FROM 019 — the media queue
-- ============================================================

create table if not exists media_submissions (
  id           uuid primary key default gen_random_uuid(),
  sent_by      uuid not null references profiles on delete cascade,
  team_id      uuid references teams on delete set null,
  storage_path text not null,
  kind         text not null check (kind in ('photo','video')),
  bytes        int,
  caption      text check (char_length(caption) <= 400),
  status       text not null default 'new' check (status in ('new','posted','passed')),
  handled_by   uuid references profiles,
  handled_at   timestamptz,
  created_at   timestamptz not null default now()
);

create index if not exists media_submissions_status_idx
  on media_submissions (status, created_at desc);
create index if not exists media_submissions_sender_idx
  on media_submissions (sent_by);

alter table media_submissions enable row level security;

drop policy if exists read_media   on media_submissions;
drop policy if exists send_media   on media_submissions;
drop policy if exists unsend_media on media_submissions;
drop policy if exists admin_media  on media_submissions;

create policy read_media on media_submissions for select using (
  status = 'posted' or sent_by = auth.uid() or is_commissioner()
);
create policy send_media on media_submissions for insert to authenticated
  with check (sent_by = auth.uid());
create policy unsend_media on media_submissions for delete
  using (sent_by = auth.uid() and status = 'new');
create policy admin_media on media_submissions for all using (is_commissioner());

create or replace function guard_media_status()
returns trigger
language plpgsql security definer
as $$
begin
  if new.status is distinct from old.status then
    if not is_commissioner() then
      raise exception 'Only the commissioner handles these';
    end if;
    new.handled_by := auth.uid();
    new.handled_at := now();
  end if;
  return new;
end;
$$;

drop trigger if exists media_guard_status on media_submissions;
create trigger media_guard_status
  before update on media_submissions
  for each row execute function guard_media_status();

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('media','media', true, 41943040,
        array['image/png','image/jpeg','image/webp','image/heic',
              'video/mp4','video/quicktime','video/webm'])
on conflict (id) do update
  set file_size_limit    = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "read media"   on storage.objects;
drop policy if exists "send media"   on storage.objects;
drop policy if exists "unsend media" on storage.objects;

create policy "read media" on storage.objects for select
  using (bucket_id = 'media');
create policy "send media" on storage.objects for insert to authenticated
  with check (bucket_id = 'media' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "unsend media" on storage.objects for delete to authenticated
  using (bucket_id = 'media' and (storage.foldername(name))[1] = auth.uid()::text);

create or replace view media_feed as
select
  ms.id, ms.storage_path, ms.kind, ms.caption, ms.status, ms.created_at,
  p.full_name as sent_by_name,
  t.name as team_name, t.slug as team_slug, t.accent
from media_submissions ms
join profiles p on p.id = ms.sent_by
left join teams t on t.id = ms.team_id
order by ms.created_at desc;

create or replace view media_usage as
select
  count(*)                                      as items,
  count(*) filter (where kind = 'video')        as videos,
  coalesce(sum(bytes), 0)                       as bytes,
  round(coalesce(sum(bytes), 0) / 1048576.0, 1) as megabytes
from media_submissions;
