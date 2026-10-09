-- ============================================================
-- 15b_rollback_sp_unif_control_mock_abrir_cerrar.sql
-- Rollback: elimina los procedimientos de control de corrida MOCK.
-- Contrapartida de 15b_sp_unif_control_mock_abrir_cerrar.sql.
-- (repo pgm / db_rcncr_btch_rdshft_pgm)
-- Codificacion: UTF-8 sin BOM.
-- ------------------------------------------------------------
-- Redshift NO soporta DROP PROCEDURE IF EXISTS (leccion #12). Firma exacta
-- obligatoria (leccion #14). Nota: p_corrida_id es INOUT en unif_control_mock_abrir,
-- pero en la firma del DROP solo se declaran los TIPOS, no los modos.
-- Orden inverso a la creacion: primero cerrar, luego abrir.
-- ============================================================

DROP PROCEDURE bdm_datos.unif_control_mock_cerrar(BIGINT, VARCHAR, DATE, BIGINT, BIGINT, BIGINT);
DROP PROCEDURE bdm_datos.unif_control_mock_abrir(VARCHAR, INTEGER, DATE, DATE, BOOLEAN, BIGINT);
