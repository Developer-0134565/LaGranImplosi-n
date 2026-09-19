alter table public.dashboard_widgets drop constraint if exists dashboard_widgets_widget_type_check;
alter table public.dashboard_widgets add constraint dashboard_widgets_widget_type_check check (widget_type in ('image','panel','text','button','resource','planet','fleet','galaxy','minimap','clock','alerts','queue','production','energy','storage','building','research','shipyard','defense','missions','chat','stats','evolution','universe_clock','ranking','quick_actions'));

insert into public.dashboard_widgets (player_id, widget_type, name, x, y, width, height, z_index, opacity, visible, config)
select '60f1043a-2fa6-416c-80db-2a83215b5404', v.widget_type, v.name, v.x, v.y, v.width, v.height, v.z_index, 1, true, v.config
from (values
 ('resource','Recursos',16,70,310,92,30,'{"title":"RECURSOS"}'::jsonb),
 ('planet','Planeta',342,70,310,160,31,'{"title":"PLANETA"}'::jsonb),
 ('fleet','Flota',668,70,310,120,32,'{"title":"FLOTA"}'::jsonb),
 ('galaxy','Galaxia',994,70,310,120,33,'{"title":"GALAXIA"}'::jsonb),
 ('building','Edificios',16,280,310,110,34,'{"title":"EDIFICIOS"}'::jsonb),
 ('research','Investigación',342,250,310,110,35,'{"title":"INVESTIGACIÓN"}'::jsonb),
 ('shipyard','Astillero',668,220,310,110,36,'{"title":"ASTILLERO"}'::jsonb),
 ('defense','Defensas',994,220,310,110,37,'{"title":"DEFENSAS"}'::jsonb)
) as v(widget_type,name,x,y,width,height,z_index,config)
where not exists (select 1 from public.dashboard_widgets w where w.player_id='60f1043a-2fa6-416c-80db-2a83215b5404' and w.widget_type=v.widget_type);