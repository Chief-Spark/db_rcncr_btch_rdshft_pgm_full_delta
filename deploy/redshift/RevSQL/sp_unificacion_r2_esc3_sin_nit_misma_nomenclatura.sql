-- Rollback de sp_unificacion_r2_esc3_sin_nit_misma_nomenclatura (Redshift no soporta IF EXISTS en DROP PROCEDURE)
DROP PROCEDURE bdm_datos.sp_unificacion_r2_esc3_sin_nit_misma_nomenclatura(VARCHAR,INTEGER);
