-- Rollback de sp_cert_evaluar_criterios_mock.
-- Firma (p_fase VARCHAR, p_lote INTEGER): lo invoca el script de la bateria.
-- Sin IF EXISTS y con la firma exacta (politica #12/#14).
DROP PROCEDURE bdm_datos.sp_cert_evaluar_criterios_mock(VARCHAR, INTEGER);
