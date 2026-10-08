# Prompt QA — Unificación (datos reales vs mock)

**Solo Unificación (R1→R2→R3).** No incluir Ordenamiento en estas corridas.  
Usar **un solo modo** por ejecución.

Detalle tablas/SPs: [`ENTREGA_QA_UNIFICACION.md`](ENTREGA_QA_UNIFICACION.md)

---

## Modo A — Datos reales

```
Proceso: UNIFICACIÓN de direcciones (R1→R2→R3). No evaluar Ordenamiento.

Conexión / DB: consumidor Reconocer, database dba_rncr_batch.
Schemas:
  - Lectura: bdm_tempo.v_xpm_* (leen ds_dba_rncr_batch.edf_views.xpm*)
  - Resultado: bdm_datos.unificacion_direccion
  - Staging: bdm_tempo.stg_*
  - Catálogos: bdm_datos.nomenclatura, tipo_ubicacion_dir, diccionario_complementos

Tablas XPM (vía datashare):
  ds_dba_rncr_batch.edf_views.xpm
  ds_dba_rncr_batch.edf_views.xpm_location
  ds_dba_rncr_batch.edf_views.xpm_location_val_contactinformations
  ds_dba_rncr_batch.edf_views.xpm_counterparties

SPs (schema bdm_datos, NO bdm_stage):
  CALL bdm_datos.sp_unificacion_regla1();
  CALL bdm_datos.sp_unificacion_regla2();
  CALL bdm_datos.sp_unificacion_regla3();

Validación Unificación:
  - Conteos por unifica_atributos
  - C03 = 0, C04 = 0
  - NO usar perf_persona_meta / scenario_code
  - R3 sin lat/long → N/A (no FAIL)
  - Muestra real pequeña: no exigir todos los escenarios R1/R2
```

---

## Modo B — Datos mockeados

```
Proceso: UNIFICACIÓN suite TC. No evaluar Ordenamiento.

DB: dba_batch · Schema: bdm_stage
Escenarios: bdm_stage.perf_persona_meta.scenario_code

R2 TC-R2-14 (R2_EMPATE):
  1) SP Esc4 con stg_regla2_e04_ganador HAVING COUNT(*)=1
  2) sql/qa_redshift/02_patch_r2_empate_limpiar_absorciones.sql
  3) Revalidar TC-R2-14 (esperado 0)

R3 mock (sí se prueba):
  1) sql/qa_redshift/mock_tc_r3_01_08_10.sql
  2) CALL regla3 sobre tablas mock
  3) Si permission denied → DBA (INSERT/UPDATE)

NO mezclar edf_views / bdm_tempo.v_xpm_* en esta corrida.
```
