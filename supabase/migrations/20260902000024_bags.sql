-- ============================================================
--  PATCH 031 — what's in the bag
--  Apply after patch-030.
--
--  Patch 006 sketched a bag_items table that nothing ever wrote
--  to. This settles its shape and hangs it off the player
--  rather than the team, since a bag belongs to a person.
-- ============================================================

drop table if exists bag_items cascade;

create table bag_items (
  id         uuid primary key default gen_random_uuid(),
  profile_id uuid not null references profiles on delete cascade,

  slot       text not null check (slot in (
               'driver','wood','hybrid','irons','wedge','putter',
               'ball','glove','shoes','bag','other')),
  brand      text check (char_length(brand) <= 60),
  model      text check (char_length(model) <= 80),
  detail     text check (char_length(detail) <= 60),

  position   smallint not null default 0,
  created_at timestamptz not null default now()
);

comment on column bag_items.detail is
  'Loft, shaft, flex, grind — whatever the person wants to add.
   Free text because everyone describes these differently.';
comment on column bag_items.position is
  'Order shown on a player page. Roughly driver to putter.';

create index on bag_items (profile_id, position);

alter table bag_items enable row level security;

create policy read_bag on bag_items for select using (true);

create policy own_bag on bag_items for all
  using (profile_id = auth.uid())
  with check (profile_id = auth.uid());

create policy admin_bag on bag_items for all using (is_commissioner());

-- ------------------------------------------------------------
--  A bag, in the order you'd pull clubs out of it.
-- ------------------------------------------------------------
create or replace view bags as
select
  bi.profile_id,
  p.full_name,
  t.slug as team_slug,
  bi.id, bi.slot, bi.brand, bi.model, bi.detail,
  case bi.slot
    when 'driver' then 1 when 'wood'  then 2 when 'hybrid' then 3
    when 'irons'  then 4 when 'wedge' then 5 when 'putter' then 6
    when 'ball'   then 7 when 'glove' then 8 when 'shoes'  then 9
    when 'bag'    then 10 else 11
  end as slot_order,
  bi.position
from bag_items bi
join profiles p on p.id = bi.profile_id
left join teams t on t.id = p.team_id
order by slot_order, bi.position, bi.created_at;

-- How many people have bothered, for the nudge on the editor.
create or replace view bag_counts as
select profile_id, count(*) as items
from bag_items group by profile_id;
