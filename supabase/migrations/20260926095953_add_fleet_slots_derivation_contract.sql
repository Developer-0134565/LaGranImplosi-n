-- FLEET SLOTS — derivation contract for `computer_technology` (2026-09-26)
-- --------------------------------------------------------------------------------------------
-- State before this migration (measured LIVE): `computer_technology` is unlock-only, there is no fleet-slot
-- sub-system of any kind (no column, no counter, no reader), and the only "slots" in LGI are EXPEDITION slots
-- (`get_player_expedition_slots`), which are a different mechanic and are NOT touched here.
--
-- OGameX evidence (`PlayerService` fleet-slot helpers @ 7c420bad, referenced by the repo map):
--   * maximum simultaneous fleets = 1 + computer_technology level (the +2 General-officer bonus does not apply:
--     LGI has no officers);
--   * every mission holds a slot for its whole duration (missile attacks are the documented exception and LGI
--     has no missile mission at all), so the count is over the player's fleets that are still alive.
--
-- What this migration DOES: exposes the two derivations plus a client-safe contract, so the rule is visible,
-- testable and ready. What it deliberately does NOT do: enforce the limit in the dispatch RPCs. Adopting the
-- cap would change what existing players may do (a hard gameplay change) and `computer_technology`'s
-- fleet-slot effect is an OPEN PRODUCT QUESTION in the repo map → the enforcement is a PRODUCT DECISION, not
-- invented here. No certified dispatcher was modified.
--
-- Read-only: none of these functions writes anything. The contract derives the caller from `auth.uid()`, so no
-- parameter can select a player.
-- Certified by `supabase/tests/fleet_slots_derivation.sql`.

create or replace function public.calculate_player_max_fleet_slots(p_player_id uuid)
returns integer
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
    select 1 + coalesce((
        select pr.level
        from public.player_research pr
        where pr.player_id = p_player_id
          and pr.research_id = 'computer_technology'
    ), 0);
$function$;

comment on function public.calculate_player_max_fleet_slots(uuid) is
$c$Maximum simultaneous fleets of a player = 1 + computer_technology level (OGameX parity; LGI has no officers,
so no +2 bonus). Read-only, credential-free derivation. Internal: EXECUTE is postgres/service_role only.
NOT enforced anywhere yet: the adoption of the cap is a PRODUCT DECISION.$c$;

create or replace function public.calculate_player_fleet_slots_in_use(p_player_id uuid)
returns integer
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
    select count(*)::integer
    from public.fleet_movements fm
    where fm.player_id = p_player_id
      and fm.status not in ('COMPLETED', 'CANCELLED');
$function$;

comment on function public.calculate_player_fleet_slots_in_use(uuid) is
$c$Fleets currently holding a slot = the player's missions whose status is neither COMPLETED nor CANCELLED, i.e.
still flying, holding or returning (OGameX counts unprocessed missions; every mission holds its slot for its whole
duration and LGI has no missile mission to exclude). Read-only. Internal: EXECUTE is postgres/service_role only.$c$;

create or replace function public.get_player_fleet_slots()
returns table(
    out_player_id uuid,
    out_computer_technology_level integer,
    out_max_slots integer,
    out_slots_in_use integer,
    out_slots_available integer
)
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
    select pl.id,
           coalesce(pr.level, 0),
           1 + coalesce(pr.level, 0),
           (select count(*)::integer
              from public.fleet_movements fm
             where fm.player_id = pl.id
               and fm.status not in ('COMPLETED', 'CANCELLED')),
           greatest(0, (1 + coalesce(pr.level, 0))
                     - (select count(*)::integer
                          from public.fleet_movements fm
                         where fm.player_id = pl.id
                           and fm.status not in ('COMPLETED', 'CANCELLED')))
    from public.players pl
    left join public.player_research pr
      on pr.player_id = pl.id
     and pr.research_id = 'computer_technology'
    where pl.user_id = auth.uid()
    order by pl.id;
$function$;

comment on function public.get_player_fleet_slots() is
$c$Client read contract: one row per player owned by auth.uid() with the computer_technology level, the maximum
simultaneous fleets (1 + level), the missions currently holding a slot, and the remaining slots (never negative).
Read-only and identity-safe: there is no player parameter, and `auth.uid()` decides whose rows are returned.
Informational only — dispatch is NOT capped by this contract yet (PRODUCT DECISION).$c$;

revoke all on function public.calculate_player_max_fleet_slots(uuid) from public;
revoke all on function public.calculate_player_max_fleet_slots(uuid) from anon;
revoke all on function public.calculate_player_max_fleet_slots(uuid) from authenticated;
grant execute on function public.calculate_player_max_fleet_slots(uuid) to service_role;

revoke all on function public.calculate_player_fleet_slots_in_use(uuid) from public;
revoke all on function public.calculate_player_fleet_slots_in_use(uuid) from anon;
revoke all on function public.calculate_player_fleet_slots_in_use(uuid) from authenticated;
grant execute on function public.calculate_player_fleet_slots_in_use(uuid) to service_role;

revoke all on function public.get_player_fleet_slots() from public;
revoke all on function public.get_player_fleet_slots() from anon;
grant execute on function public.get_player_fleet_slots() to authenticated;
grant execute on function public.get_player_fleet_slots() to service_role;
