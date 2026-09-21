-- ============================================================================
-- COMBAT ENGINE PHASE 1 — CB-02 REPAIR (forward-only)
-- ----------------------------------------------------------------------------
-- combat_round_snapshot_units and combat_round_damage were the only two combat
-- history tables without a battle-level foreign key, which allowed round history
-- to outlive its battle (LIVE held 661 + 681 orphan rows for 17 deleted battles
-- when this repair was written).
--
-- This migration restores ONLY forward integrity:
--   * new invalid orphans become impossible;
--   * existing historical orphans are intentionally LEFT UNTOUCHED (no DELETE,
--     no data archaeology — see README_COMBAT_ENGINE section 15).
--
-- NOT VALID is deliberate: the constraint is enforced for every new or updated
-- row while the pre-existing orphan rows stay as historical residue, so the
-- repair cannot fail and cannot destroy data. A future, separately verified
-- cleanup mission may remove the orphans and then run
--   ALTER TABLE ... VALIDATE CONSTRAINT ...
--
-- ON DELETE CASCADE matches the lifecycle already used by every other battle
-- child table (combat_battle_participants, combat_rounds, combat_shots,
-- combat_individual_units, combat_debris_generations, combat_defense_repairs):
-- the battle is the aggregate root and its per-round history belongs to it.
--
-- No index is added: both tables already carry a unique index whose leading
-- column is battle_id (combat_round_snapshot_units_unique, combat_round_damage_unique).
-- ============================================================================

alter table public.combat_round_snapshot_units
  add constraint combat_round_snapshot_units_battle_id_fkey
  foreign key (battle_id) references public.combat_battles(id) on delete cascade not valid;

alter table public.combat_round_damage
  add constraint combat_round_damage_battle_id_fkey
  foreign key (battle_id) references public.combat_battles(id) on delete cascade not valid;


-- ---------------------------------------------------------------------------
-- Post-conditions
-- ---------------------------------------------------------------------------
do $cb02$
declare
  c record;
begin
  for c in
    select * from (values
      ('combat_round_snapshot_units','combat_round_snapshot_units_battle_id_fkey'),
      ('combat_round_damage','combat_round_damage_battle_id_fkey')
    ) as t(tbl, cname)
  loop
    if not exists (
      select 1 from pg_constraint con join pg_class cl on cl.oid = con.conrelid
      join pg_namespace n on n.oid = cl.relnamespace
      where n.nspname='public' and cl.relname = c.tbl and con.conname = c.cname
        and con.contype = 'f' and con.confdeltype = 'c'
        and con.confrelid = 'public.combat_battles'::regclass
    ) then
      raise exception 'CB-02: % missing on % with ON DELETE CASCADE', c.cname, c.tbl;
    end if;

    if exists (
      select 1 from pg_constraint con join pg_class cl on cl.oid = con.conrelid
      join pg_namespace n on n.oid = cl.relnamespace
      where n.nspname='public' and cl.relname = c.tbl and con.conname = c.cname
        and con.convalidated = true
    ) then
      raise exception 'CB-02: % unexpectedly validated; historical orphans would have had to be deleted', c.cname;
    end if;
  end loop;
end
$cb02$;
