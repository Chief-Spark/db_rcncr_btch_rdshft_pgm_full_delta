# Proceso Reconocer Batch — de punta a punta (claro)

**Fecha:** 2026-09-11  
**Fuente de contexto:** paquete `RECONOCER-Consolidado` + trabajo DEV con **datos reales** (`edf_views`).  
**Sign-off:** gates sobre data real · mock solo anexo.

---

## 1. Qué es y hacia dónde va

| | |
|--|--|
| **Qué** | Sistema Experian Colombia: consolida, unifica y ordena ~65–70M contactos (dirección, tel, cel, email) |
| **Migración** | Teradata → **Amazon Redshift** (deadline apagado TD: **31 mar 2027**) |
| **Estándarización** | En **EDF** (Spark) cuenta productor — **no** en Redshift |
| **Batch en Redshift** | Unificación + Ordenamiento (+ consumo Geo) en cluster **consumidor** Reconocer |
| **Orquestación** | Control-M → **Framework Batch** (Step Functions + Data API) |

```
COBOL/ICBDIR → EDF (estandariza) → edf_views (datashare)
                                      ↓
                         Redshift consumidor dba_rncr_batch
                         Unificación R1→R2→R3 → Ordenamiento → (Geo)
                                      ↓
                                    DB2 Online
```

Detalle arquitectura: `contexto_reconocer/00_RECONOCER.md` · diagrama DrawIO en consolidado `diagramas/`.

---

## 2. Cuentas y lectura de datos (Data Sharing)

| Rol | Cuenta AWS | Cluster / DB | Qué hace |
|-----|------------|--------------|----------|
| **Productor** | 651706752126 | procesosbatch · `dba_batch` | Publica `edf_views` (post-EDF) |
| **Consumidor** | 647096294147 | reconocerbatch · **`dba_rncr_batch`** | Lee datashare · ejecuta SPs · escribe local |

```
Productor edf_views.*  ──Data Share──►  ds_dba_rncr_batch.edf_views.*
                                              │ SELECT only
                                              ▼
                                    vistas locales / staging
                                              ▼
                         bdm_datos.unificacion_direccion
                         score_ordenamiento / rpu_orden_prioridad
```

| Regla | Detalle |
|-------|---------|
| Lectura Alpha | Solo `SELECT` sobre `ds_dba_rncr_batch.edf_views.*` |
| Prohibido | INSERT/UPDATE/COPY en el datashare |
| Escritura | `bdm_datos`, `bdm_tempo`, `bdm_stage` (locales consumidor) |

---

## 3. Cadena de procesos (orden de negocio)

```
1. Estandarización (EDF)     → fuera de este paquete
2. GEO (ArcGIS)              → lat/long; habilita R3 y scoring dirección
3. UNIFICACIÓN               → R1 → R2 (+ motor) → R3
4. ORDENAMIENTO              → score contactabilidad 4 canales
5. Salida / Online           → DB2 (fuera de scope SQL batch)
```

| Proceso | Entrada | Salida clave | Rama Bitbucket |
|---------|---------|--------------|----------------|
| **Unificación** | `edf_views` / IFR | `unificacion_direccion`, `ind_unificacion` | `feature/unificacion-edf-views` |
| **Ordenamiento** | Post-unificación + contactos | `score_ordenamiento`, `rpu_orden_prioridad` | `feature/ordenamiento` |
| **Geo** | Delta UNLOAD → S3 → ArcGIS | lat/long, barrio, estrato | Contratos S3 (ver `04_GEO.md`) |

---

## 4. Unificación — reglas en cascada

Fuente oficial RF: *Unificación de Direcciones Físicas_VF* (Andy García, 2019).  
Resumen consolidado: `contexto_reconocer/01_UNIFICACION.md`.

| Regla | Pregunta de negocio | Criterio corto |
|-------|---------------------|----------------|
| **R1** | ¿Misma puerta, distinto tipo uso? | Padre por CIIU / tipo RES·LAB·CRR |
| **R2** | ¿Misma puerta, distinto complemento? | 6 escenarios + motor nuevas dir. |
| **R3** | ¿Misma vía, puerta ±2? | Requiere **lat/long** (Geo) o diccionario vía |
| **Motor** | ¿R2 pide dirección nueva? | Genera RPU/DF nuevas |

**Orden obligatorio:** R1 → R2 → R3 · no reprocesar `ind_unificacion = 1` · trazar en `unificacion_direccion`.

### Evidencia DEV real (sign-off)

| Métrica | Valor |
|---------|------:|
| R2 | **72.448** |
| R1 / R3 | **0** (empates / sin geo — esperado) |
| C03 / C04 | **0** / **0** |

Gates y queries: [`COMO_SE_HA_HECHO_DATOS_REALES.md`](COMO_SE_HA_HECHO_DATOS_REALES.md) · mapa HTML unificación.

---

## 5. Ordenamiento — scoring contactabilidad

Post-unificación. Coeficientes Beta (regresión logística). Canales: **DIR · TEL · CEL · EMA**.

En este paquete (Opción A edf_views) se explica como **fases = SPs**:

| Fase | Pregunta | SP |
|------|----------|-----|
| 0 | ¿Quién es vigente? | Unificación previa |
| 1 | ¿Quién entra? | `preparar_insumos_edf` |
| 2a–2d | ¿Qué contacto primero? | `scoring_{dir,tel,cel,ema}_edf` |
| 3 | ¿Qué se guarda? | `consolidacion_edf` |
| 4 | ¿Limpieza? | `drop_staging_edf` |

```sql
CALL bdm_datos.sp_ordenamiento_ejecucion_edf(TRUE);
```

### Evidencia DEV real

| Métrica | Valor |
|---------|------:|
| Scores | **1.223.998** |
| Hijas con orden incorrecto | **0** |

Detalle fases + ejemplos: [`FASES_ORDENAMIENTO_EXPLICADAS.md`](FASES_ORDENAMIENTO_EXPLICADAS.md) · [`MAPA_ORDENAMIENTO_EDF_VIEWS_NEGOCIO.html`](MAPA_ORDENAMIENTO_EDF_VIEWS_NEGOCIO.html).

> Consolidado histórico habla de **17 SPs** Teradata (malla 242). En Redshift edf_views el entregable operativo actual es el **orquestador + 8 SPs** de la Opción A documentada aquí.

---

## 6. Cómo se despliega (3 repos)

Orden **siempre**:

```
db_rcncr_btch_rdshft_strct  →  _pgm  →  _dt
     (DDL/vistas)              (SPs)    (CALL / validación)
```

| Repo | Contiene |
|------|----------|
| **strct** | Tablas, vistas lectura `edf_views`, catálogos |
| **pgm** | `CREATE OR REPLACE PROCEDURE` |
| **dt** | Scripts `CALL`, validaciones, evidencias docs |

Pipeline: Bitbucket → Jira → Jenkins **DATABASE-REDSHIFT** · `deploy.par` UTF-8 **sin BOM**.  
Guía IA repos: `contexto_reconocer/GUIA_IA_REORGANIZACION_REPOS.md`.

### Framework Batch (orquestación runtime)

Trigger `.val` en S3 → Step Functions → Redshift Data API.  
SP con contrato de 6 parámetros; wrappers en `bdm_stage` llaman helpers internos.

| Nivel YAML (unificación) | SP |
|--------------------------|-----|
| 0 | cleanup + vistas |
| 1 | Regla 1 |
| 2 | Regla 2 + motor |
| 3 | Regla 3 |

Ver `contexto_reconocer/03_FRAMEWORK_BATCH.md`.

---

## 7. Geo (por qué R3 está en 0)

1. Redshift UNLOAD delta → S3 `reconocer_input/`  
2. ArcGIS + PostGIS  
3. S3 `reconocer_output/` → COPY → UPDATE geo en Redshift  

Sin **lat/long** poblados, **R3 no unifica** (esperado, no bug).  
Ver `contexto_reconocer/04_GEO.md` · PDFs en `referencias/INDICE_PDFS.md` del consolidado.

---

## 8. Calidad — hasta dónde llegamos nosotros

Alcance de validación del **equipo de migración** (SPs + gates). Sin asignar tareas a terceros.

### Lo que sí cubrimos (datos reales)

| Hasta aquí | Detalle |
|------------|---------|
| **Fuente** | `edf_views` vía Data Share → `bdm_tempo.v_xpm_*` |
| **Ejecución** | Deploy SPs · `CALL` unificación (+ ordenamiento) |
| **Gates** | R2 > 0 · **C03=0** · **C04=0** · hijas mal = 0 |
| **Evidencia DEV** | R2=**72.448** · C03/C04=**0** · scores=**1.223.998** |
| **Límite** | R3 real = **N/A** sin lat/long. Muestra real pequeña → no todos los escenarios R1/R2. |

### Lo que no es el cierre del entregable

Laboratorio sintético (`bdm_stage` / `perf_persona_meta` / suite TC / 20K) = casos puntuales. **No sustituye** gates sobre data real.

| Nuestro cierre | Fuera de alcance |
|----------------|------------------|
| SPs Data Sharing + gates reales | Carga Geo / lat-long |
| Documentar R3 = N/A sin Geo | Exigir todos los escenarios solo con muestra real |
| Scripts mock disponibles si se piden | Grants DBA / INSERT mock en QA |

---

## 9. Mapa de lectura (qué abrir)

| Si necesitas… | Abre |
|---------------|------|
| Historia + números DEV reales | [`COMO_SE_HA_HECHO_DATOS_REALES.md`](COMO_SE_HA_HECHO_DATOS_REALES.md) |
| Este proceso completo | **este archivo** · [`PROCESO_RECONOCER_END_TO_END.html`](PROCESO_RECONOCER_END_TO_END.html) |
| Unificación visual | `MAPA_UNIFICACION_EDF_VIEWS_NEGOCIO.html` |
| Ordenamiento visual | `MAPA_ORDENAMIENTO_EDF_VIEWS_NEGOCIO.html` |
| Contexto proyecto / RF / FW / Geo / QA | carpeta [`contexto_reconocer/`](contexto_reconocer/) |
| Plantilla Confluence | `contexto_reconocer/06_DOCUMENTACION_CONFLUENCE.md` |

---

## 10. Estado (sept 2026)

| Hito | Estado |
|------|--------|
| Unificación DEV real (edf_views) | OK — R2=72.448, C03/C04=0 |
| Ordenamiento DEV real | OK — 1.22M scores |
| Data Sharing consumidor | Operativo |
| R3 real | N/A hasta Geo |
| PRs merge | Pendiente aprobación |
| Mock QA escritura | Requiere grants DBA |

---

*Complementa `RECONOCER-Consolidado` con evidencias y mapas del paquete `PAQUETE_UNIFICACION_BDM_STAGE`.*
