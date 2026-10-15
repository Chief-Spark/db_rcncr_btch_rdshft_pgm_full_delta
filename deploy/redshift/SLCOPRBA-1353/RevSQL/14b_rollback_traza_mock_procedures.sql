-- ============================================================
-- 14b_rollback_traza_mock_procedures.sql
-- Rollback: elimina los procedimientos de traza de la Unificacion MOCK.
-- Contrapartida de 14b_traza_mock_procedures.sql.
-- (repo pgm / db_rcncr_btch_rdshft_pgm)
-- Codificacion: UTF-8 sin BOM.
-- ------------------------------------------------------------
-- Redshift NO soporta DROP PROCEDURE IF EXISTS (syntax error at or near
-- "EXISTS", leccion #12). Se usa DROP PROCEDURE nombre(<firma exacta>);
-- la firma debe coincidir EXACTAMENTE con la del CREATE (leccion #14).
-- Orden inverso a la creacion: primero el fin, luego el inicio.
-- ============================================================

DROP PROCEDURE bdm_datos.unif_traza_mock_fin(BIGINT, VARCHAR, VARCHAR, BIGINT, BIGINT, BIGINT, BIGINT, BIGINT);
DROP PROCEDURE bdm_datos.unif_traza_mock_inicio(BIGINT, INTEGER, VARCHAR);
