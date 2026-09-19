alter table public.combat_battles
  add column if not exists loot_metal numeric not null default 0,
  add column if not exists loot_crystal numeric not null default 0,
  add column if not exists loot_deuterium numeric not null default 0,
  add column if not exists loot_applied_at timestamptz;

create or replace function public.apply_attack_loot(p_battle_id uuid)
returns table(loot_metal numeric, loot_crystal numeric, loot_deuterium numeric, cargo_capacity numeric)
language plpgsql
as $$
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

  /* Cargo is based only on ships that survived the last combat round. */
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

  select * into v_res from public.planet_resources where planet_id=v_battle.defender_planet_id for update;
  if not found then raise exception 'Resources for defender planet % not found',v_battle.defender_planet_id; end if;

  /* Classic normal-target attack: maximum 50% of each available resource. */
  v_metal_cap := greatest(0, floor(greatest(v_res.metal,0) * 0.5));
  v_crystal_cap := greatest(0, floor(greatest(v_res.crystal,0) * 0.5));
  v_deut_cap := greatest(0, floor(greatest(v_res.deuterium,0) * 0.5));
  v_remaining := floor(v_capacity);

  /* OGame-style cargo balancing: reserve roughly 1/3 for metal, then 1/2 of
     the remainder for crystal, and use the remainder for deuterium. */
  v_m := least(v_metal_cap, floor(v_remaining/3));
  v_remaining := v_remaining-v_m;
  v_c := least(v_crystal_cap, floor(v_remaining/2));
  v_remaining := v_remaining-v_c;
  v_d := least(v_deut_cap, v_remaining);
  v_remaining := v_remaining-v_d;

  /* Refill unused cargo in resource order without ever exceeding the 50%
     caps. This handles planets with little/no one resource. */
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

revoke all on function public.apply_attack_loot(uuid) from public;
