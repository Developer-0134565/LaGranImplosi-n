# La Gran Implosión — Auditoría técnica actual

**Fecha:** 2026-09-13
**Rama:** `main`
**Commit auditado:** `249e1093550068995e38be60df083c3a65bc8132`
**Supabase:** `LaGranImplosión` / `evtfsbntvuqmahiskekd`

## Resultado de esta pasada

Esta pasada no modifica mecánicas de juego ni elimina índices. Se registran únicamente hechos comprobados para no perder contexto entre auditorías.

### Frontend

- `src/App.tsx` ya usa datos reales de `planets` y `planet_resources` mediante Supabase.
- La configuración de fuentes se sanea antes de persistirse y se aplica mediante variables CSS.
- El panel de apariencia dispone de presets, selectores, vista previa y cierre con Escape.
- La carga de fuentes utiliza `document.fonts`; la incidencia observada anteriormente con Google Fonts se identificó como bloqueo externo de Privacy Badger, no como fallo de la lógica de React.
- `src/lib/supabase.ts` utiliza exclusivamente `VITE_SUPABASE_URL` y `VITE_SUPABASE_PUBLISHABLE_KEY`; no se observa una service key en el frontend.
- El CI ejecuta `npm ci`, `npm run lint` y `npm run build`.

### Supabase

El proyecto remoto está `ACTIVE_HEALTHY`.

La auditoría de seguridad actual detecta 7 RPC `SECURITY DEFINER` ejecutables por `authenticated`: `start_building`, `start_colonize_fleet`, `start_fleet`, `start_lifeform_building`, `start_lifeform_research`, `start_research` y `start_ship`.

No se revocan permisos automáticamente: la inspección de sus cuerpos confirma comprobaciones de propiedad mediante `auth.uid()`/`players.user_id` y una ruta de invitado condicionada a `is_guest=true`. El siguiente paso es clasificar cada RPC por superficie pública antes de tocar ACLs.

RLS comprobado en las tablas principales: `planets`, `players` y `planet_resources` tienen políticas de lectura; las tablas sensibles de estado de lifeforms tienen actualmente políticas `deny_direct_api_access`; las colas de construcción/investigación tienen políticas de lectura condicionadas al propietario.

Supabase también informa de 36 índices no utilizados. No se eliminan en esta fase porque el proyecto aún tiene poca carga y varias rutas pueden no haber sido ejercitadas suficientemente.

## Hallazgos que siguen abiertos

1. **Desfase de migraciones:** el historial remoto contiene migraciones posteriores que no están todas materializadas en `supabase/migrations` de Git. No se reconstruye SQL por intuición.
2. **ACL de RPC:** revisar individualmente los 7 `SECURITY DEFINER` antes de cualquier revocación.
3. **Rutas legacy de combate:** cerrar el grafo de llamadas y comprobar que producción no alcance mutadores antiguos.
4. **Guest isolation:** la política actual permite consultar filas de jugadores marcados como guest. Antes de restringirla hay que confirmar el diseño de cuentas invitadas del proyecto.
5. **Frontend:** la navegación sigue siendo visual; aún no están conectados los módulos de planetas, investigación, flota, galaxia, espionaje, expediciones, lifeforms e informes.
6. **CI:** no hay una ejecución de GitHub Actions asociada al commit actual según la integración consultada; no se declara CI verde sin ejecución verificable.

## Regla de esta auditoría

No se elimina infraestructura solo porque el advisor la marque como no usada. No se cambian ACLs de RPC solo para silenciar el linter. No se reconstruyen migraciones remotas con SQL inventado. Cada cambio posterior debe estar respaldado por código existente, comportamiento comprobable o una referencia clara del motor que estamos implementando.
