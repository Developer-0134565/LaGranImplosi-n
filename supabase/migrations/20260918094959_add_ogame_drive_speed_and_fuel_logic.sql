-- =============================================================================
-- RECOVERED MIGRATION — 20260918094959
-- ledger name : add_ogame_drive_speed_and_fuel_logic
-- provenance  : Supabase LIVE supabase_migrations.schema_migrations.statements
--               (verbatim payload of the original apply_migration call; no historical
--                local file existed in this repository, its stashes or the local copies)
-- recovered   : 2026-09-18 by the drift-reconciliation mission
-- ALREADY APPLIED IN LIVE — do not re-apply; this file exists for traceability only.
-- =============================================================================

create or replace function public.get_player_research_level(
  p_player_id uuid,
  p_research_id text
) returns integer
language sql stable security definer
set search_path = public, pg_temp
as $$
  select coalesce(pr.level, 0)
  from public.player_research pr
  where pr.player_id = p_player_id
    and pr.research_id = p_research_id
  limit 1;
$$;

create or replace function public.calculate_player_ship_speed(
  p_player_id uuid,
  p_ship_id text
) returns numeric
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare
  v_base numeric;
  v_comb numeric := public.get_player_research_level(p_player_id, 'combustion_drive');
  v_impulse numeric := public.get_player_research_level(p_player_id, 'impulse_drive');
  v_hyper numeric := public.get_player_research_level(p_player_id, 'hyperspace_drive');
  v_speed numeric;
begin
  select speed into v_base from public.ship_definitions where id = p_ship_id;
  if not found then raise exception 'Unknown ship: %', p_ship_id; end if;

  case p_ship_id
    when 'small_cargo' then
      if v_impulse >= 5 then
        v_speed := (v_base + 5000) * (1 + 0.2 * v_impulse);
      else
        v_speed := v_base * (1 + 0.1 * v_comb);
      end if;
    when 'bomber' then
      if v_hyper >= 8 then
        v_speed := (v_base + 1000) * (1 + 0.3 * v_hyper);
      else
        v_speed := v_base * (1 + 0.2 * v_impulse);
      end if;
    when 'large_cargo','light_fighter','recycler','espionage_probe','solar_satellite' then
      v_speed := v_base * (1 + 0.1 * v_comb);
    when 'heavy_fighter','cruiser','colony_ship' then
      v_speed := v_base * (1 + 0.2 * v_impulse);
    when 'battleship','destroyer','deathstar','battlecruiser','reaper','pathfinder' then
      v_speed := v_base * (1 + 0.3 * v_hyper);
    else
      v_speed := v_base;
  end case;

  return greatest(v_speed, 0);
end;
$$;

create or replace function public.calculate_player_fleet_fuel_for_distance(
  p_distance numeric,
  p_flight_time_seconds numeric,
  p_player_id uuid,
  p_ship_id text,
  p_quantity bigint,
  p_speed_percent numeric default 100
) returns numeric
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare
  v_ship_speed numeric;
  v_base_consumption numeric;
  v_impulse numeric;
  v_hyper_tech numeric;
  v_spd numeric;
  v_consumption numeric;
begin
  if p_distance < 0 then raise exception 'Distance cannot be negative'; end if;
  if p_flight_time_seconds <= 0 then raise exception 'Flight time must be greater than 0'; end if;
  if p_quantity <= 0 then raise exception 'Quantity must be greater than 0'; end if;
  if p_speed_percent <= 0 then raise exception 'Speed percent must be greater than 0'; end if;

  select fuel_consumption into v_base_consumption
  from public.ship_definitions where id = p_ship_id;
  if not found then raise exception 'Unknown ship: %', p_ship_id; end if;

  v_ship_speed := public.calculate_player_ship_speed(p_player_id, p_ship_id);
  v_impulse := public.get_player_research_level(p_player_id, 'impulse_drive');
  v_hyper_tech := public.get_player_research_level(p_player_id, 'hyperspace_technology');

  -- OGameX: small cargo doubles base consumption when it switches to impulse drive.
  if p_ship_id = 'small_cargo' and v_impulse >= 5 then
    v_base_consumption := v_base_consumption * 2;
  end if;

  -- OGameX FlightCons uses the internal 10x speed-percent factor.
  v_spd := 35000
    / greatest(p_flight_time_seconds * p_speed_percent * 10 - 10, 1)
    * sqrt(p_distance * 10 / greatest(v_ship_speed, 1));

  v_consumption := p_quantity * v_base_consumption
    * p_distance / 35000
    * power((v_spd / 10) + 1, 2);

  -- Hyperspace Technology reduces deuterium consumption by 0.3% per level.
  v_consumption := v_consumption * greatest(0, 1 - (0.003 * v_hyper_tech));

  return greatest(1, ceil(v_consumption));
end;
$$;

