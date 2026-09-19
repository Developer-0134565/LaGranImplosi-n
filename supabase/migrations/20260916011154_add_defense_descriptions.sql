alter table public.defense_definitions add column if not exists description text;
update public.defense_definitions set description = case id
when 'rocket_launcher' then 'Defensa de respuesta rápida que utiliza proyectiles guiados para proteger instalaciones contra incursiones.'
when 'light_laser' then 'Emisor defensivo compacto capaz de concentrar energía con gran precisión contra objetivos ligeros.'
when 'heavy_laser' then 'Sistema láser reforzado diseñado para detener unidades de mayor resistencia.'
when 'gauss_cannon' then 'Acelerador electromagnético que dispara proyectiles a velocidades extremas contra blancos pesados.'
when 'ion_cannon' then 'Batería defensiva que emplea descargas iónicas para debilitar y desestabilizar naves enemigas.'
when 'plasma_turret' then 'Plataforma de artillería avanzada que lanza plasma de alta energía contra objetivos fuertemente protegidos.'
when 'small_shield_dome' then 'Campo protector planetario de escala compacta que absorbe parte del impacto de los ataques.'
when 'large_shield_dome' then 'Generador de escudo planetario de gran capacidad, destinado a resistir ofensivas de mayor intensidad.'
else description end;
