-- Rollback de sp_ordenamiento_preparar_insumos_mock (Redshift no soporta
-- IF EXISTS en DROP PROCEDURE, leccion #12). Firma exacta (leccion #14):
-- es un procedimiento interno, NO invocado por el Framework_Batch, por lo que
-- conserva la firma propia del preparar real: (VARCHAR, INTEGER, DATE).
DROP PROCEDURE bdm_datos.sp_ordenamiento_preparar_insumos_mock(VARCHAR, INTEGER, DATE);
