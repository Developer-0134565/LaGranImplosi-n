-- ============================================================================================
-- LGI — COMERCIANTE DE EXPEDICIÓN: contrato de cliente (lectura owner-scoped + comercio)
-- ============================================================================================
-- GAP cerrado: el desenlace MERCHANT de la expedición (OGameX `ExpeditionOutcomeType::GainMerchantTrade`,
-- peso `expedition_settings.weight_merchant` = 0.4 en el universo ACTIVO `cf021ece`) YA se produce y persiste —
-- `resolve_expedition_arrival` → `resolve_expedition_merchant` escribe o MEJORA la fila activa de
-- `player_expedition_merchants`, y el informe (`expedition_results.merchant_*`) y el mensaje lo anuncian — pero
-- el premio NO era consumible desde el juego (medido LIVE 2026-09-27):
--   * `player_expedition_merchants` lleva la política `deny_direct_api_access` (USING/WITH CHECK `false` para
--     anon y authenticated) → el cliente no puede leer la oferta;
--   * `execute_expedition_merchant_trade` es EXECUTE **sólo** para `service_role`, no tiene ningún llamador en
--     `pg_proc` y no existe ruta de cliente (el Worker no invoca RPCs y no hay Edge Functions) → la oferta
--     quedaba activa para siempre y sólo podía "mejorarse" con otro desenlace MERCHANT.
-- Consecuencia real: un premio imposible de usar y una fila de estado que nunca se cierra.
--
-- Adaptación LGI — ninguna regla nueva, ninguna fórmula nueva, ningún motor paralelo:
--   * el comercio se delega ÍNTEGRAMENTE en la función ya LIVE `execute_expedition_merchant_trade`
--     (tasas de la oferta, un solo comercio por comerciante, recorte por almacén, intercambio de recursos y
--     nada de materia oscura);
--   * lo único que añade el wrapper es la capa de IDENTIDAD que la función interna no necesita porque sólo la
--     llamaba `service_role`: actor derivado de `auth.uid()` (jamás un `p_player_id` del cliente) y propiedad
--     comprobada del cuerpo. La función interna NO se modifica: el actor IA / `service_role` sigue pasando su
--     propio `p_player_id`.
--   * el comerciante general, la tienda y la economía premium (gasto de DM) siguen FUERA DE ALCANCE: esto es
--     sólo la variante de expedición que el proyecto ya adoptó (pesos + tabla + generador de oferta + informe).
--
-- Certificado por `supabase/tests/expedition_merchant_trade.sql`.

-- ---------------------------------------------------------------------------------------------
-- 1) LECTURA de la oferta activa (la tabla está cerrada al cliente por política, igual que el resto
--    de las tablas de expedición). Devuelve SIEMPRE una fila para que la UI tenga una forma estable.
--    `offered_resource` es el recurso que el comerciante ENTREGA al jugador (el `bought_resource` del
--    comercio): el jugador paga con uno de los otros dos, al cambio de las tasas devueltas.
-- ---------------------------------------------------------------------------------------------
create or replace function public.get_player_expedition_merchant()
returns table (
    has_merchant boolean,
    offered_resource text,
    metal_rate numeric,
    crystal_rate numeric,
    deuterium_rate numeric,
    source text,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
)
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $f$
    with me as (
        select pl.id as player_id
          from public.players pl
         where pl.user_id = auth.uid()
    ),
    p as (
        select me.player_id from me where (select count(*) from me) = 1
    )
    select (m.player_id is not null),
           m.resource,
           m.metal_rate,
           m.crystal_rate,
           m.deuterium_rate,
           m.source,
           m.created_at,
           m.updated_at
      from (select 1) anchor
      left join public.player_expedition_merchants m
             on m.player_id = (select p.player_id from p)
            and m.active
     where (select count(*) from p) = 1;
$f$;

comment on function public.get_player_expedition_merchant() is
$c$Contrato de lectura owner-scoped del comerciante de expedición: una fila con `has_merchant` (false cuando no
hay oferta activa), `offered_resource` (el recurso que el comerciante ENTREGA — es el `bought_resource` del
comercio) y las tres tasas de la oferta. La identidad sale de `auth.uid()` → `players.user_id`; sin jugador
resoluble no devuelve filas. Existe porque `player_expedition_merchants` está cerrada al cliente por política.
Certificado por `supabase/tests/expedition_merchant_trade.sql`.$c$;

revoke all on function public.get_player_expedition_merchant() from public;
revoke all on function public.get_player_expedition_merchant() from anon;
grant execute on function public.get_player_expedition_merchant() to authenticated;
grant execute on function public.get_player_expedition_merchant() to service_role;

-- ---------------------------------------------------------------------------------------------
-- 2) COMERCIO: contrato de cliente. Aporta el actor autorizado (auth.uid() → players.user_id) y la
--    propiedad del cuerpo, y delega toda la regla del comercio en la función ya LIVE.
-- ---------------------------------------------------------------------------------------------
create or replace function public.trade_with_expedition_merchant(
    p_planet_id uuid,
    p_sell_resource text,
    p_sell_amount numeric
)
returns table (
    sold numeric,
    bought numeric,
    bought_resource text,
    remaining_merchant boolean
)
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
    v_auth_user uuid;
    v_owner uuid;
begin
    v_auth_user := auth.uid();
    if v_auth_user is null then
        raise exception 'Authentication required';
    end if;

    /* Propiedad: cuerpo → players.user_id. Nunca una identidad enviada por el cliente, y nunca una
       heurística global de "primer planeta". Un cuerpo ajeno o destruido se rechaza antes de tocar nada. */
    select pl.id into v_owner
      from public.planets p
      join public.players pl on pl.id = p.player_id
     where p.id = p_planet_id
       and pl.user_id = v_auth_user
       and p.is_destroyed = false;

    if v_owner is null then
        raise exception 'PLANET_NOT_FOUND_OR_NOT_OWNED';
    end if;

    /* Toda la regla vive en la función ya LIVE (tasas, un único comercio por comerciante, recorte por
       almacén, recursos y asentamiento previo). Aquí sólo se aporta el actor autorizado. */
    return query
    select *
      from public.execute_expedition_merchant_trade(v_owner, p_planet_id, p_sell_resource, p_sell_amount);
end;
$function$;

comment on function public.trade_with_expedition_merchant(uuid, text, numeric) is
$c$Contrato de cliente del comerciante de expedición (OGameX `ExpeditionOutcomeType::GainMerchantTrade`).
Deriva el jugador de `auth.uid()` → `players.user_id` (no acepta `p_player_id`), exige que `p_planet_id` sea un
cuerpo PROPIO y no destruido, y delega el comercio en `execute_expedition_merchant_trade` — que sigue siendo la
autoridad de tasas, recorte por almacén, un-solo-comercio-por-comerciante y movimiento de recursos (sin materia
oscura). Devuelve las mismas cuatro columnas (`sold`, `bought`, `bought_resource`, `remaining_merchant`) para que
el cliente nunca tenga que recalcular el cambio. La función interna NO se modifica: el actor IA / service_role
sigue pasando su propio `p_player_id`. Certificado por `supabase/tests/expedition_merchant_trade.sql`.$c$;

revoke all on function public.trade_with_expedition_merchant(uuid, text, numeric) from public;
revoke all on function public.trade_with_expedition_merchant(uuid, text, numeric) from anon;
grant execute on function public.trade_with_expedition_merchant(uuid, text, numeric) to authenticated;
grant execute on function public.trade_with_expedition_merchant(uuid, text, numeric) to service_role;

