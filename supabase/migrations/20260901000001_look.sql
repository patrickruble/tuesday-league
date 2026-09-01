-- ============================================================
--  PATCH 004 — per-team typeface and background
--  Apply after patch-003.
-- ============================================================

alter table teams
  add column typeface  text not null default 'archivo'
    check (typeface in ('archivo','anton','dm-serif','space-mono','bungee','blackletter')),
  add column backdrop  text not null default 'none'
    check (backdrop in ('none','argyle','plaid','pinstripe','dots',
                        'grid','diagonal','check','turf'));

comment on column teams.typeface is
  'Display face for the team name, crest and headings. Body text is fixed
   league-wide so pages stay readable.';

comment on column teams.backdrop is
  'CSS pattern name. Patterns are generated from gradients and tinted with
   the team accent, so there are no image assets to host.';

-- A team can change its own look; nobody else can.
-- (Covered by the existing update_own_team policy.)
