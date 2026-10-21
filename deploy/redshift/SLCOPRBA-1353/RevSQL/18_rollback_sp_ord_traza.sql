-- Rollback ord_traza (SIN IF EXISTS)
DROP PROCEDURE bdm_datos.sp_rcn_ctl_ord_traza_fin(BIGINT, VARCHAR, VARCHAR, BIGINT, BIGINT);
DROP PROCEDURE bdm_datos.sp_rcn_ctl_ord_traza_inicio(BIGINT, INTEGER, VARCHAR);
