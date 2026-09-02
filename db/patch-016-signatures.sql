-- ============================================================
--  PATCH 016 — signing in person
--  Apply after patch-015.
--
--  The remote path already works: the opposing team opens
--  verify.html on their own phone, signed in as themselves.
--  In practice they're standing next to you, so the useful
--  path is handing over your phone.
--
--  That means the person signing isn't the account that's
--  signed in. So instead of pretending they authenticated, we
--  record what actually happened: a named person from the other
--  team put their finger on the screen at this time, on this
--  device, next to this photo.
--
--  Weaker than an authenticated confirmation, and about the
--  same strength as the paper card it replaces.
-- ============================================================

alter table rounds
  add column attested_name      text,
  add column attested_signature text,
  add column attested_method    text
    check (attested_method in ('account','in_person','commissioner'));

comment on column rounds.attested_name is
  'Who signed. For an in-person signature this is the name they
   picked from the other team''s roster, not an account.';
comment on column rounds.attested_signature is
  'Object path in the signatures bucket.';
comment on column rounds.attested_method is
  'account = they signed in on their own phone.
   in_person = they signed on the submitting team''s phone.
   commissioner = no opposing team in the bay, so Chris did it.';

-- ------------------------------------------------------------
--  Signatures bucket. Private — a signature isn't something to
--  leave lying around publicly, and only the people involved
--  and the commissioner need to see it.
-- ------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('signatures','signatures', false, 262144, array['image/png'])
on conflict (id) do nothing;

create policy "upload signature"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'signatures');

create policy "read signatures"
  on storage.objects for select to authenticated
  using (bucket_id = 'signatures');

-- ------------------------------------------------------------
--  Signing in person.
--
--  Called by the submitting team's account, because it's their
--  phone. The guard is that they can only do it for their own
--  round, the signer must be a real name from the other team,
--  and a signature image is required.
-- ------------------------------------------------------------
create or replace function attest_in_person(
  p_round     uuid,
  p_name      text,
  p_signature text
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  r        rounds%rowtype;
  m        matches%rowtype;
  other_id uuid;
  ok       boolean;
begin
  if auth.uid() is null then
    raise exception 'Not signed in';
  end if;

  select * into r from rounds where id = p_round;
  if r.id is null then raise exception 'No such card'; end if;
  if r.status <> 'submitted' then
    raise exception 'That card is not waiting to be signed';
  end if;
  if r.team_id <> my_team() and not is_commissioner() then
    raise exception 'That is not your card';
  end if;
  if p_signature is null or p_name is null or btrim(p_name) = '' then
    raise exception 'A name and a signature are both needed';
  end if;

  select * into m from matches where id = r.match_id;
  other_id := case when m.home_team = r.team_id then m.away_team else m.home_team end;

  -- the name has to belong to somebody on the other team, or to
  -- the commissioner when there's nobody else in the bay
  select exists (
    select 1 from roster_spots rs
     where rs.team_id = other_id and lower(btrim(rs.full_name)) = lower(btrim(p_name))
    union all
    select 1 from profiles p
     where p.team_id = other_id and lower(btrim(p.full_name)) = lower(btrim(p_name))
    union all
    select 1 from profiles p
     where p.role = 'commissioner' and lower(btrim(p.full_name)) = lower(btrim(p_name))
  ) into ok;

  if not ok then
    raise exception 'That name is not on the other team';
  end if;

  update rounds
     set status             = 'confirmed',
         attested_name      = btrim(p_name),
         attested_signature = p_signature,
         attested_method    = case when other_id is null
                                   then 'commissioner' else 'in_person' end,
         attested_at        = now()
   where id = p_round;
end;
$$;

grant execute on function attest_in_person(uuid, text, text) to authenticated;

-- ------------------------------------------------------------
--  Who can sign a given card, for the hand-over screen.
--  The other team in the bay, or the commissioner if the bay
--  only had one team in it.
-- ------------------------------------------------------------
create or replace function signers_for(p_round uuid)
returns table (name text, role text)
language plpgsql
security definer
set search_path = public
as $$
declare
  r rounds%rowtype;
  m matches%rowtype;
  other_id uuid;
begin
  select * into r from rounds where id = p_round;
  if r.id is null then return; end if;
  select * into m from matches where id = r.match_id;
  other_id := case when m.home_team = r.team_id then m.away_team else m.home_team end;

  if other_id is not null then
    return query
      select rs.full_name, 'opponent'::text
        from roster_spots rs
       where rs.team_id = other_id
       order by rs.spot;
  end if;

  return query
    select p.full_name, 'commissioner'::text
      from profiles p
     where p.role = 'commissioner';
end;
$$;

grant execute on function signers_for(uuid) to authenticated;

-- ------------------------------------------------------------
--  The existing trigger stamps attested_by from auth.uid(),
--  which is wrong for an in-person signature — that's the
--  submitting team's account, not the signer's. Leave it null
--  in that case; attested_name is the record of who signed.
-- ------------------------------------------------------------
create or replace function guard_attestation() returns trigger
language plpgsql security definer as $$
begin
  if is_commissioner() then return new; end if;

  -- an in-person signature comes through attest_in_person,
  -- which sets attested_name; nothing to guard here
  if new.attested_name is not null
     and new.attested_name is distinct from old.attested_name then
    return new;
  end if;

  if new.team_id <> my_team() then
    if new.gross is distinct from old.gross
       or new.drives_used is distinct from old.drives_used then
      raise exception 'An opposing player cannot change the scorecard';
    end if;
    if new.status not in ('confirmed','disputed') then
      raise exception 'An opposing player can only confirm or dispute';
    end if;
    new.attested_by     := auth.uid();
    new.attested_at     := now();
    new.attested_method := 'account';
  end if;

  return new;
end;
$$;

-- ------------------------------------------------------------
--  Which cards carry which kind of signature.
--  An 'account' confirmation came from the opponent's own phone
--  signed in as themselves. An 'in_person' one is a signature
--  drawn on the submitting team's phone — worth being able to
--  see at a glance.
-- ------------------------------------------------------------
create or replace view attestations as
select
  r.id as round_id,
  m.week,
  m.played_on,
  t.name  as team_name,
  t.slug  as team_slug,
  r.status,
  r.attested_method,
  coalesce(r.attested_name, p.full_name) as signed_by,
  r.attested_at,
  r.attested_signature is not null as has_signature
from rounds r
join matches m on m.id = r.match_id
join teams   t on t.id = r.team_id
left join profiles p on p.id = r.attested_by
where r.status in ('confirmed','disputed')
order by m.played_on desc, t.name;
