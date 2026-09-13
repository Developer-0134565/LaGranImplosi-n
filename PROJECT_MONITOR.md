# LA GRAN IMPLOSIÓN — Monitor técnico

**Fecha de auditoría:** 2026-09-13  
**Repositorio:** `Developer-0134565/LaGranImplosi-n`  
**Supabase:** `LaGranImplosión` (`evtfsbntvuqmahiskekd`)  
**Rama auditada:** `main`  
**Último commit observado:** `f7323f6b474c3e2692b0ec3a055bc731f26ef945` — conexión del overview con Supabase.

> Este documento distingue entre **implementado**, **conectado**, **auditado** y **pendiente**. La existencia de tablas o funciones no se considera por sí sola una prueba de que una mecánica esté terminada.

## 1. Estado actual

### Backend / Supabase

Estado del proyecto remoto: **ACTIVE_HEALTHY**.

Conteo actual verificado directamente en PostgreSQL:

- **55 tablas públicas**.
- **214 funciones PL/pgSQL públicas**.
- **3 planetas activos**.
- **4 lifeforms**.
- **48 edificios de lifeforms**.
- **72 investigaciones de lifeforms**.
- **5 batallas persistidas**.
- **10 rondas de combate**.
- **232 disparos persistidos**.
- **32 resultados de expedición**.

RLS está habilitado en las tablas revisadas y el modelo ya incluye separación entre jugador autenticado y jugador invitado.

### Frontend / GitHub

El frontend ya **no es una pantalla puramente estática**. `src/App.tsx` actualmente:

- consume `planets` y `planet_resources` desde Supabase;
- determina el planeta principal mediante `is_homeworld`;
- muestra recursos reales del planeta seleccionado por la consulta;
- genera coordenadas reales;
- muestra la lista real de planetas visibles según RLS;
- presenta estados de carga y error;
- mantiene la configuración tipográfica dinámica;
- persiste las fuentes en `localStorage`;
- precarga las fuentes con `document.fonts`;
- tiene controles de accesibilidad básicos para el panel de apariencia.

El commit `f7323f6` es un hito: el primer tramo del frontend ya está conectado al backend real.

## 2. Backend implementado

### Economía / producción

Hay infraestructura para costes, tiempos, producción planetaria, energía, almacenamiento, actualización temporal de recursos, evaluación económica, ROI/payback, candidatos, ranking, siguiente acción, explicación de acciones y simulación de cadenas de construcción.

### Construcción / investigación / astillero

Implementado: definiciones y requisitos, costes y tiempos, colas, finalización, protección de concurrencia, límites de nivel, comprobaciones de recursos, construcción de edificios, investigación, construcción de naves, procesamiento del astillero e integración con el tick planetario.

Entrypoints principales auditados recientemente: `start_building`, `start_research`, `start_ship`.

### Flotas

Implementado: movimientos, distancia y tiempo, carga, velocidad, worker, retorno idempotente, transporte, despliegue, ataque, espionaje, reciclaje, expedición, colonización, resolución de llegadas, comprobación de propietario, comprobación de universo de destino e integración con efectos de lifeforms y objetos.

### Expediciones

Implementado: slots, puntos efectivos, distancia y fórmula de tiempo, hold, retrasos, speedups, recursos, naves, materia oscura, objetos, comerciantes, piratas, aliens, agujeros negros, retornos normales y acelerados, persistencia de resultados, presupuestos de recompensa, integración con worker e idempotencia del combate de expedición.

La secuencia de migraciones recientes incluye auditorías específicas de timing y alineación con OGameX donde ya se decidió usar esa referencia.

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

1. Resolver identidad del jugador actual de forma formal.
2. Completar autenticación.
3. Eliminar datos hardcodeados que aún queden fuera del overview conectado.
4. Convertir navegación lateral en navegación funcional.
5. Pantallas de planetas, edificios/colas, investigación, astillero/flota y movimientos.
6. Galaxia.
7. Espionaje.
8. Expediciones.
9. Lifeforms.
10. Combate e informes.
11. Optimización / siguiente acción.
12. Gestión de errores RPC.
13. Protección contra doble envío.
14. Hooks/servicios de dominio para separar presentación y Supabase.
15. Pruebas frontend ↔ Supabase y E2E.

## 4. Riesgos encontrados en esta auditoría

### R1 — Desfase entre migraciones remotas y migraciones versionadas en Git — ALTA

La base remota registra muchas migraciones aplicadas, mientras que `supabase/migrations` contiene solo un subconjunto reciente.

Ejemplo confirmado: la base registra `20260913043732_harden_internal_rpc_permissions`, mientras el repositorio contiene `20260913044000_harden_internal_rpc_permissions.sql`.

Esto **no debe corregirse inventando una migración nueva**. Primero hay que reconstruir el historial real y determinar qué migraciones fueron aplicadas directamente, renombradas o no sincronizadas con Git.

**Acción:** auditoría de migraciones antes de modificar esquema.

### R2 — SECURITY DEFINER accesible por anon — ALTA / decisión arquitectónica pendiente

El advisor de Supabase detecta actualmente **7 funciones SECURITY DEFINER** ejecutables por `anon` y `authenticated`:

- `start_building`
- `start_colonize_fleet`
- `start_fleet`
- `start_lifeform_building`
- `start_lifeform_research`
- `start_research`
- `start_ship`

No se revocará `anon` automáticamente porque estas funciones contienen una ruta explícita para jugadores invitados (`is_guest=true`) cuando `auth.uid()` es NULL.

La solución correcta es clasificar cada RPC como invitado, autenticado, interno/worker o no expuesto.

### R3 — `public.strict` sin primary key — MEDIA/BAJA

La tabla contiene actualmente solo `dark_matter` y no tiene PK. No se añade una clave artificial sin conocer su propósito.

### R4 — 36 índices marcados como no usados — BAJA

No se eliminan. El proyecto todavía tiene poca carga y varias rutas de combate/lifeforms/expediciones pueden no haberse ejecutado suficientemente.

### R5 — Varias generaciones de combate — MEDIA

Hay infraestructura histórica V1/V2 y rutas nuevas. Parte de lo legacy ya está en cuarentena. Falta cerrar el grafo de llamadas para garantizar que ninguna ruta de producción alcance mutadores antiguos.

### R6 — README probablemente desactualizado — BAJA

Debe revisarse después de cerrar la sincronización de migraciones y la arquitectura frontend.

## 5. Prioridad de la siguiente fase

### Fase 1 — Integridad de repositorio y migraciones

1. Reconstruir correspondencia `supabase migration list` ↔ `supabase/migrations`.
2. Detectar migraciones aplicadas pero ausentes de Git.
3. Detectar archivos Git no aplicados.
4. No alterar producción hasta cerrar esta matriz.

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
