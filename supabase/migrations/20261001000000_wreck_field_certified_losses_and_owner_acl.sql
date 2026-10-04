-- LGI CORE RECOVERY — Wreck Field: certified loss source, battle isolation/idempotency, owner ACL
--
-- CONTEXT (browser certification + core audit):
--   * `settle_wreck_field_for_battle` derived its losses from `combat_unit_state`
--     (quantity - quantity_alive of the LAST round row per unit). That engine is DEAD for this
--     purpose: it is not the certified loss ledger and it collapses rows as units die, so the
--     quantity is under-reported. The certified, participant-aware ledger is
--     `calculate_combat_ship_losses(battle_id)`, which reads `combat_individual_units`
--     (initial rows at round 1 vs surviving rows at the LAST round) and already restricts
--     itself to `unit_type = 'SHIP'`, so defences never enter the field.
--   * Re-settlement was not idempotent: the additive `quantity = quantity + excluded.quantity`
--     in `create_or_extend_wreck_field` would DOUBLE the wreck for the same battle.
--   * `planet_wreck_fields` / `planet_wreck_field_ships` had RLS DISABLED and no owner-scoped
--     read/write contract, and the whole subsystem was service_role-only (no UI could read it).
--
-- RULES PRESERVED (NOT invented here — already LGI decisions, see
-- docs/systems/README_FLEET_ENGINE.md and migration 20260926230000):
--   * one wreck field per planet; a new battle EXTENDS it and refreshes the 72 h decay timer
--   * only SHIP losses enter the field; the field lives on the DEFENDER planet
--   * recoverable share = least(100, 20 + 8 * space_dock_level) %; repairs are free (time only)
--   * zero losses => NO wreck field
-- No new balance, no new threshold, no new expiry is introduced by this migration.

-- ---------------------------------------------------------------------------------------------
-- 1. BATTLE ISOLATION / IDEMPOTENCY LEDGER
--    One row per settled battle. Re-running the trigger (or a manual retry) is a no-op.
-- ---------------------------------------------------------------------------------------------
create table if not exists public.planet_wreck_field_battles (
    battle_id uuid primary key references public.combat_battles(id) on delete cascade,
    wreck_field_id uuid references public.planet_wreck_fields(id) on delete set null,
    settled_at timestamptz not null default now()
);

comment on table public.planet_wreck_field_battles is
    'Idempotency + battle isolation ledger for wreck settlement: a battle_id may settle at most once.';

-- ---------------------------------------------------------------------------------------------
-- 2. LOSS SOURCE + IDEMPOTENCY
--    Uses the certified ledger. The ON CONFLICT DO NOTHING + NOT FOUND check makes concurrent
--    and repeated settlement safe: the loser of the race adds nothing.
-- ---------------------------------------------------------------------------------------------
create or replace function public.settle_wreck_field_for_battle(p_battle_id uuid)
returns uuid language plpgsql security definer set search_path to 'public','pg_temp' as $f$
declare
    v_planet_id uuid;
    v_ships jsonb;
    v_field_id uuid;
    v_existing uuid;
begin
    if p_battle_id is null then return null; end if;

    /* Battle isolation: the field belongs to THIS battle's defender planet, and only ships. */
    select cb.defender_planet_id into v_planet_id from public.combat_battles cb
     where cb.id = p_battle_id and cb.defender_planet_id is not null;
    if v_planet_id is null then return null; end if;

    /* Idempotency: claim the battle first. A second settlement sees the row and stops. */
    insert into public.planet_wreck_field_battles (battle_id) values (p_battle_id)
    on conflict (battle_id) do nothing;
    if not found then
        select l.wreck_field_id into v_existing
          from public.planet_wreck_field_battles l where l.battle_id = p_battle_id;
        return v_existing;
    end if;

-- ---------------------------------------------------------------------------------------------
-- 3. OWNER-SCOPED READ CONTRACT (the UI surface; the engine stays backend-only)
--    SECURITY DEFINER + explicit ownership check. 0 rows for a foreign planet, a destroyed
--    planet, an anonymous caller or a caller with no session — never an exception.
-- ---------------------------------------------------------------------------------------------
create or replace function public.get_planet_wreck_field(p_planet_id uuid)
returns table (
    wreck_field_id uuid,
    planet_id uuid,
    status text,
    space_dock_level integer,
    blocked_reason text,
    expires_at timestamptz,
    repair_started_at timestamptz,
    repair_finishes_at timestamptz,
    ship_id text,
    ship_name text,
    quantity bigint,
    repaired_quantity bigint,
    pending_quantity bigint
)
language plpgsql stable security definer set search_path to 'public','pg_temp' as $f$
declare v_auth uuid := auth.uid();
begin
    if p_planet_id is null or v_auth is null then return; end if;

    return query
    select wf.id, wf.planet_id, wf.status, wf.space_dock_level, wf.blocked_reason,
           wf.expires_at, wf.repair_started_at, wf.repair_finishes_at,
           s.ship_id, sd.name, s.quantity, s.repaired_quantity,
           greatest(s.quantity - s.repaired_quantity, 0)
      from public.planet_wreck_fields wf
      join public.players pl on pl.id = wf.owner_player_id and pl.user_id = v_auth
      left join public.planet_wreck_field_ships s on s.wreck_field_id = wf.id
      left join public.ship_definitions sd on sd.id = s.ship_id
     where wf.planet_id = p_planet_id
     order by s.ship_id nulls first;
end;
$f$;

-- Owner-scoped mutation: the player may start repairs on THEIR OWN field only.
create or replace function public.start_planet_wreck_field_repairs(p_planet_id uuid)
returns table (out_wreck_field_id uuid, out_status text, out_result text)
language plpgsql volatile security definer set search_path to 'public','pg_temp' as $f$
declare
    v_auth uuid := auth.uid();
    v_field uuid;
    v_res record;
begin
    if p_planet_id is null or v_auth is null then
        return query select null::uuid, 'DENIED'::text, 'AUTHENTICATION_REQUIRED'::text; return;
    end if;

    select wf.id into v_field
      from public.planet_wreck_fields wf
      join public.players pl on pl.id = wf.owner_player_id and pl.user_id = v_auth
     where wf.planet_id = p_planet_id;
    if v_field is null then
        return query select null::uuid, 'DENIED'::text, 'WRECK_FIELD_NOT_FOUND_OR_NOT_OWNED'::text; return;
    end if;

    for v_res in select * from public.start_wreck_field_repairs(v_field) loop
        return query select v_res.out_field_id, v_res.out_status, v_res.out_result;
    end loop;
end;
$f$;
    /* AUTHORITATIVE LOSS SOURCE: the certified, participant-aware ship loss ledger.
       It compares round 1 against the last round and filters unit_type = 'SHIP' internally,
       so this never mixes defences in and never reconstructs from collapsing snapshots. */
    select coalesce(jsonb_object_agg(l.unit_id, l.destroyed), '{}'::jsonb) into v_ships
      from public.calculate_combat_ship_losses(p_battle_id) l
     where l.destroyed_quantity > 0
       and exists (select 1 from public.ship_definitions sd where sd.id = l.unit_id);

    /* Zero-loss rule: no wreck field at all. Release the claim so the ledger stays truthful. */
    if v_ships is null or v_ships = '{}'::jsonb then
        delete from public.planet_wreck_field_battles where battle_id = p_battle_id;
        return null;
    end if;

    v_field_id := public.create_or_extend_wreck_field(v_planet_id, v_ships, null);

    update public.planet_wreck_field_battles
       set wreck_field_id = v_field_id, settled_at = now()
     where battle_id = p_battle_id;

    return v_field_id;
end;
$f$;
-- ---------------------------------------------------------------------------------------------
-- 4. RLS / ACL
--    Defence in depth on the two wreck tables (owner-scoped SELECT, NO client write at all)
--    plus the two owner-scoped RPCs. The engine contracts stay service_role-only.
-- ---------------------------------------------------------------------------------------------
alter table public.planet_wreck_fields enable row level security;
alter table public.planet_wreck_field_ships enable row level security;
alter table public.planet_wreck_field_battles enable row level security;

drop policy if exists planet_wreck_fields_owner_select on public.planet_wreck_fields;
create policy planet_wreck_fields_owner_select on public.planet_wreck_fields
    for select to authenticated
    using (exists (select 1 from public.players pl
                    where pl.id = planet_wreck_fields.owner_player_id
                      and pl.user_id = auth.uid()));

drop policy if exists planet_wreck_field_ships_owner_select on public.planet_wreck_field_ships;
create policy planet_wreck_field_ships_owner_select on public.planet_wreck_field_ships
    for select to authenticated
    using (exists (select 1 from public.planet_wreck_fields wf
                    join public.players pl on pl.id = wf.owner_player_id and pl.user_id = auth.uid()
                   where wf.id = planet_wreck_field_ships.wreck_field_id));

-- No INSERT/UPDATE/DELETE policy on purpose: every write goes through a SECURITY DEFINER
-- contract (engine) or the owner-scoped RPC (repairs). No direct client write is possible.

revoke all on table public.planet_wreck_field_battles from public, anon, authenticated;

grant select on public.planet_wreck_fields to authenticated;
grant select on public.planet_wreck_field_ships to authenticated;
grant execute on function public.get_planet_wreck_field(uuid) to authenticated;
grant execute on function public.start_planet_wreck_field_repairs(uuid) to authenticated;

revoke all on function public.get_planet_wreck_field(uuid) from public, anon;
revoke all on function public.start_planet_wreck_field_repairs(uuid) from public, anon;

-- engine contracts stay backend-only (already revoked in 20260926230000; re-asserted here)
revoke all on function public.settle_wreck_field_for_battle(uuid) from public, anon, authenticated;
revoke all on function public.create_or_extend_wreck_field(uuid, jsonb, integer) from public, anon, authenticated;
revoke all on function public.start_wreck_field_repairs(uuid) from public, anon, authenticated;
revoke all on function public.complete_wreck_field_repairs(uuid) from public, anon, authenticated;
revoke all on function public.run_wreck_field_worker(integer) from public, anon, authenticated;
grant execute on function public.settle_wreck_field_for_battle(uuid) to service_role;
grant execute on function public.create_or_extend_wreck_field(uuid, jsonb, integer) to service_role;
grant execute on function public.start_wreck_field_repairs(uuid) to service_role;
grant execute on function public.complete_wreck_field_repairs(uuid) to service_role;
grant execute on function public.run_wreck_field_worker(integer) to service_role;