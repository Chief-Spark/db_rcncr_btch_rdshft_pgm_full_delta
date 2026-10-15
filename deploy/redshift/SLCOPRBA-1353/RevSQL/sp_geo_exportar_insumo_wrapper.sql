-- Rollback de sp_geo_exportar_insumo_wrapper (Redshift no soporta IF EXISTS en DROP PROCEDURE)
DROP PROCEDURE bdm_stage.sp_geo_exportar_insumo(VARCHAR,VARCHAR,VARCHAR,VARCHAR,VARCHAR,VARCHAR);
