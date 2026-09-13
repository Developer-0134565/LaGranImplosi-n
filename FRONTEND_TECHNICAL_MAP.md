# LA GRAN IMPLOSIÓN — Mapa técnico frontend

**Fecha:** 2026-09-13  
**Rama auditada:** `main`  
**Objetivo:** documentar el frontend real antes de conectar módulos del motor Supabase, evitando inventar capas o sustituir la arquitectura existente.

## 1. Stack real

- React 19
- TypeScript 6
- Vite 8
- `@supabase/supabase-js` 2.x
- Cloudflare/Vite plugin + Wrangler
- ESLint 10

La dependencia de Supabase está declarada y existe un cliente en `src/lib/supabase.ts`, pero la búsqueda del repositorio no encuentra actualmente llamadas `supabase.*` desde el frontend. Por tanto, el cliente está preparado pero todavía no constituye una capa de integración funcional.

## 2. Árbol funcional actual

```text
src/
├── App.tsx                 # shell actual + dashboard demo + preferencias visuales
├── App.css                 # layout/estilos de la aplicación
├── index.css               # estilos globales mínimos
├── main.tsx                # bootstrap React
├── lib/
│   └── supabase.ts         # cliente Supabase; sin RPC/queries consumidoras aún
├── styles/
│   └── fonts.css           # definición/carga de tipografías
└── assets/                 # recursos visuales
```

No se ha creado todavía una capa `services/`, `hooks/`, `queries/`, `repositories/` o equivalente. No se debe añadir una arquitectura paralela sin necesidad: primero hay que definir el contrato de datos que consumirá la UI.

## 3. `App.tsx`: responsabilidades actuales

### Estado local

- `fontSettings`: preferencias de tipografía.
- `panelOpen`: apertura/cierre del panel de apariencia.

### Lógica reutilizable ya presente

- validación de fuentes permitidas;
- sanitización de configuración persistida;
- lectura segura de `localStorage`;
- escritura segura de `localStorage`;
- limpieza de preferencias;
- construcción de variables CSS;
- aplicación de variables a la raíz y `.game`;
- precarga de fuentes mediante `document.fonts`;
- presets tipográficos;
- selector de tipografía por rol.

### UI actual

- topbar;
- logo;
- recursos demo;
- perfil invitado demo;
- navegación lateral visual;
- hero del planeta demo;
- panel de recursos demo;
- lista de planetas demo;
- estado del sistema demo;
- panel de apariencia.

**Importante:** los botones de navegación y las acciones del dashboard siguen siendo presentacionales; no se les ha inventado comportamiento de backend.

## 4. Datos actualmente hardcodeados en la UI

Se han localizado valores demo directamente en `App.tsx`:

- Metal: `100.000`
- Cristal: `86.719`
- Deuterio: `90.518`
- Energía: `0`
- jugador: `DevPlayer`
- coordenadas: `[1:1:1]`, `[1:2:1]`, `[1:2:2]`
- contador visual de colonias: `3`
- estado visual: `ONLINE`

Estos valores no deben convertirse en datos reales mediante una consulta improvisada. El siguiente paso correcto es mapear cada bloque visual con una fuente RPC/tabla concreta del backend y definir su contrato.

## 5. Mapa frontend → backend

| Módulo UI | Estado frontend | Backend existente | Próximo trabajo |
|---|---|---|---|
| Recursos | Demo | `get_current_planet_resources`, `update_planet_resources`, producción/snapshots | Crear lectura real y reloj de actualización |
| Producción | Demo | `calculate_planet_production`, snapshots/economic rates | Mostrar producción por recurso |
| Energía | Demo | `calculate_planet_energy_balance` | Integrar balance real |
| Planetas | Demo | tablas/funciones de planetas y colonias | Resolver jugador y planeta activo |
| Edificios | No UI real | funciones de costes, requisitos, colas y `start_building` | Pantalla + cola + acción segura |
| Investigación | No UI real | funciones de costes, requisitos, colas y `start_research` | Pantalla + cola + acción segura |
| Astillero | No UI real | `process_shipyard_queue`, colas y funciones de construcción | Pantalla + cola |
| Flota | No UI real | `start_fleet`, `calculate_fleet_time`, workers/movimientos | Selector de origen/destino/naves |
| Expediciones | No UI real | cálculo/resolución de expediciones y outcomes | Pantalla de envío + resultados |
| Colonización | No UI real | `start_colonize_fleet` y resolución de llegada | Flujo de colonización |
| Espionaje | No UI real | dispatch/llegada/reportes | Pantalla + informes |
| Combate | No UI real | motor V2 y persistencia de batallas/rondas/disparos | Informes y pruebas E2E |
| Lifeforms | No UI real | lifeforms, edificios, investigaciones, población, efectos | UI completa + validación E2E |
| Optimización | No UI real | candidatos, ROI, ranking, siguiente acción | Centro de control real |
| Galaxia | No UI real | estructuras/funciones de universo existentes | Lectura de galaxia y acciones permitidas |
| Apariencia | **Implementado** | No depende de backend | Mantener; ya validado funcionalmente |

## 6. Orden recomendado de integración

No se recomienda conectar todos los módulos a la vez. El orden de menor riesgo es:

1. **Contexto de sesión/jugador** — determinar si el frontend está en invitado o autenticado y obtener el `player_id` válido según el modelo existente.
2. **Planeta activo** — una única fuente de verdad para el planeta seleccionado.
3. **Recursos + producción + energía** — primera pantalla realmente viva.
4. **Edificios + cola** — primer flujo de escritura controlada.
5. **Investigación + cola**.
6. **Astillero + defensas**.
7. **Flota y movimientos**.
8. **Planetas/colonias + galaxia**.
9. **Espionaje + informes**.
10. **Expediciones + resultados**.
11. **Lifeforms**.
12. **Combate + informes**.
13. **Optimización / centro de control**.

## 7. Contratos que faltan antes de ampliar la UI

### Identidad

Definir una única función/capa frontend para:

- sesión Supabase;
- jugador actual;
- modo invitado;
- planeta activo;
- invalidación cuando cambia la identidad.

### Lecturas

Cada pantalla debería consumir un contrato estable, en vez de consultar tablas arbitrariamente desde componentes.

### Escrituras

Las acciones de juego deben pasar por RPCs existentes y mostrar:

- estado de carga;
- éxito;
- error del RPC;
- bloqueo contra doble envío;
- actualización posterior del estado.

### Tiempo

Los recursos y colas dependen del tiempo del servidor. El frontend no debe asumir que el reloj local del navegador es la autoridad.

## 8. Riesgos detectados

### Alto — backend no consumido por la UI

El cliente Supabase existe, pero el frontend todavía no ejecuta RPCs/queries reales.

### Alto — demasiada responsabilidad en `App.tsx`

Actualmente `App.tsx` concentra shell, dashboard demo y sistema de preferencias. Antes de crecer, conviene separar por dominio, pero sin crear una estructura artificial hasta que existan contratos de datos reales.

### Medio — navegación visual sin router/estado de módulo

Los botones laterales no cambian de vista. No se debe añadir un router solo por añadirlo: primero hay que fijar las pantallas que realmente existirán.

### Medio — estados de carga/error inexistentes

Al introducir Supabase, cada lectura y mutación necesitará estados explícitos para evitar pantallas aparentemente congeladas.

### Medio — doble ejecución de acciones

Las mutaciones de construcción, investigación, astillero y flota deben bloquearse mientras la llamada está pendiente y, además, seguir protegidas en backend contra repetición/concurrencia.

## 9. Corrección aplicada en esta auditoría

Se añadió `type="button"` a los botones existentes de `App.tsx`. Es un cambio deliberadamente pequeño: evita que estos controles se comporten como submits si en el futuro quedan dentro de un formulario, sin cambiar su apariencia ni inventar navegación.

## 10. Próximo objetivo técnico

La siguiente modificación de código debe ser la **primera integración real y pequeña**: identidad/jugador + planeta activo + lectura de recursos, preferiblemente mediante funciones backend ya existentes y sin duplicar reglas de negocio en TypeScript.

No se debe implementar todavía Lifeforms, combate o galaxia en la UI hasta cerrar este contrato base.
