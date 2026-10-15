-- Rollback de sp_geo_ciclo_lote (Redshift no soporta IF EXISTS en DROP PROCEDURE)
DROP PROCEDURE bdm_datos.sp_geo_ciclo_lote(INTEGER, VARCHAR, VARCHAR);
