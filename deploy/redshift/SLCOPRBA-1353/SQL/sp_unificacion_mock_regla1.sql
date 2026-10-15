-- Orquestador Regla 1
-- MODO MOCK — lee v_mock_*/bdm_stage; NO usa edf_views ni v_xpm_*
-- Escenario: CALL escenarios R1 en orden
-- Fuente: bdm_stage → bdm_tempo.v_mock_* | Salida: bdm_datos.unificacion_direccion_mock | MODO MOCK
-- Generado: tools/gen_unificacion_mock_sps.py (espejo mock)

CREATE OR REPLACE PROCEDURE bdm_datos.sp_unificacion_mock_regla1(
    p_modo      VARCHAR,   -- FULL | DELTA (modo efectivo de la corrida)
    p_lote      INTEGER,   -- Lote_Corrida externo
    p_watermark DATE       -- frontera inferior inclusiva (solo aplica en DELTA)
)
NONATOMIC
LANGUAGE plpgsql
AS $$
BEGIN

  CALL bdm_datos.sp_unificacion_mock_r1_preparar_insumo(p_modo, p_watermark);
  CALL bdm_datos.sp_unificacion_mock_r1_esc1_ciiu10_mismo_texto_padre_lab_crr(p_modo, p_lote);
  CALL bdm_datos.sp_unificacion_mock_r1_esc2_ciiu81_90_mismo_texto_padre_res_crr(p_modo, p_lote);
  CALL bdm_datos.sp_unificacion_mock_r1_esc3_otros_ciiu_mayor_entidades_reportan(p_modo, p_lote);
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_regla1_insumo;

END;
$$;
-- SLCOPRBA-1355: re-DPLY DEV post DROP SCHEMA strct #256
