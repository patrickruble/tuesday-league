-- ============================================================
--  WEEK 2 — 15 September, Pebble Beach back nine, strong wind
--
--  Same bays as week 1. Change the pairings if Chris has moved
--  anyone. Safe to run twice.
-- ============================================================

delete from matches where week = 2;

insert into matches (week, played_on, tee_time, bay, course_id, home_team, away_team)
select 2, '2026-09-15', '19:00', v.bay,
       (select id from courses where name = 'Pebble Beach' and nine = 'back'),
       (select id from teams where slug = v.a),
       (select id from teams where slug = v.b)
from (values
  (1, 'ball-gags-and-bogeys',           'dee-is-for-deserter'),
  (2, 'the-strangers',                  'good-putts-great-butts'),
  (3, 'pat-daddy-and-the-heartbreakers','balls-deep'),
  (4, 'putt-pirates',                   'no-mames-fore'),
  (5, 'm-n-m',                          'consensual-threesum')
) as v(bay, a, b);

-- contests: same shape as last week
insert into week_settings (week, wind, ctp_hole, long_putt_any, chip_in_any)
values (2, 'strong', 6, true, true)
on conflict (week) do update
  set wind = 'strong', ctp_hole = 6,
      long_putt_any = true, chip_in_any = true;

-- clear the half-finished drafts from last week so they don't
-- sit around confusing anyone
delete from round_photos where round_id in (
  select id from rounds where status = 'draft');
delete from rounds where status = 'draft';

select m.bay, h.name as team, a.name as with_team
from matches m
join teams h on h.id = m.home_team
left join teams a on a.id = m.away_team
where m.week = 2 order by m.bay;
