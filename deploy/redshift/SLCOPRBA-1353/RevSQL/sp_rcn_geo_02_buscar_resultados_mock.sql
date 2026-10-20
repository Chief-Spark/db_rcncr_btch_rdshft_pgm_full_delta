-- Rollback de sp_rcn_geo_02_buscar_resultados_mock (Redshift no soporta IF EXISTS en DROP PROCEDURE)
DROP PROCEDURE bdm_datos.sp_rcn_geo_02_buscar_resultados_mock();
