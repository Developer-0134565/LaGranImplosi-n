-- Temporal catch-up hardening:
-- 1) universe ticks settle economy chronologically per planet;
-- 2) player-wide research settles every planet through its completion event;
-- 3) lifeform population integrates sqrt(evolution) over elapsed time;
-- 4) player-scoped economy locks serialize concurrent resource/research settlement.

CREATE OR REPLACE FUNCTION public.calculate_universe_evolution_population_seconds(p_universe_id uuid,p_start_at timestamptz,p_end_at timestamptz)
RETURNS numeric LANGUAGE plpgsql STABLE SET search_path TO 'public','pg_temp' AS $function$
DECLARE
 v_created_at timestamptz; v_cursor timestamptz; v_end timestamptz; v_seg_end timestamptz;
 v_t0 numeric; v_t1 numeric; v_dt numeric; v_age0 numeric; v_age1 numeric;
 v_slope numeric; v_intercept numeric; v_x0 numeric; v_x1 numeric; v_integral numeric:=0;
BEGIN
 SELECT created_at INTO v_created_at FROM public.universes WHERE id=p_universe_id;
 IF v_created_at IS NULL THEN RAISE EXCEPTION 'Universe % does not exist',p_universe_id; END IF;
 IF p_end_at<=p_start_at THEN RETURN 0; END IF;
 v_cursor:=GREATEST(p_start_at,v_created_at); v_end:=p_end_at;
 IF v_cursor>=v_end THEN RETURN 0; END IF;
 WHILE v_cursor<v_end LOOP
  v_age0:=GREATEST(0,EXTRACT(EPOCH FROM(v_cursor-v_created_at))/86400.0);
  IF v_age0<7 THEN v_age1:=7; v_slope:=4.0/(7.0*86400.0); v_intercept:=1.0;
  ELSIF v_age0<14 THEN v_age1:=14; v_slope:=5.0/(7.0*86400.0); v_intercept:=5.0-v_slope*(7.0*86400.0);
  ELSIF v_age0<30 THEN v_age1:=30; v_slope:=15.0/(16.0*86400.0); v_intercept:=10.0-v_slope*(14.0*86400.0);
  ELSIF v_age0<45 THEN v_age1:=45; v_slope:=15.0/(15.0*86400.0); v_intercept:=25.0-v_slope*(30.0*86400.0);
  ELSIF v_age0<60 THEN v_age1:=60; v_slope:=20.0/(15.0*86400.0); v_intercept:=40.0-v_slope*(45.0*86400.0);
  ELSIF v_age0<90 THEN v_age1:=90; v_slope:=40.0/(30.0*86400.0); v_intercept:=60.0-v_slope*(60.0*86400.0);
  ELSE v_age1:=1000000000; v_slope:=0; v_intercept:=100;
  END IF;
  v_seg_end:=LEAST(v_end,v_created_at+make_interval(secs=>v_age1*86400.0));
  v_t0:=EXTRACT(EPOCH FROM(v_cursor-v_created_at)); v_t1:=EXTRACT(EPOCH FROM(v_seg_end-v_created_at)); v_dt:=v_t1-v_t0;
  v_x0:=GREATEST(v_slope*v_t0+v_intercept,0); v_x1:=GREATEST(v_slope*v_t1+v_intercept,0);
  IF v_dt>0 THEN
   IF v_slope=0 THEN v_integral:=v_integral+sqrt(v_intercept)*v_dt;
   ELSE v_integral:=v_integral+(2.0/(3.0*v_slope))*(power(v_x1,1.5)-power(v_x0,1.5)); END IF;
  END IF;
  v_cursor:=v_seg_end;
 END LOOP;
 RETURN v_integral;
END;
$function$;

CREATE OR REPLACE FUNCTION public.update_planet_resources_until(p_planet_id uuid,p_until timestamptz)
RETURNS TABLE(planet_id uuid,metal numeric,crystal numeric,deuterium numeric,energy numeric,elapsed_seconds numeric,metal_produced numeric,crystal_produced numeric,deuterium_produced numeric)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp' AS $function$
declare
 v_player_id uuid; v_last_calculated_at timestamptz; v_event_id uuid; v_event_at timestamptz; v_event_type text; v_raw record; v_final record;
begin
 select p.player_id,pr.last_calculated_at into v_player_id,v_last_calculated_at from public.planets p join public.planet_resources pr on pr.planet_id=p.id where p.id=p_planet_id for update of pr;
 if not found then raise exception 'PLANET_RESOURCES_NOT_FOUND'; end if;
 if p_until<v_last_calculated_at then raise exception 'INVALID_RESOURCE_TIMESTAMP'; end if;
 if v_player_id is not null then perform pg_advisory_xact_lock(hashtextextended('planet-economy:'||v_player_id::text,0)); end if;
 loop
  v_event_id:=null; v_event_at:=null; v_event_type:=null;
  select q.id,q.finishes_at,'BUILDING' into v_event_id,v_event_at,v_event_type from public.building_queue q where q.planet_id=p_planet_id and upper(q.status)='BUILDING' and q.finishes_at>v_last_calculated_at and q.finishes_at<=p_until order by q.finishes_at,q.created_at,q.id limit 1;
  if v_player_id is not null then
   declare r_id uuid; r_at timestamptz;
   begin
    select q.id,q.finishes_at into r_id,r_at from public.research_queue q where q.player_id=v_player_id and upper(q.status)='RESEARCHING' and q.finishes_at>v_last_calculated_at and q.finishes_at<=p_until order by q.finishes_at,q.created_at,q.id limit 1;
    if r_id is not null and (v_event_at is null or r_at<v_event_at or (r_at=v_event_at and r_id::text<v_event_id::text)) then v_event_id:=r_id; v_event_at:=r_at; v_event_type:='RESEARCH'; end if;
   end;
  end if;
  if v_event_id is null then exit; end if;
  select * into v_raw from public.update_planet_resources_until_raw(p_planet_id,v_event_at);
  if v_event_type='BUILDING' then perform public.complete_building(v_event_id); else perform public.complete_research(v_event_id); end if;
  select pr.last_calculated_at into v_last_calculated_at from public.planet_resources pr where pr.planet_id=p_planet_id;
 end loop;
 select * into v_final from public.update_planet_resources_until_raw(p_planet_id,p_until);
 return query select v_final.planet_id,v_final.metal,v_final.crystal,v_final.deuterium,v_final.energy,v_final.elapsed_seconds,v_final.metal_produced,v_final.crystal_produced,v_final.deuterium_produced;
end;
$function$;

CREATE OR REPLACE FUNCTION public.complete_research(p_queue_id uuid)
RETURNS boolean LANGUAGE plpgsql SET search_path TO 'public','pg_temp' AS $function$
declare
 v_player_id uuid; v_planet_id uuid; v_universe_id uuid; v_research_id text; v_target_level integer; v_status text; v_finishes_at timestamptz; v_planet_id_iter uuid;
begin
 select player_id,planet_id,research_id,target_level,status,finishes_at into v_player_id,v_planet_id,v_research_id,v_target_level,v_status,v_finishes_at from public.research_queue where id=p_queue_id for update;
 if not found then raise exception 'Research queue does not exist: %',p_queue_id; end if;
 if v_status<>'RESEARCHING' then raise exception 'Research queue is not active. Current status: %',v_status; end if;
 if v_finishes_at>now() then raise exception 'Research is not finished yet. Finishes at: %',v_finishes_at; end if;
 select universe_id into v_universe_id from public.players where id=v_player_id;
 if v_universe_id is null and v_planet_id is not null then select universe_id into v_universe_id from public.planets where id=v_planet_id; end if;
 if v_player_id is not null then perform pg_advisory_xact_lock(hashtextextended('planet-economy:'||v_player_id::text,0)); end if;
 for v_planet_id_iter in select p.id from public.planets p where p.player_id=v_player_id and (v_universe_id is null or p.universe_id=v_universe_id) and not p.is_destroyed order by p.id loop
  perform public.update_planet_resources_until_raw(v_planet_id_iter,v_finishes_at);
 end loop;
 insert into public.player_research(player_id,research_id,level) values(v_player_id,v_research_id,v_target_level) on conflict(player_id,research_id) do update set level=excluded.level;
 update public.research_queue set status='COMPLETED' where id=p_queue_id;
 return true;
end;
$function$;

CREATE OR REPLACE FUNCTION public.process_lifeform_tick(p_planet_id uuid)
RETURNS jsonb LANGUAGE plpgsql SET search_path TO 'public','pg_temp' AS $function$
DECLARE
 v_lf public.planet_lifeforms%ROWTYPE; v_elapsed numeric; v_capacity numeric; v_food_capacity numeric; v_food_rate numeric; v_growth_bonus numeric; v_hours numeric; v_growth numeric; v_consumption numeric; v_new_food numeric; v_growth_hours numeric;
BEGIN
 SELECT * INTO v_lf FROM public.planet_lifeforms WHERE planet_id=p_planet_id AND active=true FOR UPDATE;
 IF NOT FOUND THEN RETURN jsonb_build_object('processed',false,'reason','no_active_lifeform'); END IF;
 SELECT EXTRACT(EPOCH FROM(now()-v_lf.last_population_tick_at)) INTO v_elapsed;
 v_hours:=greatest(v_elapsed,0)/3600.0;
 SELECT public.calculate_universe_evolution_population_seconds(p.universe_id,v_lf.last_population_tick_at,now())/3600.0 INTO v_growth_hours FROM public.planets p WHERE p.id=p_planet_id;
 v_growth_hours:=greatest(coalesce(v_growth_hours,0),0);
 v_capacity:=10000*COALESCE((SELECT level FROM public.planet_lifeform_buildings WHERE planet_id=p_planet_id AND building_id IN('human_residential_sector','rocktal_meditation_enclave','mecha_assembly_line','kalesh_sanctuary')),0);
 v_capacity:=v_capacity+COALESCE(public.get_planet_lifeform_building_effect(p_planet_id,'population_capacity'),0);
 v_food_capacity:=10000+COALESCE(public.get_planet_lifeform_building_effect(p_planet_id,'food_capacity'),0);
 v_food_rate:=500*COALESCE((SELECT SUM(level) FROM public.planet_lifeform_buildings plb JOIN public.lifeform_building_definitions lbd ON lbd.id=plb.building_id WHERE plb.planet_id=p_planet_id AND lbd.effect_key='food_production_percent'),0);
 IF v_food_rate=0 THEN v_food_rate:=100; END IF;
 v_growth_bonus:=public.get_planet_lifeform_building_effect(p_planet_id,'population_growth_percent');
 v_consumption:=(v_lf.population_t1+v_lf.population_t2+v_lf.population_t3)*0.001*v_hours;
 v_new_food:=least(v_food_capacity,greatest(0,v_lf.food+v_food_rate*v_hours-v_consumption));
 v_growth:=CASE WHEN v_new_food>0 AND v_capacity>0 THEN least(greatest(v_capacity-(v_lf.population_t1+v_lf.population_t2+v_lf.population_t3),0),v_capacity*0.02*v_growth_hours*(1+v_growth_bonus/100)) ELSE 0 END;
 UPDATE public.planet_lifeforms SET population_t1=population_t1+v_growth,food=v_new_food,last_population_tick_at=now(),updated_at=now() WHERE planet_id=p_planet_id;
 RETURN jsonb_build_object('processed',true,'growth',round(v_growth,4),'population_capacity',v_capacity,'food',round(v_new_food,4),'food_consumed',round(v_consumption,4),'hours',round(v_hours,4),'evolution_growth_hours',round(v_growth_hours,4));
END;
$function$;

CREATE OR REPLACE FUNCTION public.process_planet_tick_local(p_planet_id uuid)
RETURNS TABLE(planet_id uuid,metal numeric,crystal numeric,deuterium numeric,energy numeric,buildings_completed integer,researches_completed integer)
LANGUAGE plpgsql SET search_path TO 'public','pg_temp' AS $function$
DECLARE v_metal numeric; v_crystal numeric; v_deuterium numeric; v_energy numeric; v_buildings_completed integer:=0; v_researches_completed integer:=0; v_player_id uuid;
BEGIN
 SELECT p.player_id INTO v_player_id FROM public.planets p WHERE p.id=p_planet_id;
 SELECT count(*)::integer INTO v_buildings_completed FROM public.building_queue q WHERE q.planet_id=p_planet_id AND upper(q.status)='BUILDING' AND q.finishes_at<=now();
 IF v_player_id IS NOT NULL THEN SELECT count(*)::integer INTO v_researches_completed FROM public.research_queue q WHERE q.player_id=v_player_id AND upper(q.status)='RESEARCHING' AND q.finishes_at<=now(); END IF;
 SELECT r.metal,r.crystal,r.deuterium,r.energy INTO v_metal,v_crystal,v_deuterium,v_energy FROM public.update_planet_resources_until(p_planet_id,now()) r;
 PERFORM public.process_lifeform_tick(p_planet_id);
 PERFORM public.process_shipyard_queue(p_planet_id);
 PERFORM public.process_defense_queue(p_planet_id);
 RETURN QUERY SELECT p_planet_id,v_metal,v_crystal,v_deuterium,v_energy,v_buildings_completed,v_researches_completed;
END;
$function$;

CREATE OR REPLACE FUNCTION public.process_universe_tick(p_universe_id uuid)
RETURNS TABLE(planet_id uuid,metal numeric,crystal numeric,deuterium numeric,energy numeric,buildings_completed integer,researches_completed integer)
LANGUAGE plpgsql SET search_path TO 'public','pg_temp' AS $function$
DECLARE v_planet RECORD; v_result RECORD;
BEGIN
 FOR v_planet IN SELECT p.id FROM public.planets p WHERE p.universe_id=p_universe_id AND NOT p.is_destroyed ORDER BY p.created_at,p.id LOOP
  SELECT * INTO v_result FROM public.process_planet_tick_local(v_planet.id);
  RETURN QUERY SELECT v_result.planet_id,v_result.metal,v_result.crystal,v_result.deuterium,v_result.energy,v_result.buildings_completed,v_result.researches_completed;
 END LOOP;
END;
$function$;
