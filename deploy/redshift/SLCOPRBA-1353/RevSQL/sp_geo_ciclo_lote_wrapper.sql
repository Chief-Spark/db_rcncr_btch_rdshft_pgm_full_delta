-- Rollback de sp_geo_ciclo_lote_wrapper (Redshift no soporta IF EXISTS en DROP PROCEDURE)
DROP PROCEDURE bdm_stage.sp_geo_ciclo_lote(VARCHAR,VARCHAR,VARCHAR,VARCHAR,VARCHAR,VARCHAR);
