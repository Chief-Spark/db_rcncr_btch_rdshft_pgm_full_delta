# Entrega QA — Unificación (datos reales + mock)

**Alcance de esta entrega:** solo **Unificación de direcciones** (R1 → R2 → R3).  
**Fuera de alcance aquí:** Ordenamiento / scoring (otra rama / otro entregable).

**Fecha:** 2026-09-14  
**Rama Bitbucket (3 repos):** `feature/unificacion-edf-views`  
**Orden deploy:** `_strct` → `_pgm` → `_dt`

---

## 1. Qué deben configurar en el prompt

Hay **dos modos**. Elegir **uno** por corrida; no mezclar.

| | Modo A — Datos reales | Modo B — Datos mockeados |
|--|------------------------|---------------------------|
| **Para qué** | Cierre / gates de Unificación | Suite TC (empates, R3 con geo sintético) |
| **DB** | Consumidor Reconocer · `dba_rncr_batch` | Productor QA · `dba_batch` |
| **Schema lectura** | `bdm_tempo.v_xpm_*` (leen `edf_views`) | `bdm_stage` + `perf_persona_meta` |
| **Schema SPs / salida** | **`bdm_datos`** | **`bdm_stage`** (path mock) |
| **R3** | **N/A** sin lat/long | **Sí se debe probar** con mock geo |

---

## 2. Modo A — Datos reales (Unificación)

### 2.1 Tablas / esquemas fuente

| Objeto | Rol |
|--------|-----|
| `ds_dba_rncr_batch.edf_views.xpm` | Persona / pin |
| `ds_dba_rncr_batch.edf_views.xpm_location` | Ubicación |
| `ds_dba_rncr_batch.edf_views.xpm_location_val_contactinformations` | Dirección / `standardized*` |
| `ds_dba_rncr_batch.edf_views.xpm_counterparties` | Entidades reportantes |

### 2.2 Vistas que usan los SPs (usar estas, no XPM crudo)

- `bdm_tempo.v_xpm_relacion_persona_ubicacion`
- `bdm_tempo.v_xpm_ubicacion_estandarizada`
- `bdm_tempo.v_xpm_direccion_fisica`
- `bdm_tempo.v_xpm_reporte_relacion_persona_ubica`
- `bdm_tempo.v_xpm_ciiu_persona`
- `bdm_tempo.v_xpm_contacto_direccion`

### 2.3 Catálogos y salida

| Objeto | Rol |
|--------|-----|
| `bdm_datos.nomenclatura` | Catálogo |
| `bdm_datos.tipo_ubicacion_dir` | Catálogo |
| `bdm_datos.diccionario_complementos` | Catálogo R2 |
| `bdm_tempo.stg_regla*` | Staging temporal |
| **`bdm_datos.unificacion_direccion`** | **Resultado Unificación** |

### 2.4 Stored procedures (nombres exactos)

```sql
CALL bdm_datos.sp_unificacion_regla1();
CALL bdm_datos.sp_unificacion_regla2();
CALL bdm_datos.sp_unificacion_regla3();  -- sin geo → 0 filas; marcar N/A
```

Detalle por escenario (repo `_pgm`):

| Regla | Procedimientos |
|-------|----------------|
| **R1** | `sp_unificacion_r1_preparar_insumo` · `sp_unificacion_r1_esc1_ciiu10_mismo_texto_padre_lab_crr` · `sp_unificacion_r1_esc2_ciiu81_90_mismo_texto_padre_res_crr` · `sp_unificacion_r1_esc3_otros_ciiu_mayor_entidades_reportan` · `sp_unificacion_regla1` |
| **R2** | `sp_unificacion_r2_preparar_insumo` · `sp_unificacion_r2_esc1_complemento_vacio_esc2_substring_complemento` · `sp_unificacion_r2_esc3_sin_nit_misma_nomenclatura` · `sp_unificacion_r2_esc4_diccionario_frecuencia_complemento` · `sp_unificacion_r2_esc5_nomenclatura_menor_nivel_pierde` · `sp_unificacion_r2_esc6_frecuencia_complemento_gana` · `sp_unificacion_r2_motor_nit_empates_nuevas_direcciones` · `sp_unificacion_regla2` |
| **R3** | `sp_unificacion_r3_esc1_geo_misma_via_puerta_cercana` · `sp_unificacion_regla3` |

Script de corrida en `_dt`: `run_unificacion_ejecucion_secuencial.sql`

### 2.5 Gates de Unificación (modo real)

```sql
SELECT unifica_atributos, COUNT(*)
FROM bdm_datos.unificacion_direccion
GROUP BY 1 ORDER BY 1;

SELECT
  SUM(CASE WHEN cod_dw_direccion_unificada IS NULL THEN 1 ELSE 0 END) AS c03,
  SUM(CASE WHEN cod_dw_persona_ubic = cod_dw_direccion_unificada THEN 1 ELSE 0 END) AS c04
FROM bdm_datos.unificacion_direccion;
```

| Gate | Esperado |
|------|----------|
| `unifica_atributos = 2` (R2) | > 0 |
| C03 (hijo sin padre) | **0** |
| C04 (autoreferencia) | **0** |
| R1 | Puede ser 0 (empates / poca variedad) |
| R3 | **0 = N/A** sin lat/long — **no es FAIL** |

**No usar** en modo real: `perf_persona_meta` ni `TC-R1-01…TC-R2-14` con `scenario_code`.

**Nota:** la muestra real es pequeña; es muy probable que no existan filas para **todos** los escenarios R1/R2. Eso no invalida los SPs.

Evidencia DEV (referencia): R2 = 72.448 · C03/C04 = 0 · R1/R3 = 0.

---

## 3. Modo B — Datos mockeados (solo Unificación TC)

| Pieza | Valor |
|-------|--------|
| DB | `dba_batch` |
| Schema | `bdm_stage` |
| Escenarios | `bdm_stage.perf_persona_meta.scenario_code` |
| Tablas | `relacion_persona_ubicacion`, `direccion_fisica`, `unificacion_direccion`, `diccionario_complementos`, … |

### R2 — hallazgo TC-R2-14 (`R2_EMPATE`)

1. SP Esc4 con `stg_regla2_e04_ganador … HAVING COUNT(*) = 1` (ya en rama `feature/unificacion-edf-views`).
2. Patch: `sql/qa_redshift/02_patch_r2_empate_limpiar_absorciones.sql`
3. Revalidar: `04_revalidar_r2_empate_tras_sp.sql` / `04_validacion_tc_r1_r2_bdm_stage.sql`
4. Runbook: `RUNBOOK_MOCK_QA_CALIDAD.md`

### R3 — mock (sí se prueba)

1. Sembrar geo: `sql/qa_redshift/mock_tc_r3_01_08_10.sql`
2. `CALL` regla 3 sobre tablas mock
3. Si `permission denied` → grants DBA (INSERT/UPDATE en `bdm_stage`)

---

## 4. Prompts listos (copiar)

### Prompt Unificación — datos reales

```
Proceso: UNIFICACIÓN de direcciones (R1→R2→R3). No evaluar Ordenamiento.

Ambiente: consumidor Reconocer / dba_rncr_batch (Data Sharing).
NO uses bdm_stage ni perf_persona_meta.
Fuente: bdm_tempo.v_xpm_* (leen ds_dba_rncr_batch.edf_views.xpm*).
SPs: CALL bdm_datos.sp_unificacion_regla1(); regla2(); regla3();
Resultado: bdm_datos.unificacion_direccion.
Validar: conteo por unifica_atributos, C03=0, C04=0.
R3 sin lat/long → N/A (no FAIL).
Muestra real pequeña: no exigir todos los escenarios R1/R2.
```

### Prompt Unificación — datos mockeados

```
Proceso: UNIFICACIÓN (suite TC). No evaluar Ordenamiento.

Ambiente: dba_batch / bdm_stage.
Usa perf_persona_meta.scenario_code.
TC-R2-14: patch R2_EMPATE + SP Esc4 con e04_ganador HAVING COUNT(*)=1.
R3: sembrar mock_tc_r3 (lat/long) y CALL regla3; R3 mock sí se prueba.
No mezclar edf_views / v_xpm_* en esta corrida.
```

---

## 5. Estado en Bitbucket

| Ítem Unificación | Estado |
|------------------|--------|
| Vistas `v_xpm_*` (`_strct`) | En `feature/unificacion-edf-views` |
| 15 SPs R1/R2/R3 (`_pgm`) incl. fix Esc4 empate | En rama |
| `run_` + validación (`_dt`) | En rama |
| Scripts mock R2/R3 | `docs/sql_qa_redshift_mock/` en `_dt` |
| Deploy Jenkins QA consumidor | Pendiente pipeline |

---

*Complemento prompts:* `PROMPT_PRUEBAS_QA_REAL_VS_MOCK.md` · *Runbook mock:* `RUNBOOK_MOCK_QA_CALIDAD.md`
