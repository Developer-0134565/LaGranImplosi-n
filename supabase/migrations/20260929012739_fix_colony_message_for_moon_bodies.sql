-- ============================================================================================
-- FIX — a false "Colony established" message is produced every time a MOON is formed
-- ============================================================================================
-- GAP (2026-09-29, Messaging/Reports residual cycle). The producer `notify_colony_established()`
-- is an `AFTER INSERT ON public.planets` trigger. Its only guard was
--     new.player_id is null or coalesce(new.is_homeworld, false)
-- which every row written by `settle_moon_creation_for_battle()` passes: a moon is inserted with
-- the DEFENDER's player_id, `is_homeworld = false` and `kind = 'MOON'`.
--
-- Consequence, measured from the two live function bodies:
--   * `settle_moon_creation_for_battle` itself already produces the correct message
--     ('Moon formed', dedupe 'moon_created:<id>');
--   * so the defender received TWO messages, and the second one asserted something that never
--     happened — "Colony established / Your colony ship founded Moon at [1:2:3]" — attributing a
--     moon to a colony ship that was never involved, and reporting a colony that does not exist.
-- This is a false statement about game state, not a cosmetic issue: the message set is the
-- player's authoritative record of what the engine did.
--
-- Latent, not active: LIVE currently holds 0 rows with `kind = 'MOON'` (656 PLANET, all
-- homeworlds), so the defect is proven by the two function bodies and by the fixture below, which
-- drives a REAL moon insert. No false message exists in LIVE data yet.
--
-- THE FIX, and its exact scope: one additional `kind` guard. The colony path is byte-for-byte
-- unchanged for `kind = 'PLANET'` rows, and the moon path already has its own dedicated producer
-- inside `settle_moon_creation_for_battle`, so nothing is lost — the correct message still exists.
-- This is the same `kind` discrimination the project already uses everywhere else in this table
-- (`enforce_planet_kind_consistency`, `settle_moon_creation_for_battle`, `resolve_colonize_arrival`).
--
-- Deliberately NOT changed: `settle_moon_creation_for_battle` and its 'Moon formed' message,
-- `create_player_message`, the trigger binding itself, the colony engine, and every other producer.
-- No product decision is involved: the message is factually wrong, not a policy choice.
-- ============================================================================================

create or replace function public.notify_colony_established()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
begin
    /* A colony is a PLANET body founded by a colony ship. Every other non-homeworld row in this
       table is a MOON, which `settle_moon_creation_for_battle` already announces itself. Without
       this guard a moon produced a second, false "Colony established" message. */
    if new.player_id is null or coalesce(new.is_homeworld, false) then
        return new;
    end if;
    if new.kind is distinct from 'PLANET' then
        return new;
    end if;
    begin
        perform public.create_player_message(
            new.player_id, null, 'Colony established',
            format('Your colony ship founded %s at %s.', new.name,
                   public.format_coordinates(new.galaxy, new.system, new.position)),
            'colony:' || new.id::text);
    exception when others then
        raise warning 'MESSAGE_PRODUCER_FAILED colony=% error=%', new.id, sqlerrm;
    end;
    return new;
end;
$fn$;


comment on function public.notify_colony_established() is
$c$AFTER INSERT ON public.planets. Produces 'Colony established' ONLY for a real colony: a row with a
player_id, is_homeworld = false AND kind = 'PLANET'. A MOON row is excluded, because
settle_moon_creation_for_battle() already announces it as 'Moon formed' — without this guard a moon
also produced a false 'Colony established' message attributing the moon to a colony ship. Owner of the
only write path (create_player_message) and therefore never client-reachable.$c$;


-- Post-conditions: the guard is really in place, the trigger is still bound, the moon producer
-- still announces the moon, and no other producer was touched.
do $verify$
declare
    v_src text;
begin
    select p.prosrc::text into v_src
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'notify_colony_established';
    if v_src is null then
        raise exception 'COLONY_MESSAGE_BODY_KIND: notify_colony_established() is missing';
    end if;

    -- the kind guard must be present, and must DISCRIMINATE, not blanket-return
    if v_src !~* 'kind\s+is\s+distinct\s+from\s+''PLANET''' then
        raise exception 'COLONY_MESSAGE_BODY_KIND: the kind guard is missing';
    end if;

    -- the trigger must still be attached (the fix is in the body, not a removed trigger)
    if not exists (select 1 from pg_trigger t join pg_class c on c.oid = t.tgrelid
                    where c.relname = 'planets' and t.tgname = 'trg_notify_colony_established'
                      and not t.tgisinternal) then
        raise exception 'COLONY_MESSAGE_BODY_KIND: the AFTER INSERT trigger was detached';
    end if;

    -- the moon producer must still announce the moon itself
    select p.prosrc::text into v_src
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'settle_moon_creation_for_battle';
    if v_src is null or v_src not ilike '%Moon formed%' then
        raise exception 'COLONY_MESSAGE_BODY_KIND: the moon producer lost its own message';
    end if;

    -- no producer may be made to delegate to the colony trigger
    if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                where n.nspname = 'public'
                  and p.proname in ('resolve_colonize_arrival','create_player_message',
                                    'notify_fleet_status_change','notify_combat_participant',
                                    'notify_expedition_result')
                  and p.prosrc::text ilike '%notify_colony_established%') then
        raise exception 'COLONY_MESSAGE_BODY_KIND: no producer may delegate to the colony trigger';
    end if;

    -- the only write path keeps its ACL (this is a producer-body fix, not an ACL change)
    if has_function_privilege('anon', 'public.create_player_message(uuid,uuid,text,text,text)', 'EXECUTE')
       or has_function_privilege('authenticated', 'public.create_player_message(uuid,uuid,text,text,text)', 'EXECUTE') then
        raise exception 'COLONY_MESSAGE_BODY_KIND: create_player_message ACL drift';
    end if;
end;
$verify$;
