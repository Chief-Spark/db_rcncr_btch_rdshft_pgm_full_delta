-- Rollback de sp_mock_ciclo.sql
-- (repo pgm / db_rcncr_btch_rdshft_pgm). UTF-8 sin BOM.
-- Firma EXACTA del Framework Batch: seis VARCHAR (lecciones #11 y #12).
-- Sin IF EXISTS: Redshift da syntax error at or near "EXISTS".
DROP PROCEDURE bdm_datos.sp_mock_ciclo(VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR);
