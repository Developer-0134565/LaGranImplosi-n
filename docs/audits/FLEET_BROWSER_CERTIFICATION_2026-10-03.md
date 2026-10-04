# FLEET BROWSER E2E CERTIFICATION — 2026-10-03

> **Resultado: `FLEET BROWSER CERTIFICATION — CLOSED`.**
> Ejecución **real** en la cuenta DEV: login UI sin bypass, dispatch real, worker real, llegada real.
> **No se modificó código de producto.** Cleanup completo, **residue 0**.

## 1. Alcance EXACTO (leer antes de citar este documento)

```text
CERTIFICADO
  1 misión ATTACK real, objetivo SIN combate, pipeline completo en tiempo real
  dispatch · movement · worker · arrival · resolution · return · accounting
  ownership · cleanup · residue = 0

NO CERTIFICADO
  todos los tipos de misión de flota          (una sola misión)
  misiones con combate real                  (el objetivo estaba vacío)
  navegador de economy / missile / moon      (fuera del alcance de esta misión)
```

> **No afirmar «todos los tipos de misión están browser-certified».** Eso no se probó.

## 2. Resultado del arnés — 9/9 PASS

```text
PASS 1  Login real DEV (UI, sin bypass)   c***@outlook.com · sesión establecida
PASS 2  Abrir vista Fleet                 encabezado="Flotas"
PASS 3  Origen                            2 opciones · Homeworld [1:1:1]
PASS 4  Misión                            11 misiones · ATTACK
PASS 5  Naves                             Large Cargo max=11 · valor=1
PASS 6  Destino                           DOM verificado 1/1/4
PASS 7  Botón LANZAR y su gate            "LANZAR ATAQUE" disabled=false
PASS 8  Selección inválida                ERROR: "Selecciona al menos una nave."
PASS 9  DISPATCH real desde la UI         cabecera "DESPACHANDO…"
```
`RESUMEN: 9/9 comprobaciones ejecutadas OK (0 omitidas)` · exit 0 · errores de consola/red: ninguno.

El paso 8 es un negativo **real**: el rechazo lo dio el **servidor**, no un botón deshabilitado.

## 3. E2E — tiempo real, sin manipulaciones

```text
dispatch     movement 0f884da4 ATTACK/OUTBOUND
             owner=DEV (players.user_id), Homeworld → AI World G1:S1:P4
             composition large_cargo x1 · fuel_consumed 2 · travel 2.20 min
worker       NO lo procesó mientras no vencía  → la puerta temporal funciona
arrival      21:46:15 · worker pasó OUTBOUND → RETURNING 11 s después
resolution   combat_battles 4864480b ligado a la flota · atacante 1 → 1 (sobrevivió)
             botín capturado: 117 metal / 121 cristal
return       returns_at 21:48:27 → COMPLETED 21:48:39 · large_cargo volvió (11)
ownership    atacante=DEV · defensor=IA · ambos recibieron informes
```

**No se tocó ningún timestamp ni se llamó a ninguna función interna para forzar la llegada.**
El worker lo hizo solo, con su `pg_cron` de 1 segundo.

Informes generados (6, ambos lados): Fleet returning · Fleet arrived · Battle report (DEV) ·
Battle report + Attack received (IA) · Fleet returned.

## 4. Baseline → Final (residue)

```text
fleet_movements 7→7      open 0→0        ships 7→7 / unidades 87→87
messages 32→32           buildings 5→5  resources 821→821     battles 2→2
large_cargo 11→11        metal 223566.3333→223566.3333
crystal 94907.6667→94907.6667            deuterium 88969→88969
```

Cleanup: movimiento + `fleet_movement_ships` + batalla y sus 6 tablas hijas + los 6 informes +
reversión exacta del botín (−117 metal, −121 cristal) y del combustible (+2 deuterio).
**Todos los contadores coinciden con el baseline. Residue = 0.**

## 5. El blocker que resultó falso (y su lección)

Las misiones previas marcaron esto `ENVIRONMENT BLOCKED` por «falta de driver / credencial DEV».
Medido de verdad:

```text
Edge        DISPONIBLE  (C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe)
credenciales EXISTENTES en credentials.txt  → DEV_EMAIL / DEV_PASSWORD en tiempo de ejecución
```

El bloqueo real era más estrecho: **las variables de entorno no estaban definidas**. El script ya
salía con `exit 2` por diseño cuando faltan, lo que hacía el "blocked" autoreportado.

Dos cambios de higiene derivados (no de producto):

```text
.gitignore                     credentials.txt / *.credentials / secrets.txt  (era un secreto
                               sin ignorar, a un `git add .` de subirse a GitHub)
scripts/fleet-browser-certify  CERTIFY_MAX_STEP: correr sólo la parte diagnóstica sin mutar.
                               SKIP ≠ PASS: los omitidos se cuentan aparte y la corrida parcial
                               devuelve exit 3, para que un recorrido parcial NUNCA se lea como
                               certificación completa.
```

## 6. Verificación estática

```text
npx tsc -b          exit 0
npm run build       exit 0
npm run lint        0 errors (7 warnings preexistentes)
git diff --check    limpio
código de producto  SIN CAMBIOS (src/ y supabase/ intactos en esta misión)
```