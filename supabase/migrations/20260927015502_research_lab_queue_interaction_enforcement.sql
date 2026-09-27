-- ============================================================================================
-- LGI — RESEARCH LAB ↔ INVESTIGACIÓN: enforcement de cola (referencia OGameX)
-- ============================================================================================
-- OGameX verificado verbatim @ 7c420bad3478d7099791e1f33c920e9ff92822e8
-- (`app/Services/BuildingQueueService.php`):
--   * addDowngrade() 207-210 (alta de la bajada):
--         // Check if Research Lab is being downgraded while research is in progress
--         if ($building->machine_name === 'research_lab' && $player->isResearching()) {
--             throw new Exception('Cannot downgrade Research Lab while research is in progress.');
--         }
--   * start() 397-401 (rama bajada) y 416-421 (rama ampliación), el PROCESADO de la cola:
--         if ($object->machine_name === 'research_lab' && $player->isResearching()) {
--             $this->cancel($planet, $queue_item->id, $queue_item->object_id);
--             continue;
--         }
--     El chequeo recorre los items AÚN NO iniciados (`building = 0`): `PlanetService::updateBuildingQueue`
--     (1693-1740) NO mira la investigación, así que una ampliación ya EN VUELO termina aunque la
--     investigación arranque después.
--   * cancel() 471-515: marca `canceled = 1` y devuelve EXACTAMENTE el precio cobrado cuando el item ya
--     estaba construyendo (`if ($queue_item->building === 1) addResources(...)`).
--
-- ADAPTACIÓN LGI (arquitectura propia, sin copiar la de OGameX): LGI cobra y arranca en el mismo acto
-- (`start_building`), mantiene UN item activo por planeta y `complete_building` no comprueba la
-- investigación (igual que OGameX con los items en vuelo), de modo que el punto equivalente a «cancelar
-- el item no iniciado» es RECHAZARLO antes de cobrar. El estado final alcanzable es idéntico al de OGameX
-- (ninguna ampliación ni bajada del laboratorio progresa mientras haya investigación activa), sin el ciclo
-- cobro → devolución que OGameX deja en la cola.
--
-- Autoridad única en dos capas, el patrón ya certificado de `enforce_building_kind_and_research`:
--   1) guard BEFORE INSERT en `building_queue` (cubre `start_building`, `start_demolition` y el actor IA);
--   2) la disponibilidad se declara en `evaluate_building_start_internal` (contrato cliente
--      `can_start_building` + camino IA) y en `inspect_demolition` (contrato cliente de demolición).
-- Los procesadores (`process_building_queue*`) y `complete_building` NO se tocan: la tolerancia con los
-- items ya en vuelo es la de OGameX.

create or replace function public.enforce_research_lab_research_interaction()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
    v_player_id uuid;
begin
    /* Sólo el laboratorio de investigación está sujeto a esta regla (OGameX: `research_lab`). */
    if new.building_id <> 'research_lab' then
        return new;
    end if;

    select p.player_id into v_player_id
      from public.planets p
     where p.id = new.planet_id;

    if v_player_id is null then
        /* Planeta o definición inexistentes: los rechaza el guard de tipo/definición. */
        return new;
    end if;

    /* OGameX `PlayerService::isResearching()` = hay investigación activa (LGI: una sola por jugador). */
    if exists (
        select 1
          from public.research_queue rq
         where rq.player_id = v_player_id
           and upper(rq.status) = 'RESEARCHING'
    ) then
        raise exception 'BUILDING_BLOCKED_BY_ACTIVE_RESEARCH: research_lab no puede ampliarse ni bajarse mientras hay una investigación en curso';
    end if;

    return new;
end;
$function$;

comment on function public.enforce_research_lab_research_interaction() is
$c$BEFORE INSERT guard on `building_queue`: OGameX `BuildingQueueService::addDowngrade` (207-210) lanza al
intentar la bajada del laboratorio con investigación activa y su procesado `start()` (398-401 / 416-421) cancela
el item del laboratorio (ampliación o bajada) que aún no ha empezado. LGI cobra al iniciar, así que se rechaza
antes de cobrar: mismo estado final, sin ciclo cobro → devolución. Los items ya en vuelo y `complete_building` no
se tocan (tolerancia idéntica a OGameX).$c$;

drop trigger if exists trg_enforce_research_lab_research_interaction on public.building_queue;
create trigger trg_enforce_research_lab_research_interaction
    before insert on public.building_queue
    for each row
    execute function public.enforce_research_lab_research_interaction();

revoke all on function public.enforce_research_lab_research_interaction() from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 2) DISPONIBILIDAD DEL ALTA — `evaluate_building_start_internal`
--    (consumido por el contrato cliente `can_start_building` y por el camino del actor IA).
--    La regla se inserta justo antes del chequeo de recursos para que las trabas duras
--    (nivel máximo, campos, prerrequisitos, cola) mantengan la prioridad en el motivo.
-- ---------------------------------------------------------------------
do $patch_start$
declare
    v_def text;
    v_old text;
    v_new text;
    v_occ integer;
begin
    select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'evaluate_building_start_internal';

    if v_def is null then
        raise exception 'PATCH TARGET MISSING: evaluate_building_start_internal';
    end if;
    if position('mientras hay una investigación en curso' in v_def) > 0 then
        return; -- idempotente
    end if;

    v_old := $frag$    /*
     * RECURSOS
     */
    IF v_metal < v_cost.metal$frag$;

    v_new := $frag$    /*
     * INTERACCIÓN CON LA INVESTIGACIÓN (OGameX BuildingQueueService 207-210 / 398-401 / 416-421)
     */
    IF p_building_id = 'research_lab'
       AND EXISTS (
           SELECT 1
           FROM public.research_queue AS rq
           WHERE rq.player_id = p_player_id
             AND UPPER(rq.status) = 'RESEARCHING'
       )
    THEN
        RETURN QUERY SELECT
            false,
            'El laboratorio no puede ampliarse mientras hay una investigación en curso',
            v_current_level,
            v_target_level,
            v_cost.metal,
            v_cost.crystal,
            v_cost.deuterium,
            v_metal,
            v_crystal,
            v_deuterium,
            true,
            true,
            v_queue_available;

        RETURN;
    END IF;


    /*
     * RECURSOS
     */
    IF v_metal < v_cost.metal$frag$;

    v_old := replace(replace(v_old, chr(13)||chr(10), chr(10)), chr(13), '');
    v_new := replace(replace(v_new, chr(13)||chr(10), chr(10)), chr(13), '');
    if position(chr(13)||chr(10) in v_def) > 0 then
        v_old := replace(v_old, chr(10), chr(13)||chr(10));
        v_new := replace(v_new, chr(10), chr(13)||chr(10));
    end if;

    select (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) into v_occ;
    if v_occ <> 1 then
        raise exception 'PATCH: evaluate_building_start_internal anchor matched % time(s), expected 1', v_occ;
    end if;

    execute replace(v_def, v_old, v_new);
end;
$patch_start$;

-- ---------------------------------------------------------------------
-- 3) DISPONIBILIDAD DE LA BAJADA — `inspect_demolition`
--    (contrato cliente `can_start_demolition`). La Rule 5 existente bloqueaba la bajada cuando una
--    investigación ACTIVA necesitaba el nivel retirado; OGameX bloquea el laboratorio en bloque
--    (`addDowngrade` 207-210 lanza con CUALQUIER investigación en curso). Se conserva el motivo
--    `DEMOLITION_BLOCKED_BY_ACTIVE_RESEARCH` (mismo vocabulario de UI) y se añade la regla del laboratorio.
--    El resto de la Rule 5 (dependencia de nivel de cualquier edificio) queda intacto.
-- ---------------------------------------------------------------------
do $patch_demolition$
declare
    v_def text;
    v_old text;
    v_new text;
    v_occ integer;
begin
    select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'inspect_demolition';

    if v_def is null then
        raise exception 'PATCH TARGET MISSING: inspect_demolition';
    end if;
    if position('OGameX BuildingQueueService::addDowngrade' in v_def) > 0 then
        return; -- idempotente
    end if;

    v_old := $frag$        /* Rule 5: an active research that still needs the level being removed. */
        v_research_idle := not exists (
            select 1
            from public.research_queue rq
            join public.research_building_prerequisites rbp on rbp.research_id = rq.research_id
            where rq.player_id = p_player_id
              and upper(rq.status) = 'RESEARCHING'
              and rbp.building_id = p_building_id
              and rbp.required_level > v_target_level
        );$frag$;

    v_new := $frag$        /* Rule 5: an active research that still needs the level being removed, OR the research
           laboratory itself while ANY research is in progress (OGameX BuildingQueueService::addDowngrade
           207-210: 'Cannot downgrade Research Lab while research is in progress.'). */
        v_research_idle := not exists (
            select 1
            from public.research_queue rq
            left join public.research_building_prerequisites rbp
              on rbp.research_id = rq.research_id
             and rbp.building_id = p_building_id
            where rq.player_id = p_player_id
              and upper(rq.status) = 'RESEARCHING'
              and (p_building_id = 'research_lab' or rbp.required_level > v_target_level)
        );$frag$;

    v_old := replace(replace(v_old, chr(13)||chr(10), chr(10)), chr(13), '');
    v_new := replace(replace(v_new, chr(13)||chr(10), chr(10)), chr(13), '');
    if position(chr(13)||chr(10) in v_def) > 0 then
        v_old := replace(v_old, chr(10), chr(13)||chr(10));
        v_new := replace(v_new, chr(10), chr(13)||chr(10));
    end if;

    select (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) into v_occ;
    if v_occ <> 1 then
        raise exception 'PATCH: inspect_demolition anchor matched % time(s), expected 1', v_occ;
    end if;

    execute replace(v_def, v_old, v_new);
end;
$patch_demolition$;
