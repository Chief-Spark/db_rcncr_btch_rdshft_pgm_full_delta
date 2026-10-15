-- Orquestador ordenamiento EDF (cadena interna; preferir sp_ordenamiento_ciclo)
CREATE OR REPLACE PROCEDURE bdm_datos.sp_ordenamiento_ejecucion_edf(
  p_preparar_insumos BOOLEAN,
  p_modo             VARCHAR,
  p_lote             INTEGER,
  p_watermark        DATE
)
NONATOMIC
LANGUAGE plpgsql
AS $$
DECLARE
  v_modo VARCHAR(10) := COALESCE(NULLIF(TRIM(p_modo), ''), 'FULL');
BEGIN
  IF COALESCE(p_preparar_insumos, TRUE) THEN
    CALL bdm_datos.sp_ordenamiento_preparar_insumos_edf(v_modo, p_lote, p_watermark);
  END IF;

  CALL bdm_datos.sp_ordenamiento_scoring_dir_edf();
  CALL bdm_datos.sp_ordenamiento_scoring_tel_edf();
  CALL bdm_datos.sp_ordenamiento_scoring_cel_edf();
  CALL bdm_datos.sp_ordenamiento_scoring_ema_edf();
  CALL bdm_datos.sp_ordenamiento_consolidacion_edf();
  CALL bdm_datos.sp_ordenamiento_drop_staging_edf();
END;
$$;

-- SLCOPRBA-1355: re-DPLY DEV post DROP SCHEMA strct #256
