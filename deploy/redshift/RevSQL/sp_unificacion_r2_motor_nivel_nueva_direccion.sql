-- Rollback de sp_unificacion_r2_motor_nivel_nueva_direccion (Redshift no soporta IF EXISTS en DROP PROCEDURE)
DROP PROCEDURE bdm_datos.sp_unificacion_r2_motor_nivel_nueva_direccion(VARCHAR,INTEGER);
