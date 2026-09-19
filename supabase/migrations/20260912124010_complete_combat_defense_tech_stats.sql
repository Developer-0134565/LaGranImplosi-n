CREATE OR REPLACE FUNCTION public.get_combat_defense_attack(p_player_id uuid, p_defense_id text)
RETURNS numeric
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT dd.attack * (1 + public.get_player_research_level(p_player_id,'weapons_technology') * 0.10)
    FROM public.defense_definitions dd
    WHERE dd.id = p_defense_id;
$$;

CREATE OR REPLACE FUNCTION public.get_combat_defense_shield(p_player_id uuid, p_defense_id text)
RETURNS numeric
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT dd.shield * (1 + public.get_player_research_level(p_player_id,'shielding_technology') * 0.10)
    FROM public.defense_definitions dd
    WHERE dd.id = p_defense_id;
$$;

CREATE OR REPLACE FUNCTION public.get_combat_defense_hull(p_player_id uuid, p_defense_id text)
RETURNS numeric
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT (dd.hull / 10) * (1 + public.get_player_research_level(p_player_id,'armour_technology') * 0.10)
    FROM public.defense_definitions dd
    WHERE dd.id = p_defense_id;
$$;

CREATE OR REPLACE FUNCTION public.initialize_individual_combat_units(p_battle_id uuid)
RETURNS integer
LANGUAGE plpgsql
AS $function$
DECLARE
    v_fleet_id uuid;
    v_planet_id uuid;
    v_attacker_player_id uuid;
    v_defender_player_id uuid;
    v_count integer;
BEGIN
    SELECT cb.fleet_id, cb.defender_planet_id, cb.attacker_player_id
    INTO v_fleet_id, v_planet_id, v_attacker_player_id
    FROM public.combat_battles cb WHERE cb.id=p_battle_id;
    IF v_fleet_id IS NULL THEN RAISE EXCEPTION 'Batalla % no encontrada',p_battle_id; END IF;

    SELECT p.player_id INTO v_defender_player_id FROM public.planets p WHERE p.id=v_planet_id;

    INSERT INTO public.combat_individual_units (
      battle_id,round_number,side,unit_type,unit_id,unit_number,
      attack,shield_max,shield_current,structural_integrity,hull_max,hull_current)
    SELECT p_battle_id,1,'ATTACKER','SHIP',fms.ship_id,gs.n,
      public.get_combat_ship_attack(v_attacker_player_id,fms.ship_id),
      public.get_combat_ship_shield(v_attacker_player_id,fms.ship_id),
      public.get_combat_ship_shield(v_attacker_player_id,fms.ship_id),
      public.get_combat_ship_hull(v_attacker_player_id,fms.ship_id)*10,
      public.get_combat_ship_hull(v_attacker_player_id,fms.ship_id),
      public.get_combat_ship_hull(v_attacker_player_id,fms.ship_id)
    FROM public.fleet_movement_ships fms
    CROSS JOIN LATERAL generate_series(1,fms.quantity) gs(n)
    WHERE fms.fleet_id=v_fleet_id;

    INSERT INTO public.combat_individual_units (
      battle_id,round_number,side,unit_type,unit_id,unit_number,
      attack,shield_max,shield_current,structural_integrity,hull_max,hull_current)
    SELECT p_battle_id,1,'DEFENDER','SHIP',ps.ship_id,gs.n,
      public.get_combat_ship_attack(v_defender_player_id,ps.ship_id),
      public.get_combat_ship_shield(v_defender_player_id,ps.ship_id),
      public.get_combat_ship_shield(v_defender_player_id,ps.ship_id),
      public.get_combat_ship_hull(v_defender_player_id,ps.ship_id)*10,
      public.get_combat_ship_hull(v_defender_player_id,ps.ship_id),
      public.get_combat_ship_hull(v_defender_player_id,ps.ship_id)
    FROM public.planet_ships ps
    CROSS JOIN LATERAL generate_series(1,ps.quantity) gs(n)
    WHERE ps.planet_id=v_planet_id AND ps.quantity>0;

    INSERT INTO public.combat_individual_units (
      battle_id,round_number,side,unit_type,unit_id,unit_number,
      attack,shield_max,shield_current,structural_integrity,hull_max,hull_current)
    SELECT p_battle_id,1,'DEFENDER','DEFENSE',pd.defense_id,gs.n,
      public.get_combat_defense_attack(v_defender_player_id,pd.defense_id),
      public.get_combat_defense_shield(v_defender_player_id,pd.defense_id),
      public.get_combat_defense_shield(v_defender_player_id,pd.defense_id),
      public.get_combat_defense_hull(v_defender_player_id,pd.defense_id)*10,
      public.get_combat_defense_hull(v_defender_player_id,pd.defense_id),
      public.get_combat_defense_hull(v_defender_player_id,pd.defense_id)
    FROM public.planet_defenses pd
    CROSS JOIN LATERAL generate_series(1,pd.quantity) gs(n)
    WHERE pd.planet_id=v_planet_id AND pd.quantity>0;

    SELECT count(*)::integer INTO v_count FROM public.combat_individual_units
    WHERE battle_id=p_battle_id AND round_number=1;
    RETURN v_count;
END;
$function$;