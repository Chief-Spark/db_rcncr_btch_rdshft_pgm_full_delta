-- Rollback de sp_cert_evaluar_criterios_nov_mock.sql
-- (repo pgm / db_rcncr_btch_rdshft_pgm). UTF-8 sin BOM.
-- Redshift NO soporta DROP PROCEDURE IF EXISTS: firma EXACTA (leccion #12).
-- Firma de gate (VARCHAR, INTEGER), no la del Framework Batch.
DROP PROCEDURE bdm_datos.sp_cert_evaluar_criterios_nov_mock(VARCHAR, INTEGER);
