-- =============================================================================
-- RECOVERED MIGRATION — 20260916020215
-- ledger name : harden_fleet_arrival_queue_timestamps
-- provenance  : Supabase LIVE supabase_migrations.schema_migrations.statements
--               (verbatim payload of the original apply_migration call; recovered during
--                blocker resolution of the inverse-drift audit, 2026-09-18)
-- ALREADY APPLIED IN LIVE — do not re-apply; this file exists for traceability only.
-- =============================================================================
CREATE OR REPLACE FUNCTION public.process_shipyard_queue_until(p_planet_id uuid, p_until timestamptz)
RETURNS TABLE(queue_id uuid, ship_id text, quantity bigint, status text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $function$
DECLARE v_queue record;
BEGIN
  FOR v_queue IN
    SELECT sq.id,sq.planet_id,sq.ship_id AS queued_ship_id,sq.quantity AS queued_quantity,sq.finishes_at
    FROM public.shipyard_queue sq
    WHERE sq.planet_id=p_planet_id AND sq.status='BUILDING' AND sq.finishes_at<=p_until
    ORDER BY sq.finishes_at,sq.created_at,sq.id
    FOR UPDATE SKIP LOCKED
  LOOP
    INSERT INTO public.planet_ships AS ps(planet_id,ship_id,quantity)
    VALUES(v_queue.planet_id,v_queue.queued_ship_id,v_queue.queued_quantity)
    ON CONFLICT ON CONSTRAINT planet_ships_pkey
    DO UPDATE SET quantity=ps.quantity+EXCLUDED.quantity;
    UPDATE public.shipyard_queue sq SET status='COMPLETED' WHERE sq.id=v_queue.id AND sq.status='BUILDING';
    queue_id:=v_queue.id; ship_id:=v_queue.queued_ship_id; quantity:=v_queue.queued_quantity; status:='COMPLETED'; RETURN NEXT;
  END LOOP;
END;
$function$;

CREATE OR REPLACE FUNCTION public.process_defense_queue_until(p_planet_id uuid, p_until timestamptz)
RETURNS TABLE(queue_id uuid, defense_id text, quantity bigint, status text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $function$
DECLARE v_queue record;
BEGIN
  FOR v_queue IN
    SELECT dq.id,dq.planet_id,dq.defense_id AS queued_defense_id,dq.quantity AS queued_quantity,dq.finishes_at
    FROM public.defense_queue dq
    WHERE dq.planet_id=p_planet_id AND dq.status='BUILDING' AND dq.finishes_at<=p_until
    ORDER BY dq.finishes_at,dq.created_at,dq.id
    FOR UPDATE SKIP LOCKED
  LOOP
    INSERT INTO public.planet_defenses(planet_id,defense_id,quantity,updated_at)
    VALUES(v_queue.planet_id,v_queue.queued_defense_id,v_queue.queued_quantity,now())
    ON CONFLICT ON CONSTRAINT planet_defenses_planet_defense_unique
    DO UPDATE SET quantity=public.planet_defenses.quantity+EXCLUDED.quantity,updated_at=now();
    UPDATE public.defense_queue dq SET status='COMPLETED' WHERE dq.id=v_queue.id AND dq.status='BUILDING';
    queue_id:=v_queue.id; defense_id:=v_queue.queued_defense_id; quantity:=v_queue.queued_quantity; status:='COMPLETED'; RETURN NEXT;
  END LOOP;
END;
$function$;

CREATE OR REPLACE FUNCTION public.resolve_attack_arrival(p_fleet_id uuid)
RETURNS uuid LANGUAGE plpgsql SET search_path TO 'pg_catalog','public'
AS $function$
declare
  v_fleet public.fleet_movements%rowtype; v_battle_id uuid; v_last_round integer;
begin
  select * into v_fleet from public.fleet_movements where id=p_fleet_id for update;
  if not found then raise exception 'Fleet % no existe',p_fleet_id; end if;
  if v_fleet.mission_type<>'ATTACK' then raise exception 'Fleet % no es ATTACK',p_fleet_id; end if;
  if v_fleet.status not in ('ARRIVED','RETURNING','COMPLETED') then raise exception 'Fleet % no está lista para resolver ataque. Estado: %',p_fleet_id,v_fleet.status; end if;
  select cb.id into v_battle_id from public.combat_battles cb where cb.fleet_id=p_fleet_id order by cb.created_at limit 1 for update;
  if v_battle_id is null then v_battle_id:=public.resolve_combat(p_fleet_id); end if;
  if v_fleet.status<>'ARRIVED' then return v_battle_id; end if;

  -- The defender is observed at the attack's logical arrival timestamp.
  perform public.update_planet_resources_until(v_fleet.destination_planet_id,v_fleet.arrives_at);
  perform public.process_shipyard_queue_until(v_fleet.destination_planet_id,v_fleet.arrives_at);
  perform public.process_defense_queue_until(v_fleet.destination_planet_id,v_fleet.arrives_at);

  if not exists(select 1 from public.combat_battles where id=v_battle_id and finished_at is not null) then perform public.run_expedition_combat(v_battle_id); end if;
  select max(round_number) into v_last_round from public.combat_individual_units where battle_id=v_battle_id;
  if v_last_round is null then raise exception 'Battle % finished without rounds',v_battle_id; end if;
  perform public.sync_combat_battle_final_counts(v_battle_id);
  delete from public.fleet_movement_ships where fleet_id=p_fleet_id;
  insert into public.fleet_movement_ships(fleet_id,ship_id,quantity)
  select p_fleet_id,ciu.unit_id,count(*)::bigint from public.combat_individual_units ciu
  where ciu.battle_id=v_battle_id and ciu.round_number=v_last_round and ciu.side='ATTACKER' and ciu.unit_type='SHIP' and ciu.alive group by ciu.unit_id;
  update public.planet_ships ps set quantity=coalesce(src.quantity,0) from (select ciu.unit_id,count(*)::bigint quantity from public.combat_individual_units ciu where ciu.battle_id=v_battle_id and ciu.round_number=v_last_round and ciu.side='DEFENDER' and ciu.unit_type='SHIP' and ciu.alive group by ciu.unit_id) src where ps.planet_id=v_fleet.destination_planet_id and ps.ship_id=src.unit_id;
  update public.planet_ships ps set quantity=0 where ps.planet_id=v_fleet.destination_planet_id and exists(select 1 from public.combat_individual_units ciu where ciu.battle_id=v_battle_id and ciu.round_number=v_last_round and ciu.side='DEFENDER' and ciu.unit_type='SHIP' and ciu.unit_id=ps.ship_id) and not exists(select 1 from public.combat_individual_units ciu where ciu.battle_id=v_battle_id and ciu.round_number=v_last_round and ciu.side='DEFENDER' and ciu.unit_type='SHIP' and ciu.unit_id=ps.ship_id and ciu.alive);
  update public.planet_defenses pd set quantity=coalesce(src.quantity,0) from (select ciu.unit_id,count(*)::bigint quantity from public.combat_individual_units ciu where ciu.battle_id=v_battle_id and ciu.round_number=v_last_round and ciu.side='DEFENDER' and ciu.unit_type='DEFENSE' and ciu.alive group by ciu.unit_id) src where pd.planet_id=v_fleet.destination_planet_id and pd.defense_id=src.unit_id;
  update public.planet_defenses pd set quantity=0 where pd.planet_id=v_fleet.destination_planet_id and exists(select 1 from public.combat_individual_units ciu where ciu.battle_id=v_battle_id and ciu.round_number=v_last_round and ciu.side='DEFENDER' and ciu.unit_type='DEFENSE' and ciu.unit_id=pd.defense_id) and not exists(select 1 from public.combat_individual_units ciu where ciu.battle_id=v_battle_id and ciu.round_number=v_last_round and ciu.side='DEFENDER' and ciu.unit_type='DEFENSE' and ciu.unit_id=pd.defense_id and ciu.alive);
  perform * from public.apply_attack_loot(v_battle_id);
  perform * from public.repair_defenses_after_combat(v_battle_id);
  perform public.create_combat_debris(v_battle_id);
  update public.fleet_movements set status='RETURNING',returns_at=arrives_at+(arrives_at-started_at) where id=p_fleet_id and status='ARRIVED';
  return v_battle_id;
end;
$function$;

CREATE OR REPLACE FUNCTION public.resolve_espionage_arrival(p_fleet_id uuid)
RETURNS TABLE(fleet_id uuid,target_planet_id uuid,report_id uuid,status text,returns_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $function$
DECLARE v_fleet record; v_target record; v_report_id uuid; v_duration interval; v_esp integer:=0; v_target_esp integer:=0; v_returns_at timestamptz;
BEGIN
  SELECT fm.* INTO v_fleet FROM public.fleet_movements fm WHERE fm.id=p_fleet_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Fleet not found'; END IF;
  IF v_fleet.mission_type<>'ESPIONAGE' THEN RAISE EXCEPTION 'Fleet is not ESPIONAGE'; END IF;
  IF v_fleet.status<>'ARRIVED' THEN RAISE EXCEPTION 'Espionage must be ARRIVED'; END IF;
  IF v_fleet.destination_planet_id IS NULL THEN RAISE EXCEPTION 'Espionage has no target'; END IF;
  SELECT p.* INTO v_target FROM public.planets p WHERE p.id=v_fleet.destination_planet_id AND NOT p.is_destroyed FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Target planet not found'; END IF;
  PERFORM public.update_planet_resources_until(v_target.id,v_fleet.arrives_at);
  PERFORM public.process_shipyard_queue_until(v_target.id,v_fleet.arrives_at);
  PERFORM public.process_defense_queue_until(v_target.id,v_fleet.arrives_at);
  v_esp:=COALESCE(public.get_player_research_level(v_fleet.player_id,'espionage_technology'),0);
  IF v_target.player_id IS NOT NULL THEN v_target_esp:=COALESCE(public.get_player_research_level(v_target.player_id,'espionage_technology'),0); END IF;
  INSERT INTO public.espionage_reports(fleet_id,player_id,target_planet_id,espionage_level,target_espionage_level,metal,crystal,deuterium,energy,fleet,defenses)
  SELECT v_fleet.id,v_fleet.player_id,v_target.id,v_esp,v_target_esp,pr.metal,pr.crystal,pr.deuterium,COALESCE((SELECT SUM(ps.quantity*sd.attack) FROM public.planet_ships ps JOIN public.ship_definitions sd ON sd.id=ps.ship_id WHERE ps.planet_id=v_target.id),0),COALESCE((SELECT jsonb_object_agg(ps.ship_id,ps.quantity) FROM public.planet_ships ps WHERE ps.planet_id=v_target.id),'{}'::jsonb),COALESCE((SELECT jsonb_object_agg(pd.defense_id,pd.quantity) FROM public.planet_defenses pd WHERE pd.planet_id=v_target.id),'{}'::jsonb)
  FROM public.planet_resources pr WHERE pr.planet_id=v_target.id ON CONFLICT ON CONSTRAINT espionage_reports_fleet_id_key DO UPDATE SET created_at=clock_timestamp() RETURNING public.espionage_reports.id INTO v_report_id;
  v_duration:=v_fleet.arrives_at-v_fleet.started_at; v_returns_at:=v_fleet.arrives_at+v_duration;
  UPDATE public.fleet_movements SET status='RETURNING',returns_at=v_returns_at WHERE id=p_fleet_id;
  RETURN QUERY SELECT v_fleet.id,v_target.id,v_report_id,'RETURNING'::text,v_returns_at;
END;
$function$;
