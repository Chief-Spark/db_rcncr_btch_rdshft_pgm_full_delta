-- ============================================================
-- 15_rollback_sp_unif_control_abrir_cerrar.sql
-- Rollback: elimina los procedimientos de control de corrida de la Unificacion.
-- Contrapartida de 15_sp_unif_control_abrir_cerrar.sql (Task 3.2).
-- (repo pgm / db_rcncr_btch_rdshft_pgm)
-- Codificacion: UTF-8 sin BOM.
-- Spec: unificacion-full-delta (Task 3.2)
-- ------------------------------------------------------------
-- Redshift NO soporta DROP PROCEDURE IF EXISTS (syntax error at or near
-- "EXISTS"). Los PROCEDIMIENTOS se revierten con DROP PROCEDURE nombre(<firma
-- exacta>) SIN IF EXISTS; la firma debe coincidir EXACTAMENTE con la del CREATE
-- (incluido el parametro INOUT de salida) -- lecciones #12 y #14.
-- Orden INVERSO al de creacion: primero cerrar, luego abrir.
-- ============================================================

DROP PROCEDURE bdm_datos.unif_control_cerrar(BIGINT, VARCHAR, DATE, BIGINT, BIGINT, BIGINT);
DROP PROCEDURE bdm_datos.unif_control_abrir(VARCHAR, INTEGER, DATE, DATE, BOOLEAN, BIGINT);
