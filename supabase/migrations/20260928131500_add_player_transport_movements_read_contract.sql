-- ============================================================================================
-- OWNER-SCOPED READ CONTRACT — the player's transport movements (Messages / TRANSPORTES category)
-- ============================================================================================
-- GAP (2026-09-28, Messaging/Reports cycle). The communications centre builds four categories and three of
-- them were already served by a certified owner-scoped contract (get_player_battle_reports,
-- get_player_espionage_reports, get_player_expedition_reports). TRANSPORTES was the only one left reading a
-- table straight from the browser:
--
--     supabase.from('fleet_movements').select(...).eq('player_id', playerId).eq('mission_type','TRANSPORT')
--
-- This is NOT a vulnerability: `fleet_movements_select_access` is already owner-scoped
-- (EXISTS … pl.user_id = auth.uid()), so a client-supplied player_id cannot widen access. It IS the last
-- place where the browser supplies its own ownership selector, and the only Messages category that bypasses
-- a server contract.
--
-- This migration adds the missing contract and nothing else. It does NOT touch the RLS of fleet_movements,
-- the fleet engine, the ownership of the engine, or the mission lifecycle. No new table, no write path.
--
-- Design (same pattern as get_player_messages / get_player_battle_reports):
--   * SECURITY DEFINER + pinned search_path (fleet_movements has RLS; the contract is how the owner reads it).
--   * ownership: rows are selected strictly through auth.uid() -> players.user_id -> players.id. There is NO
--     player_id parameter, so no argument can select another player's movements.
--   * the mission type is fixed inside the function (TRANSPORT): the client cannot ask for other missions.
--   * the limit is clamped server-side, greatest(1, least(coalesce(p_limit, 25), 100)) — the same shape as the
--     other contracts, never trusting the frontend .limit().
--   * ordering: created_at desc, id — identical to the .order('created_at', {ascending:false}) the browser
--     applied, so the visible result does not change.
--   * the returned columns are exactly the ones the TRANSPORTES row renders (id, status and the three
--     destination coordinates, plus created_at). Nothing is copied "just in case".
--
-- Migration id chosen after 20260928121226 (the D6 fix already applied to LIVE as 20260928121226).
-- ============================================================================================

create or replace function public.get_player_transport_movements(p_limit integer default 25)
returns table(
    out_movement_id uuid,
    out_status text,
    out_destination_galaxy integer,
    out_destination_system integer,
    out_destination_position integer,
    out_created_at timestamptz
)
language sql
stable
security definer
set search_path = public, pg_temp
as $fn$
    select fm.id,
           fm.status,
           fm.destination_galaxy,
           fm.destination_system,
           fm.destination_position,
           fm.created_at
    from public.fleet_movements fm
    where fm.mission_type = 'TRANSPORT'
      and fm.player_id in (select pl.id from public.players pl where pl.user_id = auth.uid())
    order by fm.created_at desc, fm.id
    limit greatest(1, least(coalesce(p_limit, 25), 100));
$fn$;

comment on function public.get_player_transport_movements(integer) is
$c$Client read contract for the caller's OWN transport movements (the Messages / TRANSPORTES category).
Rows are selected strictly through auth.uid() -> players.user_id -> players.id, so no argument can select
another player's movements; the mission type is fixed to TRANSPORT inside the function. SECURITY DEFINER with a
pinned search_path because fleet_movements carries RLS. p_limit is clamped server-side to 1..100. Read-only:
there is no write path here.$c$;

-- ACL: exactly the shape of the other Messages read contracts — authenticated + service_role, never anon.
revoke all on function public.get_player_transport_movements(integer) from public;
revoke all on function public.get_player_transport_movements(integer) from anon;
grant execute on function public.get_player_transport_movements(integer) to authenticated;
grant execute on function public.get_player_transport_movements(integer) to service_role;

-- Post-conditions: the ACL is what we claim, and the function is genuinely read-only.
do $verify$
declare
    v_bad text;
begin
    if has_function_privilege('anon', 'public.get_player_transport_movements(integer)', 'EXECUTE')
       or not has_function_privilege('authenticated', 'public.get_player_transport_movements(integer)', 'EXECUTE')
       or not has_function_privilege('service_role', 'public.get_player_transport_movements(integer)', 'EXECUTE') then
        raise exception 'TRANSPORT_MOVEMENT_READ_CONTRACT: ACL drift after creation';
    end if;

    -- the ownership chain must not accept a player selector
    select string_agg(a, ', ') into v_bad
      from unnest(regexp_split_to_array(
             (select p.prosrc::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
               where n.nspname = 'public' and p.proname = 'get_player_transport_movements'
                 and pg_get_function_arguments(p.oid) = 'p_limit integer DEFAULT 25'), '\s+')) a
     where a ilike '%p_player_id%';
    if v_bad is not null then
        raise exception 'TRANSPORT_MOVEMENT_READ_CONTRACT: the contract must not take a player selector (%s)', v_bad;
    end if;
end;
$verify$;
