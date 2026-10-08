-- Orquestador Regla 3
-- MODO MOCK — lee v_mock_*/bdm_stage; NO usa edf_views ni v_xpm_*
-- Escenario: CALL R3 geo
-- Fuente: bdm_stage → bdm_tempo.v_mock_* | Salida: bdm_datos.unificacion_direccion_mock | MODO MOCK
-- Generado: tools/gen_unificacion_mock_sps.py (espejo mock)

CREATE OR REPLACE PROCEDURE bdm_datos.sp_unificacion_mock_regla3(
    p_modo      VARCHAR,   -- FULL | DELTA (modo efectivo de la corrida)
    p_lote      INTEGER,   -- Lote_Corrida externo
    p_watermark DATE       -- frontera inferior inclusiva (solo aplica en DELTA)
)
NONATOMIC
LANGUAGE plpgsql
AS $$
BEGIN

  CALL bdm_datos.sp_unificacion_mock_r3_esc1_geo_misma_via_puerta_cercana(p_modo, p_lote);

END;
$$;
-- SLCOPRBA-1355: re-DPLY DEV post DROP SCHEMA strct #256
