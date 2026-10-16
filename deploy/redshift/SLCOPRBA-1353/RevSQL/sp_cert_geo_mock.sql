-- Rollback de sp_cert_geo_mock (Redshift no soporta IF EXISTS en DROP PROCEDURE)
DROP PROCEDURE bdm_datos.sp_cert_geo_mock();
