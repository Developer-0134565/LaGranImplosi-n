-- ============================================================================================
-- LGI — CAMPOS DE RESTOS DEL UNIVERSO: contrato de lectura para el cliente
-- ============================================================================================
-- GAP cerrado (medido LIVE 2026-09-27): `public.debris_fields` tiene la política
-- `deny_direct_api_access` (USING/WITH CHECK false para anon y authenticated) y NINGÚN contrato lo expone, así
-- que el jugador no puede ver dónde hay restos: `src/**` sólo menciona `debris` en textos de informe y nada
-- lee la tabla. La misión RECYCLE sí funciona (el servidor elige el campo MÁS CERCANO en `start_fleet_mixed`),
-- de modo que hoy se recicla a ciegas: no hay forma de saber que existe un campo, ni de qué tamaño, ni si el
-- reciclador irá cerca o al otro extremo del universo.
--
-- Visible para cualquier sesión autenticada del universo, igual que `planets` (la vista de galaxia ya muestra
-- planetas y dueños ajenos): los restos son estado público del juego y `can_recycle_debris` nunca comprobó su
-- propiedad. No se abre la tabla: se expone SÓLO (posición, metal, cristal, actualizado) del sistema pedido y
-- ÚNICAMENTE si el llamante pertenece a ese universo (identidad `auth.uid()` → `players.user_id` validada
-- contra `p_universe_id`); en cualquier otro caso devuelve 0 filas. Los caminos de ESCRITURA
-- (`add_debris_field`, `collect_debris`, `create_combat_debris`) siguen siendo internos.
--
-- Certificado por `supabase/tests/universe_debris_read_contract.sql`.

create or replace function public.get_universe_debris(
    p_universe_id uuid,
    p_galaxy integer,
    p_system integer
)
returns table (
    out_position integer,
    out_metal numeric,
    out_crystal numeric,
    out_updated_at timestamp with time zone
)
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $f$
begin
    /* El universo se VALIDA contra la identidad, nunca se confía en él: sin sesión, sin jugador o con un
       universo al que el llamante no pertenece, la respuesta es 0 filas. */
    if not exists (
        select 1
          from public.players pl
         where pl.user_id = auth.uid()
           and pl.universe_id = p_universe_id
    ) then
        return;
    end if;

    return query
    select d.position, d.metal, d.crystal, d.updated_at
      from public.debris_fields d
     where d.universe_id = p_universe_id
       and d.galaxy = p_galaxy
       and d.system = p_system
       and (d.metal > 0 or d.crystal > 0)
     order by d.position;
end;
$f$;

comment on function public.get_universe_debris(uuid, integer, integer) is
$c$Contrato de lectura de los campos de restos de un sistema del universo propio: una fila por posición con
`metal`, `crystal` y `updated_at`. Existe porque `debris_fields` está cerrada al cliente por política y sin él la
misión RECYCLE (que el servidor dirige al campo MÁS CERCANO) era completamente ciega. La pertenencia al universo
se valida con `auth.uid()` → `players.user_id` contra `p_universe_id`; si no se cumple, 0 filas. Sólo lectura:
los productores (`create_combat_debris`, `add_debris_field`) y el recolector (`collect_debris`) siguen internos.
Certificado por `supabase/tests/universe_debris_read_contract.sql`.$c$;

revoke all on function public.get_universe_debris(uuid, integer, integer) from public;
revoke all on function public.get_universe_debris(uuid, integer, integer) from anon;
grant execute on function public.get_universe_debris(uuid, integer, integer) to authenticated;
grant execute on function public.get_universe_debris(uuid, integer, integer) to service_role;
