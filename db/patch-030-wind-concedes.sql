-- ============================================================
--  PATCH 030 — the settings as the league actually states them
--  Apply after patch-029.
--
--  Wind is none, calm, moderate or strong. Concedes are one of
--  four distances the sim offers rather than any number.
-- ============================================================

-- Patch 029 added these. If it didn't land, add them here.
alter table week_settings
  add column if not exists wind        text,
  add column if not exists wind_speed  smallint,
  add column if not exists green_speed text,
  add column if not exists gimme_ft    smallint,
  add column if not exists conditions  text;

alter table week_settings drop constraint if exists week_settings_wind_speed_check;
alter table week_settings add constraint week_settings_wind_speed_check
  check (wind_speed is null or wind_speed between 0 and 40);

alter table week_settings drop constraint if exists week_settings_green_check;
alter table week_settings add constraint week_settings_green_check
  check (green_speed is null or
         green_speed in ('slow','medium','fast','tournament'));

alter table week_settings drop constraint if exists week_settings_wind_check;
alter table week_settings add constraint week_settings_wind_check
  check (wind is null or wind in ('none','calm','moderate','strong'));

-- anything set under the old wording
update week_settings set wind = 'calm' where wind in ('light','random');

alter table week_settings drop constraint if exists week_settings_gimme_ft_check;
alter table week_settings add constraint week_settings_gimme_ft_check
  check (gimme_ft is null or gimme_ft in (0, 2, 4, 7));

comment on column week_settings.wind is
  'none, calm, moderate or strong — the four the sim is set to.';
comment on column week_settings.gimme_ft is
  'Concede range in feet: 7, 4, 2, or 0 for putt everything out.';

-- ------------------------------------------------------------
--  One line describing a week, built once here so the schedule,
--  the TV and the week report all say the same thing.
-- ------------------------------------------------------------
create or replace function conditions_line(p_week smallint)
returns text
language sql
stable
as $$
  select nullif(array_to_string(array_remove(array[
    case
      when ws.wind = 'none' then 'no wind'
      when ws.wind is not null then ws.wind || ' wind'
      when ws.wind_speed is not null then ws.wind_speed || ' mph wind'
    end,
    case when ws.green_speed is not null then ws.green_speed || ' greens' end,
    case
      when ws.gimme_ft = 0 then 'putt everything out'
      when ws.gimme_ft is not null then ws.gimme_ft || 'ft concedes'
    end,
    ws.conditions
  ], null), ' · '), '')
  from week_settings ws
  where ws.week = p_week;
$$;

create or replace view week_conditions as
select
  ws.week,
  ws.wind, ws.wind_speed, ws.green_speed, ws.gimme_ft, ws.conditions,
  ws.ctp_hole, ws.long_putt_hole, ws.chip_in_any,
  conditions_line(ws.week) as line,
  m.played_on,
  m.tee_time,
  c.name as course_name,
  c.nine
from week_settings ws
left join lateral (
  select played_on, tee_time, course_id
    from matches where week = ws.week limit 1
) m on true
left join courses c on c.id = m.course_id;
