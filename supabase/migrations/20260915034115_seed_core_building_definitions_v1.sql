insert into public.building_definitions (id,name,description,base_metal,base_crystal,base_deuterium,cost_factor,base_build_time_seconds,time_factor) values
('metal_mine','Metal Mine','Produces metal.',60,15,0,1.5,60,2),
('crystal_mine','Crystal Mine','Produces crystal.',48,24,0,1.6,60,2),
('deuterium_synthesizer','Deuterium Synthesizer','Produces deuterium.',225,75,0,1.5,60,2),
('solar_plant','Solar Plant','Produces energy.',75,30,0,1.5,60,2),
('metal_storage','Metal Storage','Increases maximum metal storage capacity.',1000,0,0,2,60,2),
('crystal_storage','Crystal Storage','Increases maximum crystal storage capacity.',1000,0,0,2,60,2),
('deuterium_tank','Deuterium Tank','Increases maximum deuterium storage capacity.',1000,1000,0,2,60,2),
('shipyard','Shipyard','Facility for constructing and maintaining spacecraft.',400,200,100,2,60,2)
on conflict (id) do update set name=excluded.name,description=excluded.description,base_metal=excluded.base_metal,base_crystal=excluded.base_crystal,base_deuterium=excluded.base_deuterium,cost_factor=excluded.cost_factor,base_build_time_seconds=excluded.base_build_time_seconds,time_factor=excluded.time_factor;