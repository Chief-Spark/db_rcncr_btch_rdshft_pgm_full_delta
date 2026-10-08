# QA unificación — **prioridad: datos reales** (mock solo laboratorio)

**Fecha:** 2026-09-11

## De dónde sale cada data (importante)

| Camino | Origen de la data | ¿Quién la pone? | ¿Cierra el entregable? |
|--------|-------------------|-----------------|------------------------|
| **A — Real** | `edf_views` / IFR / XPM vía Data Sharing (personas reales Experian) | EDF / datos / Geo | **Sí** (gates R2, C03, C04) |
| **B — Mock / sintético** | `INSERT` de scripts en `bdm_stage.perf_persona_meta`, benchmark 20K, `mock_tc_r3` | Nosotros / DBA con el runbook | **No** — solo laboratorio |

El cluster QA es real; lo “mock” es **la suite/datos inventados**, no el ambiente.

**Documento maestro:** [`COMO_SE_HA_HECHO_DATOS_REALES.md`](COMO_SE_HA_HECHO_DATOS_REALES.md)  
**Proceso punta a punta:** [`PROCESO_RECONOCER_END_TO_END.md`](PROCESO_RECONOCER_END_TO_END.md) · [`RECONOCER_TODO_EN_UNO.html`](RECONOCER_TODO_EN_UNO.html)  
**Metodología consolidado:** [`contexto_reconocer/05_PRUEBAS_QA.md`](contexto_reconocer/05_PRUEBAS_QA.md)

---

## Primero: confirmar con Julian (1 pregunta)

> Julian, ¿los TC-R2-14 / R3 los corrieron contra:
> **A)** IFR/XPM real en QA (`ifr_data` / tablas reales), o  
> **B)** benchmark sintético (`perf_persona_meta` / mock 20K / `mock_tc_r3`)?

| Si responde… | Usar sección |
|--------------|--------------|
| **A — datos reales** | §1 (pedir data a negocio) |
| **B — mock / suite TC** | §2 (añadir/ajustar registros + fix) |

En QA **existe** `perf_persona_meta` y TC-R2-14 = 1.200 → eso apunta a que **al menos la suite TC usó el escenario sintético `R2_EMPATE`**.

---

## §1 — Camino A: QA con datos reales (recomendado para sign-off)

### Qué NO aplicar
- Suite `TC-R1-01…TC-R2-14` con `scenario_code` / `perf_persona_meta` → **no aplica** a IFR real.
- Esperar R3 > 0 sin geo → **no aplica** (en DEV edf_views real también R3 = 0).

### Qué SÍ validar (gates reales)

| Gate | Esperado | Query corta |
|------|----------|-------------|
| Unificaciones R2 | > 0 (orden magnitud) | `COUNT(*) WHERE unifica_atributos=2` |
| C03 hijos sin padre | **0** | `cod_dw_direccion_unificada IS NULL` |
| C04 autoreferencia | **0** | hijo = padre |
| Hijas con orden (si aplica ordenamiento) | **0** | `ind_unificacion=1 AND orden_prioridad IS NOT NULL` |
| R1 / R3 | pueden ser **0** si datos no dan casos | No es fallo automático |

Scripts reales (no mock):

- `sql/qa_ifr_data/03_validaciones_unificacion.sql`
- `sql/qa_ifr_data/00_validar_todo_una_query.sql`
- Evidencia DEV: `Evidencias_QA_UNIFICACION_ESCENARIOS_DEV.md` (R2=72.448, C03/C04=0)

### Mensaje para negocio / Experian / datos (copiar)

---

Hola equipo,

Para cerrar **QA de unificación con datos reales** (no mock), necesitamos que el insumo en QA traiga estas características. Sin ellas, algunas reglas salen en 0 y no se pueden certificar:

**1. Regla 3 (geo) — hoy bloqueada**
- Campo: **`latitud` y `longitud`** poblados en ubicación (XPM / capa GEO / ArcGIS).
- Qué necesitamos ver: pares de direcciones de la **misma persona**, misma vía, **número de puerta ±2**, con coordenadas válidas (no NULL, no 0).
- Sin geo, R3 no genera unificaciones (esperado; no es bug del SP).

**2. Regla 2 (complemento) — ya funciona en DEV**
- Campo: **`complemento`** (apto, torre, local, etc.) en dirección física.
- Casos útiles: mismo texto de vía + un complemento vacío vs informado; o uno contenido en el otro.

**3. Regla 1 (tipos RES/LAB/CRR + CIIU)**
- Misma dirección (texto + ciudad) con **más de un tipo** (casa/trabajo/correspondencia).
- **CIIU** / actividad económica poblada cuando aplique.
- Scores de entidades **no empatados al 100%** (si todo empata, R1 queda en 0 por política de empate).

**4. Volumen mínimo en QA**
- Universo de contactos dirección comparable a DEV (orden de cientos de miles) o, como mínimo, un **recorte representativo** con los casos de arriba etiquetados.

**Entregable que pedimos:** confirmar fecha de carga en QA de geo + muestra de casos R1/R2/R3, o aceptar que R3 quede **N/A** hasta GEO.

Gracias.

---

### Checklist corto para negocio

| Característica | Para qué regla | ¿Obligatorio para cerrar QA real? |
|----------------|----------------|-----------------------------------|
| lat/long poblados | R3 | **Sí**, si quieren certificar R3 |
| complemento (apto/torre) | R2 | Deseable (en DEV ya hay casos) |
| multitipo RES/LAB/CRR + CIIU | R1 | Deseable (si no, R1=0 es esperado) |
| Sin empates 100% en score R1 | R1 > 0 | Decisión de negocio / desempate |

---

## §2 — Camino B: Julian usó mock → añadir registros / ajustar para que no falle

**Runbook listo:** [`RUNBOOK_MOCK_QA_CALIDAD.md`](RUNBOOK_MOCK_QA_CALIDAD.md)  
**Scripts:** `sql/qa_redshift/00_RUNBOOK_MOCK_QA_CALIDAD.sql` … `04_revalidar_r2_empate_tras_sp.sql`

### B1. TC-R2-14 (1.200 en `R2_EMPATE`)

**Problema:** el escenario sintético dice “empate → **no** unificar”, pero R2 aún absorbe 1.200 personas.

**Qué hacer (en orden):**

1. **Confirmar SP en QA** = misma versión que repo (`stg_regla2_e04_ganador` con `HAVING COUNT(*)=1`).
2. **Si el SP está al día y aún falla:** el seed `CS 8` / `PI 8` sigue unificando por **otra rama de R2** (Esc1/Esc2/motor), no solo Esc4.
3. **Arreglo de datos mock (rápido para pasar TC):**
   - Recargar benchmark con seed que **no dispare** Esc1/Esc2 (complementos que no sean “vacío vs informado” ni substring).
   - O marcar en diccionario **misma frecuencia** y bloquear ganador único (ya es la intención de Esc4).
4. **Arreglo de lógica (correcto a largo plazo):** ticket en R2 — empate persistente no debe absorber por ninguna sub-rama cuando `scenario`/`conteo` empatan.

**Archivos:**

| Acción | Archivo |
|--------|---------|
| Recargar mock 20K | `sql/benchmark_20k/A_data_load_sintetico.sql` |
| Validar TC-R2-14 | `sql/qa_redshift/04_validacion_tc_r1_r2_bdm_stage.sql` |
| Seed R2_EMPATE | SPEC filas 24–29: `CS 8` / `PI 8` |

**Query gate (debe dar 0):**

```sql
SELECT COUNT(*) AS violaciones
FROM bdm_stage.perf_persona_meta m
WHERE m.scenario_code = 'R2_EMPATE'
  AND EXISTS (
    SELECT 1 FROM bdm_stage.relacion_persona_ubicacion r
    JOIN bdm_stage.unificacion_direccion u
      ON u.cod_dw_persona_ubic = r.cod_dw_persona_ubic AND u.unifica_atributos = 2
    WHERE r.id_buro_persona = m.id_buro_persona
  );
```

### B2. R3 en mock (sin geo)

**Problema:** en stage QA no hay lat/long → TCs R3 fallan / quedan vacíos.

**Qué hacer — añadir registros:**

Ejecutar en QA (sandbox autorizado) **antes** de R3:

```text
sql/qa_redshift/mock_tc_r3_01_08_10.sql
```

Eso inserta personas **930001 / 930008 / 930010** con lat/long y casos:

| ID | Caso | Esperado |
|----|------|----------|
| 930001 | Manzana | NO unifica |
| 930008 | puerta ±2 | SÍ unifica |
| 930010 | empate dicc vía | NO unifica |

Luego validar con `sql/qa_redshift/validar_mock_tc_r3_suite.sql` (o el validador del paquete).

**Si usan mock 20K completo:** el seed ya trae `R3_GEO` / `R3_DICC_VIA` con coordenadas (filas 48–56 de la SPEC). Hay que **recargar `A_data_load_sintetico.sql`** en sandbox QA (borra/recrea `bdm_stage` — pedir permiso DBA).

---

## Resumen ejecutivo (qué hacer tú ahora)

| Decisión | Acción inmediata |
|----------|------------------|
| **Sign-off = datos reales** | Usar gates C03/C04/R2; R3 = N/A hasta geo. Enviar §1 a negocio. |
| **Sign-off = suite mock de Julian** | Cargar `mock_tc_r3_01_08_10.sql` + recalibrar seed/SP de `R2_EMPATE` hasta TC-R2-14 = 0. |
| **No sabemos** | Preguntar a Julian A vs B (arriba). |

---

## Mensaje corto para Julian (copiar)

> Julian, para no mezclar: ¿tu revisión fue con **IFR real** o con **benchmark/mock** (`perf_persona_meta`)?  
> - Si es **real**: R3 sin geo queda N/A; pedimos a negocio lat/long. TC-R2-14 con `R2_EMPATE` no aplica. Gates: C03/C04=0 y R2 poblado.  
> - Si es **mock**: cargamos los registros R3 con geo (`mock_tc_r3`) y ajustamos seed/lógica de `R2_EMPATE` para que TC-R2-14 dé 0.

---

*Paquete: PAQUETE_UNIFICACION_BDM_STAGE*
