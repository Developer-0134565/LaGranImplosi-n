-- Read-only GUEST access for the next dashboard layer.

GRANT SELECT ON TABLE public.planet_buildings, public.player_research, public.planet_ships, public.planet_defenses, public.building_queue, public.research_queue, public.shipyard_queue, public.fleet_movements, public.fleet_movement_ships TO anon, authenticated;

ALTER TABLE public.planet_buildings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.planet_defenses ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS planet_buildings_select_guest ON public.planet_buildings;
CREATE POLICY planet_buildings_select_guest ON public.planet_buildings
FOR SELECT TO anon, authenticated
USING (EXISTS (SELECT 1 FROM public.planets p JOIN public.players pl ON pl.id = p.player_id WHERE p.id = planet_buildings.planet_id AND pl.is_guest = true));

DROP POLICY IF EXISTS planet_defenses_select_guest ON public.planet_defenses;
CREATE POLICY planet_defenses_select_guest ON public.planet_defenses
FOR SELECT TO anon, authenticated
USING (EXISTS (SELECT 1 FROM public.planets p JOIN public.players pl ON pl.id = p.player_id WHERE p.id = planet_defenses.planet_id AND pl.is_guest = true));

DROP POLICY IF EXISTS planet_ships_select_guest ON public.planet_ships;
CREATE POLICY planet_ships_select_guest ON public.planet_ships
FOR SELECT TO anon, authenticated
USING (EXISTS (SELECT 1 FROM public.planets p JOIN public.players pl ON pl.id = p.player_id WHERE p.id = planet_ships.planet_id AND pl.is_guest = true));

DROP POLICY IF EXISTS player_research_select_guest ON public.player_research;
CREATE POLICY player_research_select_guest ON public.player_research
FOR SELECT TO anon, authenticated
USING (EXISTS (SELECT 1 FROM public.players pl WHERE pl.id = player_research.player_id AND pl.is_guest = true));

DROP POLICY IF EXISTS building_queue_select_guest ON public.building_queue;
CREATE POLICY building_queue_select_guest ON public.building_queue
FOR SELECT TO anon, authenticated
USING (EXISTS (SELECT 1 FROM public.planets p JOIN public.players pl ON pl.id = p.player_id WHERE p.id = building_queue.planet_id AND pl.is_guest = true));

DROP POLICY IF EXISTS research_queue_select_guest ON public.research_queue;
CREATE POLICY research_queue_select_guest ON public.research_queue
FOR SELECT TO anon, authenticated
USING (EXISTS (SELECT 1 FROM public.players pl WHERE pl.id = research_queue.player_id AND pl.is_guest = true));

DROP POLICY IF EXISTS shipyard_queue_select_guest ON public.shipyard_queue;
CREATE POLICY shipyard_queue_select_guest ON public.shipyard_queue
FOR SELECT TO anon, authenticated
USING (EXISTS (SELECT 1 FROM public.planets p JOIN public.players pl ON pl.id = p.player_id WHERE p.id = shipyard_queue.planet_id AND pl.is_guest = true));

DROP POLICY IF EXISTS fleet_movements_select_guest ON public.fleet_movements;
CREATE POLICY fleet_movements_select_guest ON public.fleet_movements
FOR SELECT TO anon, authenticated
USING (EXISTS (SELECT 1 FROM public.players pl WHERE pl.id = fleet_movements.player_id AND pl.is_guest = true));

DROP POLICY IF EXISTS fleet_movement_ships_select_guest ON public.fleet_movement_ships;
CREATE POLICY fleet_movement_ships_select_guest ON public.fleet_movement_ships
FOR SELECT TO anon, authenticated
USING (EXISTS (SELECT 1 FROM public.fleet_movements fm JOIN public.players pl ON pl.id = fm.player_id WHERE fm.id = fleet_movement_ships.fleet_id AND pl.is_guest = true));