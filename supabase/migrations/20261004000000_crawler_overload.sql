-- =============================================================================
-- CRAWLER OVERLOAD 0-150 %  (mission 2026-10-03)
-- =============================================================================
-- OGameX = REFERENCIA DE COMPORTAMIENTO. LGI = AUTORIDAD.
--
-- QUE SE IMPLEMENTA
--   LGI ya tenia el crawler al 100 % fijo: produccion +0.02 % por crawler efectivo
--   y 50 de energia por crawler efectivo. NO existia ningun porcentaje configurable
--   (0 columnas '%overload%' en todo el schema public, medido el 2026-10-02).
--   Este bloque anade el overload 0-150 % conservando 100 % como valor por defecto,
--   de modo que el comportamiento actual de TODOS los cuerpos NO cambia.
--
-- FORMULA (OGameX)
--   p = porcentaje / 100
--   energia = 50 * p                    si p <= 1
--   energia = 50 * p + 50 * (p - 1)     si p > 1     (equivalente a 50 * (2p - 1))
--     100 % -> 50      110 % -> 60      120 % -> 70
--     130 % -> 80      140 % -> 90      150 % -> 100
--   produccion: el bonus sigue siendo +0.02 % por crawler efectivo, escalado por p.
--
-- LO QUE NO SE IMPORTA (divergencia deliberada)
--   OGameX limita el overload a la clase Collector (General 100 %, Collector 150 %).
--   LGI NO tiene Character Classes ni Lifeforms. Crear ese sistema solo para el crawler
--   habria sido inventar infraestructura CLOSED, asi que NO se importa el gating por
--   clase: el limite es 0-150 % para todos los cuerpos.
--
-- LO QUE NO SE TOCA
--   No se reescriben las formulas de produccion, energia, almacen ni las colas.
--   calculate_planet_production cambia SOLO en su unico termino de crawler (3
--   ocurrencias, replace exacto verificado por el propio bloque). Nada mas.
--   La sostenibilidad se integra sola: el consumo sigue saliendo de
--   calculate_crawler_energy_consumption, que es la MISMA ruta que ya consumen
--   calculate_planet_energy_balance y evaluate_economic_sustainability. No se crea una
--   segunda regla de sostenibilidad.
-- =============================================================================

BEGIN;

-- 1. ALMACENAMIENTO: un unico porcentaje por cuerpo. 0 = sin crawler, 100 = igual
--    que hoy, 150 = tope. Entero (no 0.15) porque la UI y el contrato ya hablan en
--    "por ciento", y asi no hay conversion escondida.
ALTER TABLE public.planets
  ADD COLUMN IF NOT EXISTS crawler_percentage integer NOT NULL DEFAULT 100;

ALTER TABLE public.planets
  DROP CONSTRAINT IF EXISTS planets_crawler_percentage_check;

ALTER TABLE public.planets
  ADD CONSTRAINT planets_crawler_percentage_check
  CHECK (crawler_percentage BETWEEN 0 AND 150);

COMMENT ON COLUMN public.planets.crawler_percentage IS
  'Overload del crawler en porcentaje entero: 0-150. 100 = comportamiento LGI historico. Base 50 de energia por crawler efectivo: p<=1 => 50*p, p>1 => 50*(2p-1). Gating por Character Class de OGameX NO importado (LGI no tiene clases).';

-- 2. CRAWLERS EFECTIVOS: extraido para que produccion, energia y el contrato de
--    lectura compartan EXACTAMENTE la misma regla de tope. Una sola verdad.
--    Q1 (ya cerrado y verificado): cap = (metal + crystal + deuterium) * 8.
--    El overload NO cambia el tope: sube la potencia de cada crawler, no cuantos son utiles.
CREATE OR REPLACE FUNCTION public.calculate_crawler_effective_count(p_planet_id uuid)
 RETURNS bigint
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $$
    select least(
               coalesce((select sum(ps.quantity) from public.planet_ships ps
                          where ps.planet_id = p_planet_id and ps.ship_id = 'crawler'), 0),
-- 3. FORMULA PURA DEL OVERLOAD, aislada para poder certificarla sola.
--    Por encima del 100 % el coste crece MAS RAPIDO que la produccion (p + (p-1)),
--    que es justo la penalizacion que hace que el overload sea una decision y no
--    un bonus gratis.
CREATE OR REPLACE FUNCTION public.calculate_crawler_overload_energy(p_crawlers bigint, p_percentage integer)
 RETURNS numeric
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
    v_base numeric;
    v_p    numeric;
BEGIN
    if coalesce(p_crawlers, 0) <= 0 then
        return 0;
    end if;

    v_base := coalesce(p_crawlers, 0)::numeric * 50;   -- coste al 100 %
    v_p    := greatest(0, least(150, coalesce(p_percentage, 100)))::numeric / 100;

    if v_p <= 1 then
        return v_base * v_p;
    end if;

    return v_base * v_p + v_base * (v_p - 1);
END;
$$;

COMMENT ON FUNCTION public.calculate_crawler_overload_energy(bigint,integer) IS
  'OGameX: energia = 50*p (p<=1) | 50*p + 50*(p-1) (p>1), por crawler efectivo. 100%=50, 150%=100.';

-- 4. ENERGIA CON OVERLOAD: misma firma publica que ya consume el motor.
CREATE OR REPLACE FUNCTION public.calculate_crawler_energy_consumption(p_planet_id uuid)
 RETURNS numeric
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $$
    select public.calculate_crawler_overload_energy(
-- 5. PRODUCCION: se multiplica SOLO el termino de crawler por el factor de overload.
--    Splice exacto sobre pg_get_functiondef. El propio bloque ABORTA si el numero de
--    ocurrencias no es 3, de modo que nunca puede aplicarse a otra version por error.
DO $do$
DECLARE
    v_def text;
    v_old text := '0.0002 * v_crawler_effective';
    v_new text := '0.0002 * v_crawler_effective * v_crawler_overload_factor';
    v_n   integer;
BEGIN
    select pg_get_functiondef(p.oid) into v_def
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'calculate_planet_production';

    if v_def is null then
        raise exception 'CRAWLER_OVERLOAD_ABORT: calculate_planet_production no existe';
    end if;

    v_n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
    if v_n <> 3 then
        raise exception 'CRAWLER_OVERLOAD_ABORT: se esperaban 3 ocurrencias de "%" y hay %', v_old, v_n;
    end if;

    v_def := replace(v_def,
        '  v_crawler_effective bigint := 0;',
        '  v_crawler_effective bigint := 0;' || chr(10) ||
        '  v_crawler_overload_factor numeric := 1;');

    v_def := replace(v_def,
        '  v_crawler_effective := least(v_crawler_count, (v_metal_level + v_crystal_level + v_deuterium_level)::bigint * 8);',
        '  v_crawler_effective := public.calculate_crawler_effective_count(p_planet_id);' || chr(10) ||
        '  v_crawler_overload_factor := greatest(0, least(150, coalesce(' ||
        '(select p.crawler_percentage from public.planets p where p.id = p_planet_id), 100)))::numeric / 100;');

    v_def := replace(v_def, v_old, v_new);

    -- GUARDAS: si un replace no encaja, el factor se quedaria en 1 y el overload
    -- seria un no-op SILENCIOSO. Se aborta en vez de fingir que se aplico.
    if position('v_crawler_overload_factor numeric := 1;' in v_def) = 0 then
        raise exception 'CRAWLER_OVERLOAD_ABORT: no se pudo declarar v_crawler_overload_factor';
    end if;
    if position('v_crawler_overload_factor := greatest(0, least(150, coalesce(' in v_def) = 0 then
        raise exception 'CRAWLER_OVERLOAD_ABORT: no se pudo asignar v_crawler_overload_factor desde planets.crawler_percentage';
    end if;
    if position('public.calculate_crawler_effective_count(p_planet_id);' in v_def) = 0 then
        raise exception 'CRAWLER_OVERLOAD_ABORT: no se pudo delegar el tope en calculate_crawler_effective_count';
    end if;

    execute v_def;
END;
$do$;

COMMENT ON FUNCTION public.calculate_planet_production(uuid) IS
  'Produccion autoritativa por hora. Unico cambio de la mision 2026-10-03: el bonus de crawler se escala por planets.crawler_percentage/100 (0-150).';

-- 6. CONTRATO DE LECTURA: se ANADEN dos columnas AL FINAL. Ninguna de las existentes
--    cambia de nombre, tipo ni orden, asi que ningun consumidor actual se rompe.
--    PostgreSQL exige DROP para cambiar la fila de OUT params de una funcion que ya
--    existe. Se comprueba antes que NADIE dependa de ella en la base (el unico
--    consumidor es el navegador, via PostgREST), y el DROP va DENTRO de la misma
--    transaccion que el CREATE: nunca queda un instante sin la funcion.
DO $check$
DECLARE v_deps integer;
BEGIN
    select count(*) into v_deps
      from pg_depend d
     where d.refobjid = 'public.get_planet_crawler_status(uuid)'::regprocedure
       and d.deptype not in ('i','a');

    if v_deps > 0 then
        raise exception 'CRAWLER_OVERLOAD_ABORT: hay % dependencias de BD sobre get_planet_crawler_status', v_deps;
    end if;
END;
$check$;

DROP FUNCTION IF EXISTS public.get_planet_crawler_status(uuid);

CREATE OR REPLACE FUNCTION public.get_planet_crawler_status(p_planet_id uuid)
 RETURNS TABLE(crawler_count bigint, crawler_cap bigint, crawler_effective bigint, crawler_bonus_percent numeric, crawler_energy_per_hour numeric, crawler_percentage integer, crawler_production_multiplier numeric)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $$
declare
    v_player_id  uuid;
    v_planet     uuid;
    v_percentage integer := 100;
    v_metal      integer := 0;
    v_crystal    integer := 0;
    v_deuterium  integer := 0;
    v_count      bigint := 0;
    v_cap        bigint := 0;
    v_effective  bigint := 0;
begin
    select pl.id into v_player_id
      from public.players pl
     where pl.user_id = auth.uid();

    select p.id into v_planet
      from public.planets p
     where p.id = p_planet_id
       and p.player_id = v_player_id
       and p.is_destroyed = false;

    if v_planet is null then
        return;
    end if;
-- 7. ACCION: fijar el overload. SECURITY DEFINER, ownership por sesion, 0-150.
--    No acepta el player_id del cliente como autoridad: se exige que ese jugador
--    pertenezca al usuario autenticado.
CREATE OR REPLACE FUNCTION public.set_planet_crawler_percentage(p_player_id uuid, p_planet_id uuid, p_percentage integer)
 RETURNS TABLE(crawler_percentage integer, crawler_production_multiplier numeric, crawler_energy_per_hour numeric)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
    v_auth uuid := auth.uid();
    v_effective bigint;
begin
    if v_auth is null then
        raise exception 'AUTHENTICATION_REQUIRED';
    end if;

    if not exists (select 1 from public.players pl
                    where pl.id = p_player_id and pl.user_id = v_auth) then
        raise exception 'PLAYER_NOT_OWNED_BY_AUTH_USER';
    end if;

    if p_percentage is null or p_percentage < 0 or p_percentage > 150 then
        raise exception 'CRAWLER_PERCENTAGE_OUT_OF_RANGE: % (debe estar entre 0 y 150)', p_percentage;
    end if;

    update public.planets
       set crawler_percentage = p_percentage
     where id = p_planet_id
       and player_id = p_player_id
       and is_destroyed = false;

    if not found then
        raise exception 'PLANET_NOT_FOUND_OR_NOT_OWNED';
    end if;

    v_effective := public.calculate_crawler_effective_count(p_planet_id);

    return query
    select p_percentage,
           (p_percentage::numeric / 100),
           public.calculate_crawler_overload_energy(v_effective, p_percentage);
end;
$$;

COMMENT ON FUNCTION public.set_planet_crawler_percentage(uuid,uuid,integer) IS
  'Fija el overload del crawler del cuerpo (0-150). Ownership por auth.uid() -> players.user_id. Fuera de rango => error.';

-- 8. ACL: solo el cliente autenticado puede ACCIONAR. Los helpers puros siguen
--    cerrados para que el navegador no los use como oraculo sobre otros cuerpos.
REVOKE ALL ON FUNCTION public.set_planet_crawler_percentage(uuid,uuid,integer) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.set_planet_crawler_percentage(uuid,uuid,integer) TO authenticated;

GRANT  EXECUTE ON FUNCTION public.get_planet_crawler_status(uuid) TO authenticated;

REVOKE ALL ON FUNCTION public.calculate_crawler_effective_count(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.calculate_crawler_overload_energy(bigint,integer) FROM PUBLIC, anon, authenticated;

COMMIT;

    select coalesce(max(level) filter (where building_id = 'metal_mine'), 0),
           coalesce(max(level) filter (where building_id = 'crystal_mine'), 0),
           coalesce(max(level) filter (where building_id = 'deuterium_synthesizer'), 0)
      into v_metal, v_crystal, v_deuterium
      from public.planet_buildings
     where planet_id = v_planet;

    select coalesce(sum(ps.quantity), 0)
      into v_count
      from public.planet_ships ps
     where ps.planet_id = v_planet
       and ps.ship_id = 'crawler';

    select coalesce(p.crawler_percentage, 100) into v_percentage
      from public.planets p where p.id = v_planet;

    v_cap       := (v_metal + v_crystal + v_deuterium)::bigint * 8;
    v_effective := public.calculate_crawler_effective_count(v_planet);

    return query
    select v_count,
           v_cap,
           v_effective,
           (0.0002 * v_effective * (v_percentage::numeric / 100) * 100)::numeric,
           public.calculate_crawler_overload_energy(v_effective, v_percentage),
           v_percentage,
           (v_percentage::numeric / 100);
end;
$$;

COMMENT ON FUNCTION public.get_planet_crawler_status(uuid) IS
  'Estado del crawler del cuerpo. Anade crawler_percentage (0-150) y crawler_production_multiplier. Columnas existentes sin cambios.';
               public.calculate_crawler_effective_count(p_planet_id),
               coalesce((select p.crawler_percentage from public.planets p
                          where p.id = p_planet_id), 100));
$$;

COMMENT ON FUNCTION public.calculate_crawler_energy_consumption(uuid) IS
  'Consumo energetico del crawler con overload. 50 por crawler efectivo al 100 %; 150 % => 100 por crawler.';
               ( coalesce((select max(pb.level) from public.planet_buildings pb
                           where pb.planet_id = p_planet_id and pb.building_id = 'metal_mine'), 0)
               + coalesce((select max(pb.level) from public.planet_buildings pb
                           where pb.planet_id = p_planet_id and pb.building_id = 'crystal_mine'), 0)
               + coalesce((select max(pb.level) from public.planet_buildings pb
                           where pb.planet_id = p_planet_id and pb.building_id = 'deuterium_synthesizer'), 0)
               ) * 8
           );
$$;

COMMENT ON FUNCTION public.calculate_crawler_effective_count(uuid) IS
  'Crawlers efectivos = min(crawlers poseidos, (minas+extraccion)*8). Unica verdad para produccion, energia y contrato de lectura.';
