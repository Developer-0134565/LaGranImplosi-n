-- ============================================================================================
-- LGI — ECONOMÍA Y TIEMPO DE OBRA DEL PROPIO PLANETA: contratos de lectura (definer, owner-scoped)
-- ============================================================================================
-- GAP cerrado (medido LIVE 2026-09-27 como el rol `authenticated`, no inferido):
--
--   calculate_planet_production(planet)        → ERROR: permission denied for table universes
--   calculate_planet_energy_balance(planet)    → ERROR: permission denied for table universes
--   calculate_building_time(b, nivel, universo) → ERROR: permission denied for table universes
--   calculate_research_time / calculate_ship_build_time          → ERROR: permission denied for table universes
--   get_planet_economic_rates / get_planet_rate_snapshot         → ERROR: permission denied for table universes
--
-- Causa: esos helpers son SECURITY **INVOKER** y leen `public.universes`, que tiene política RLS pública pero
-- NINGÚN grant de tabla para anon/authenticated. Consecuencias reales en el producto:
--   * la vista de Edificios muestra el TIEMPO BASE de la definición en lugar del tiempo real de la obra
--     (`can_start_building` no devuelve duración, a diferencia de `can_start_research`, `can_build_ship`,
--     `can_build_defense` y `can_start_demolition`, que sí la devuelven ya calculada por el servidor);
--   * el jugador no ve NUNCA su producción/hora, su balance de energía ni la capacidad de almacén — y el
--     almacén se aplica de verdad (el asentamiento recorta en la capacidad: medido, 100 000 en el Homeworld),
--     de modo que los recursos se pierden sin que nada lo indique.
--
-- Remedio elegido (documentado, mínimo y coherente con la arquitectura LGI):
--   * NO se abre `public.universes` a ningún rol (la restricción documentada se mantiene intacta);
--   * se añaden DOS contratos de lectura SECURITY DEFINER, con identidad `auth.uid()` → `players.user_id` y
--     propiedad del planeta comprobada, que *delegan* en los helpers ya certificados (ninguna fórmula nueva,
--     ningún oráculo paralelo):
--       1) `get_planet_economy_overview(planet)`  → producción/h, balance de energía y capacidades de almacén.
--       2) `get_planet_building_preview(planet)`  → por edificio: nivel actual, nivel objetivo (el MISMO que
--          declara `evaluate_building_start_internal`, del que `can_start_building` es el contrato cliente),
--          duración REAL de la obra y delta de energía/h del siguiente nivel.
--   * la duración se compone EXACTAMENTE como la cobra `start_building`:
--        round(calculate_building_time(edificio, nivel_objetivo, universo) /
--              (1 + optimize_bonus_por_item_de_expedición/100), 4)
--   * ni una regla de juego nueva: LGI no bloquea la construcción por energía
--     (`start_building`/`evaluate_building_start_internal` no mencionan energía en absoluto), así que el
--     balance se EXPONE como información y nunca como puerta.
--
-- Certificado por `supabase/tests/planet_economy_read_contracts.sql`.

-- ---------------------------------------------------------------------------------------------
-- 1) Producción, energía y almacén del planeta propio (una fila; 0 filas si no es propio o está destruido).
-- ---------------------------------------------------------------------------------------------
create or replace function public.get_planet_economy_overview(p_planet_id uuid)
returns table (
    metal_per_hour numeric,
    crystal_per_hour numeric,
    deuterium_per_hour numeric,
    energy_per_hour numeric,
    energy_production_per_hour numeric,
    energy_consumption_per_hour numeric,
    energy_balance_per_hour numeric,
    metal_capacity numeric,
    crystal_capacity numeric,
    deuterium_capacity numeric
)
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $f$
declare
    v_player_id uuid;
    v_planet_id uuid;
    v_prod record;
    v_bal record;
    v_st record;
begin
    /* Identidad y propiedad ANTES de llamar a ningún helper. Es obligatorio hacerlo así y no con un LATERAL en
       un cuerpo SQL: los helpers autoritativos levantan PLAYER_NOT_OWNED para un planeta ajeno, y con un cuerpo
       SQL el planificador puede PLEGAR una función STABLE cuyo argumento se propaga a la constante de la
       consulta, ejecutándola en tiempo de plan aunque no se produzca ninguna fila (comprobado LIVE 2026-09-27).
       Con la guarda explícita, un planeta ajeno, destruido o una sesión sin jugador devuelven 0 filas. */
    select pl.id into v_player_id
      from public.players pl
     where pl.user_id = auth.uid();

    select p.id into v_planet_id
      from public.planets p
     where p.id = p_planet_id
       and p.player_id = v_player_id
       and p.is_destroyed = false;

    if v_planet_id is null then
        return;
    end if;

    select * into v_prod from public.calculate_planet_production(v_planet_id);
    select * into v_bal from public.calculate_planet_energy_balance(v_planet_id);
    select * into v_st from public.calculate_planet_storage(v_planet_id);

    return query
    select v_prod.metal_per_hour,
           v_prod.crystal_per_hour,
           v_prod.deuterium_per_hour,
           v_prod.energy_per_hour,
           v_bal.energy_production_per_hour,
           v_bal.energy_consumption_per_hour,
           v_bal.energy_balance_per_hour,
           v_st.metal_capacity,
           v_st.crystal_capacity,
           v_st.deuterium_capacity;
end;
$f$;

comment on function public.get_planet_economy_overview(uuid) is
$c$Contrato de lectura owner-scoped de la economía del propio planeta: producción por hora (autoridad
`calculate_planet_production`), balance de energía por hora (`calculate_planet_energy_balance`) y capacidades de
almacén (`calculate_planet_storage`). Existe porque esos helpers son SECURITY INVOKER y leen `public.universes`,
que no tiene grant para el cliente; este contrato es DEFINER y sólo delega en ellos, sin recalcular nada. La
identidad sale de `auth.uid()` → `players.user_id` y el planeta tiene que ser propio y no estar destruido: en
cualquier otro caso devuelve 0 filas (nunca datos de otro jugador). La energía es INFORMACIÓN: LGI no bloquea ni
la construcción ni la producción por energía. Certificado por `supabase/tests/planet_economy_read_contracts.sql`.$c$;

revoke all on function public.get_planet_economy_overview(uuid) from public;
revoke all on function public.get_planet_economy_overview(uuid) from anon;
grant execute on function public.get_planet_economy_overview(uuid) to authenticated;
grant execute on function public.get_planet_economy_overview(uuid) to service_role;

-- ---------------------------------------------------------------------------------------------
-- 2) Previsión por edificio: nivel objetivo (el MISMO que declara el oráculo certificado), duración REAL de
--    la obra (misma composición que cobra `start_building`) y delta de energía/h del siguiente nivel.
-- ---------------------------------------------------------------------------------------------
create or replace function public.get_planet_building_preview(p_planet_id uuid)
returns table (
    building_id text,
    current_level integer,
    target_level integer,
    duration_seconds numeric,
    energy_delta_per_hour numeric
)
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $f$
declare
    v_player_id uuid;
    v_planet_id uuid;
    v_universe_id uuid;
    v_item_bonus numeric;
    v_def record;
    v_eval record;
    v_energy numeric;
begin
    /* Misma guarda explícita que `get_planet_economy_overview` (ver el comentario de allí): identidad y
       propiedad antes de evaluar cualquier helper autoritativo. */
    select pl.id into v_player_id
      from public.players pl
     where pl.user_id = auth.uid();

    select p.id, p.universe_id into v_planet_id, v_universe_id
      from public.planets p
     where p.id = p_planet_id
       and p.player_id = v_player_id
       and p.is_destroyed = false;

    if v_planet_id is null then
        return;
    end if;

    /* Bonus activo de objeto de expedición: exactamente la misma pieza que descuenta `start_building`. */
    v_item_bonus := coalesce(
        public.get_active_expedition_item_effect(v_player_id, v_planet_id, 'building_speed_percent'), 0);

    for v_def in
        select d.id as def_id from public.building_definitions d order by d.id
    loop
        /* Nivel actual y objetivo del oráculo certificado (el mismo que expone `can_start_building`). */
        select * into v_eval
          from public.evaluate_building_start_internal(v_player_id, v_planet_id, v_def.def_id);

        select e.energy_delta_per_hour into v_energy
          from public.calculate_building_energy_delta(v_planet_id, v_def.def_id) e;

        building_id := v_def.def_id;
        current_level := v_eval.current_level;
        target_level := v_eval.target_level;
        duration_seconds := round(
            public.calculate_building_time(v_def.def_id, v_eval.target_level, v_universe_id)
            / (1 + v_item_bonus / 100), 4);
        energy_delta_per_hour := v_energy;
        return next;
    end loop;

    return;
end;
$f$;

comment on function public.get_planet_building_preview(uuid) is
$c$Contrato de lectura owner-scoped de la previsión de obra del propio planeta, una fila por definición de
edificio: `current_level`, `target_level` (tomado del oráculo certificado `evaluate_building_start_internal`, del
que `can_start_building` es el contrato cliente — nunca una derivación paralela), `duration_seconds` (la misma
composición que cobra `start_building`: `calculate_building_time(edificio, nivel_objetivo, universo)` dividido por
el bonus activo de objeto de expedición `building_speed_percent`) y `energy_delta_per_hour` (autoridad
`calculate_building_energy_delta`). Existe porque `calculate_building_time` es SECURITY INVOKER y lee
`public.universes`, ilegible para el cliente: sin este contrato la vista de Edificios sólo puede mostrar el
TIEMPO BASE de la definición. Identidad `auth.uid()` → `players.user_id` y planeta propio no destruido: si no, 0
filas. La energía es información, no una puerta (LGI no bloquea la construcción por energía). Certificado por
`supabase/tests/planet_economy_read_contracts.sql`.$c$;

revoke all on function public.get_planet_building_preview(uuid) from public;
revoke all on function public.get_planet_building_preview(uuid) from anon;
grant execute on function public.get_planet_building_preview(uuid) to authenticated;
grant execute on function public.get_planet_building_preview(uuid) to service_role;

