-- Rollback de sp_novedades_ciclo_edf.sql
-- (repo pgm / db_rcncr_btch_rdshft_pgm). UTF-8 sin BOM.
-- Firma EXACTA del Framework Batch: seis VARCHAR (lecciones #11 y #12).
DROP PROCEDURE bdm_datos.sp_novedades_ciclo_edf(VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR);
