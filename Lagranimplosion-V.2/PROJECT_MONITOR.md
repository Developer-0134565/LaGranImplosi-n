# LA GRAN IMPLOSIÓN — Monitor técnico

**Fecha de auditoría:** 2026-09-13  
**Repositorio:** `Developer-0134565/LaGranImplosi-n`  
**Supabase:** `LaGranImplosión` (`evtfsbntvuqmahiskekd`)  
**Rama auditada:** `main`  
**Último commit observado:** `3504ec24893e0a9f39c5003785a3ddb0a433b704` — conexión de identidad del jugador y estados reales del overview.

> Este documento distingue entre **implementado**, **conectado**, **auditado** y **pendiente**. La existencia de tablas o funciones no se considera por sí sola una prueba de que una mecánica esté terminada.

## 1. Estado actual

### Backend / Supabase

Proyecto remoto: **ACTIVE_HEALTHY**.

La base de datos remota está por delante del historial versionado visible en Git. La comprobación actual muestra migraciones aplicadas hasta `20260913101718_tighten_start_fleet_colonize_mission`, mientras que ese archivo y otras migraciones posteriores a la última sincronización de Git todavía no están presentes en `supabase/migrations` del repositorio.

Esto queda marcado como **desfase de historial**, no como permiso para inventar SQL retrospectivo.

### Frontend / GitHub

El frontend ya no es una pantalla puramente estática. `src/App.tsx` actualmente:

- consume `planets` y `planet_resources` desde Supabase;
- determina el planeta principal mediante `is_homeworld`;
- muestra recursos reales;
- genera coordenadas reales;
- muestra planetas visibles según RLS;
- presenta estados de carga y error;
- mantiene configuración tipográfica dinámica;
- persiste y sanea las fuentes en `localStorage`;
- precarga las fuentes con `document.fonts`;
- aplica las variables tipográficas también al contenedor `.game`;
- incluye controles básicos de accesibilidad para el panel de apariencia.

El último commit observado es `3504ec2`, posterior a la conexión inicial del overview.

## 2. Backend implementado

### Economía / producción

Hay infraestructura para costes, tiempos, producción planetaria, energía, almacenamiento, actualización temporal de recursos, evaluación económica, ROI/payback, candidatos, ranking, siguiente acción, explicación de acciones y simulación de cadenas de construcción.

### Construcción / investigación / astillero

Implementado: definiciones y requisitos, costes y tiempos, colas, finalización, protección de concurrencia, límites de nivel, comprobaciones de recursos, construcción de edificios, investigación, construcción de naves, procesamiento del astillero e integración con el tick planetario.

Entrypoints principales auditados recientemente: `start_building`, `start_research`, `start_ship`.

### Flotas

Implementado: movimientos, distancia y tiempo, carga, velocidad, worker, retorno idempotente, transporte, despliegue, ataque, espionaje, reciclaje, expedición, colonización, resolución de llegadas, comprobación de propietario, comprobación de universo de destino e integración con efectos de lifeforms y objetos.

La base remota ya separa colonización en `start_colonize_fleet`; `start_fleet` ya no acepta `COLONIZE`. La migración que materializa ese cambio aún debe sincronizarse con Git.

### Expediciones

Implementado: slots, puntos efectivos, distancia y fórmula de tiempo, hold, retrasos, speedups, recursos, naves, materia oscura, objetos, comerciantes, piratas, aliens, agujeros negros, retornos normales y acelerados, persistencia de resultados, presupuestos de recompensa, integración con worker e idempotencia del combate de expedición.

### Objetos de expedición

Implementado: definiciones, inventario, consumo, usos, efectos activos, snapshots de efecto e integración con producción, energía, construcción/investigación y velocidad.

### Lifeforms

El núcleo de Lifeforms está implementado en Supabase:

- 4 lifeforms;
- 48 edificios;
- 72 investigaciones;
- descubrimientos;
- lifeform activa por planeta;
- población T1/T2/T3;
- experiencia y nivel;
- tick de población;
- edificios e investigaciones por planeta;
- colas;
- costes;
- efectos;
- integración con Dark Matter;
- integración con velocidad de flota;
- validación de descubrimiento y lifeform activa.

Entrypoints: `start_lifeform_building` y `start_lifeform_research`.

**Pendiente:** auditoría funcional exhaustiva de cada efecto/slot/tier y exposición completa desde frontend.

### Combate

Infraestructura presente: batallas, rondas, snapshots, unidades individuales, estado de unidades, ataques, daño, escudo/casco, rapidfire, selección de objetivos, ledger de disparos, pérdidas, debris, reparación de defensas, contadores finales, tecnologías de combate, pipeline de ataque normal, worker, combate de piratas/aliens y cuarentena de mutadores legacy.

El núcleo está muy avanzado, pero todavía requiere una auditoría de regresión sistemática antes de declararlo cerrado.

### Espionaje / colonización

Implementado: dispatch de espionaje, llegada, reportes, dispatch de colonización, validación de coordenadas y posición ocupada, consumo de nave colonia y llegada de colonización.

### Monitor / optimización

Existe infraestructura para monitor económico, monitor energético, siguiente acción, ranking, candidatos ejecutables/optimizables, ROI, simulación temporal y cadenas de construcción.

**Pendiente:** conectar esta capa con la UI real y validar sus recomendaciones contra escenarios reproducibles.

## 3. Frontend actual

### Implementado

- React 19 + TypeScript + Vite.
- Cliente Supabase mediante `VITE_SUPABASE_URL` y `VITE_SUPABASE_PUBLISHABLE_KEY`.
- Layout principal, topbar, sidebar y overview.
- Consulta real de planetas y recursos.
- Identidad del jugador derivada del planeta cargado.
- Estados de carga/error.
- Panel de apariencia.
- Presets y selectores tipográficos.
- Persistencia y sanitización de fuentes.
- Variables CSS dinámicas.
- Pre-carga de Google Fonts.
- Vista previa tipográfica.
- Accesibilidad básica, cierre con Escape y focus visible.

La incidencia anterior de tipografías quedó identificada como un bloqueo externo de **Privacy Badger**, no como un fallo persistente del motor de selección.

### Pendiente

1. Completar autenticación formal.
2. Sustituir cualquier dato hardcodeado que quede fuera del overview conectado.
3. Convertir navegación lateral en navegación funcional.
4. Pantallas de planetas, edificios/colas, investigación, astillero/flota y movimientos.
5. Galaxia.
6. Espionaje.
7. Expediciones.
8. Lifeforms.
9. Combate e informes.
10. Optimización / siguiente acción.
11. Gestión de errores RPC.
12. Protección contra doble envío.
13. Hooks/servicios de dominio para separar presentación y Supabase.
14. Pruebas frontend ↔ Supabase y E2E.

## 4. Hallazgos confirmados en la auditoría actual

### R1 — Desfase entre migraciones remotas y migraciones versionadas en Git — ALTA

La base remota registra migraciones que no están presentes como archivos en `supabase/migrations` de `main`.

Confirmado actualmente:

- remoto: `20260913101718_tighten_start_fleet_colonize_mission`;
- remoto: `20260913101031_tighten_game_rpc_execute_acl`;
- remoto: `20260913101019_revoke_anon_remaining_game_action_rpcs`;
- en Git no existe, al menos, el archivo `supabase/migrations/20260913101718_tighten_start_fleet_colonize_mission.sql`.

No se debe inventar el contenido histórico. Primero hay que reconstruirlo a partir de los cambios verificables de producción y, si es necesario, materializar una migración de sincronización explícita.

### R2 — SECURITY DEFINER expuesto a authenticated — ADVERTENCIA CONTROLADA

Supabase detecta 7 funciones `SECURITY DEFINER` ejecutables por `authenticated`:

- `start_building`
- `start_colonize_fleet`
- `start_fleet`
- `start_lifeform_building`
- `start_lifeform_research`
- `start_research`
- `start_ship`

La auditoría directa de las funciones confirma que validan `auth.uid()` contra `players.user_id` y que la ruta anónima exige `is_guest=true` cuando `auth.uid()` es NULL. Por tanto, **no se revocará authenticated ni anon a ciegas**.

La siguiente acción correcta es clasificar cada RPC como guest/authenticated/internal y revisar si la exposición pública coincide con esa clasificación.

### R3 — `public.strict` sin primary key — MEDIA/BAJA

La tabla contiene actualmente una sola columna (`dark_matter`), una fila y ninguna constraint. No se añade una PK artificial sin conocer su propósito.

### R4 — 36 índices marcados como no usados — BAJA

No se eliminan. El proyecto todavía tiene poca carga y varias rutas de combate/lifeforms/expediciones pueden no haberse ejecutado suficientemente.

### R5 — Varias generaciones de combate — MEDIA

Hay infraestructura histórica V1/V2 y rutas nuevas. Parte de lo legacy ya está en cuarentena. Falta cerrar el grafo de llamadas para garantizar que ninguna ruta de producción alcance mutadores antiguos.

### R6 — CI sin estado publicado para el último commit — MEDIA/BAJA

El workflow `.github/workflows/ci.yml` existe y ejecuta `npm ci`, lint y build, pero el commit `3504ec2` no devuelve estados de commit publicados mediante la integración consultada. Debe comprobarse la ejecución real de GitHub Actions antes de considerar CI verde.

### R7 — Monitor anteriormente desactualizado — CORREGIDO

Este documento seguía señalando `f7323f6` como último commit. Se actualiza ahora a `3504ec2` y se incorpora el desfase real de migraciones detectado directamente en la base remota.

## 5. Prioridad de la siguiente fase

### Fase 1 — Integridad de repositorio y migraciones

1. Reconstruir correspondencia `supabase migration list` ↔ `supabase/migrations`.
2. Detectar migraciones aplicadas pero ausentes de Git.
3. Detectar archivos Git no aplicados.
4. Reconstruir únicamente cambios verificables.
5. No alterar producción para corregir el historial sin una matriz de correspondencia.

### Fase 2 — Seguridad RPC

1. Auditar los 7 `SECURITY DEFINER` expuestos.
2. Verificar todos los grants.
3. Clasificar guest/authenticated/internal.
4. Revisar RLS de todas las tablas de juego.

### Fase 3 — Integridad de motor

Economía → colas → flotas → expediciones → lifeforms → combate → espionaje/colonización.

### Fase 4 — Frontend

Identidad → servicios/hooks → navegación → módulos → RPCs → estados/errores → pruebas.

## 6. Regla de trabajo

- No crear tablas duplicadas.
- No crear funciones paralelas si ya existe una ruta canónica.
- No renombrar estructuras sin necesidad.
- No eliminar índices legacy sin evidencia.
- No revocar permisos de invitados sin entender el modelo guest.
- No modificar producción para solucionar un warning sin reproducir el problema.
- Cuando OGameX sea una referencia más completa, usarlo como referencia primaria y OGame clásico como contraste.
- Toda corrección importante debe quedar reflejada en Git y en este monitor.
