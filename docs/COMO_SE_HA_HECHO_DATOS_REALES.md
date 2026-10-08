# Cómo se ha venido haciendo — Unificación + Ordenamiento (datos reales)

**Fecha:** 2026-09-11  
**Prioridad:** **datos reales** (`edf_views` / IFR) — el mock solo es anexo de laboratorio.  
**Ambiente sign-off:** Reconocer DEV consumidor · `dba_rncr_batch`

**Proceso punta a punta (claro):** [`RECONOCER_TODO_EN_UNO.html`](RECONOCER_TODO_EN_UNO.html) (E2E + Unificación + Ordenamiento en un solo archivo) · [`PROCESO_RECONOCER_END_TO_END.md`](PROCESO_RECONOCER_END_TO_END.md)  
**Contexto consolidado (proyecto / RF / FW / Geo / QA):** carpeta [`contexto_reconocer/`](contexto_reconocer/)

---

## 0. Dónde encaja en Reconocer Master Cloud

```
EDF (estandariza) → edf_views Data Share → [Geo] → Unificación → Ordenamiento → DB2
```

| Pieza | Rol |
|-------|-----|
| Productor AWS `651706752126` | Publica `edf_views` · Framework Batch |
| Consumidor AWS `647096294147` | `dba_rncr_batch` · SPs escriben local |
| Deadline TD | Apagado Teradata **31 mar 2027** |

Detalle: `contexto_reconocer/00_RECONOCER.md` · `03_FRAMEWORK_BATCH.md` · `04_GEO.md`.

---

## 1. Principio

| Qué | Cómo |
|-----|------|
| Fuente | Lectura por **datasharing** (`ds_dba_rncr_batch.edf_views.*`) — **sin copiar** XPM |
| Salida | `bdm_datos.unificacion_direccion` · `score_ordenamiento` · `rpu_orden_prioridad` |
| Repos | `_strct` → `_pgm` → `_dt` (orden de merge Jenkins) |
| QA mock (`perf_persona_meta`, benchmark 20K) | **No es el entregable** — ver anexo |

---

## 2. Unificación (datos reales)

### Flujo

```
edf_views → vistas bdm_tempo.v_xpm_* → SPs R1/R2/R3 por escenario → unificacion_direccion
```

### Evidencia DEV (2026-09-04 / revalidado 2026-09-10)

| Métrica | Valor |
|---------|------:|
| Universo RPU | 591.166 |
| R2 unificaciones | **72.448** |
| R1 / R3 | **0** (esperado: empates R1 / sin geo R3) |
| C03 hijos sin padre | **0** |
| C04 autoreferencia | **0** |

### Artefactos

| Tipo | Dónde |
|------|--------|
| SPs por escenario | `sql/unificacion_por_escenario/` → repo `_pgm` rama `feature/unificacion-edf-views` |
| Vistas / DDL | `_strct` |
| Run + validación | `_dt` |
| Mapa HTML | `Documentacion/MAPA_UNIFICACION_EDF_VIEWS_NEGOCIO.html` |
| Checklist Manuel | `Documentacion/CHECKLIST_REVISION_MANUEL_DATOS_REALES.md` |
| Evidencias | `Documentacion/Evidencias_QA_UNIFICACION_ESCENARIOS_DEV.md` |

### Gates de calidad (reales) — lo que importa

```sql
-- Por regla
SELECT unifica_atributos, COUNT(*) 
FROM bdm_datos.unificacion_direccion GROUP BY 1 ORDER BY 1;

-- C03 / C04
SELECT
  SUM(CASE WHEN cod_dw_direccion_unificada IS NULL THEN 1 ELSE 0 END) AS c03,
  SUM(CASE WHEN cod_dw_persona_ubic = cod_dw_direccion_unificada THEN 1 ELSE 0 END) AS c04
FROM bdm_datos.unificacion_direccion;
```

**Cerrar entregable real:** R2 poblado · c03=0 · c04=0.  
**R3=0 sin lat/long** no es bug → pedir geo a negocio/Experian.

---

## 3. Ordenamiento (datos reales)

### Flujo (Opción A)

```
Unificación OK → preparar insumos → DIR → TEL → CEL → EMA → consolidar → drop
CALL bdm_datos.sp_ordenamiento_ejecucion_edf(TRUE);
```

### Evidencia DEV

| Métrica | Valor |
|---------|------:|
| Scores totales | **1.223.998** |
| Personas | 407.351 |
| Hijas con orden incorrecto | **0** |
| Tiempo | ~78 s preparar + ~20 s scoring |

### Artefactos

| Tipo | Dónde |
|------|--------|
| SPs (8 + orquestador) | `sql/dev_edf_ordenamiento/` → `_pgm` rama `feature/ordenamiento` |
| DDL / catálogos / vistas | `_strct` |
| Run + validación | `_dt` |
| **Explicación fases** | `Documentacion/FASES_ORDENAMIENTO_EXPLICADAS.md` (+ PDF) |
| Mapa HTML | `Documentacion/MAPA_ORDENAMIENTO_EDF_VIEWS_NEGOCIO.html` |
| Guía ejemplos | `Documentacion/GUIA_ORDENAMIENTO_EJEMPLOS_BASICOS.md` |

### Cómo se explica (fases = SPs)

| Fase | Pregunta | SP |
|------|----------|-----|
| 0 | ¿Quién es vigente? | Unificación previa |
| 1 | ¿Quién entra? | `preparar_insumos_edf` |
| 2a–2d | ¿Qué contacto primero? | `scoring_{dir,tel,cel,ema}_edf` |
| 3 | ¿Qué se guarda? | `consolidacion_edf` |
| 4 | ¿Limpieza? | `drop_staging_edf` |

---

## 4. Ramas Bitbucket

| Proceso | Rama | Repos |
|---------|------|-------|
| Unificación | `feature/unificacion-edf-views` | strct · pgm · dt |
| Ordenamiento | `feature/ordenamiento` | strct · pgm · dt |

Merge: **`_strct` → `_pgm` → `_dt`**

---

## 5. Qué pedir a negocio (datos reales) — para completar R1/R3

| Dato | Regla | Nota |
|------|-------|------|
| `latitud` / `longitud` | R3 | Sin esto R3=0 (N/A) |
| `complemento` (apto/torre) | R2 | Ya aporta en DEV (72k) |
| Multitipo RES/LAB/CRR + CIIU | R1 | Si 100% empate → R1=0 esperado |

Detalle: `Documentacion/PLAN_QA_DATOS_REALES_VS_MOCK.md` §1

---

## 6. Anexo — Mock (no bloquea sign-off real)

Solo si Julian/QA exige suite `perf_persona_meta` / TC-R2-14 / mock R3:

- Runbook: `Documentacion/RUNBOOK_MOCK_QA_CALIDAD.md`
- Scripts: `sql/qa_redshift/0*_*.sql` + `mock_tc_r3_01_08_10.sql`
- En QA (2026-09-11): usuario `c32525e` **conecta** pero **sin INSERT/DELETE** en `bdm_stage` → falta grant DBA o que DBA ejecute scripts.

---

## 7. Estado operativo (resumen)

| Tema | Estado |
|------|--------|
| Unificación DEV real | OK — R2=72.448, C03/C04=0 |
| Ordenamiento DEV real | OK — 1.22M scores, 0 hijas mal |
| HTML mapas negocio | Actualizados (fases claras ordenamiento) |
| PRs / merge lunes | Pendiente aprobación |
| R3 real | N/A hasta geo Experian |
| Suite mock QA | Anexo; requiere permisos escritura |

---

*Paquete local: PAQUETE_UNIFICACION_BDM_STAGE*
