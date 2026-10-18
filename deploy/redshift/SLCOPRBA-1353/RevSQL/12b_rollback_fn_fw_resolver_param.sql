-- ============================================================
-- 12b_rollback_fn_fw_resolver_param.sql
-- Rollback: elimina la funcion bdm_datos.fw_resolver_param
-- (repo pgm / db_rcncr_btch_rdshft_pgm)
-- Contrapartida de 12b_fn_fw_resolver_param.sql.
-- Codificacion: UTF-8 sin BOM.
-- ------------------------------------------------------------
-- Leccion #10: Redshift NO soporta DROP FUNCTION IF EXISTS (da
-- syntax error at or near "EXISTS"), y DROP SCHEMA CASCADE no es
-- opcion porque bdm_datos es compartido (incidente DEV #256).
-- Se usa la FIRMA EXACTA del CREATE y se asume el fallo
-- "function ... does not exist" si no estaba desplegada: es
-- esperado en un rollback y no deja residuos.
-- ============================================================

DROP FUNCTION bdm_datos.fw_resolver_param(VARCHAR, VARCHAR);
