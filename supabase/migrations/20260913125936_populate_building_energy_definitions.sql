INSERT INTO public.building_energy_definitions (building_id, base_consumption, consumption_factor)
VALUES
  ('metal_mine', 10, 1.1),
  ('crystal_mine', 10, 1.1),
  ('deuterium_synthesizer', 20, 1.1)
ON CONFLICT (building_id) DO UPDATE
SET base_consumption = EXCLUDED.base_consumption,
    consumption_factor = EXCLUDED.consumption_factor;