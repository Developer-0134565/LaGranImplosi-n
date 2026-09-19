create unique index if not exists ux_combat_debris_generations_battle on public.combat_debris_generations (battle_id);

create or replace function public.create_combat_debris(p_battle_id uuid)
returns table(out_battle_id uuid, out_debris_id uuid, out_galaxy integer, out_system integer, out_position integer, out_debris_metal numeric, out_debris_crystal numeric, out_total_metal numeric, out_total_crystal numeric, out_already_generated boolean)
language plpgsql
set search_path to 'public','pg_temp'
as $function$
declare
    v_universe_id uuid;
    v_galaxy integer;
    v_system integer;
    v_position integer;
    v_debris_metal numeric := 0;
    v_debris_crystal numeric := 0;
    v_total_metal numeric := 0;
    v_total_crystal numeric := 0;
    v_debris_id uuid;
    v_existing_debris_id uuid;
begin
    select cdg.debris_field_id into v_existing_debris_id
    from public.combat_debris_generations cdg
    where cdg.battle_id=p_battle_id
    limit 1;

    if found then
        select d.universe_id,d.galaxy,d.system,d.position,d.metal,d.crystal
        into v_universe_id,v_galaxy,v_system,v_position,v_debris_metal,v_debris_crystal
        from public.debris_fields d where d.id=v_existing_debris_id;
        return query select p_battle_id,v_existing_debris_id,v_galaxy,v_system,v_position,0::numeric,0::numeric,0::numeric,0::numeric,true;
        return;
    end if;

    select p.universe_id,p.galaxy,p.system,p.position
    into v_universe_id,v_galaxy,v_system,v_position
    from public.combat_battles b join public.planets p on p.id=b.defender_planet_id
    where b.id=p_battle_id;
    if not found then raise exception 'Battle % not found or defender planet missing',p_battle_id; end if;

    select d.metal_lost,d.crystal_lost,d.debris_metal,d.debris_crystal
    into v_total_metal,v_total_crystal,v_debris_metal,v_debris_crystal
    from public.calculate_combat_total_debris(p_battle_id) d;

    if coalesce(v_debris_metal,0)<=0 and coalesce(v_debris_crystal,0)<=0 then
        return query select p_battle_id,null::uuid,v_galaxy,v_system,v_position,0::numeric,0::numeric,coalesce(v_total_metal,0),coalesce(v_total_crystal,0),false;
        return;
    end if;

    select d.out_debris_id into v_debris_id
    from public.add_debris_field(v_universe_id,v_galaxy,v_system,v_position,v_debris_metal,v_debris_crystal) d;

    insert into public.combat_debris_generations(battle_id,debris_field_id,metal_generated,crystal_generated)
    values(p_battle_id,v_debris_id,v_debris_metal,v_debris_crystal)
    on conflict (battle_id) do nothing;

    if not found then
        select cdg.debris_field_id into v_debris_id from public.combat_debris_generations cdg where cdg.battle_id=p_battle_id;
        return query select p_battle_id,v_debris_id,v_galaxy,v_system,v_position,0::numeric,0::numeric,0::numeric,0::numeric,true;
        return;
    end if;

    return query select p_battle_id,v_debris_id,v_galaxy,v_system,v_position,v_debris_metal,v_debris_crystal,v_total_metal,v_total_crystal,false;
end;
$function$;