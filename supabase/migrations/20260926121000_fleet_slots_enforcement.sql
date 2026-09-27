-- FLEET SLOTS — server-side enforcement (2026-09-26)
-- --------------------------------------------------------------------------------------------
-- Derivation already existed (`20260926095953_add_fleet_slots_derivation_contract`:
-- `calculate_player_max_fleet_slots` = 1 + computer_technology, `calculate_player_fleet_slots_in_use` =
-- missions whose status is neither COMPLETED nor CANCELLED, plus the owner-scoped read contract
-- `get_player_fleet_slots`). PRODUCT DECISION of the GAMEPLAY COMPLETION SWEEP: the cap is ADOPTED and must be
-- enforced SERVER-SIDE, for every mission that puts a fleet in flight; the UI is never the authority.
--
-- Enforcement sits in a BEFORE INSERT trigger on `fleet_movements` instead of being duplicated inside every
-- dispatcher. Rationale (no-regression): the certified dispatchers (`start_fleet`, `start_fleet_mixed`,
-- `start_support_fleet`, `start_colonize_fleet`) stay byte-identical, the rule cannot be bypassed by a future
-- dispatcher, and a client can never reach `fleet_movements` directly (it is `deny_direct_api_access`).
--
-- Rules:
--   * every mission holds one slot for its whole duration (OGameX `PlayerService` fleet-slot helpers; LGI has no
--     officers and no missile mission, so no exception applies) — ACS_HOLD/HOLDING, expeditions and colonisation
--     all consume a slot, and a returning fleet keeps it until it lands (status RETURNING is not COMPLETED);
--   * a duplicated idempotent request (`idempotency_key` already used by the same player) is NOT rejected here:
--     it must reach the partial unique index so `start_support_fleet` can return the durable movement of the
--     winner instead of a slot error;
--   * rejection is an exception (`FLEET_SLOTS_FULL: used/max`) raised inside the caller's transaction, so the
--     dispatch is atomic: no fuel, no ships, no movement.
--
-- Certified by `supabase/tests/fleet_slots_enforcement.sql`.
begin;

create or replace function public.assert_player_fleet_slot_available(p_player_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
    v_max_slots integer;
    v_in_use integer;
begin
    if p_player_id is null then
        raise exception 'FLEET_SLOT_PLAYER_REQUIRED';
    end if;

    v_max_slots := public.calculate_player_max_fleet_slots(p_player_id);
    v_in_use := public.calculate_player_fleet_slots_in_use(p_player_id);

    if v_in_use >= v_max_slots then
        raise exception 'FLEET_SLOTS_FULL: %/%', v_in_use, v_max_slots;
    end if;
end;
$function$;

comment on function public.assert_player_fleet_slot_available(uuid) is
$c$Raises FLEET_SLOTS_FULL when the player already uses all of its simultaneous-fleet slots (1 +
computer_technology). Internal helper used by the fleet_movements insert guard; EXECUTE is postgres/service_role
only.$c$;

create or replace function public.enforce_fleet_slots_before_insert()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
begin
    /*
      A retry of an identical idempotent dispatch must not be blocked by the cap: the partial unique index
      (player_id, idempotency_key) has to see the insert so the dispatcher can return the existing movement.
    */
    if new.idempotency_key is not null
       and exists (select 1
                     from public.fleet_movements fm
                    where fm.player_id = new.player_id
                      and fm.idempotency_key = new.idempotency_key) then
        return new;
    end if;

    perform public.assert_player_fleet_slot_available(new.player_id);
    return new;
end;
$function$;

comment on function public.enforce_fleet_slots_before_insert() is
$c$BEFORE INSERT trigger on fleet_movements: every dispatch path (start_fleet, start_fleet_mixed,
start_support_fleet, start_colonize_fleet and any future dispatcher) is capped by 1 + computer_technology. An
identical idempotent retry is exempted so the idempotency contract keeps working.$c$;

drop trigger if exists trg_enforce_fleet_slots on public.fleet_movements;
create trigger trg_enforce_fleet_slots
    before insert on public.fleet_movements
    for each row
    execute function public.enforce_fleet_slots_before_insert();

revoke all on function public.assert_player_fleet_slot_available(uuid) from public, anon, authenticated;
grant execute on function public.assert_player_fleet_slot_available(uuid) to service_role;
revoke all on function public.enforce_fleet_slots_before_insert() from public, anon, authenticated;

commit;
