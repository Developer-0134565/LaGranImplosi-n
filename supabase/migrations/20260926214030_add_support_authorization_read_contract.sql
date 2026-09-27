-- ============================================================================================
-- LGI — ACS_HOLD: contrato de descubrimiento de autorizaciones de apoyo (owner-scoped)
-- ============================================================================================
-- Hueco demostrado LIVE (2026-09-26), con el motor de apoyo y la concesión ya certificados:
--   * `planet_support_authorizations` tiene RLS con `deny_direct_api_access` y sólo MAINTAIN para
--     `authenticated` → permission denied en lectura directa;
--   * `players` (RLS) oculta a los demás humanos: ni por id ni por nombre (0 filas);
--   * `get_universe_ranking*` NO expone a otros humanos humanos (verificado: el jugador ajeno no aparece);
--   * no existía ningún contrato de lectura para las autorizaciones.
-- Conceder (`grant_planet_support_authorization`) y enviar (`start_support_fleet`) ya funcionan; lo que faltaba era
-- que cada lado pudiera DESCUBRIR la autorización que le afecta.
--
-- Alcance mínimo (no es un directorio de jugadores):
--   * devuelve SÓLO las autorizaciones no revocadas en las que el llamante es parte (owner o guest);
--   * SECURITY DEFINER con `search_path` fijo (patrón del proyecto) y propiedad vía `players.user_id = auth.uid()`;
--   * expone el nombre del contraparte únicamente para una relación que ya existe con el llamante, más los datos
--     públicos del planeta destino y las fechas almacenadas;
--   * `out_is_usable` refleja el MISMO predicado del despachador (no revocado y sin caducar); la autoridad sigue
--     siendo `start_support_fleet`, que revalida la autorización en el momento del envío;
--   * EXECUTE sólo `authenticated`/`service_role` (nunca `anon`); no se toca ninguna ACL de tablas ni RLS.
--
-- Identificación del contraparte para CONCEDER: no requiere contrato nuevo — `planets.player_id` es público (la
-- galaxia ya lo muestra), así que el propietario resuelve al invitado por coordenadas. Este contrato no permite
-- enumerar jugadores ni leer autorizaciones ajenas.

create or replace function public.get_player_support_authorizations()
returns table (
    out_authorization_id uuid,
    out_direction text,
    out_destination_planet_id uuid,
    out_destination_name text,
    out_destination_kind text,
    out_galaxy integer,
    out_system integer,
    out_position integer,
    out_owner_player_id uuid,
    out_owner_username text,
    out_guest_player_id uuid,
    out_guest_username text,
    out_authorized_at timestamp with time zone,
    out_expires_at timestamp with time zone,
    out_is_usable boolean
)
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $f$
    with me as (
        select pl.id
          from public.players pl
         where pl.user_id = auth.uid()
    )
    select a.id,
           case when a.owner_player_id = me.id then 'GRANTED' else 'RECEIVED' end,
           a.destination_planet_id,
           p.name,
           p.kind,
           p.galaxy,
           p.system,
           p.position,
           a.owner_player_id,
           own.username,
           a.guest_player_id,
           gst.username,
           a.authorized_at,
           a.expires_at,
           (a.expires_at is null or a.expires_at > now())
      from public.planet_support_authorizations a
      join me on me.id in (a.owner_player_id, a.guest_player_id)
      join public.planets p on p.id = a.destination_planet_id
      join public.players own on own.id = a.owner_player_id
      join public.players gst on gst.id = a.guest_player_id
     where a.revoked_at is null
     order by a.authorized_at desc;
$f$;

revoke all on function public.get_player_support_authorizations() from public, anon;
grant execute on function public.get_player_support_authorizations() to authenticated;
grant execute on function public.get_player_support_authorizations() to service_role;
