-- ============================================================================================
-- READ CONTRACT — "is there any recyclable debris field right now?" (existence only)
-- ============================================================================================
-- GAP (2026-09-28). The RECYCLE mission picks its target SERVER-SIDE: the player may not send
-- coordinates, so `start_fleet_mixed` selects the nearest non-empty field itself and, when there is
-- none, raises 'No debris field available for RECYCLE'. That refusal is already correct and ATOMIC
-- (verified LIVE: 0 movements created, no slot and no fuel consumed), so this is NOT a correctness bug
-- and this migration does NOT change the mechanic.
--
-- What was missing is discoverability: the dispatch screen enabled the launch button with no
-- pre-flight indication, so the only feedback was an error AFTER pressing it. Every other blocked
-- mission (FLEET_SLOTS_FULL, EXPEDITION_SLOTS_FULL, COLONY_CAP_REACHED) is surfaced up front through
-- the `launchBlock` derived from server contracts; RECYCLE was the odd one out.
--
-- WHY THIS IS EXISTENCE-ONLY, AND WHY THAT IS EXACT (not a weakening):
-- the dispatcher's target selection is
--     WHERE df.universe_id = <mine> AND (df.metal > 0 OR df.crystal > 0)  ... LIMIT 1
-- and it raises precisely when that SELECT finds nothing. So "is there a recyclable field?" is the
-- SAME predicate as the server's precondition, with NO ordering and NO distance involved — verified
-- LIVE on both an empty universe (EXISTS=f, dispatcher found nothing) and a populated one
-- (EXISTS=t, dispatcher found [1:1:15]). This contract therefore does NOT invent a range, a distance
-- metric, a ranking or a capacity, and it deliberately does NOT tell the player WHICH field will be
-- targeted: that selection stays the single source of truth inside start_fleet_mixed.
--
-- Shape follows the certified read contracts (get_universe_debris, get_my_attack_protection):
--   * NO arguments at all. The universe is resolved from auth.uid() -> players.user_id ->
--     players.universe_id, so there is nothing for the client to manipulate — not even a universe id;
--   * SECURITY DEFINER with search_path pinned (debris_fields is closed to the client by
--     deny_direct_api_access, exactly like for get_universe_debris);
--   * ACL: authenticated + service_role, never anon;
--   * read-only: it selects and counts, it never writes.
--
-- Deliberately NOT changed: start_fleet_mixed, collect_debris, the fleet worker, the RECYCLE
-- composition rule, calculate_recycler_capacity, and anything ACS/Combat/Espionage/Messaging.
-- ============================================================================================

create or replace function public.get_recyclable_debris_status()
returns table(
    out_available boolean,
    out_field_count bigint
)
language sql
stable
security definer
set search_path = public, pg_temp
as $fn$
    select count(*) > 0, count(*)
    from public.debris_fields d
    where d.universe_id in (select pl.universe_id from public.players pl where pl.user_id = auth.uid())
      and (d.metal > 0 or d.crystal > 0);
$fn$;

comment on function public.get_recyclable_debris_status() is
$c$Client read contract answering ONE question: does a recyclable debris field exist in MY universe right
now? Existence only — deliberately no distance, range, ranking or capacity, and it never reveals which
field start_fleet_mixed will pick (that stays the engine's single source of truth). The predicate is the
same as the dispatcher's precondition, so a false answer means the server WILL refuse the dispatch.
Takes NO arguments: the universe comes from auth.uid() -> players.user_id -> players.universe_id, so
nothing can be manipulated. SECURITY DEFINER with a pinned search_path (debris_fields is closed to the
client). Read-only.$c$;


-- Post-conditions: ACL is what we claim, the contract takes nothing, and the recycling engine
-- itself was not touched by this migration.
do $verify$
declare
    v_bad text;
    v_args text;
begin
    if has_function_privilege('anon', 'public.get_recyclable_debris_status()', 'EXECUTE')
       or not has_function_privilege('authenticated', 'public.get_recyclable_debris_status()', 'EXECUTE')
       or not has_function_privilege('service_role', 'public.get_recyclable_debris_status()', 'EXECUTE') then
        raise exception 'RECYCLABLE_DEBRIS_STATUS: ACL drift after creation';
    end if;

    select pg_get_function_arguments(p.oid) into v_args
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'get_recyclable_debris_status';
    if v_args is distinct from '' then
        raise exception 'RECYCLABLE_DEBRIS_STATUS: the contract must take NO arguments (got %)', v_args;
    end if;

    select string_agg(a, ', ') into v_bad
      from unnest(regexp_split_to_array(
             (select p.prosrc::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
               where n.nspname = 'public' and p.proname = 'get_recyclable_debris_status'), '\s+')) a
     where a ilike '%p_player_id%' or a ilike '%p_universe_id%';
    if v_bad is not null then
        raise exception 'RECYCLABLE_DEBRIS_STATUS: must not take a client selector (%s)', v_bad;
    end if;

    -- no distance / range / capacity rule may leak into an existence-only contract
    if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                where n.nspname = 'public' and p.proname = 'get_recyclable_debris_status'
                  and p.prosrc::text ~* '\m(distance|range|capacity|order by|limit)\M') then
        raise exception 'RECYCLABLE_DEBRIS_STATUS: an existence-only contract must not rank or measure';
    end if;

    -- the recycling engine must be untouched
    if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                where n.nspname = 'public'
                  and p.proname in ('start_fleet_mixed','collect_debris','calculate_recycler_capacity','can_recycle_debris')
                  and p.prosrc::text ilike '%get_recyclable_debris_status%') then
        raise exception 'RECYCLABLE_DEBRIS_STATUS: the recycling engine must not depend on the new contract';
    end if;
end;
$verify$;

-- ACL: the sibling shape — authenticated + service_role, never anon.
revoke all on function public.get_recyclable_debris_status() from public;
revoke all on function public.get_recyclable_debris_status() from anon;
grant execute on function public.get_recyclable_debris_status() to authenticated;
grant execute on function public.get_recyclable_debris_status() to service_role;
