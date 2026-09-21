-- ============================================================================
-- COMBAT ENGINE PHASE 1 — CB-01 FOLLOW-UP (forward-only)
-- ----------------------------------------------------------------------------
-- `resolve_expedition_pirates` / `resolve_expedition_aliens` wrote the surviving
-- fleet back by counting alive ATTACKER units across ALL recorded rounds instead
-- of the final round. Any expedition battle lasting more than one round inflated
-- the surviving fleet (e.g. 11 alive in round 1 + 10 alive in round 2 = 21 ships
-- returned, while only 10 survived). The ATTACK path
-- (`resolve_attack_arrival`) already scopes both the quantity rewrite and the
-- survivor cleanup to the last round; this makes the expedition path identical.
-- ============================================================================

do $cb01g$
declare
  v_def text;
  v_new text;
  v_occ integer;
  r record;
begin
  for r in
    select * from (values
      (1, 'resolve_expedition_pirates', 'v_battle'),
      (2, 'resolve_expedition_aliens', 'b')
    ) as t(ord, fn, battle_var) order by ord
  loop
    select pg_get_functiondef(p.oid) into v_def
    from pg_proc p
    where p.pronamespace='public'::regnamespace and p.proname = r.fn;

    if v_def is null then
      raise exception 'CB-01g: function public.% not found', r.fn;
    end if;

    -- (1) the survivor quantity must count only the last recorded round
    v_occ := (length(v_def) - length(replace(v_def,
      'JOIN public.combat_individual_units ciu ON ciu.battle_id=' || r.battle_var ||
      ' AND ciu.side=''ATTACKER'' AND ciu.unit_id=fms2.ship_id AND ciu.alive WHERE fms2.fleet_id=p_fleet_id', '')))
      / length('JOIN public.combat_individual_units ciu ON ciu.battle_id=' || r.battle_var ||
      ' AND ciu.side=''ATTACKER'' AND ciu.unit_id=fms2.ship_id AND ciu.alive WHERE fms2.fleet_id=p_fleet_id');

    if v_occ <> 1 then
      raise exception 'CB-01g: survivor update fragment matched % time(s) in public.%', v_occ, r.fn;
    end if;

    v_new := replace(v_def,
      'JOIN public.combat_individual_units ciu ON ciu.battle_id=' || r.battle_var ||
      ' AND ciu.side=''ATTACKER'' AND ciu.unit_id=fms2.ship_id AND ciu.alive WHERE fms2.fleet_id=p_fleet_id',
      'JOIN public.combat_individual_units ciu ON ciu.battle_id=' || r.battle_var ||
      ' AND ciu.side=''ATTACKER'' AND ciu.unit_id=fms2.ship_id AND ciu.alive AND ciu.round_number=(select max(round_number) from public.combat_individual_units where battle_id=' || r.battle_var || ') WHERE fms2.fleet_id=p_fleet_id');
    v_def := v_new;

    -- (2) the survivor cleanup must use the same scope
    v_occ := (length(v_def) - length(replace(v_def,
      'NOT EXISTS(SELECT 1 FROM public.combat_individual_units ciu WHERE ciu.battle_id=' || r.battle_var ||
      ' AND ciu.side=''ATTACKER'' AND ciu.unit_id=fms.ship_id AND ciu.alive)', '')))
      / length('NOT EXISTS(SELECT 1 FROM public.combat_individual_units ciu WHERE ciu.battle_id=' || r.battle_var ||
      ' AND ciu.side=''ATTACKER'' AND ciu.unit_id=fms.ship_id AND ciu.alive)');

    if v_occ <> 1 then
      raise exception 'CB-01g: survivor cleanup fragment matched % time(s) in public.%', v_occ, r.fn;
    end if;

    v_new := replace(v_def,
      'NOT EXISTS(SELECT 1 FROM public.combat_individual_units ciu WHERE ciu.battle_id=' || r.battle_var ||
      ' AND ciu.side=''ATTACKER'' AND ciu.unit_id=fms.ship_id AND ciu.alive)',
      'NOT EXISTS(SELECT 1 FROM public.combat_individual_units ciu WHERE ciu.battle_id=' || r.battle_var ||
      ' AND ciu.side=''ATTACKER'' AND ciu.unit_id=fms.ship_id AND ciu.alive AND ciu.round_number=(select max(round_number) from public.combat_individual_units where battle_id=' || r.battle_var || '))');

    execute v_new;
  end loop;

  if exists (
    select 1 from pg_proc p
    where p.pronamespace='public'::regnamespace
      and p.proname in ('resolve_expedition_pirates','resolve_expedition_aliens')
      and (p.prosrc not like '%AND ciu.round_number=(select max(round_number)%'
           or p.prosrc like '%AND ciu.alive WHERE fms2.fleet_id=p_fleet_id%')
  ) then
    raise exception 'CB-01g: survivor scope repair incomplete';
  end if;
end
$cb01g$;
