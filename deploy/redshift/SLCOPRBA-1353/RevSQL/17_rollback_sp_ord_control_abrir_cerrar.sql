-- Rollback ord_control abrir/cerrar (SIN IF EXISTS)
DROP PROCEDURE bdm_datos.ord_control_cerrar(BIGINT, VARCHAR, DATE, BIGINT, BIGINT, BIGINT);
DROP PROCEDURE bdm_datos.ord_control_abrir(VARCHAR, INTEGER, DATE, DATE, BOOLEAN, BIGINT);
