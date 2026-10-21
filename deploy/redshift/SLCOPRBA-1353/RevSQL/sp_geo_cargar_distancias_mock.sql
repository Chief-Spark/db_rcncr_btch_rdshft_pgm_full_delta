-- Rollback de sp_geo_cargar_distancias_mock.sql
-- (repo pgm / db_rcncr_btch_rdshft_pgm). UTF-8 sin BOM.
-- Redshift NO soporta DROP PROCEDURE IF EXISTS: firma EXACTA (leccion #12).
DROP PROCEDURE bdm_datos.sp_geo_cargar_distancias_mock(INTEGER, VARCHAR);
