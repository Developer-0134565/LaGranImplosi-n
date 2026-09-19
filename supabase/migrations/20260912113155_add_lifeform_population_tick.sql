ALTER TABLE public.planet_lifeforms ADD COLUMN IF NOT EXISTS last_population_tick_at timestamptz NOT NULL DEFAULT now();

CREATE OR REPLACE FUNCTION public.process_lifeform_tick(p_planet_id uuid)
RETURNS jsonb LANGUAGE plpgsql AS $function$
DECLARE v_lf public.planet_lifeforms%ROWTYPE;v_elapsed numeric;v_capacity numeric;v_food_capacity numeric;v_food_rate numeric;v_growth_bonus numeric;v_hours numeric;v_growth numeric;v_consumption numeric;v_evolution numeric;v_new_food numeric;
BEGIN
SELECT * INTO v_lf FROM public.planet_lifeforms WHERE planet_id=p_planet_id AND active=true FOR UPDATE;
IF NOT FOUND THEN RETURN jsonb_build_object('processed',false,'reason','no_active_lifeform'); END IF;
SELECT EXTRACT(EPOCH FROM (now()-v_lf.last_population_tick_at)) INTO v_elapsed;v_hours:=greatest(v_elapsed,0)/3600.0;
SELECT public.calculate_universe_evolution_rate(p.universe_id) INTO v_evolution FROM public.planets p WHERE p.id=p_planet_id;
v_capacity:=10000*COALESCE((SELECT level FROM public.planet_lifeform_buildings WHERE planet_id=p_planet_id AND building_id IN('human_residential_sector','rocktal_meditation_enclave','mecha_assembly_line','kalesh_sanctuary')),0);
v_capacity:=v_capacity+COALESCE(public.get_planet_lifeform_building_effect(p_planet_id,'population_capacity'),0);
v_food_capacity:=10000+COALESCE(public.get_planet_lifeform_building_effect(p_planet_id,'food_capacity'),0);
v_food_rate:=500*COALESCE((SELECT SUM(level) FROM public.planet_lifeform_buildings plb JOIN public.lifeform_building_definitions lbd ON lbd.id=plb.building_id WHERE plb.planet_id=p_planet_id AND lbd.effect_key='food_production_percent'),0);
IF v_food_rate=0 THEN v_food_rate:=100; END IF;
v_growth_bonus:=public.get_planet_lifeform_building_effect(p_planet_id,'population_growth_percent');
v_consumption:=(v_lf.population_t1+v_lf.population_t2+v_lf.population_t3)*0.001*v_hours;
v_new_food:=least(v_food_capacity,greatest(0,v_lf.food+v_food_rate*v_hours-v_consumption));
v_growth:=CASE WHEN v_new_food>0 AND v_capacity>0 THEN least(greatest(v_capacity-(v_lf.population_t1+v_lf.population_t2+v_lf.population_t3),0),v_capacity*0.02*v_hours*sqrt(v_evolution)*(1+v_growth_bonus/100)) ELSE 0 END;
UPDATE public.planet_lifeforms SET population_t1=population_t1+v_growth,food=v_new_food,last_population_tick_at=now(),updated_at=now() WHERE planet_id=p_planet_id;
RETURN jsonb_build_object('processed',true,'growth',round(v_growth,4),'population_capacity',v_capacity,'food',round(v_new_food,4),'food_consumed',round(v_consumption,4),'hours',round(v_hours,4));
END;$function$;

CREATE OR REPLACE FUNCTION public.process_planet_tick(p_planet_id uuid)
RETURNS TABLE(planet_id uuid,metal numeric,crystal numeric,deuterium numeric,energy numeric,buildings_completed integer,researches_completed integer)
LANGUAGE plpgsql AS $function$
DECLARE v_metal numeric;v_crystal numeric;v_deuterium numeric;v_energy numeric;v_buildings_completed integer:=0;v_researches_completed integer:=0;
BEGIN
SELECT r.metal,r.crystal,r.deuterium,r.energy INTO v_metal,v_crystal,v_deuterium,v_energy FROM public.update_planet_resources(p_planet_id) r;
PERFORM public.process_lifeform_tick(p_planet_id);
SELECT COUNT(*) INTO v_buildings_completed FROM public.process_building_queue() b WHERE b.planet_id=p_planet_id;
SELECT COUNT(*) INTO v_researches_completed FROM public.process_research_queue() r WHERE r.player_id=(SELECT p.player_id FROM public.planets p WHERE p.id=p_planet_id);
RETURN QUERY SELECT p_planet_id,v_metal,v_crystal,v_deuterium,v_energy,v_buildings_completed,v_researches_completed;
END;$function$;
