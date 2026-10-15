-- Rollback de sp_unificacion_mock_gate_arq.
-- Firma (p_fase VARCHAR, p_lote INTEGER): lo invoca el script de la bateria.
DROP PROCEDURE bdm_datos.sp_unificacion_mock_gate_arq(VARCHAR, INTEGER);
