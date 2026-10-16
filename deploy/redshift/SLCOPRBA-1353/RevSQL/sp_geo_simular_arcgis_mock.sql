-- Rollback de sp_geo_simular_arcgis_mock (Redshift no soporta IF EXISTS en DROP PROCEDURE)
DROP PROCEDURE bdm_datos.sp_geo_simular_arcgis_mock(INTEGER, VARCHAR);
