-- ============================================================
--  PATCH 002 — photo archive + audit trail
--  Apply after patch-001.
--
--  Principle: evidence is append-only. A retake ADDS a photo,
--  a correction ADDS an audit row. Nothing overwrites history.
-- ============================================================

-- ------------------------------------------------------------
--  1. PHOTOS
--     Many per round. The newest is "current", the rest stay
--     for the archive. Nothing here is ever updated or deleted
--     by a player.
-- ------------------------------------------------------------
create table round_photos (
  id           uuid primary key default gen_random_uuid(),
  round_id     uuid not null references rounds on delete cascade,
  storage_path text not null,          -- object key in the 'scorecards' bucket
  uploaded_by  uuid not null references profiles,
  uploaded_at  timestamptz not null default now(),
  bytes        int,
  width        int,
  height       int,
  superseded   boolean not null default false,
  note         text                    -- e.g. 'retake, first was blurry'
);

create index on round_photos (round_id, uploaded_at desc);

-- When a new photo lands, mark the previous ones superseded
-- (but keep them).
create or replace function supersede_photos() returns trigger
language plpgsql as $$
begin
  update round_photos
     set superseded = true
   where round_id = new.round_id
     and id <> new.id;
  return new;
end;
$$;

create trigger photos_supersede
  after insert on round_photos
  for each row execute function supersede_photos();

-- Convenience: the photo currently backing each round.
create or replace view current_photos as
select distinct on (round_id)
  round_id, id as photo_id, storage_path, uploaded_by, uploaded_at
from round_photos
where superseded = false
order by round_id, uploaded_at desc;

-- Drop the old single-photo column once you've migrated.
-- Leave this commented until the app writes to round_photos.
-- alter table rounds drop column photo_path;

-- ------------------------------------------------------------
--  2. AUDIT TRAIL
--     Every score change, every status change, who and when.
--     This is what makes an attestation mean something later.
-- ------------------------------------------------------------
create table round_audit (
  id          bigserial primary key,
  round_id    uuid not null references rounds on delete cascade,
  actor_id    uuid references profiles,
  action      text not null,           -- 'created' | 'edited' | 'submitted'
                                       -- | 'confirmed' | 'disputed' | 'override'
  old_gross   smallint[],
  new_gross   smallint[],
  old_status  text,
  new_status  text,
  note        text,
  at          timestamptz not null default now()
);

create index on round_audit (round_id, at desc);

create or replace function log_round_change() returns trigger
language plpgsql security definer as $$
declare
  act text;
begin
  if TG_OP = 'INSERT' then
    insert into round_audit (round_id, actor_id, action, new_gross, new_status)
    values (new.id, auth.uid(), 'created', new.gross, new.status);
    return new;
  end if;

  act := case
    when new.status is distinct from old.status then new.status
    when new.gross  is distinct from old.gross  then 'edited'
    else null
  end;

  if act is not null then
    insert into round_audit (
      round_id, actor_id, action,
      old_gross, new_gross, old_status, new_status, note
    ) values (
      new.id, auth.uid(),
      case when is_commissioner() and new.team_id <> my_team()
           then 'override' else act end,
      old.gross, new.gross, old.status, new.status, new.dispute_note
    );
  end if;

  return new;
end;
$$;

create trigger rounds_audit_ins
  after insert on rounds
  for each row execute function log_round_change();

create trigger rounds_audit_upd
  after update on rounds
  for each row execute function log_round_change();

-- ------------------------------------------------------------
--  3. RLS
-- ------------------------------------------------------------
alter table round_photos enable row level security;
alter table round_audit  enable row level security;

-- Photos follow the same visibility as the round they belong to.
create policy read_photos on round_photos for select using (
  exists (
    select 1 from rounds r
    where r.id = round_photos.round_id
      and (r.status = 'confirmed'
           or r.team_id = my_team()
           or can_attest(r.id)
           or is_commissioner())
  )
);

-- Only the team that owns the round can add a photo.
create policy insert_photos on round_photos for insert with check (
  uploaded_by = auth.uid()
  and exists (
    select 1 from rounds r
    where r.id = round_photos.round_id and r.team_id = my_team()
  )
);

-- Nobody edits or deletes photos. Not even the commissioner
-- through the app — that's the point of an archive.
create policy admin_read_photos on round_photos for select
  using (is_commissioner());

-- Audit is read-only to everyone; only triggers write to it.
create policy read_audit on round_audit for select using (
  is_commissioner()
  or exists (
    select 1 from rounds r
    where r.id = round_audit.round_id
      and (r.team_id = my_team() or can_attest(r.id))
  )
);

-- ============================================================
--  4. STORAGE BUCKET
--     Run once. Private bucket — the app hands out short-lived
--     signed URLs rather than making photos world-readable.
--
--     Path convention:
--       scorecards/{season}/wk{week}/{match_id}/{team_id}/{ts}.jpg
--     Season and week in the path make yearly archiving trivial.
-- ============================================================
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'scorecards', 'scorecards', false,
  8388608,                                   -- 8 MB hard ceiling
  array['image/jpeg','image/png','image/webp']
)
on conflict (id) do nothing;

-- Upload: signed-in players only, into their own team's folder.
create policy "upload own scorecards"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'scorecards'
    and (storage.foldername(name))[5] = my_team()::text
  );

-- Read: anyone signed in can view (opponents need to check them,
-- and the archive is the point). Tighten to teams-involved-only
-- by joining rounds if you'd rather.
create policy "read scorecards"
  on storage.objects for select to authenticated
  using (bucket_id = 'scorecards');

-- No update, no delete policies. Absence of a policy = denied.
-- Photos can only be removed by you in the Supabase dashboard.
