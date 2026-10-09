-- Rollback de sp_unif_gate_convergencia_snapshot.
-- Firma (p_etiqueta VARCHAR, p_secuencia INTEGER, p_lote INTEGER): lo invoca el
-- script de la bateria, no el Framework_Batch.
DROP PROCEDURE bdm_datos.sp_unif_gate_convergencia_snapshot(VARCHAR, INTEGER, INTEGER);
