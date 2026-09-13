# LA GRAN IMPLOSIÓN — Monitor técnico

**Fecha de auditoría:** 2026-09-13  
**Repositorio:** `Developer-0134565/LaGranImplosi-n`  
**Supabase:** proyecto `LaGranImplosión` (`evtfsbntvuqmahiskekd`)  
**Objetivo de este documento:** mantener un inventario técnico real y separar lo implementado de lo pendiente, sin asumir que una función existente está terminada solo porque existe.

## 1. Estado general

### Backend / Supabase

El backend está considerablemente más avanzado que la interfaz actual. La base pública contiene **55 tablas** y **214 funciones PL/pgSQL**. Hay estructuras para economía, producción, colas, flotas, expediciones, combate, espionaje, colonización, lifeforms y optimización.

RLS está activo en las tablas críticas revisadas: jugadores, planetas, recursos, edificios, naves, colas, flotas, combate y lifeforms.

### Frontend / GitHub

El frontend es React + TypeScript + Vite. La aplicación ya contiene la interfaz base, configuración dinámica de tipografías y un cliente Supabase en `src/lib/supabase.ts`, pero `src/App.tsx` sigue siendo principalmente una pantalla de demostración: los recursos, planetas y estados mostrados son valores estáticos y la navegación todavía no ejecuta las operaciones reales del backend.

Esto es actualmente la **principal incongruencia arquitectónica**: el motor Supabase tiene mucha más funcionalidad que la UI que lo consume.

---

## 2. Funciones implementadas en Supabase

### Economía y producción

Implementado a nivel de funciones y estructuras:

- cálculo de costes de edificios e investigaciones;
- cálculo de tiempos;
- producción planetaria;
- snapshots de producción;
- consumo y balance energético;
- almacenamiento;
- actualización temporal de recursos;
- producción virtual/simulada;
- ROI y payback de acciones;
- candidatos económicos y de optimización;
- ranking de acciones;
- siguiente acción y explicación de la siguiente acción;
- evaluación temporal/económica/energética de acciones;
- simulación y evaluación de cadenas de edificios.

Funciones clave presentes incluyen `calculate_building_cost`, `calculate_building_time`, `calculate_planet_production`, `calculate_planet_energy_balance`, `calculate_planet_storage`, `update_planet_resources`, `update_planet_resources_until`, `calculate_action_payback`, `evaluate_action_at_time`, `rank_building_sequences`, `evaluate_building_chain` y varias funciones auxiliares.

### Construcción, investigación y astillero

Implementado:

- requisitos de edificios;
- colas de edificios;
- finalización de edificios;
- requisitos de investigación;
- colas de investigación;
- finalización de investigación;
- requisitos de naves;
- cálculo de costes y tiempos de naves;
- cola de astillero;
- procesamiento de colas;
- integración del astillero con el tick planetario;
- protección de escrituras de las colas;
- funciones `start_building`, `start_research` y `start_ship` con comprobación de propietario.

### Flotas

Implementado:

- movimiento de flotas;
- cálculo de distancia;
- cálculo de tiempo;
- capacidad de carga;
- velocidad de flota;
- worker de flotas;
- retorno idempotente;
- transporte;
- despliegue;
- ataque;
- espionaje;
- reciclaje;
- expediciones;
- colonización;
- resolución de llegadas;
- integración de efectos de lifeforms y objetos de expedición en velocidad;
- protección de identidad del jugador en los entrypoints principales.

Entry points relevantes: `start_fleet`, `start_colonize_fleet`, `process_fleet_movements`, `run_fleet_worker`, `resolve_attack_arrival`, `resolve_transport_arrival`, `resolve_deploy_arrival`, `resolve_espionage_arrival`, `resolve_colonize_arrival` y `calculate_fleet_time`.

### Expediciones

Es una de las áreas más desarrolladas. El historial de migraciones muestra trabajo específico para:

- fórmula de distancia y tiempo;
- espera/hold de expedición;
- retrasos;
- speedups;
- clase de expedición;
- puntos efectivos;
- capacidad de recursos;
- presupuestos de recompensas;
- recompensas de recursos;
- recompensas de naves;
- materia oscura;
- objetos;
- comerciantes;
- piratas;
- aliens;
- agujeros negros;
- retornos normales y acelerados;
- integración con el worker;
- idempotencia del combate de expedición;
- alineación de fórmulas con OGameX donde ya se auditó.

Funciones relevantes: `calculate_expedition_time`, `calculate_expedition_distance`, `calculate_expedition_points`, `calculate_expedition_effective_points`, `calculate_expedition_resource_reward`, `calculate_expedition_dark_matter_amount`, `resolve_expedition_arrival`, `resolve_expedition_return`, `resolve_expedition_pirates`, `resolve_expedition_aliens`, `resolve_expedition_black_hole`, `resolve_expedition_item` y `resolve_expedition_merchant`.

Datos actuales observados: 32 resultados de expedición.

### Objetos de expedición

Implementado:

- definiciones de objetos;
- usos;
- efectos activos;
- consumo;
- efectos sobre producción/energía/velocidad;
- integración con los cálculos del motor.

### Lifeforms

El **núcleo de Lifeforms sí existe**. La base contiene:

- 4 lifeforms;
- 48 definiciones de edificios de lifeforms;
- 72 definiciones de investigaciones de lifeforms;
- descubrimientos de jugadores;
- lifeforms por planeta;
- edificios por planeta;
- investigaciones por planeta;
- colas de edificios;
- colas de investigación;
- población/tick;
- costes;
- efectos;
- integración con Dark Matter;
- integración con velocidad de flota;
- comprobaciones de lifeform activa y descubrimiento;
- funciones `start_lifeform_building` y `start_lifeform_research`.

**No se considera pendiente la existencia del núcleo.** Lo pendiente es la auditoría funcional completa y su integración real con la UI, además de verificar todos los efectos y niveles contra las reglas objetivo.

### Combate

El motor de combate tiene una cantidad importante de infraestructura V1/V2/V3 y ha recibido una secuencia reciente de correcciones.

Implementado a nivel de backend:

- batallas;
- rondas;
- snapshots;
- unidades individuales;
- estado de unidades;
- ataques/daño;
- casco/escudo;
- daño pendiente;
- rapidfire;
- selección de objetivos;
- generación de disparos;
- resolución de disparos;
- explosiones;
- pérdidas;
- debris;
- reparación de defensas;
- contadores finales;
- resolución de batalla;
- pipeline de ataque normal;
- worker de flotas;
- combate de piratas y aliens en expediciones;
- persistencia del ledger de daño de disparos;
- snapshots de escudo;
- tecnologías de combate;
- cuarentena de mutadores legacy.

Funciones representativas: `generate_combat_round_v2`, `process_combat_round_v2`, `generate_combat_shot_v2`, `resolve_combat_shot_v2`, `resolve_combat_damage_v2`, `resolve_combat_rapidfire`, `create_next_combat_round_v2`, `expand_all_rapidfire_v2`, `finish_combat_battle`, `calculate_combat_total_debris`, `calculate_combat_ship_losses` y `calculate_combat_defense_losses`.

Datos actuales: 5 batallas, 10 rondas y 232 disparos persistidos.

### Espionaje y colonización

El backend ya tiene una implementación para:

- reportes de espionaje;
- dispatch de espionaje;
- llegada de espionaje;
- dispatch de colonización;
- comprobación de coordenadas;
- comprobación de posición ocupada;
- consumo de nave colonia;
- llegada de colonización.

Hay 1 reporte de espionaje y 3 planetas actualmente en la base.

### Monitorización / optimización

Hay estructuras para:

- `empire_economic_monitor`;
- `empire_energy_monitor`;
- `empire_next_action`;
- `empire_action_ranking`;
- candidatos de acción;
- candidatos ejecutables;
- candidatos de optimización;
- ROI;
- secuencias de construcción;
- simulación de acciones;
- acciones temporales;
- explicación de siguiente acción.

El motor de optimización existe, pero la interfaz todavía no expone este sistema de forma real.

---

## 3. Estado del frontend

### Ya implementado

- React 19 + TypeScript + Vite.
- Layout base del juego.
- Topbar.
- Recursos de demostración.
- Sidebar.
- Dashboard base.
- Panel de apariencia.
- Presets tipográficos.
- Selectores por rol.
- Persistencia de tipografías en `localStorage`.
- Sanitización de configuraciones guardadas.
- Aplicación dinámica de variables CSS.
- Pre-carga de fuentes mediante `document.fonts`.
- Preview de cada tipografía.
- Cliente Supabase en `src/lib/supabase.ts`.
- Uso de `VITE_SUPABASE_URL` y `VITE_SUPABASE_PUBLISHABLE_KEY`, sin introducir claves secretas en frontend.

La implementación actual de tipografía está especialmente protegida contra valores inválidos y contra fallos de `localStorage`. El problema observado anteriormente con las fuentes no era únicamente código: Privacy Badger estaba bloqueando la carga de Google Fonts.

### Pendiente en frontend

1. Conectar autenticación real.
2. Sustituir los valores hardcodeados del dashboard por datos Supabase.
3. Resolver jugador actual y planeta actual.
4. Mostrar recursos calculados en tiempo real.
5. Mostrar colas reales.
6. Mostrar flotas reales.
7. Mostrar investigación real.
8. Mostrar edificios reales.
9. Implementar navegación real entre módulos.
10. Implementar galaxia.
11. Implementar espionaje.
12. Implementar expediciones.
13. Implementar Lifeforms.
14. Implementar combate/informes.
15. Exponer el sistema de optimización y siguiente acción.
16. Añadir estados de carga, errores y estados vacíos.
17. Añadir protección contra doble envío de acciones.
18. Validar permisos antes de presentar acciones ejecutables.
19. Crear una capa de servicios/hooks para no llamar RPCs directamente desde componentes de presentación.
20. Añadir pruebas de integración frontend ↔ Supabase.

---

## 4. Errores / riesgos actuales

### R1 — Integración frontend/backend incompleta — ALTA

`src/lib/supabase.ts` existe, pero `App.tsx` no está consumiendo todavía el estado real de Supabase. La pantalla principal continúa usando valores de demostración.

### R2 — Advertencias SECURITY DEFINER — ALTA, pendiente de decisión arquitectónica

Supabase detecta 8 funciones `SECURITY DEFINER` ejecutables por `anon` y `authenticated`.

No se debe eliminar este acceso automáticamente: las funciones `start_*` contienen explícitamente una bifurcación para jugadores invitados (`is_guest`) cuando `auth.uid()` es NULL. Por tanto, revocar `anon` indiscriminadamente rompe el modelo de invitado existente.

La solución correcta pendiente es auditar función por función y decidir qué RPC debe ser:

- público para invitados;
- solo `authenticated`;
- solo interno/worker;
- o `SECURITY INVOKER`.

Los entrypoints de juego revisados ya comprueban la correspondencia entre jugador y usuario autenticado y rechazan un jugador ajeno.

### R3 — Tabla `public.strict` sin primary key — MEDIA/BAJA

El linter detecta `public.strict` sin primary key. La tabla solo contiene actualmente `dark_matter` como columna `numeric`. No se ha añadido una PK porque no conocemos todavía su propósito semántico y hacerlo a ciegas podría cambiar el diseño previsto.

### R4 — Índices marcados como no usados — BAJA / NO TOCAR AÚN

El linter informa 36 índices no utilizados. Esto no demuestra que sean inútiles: el proyecto todavía tiene poca carga y el motor tiene rutas que pueden no haberse ejecutado suficientemente. No eliminarlos hasta disponer de tráfico/pruebas representativas.

### R5 — Funciones legacy y múltiples generaciones del combate — MEDIA

Existen funciones V1/V2/V3 y funciones históricas relacionadas con combate. Algunas ya están explícitamente puestas en cuarentena, pero hay que completar el mapa de llamadas para garantizar que ningún worker o RPC real termine usando accidentalmente una ruta legacy.

### R6 — README desactualizado — BAJA

El README sigue describiendo el repositorio como el template inicial de React/Vite, mientras que el proyecto ya contiene un backend de juego muy avanzado. Debe actualizarse cuando cerremos la primera auditoría estructural.

---

## 5. Auditorías pendientes prioritarias

### A. Seguridad Supabase

- mapear grants de todas las funciones públicas;
- clasificar RPC públicas / autenticadas / internas;
- verificar `SECURITY DEFINER` y `search_path` en todas las funciones sensibles;
- revisar todas las políticas RLS, no solo las tablas principales;
- comprobar que ningún RPC permita cambiar `player_id` de otro usuario;
- revisar funciones de lectura que devuelvan información de otros jugadores;
- revisar guest access de forma específica;
- revisar exposición de funciones internas de workers.

### B. Integridad económica

- recursos y almacenamiento;
- producción por tick;
- energía;
- costes;
- tiempos;
- colas;
- cancelaciones;
- concurrencia;
- doble ejecución;
- límites de nivel;
- efectos de objetos y lifeforms.

### C. Combate V2

- verificar pipeline canónico de ataque;
- eliminar rutas legacy no alcanzables;
- validar orden de rondas;
- validar snapshots;
- validar daño de escudo/casco;
- validar rapidfire;
- validar explosión;
- validar pérdidas;
- validar debris;
- validar reparación;
- comprobar idempotencia del worker;
- crear casos de regresión reproducibles.

### D. Expediciones

- comprobar fórmulas finales frente a OGameX/OGame cuando proceda;
- verificar cada outcome;
- comprobar pesos y límites;
- revisar tiempos y hold;
- revisar speedup;
- revisar recompensa de naves;
- revisar Dark Matter;
- revisar objetos;
- revisar comerciante;
- revisar piratas;
- revisar aliens;
- revisar agujero negro;
- comprobar que un evento no pueda ejecutarse dos veces.

### E. Lifeforms

- validar los 4 lifeforms;
- validar los 48 edificios;
- validar las 72 investigaciones;
- validar requisitos de población;
- validar tiers y slots;
- validar efectos acumulativos;
- validar efectos de fleet speed y demás estadísticas;
- validar costes y tiempos;
- validar interacción con producción/energía;
- validar descubrimientos;
- validar que las acciones no puedan ejecutarse sobre un lifeform no activo.

### F. Flotas

- ataque;
- transporte;
- despliegue;
- reciclaje;
- espionaje;
- colonización;
- expedición;
- retorno;
- consumo/restauración de naves;
- cargo;
- velocidad;
- evolución del universo;
- concurrencia de movimientos.

### G. Frontend

- integración real con Supabase;
- autenticación/guest;
- servicios RPC;
- estado global;
- caché/refresco;
- manejo de errores;
- protección contra doble acción;
- sincronización temporal;
- UI de colas;
- UI de informes.

---

## 6. Próxima secuencia recomendada

No ampliar funcionalidades grandes todavía. El orden recomendado es:

1. **Cerrar auditoría de seguridad RPC/RLS.**
2. **Mapear frontend ↔ backend y eliminar incongruencias de contrato.**
3. **Crear una capa de servicios Supabase estable.**
4. **Conectar Overview a datos reales.**
5. **Probar recursos/producción/colas con datos reales.**
6. **Conectar edificios/investigación/flota.**
7. **Auditar y exponer expediciones.**
8. **Auditar Lifeforms antes de crear una UI grande.**
9. **Cerrar combate V2 con regresiones.**
10. **Después ampliar Galaxy, espionaje, informes y optimización visual.**

## 7. Principio de mantenimiento

- No inventar reglas si el backend o una referencia fiable no las define.
- No eliminar funciones antiguas hasta demostrar que son inalcanzables.
- No eliminar índices únicamente porque el linter los marque como no usados.
- No modificar fórmulas económicas o de combate sin un caso reproducible.
- Preferir migraciones pequeñas y reversibles.
- Después de cada cambio de backend: revisar advisors + ejecutar pruebas de regresión.
- Cuando OGameX aporte una implementación más completa, usarlo como referencia primaria para esa mecánica; OGame clásico como contraste.

## 8. Estado de la auditoría actual

**Backend:** 🟡 avanzado, pero requiere auditoría de contratos y seguridad antes de considerarlo cerrado.  
**Combate:** 🟡 motor V2 avanzado; requiere regresión y limpieza final de rutas legacy.  
**Expediciones:** 🟡 muy avanzado; requiere auditoría final de outcomes y regresiones.  
**Lifeforms:** 🟡 núcleo implementado; falta auditoría funcional completa y UI.  
**Flotas:** 🟡 núcleo implementado; falta cobertura completa de pruebas y UI.  
**Frontend:** 🔴 todavía principalmente demostrativo respecto al backend real.  
**Optimización:** 🟡 motor de datos/candidatos presente; UI y validación final pendientes.  
**Seguridad:** 🟡 RLS activo y guards presentes, pero quedan warnings de `SECURITY DEFINER` que deben resolverse mediante clasificación de RPC, no mediante revocaciones ciegas.  
**Rendimiento:** 🟢 sin problemas críticos observados; los 36 índices no usados quedan en observación hasta disponer de carga representativa.

## 9. Datos de referencia observados durante esta auditoría

- 55 tablas públicas.
- 214 funciones públicas.
- 4 lifeforms.
- 48 edificios de lifeforms.
- 72 investigaciones de lifeforms.
- 16 naves.
- 8 defensas.
- 8 edificios base.
- 16 investigaciones base.
- 5 batallas.
- 10 rondas de combate.
- 232 disparos.
- 46 movimientos de flota.
- 32 resultados de expedición.
- 1 reporte de espionaje.
- 3 planetas.
- 1 jugador.

Estos números son una fotografía de la base en el momento de la auditoría, no límites del diseño.
