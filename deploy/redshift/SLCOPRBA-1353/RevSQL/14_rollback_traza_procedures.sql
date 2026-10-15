-- ============================================================
-- 14_rollback_traza_procedures.sql
-- Rollback: elimina los procedimientos de traza de la Unificacion
-- (repo pgm / db_rcncr_btch_rdshft_pgm)
-- Contrapartida de 14_traza_procedures.sql (Task 3.3).
-- Codificacion: UTF-8 sin BOM.
-- Spec: unificacion-full-delta (Task 3.3)
-- Requirements: 13.8, 13.9
-- ------------------------------------------------------------
-- Rollback de PROCEDIMIENTOS: Redshift NO soporta DROP PROCEDURE IF EXISTS
-- (lecciones #12/#14). Se usa DROP PROCEDURE nombre(<firma exacta>); sin IF EXISTS.
-- La firma exacta importa: debe coincidir con los tipos declarados en 14_traza_procedures.sql.
-- Orden INVERSO a la creacion: se creo primero unif_traza_inicio y luego
-- unif_traza_fin, por lo que aqui se elimina primero unif_traza_fin.
-- NOTA: no se elimina el schema bdm_datos porque es compartido.
-- ============================================================

DROP PROCEDURE bdm_datos.unif_traza_fin(BIGINT, VARCHAR, VARCHAR, BIGINT, BIGINT, BIGINT, BIGINT, BIGINT);
DROP PROCEDURE bdm_datos.unif_traza_inicio(BIGINT, INTEGER, VARCHAR);
