-- ============================================================
--  PATCH 011 — let the look columns take the full set
--  Apply after patch-010.
--
--  typeface and backdrop were pinned to the six fonts and nine
--  patterns that existed when the columns were created. There
--  are now 21 and 24, and the list lives in data/looks.json so
--  it can grow without a migration.
--
--  Dropping the enum check rather than restating it: the editor
--  only ever offers what's in looks.json, and a wrong value
--  degrades to the default rather than breaking anything.
-- ============================================================

alter table teams drop constraint if exists teams_typeface_check;
alter table teams drop constraint if exists teams_backdrop_check;

-- keep the shape, lose the fixed list
alter table teams
  alter column typeface set default 'archivo',
  alter column backdrop set default 'none';

comment on column teams.typeface is
  'Key from data/looks.json typefaces. Unknown values fall back
   to archivo when the page is generated.';

comment on column teams.backdrop is
  'Key from data/looks.json patterns. Unknown values render as
   no pattern.';

-- Backdrop mode is a genuinely fixed set, so that one stays.
-- Colours stay validated as hex, which catches typos without
-- limiting the palette.
