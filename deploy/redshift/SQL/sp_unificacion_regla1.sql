-- Orquestador Regla 1
-- Escenario: CALL escenarios R1 en orden
-- Fuente: edf_views → bdm_tempo.v_xpm_* | Salida: bdm_datos.unificacion_direccion
-- Generado: tools/gen_unificacion_sps_por_escenario.py

-- Firma Framework Batch (6 params VARCHAR): in_solicitud, in_nit_suscriptor,
-- in_path_archivo, in_nemotecnico, in_id_facturacion, in_fecha_ejecucion.
-- Los parametros no se usan en la logica de unificacion (procesa edf_views completo).
CREATE OR REPLACE PROCEDURE bdm_datos.sp_unificacion_regla1(
    in_solicitud       VARCHAR,
    in_nit_suscriptor  VARCHAR,
    in_path_archivo    VARCHAR,
    in_nemotecnico     VARCHAR,
    in_id_facturacion  VARCHAR,
    in_fecha_ejecucion VARCHAR
)
NONATOMIC
LANGUAGE plpgsql
AS $$
DECLARE
  -- (Tarea 6.1) El orquestador maestro re-emite en los slots 4/5/6 del
  -- Framework_Batch: in_nemotecnico=Modo_Corrida, in_id_facturacion=Lote_Corrida,
  -- in_fecha_ejecucion=Watermark (frontera inferior inclusiva de la ventana
  -- DELTA; NO es la Fecha_Proceso). Se derivan aqui y se propagan a
  -- preparar_insumo(p_modo, p_watermark) y a cada escenario(p_modo, p_lote);
  -- ningun escenario re-parsea el Framework_Batch.
  p_modo      VARCHAR := NULLIF(UPPER(TRIM(COALESCE(in_nemotecnico, ''))), '');
  p_lote      INTEGER := CAST(NULLIF(TRIM(COALESCE(in_id_facturacion, '')), '') AS INTEGER);
  p_watermark DATE    := CAST(NULLIF(TRIM(COALESCE(in_fecha_ejecucion, '')), '') AS DATE);
BEGIN

  IF p_modo IS NULL THEN
    p_modo := 'FULL';   -- FULL por defecto (no romper lo desplegado, Req 10.1).
  END IF;

  CALL bdm_datos.sp_unificacion_r1_preparar_insumo(p_modo, p_watermark);
  CALL bdm_datos.sp_unificacion_r1_esc1_ciiu10_mismo_texto_padre_lab_crr(p_modo, p_lote);
  CALL bdm_datos.sp_unificacion_r1_esc2_ciiu81_90_mismo_texto_padre_res_crr(p_modo, p_lote);
  CALL bdm_datos.sp_unificacion_r1_esc3_otros_ciiu_mayor_entidades_reportan(p_modo, p_lote);
  DROP TABLE IF EXISTS bdm_tempo.stg_regla1_insumo;

EXCEPTION WHEN OTHERS THEN
  RAISE EXCEPTION 'sp_unificacion_regla1 failed: %', SQLERRM;
END;
$$;
-- SLCOPRBA-1355: re-DPLY DEV post DROP SCHEMA strct #256
