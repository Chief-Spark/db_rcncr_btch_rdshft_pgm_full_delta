-- Rollback de sp_geo_cargar_georreferenciacion_mock (Redshift no soporta IF EXISTS en DROP PROCEDURE)
DROP PROCEDURE bdm_datos.sp_geo_cargar_georreferenciacion_mock(INTEGER, VARCHAR);
