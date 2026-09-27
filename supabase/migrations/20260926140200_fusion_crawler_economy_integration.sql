-- FUSION REACTOR + CRAWLER — economy integration (2026-09-26)
-- --------------------------------------------------------------------------------------------
-- The function is patched by replacing exact fragments of its LIVE definition and re-executing it; every replacement
-- is ASSERTED, so a drifted definition fails loudly instead of silently skipping a term.
-- Fuel policy: the reactor runs only while the planet holds deuterium (official OGame: a reactor without fuel stops).
-- OGameX's own code applies its deuterium formula unconditionally, which would let an empty tank keep producing
-- energy; LGI implements the OGame rule so no free energy can exist. Deliberate, documented adaptation.
begin;

do $patch$
declare
    v_def text;
    v_base text;
    nl text := chr(10);
begin
    select pg_get_functiondef(p.oid) into v_def
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'calculate_planet_production';

    if v_def is null then
        raise exception 'PLANET_PRODUCTION_PATCH: calculate_planet_production not found';
    end if;

    v_base := v_def;

    v_def := replace(v_def, '  v_solar_level integer := 0;',
        '  v_solar_level integer := 0;' || nl ||
        '  v_fusion_level integer := 0;' || nl ||
        '  v_crawler_count bigint := 0;' || nl ||
        '  v_crawler_effective bigint := 0;' || nl ||
        '  v_deuterium_stock numeric := 0;' || nl ||
        '  v_fusion_energy numeric := 0;' || nl ||
        '  v_fusion_deuterium numeric := 0;');
    if v_def = v_base then raise exception 'PLANET_PRODUCTION_PATCH: declaration anchor not found'; end if;
    v_base := v_def;

    v_def := replace(v_def, 'COALESCE(MAX(level) FILTER (WHERE building_id = ''solar_plant''), 0),',
        'COALESCE(MAX(level) FILTER (WHERE building_id = ''solar_plant''), 0),' || nl ||
        '    COALESCE(MAX(level) FILTER (WHERE building_id = ''fusion_plant''), 0),');
    if v_def = v_base then raise exception 'PLANET_PRODUCTION_PATCH: aggregate anchor not found'; end if;
    v_base := v_def;

    v_def := replace(v_def,
        'INTO v_metal_level, v_crystal_level, v_deuterium_level, v_solar_level, v_energy_consumption',
        'INTO v_metal_level, v_crystal_level, v_deuterium_level, v_solar_level, v_fusion_level, v_energy_consumption');
    if v_def = v_base then raise exception 'PLANET_PRODUCTION_PATCH: into anchor not found'; end if;
    v_base := v_def;

    v_def := replace(v_def, '  v_energy_production := floor(',
        '  select coalesce(pr.deuterium, 0) into v_deuterium_stock' || nl ||
        '    from public.planet_resources pr where pr.planet_id = p_planet_id;' || nl ||
        '  select coalesce(sum(ps.quantity), 0) into v_crawler_count' || nl ||
        '    from public.planet_ships ps where ps.planet_id = p_planet_id and ps.ship_id = ''crawler'';' || nl ||
        '  v_crawler_effective := least(v_crawler_count, (v_metal_level + v_crystal_level + v_deuterium_level)::bigint * 8);' || nl ||
        '  v_energy_consumption := v_energy_consumption + (v_crawler_effective * 50);' || nl ||
        '  v_energy_production := floor(');
    if v_def = v_base then raise exception 'PLANET_PRODUCTION_PATCH: energy production anchor not found'; end if;
    v_base := v_def;

    v_def := replace(v_def, '    * (1 + 0.05 * v_energy_technology_level)' || nl || '  );',
        '    * (1 + 0.05 * v_energy_technology_level)' || nl || '  );' || nl ||
        '  v_fusion_energy := case when v_fusion_level > 0 and v_deuterium_stock > 0' || nl ||
        '    then floor(30 * v_fusion_level * power(1.05 + 0.01 * v_energy_technology_level, v_fusion_level)' || nl ||
        '               * (1 + v_energy_bonus / 100))' || nl ||
        '    else 0 end;' || nl ||
        '  v_energy_production := v_energy_production + v_fusion_energy;' || nl ||
        '  v_fusion_deuterium := case when v_fusion_level > 0 and v_deuterium_stock > 0' || nl ||
        '    then 10 * v_fusion_level * power(1.1, v_fusion_level) * v_economy_rate * v_production_rate' || nl ||
        '    else 0 end;');
    if v_def = v_base then raise exception 'PLANET_PRODUCTION_PATCH: solar assignment anchor not found'; end if;
    v_base := v_def;

    v_def := replace(v_def, '30 * v_metal_level * power(1.1, v_metal_level) * v_economy_rate',
        '(30 * v_metal_level * power(1.1, v_metal_level)' || nl ||
        '     + floor(30 * v_metal_level * power(1.1, v_metal_level) * 0.0002 * v_crawler_effective)) * v_economy_rate');
    if v_def = v_base then raise exception 'PLANET_PRODUCTION_PATCH: metal anchor not found'; end if;
    v_base := v_def;

    v_def := replace(v_def, '20 * v_crystal_level * power(1.1, v_crystal_level) * v_economy_rate',
        '(20 * v_crystal_level * power(1.1, v_crystal_level)' || nl ||
        '     + floor(20 * v_crystal_level * power(1.1, v_crystal_level) * 0.0002 * v_crawler_effective)) * v_economy_rate');
    if v_def = v_base then raise exception 'PLANET_PRODUCTION_PATCH: crystal anchor not found'; end if;
    v_base := v_def;

    v_def := replace(v_def, '10 * v_deuterium_level * power(1.1, v_deuterium_level) * v_economy_rate',
        '(10 * v_deuterium_level * power(1.1, v_deuterium_level)' || nl ||
        '     + floor(10 * v_deuterium_level * power(1.1, v_deuterium_level) * 0.0002 * v_crawler_effective)) * v_economy_rate');
    if v_def = v_base then raise exception 'PLANET_PRODUCTION_PATCH: deuterium anchor not found'; end if;
    v_base := v_def;

    v_def := replace(v_def, '* v_plasma_deuterium_factor,', '* v_plasma_deuterium_factor - v_fusion_deuterium,');
    if v_def = v_base then raise exception 'PLANET_PRODUCTION_PATCH: deuterium return anchor not found'; end if;

    execute v_def;
end;
$patch$;

comment on function public.calculate_planet_production(uuid) is
$c$Per-hour production of a planet (rates already scaled by economy x production; the raw settlement divides by that
combined rate to recover the base and applies the evolution-weighted seconds). Includes the fusion reactor's
fuel-gated energy (30*L*(1.05 + 0.01*energy_technology)^L only while the planet holds deuterium) and its deuterium
burn (10*L*1.1^L base per hour), plus the crawler bonus (+0.02 % of the mine output per effective unit, effective
units capped at (metal_mine + crystal_mine + deuterium_synthesizer) x 8) and the crawler energy consumption
(50 per effective unit).$c$;

commit;

