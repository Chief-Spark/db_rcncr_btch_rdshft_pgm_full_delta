-- ============================================================
-- 16_rollback_sp_unificacion_ciclo.sql
-- Rollback: elimina el orquestador maestro de corrida de la Unificacion.
-- Contrapartida de 16_sp_unificacion_ciclo.sql (Task 4.1).
-- (repo pgm / db_rcncr_btch_rdshft_pgm)
-- Codificacion: UTF-8 sin BOM.
-- Spec: unificacion-full-delta (Task 4.1)
-- ------------------------------------------------------------
-- Redshift NO soporta DROP PROCEDURE IF EXISTS (syntax error at or near
-- "EXISTS"). El PROCEDIMIENTO se revierte con DROP PROCEDURE nombre(<firma
-- exacta>) SIN IF EXISTS; la firma debe coincidir EXACTAMENTE con la del CREATE:
-- los orquestadores invocados por el Framework_Batch llevan 6 params VARCHAR
-- (in_solicitud, in_nit_suscriptor, in_path_archivo, in_nemotecnico,
-- in_id_facturacion, in_fecha_ejecucion) -- lecciones #11, #12 y #14.
-- ============================================================

DROP PROCEDURE bdm_datos.sp_unificacion_ciclo(VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR);
