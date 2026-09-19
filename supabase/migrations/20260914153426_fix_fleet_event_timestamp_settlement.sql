CREATE OR REPLACE FUNCTION public.resolve_transport_arrival(p_fleet_id uuid)
RETURNS TABLE(fleet_id uuid, destination_planet_id uuid, delivered_metal numeric, delivered_crystal numeric, delivered_deuterium numeric, status text, returns_at timestamp with time zone)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
    v_fleet RECORD;
    v_duration interval;
    v_returns_at timestamptz;
BEGIN
    SELECT fm.id, fm.origin_planet_id, fm.destination_planet_id, fm.mission_type,
           fm.status, fm.started_at, fm.arrives_at, fm.metal, fm.crystal, fm.deuterium
    INTO v_fleet
    FROM public.fleet_movements fm
    WHERE fm.id = p_fleet_id
    FOR UPDATE;

    IF NOT FOUND THEN RAISE EXCEPTION 'Fleet not found'; END IF;
    IF v_fleet.mission_type <> 'TRANSPORT' THEN RAISE EXCEPTION 'Fleet is not a TRANSPORT mission'; END IF;
    IF v_fleet.status <> 'ARRIVED' THEN RAISE EXCEPTION 'Transport must be ARRIVED. Current status: %', v_fleet.status; END IF;
    IF v_fleet.destination_planet_id IS NULL THEN RAISE EXCEPTION 'Transport has no destination'; END IF;

    v_duration := v_fleet.arrives_at - v_fleet.started_at;

    -- Settlement belongs to the event timestamp, not the worker execution time.
    -- This preserves offline production and prevents a late worker from granting
    -- production after the transport has already arrived.
    PERFORM public.update_planet_resources_until(
        v_fleet.destination_planet_id,
        v_fleet.arrives_at
    );

    UPDATE public.planet_resources pr
    SET metal = pr.metal + v_fleet.metal,
        crystal = pr.crystal + v_fleet.crystal,
        deuterium = pr.deuterium + v_fleet.deuterium,
        updated_at = clock_timestamp()
    WHERE pr.planet_id = v_fleet.destination_planet_id;

    IF NOT FOUND THEN RAISE EXCEPTION 'Destination planet resources not found'; END IF;

    -- Keep the scheduled timeline anchored to the original arrival event.
    v_returns_at := v_fleet.arrives_at + v_duration;

    UPDATE public.fleet_movements fm
    SET metal = 0,
        crystal = 0,
        deuterium = 0,
        status = 'RETURNING',
        returns_at = v_returns_at
    WHERE fm.id = p_fleet_id;

    RETURN QUERY
    SELECT v_fleet.id, v_fleet.destination_planet_id,
           v_fleet.metal, v_fleet.crystal, v_fleet.deuterium,
           'RETURNING'::text, v_returns_at;
END;
$$;

CREATE OR REPLACE FUNCTION public.resolve_espionage_arrival(p_fleet_id uuid)
RETURNS TABLE(fleet_id uuid, target_planet_id uuid, report_id uuid, status text, returns_at timestamp with time zone)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
    v_fleet record;
    v_target record;
    v_report_id uuid;
    v_duration interval;
    v_esp integer := 0;
    v_target_esp integer := 0;
    v_returns_at timestamptz;
BEGIN
    SELECT fm.* INTO v_fleet
    FROM public.fleet_movements fm
    WHERE fm.id = p_fleet_id
    FOR UPDATE;

    IF NOT FOUND THEN RAISE EXCEPTION 'Fleet not found'; END IF;
    IF v_fleet.mission_type <> 'ESPIONAGE' THEN RAISE EXCEPTION 'Fleet is not ESPIONAGE'; END IF;
    IF v_fleet.status <> 'ARRIVED' THEN RAISE EXCEPTION 'Espionage must be ARRIVED'; END IF;
    IF v_fleet.destination_planet_id IS NULL THEN RAISE EXCEPTION 'Espionage has no target'; END IF;

    SELECT p.* INTO v_target
    FROM public.planets p
    WHERE p.id = v_fleet.destination_planet_id
      AND NOT p.is_destroyed
    FOR UPDATE;

    IF NOT FOUND THEN RAISE EXCEPTION 'Target planet not found'; END IF;

    v_esp := COALESCE(public.get_player_research_level(v_fleet.player_id,'espionage_technology'),0);
    IF v_target.player_id IS NOT NULL THEN
        v_target_esp := COALESCE(public.get_player_research_level(v_target.player_id,'espionage_technology'),0);
    END IF;

    -- The report observes the target exactly when the probe arrives.
    PERFORM public.update_planet_resources_until(v_target.id, v_fleet.arrives_at);

    INSERT INTO public.espionage_reports(
        fleet_id, player_id, target_planet_id, espionage_level, target_espionage_level,
        metal, crystal, deuterium, energy, fleet, defenses
    )
    SELECT v_fleet.id, v_fleet.player_id, v_target.id, v_esp, v_target_esp,
           pr.metal, pr.crystal, pr.deuterium,
           COALESCE((SELECT SUM(ps.quantity*sd.attack)
                     FROM public.planet_ships ps
                     JOIN public.ship_definitions sd ON sd.id=ps.ship_id
                     WHERE ps.planet_id=v_target.id),0),
           COALESCE((SELECT jsonb_object_agg(ps.ship_id,ps.quantity)
                     FROM public.planet_ships ps WHERE ps.planet_id=v_target.id),'{}'::jsonb),
           COALESCE((SELECT jsonb_object_agg(pd.defense_id,pd.quantity)
                     FROM public.planet_defenses pd WHERE pd.planet_id=v_target.id),'{}'::jsonb)
    FROM public.planet_resources pr
    WHERE pr.planet_id=v_target.id
    ON CONFLICT ON CONSTRAINT espionage_reports_fleet_id_key
    DO UPDATE SET created_at=clock_timestamp()
    RETURNING public.espionage_reports.id INTO v_report_id;

    v_duration := v_fleet.arrives_at - v_fleet.started_at;
    v_returns_at := v_fleet.arrives_at + v_duration;

    UPDATE public.fleet_movements
    SET status='RETURNING', returns_at=v_returns_at
    WHERE id=p_fleet_id;

    RETURN QUERY SELECT v_fleet.id,v_target.id,v_report_id,'RETURNING'::text,v_returns_at;
END;
$$;

CREATE OR REPLACE FUNCTION public.resolve_colonize_arrival(p_fleet_id uuid)
RETURNS TABLE(fleet_id uuid, new_planet_id uuid, galaxy integer, system integer, "position" integer, status text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
    v_fleet record;
    v_origin record;
    v_ship_qty bigint := 0;
    v_new uuid;
    v_fields integer := 100;
BEGIN
    SELECT fm.* INTO v_fleet FROM public.fleet_movements fm WHERE fm.id=p_fleet_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Fleet not found'; END IF;
    IF v_fleet.mission_type<>'COLONIZE' THEN RAISE EXCEPTION 'Fleet is not COLONIZE'; END IF;
    IF v_fleet.status<>'ARRIVED' THEN RAISE EXCEPTION 'Colonize must be ARRIVED'; END IF;
    IF v_fleet.destination_planet_id IS NOT NULL THEN RAISE EXCEPTION 'Colonize target must be an empty coordinate'; END IF;

    SELECT p.* INTO v_origin FROM public.planets p WHERE p.id=v_fleet.origin_planet_id FOR UPDATE;
    SELECT COALESCE(SUM(fms.quantity),0) INTO v_ship_qty
    FROM public.fleet_movement_ships fms
    WHERE fms.fleet_id=p_fleet_id AND fms.ship_id='colony_ship';
    IF v_ship_qty<=0 THEN RAISE EXCEPTION 'Colonize requires colony ship'; END IF;

    IF EXISTS(
        SELECT 1 FROM public.planets p
        WHERE p.universe_id=v_origin.universe_id
          AND p.galaxy=v_fleet.destination_galaxy
          AND p.system=v_fleet.destination_system
          AND p.position=v_fleet.destination_position
          AND NOT p.is_destroyed
    ) THEN
        -- A late worker must not extend the flight. The retry return is anchored
        -- to the original arrival event.
        UPDATE public.fleet_movements fm
        SET status='RETURNING', returns_at=v_fleet.arrives_at+(fm.arrives_at-fm.started_at)
        WHERE fm.id=p_fleet_id;
        RETURN QUERY SELECT v_fleet.id,NULL::uuid,v_fleet.destination_galaxy,v_fleet.destination_system,v_fleet.destination_position,'RETURNING'::text;
        RETURN;
    END IF;

    INSERT INTO public.planets(
        universe_id,player_id,name,galaxy,system,position,
        temperature_min,temperature_max,fields_total,fields_used,is_homeworld,is_destroyed
    ) VALUES(
        v_origin.universe_id,v_fleet.player_id,
        'Colony '||v_fleet.destination_galaxy||':'||v_fleet.destination_system||':'||v_fleet.destination_position,
        v_fleet.destination_galaxy,v_fleet.destination_system,v_fleet.destination_position,
        -20,20,v_fields,0,false,false
    ) RETURNING id INTO v_new;

    INSERT INTO public.planet_resources(planet_id,metal,crystal,deuterium)
    VALUES(v_new,0,0,0)
    ON CONFLICT(planet_id) DO NOTHING;

    DELETE FROM public.fleet_movement_ships
    WHERE fleet_id=p_fleet_id AND ship_id='colony_ship';

    UPDATE public.fleet_movements fm
    SET destination_planet_id=v_new,status='COMPLETED',returns_at=NULL
    WHERE fm.id=p_fleet_id;

    RETURN QUERY SELECT v_fleet.id,v_new,v_fleet.destination_galaxy,v_fleet.destination_system,v_fleet.destination_position,'COMPLETED'::text;
END;
$$;

CREATE OR REPLACE FUNCTION public.apply_attack_loot(p_battle_id uuid)
RETURNS TABLE(loot_metal numeric, loot_crystal numeric, loot_deuterium numeric, cargo_capacity numeric)
LANGUAGE plpgsql
AS $$
declare
  v_battle public.combat_battles%rowtype;
  v_fleet public.fleet_movements%rowtype;
  v_res public.planet_resources%rowtype;
  v_capacity numeric := 0;
  v_remaining numeric;
  v_metal_cap numeric;
  v_crystal_cap numeric;
  v_deut_cap numeric;
  v_m numeric := 0;
  v_c numeric := 0;
  v_d numeric := 0;
  v_take numeric;
begin
  select * into v_battle from public.combat_battles where id=p_battle_id for update;
  if not found then raise exception 'Battle % not found',p_battle_id; end if;

  if v_battle.loot_applied_at is not null then
    return query select v_battle.loot_metal,v_battle.loot_crystal,v_battle.loot_deuterium,0::numeric;
    return;
  end if;

  if not coalesce(v_battle.attacker_win,false) then
    update public.combat_battles
      set loot_applied_at=clock_timestamp(),loot_metal=0,loot_crystal=0,loot_deuterium=0
      where id=p_battle_id;
    return query select 0::numeric,0::numeric,0::numeric,0::numeric;
    return;
  end if;

  select * into v_fleet from public.fleet_movements where id=v_battle.fleet_id for update;
  if not found then raise exception 'Fleet % not found for battle %',v_battle.fleet_id,p_battle_id; end if;

  select coalesce(sum(fms.quantity * sd.cargo_capacity),0)
    into v_capacity
  from public.fleet_movement_ships fms
  join public.ship_definitions sd on sd.id=fms.ship_id
  where fms.fleet_id=v_fleet.id and fms.quantity>0;

  if v_capacity <= 0 then
    update public.combat_battles set loot_applied_at=clock_timestamp() where id=p_battle_id;
    return query select 0::numeric,0::numeric,0::numeric,v_capacity;
    return;
  end if;

  -- Loot is an arrival-time transaction. Settle production only through the
  -- attack event timestamp before calculating the 50% plunder caps.
  perform public.update_planet_resources_until(v_battle.defender_planet_id, v_fleet.arrives_at);

  select * into v_res from public.planet_resources where planet_id=v_battle.defender_planet_id for update;
  if not found then raise exception 'Resources for defender planet % not found',v_battle.defender_planet_id; end if;

  v_metal_cap := greatest(0, floor(greatest(v_res.metal,0) * 0.5));
  v_crystal_cap := greatest(0, floor(greatest(v_res.crystal,0) * 0.5));
  v_deut_cap := greatest(0, floor(greatest(v_res.deuterium,0) * 0.5));
  v_remaining := floor(v_capacity);

  v_m := least(v_metal_cap, floor(v_remaining/3));
  v_remaining := v_remaining-v_m;
  v_c := least(v_crystal_cap, floor(v_remaining/2));
  v_remaining := v_remaining-v_c;
  v_d := least(v_deut_cap, v_remaining);
  v_remaining := v_remaining-v_d;

  v_take := least(v_metal_cap-v_m,v_remaining);
  v_m := v_m+greatest(v_take,0); v_remaining := v_remaining-greatest(v_take,0);
  v_take := least(v_crystal_cap-v_c,v_remaining);
  v_c := v_c+greatest(v_take,0); v_remaining := v_remaining-greatest(v_take,0);
  v_take := least(v_deut_cap-v_d,v_remaining);
  v_d := v_d+greatest(v_take,0); v_remaining := v_remaining-greatest(v_take,0);

  update public.planet_resources
  set metal=greatest(0,metal-v_m),
      crystal=greatest(0,crystal-v_c),
      deuterium=greatest(0,deuterium-v_d),
      updated_at=clock_timestamp()
  where planet_id=v_battle.defender_planet_id;

  update public.fleet_movements
  set metal=coalesce(metal,0)+v_m,
      crystal=coalesce(crystal,0)+v_c,
      deuterium=coalesce(deuterium,0)+v_d
  where id=v_fleet.id and status='ARRIVED';

  update public.combat_battles
  set loot_metal=v_m,loot_crystal=v_c,loot_deuterium=v_d,loot_applied_at=clock_timestamp()
  where id=p_battle_id;

  return query select v_m,v_c,v_d,v_capacity;
end;
$$;

CREATE OR REPLACE FUNCTION public.execute_expedition_merchant_trade(p_player_id uuid, p_planet_id uuid, p_sell_resource text, p_sell_amount numeric)
RETURNS TABLE(sold numeric, bought numeric, bought_resource text, remaining_merchant boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
    v_merchant record;
    v_res record;
    v_caps record;
    v_buy numeric;
    v_ratio numeric;
    v_capacity numeric;
    v_resource text;
BEGIN
    IF p_sell_amount <= 0 THEN RAISE EXCEPTION 'Sell amount must be positive'; END IF;
    IF p_sell_resource NOT IN ('METAL','CRYSTAL','DEUTERIUM') THEN RAISE EXCEPTION 'Invalid sell resource'; END IF;

    -- Merchant trades are immediate resource transactions, so first settle the
    -- production clock to the transaction time.
    PERFORM public.update_planet_resources_until(p_planet_id, now());

    SELECT * INTO v_merchant FROM public.player_expedition_merchants
    WHERE player_id=p_player_id AND active=true FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'No active merchant for player %',p_player_id; END IF;
    IF p_sell_resource=v_merchant.resource THEN RAISE EXCEPTION 'Merchant buys %, not %',v_merchant.resource,p_sell_resource; END IF;

    SELECT * INTO v_res FROM public.planet_resources WHERE planet_id=p_planet_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Planet resources not found'; END IF;
    SELECT * INTO v_caps FROM public.calculate_planet_storage(p_planet_id);

    IF p_sell_resource='METAL' AND v_res.metal < p_sell_amount THEN RAISE EXCEPTION 'Insufficient metal'; END IF;
    IF p_sell_resource='CRYSTAL' AND v_res.crystal < p_sell_amount THEN RAISE EXCEPTION 'Insufficient crystal'; END IF;
    IF p_sell_resource='DEUTERIUM' AND v_res.deuterium < p_sell_amount THEN RAISE EXCEPTION 'Insufficient deuterium'; END IF;

    v_resource:=v_merchant.resource;
    IF v_resource='METAL' THEN v_ratio:=v_merchant.metal_rate; v_capacity:=GREATEST(0,v_caps.metal_capacity-v_res.metal);
    ELSIF v_resource='CRYSTAL' THEN v_ratio:=v_merchant.crystal_rate; v_capacity:=GREATEST(0,v_caps.crystal_capacity-v_res.crystal);
    ELSE v_ratio:=v_merchant.deuterium_rate; v_capacity:=GREATEST(0,v_caps.deuterium_capacity-v_res.deuterium);
    END IF;

    IF v_resource='METAL' THEN
        IF p_sell_resource='CRYSTAL' THEN v_buy:=floor(p_sell_amount*(v_ratio/v_merchant.crystal_rate));
        ELSIF p_sell_resource='DEUTERIUM' THEN v_buy:=floor(p_sell_amount*v_ratio); ELSE RAISE EXCEPTION 'Invalid merchant trade'; END IF;
    ELSIF v_resource='CRYSTAL' THEN
        IF p_sell_resource='METAL' THEN v_buy:=floor(p_sell_amount*(v_ratio/v_merchant.metal_rate));
        ELSIF p_sell_resource='DEUTERIUM' THEN v_buy:=floor(p_sell_amount*v_ratio); ELSE RAISE EXCEPTION 'Invalid merchant trade'; END IF;
    ELSE
        IF p_sell_resource='METAL' THEN v_buy:=floor(p_sell_amount/v_merchant.metal_rate);
        ELSIF p_sell_resource='CRYSTAL' THEN v_buy:=floor(p_sell_amount/v_merchant.crystal_rate); ELSE RAISE EXCEPTION 'Invalid merchant trade'; END IF;
    END IF;

    v_buy:=LEAST(v_buy,v_capacity);
    IF v_buy <= 0 THEN RAISE EXCEPTION 'Insufficient storage for merchant purchase'; END IF;

    IF v_resource='METAL' THEN
        IF p_sell_resource='CRYSTAL' THEN p_sell_amount:=LEAST(p_sell_amount,floor(v_buy*v_merchant.crystal_rate));
        ELSE p_sell_amount:=LEAST(p_sell_amount,floor(v_buy/v_merchant.metal_rate)); END IF;
    ELSIF v_resource='CRYSTAL' THEN
        IF p_sell_resource='METAL' THEN p_sell_amount:=LEAST(p_sell_amount,floor(v_buy*v_merchant.metal_rate));
        ELSE p_sell_amount:=LEAST(p_sell_amount,floor(v_buy/v_merchant.crystal_rate)); END IF;
    ELSE
        p_sell_amount:=LEAST(p_sell_amount,floor(v_buy*v_merchant.metal_rate));
    END IF;

    IF p_sell_resource='METAL' THEN UPDATE public.planet_resources SET metal=metal-p_sell_amount,updated_at=clock_timestamp() WHERE planet_id=p_planet_id;
    ELSIF p_sell_resource='CRYSTAL' THEN UPDATE public.planet_resources SET crystal=crystal-p_sell_amount,updated_at=clock_timestamp() WHERE planet_id=p_planet_id;
    ELSE UPDATE public.planet_resources SET deuterium=deuterium-p_sell_amount,updated_at=clock_timestamp() WHERE planet_id=p_planet_id; END IF;

    IF v_resource='METAL' THEN UPDATE public.planet_resources SET metal=metal+v_buy,updated_at=clock_timestamp() WHERE planet_id=p_planet_id;
    ELSIF v_resource='CRYSTAL' THEN UPDATE public.planet_resources SET crystal=crystal+v_buy,updated_at=clock_timestamp() WHERE planet_id=p_planet_id;
    ELSE UPDATE public.planet_resources SET deuterium=deuterium+v_buy,updated_at=clock_timestamp() WHERE planet_id=p_planet_id; END IF;

    UPDATE public.player_expedition_merchants SET active=false,updated_at=clock_timestamp() WHERE player_id=p_player_id;
    sold:=p_sell_amount; bought:=v_buy; bought_resource:=v_resource; remaining_merchant:=false; RETURN NEXT;
END;
$$;