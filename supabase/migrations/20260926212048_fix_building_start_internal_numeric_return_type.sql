-- H6 — `evaluate_building_start_internal` devolvía literales enteros sin castear en las seis columnas
-- `numeric` (cost_metal/crystal/deuterium y available_metal/crystal/deuterium) de TRES ramas de rechazo:
--   · "Planeta no encontrado o no pertenece al jugador"   (cuerpo ajeno, destruido o inexistente)
--   · "Edificio inexistente"                              (p_building_id desconocido = H6 reportado)
--   · "Nivel máximo alcanzado"                            (edificio ya al máximo)
-- Consecuencia: `can_start_building` — contrato público, certificado y concedido a `authenticated` — no devolvía
-- el rechazo sino que fallaba con `42804 structure of query does not match function result type`, y la superficie
-- de edificios (planetas y lunas) rompía la vista entera cuando un cuerpo activo quedaba obsoleto o ajeno.
--
-- Arreglo MÍNIMO y SÓLO DE TIPOS: los 18 literales de esas tres ramas pasan a `0::numeric`. No cambia ninguna
-- decisión (la misma rama, el mismo `reason`, los mismos valores), no toca firmas, no toca ACLs, no toca el
-- contrato público `can_start_building` (que ya casteaba correctamente sus propios literales) y no toca el resto
-- del cuerpo de la función. La función es interna: su ACL sigue siendo `postgres`/`service_role`.
--
-- La migración es idempotente y auto-verificada: exige encontrar los 3 bloques heredados, y comprueba que la
-- definición resultante es exactamente la reescritura esperada (md5) antes de confirmar.

do $h6$
declare
    v_before text;
    v_expected text;
    v_after text;
    v_hits integer;
    v_pattern text := E'\r\n            0, 0, 0,\r\n            0, 0, 0,';
    v_replacement text := E'\r\n            0::numeric, 0::numeric, 0::numeric,\r\n            0::numeric, 0::numeric, 0::numeric,';
begin
    v_before := pg_get_functiondef('public.evaluate_building_start_internal(uuid,uuid,text)'::regprocedure);

    v_hits := (length(v_before) - length(replace(v_before, v_pattern, ''))) / length(v_pattern);

    if v_hits = 0 and position('0::numeric' in v_before) > 0 then
        raise notice 'H6 already fixed: no legacy numeric literal blocks found';
        return;
    end if;

    if v_hits <> 3 then
        raise exception 'H6_FIX_UNEXPECTED_PATTERN: expected 3 legacy literal blocks, found %', v_hits;
    end if;

    v_expected := replace(v_before, v_pattern, v_replacement);
    execute v_expected;

    v_after := pg_get_functiondef('public.evaluate_building_start_internal(uuid,uuid,text)'::regprocedure);

    if md5(v_after) <> md5(v_expected) then
        raise exception 'H6_FIX_VERIFICATION_FAILED: resulting definition differs from the expected rewrite';
    end if;

    if (length(v_after) - length(replace(v_after, '0::numeric', ''))) / length('0::numeric') <> 18 then
        raise exception 'H6_FIX_VERIFICATION_FAILED: expected 18 cast literals in the result';
    end if;

    raise notice 'H6 fixed: % legacy literal blocks rewritten to numeric', v_hits;
end
$h6$;
