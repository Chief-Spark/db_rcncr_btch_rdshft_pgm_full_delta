-- Rollback de sp_unificacion_r2_esc5_nomenclatura_menor_nivel_pierde (Redshift no soporta IF EXISTS en DROP PROCEDURE)
DROP PROCEDURE bdm_datos.sp_unificacion_r2_esc5_nomenclatura_menor_nivel_pierde(VARCHAR,INTEGER);
