-- Consolidacion EDF — UPSERT por personas del alcance (FULL/DELTA)
CREATE OR REPLACE PROCEDURE bdm_datos.sp_ordenamiento_consolidacion_edf()
NONATOMIC
LANGUAGE plpgsql
AS $$
BEGIN
  DELETE FROM bdm_datos.rpu_orden_prioridad
  WHERE id_buro_persona IN (
    SELECT id_buro_persona FROM bdm_tempo.stg_ord_personas_alcance
  );

  INSERT INTO bdm_datos.rpu_orden_prioridad (
    cod_dw_persona_ubic, id_buro_persona, orden_prioridad, fecha_actualizacion
  )
  SELECT
    best.cod_dw_persona_ubic,
    best.id_buro_persona,
    best.lugar,
    GETDATE()
  FROM (
    SELECT
      s.cod_dw_persona_ubic,
      s.id_buro_persona,
      MIN(s.lugar) AS lugar
    FROM bdm_datos.score_ordenamiento s
    INNER JOIN bdm_tempo.stg_rpu_post_unificacion rpu
      ON rpu.cod_dw_persona_ubic = s.cod_dw_persona_ubic
     AND COALESCE(rpu.ind_unificacion, 0) <> 1
    WHERE s.id_buro_persona IN (
      SELECT id_buro_persona FROM bdm_tempo.stg_ord_personas_alcance
    )
    GROUP BY 1, 2
  ) best;
END;
$$;
-- SLCOPRBA-1355: re-DPLY DEV post DROP SCHEMA strct #256
