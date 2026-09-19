CREATE OR REPLACE FUNCTION public.resolve_espionage_arrival(p_fleet_id uuid) RETURNS TABLE(fleet_id uuid,target_planet_id uuid,report_id uuid,status text,returns_at timestamptz) LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $function$
DECLARE v_fleet record; v_target record; v_report_id uuid; v_duration interval; v_esp integer:=0; v_target_esp integer:=0; v_returns_at timestamptz;
BEGIN
 SELECT fm.* INTO v_fleet FROM public.fleet_movements fm WHERE fm.id=p_fleet_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Fleet not found'; END IF;
 IF v_fleet.mission_type<>'ESPIONAGE' THEN RAISE EXCEPTION 'Fleet is not ESPIONAGE'; END IF;
 IF v_fleet.status<>'ARRIVED' THEN RAISE EXCEPTION 'Espionage must be ARRIVED'; END IF;
 IF v_fleet.destination_planet_id IS NULL THEN RAISE EXCEPTION 'Espionage has no target'; END IF;
 SELECT p.* INTO v_target FROM public.planets p WHERE p.id=v_fleet.destination_planet_id AND NOT p.is_destroyed FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Target planet not found'; END IF;
 v_esp:=COALESCE(public.get_player_research_level(v_fleet.player_id,'espionage_technology'),0);
 IF v_target.player_id IS NOT NULL THEN v_target_esp:=COALESCE(public.get_player_research_level(v_target.player_id,'espionage_technology'),0); END IF;
 PERFORM public.update_planet_resources_until(v_target.id,now());
 INSERT INTO public.espionage_reports(fleet_id,player_id,target_planet_id,espionage_level,target_espionage_level,metal,crystal,deuterium,energy,fleet,defenses)
 SELECT v_fleet.id,v_fleet.player_id,v_target.id,v_esp,v_target_esp,pr.metal,pr.crystal,pr.deuterium,COALESCE((SELECT SUM(ps.quantity*sd.attack) FROM public.planet_ships ps JOIN public.ship_definitions sd ON sd.id=ps.ship_id WHERE ps.planet_id=v_target.id),0),COALESCE((SELECT jsonb_object_agg(ps.ship_id,ps.quantity) FROM public.planet_ships ps WHERE ps.planet_id=v_target.id),'{}'::jsonb),COALESCE((SELECT jsonb_object_agg(pd.defense_id,pd.quantity) FROM public.planet_defenses pd WHERE pd.planet_id=v_target.id),'{}'::jsonb) FROM public.planet_resources pr WHERE pr.planet_id=v_target.id ON CONFLICT ON CONSTRAINT espionage_reports_fleet_id_key DO UPDATE SET created_at=now() RETURNING public.espionage_reports.id INTO v_report_id;
 v_duration:=v_fleet.arrives_at-v_fleet.started_at; v_returns_at:=now()+v_duration;
 UPDATE public.fleet_movements SET status='RETURNING',returns_at=v_returns_at WHERE id=p_fleet_id;
 RETURN QUERY SELECT v_fleet.id,v_target.id,v_report_id,'RETURNING'::text,v_returns_at;
END;$function$;