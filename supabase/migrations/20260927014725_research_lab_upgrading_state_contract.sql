-- ============================================================================================
-- LGI — RESEARCH LAB UPGRADING: estado OGameX (capa de ESTADO/UI, NUNCA enforcement)
-- ============================================================================================
-- OGameX verificado verbatim @ 7c420bad3478d7099791e1f33c920e9ff92822e8:
--   * app/Http/Traits/ObjectAjaxTrait.php, rama GameObjectType::Research (89-95):
--         // Researching is disallowed when Research Lab is upgrading
--         $research_lab_upgrading = $player->isBuildingObject('research_lab');
--     y rama Building/Station:
--         $research_in_progress = $player->isResearching();
--     Los dos flags viajan en el payload ajax (`research_lab_upgrading`, `research_in_progress`).
--   * app/Http/Controllers/ResearchController.php: index() calcula el mismo flag (75) y lo pasa al view model
--     (101) y al payload (134); addBuildRequest() (160-193) valida SÓLO vacation mode + CSRF, y
--     `ResearchQueueService::add()` no comprueba el laboratorio: **OGameX NO bloquea en servidor**.
--   * resources/views/ingame/research/research-item.blade.php: único consumidor del flag, como marca de UI:
--         @elseif ($building->research_lab_upgrading)
--             data-status="disabled"
--   * PlayerService::isBuildingObject() (950-959) recorre TODOS los planetas del jugador → el flag es de
--     IMPERIO, no del planeta activo. PlayerService::isResearching() (828-832) = hay investigación activa.
--
-- CONSECUENCIA PARA LGI (regla de la misión: no introducir un bloqueo backend más estricto que OGameX):
--   * Se reproduce como CONTRATO DE LECTURA + UI. `can_start_research` / `start_research` NO se tocan
--     (contratos certificados) y el cálculo IRN no se toca: el servidor LGI sigue aceptando la investigación
--     mientras el laboratorio se amplía, exactamente igual que OGameX.
--   * El flag inverso (`research_in_progress`) se expone con la misma semántica de OGameX para que la vista
--     de Edificios refleje la regla del laboratorio, sin tocar `start_building`.
--   * NO se implementa la cancelación del PROCESADO de OGameX (BuildingQueueService 398-401 y 416-421
--     cancelan la ampliación/bajada del laboratorio si hay investigación en curso): pertenece al motor de
--     colas, certificado y cerrado en LGI. Se documenta y se reporta; no se toca aquí.

create or replace function public.get_player_research_lab_status()
returns table (
    research_lab_upgrading boolean,
    research_in_progress boolean,
    upgrading_planet_id uuid,
    upgrading_target_level integer,
    upgrading_finishes_at timestamp with time zone
)
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $f$
    with me as (
        select pl.id as player_id from public.players pl where pl.user_id = auth.uid()
    ),
    p as (
        select me.player_id from me where (select count(*) from me) = 1
    ),
    /* OGameX `PlayerService::isBuildingObject('research_lab')` → `PlanetService::isBuildingObject`
       → `BuildingQueueService::objectInBuildingQueue($planet, 'research_lab', current_level + 1)`:
       cuenta una AMPLIACIÓN (target = nivel actual + 1) del laboratorio en cualquier planeta del jugador.
       Una bajada (`is_downgrade`) no activa el flag, igual que `objectInBuildingQueue`, que compara
       `object_level_target` con `current_level + 1`. */
    lab as (
        select q.planet_id, q.target_level, q.finishes_at
          from public.building_queue q
          join public.planets pl on pl.id = q.planet_id
         where pl.player_id = (select p.player_id from p)
           and not pl.is_destroyed
           and q.building_id = 'research_lab'
           and q.status = 'BUILDING'
           and not q.is_downgrade
         order by q.finishes_at
         limit 1
    ),
    /* OGameX `PlayerService::isResearching()` = `activeResearchQueueItemCount > 0`; LGI mantiene una sola
       investigación activa por jugador (`research_queue.status = 'RESEARCHING'`). */
    researching as (
        select rq.id
          from public.research_queue rq
         where rq.player_id = (select p.player_id from p)
           and rq.status = 'RESEARCHING'
         limit 1
    )
    select (select count(*) from lab) > 0,
           (select count(*) from researching) > 0,
           (select lab.planet_id from lab),
           (select lab.target_level from lab),
           (select lab.finishes_at from lab)
    where (select count(*) from p) = 1;
$f$;

comment on function public.get_player_research_lab_status() is
$c$Estado de lectura OGameX (sólo estado/UI, nunca enforcement): `research_lab_upgrading` = algún planeta PROPIO
tiene una ampliación del laboratorio en curso (building_queue.status = 'BUILDING' y sin `is_downgrade`; imperio
entero, como `PlayerService::isBuildingObject`) y `research_in_progress` = hay investigación activa
(research_queue.status = 'RESEARCHING'). `can_start_research` / `start_research` / `start_building` siguen siendo
la autoridad y aceptan la acción mientras el flag está activo, igual que OGameX.$c$;

revoke all on function public.get_player_research_lab_status() from public;
revoke all on function public.get_player_research_lab_status() from anon;
grant execute on function public.get_player_research_lab_status() to authenticated;
grant execute on function public.get_player_research_lab_status() to service_role;
