# Casos de prueba mock — Unificación, Ordenamiento y Geolocalización (FULL / DELTA)

**Fuente funcional:** Plan Maestro QA, capítulos 5 a 8 (Regla 1, Regla 2, Regla 3 y reglas generales).
**Qué certifica este catálogo:** los stored procedures **mock** desplegados en `_pgm`. El resultado esperado es el del SP mock. Donde ese resultado se aparta del plan maestro, el caso lo dice en **Divergencia**.
**Repos:** `_strct` (vistas y tablas) → `_pgm` (CALL) → `_dt` (query de evidencia). `_strct` y `_dt` no están en este workspace; los objetos se citan tal como los leen o escriben los SP de `_pgm`.

Salida de unificación: `bdm_datos.unificacion_direccion_mock`.
Salida de ordenamiento: `bdm_stage.mock_ord_ca_result` y `bdm_stage.mock_ord_control`.

Un caso no está probado sin query, resultado real y estado `PASS | FAIL | BLOCKED | GAP`.

---

## 1. Reparto por repo

```
strct  vistas v_mock_* y tablas
        │
        ▼
pgm    CALL sp_unificacion_mock_regla{1|2|3}  o  sp_ordenamiento_ejecucion_mock
        │
        ▼
dt     SELECT sobre unificacion_direccion_mock  o  mock_ord_ca_result
```

| Repo | Qué se prueba | Qué no se prueba aquí |
|------|----------------|------------------------|
| `_strct` | Que existan las vistas y tablas que el mock lee y escribe | No hay SP de negocio mock en estructura |
| `_pgm` | La decisión de padre/hija y la persistencia FULL vs DELTA | `sp_unificacion_ciclo` y `sp_ordenamiento_ciclo` (camino real, `v_xpm_*`) |
| `_dt` | La evidencia SQL de cada caso | No ejecuta la regla |

---

## 2. Firmas y reglas de corrida

### 2.1 Unificación

```sql
CALL bdm_datos.sp_unificacion_mock_regla1('FULL',  <lote>, NULL);
CALL bdm_datos.sp_unificacion_mock_regla1('DELTA', <lote>, DATE '2026-01-01');
-- La misma firma vale para sp_unificacion_mock_regla2 y sp_unificacion_mock_regla3.
```

| Modo | Universo que entra | Escritura en `unificacion_direccion_mock` |
|------|--------------------|--------------------------------------------|
| `FULL` | R1 y R2: sin filtro de fecha. El tercer argumento se ignora. | `INSERT` (append). El SP **no** trunca. |
| `DELTA` | R1 y R2: `fecha_relacion_persona_ubicaci >= watermark` **o** fecha `NULL`. | `DELETE` + `INSERT` de la pareja `(cod_dw_persona_ubic, cod_dw_direccion_unificada)`. No borra otras parejas. |

R3 mock **no** usa el watermark. `p_modo` solo cambia append vs upsert. Ver TC-R3-05 y TC-R3-VENTANA.

No existe `sp_unificacion_mock_ciclo`. Antes de cada corrida FULL de unificación:

```sql
TRUNCATE TABLE bdm_datos.unificacion_direccion_mock;
```

Ese `TRUNCATE` borra la tabla completa. Correr primero las suites FULL y después las DELTA, para poder demostrar que el upsert no toca parejas ajenas.

### 2.2 Ordenamiento

```sql
CALL bdm_datos.sp_ordenamiento_ejecucion_mock('', '', '', 'FULL',  '2001', '2026-02-01');
CALL bdm_datos.sp_ordenamiento_ejecucion_mock('', '', '', 'DELTA', '2002', '2026-02-01');
```

El ejecutor ya llama a `sp_ordenamiento_cargar_seed_mock` y a `sp_ordenamiento_validar_mock`. El seed es fijo (personas `20001`–`20014`). El mock guarda el modo en `mock_ord_control`; **no** filtra por watermark. Eso lo hace `sp_ordenamiento_ciclo`, que queda fuera de este catálogo.

Modo distinto de `FULL`/`DELTA`, o lote vacío, lanza excepción y no cierra la corrida en `completado`.

### 2.3 Aislamiento

- Una persona, un escenario. El `CALL` de la regla procesa **toda** la vista `v_mock_*` que pase el filtro de fecha.
- Namespaces: R1 `910xxx`, R2 `920xxx`, R3 `930xxx`. Ordenamiento usa `20001`–`20014` (lo inserta el propio SP).
- RPU: persona `910001` → `910001001`, `910001002`, `910001003`.
- Mismo `texto_ubicacion` y mismo municipio dentro de la persona, salvo el caso de geolocalización, donde cambia el número de puerta.
- R1: complemento `NULL`. R2: mismo `cod_dw_tipo_ubicacion_dir` en las dos direcciones.
- `descripcion_tipo_ubicacion_dir` debe ser exactamente `RES`, `LAB` o `CRR`. El score de R1 compara ese texto.
- CIIU en texto: `'10'`, `'81'`, `'82'`, `'90'`, `'47'`.
- Watermark de todas las corridas DELTA: `DATE '2026-01-01'`.
- Fecha dentro de ventana: `2026-02-01`. Fecha fuera: `2025-01-01`.
- Lotes: R1 FULL `9101`, R1 DELTA `9102`, R2 FULL `9201`, R2 DELTA `9202`, R3 FULL `9301`, R3 DELTA `9302`, ordenamiento FULL `2001`, DELTA `2002`.

### 2.4 Cadena interna de Regla 2

`sp_unificacion_mock_regla2` llama, en esta sesión y en este orden:

1. `sp_unificacion_mock_r2_preparar_insumo`
2. `sp_unificacion_mock_r2_esc1_complemento_vacio_esc2_substring_complemento` — escribe traza y deja `stg_mock_regla2_e2`
3. `sp_unificacion_mock_r2_esc3_sin_nit_misma_nomenclatura`
4. `sp_unificacion_mock_r2_esc4_diccionario_frecuencia_complemento`
5. `sp_unificacion_mock_r2_esc5_nomenclatura_menor_nivel_pierde`
6. `sp_unificacion_mock_r2_esc6_frecuencia_complemento_gana`
7. `sp_unificacion_mock_r2_motor_nit_empates_nuevas_direcciones` — arma `stg_mock_motor_insumo` y **no** inserta en `unificacion_direccion_mock`
8. `DROP` de todo el staging, incluido `stg_mock_motor_insumo`

Los escenarios 3 a 6 y el motor leen tablas que creó el paso anterior. No se puede llamar un escenario suelto. Para TC-R2-04 la evidencia del motor se toma **después del paso 7 y antes del DROP**. El `CALL` del orquestador completo borra esa tabla.

Esc4 y esc6 pueden emitir la misma pareja. En FULL quedan **dos** filas iguales. En DELTA el upsert deja **una**.

---

## 3. `_strct` — precondiciones

Estos casos no llaman un SP de regla. Si fallan, el resto queda `BLOCKED`.

### TC-STRCT-01 — Vistas mock

```sql
SELECT table_name
FROM information_schema.views
WHERE table_schema = 'bdm_tempo'
  AND table_name IN (
    'v_mock_relacion_persona_ubicacion',
    'v_mock_ubicacion_estandarizada',
    'v_mock_direccion_fisica',
    'v_mock_reporte_relacion_persona_ubica',
    'v_mock_ciiu_persona'
  )
ORDER BY 1;
```

Esperado: 5 filas.

### TC-STRCT-02 — Tabla destino de unificación mock

```sql
SELECT column_name
FROM information_schema.columns
WHERE table_schema = 'bdm_datos'
  AND table_name = 'unificacion_direccion_mock'
  AND column_name IN (
    'cod_dw_persona_ubic',
    'cod_dw_direccion_unificada',
    'unifica_atributos',
    'fecha_unificacion',
    'lote',
    'severidad',
    'usuario_bd'
  )
ORDER BY 1;
```

Esperado: 7 columnas.

### TC-STRCT-03 — Catálogos que leen R1 y R2

```sql
SELECT table_name
FROM information_schema.tables
WHERE table_schema = 'bdm_stage'
  AND table_name IN ('tipo_ubicacion_dir', 'nomenclatura', 'diccionario_complementos')
ORDER BY 1;
```

Esperado: 3 filas. `tipo_ubicacion_dir` debe tener descripciones `RES`, `LAB` y `CRR`.

### TC-STRCT-04 — Tablas del ordenamiento mock

```sql
SELECT table_name
FROM information_schema.tables
WHERE table_schema = 'bdm_stage'
  AND table_name IN (
    'mock_ord_escenario',
    'mock_ord_rpu',
    'mock_ord_score',
    'mock_ord_prioridad',
    'mock_ord_ca_result',
    'mock_ord_control',
    'mock_ord_control_etapa'
  )
ORDER BY 1;
```

Esperado: 7 filas.

### TC-STRCT-05 — Beta de ordenamiento (CA-O02)

```sql
SELECT COUNT(*) AS n FROM bdm_datos.beta_ordenamiento;
```

Esperado: `47`. Si el conteo es otro, CA-O02 sale `FAILED` aunque el seed mock esté bien. Estado del caso: `BLOCKED` hasta cargar el catálogo.

### TC-STRCT-06 — Columnas que el filtro DELTA lee

```sql
SELECT column_name
FROM information_schema.columns
WHERE table_schema = 'bdm_tempo'
  AND table_name = 'v_mock_relacion_persona_ubicacion'
  AND column_name IN (
    'fecha_relacion_persona_ubicaci',
    'ind_unificacion',
    'cod_tipo_ident_fte',
    'cod_dw_tipo_ubicacion_dir',
    'id_buro_persona',
    'cod_dw_persona_ubic'
  )
ORDER BY 1;
```

Esperado: las 6 columnas. Sin `fecha_relacion_persona_ubicaci` la corrida DELTA de R1/R2 no compila el filtro.

---

## 4. `_pgm` — Regla 1 (capítulo 5)

Orquestador: `bdm_datos.sp_unificacion_mock_regla1`.
Sello: `unifica_atributos = 1`.

Score:

- CIIU `10`: `100000` si el tipo es `LAB` o `CRR`, más el número de entidades. `RES` no recibe el bono.
- CIIU `81`, `82` o `90`: bono si el tipo es `RES` o `CRR`.
- Otro CIIU: el score es solo el número de entidades.
- Hay traza solo si **un** RPU tiene el score máximo (`HAVING COUNT(*) = 1`). Empate de ese máximo → 0 trazas.
- Toda dirección del mismo texto con otro tipo y `orden > 1` queda hija del ganador.

**Divergencia con el capítulo 5:** el plan deja fuera de la competencia al tipo que no entra al grupo (RES en CIIU 10, LAB en CIIU 81/82/90). El mock sí los carga en el mismo grupo. Si pierden el score, **también quedan hijas**.

Semilla común de cada persona R1: mismo `texto_ubicacion` (por ejemplo `CL 45 12 33`), mismo municipio, complemento `NULL`, `ind_unificacion` `NULL`, tres suscriptores distintos según la columna Entidades.

| Persona | CIIU | RPU | Tipo | Entidades | Fecha |
|---------|------|-----|------|-----------|-------|
| 910001 | 10 | 910001001 | LAB | 2 | 2026-02-01 |
| 910001 | 10 | 910001002 | CRR | 5 | 2026-02-01 |
| 910001 | 10 | 910001003 | RES | 8 | 2026-02-01 |
| 910002 | 81 | 910002001 | RES | 3 | 2026-02-01 |
| 910002 | 81 | 910002002 | CRR | 7 | 2026-02-01 |
| 910002 | 81 | 910002003 | LAB | 10 | 2026-02-01 |
| 910003 | 47 | 910003001 | LAB | 2 | 2026-02-01 |
| 910003 | 47 | 910003002 | RES | 4 | 2026-02-01 |
| 910003 | 47 | 910003003 | CRR | 9 | 2026-02-01 |
| 910008 | 10 | 910008001 | LAB | 5 | 2026-02-01 |
| 910008 | 10 | 910008002 | CRR | 5 | 2026-02-01 |
| 910009 | 10 | 910009001 | LAB | 2 | 2025-01-01 |
| 910009 | 10 | 910009002 | CRR | 5 | 2025-01-01 |
| 910010 | 10 | 910010001 | LAB | 2 | NULL |
| 910010 | 10 | 910010002 | CRR | 5 | NULL |

### TC-R1-01-FULL — CIIU 10, lote 9101

Plan: TC-R1-01. SP: `sp_unificacion_mock_r1_esc1_ciiu10_mismo_texto_padre_lab_crr`.

```sql
TRUNCATE TABLE bdm_datos.unificacion_direccion_mock;
CALL bdm_datos.sp_unificacion_mock_regla1('FULL', 9101, NULL);
```

Esperado para `910001`: padre `910001002` (CRR, score `100005`). Hijas `910001001` (LAB) y `910001003` (RES). Dos filas, `unifica_atributos = 1`, `lote = 9101`.

Divergencia: el plan deja `910001003` vigente. El mock la escribe como hija.

### TC-R1-01-DELTA — CIIU 10 dentro de ventana, lote 9102

Misma persona `910001` (fecha `2026-02-01` >= watermark).

```sql
CALL bdm_datos.sp_unificacion_mock_regla1('DELTA', 9102, DATE '2026-01-01');
```

Esperado: la misma pareja de trazas, **una** fila por clave, `lote = 9102`. Si TC-R1-01-FULL ya insertó esas claves, el upsert las reemplaza y el conteo por clave sigue en 1.

### TC-R1-02-FULL / TC-R1-02-DELTA — CIIU 81

Plan: TC-R1-02. SP: `sp_unificacion_mock_r1_esc2_ciiu81_90_mismo_texto_padre_res_crr`.
Persona `910002`. Mismos CALL que R1-01 (el orquestador evalúa los tres escenarios).

Esperado: padre `910002002` (CRR, score `100007`). Hijas `910002001` (RES, score `100003`) y `910002003` (LAB, score `10`).

Divergencia: el plan deja la LAB vigente. El mock la escribe como hija. CIIU `82` y `90` usan el mismo SP; repetir el patrón de `910002` con otra persona si se quiere evidencia de cada código.

### TC-R1-03-FULL / TC-R1-03-DELTA — Otro CIIU

Plan: TC-R1-03. SP: `sp_unificacion_mock_r1_esc3_otros_ciiu_mayor_entidades_reportan`.
Persona `910003`, CIIU `47`.

Esperado: padre `910003003` (CRR, 9 entidades). Hijas `910003001` y `910003002`. Coincide con el plan (gana quien más entidades reporta).

### TC-R1-08-FULL / TC-R1-08-DELTA — Empate

Plan: TC-R1-08. Persona `910008`. LAB y CRR con 5 entidades: los dos scores máximos son `100005`.

Esperado: **0** filas en `unificacion_direccion_mock` con `cod_dw_persona_ubic IN (910008001, 910008002)`, en FULL y en DELTA.

### TC-R1-DELTA-FUERA — Fecha anterior al watermark

Plan: ventana DELTA (cap. 5, sembrado + modo del SP). Persona `910009`, fecha `2025-01-01`.

- En el CALL FULL del lote `9101`: **sí** hay traza. Padre `910009002`, hija `910009001`.
- En el CALL DELTA del lote `9102`: **0** trazas de `910009`.

### TC-R1-DELTA-NULL — Fecha nula entra en DELTA

Persona `910010`, `fecha_relacion_persona_ubicaci` NULL.

Esperado en el CALL DELTA: padre `910010002`, hija `910010001`, `unifica_atributos = 1`. La fecha nula es inclusiva.

### TC-R1-04 y TC-R1-05 — Marca y trazabilidad

El mock **no** actualiza `ind_unificacion` en la vista. La evidencia de hija es la fila de `unificacion_direccion_mock`.

- TC-R1-04: toda hija listada arriba tiene fila con `unifica_atributos = 1`.
- TC-R1-05: `cod_dw_direccion_unificada` no es nulo y es distinto de `cod_dw_persona_ubic`.

### TC-R1-07 — Baseline por grupo CIIU

Queda cubierto al pasar juntos TC-R1-01 (grupo 10), TC-R1-02 (grupo 81) y TC-R1-03 (grupo 47) en la misma corrida del orquestador.

---

## 5. `_pgm` — Regla 2 (capítulo 6)

Orquestador: `bdm_datos.sp_unificacion_mock_regla2`.
Sello de las trazas que sí persisten: `unifica_atributos = 2`.

Semilla común: mismo texto, mismo municipio, mismo tipo (`RES` = código 1), complemento distinto, CIIU `47` para no mezclar el criterio de R1 si más adelante se corre la cascada a mano. `ind_unificacion` NULL.

| Persona | RPU | Complemento | Tipo ident | Entidades | Fecha | Diccionario |
|---------|-----|-------------|------------|-----------|-------|-------------|
| 920001 | 920001001 | `''` o NULL | distinto de 3 | 1 | 2026-02-01 | no aplica |
| 920001 | 920001002 | `AP 201` | distinto de 3 | 1 | 2026-02-01 | no aplica |
| 920002 | 920002001 | `TO 1` | distinto de 3 | 1 | 2026-02-01 | no aplica |
| 920002 | 920002002 | `TO 1 AP 502` | distinto de 3 | 1 | 2026-02-01 | no aplica |
| 920003 | 920003001 | `AP 201` | distinto de 3 | 3 | 2026-02-01 | sin fila, o frecuencia 0 en ambos |
| 920003 | 920003002 | `AP 202` | distinto de 3 | 5 | 2026-02-01 | igual |
| 920004 | 920004001 | `OF 301` | **3 (NIT)** | 1 | 2026-02-01 | misma frecuencia en los dos |
| 920004 | 920004002 | `OF 302` | **3 (NIT)** | 1 | 2026-02-01 | misma frecuencia |
| 920005 | 920005001 | `AP 401` | distinto de 3 | 1 | 2026-02-01 | frecuencia mayor que LC |
| 920005 | 920005002 | `LC 401` | distinto de 3 | 1 | 2026-02-01 | frecuencia menor |
| 920006 | 920006001 | `ED SAN PABLO` | distinto de 3 | 1 | 2026-02-01 | niveles distintos en `nomenclatura` |
| 920006 | 920006002 | `AP 101` | distinto de 3 | 1 | 2026-02-01 | el otro nivel |
| 920014 | 920014001 | `CS 8` | distinto de 3 | 1 | 2026-02-01 | **misma** frecuencia |
| 920014 | 920014002 | `PI 8` | distinto de 3 | 1 | 2026-02-01 | **misma** frecuencia |
| 920015 | 920015001 | `''` | distinto de 3 | 1 | 2025-01-01 | no aplica |
| 920015 | 920015002 | `AP 201` | distinto de 3 | 1 | 2025-01-01 | no aplica |

`nomenclatura` debe hacer match con espacio: el complemento empieza por el código y un espacio (`AP 201`, no `AP201`). Esc5 compara `nivel_complemento`: gana el número **menor**. Para `920006`, dejar `ED` con nivel menor que `AP`.

Los complementos de `920003`, `920005`, `920006` y `920014` no deben ser vacío ni estar contenidos uno en el otro. Si lo están, esc1/esc2 los absorbe antes y el escenario queda `BLOCKED`.

```sql
TRUNCATE TABLE bdm_datos.unificacion_direccion_mock;
CALL bdm_datos.sp_unificacion_mock_regla2('FULL', 9201, NULL);
CALL bdm_datos.sp_unificacion_mock_regla2('DELTA', 9202, DATE '2026-01-01');
```

La segunda llamada es la corrida DELTA. Los esperados FULL se leen en el lote `9201` **antes** de lanzar DELTA. Los esperados DELTA se leen en el lote `9202`.

### TC-R2-01-FULL / TC-R2-01-DELTA — Vacío vs informado

Plan: TC-R2-01. SP: `sp_unificacion_mock_r2_esc1_complemento_vacio_esc2_substring_complemento`.
Persona `920001`.

Esperado: hija `920001001`, padre `920001002`, `unifica_atributos = 2`. Una fila por clave en DELTA. En FULL, una fila (esc2 no vuelve a tomar el par: el vacío ya quedó marcado en `stg_mock_regla2_e2`).

### TC-R2-02-FULL / TC-R2-02-DELTA — Complemento contenido

Plan: TC-R2-02. Mismo SP, rama substring. Persona `920002`.

`TO 1 AP 502` contiene `TO 1`. Esperado: hija `920002001`, padre `920002002`.

### TC-R2-03-FULL / TC-R2-03-DELTA — Misma nomenclatura, sin NIT

Plan: TC-R2-03. SP: `sp_unificacion_mock_r2_esc3_sin_nit_misma_nomenclatura`.
Persona `920003`. Exige filas en `bdm_stage.nomenclatura` cuyo código sea prefijo de `AP 201` y de `AP 202` (el mismo código `AP`).

El ganador es el de mayor `fecha (YYYYMMDD) + entidades + 10000000`. Misma fecha y 5 entidades contra 3: padre `920003002`, hija `920003001`.

Esperado en `unificacion_direccion_mock`: esa pareja y **ninguna** RPU nueva. El motor puede armar staging si las frecuencias empatan en 0; el orquestador lo borra y no lo inserta en la tabla destino. Por eso “sin dirección generada” se afirma sobre `unificacion_direccion_mock`, no sobre el staging.

Con diccionario en frecuencia 0 para los dos, esc4 no tiene ganador único y esc6 no escribe (`freq` iguales). La pareja queda una vez (solo esc3).

### TC-R2-04 / TC-R2-08 / TC-R2-09 — NIT, dirección combinada

Plan: TC-R2-04, TC-R2-08, TC-R2-09. SP: `sp_unificacion_mock_r2_motor_nit_empates_nuevas_direcciones`.
Persona `920004`, `cod_tipo_ident_fte = 3`. Frecuencias de diccionario iguales, para que esc4 y esc6 no se queden la pareja.

**No usar solo el orquestador** si se quiere ver el motor: el paso 8 hace `DROP` de `stg_mock_motor_insumo`. Secuencia, en una sola sesión, hasta el motor:

```sql
CALL bdm_datos.sp_unificacion_mock_r2_preparar_insumo('FULL', NULL);
CALL bdm_datos.sp_unificacion_mock_r2_esc1_complemento_vacio_esc2_substring_complemento('FULL', 9201);
CALL bdm_datos.sp_unificacion_mock_r2_esc3_sin_nit_misma_nomenclatura('FULL', 9201);
CALL bdm_datos.sp_unificacion_mock_r2_esc4_diccionario_frecuencia_complemento('FULL', 9201);
CALL bdm_datos.sp_unificacion_mock_r2_esc5_nomenclatura_menor_nivel_pierde('FULL', 9201);
CALL bdm_datos.sp_unificacion_mock_r2_esc6_frecuencia_complemento_gana('FULL', 9201);
CALL bdm_datos.sp_unificacion_mock_r2_motor_nit_empates_nuevas_direcciones('FULL', 9201);

SELECT complemento_motor, generada_enriquecida, cod_dw_persona_ubic
FROM bdm_tempo.stg_mock_motor_insumo
WHERE id_buro_persona = 920004;
```

Esperado del mock:

- 1 fila en `stg_mock_motor_insumo`.
- `generada_enriquecida = 1` (esto cubre TC-R2-08 a nivel staging).
- `complemento_motor = 'OF 301 OF 302'` si `920004001 < 920004002`. El orden es el de `cod_dw_persona_ubic`. Une con espacio, sin guion.
- `cod_dw_persona_ubic` de la generada es `FNV_HASH(...)`, no un consecutivo.
- 0 filas en `unificacion_direccion_mock` para `920004001` y `920004002`.

Repetir la secuencia con `'DELTA', DATE '2026-01-01'` y lote `9202`. La persona está en ventana; el staging esperado es el mismo. El motor no hace upsert sobre la tabla destino.

Divergencia con el capítulo 6.4: el plan espera padre `OF 301 - OF 302` en una RPU nueva y las dos originales como hijas en `unificacion_direccion`. El mock no inserta esa traza ni usa el guion. TC-R2-09 (0 generadas huérfanas en la tabla destino) sale 0 filas porque la generada **no se persiste**. Marcar TC-R2-09 como `GAP` de persistencia, con evidencia del staging en TC-R2-04.

### TC-R2-05-FULL / TC-R2-13 — Diccionario, gana la frecuencia

Plan: TC-R2-05 y TC-R2-13. SP: `sp_unificacion_mock_r2_esc4_diccionario_frecuencia_complemento` y también `sp_unificacion_mock_r2_esc6_frecuencia_complemento_gana`.
Persona `920005`. Misma puerta, nomenclaturas distintas, `nivel_complemento` **igual** (si difiere, esc5 también escribe). Frecuencia de `AP 401` mayor que la de `LC 401`, join por `cod_dw_ubic`, `id_buro_persona` y complemento que contiene la nomenclatura del diccionario.

Esperado:

- Padre `920005001`, hija `920005002`, `unifica_atributos = 2`.
- FULL, orquestador completo: **2** filas de esa misma clave (esc4 y esc6).
- DELTA: **1** fila, `lote = 9202`.

TC-R2-13 es el mismo par: el padre es el de mayor `SUM(frecuencia)`.

### TC-R2-14-FULL / TC-R2-14-DELTA — Empate de diccionario

Plan: TC-R2-14. Persona `920014`, `CS 8` y `PI 8`, misma frecuencia. No son vacío ni substring.

Esperado: **0** filas en `unificacion_direccion_mock` para `920014001` y `920014002`. Esc4 exige un solo RPU en el conteo máximo. Esc6 exige frecuencia estrictamente mayor.

El motor, con frecuencias iguales, arma staging y el orquestador lo borra. No cuenta como traza.

### TC-R2-06-FULL / TC-R2-06-DELTA — Nivel distinto

Plan: TC-R2-06. SP: `sp_unificacion_mock_r2_esc5_nomenclatura_menor_nivel_pierde`.
Persona `920006`. Nomenclaturas distintas y `nivel_complemento` de `ED` menor que el de `AP`.

Esperado en `unificacion_direccion_mock`: hija el RPU de mayor nivel, padre el RPU de menor nivel, `unifica_atributos = 2`.

Divergencia: el plan pide dirección **combinada**. El mock esc5 elige un padre entre las existentes. El motor, además, arma `stg_mock_motor_insumo` porque los niveles difieren. Esa fila se observa solo si se consulta el staging antes del DROP, igual que TC-R2-04.

### TC-R2-07-FULL / TC-R2-07-DELTA — Frecuencia en el caso que no resolvió el nivel

Plan: TC-R2-07. SP: `sp_unificacion_mock_r2_esc6_frecuencia_complemento_gana`.
Queda cubierto con `920005` junto a TC-R2-05: si las frecuencias difieren y esc1/esc2 no absorbieron, esc6 escribe hija → RPU de mayor frecuencia.

No hace falta otra persona si `920005` tiene niveles iguales. Si se quiere el escenario aislado de esc6, usar otra persona `920007` con complementos que no disparen esc1, esc2, esc3 ni esc5, y frecuencias distintas.

### TC-R2-DELTA-FUERA — Fecha anterior al watermark

Persona `920015`, mismo patrón que `920001`, fecha `2025-01-01`.

- FULL lote `9201`: hija `920015001`, padre `920015002`.
- DELTA lote `9202`: **0** trazas de `920015`.

### TC-R2-10, TC-R2-11, TC-R2-12 — Integridad de lo que sí se persistió

Sobre el lote acabado de correr y `unifica_atributos = 2`:

- TC-R2-10: ningún `cod_dw_direccion_unificada` aparece también como `cod_dw_persona_ubic` en el mismo lote. Esperado: 0 filas. El motor no participa de esta tabla.
- TC-R2-11: por cada hija, un solo padre **distinto** después de DELTA (el upsert colapsa la clave). En FULL, `920005` puede tener 2 filas de la misma clave; no es un segundo padre. El assert de “un padre” agrupa por hija y cuenta padres distintos. Esperado: 1.
- TC-R2-12: `complemento_motor` del staging no trae doble espacio. En la tabla destino el mock no reescribe el complemento. Assert de formato solo sobre `stg_mock_motor_insumo.complemento_motor` de `920004`: sin `'  '` y sin guion doble.

---

## 6. `_pgm` — Regla 3 / geolocalización (capítulo 7)

Orquestador: `bdm_datos.sp_unificacion_mock_regla3`.
Único escenario: `sp_unificacion_mock_r3_esc1_geo_misma_via_puerta_cercana`.
Sello: `unifica_atributos = 3`.

Unifica solo si se cumple todo esto:

- `ind_unificacion` de la vista es `NULL`.
- Misma persona y mismo municipio.
- Las dos tienen `latitud` no nula. No mira la distancia ni la longitud para decidir.
- Los dos primeros tokens de `texto_ubicacion` (separados por espacio) coinciden.
- La diferencia absoluta del token 3 **o** del token 4 está entre 1 y 2, y esos tokens son enteros.
- El padre es el que tiene **más** entidades.

El texto hay que sembrarlo con espacios y números enteros: `CL 10 5 10`. Un guion (`5-10`) rompe el `CAST` a entero.

`p_watermark` llega al orquestador y **no** se pasa al escenario. FULL y DELTA ven el mismo universo. Cambia la escritura: append vs upsert.

| Persona | RPU | texto_ubicacion | Entidades | latitud | Fecha |
|---------|-----|-----------------|-----------|---------|-------|
| 930005 | 930005001 | `CL 10 5 10` | 5 | no nula | 2026-02-01 |
| 930005 | 930005002 | `CL 10 5 12` | 2 | no nula | 2026-02-01 |
| 930006 | 930006001 | `CL 10 5 10` | 5 | no nula | 2026-02-01 |
| 930006 | 930006002 | `CL 10 5 15` | 2 | no nula | 2026-02-01 |
| 930002 | 930002001 | `CL 10 5 10` | 5 | no nula | 2026-02-01 |
| 930002 | 930002002 | `CL 10 5 12` | 2 | **NULL** | 2026-02-01 |
| 930011 | 930011001 | `CL 10 5 10` | 5 | no nula | 2025-01-01 |
| 930011 | 930011002 | `CL 10 5 12` | 2 | no nula | 2025-01-01 |

```sql
TRUNCATE TABLE bdm_datos.unificacion_direccion_mock;
CALL bdm_datos.sp_unificacion_mock_regla3('FULL', 9301, NULL);
```

### TC-R3-05-FULL — Umbral de puerta 2

Plan: TC-R3-05. Persona `930005`. Token 4: `|10 - 12| = 2`.

Esperado: hija `930005002`, padre `930005001`, `unifica_atributos = 3`, `lote = 9301`. Una fila.

### TC-R3-05-DELTA — Misma pareja, upsert

```sql
CALL bdm_datos.sp_unificacion_mock_regla3('DELTA', 9302, DATE '2026-01-01');
```

Esperado: una fila de la clave `(930005002, 930005001)`, `lote = 9302`. La fila del lote `9301` de esa misma clave ya no está (el DELETE la quitó). Otras claves que este CALL no recalcula siguen igual.

### TC-R3-06-FULL / TC-R3-06-DELTA — Puerta a más de 2

Plan: TC-R3-06. Persona `930006`. `|10 - 15| = 5`. Token 3 no difiere.

Esperado: **0** filas para `930006001` y `930006002`, en los dos modos.

### TC-R3-02-MOCK — Una sola latitud

Plan: TC-R3-02 pedía padre = la dirección que tiene GPS. Persona `930002`, la segunda latitud es NULL.

Esperado del mock: **0** trazas. El SP exige latitud en las dos.

Divergencia: no se certifica “la que tiene GPS gana”. El caso negativo del mock es 0 filas. El comportamiento del plan queda en la matriz de huecos.

### TC-R3-VENTANA — DELTA no recorta por fecha

Persona `930011`, puerta a 2, las dos con latitud, fecha `2025-01-01`.

Esperado en FULL **y** en DELTA: hija `930011002`, padre `930011001`. La fecha vieja no excluye.

Divergencia con la ventana de R1/R2: R3 mock no implementa el filtro `>= watermark`.

---

## 7. `_pgm` — Ordenamiento y reglas generales (capítulo 8)

### TC-ORD-FULL — Seed y CA-O01 … CA-O12

```sql
CALL bdm_datos.sp_ordenamiento_ejecucion_mock('', '', '', 'FULL', '2001', '2026-02-01');
```

Esperado en `bdm_stage.mock_ord_control` para lote `2001`: `modo = 'FULL'`, `estado = 'completado'`, `bootstrap = FALSE`.

Esperado en `bdm_stage.mock_ord_ca_result`: 12 filas, todas `PASSED`.

| Criterio | Persona / RPU | Qué afirma | Capítulo |
|----------|---------------|------------|----------|
| CA-O01 | canales del seed | Al menos 3 canales distintos en `mock_ord_score` | scoring |
| CA-O02 | `bdm_datos.beta_ordenamiento` | 47 filas | catálogo |
| CA-O03 | hija `91019` | 0 filas de prioridad si `ind_unificacion = 1` | G-09 |
| CA-O04 | `20001` DIR | lugar 1 tiene el score máximo; 2 direcciones | G-10 |
| CA-O05 | RPU `91019` | 0 scores | G-09 |
| CA-O06 | `20001` | DIR, TEL y EMA tienen su propio lugar 1 | canales |
| CA-O07 | `20001` DIR | `orden_prioridad = lugar` | G-10 |
| CA-O08 | `20010` DIR | 2 filas, mismo score | empate |
| CA-O09 | `20013` TEL | 2 filas, mismo score | empate TEL |
| CA-O10 | `20014` EMA | 2 filas, mismo score | empate EMA |
| CA-O11 | `20012` CEL | una fila, score `220.0000` | default |
| CA-O12 | `20003` DIR | 3 lugares, mínimo 1 y máximo 3 | ranking |

El seed lo vuelve a truncar e insertar el propio SP. No hace falta sembrarlo a mano.

### TC-ORD-DELTA — Mismo seed, otro lote

```sql
CALL bdm_datos.sp_ordenamiento_ejecucion_mock('', '', '', 'DELTA', '2002', '2026-02-01');
```

Esperado: otra fila de control con `modo = 'DELTA'`, `estado = 'completado'`, lote `2002`. Los 12 criterios siguen en `PASSED`. El seed no cambia por el modo: no hay recorte por watermark.

La corrida FULL lote `2001` sigue en `mock_ord_control`. DELTA no la borra.

### TC-ORD-G09 / TC-ORD-G10 — Hijas no ordenan, vigentes sí

Plan: G-09 y G-10. Datos que inserta `sp_ordenamiento_cargar_seed_mock`:

- Persona `20011`, RPU `91018` padre (`ind_unificacion` NULL), con score DIR y `orden_prioridad = 1`.
- RPU `91019` hija (`ind_unificacion = 1`), sin fila en `mock_ord_score` ni en `mock_ord_prioridad`.
- Persona `20001`, RPU `91001` y `91002` vigentes, lugares 1 y 2.

CA-O03 y CA-O05 en `PASSED` cierran G-09. CA-O04 y CA-O07 en `PASSED` cierran G-10 para el canal DIR del mock.

### TC-G06-FULL — Segunda corrida FULL duplica

Plan: G-06, sobre el mock de unificación (no sobre el ciclo real).

Después de un FULL de R1 con lote `9101` y la traza `(910001001, 910001002)` ya insertada, **sin** `TRUNCATE`:

```sql
CALL bdm_datos.sp_unificacion_mock_regla1('FULL', 9101, NULL);
```

Esperado: **2** filas de esa clave. El SP de escenario hace append. El `TRUNCATE` único vive en el ciclo real, que este mock no llama.

### TC-G06-DELTA — Segunda corrida DELTA no duplica la clave

Con la pareja ya escrita:

```sql
CALL bdm_datos.sp_unificacion_mock_regla1('DELTA', 9102, DATE '2026-01-01');
```

Esperado: **1** fila de `(910001001, 910001002)`, `lote = 9102`. Parejas de otras personas que este DELTA no recalcula permanecen.

### TC-ORD-MODO-INVALIDO

```sql
CALL bdm_datos.sp_ordenamiento_ejecucion_mock('', '', '', 'PARCIAL', '2003', '2026-02-01');
```

Esperado: excepción `ORD MOCK: modo invalido`. No queda corrida `completado` para el lote `2003`.

### TC-ORD-LOTE-VACIO

```sql
CALL bdm_datos.sp_ordenamiento_ejecucion_mock('', '', '', 'FULL', '', '2026-02-01');
```

Esperado: excepción `ORD MOCK: lote obligatorio`. Sin fila `completado` nueva.

### TC-G07 — Intra-persona

En todas las trazas de los lotes `9101`, `9102`, `9201`, `9202`, `9301` y `9302`, el padre y la hija pertenecen a la misma `id_buro_persona` al cruzar con `v_mock_relacion_persona_ubicacion`. Esperado del assert de la sección 9: 0 filas cruzadas.

### TC-G08 — Sin DELETE de direcciones

Los SP mock de unificación solo insertan o hacen delete de **parejas ya unificadas** en `unificacion_direccion_mock`. No borran filas de `v_mock_relacion_persona_ubicacion` ni de `v_mock_direccion_fisica`. Conteos de RPU del namespace antes y después del CALL: iguales.

---

## 8. Huecos — no marcar PASS

| Id del plan | Por qué no lo cierra este mock | Estado |
|-------------|-------------------------------|--------|
| TC-R1-06 / G-04 bloqueo | `sp_unificacion_mock_r1_preparar_insumo` no lee `ind_bloqueo` | GAP |
| TC-R1-04 marca `ind_unificacion = 1` | El mock no actualiza la vista; solo escribe la traza | GAP de marca. La traza sí se afirma en TC-R1-05 |
| TC-R3-01 Manzana / Rural | R3 mock no lee tipo de vía | GAP |
| TC-R3-02 padre = quien tiene GPS | Con una latitud nula el mock escribe 0. No elige padre | GAP. El negativo está en TC-R3-02-MOCK |
| TC-R3-03 sin GPS, gana la fecha | El escenario exige latitud en las dos | GAP |
| TC-R3-04 / TC-R3-10 diccionario de vía | No lee `diccionario_via` | GAP |
| TC-R3-07 BIS, B, C, F | No excluye modificadores | GAP |
| TC-R3-08 cuadrantes | No normaliza N/S/E/O. Un token no entero rompe el `CAST` | GAP |
| TC-R3-09 umbral solo con GPS | No hay rama “sin coordenadas” | GAP |
| TC-R2-04 padre combinado en tabla destino | El motor llena staging y no inserta la traza. El orquestador borra el staging | GAP de persistencia. El staging se ve en la secuencia del caso |
| TC-R2-06 combinada | Esc5 elige un padre existente | GAP parcial. La traza de nivel sí se afirma |
| TC-R2-09 generada con RPU en destino | No hay fila destino que pueda quedar huérfana | GAP |
| G-01 / G-02 / G-03 cascada | No hay orquestador mock R1→R2→R3. R3 no lee `unificacion_direccion_mock` | GAP |
| G-06 del ciclo real | El mock de escenario duplica en un segundo FULL. El caso TC-G06-FULL documenta ese comportamiento, no la idempotencia del ciclo | Cubierto como comportamiento mock, no como ciclo |
| Carga GEO S3 | `sp_geo_exportar_insumo`, `sp_geo_ciclo_lote`, COPY de georreferencia y distancias no son mock | Fuera de catálogo |
| `sp_ordenamiento_ciclo` | Watermark, bootstrap y scoring EDF son el camino real | Fuera de catálogo |

---

## 9. `_dt` — Queries de evidencia

Sustituyen las plantillas del capítulo 11 del plan maestro. Filtrar por el lote de la corrida. Pegar el resultado junto al caso y cerrar con PASS, FAIL, BLOCKED o GAP.

### 9.1 Trazas de una persona

```sql
SELECT u.cod_dw_persona_ubic       AS id_hijo,
       u.cod_dw_direccion_unificada AS id_padre,
       u.unifica_atributos,
       u.lote,
       COUNT(*)                     AS filas
FROM bdm_datos.unificacion_direccion_mock u
WHERE u.lote = :lote
  AND u.unifica_atributos = :attr          -- 1 R1, 2 R2, 3 R3
  AND u.cod_dw_persona_ubic IN (:rpus)
GROUP BY 1, 2, 3, 4
ORDER BY 1;
```

### 9.2 Persona fuera de ventana (DELTA)

```sql
SELECT COUNT(*) AS trazas
FROM bdm_datos.unificacion_direccion_mock u
JOIN bdm_tempo.v_mock_relacion_persona_ubicacion r
  ON r.cod_dw_persona_ubic = u.cod_dw_persona_ubic
WHERE u.lote = :lote_delta
  AND r.id_buro_persona = :persona;        -- 910009, 920015
-- R1/R2 esperado: 0. R3 persona 930011 esperado: > 0 (no aplica watermark).
```

### 9.3 Un padre distinto por hija, después de DELTA

```sql
SELECT cod_dw_persona_ubic,
       COUNT(DISTINCT cod_dw_direccion_unificada) AS padres,
       COUNT(*)                                   AS filas
FROM bdm_datos.unificacion_direccion_mock
WHERE lote = :lote_delta
  AND unifica_atributos = :attr
GROUP BY 1
HAVING COUNT(DISTINCT cod_dw_direccion_unificada) <> 1
    OR COUNT(*) <> 1;
-- Esperado: 0 filas.
```

### 9.4 Padre que también es hijo en la misma regla y lote

```sql
SELECT u.cod_dw_direccion_unificada AS padre_que_tambien_es_hijo
FROM bdm_datos.unificacion_direccion_mock u
WHERE u.lote = :lote
  AND u.unifica_atributos = :attr
  AND u.cod_dw_direccion_unificada IN (
    SELECT cod_dw_persona_ubic
    FROM bdm_datos.unificacion_direccion_mock
    WHERE lote = :lote
      AND unifica_atributos = :attr
  );
-- Esperado: 0 filas.
```

### 9.5 Intra-persona (G-07)

```sql
SELECT u.cod_dw_persona_ubic, u.cod_dw_direccion_unificada
FROM bdm_datos.unificacion_direccion_mock u
JOIN bdm_tempo.v_mock_relacion_persona_ubicacion h
  ON h.cod_dw_persona_ubic = u.cod_dw_persona_ubic
JOIN bdm_tempo.v_mock_relacion_persona_ubicacion p
  ON p.cod_dw_persona_ubic = u.cod_dw_direccion_unificada
WHERE u.lote = :lote
  AND h.id_buro_persona <> p.id_buro_persona;
-- Esperado: 0 filas.
```

### 9.6 Motor R2, antes del DROP

```sql
SELECT id_buro_persona,
       complemento_motor,
       generada_enriquecida,
       cod_dw_persona_ubic
FROM bdm_tempo.stg_mock_motor_insumo
WHERE id_buro_persona = 920004;
-- Esperado: 1 fila, generada_enriquecida = 1,
-- complemento_motor = 'OF 301 OF 302' (orden por RPU ascendente).
```

### 9.7 Ordenamiento

```sql
SELECT lote, modo, estado, bootstrap, watermark_nuevo
FROM bdm_stage.mock_ord_control
WHERE lote IN (2001, 2002)
ORDER BY corrida_id;

SELECT criterio_ca, estado, detalle
FROM bdm_stage.mock_ord_ca_result
ORDER BY criterio_ca;
-- Esperado: CA-O01 … CA-O12, estado PASSED.
-- Si CA-O02 falla, revisar TC-STRCT-05 antes de culpar al seed.
```

### 9.8 Idempotencia de la clave

```sql
SELECT cod_dw_persona_ubic,
       cod_dw_direccion_unificada,
       COUNT(*) AS filas
FROM bdm_datos.unificacion_direccion_mock
WHERE cod_dw_persona_ubic = 910001001
  AND cod_dw_direccion_unificada = 910001002
GROUP BY 1, 2;
-- Tras el segundo FULL sin TRUNCATE: filas = 2.
-- Tras el DELTA de esa misma clave: filas = 1 y lote = 9102.
```

---

## 10. Orden de ejecución

1. TC-STRCT-01 … TC-STRCT-06. Si alguno falla, detener.
2. Sembrar namespaces `910xxx`, `920xxx` y `930xxx` en las tablas que alimentan `v_mock_*`, más `nomenclatura` y `diccionario_complementos` de las personas R2.
3. `TRUNCATE` de `unificacion_direccion_mock`.
4. `CALL sp_unificacion_mock_regla1('FULL', 9101, NULL)` y asserts R1 FULL, incluida `910009`.
5. Segundo CALL FULL sin truncate: TC-G06-FULL.
6. `CALL sp_unificacion_mock_regla1('DELTA', 9102, DATE '2026-01-01')` y asserts R1 DELTA, `910009` en 0, `910010` con traza, clave de `910001` en una fila.
7. `TRUNCATE`. Semilla R2. `CALL sp_unificacion_mock_regla2('FULL', 9201, NULL)`.
8. Para `920004` y el staging de `920006`, repetir la secuencia de la sección 5 **sin** el DROP y correr la query 9.6. Después sí se puede llamar al orquestador, sabiendo que borra el staging.
9. `CALL sp_unificacion_mock_regla2('DELTA', 9202, DATE '2026-01-01')`. `920015` en 0. Clave de `920005` en una fila.
10. `TRUNCATE`. Semilla R3. FULL lote `9301`, luego DELTA lote `9302`. Incluir `930011` en los dos modos.
11. Ordenamiento FULL lote `2001` y DELTA lote `2002`. Leer `mock_ord_ca_result`.
12. TC-ORD-MODO-INVALIDO y TC-ORD-LOTE-VACIO.
13. Cerrar la matriz de la sección 8 en `GAP` o “fuera de catálogo”. No convertir esos id en PASS por ausencia de filas.
