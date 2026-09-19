INSERT INTO public.building_energy_definitions (building_id, base_consumption, consumption_factor)
VALUES ('solar_plant', 0, 1)
ON CONFLICT (building_id) DO UPDATE
SET base_consumption = EXCLUDED.base_consumption,
    consumption_factor = EXCLUDED.consumption_factor;