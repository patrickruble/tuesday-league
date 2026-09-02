-- ============================================================
--  PATCH 028 — the other team signs, Chris steps in
--  Apply after patch-027.
--
--  Normal course: the team beside you confirms the card. When
--  they've gone home, or won't, or there's nobody in the bay,
--  Chris confirms it himself. He can always do that — it's the
--  fallback, not the routine.
-- ============================================================

-- Patch 023 introduced these. If that migration didn't land,
-- add them here rather than failing.
alter table league_settings
  add column if not exists require_signoff boolean not null default true,
  add column if not exists draw_public_at  time    not null default '11:00',
  add column if not exists instagram       text,
  add column if not exists media_note      text,
  add column if not exists mulligans_allowed smallint;

alter table league_settings
  alter column require_signoff set default true;

update league_settings set require_signoff = true where id = 1;

-- ------------------------------------------------------------
--  The draw gate, also from patch 023, restated so it exists
--  either way.
-- ------------------------------------------------------------
create or replace function draw_is_public(p_played_on date)
returns boolean
language sql
stable
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

drop policy if exists read_week_settings on week_settings;
create policy read_week_settings on week_settings for select using (
  is_commissioner()
  or exists (
    select 1 from matches m
     where m.week = week_settings.week and draw_is_public(m.played_on)
  )
);

comment on column league_settings.require_signoff is
  'A card waits for the other team in the bay. The commissioner
   can confirm anything at any time regardless — this only
   governs whether a card counts before someone signs it.';

-- ------------------------------------------------------------
--  The fallback, as one call rather than a raw update, so the
--  reason is recorded rather than inferred.
-- ------------------------------------------------------------
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

-- ------------------------------------------------------------
--  How long a card has been sitting, so the dashboard can say
--  which ones have been waiting long enough to step in on.
-- ------------------------------------------------------------
create or replace view waiting_cards as
select
  r.id,
  m.week,
  m.played_on,
  m.bay,
  t.name  as team_name,
  t.slug  as team_slug,
  t.accent,
  o.name  as waiting_on,
  r.submitted_at,
  round(extract(epoch from (now() - r.submitted_at)) / 3600.0, 1) as hours_waiting
from rounds r
join matches m on m.id = r.match_id
join teams   t on t.id = r.team_id
left join teams o on o.id = case when m.home_team = r.team_id
                                 then m.away_team else m.home_team end
where r.status = 'submitted'
order by r.submitted_at;
