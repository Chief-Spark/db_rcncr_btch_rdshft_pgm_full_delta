-- Rollback de sp_unificacion_r2_construir_diccionario_complementos (Redshift no
-- soporta IF EXISTS en DROP PROCEDURE, leccion #12). Firma exacta (leccion #14):
-- es un SP interno, NO invocado por el Framework_Batch, de modo que lleva la
-- firma propia de los escenarios de Regla 2: (p_modo VARCHAR, p_lote INTEGER).
DROP PROCEDURE bdm_datos.sp_unificacion_r2_construir_diccionario_complementos(VARCHAR, INTEGER);
