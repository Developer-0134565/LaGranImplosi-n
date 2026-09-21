-- ============================================================================
-- COMBAT ENGINE PHASE 2 — DG-01: CLIENT BATTLE-REPORT READ CONTRACT
-- ----------------------------------------------------------------------------
-- The engine persists the whole battle, but no client read path existed: every
-- combat table carries an ALL-command `deny_direct_api_access` policy for
-- anon/authenticated, so the COMBATE feed in src/App.tsx could only render
-- nothing. This adds the smallest authoritative read contract without exposing a
-- raw combat table and without weakening the deny model:
--
--   * SECURITY DEFINER (owner postgres), search_path pinned, EXECUTE only for
--     `authenticated`;
--   * authorization derives from the existing ownership model —
--     auth.uid() -> players.user_id -> players.id, allowed only when that player
--     id appears as a combat_battle_participants.player_id of the battle (covers
--     the attacking player and the planet-defender owner; ENEMY participants have
--     NULL player_id and authorize nobody); an unauthenticated caller always gets
--     an empty set;
--   * no combat calculation is duplicated: losses come from the certified readers
--     calculate_combat_ship_losses / calculate_combat_defense_losses, rounds from
--     combat_rounds, debris from combat_debris_generations, repairs from
--     combat_defense_repairs, result from the persisted combat_battles flags.
-- Not a second combat engine: it is a projection of persisted state.
-- ============================================================================

create or replace function public.get_player_battle_reports(p_limit integer default 25)
returns table (
    battle_id uuid,
    created_at timestamp with time zone,
    finished_at timestamp with time zone,
    outcome text,
    caller_role text,
    attacker_player_id uuid,
    defender_planet_id uuid,
    defender_player_id uuid,
    attacker_ships_before bigint,
    attacker_ships_after bigint,
    defender_ships_before bigint,
    defender_ships_after bigint,
    defender_defenses_before bigint,
    defender_defenses_after bigint,
    loot_metal numeric,
    loot_crystal numeric,
    loot_deuterium numeric,
    loot_applied_at timestamp with time zone,
    debris_metal numeric,
    debris_crystal numeric,
    defenses_repaired bigint,
    rounds_played integer,
    participants jsonb,
    rounds jsonb,
    losses jsonb
)
language sql
security definer
set search_path to 'public', 'pg_temp'
as $battle_reports$
with me as (
    select pl.id as player_id
    from public.players pl
    where pl.user_id = auth.uid()
),
visible as (
    select cb.*
    from public.combat_battles cb
    where (select count(*) from me) = 1
      and exists (
            select 1
            from public.combat_battle_participants p
            where p.battle_id = cb.id
              and p.player_id = (select me.player_id from me)
      )
    order by cb.created_at desc
    limit greatest(1, least(coalesce(p_limit, 25), 100))
)
select
    v.id,
    v.created_at,
    v.finished_at,
    case
        when v.finished_at is null then 'UNRESOLVED'
        when coalesce(v.attacker_win, false) then 'ATTACKER_WIN'
        when coalesce(v.defender_win, false) then 'DEFENDER_WIN'
        else 'DRAW'
    end,
    case
        when exists (
            select 1 from public.combat_battle_participants p
            where p.battle_id = v.id and p.side = 'ATTACKER'
              and p.player_id = (select me.player_id from me)
        ) then 'ATTACKER'
        else 'DEFENDER'
    end,
    v.attacker_player_id,
    v.defender_planet_id,
    (select p.player_id from public.combat_battle_participants p
      where p.battle_id = v.id and p.side = 'DEFENDER' and p.participant_type = 'PLANET'
      limit 1),
    v.attacker_ships_before,
    v.attacker_ships_after,
    v.defender_ships_before,
    v.defender_ships_after,
    v.defender_defenses_before,
    v.defender_defenses_after,
    v.loot_metal,
    v.loot_crystal,
    v.loot_deuterium,
    v.loot_applied_at,
    coalesce((select g.metal_generated from public.combat_debris_generations g where g.battle_id = v.id), 0),
    coalesce((select g.crystal_generated from public.combat_debris_generations g where g.battle_id = v.id), 0),
    coalesce((select sum(r.repaired_quantity) from public.combat_defense_repairs r where r.battle_id = v.id), 0),
    coalesce((select count(*) from public.combat_rounds cr where cr.battle_id = v.id), 0)::integer,
    coalesce((
        select jsonb_agg(jsonb_build_object(
                   'side', p.side, 'participant_type', p.participant_type,
                   'player_id', p.player_id, 'fleet_id', p.fleet_id, 'planet_id', p.planet_id)
               order by p.side, p.participant_type)
        from public.combat_battle_participants p
        where p.battle_id = v.id
    ), '[]'::jsonb),
    coalesce((
        select jsonb_agg(jsonb_build_object(
                   'round', cr.round_number,
                   'attacker_units_before', cr.attacker_units_before,
                   'attacker_units_after', cr.attacker_units_after,
                   'defender_units_before', cr.defender_units_before,
                   'defender_units_after', cr.defender_units_after,
                   'defender_combat_units_after', cr.defender_combat_units_after)
               order by cr.round_number)
        from public.combat_rounds cr
        where cr.battle_id = v.id
    ), '[]'::jsonb),
    coalesce((
        select jsonb_agg(jsonb_build_object(
                   'side', l.side, 'unit_type', l.unit_type,
                   'unit_id', l.unit_id, 'destroyed_quantity', l.destroyed_quantity)
               order by l.side, l.unit_id)
        from (
            select s.side, 'SHIP'::text as unit_type, s.unit_id, s.destroyed_quantity
            from public.calculate_combat_ship_losses(v.id) s
            where s.destroyed_quantity > 0
            union all
            select d.side, 'DEFENSE'::text, d.unit_id, d.destroyed_quantity
            from public.calculate_combat_defense_losses(v.id) d
            where d.destroyed_quantity > 0
        ) l
    ), '[]'::jsonb)
from visible v;
$battle_reports$;

-- Only authenticated players may call it; anon/PUBLIC keep no access.
revoke all on function public.get_player_battle_reports(integer) from public, anon, authenticated;
grant execute on function public.get_player_battle_reports(integer) to authenticated;

-- Post-conditions
do $dg01$
begin
  if not exists (
    select 1 from pg_proc p
    where p.pronamespace='public'::regnamespace and p.proname='get_player_battle_reports'
      and p.prosecdef and array_to_string(p.proconfig,',') like '%search_path%'
  ) then
    raise exception 'DG-01: get_player_battle_reports missing or not hardened';
  end if;

  if has_function_privilege('anon', 'public.get_player_battle_reports(integer)', 'EXECUTE') then
    raise exception 'DG-01: anon must not execute the battle-report contract';
  end if;

  if not has_function_privilege('authenticated', 'public.get_player_battle_reports(integer)', 'EXECUTE') then
    raise exception 'DG-01: authenticated must be able to execute the battle-report contract';
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname='public' and tablename='combat_battles'
      and policyname='deny_direct_api_access'
  ) then
    raise exception 'DG-01: the direct-API deny policy on combat_battles must stay in place';
  end if;
end
$dg01$;
