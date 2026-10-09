-- ============================================================
-- 16b_rollback_sp_unificacion_mock_ciclo.sql
-- Rollback: elimina el orquestador maestro de la Unificacion MOCK.
-- Contrapartida de 16b_sp_unificacion_mock_ciclo.sql.
-- (repo pgm / db_rcncr_btch_rdshft_pgm)
-- Codificacion: UTF-8 sin BOM.
-- ------------------------------------------------------------
-- Redshift NO soporta DROP PROCEDURE IF EXISTS (leccion #12). Firma exacta
-- obligatoria (leccion #14): los orquestadores invocados por el
-- Framework_Batch llevan 6 params VARCHAR (in_solicitud, in_nit_suscriptor,
-- in_path_archivo, in_nemotecnico, in_id_facturacion, in_fecha_ejecucion).
-- ============================================================

DROP PROCEDURE bdm_datos.sp_unificacion_mock_ciclo(VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR);
