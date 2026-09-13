BEGIN;

REVOKE EXECUTE ON FUNCTION public.execute_expedition_merchant_trade(uuid,uuid,text,numeric) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.use_expedition_item(uuid,text,uuid) FROM PUBLIC, anon, authenticated;

-- Reuse the existing player-write guard for lifeform queues too. This keeps
-- SECURITY DEFINER queue entrypoints from being used against another player.
CREATE OR REPLACE FUNCTION public.enforce_player_write_access()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
declare
  v_player_id uuid;
  v_is_guest boolean;
  v_user_id uuid;
begin
  if tg_table_name = 'research_queue' then
    v_player_id := new.player_id;
  elsif tg_table_name in ('building_queue','shipyard_queue','lifeform_building_queue','lifeform_research_queue') then
    select p.player_id into v_player_id
    from public.planets p
    where p.id = new.planet_id;
  elsif tg_table_name = 'fleet_movements' then
    v_player_id := new.player_id;
  else
    raise exception 'Unsupported protected table: %', tg_table_name;
  end if;

  if v_player_id is null then
    raise exception 'PLAYER_ACCESS_DENIED';
  end if;

  select pl.is_guest, pl.user_id
    into v_is_guest, v_user_id
  from public.players pl
  where pl.id = v_player_id;

  if not found then
    raise exception 'PLAYER_NOT_FOUND';
  end if;

  v_user_id := auth.uid();

  if v_user_id is null then
    if coalesce(v_is_guest, false) is not true then
      raise exception 'AUTHENTICATION_REQUIRED';
    end if;
  elsif v_user_id is distinct from (select pl.user_id from public.players pl where pl.id = v_player_id) then
    raise exception 'PLAYER_NOT_OWNED_BY_AUTH_USER';
  end if;

  return new;
end;
$$;

DROP TRIGGER IF EXISTS trg_enforce_player_write_lifeform_building_queue ON public.lifeform_building_queue;
CREATE TRIGGER trg_enforce_player_write_lifeform_building_queue
BEFORE INSERT ON public.lifeform_building_queue
FOR EACH ROW EXECUTE FUNCTION public.enforce_player_write_access();

DROP TRIGGER IF EXISTS trg_enforce_player_write_lifeform_research_queue ON public.lifeform_research_queue;
CREATE TRIGGER trg_enforce_player_write_lifeform_research_queue
BEFORE INSERT ON public.lifeform_research_queue
FOR EACH ROW EXECUTE FUNCTION public.enforce_player_write_access();

-- Legacy resolver fix: ship and defense totals must be accumulated separately.
CREATE OR REPLACE FUNCTION public.resolve_combat(p_fleet_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_battle_id uuid;
    v_fleet public.fleet_movements%ROWTYPE;
    v_attacker_units bigint := 0;
    v_defender_ship_units bigint := 0;
    v_defense_units bigint := 0;
    v_defender_units bigint := 0;
    v_attacker_attack numeric := 0;
    v_attacker_shield numeric := 0;
    v_attacker_hull numeric := 0;
    v_defender_ship_attack numeric := 0;
    v_defender_ship_shield numeric := 0;
    v_defender_ship_hull numeric := 0;
    v_defense_attack numeric := 0;
    v_defense_shield numeric := 0;
    v_defense_hull numeric := 0;
    v_defender_attack numeric := 0;
    v_defender_shield numeric := 0;
    v_defender_hull numeric := 0;
begin
    SELECT * INTO v_fleet
    FROM public.fleet_movements
    WHERE id=p_fleet_id
    FOR UPDATE;

    IF NOT FOUND THEN RAISE EXCEPTION 'Fleet % no existe',p_fleet_id; END IF;
    IF v_fleet.mission_type <> 'ATTACK' THEN RAISE EXCEPTION 'Fleet % no es una misión ATTACK',p_fleet_id; END IF;
    IF v_fleet.destination_planet_id IS NULL THEN RAISE EXCEPTION 'La flota % no tiene planeta objetivo',p_fleet_id; END IF;

    SELECT cb.id INTO v_battle_id
    FROM public.combat_battles cb
    WHERE cb.fleet_id=p_fleet_id
    ORDER BY cb.created_at
    LIMIT 1
    FOR UPDATE;

    IF v_battle_id IS NOT NULL THEN RETURN v_battle_id; END IF;

    SELECT COALESCE(SUM(sd.attack*fms.quantity),0),
           COALESCE(SUM(sd.shield*fms.quantity),0),
           COALESCE(SUM(sd.hull*fms.quantity),0),
           COALESCE(SUM(fms.quantity),0)
    INTO v_attacker_attack,v_attacker_shield,v_attacker_hull,v_attacker_units
    FROM public.fleet_movement_ships fms
    JOIN public.ship_definitions sd ON sd.id=fms.ship_id
    WHERE fms.fleet_id=p_fleet_id;

    IF v_attacker_units<=0 THEN RAISE EXCEPTION 'La flota % no contiene naves',p_fleet_id; END IF;

    SELECT COALESCE(SUM(sd.attack*ps.quantity),0),
           COALESCE(SUM(sd.shield*ps.quantity),0),
           COALESCE(SUM(sd.hull*ps.quantity),0),
           COALESCE(SUM(ps.quantity),0)
    INTO v_defender_ship_attack,v_defender_ship_shield,v_defender_ship_hull,v_defender_ship_units
    FROM public.planet_ships ps
    JOIN public.ship_definitions sd ON sd.id=ps.ship_id
    WHERE ps.planet_id=v_fleet.destination_planet_id AND ps.quantity>0;

    SELECT COALESCE(SUM(dd.attack*pd.quantity),0),
           COALESCE(SUM(dd.shield*pd.quantity),0),
           COALESCE(SUM(dd.hull*pd.quantity),0),
           COALESCE(SUM(pd.quantity),0)
    INTO v_defense_attack,v_defense_shield,v_defense_hull,v_defense_units
    FROM public.planet_defenses pd
    JOIN public.defense_definitions dd ON dd.id=pd.defense_id
    WHERE pd.planet_id=v_fleet.destination_planet_id AND pd.quantity>0;

    v_defender_units := v_defender_ship_units + v_defense_units;
    v_defender_attack := v_defender_ship_attack + v_defense_attack;
    v_defender_shield := v_defender_ship_shield + v_defense_shield;
    v_defender_hull := v_defender_ship_hull + v_defense_hull;

    INSERT INTO public.combat_battles(
      fleet_id,attacker_player_id,defender_planet_id,
      attacker_ships_before,attacker_ships_after,
      defender_ships_before,defender_ships_after,
      defender_defenses_before,defender_defenses_after,
      defender_combat_units_before,defender_combat_units_after
    ) VALUES (
      p_fleet_id,v_fleet.player_id,v_fleet.destination_planet_id,
      v_attacker_units,v_attacker_units,
      v_defender_ship_units,v_defender_ship_units,
      v_defense_units,v_defense_units,
      v_defender_units,v_defender_units
    ) RETURNING id INTO v_battle_id;

    PERFORM public.initialize_individual_combat_units(v_battle_id);
    RETURN v_battle_id;
end;
$$;

COMMIT;
