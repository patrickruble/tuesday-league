-- ============================================================
--  PATCH 039 — the long putt is any hole
--  Apply after patch-037.
--
--  Closest to the pin is a nominated hole. The long putt isn't
--  — it's the longest one anybody holes all night, wherever it
--  happens. Same as the chip-in.
-- ============================================================

alter table week_settings
  add column if not exists long_putt_any boolean not null default true;

comment on column week_settings.long_putt_any is
  'True means the long putt counts from any hole, which is the
   normal way of it. Setting long_putt_hole pins it to one hole
   instead.';

-- Anything already pinned to a hole goes back to any hole.
update week_settings set long_putt_any = true, long_putt_hole = null;

-- ------------------------------------------------------------
--  Which contests are running, stated once so the board and
--  the week report agree.
-- ------------------------------------------------------------
create or replace view week_running as
select
  ws.week,
  ws.ctp_hole is not null                    as ctp_on,
  ws.ctp_hole,
  coalesce(ws.long_putt_any, true)           as long_putt_on,
  ws.long_putt_hole,
  coalesce(ws.chip_in_any, true)             as chip_in_on
from week_settings ws;
