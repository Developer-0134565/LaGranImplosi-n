-- ============================================================================================
-- LGI - close the can_start_building ownership oracle  (integral Supabase<->frontend audit, P2)
-- ============================================================================================
-- BEFORE (reproduced LIVE 2026-09-26 with a real planet):
--   owner                 -> allowed=t reason=OK   level=2 cost_metal=122.88 available_metal=89075.2
--   foreign authenticated -> allowed=t reason=OK   level=0 cost_metal=48     available_metal=NULL
--   anonymous (claims {}) -> allowed=t reason=OK   level=0
-- The function was SECURITY INVOKER and had no identity check at all, so an actor who does not own the
-- player received a positive decision about somebody else's planet (an oracle over private conditions:
-- planet_buildings is RLS-hidden, the deciding read is RLS-filtered, and for guest-owned victims the
-- resources policy leaks further).
--
-- AFTER: SECURITY DEFINER + the SAME inline identity gate already certified in inspect_demolition,
-- can_build_defense and can_start_research: authentication first, then ownership, then the explicit AI
-- actor path (is_ai_actor_target - no bypass, no weakening of enforce_player_write_access).
-- Refusals are RETURNED as a blocked row (not raised), so the 13-column contract, the reason codes the
-- client already renders and every caller stay intact.
-- The evaluation logic itself is NOT reimplemented: it is preserved verbatim under the internal name
-- evaluate_building_start_internal (ACL: service_role only) and the certified name delegates to it.
-- ============================================================================================

alter function public.can_start_building(uuid, uuid, text) rename to evaluate_building_start_internal;

revoke all on function public.evaluate_building_start_internal(uuid, uuid, text) from public, anon, authenticated;
grant execute on function public.evaluate_building_start_internal(uuid, uuid, text) to service_role;

create or replace function public.can_start_building(p_player_id uuid, p_planet_id uuid, p_building_id text)
returns table (allowed boolean, reason text, current_level integer, target_level integer, cost_metal numeric,
               cost_crystal numeric, cost_deuterium numeric, available_metal numeric, available_crystal numeric,
               available_deuterium numeric, fields_available boolean, prerequisites_met boolean, queue_available boolean)
language plpgsql stable security definer set search_path to 'public', 'pg_temp' as $function$
begin
    /* 1. AUTHENTICATION - or the explicit, declared AI service actor. */
    if auth.uid() is null then
        if not public.is_ai_actor_target(p_player_id) then
            return query select false, 'AUTHENTICATION_REQUIRED', 0, 0, 0::numeric, 0::numeric, 0::numeric,
                                0::numeric, 0::numeric, 0::numeric, false, false, false;
            return;
        end if;
    /* 2. OWNERSHIP - players.user_id = auth.uid() for the requested player. */
    elsif not exists (
        select 1 from public.players pl
         where pl.id = p_player_id and pl.user_id = auth.uid()
    ) then
        return query select false, 'PLAYER_NOT_OWNED', 0, 0, 0::numeric, 0::numeric, 0::numeric,
                            0::numeric, 0::numeric, 0::numeric, false, false, false;
        return;
    end if;

    /* 3. EVALUATION - the certified logic, unchanged, now authoritative (DEFINER). */
    return query select * from public.evaluate_building_start_internal(p_player_id, p_planet_id, p_building_id);
end;
$function$;

revoke all on function public.can_start_building(uuid, uuid, text) from public;
grant execute on function public.can_start_building(uuid, uuid, text) to anon, authenticated, service_role;

comment on function public.can_start_building(uuid, uuid, text) is
  'Ownership-gated building analysis: auth.uid() -> players.user_id (or the declared AI actor), refusing with AUTHENTICATION_REQUIRED / PLAYER_NOT_OWNED. Evaluation logic lives in evaluate_building_start_internal.';