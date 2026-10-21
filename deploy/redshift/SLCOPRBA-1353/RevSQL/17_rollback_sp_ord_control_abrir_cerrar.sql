-- Rollback ord_control abrir/cerrar (SIN IF EXISTS)
DROP PROCEDURE bdm_datos.sp_rcn_ctl_ord_cerrar(BIGINT, VARCHAR, DATE, BIGINT, BIGINT, BIGINT);
DROP PROCEDURE bdm_datos.sp_rcn_ctl_ord_abrir(VARCHAR, INTEGER, DATE, DATE, BOOLEAN, BIGINT);
