-- Rollback ord_traza (SIN IF EXISTS)
DROP PROCEDURE bdm_datos.ord_traza_fin(BIGINT, VARCHAR, VARCHAR, BIGINT, BIGINT);
DROP PROCEDURE bdm_datos.ord_traza_inicio(BIGINT, INTEGER, VARCHAR);
