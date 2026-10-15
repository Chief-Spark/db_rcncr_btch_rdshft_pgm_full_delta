-- Rollback de sp_unificacion_r1_preparar_insumo (Redshift no soporta IF EXISTS en DROP PROCEDURE)
DROP PROCEDURE bdm_datos.sp_unificacion_r1_preparar_insumo(VARCHAR,DATE);
