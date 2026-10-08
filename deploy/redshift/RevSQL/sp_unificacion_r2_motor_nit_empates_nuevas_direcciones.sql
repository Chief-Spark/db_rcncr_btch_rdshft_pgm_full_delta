-- Rollback de sp_unificacion_r2_motor_nit_empates_nuevas_direcciones (Redshift no soporta IF EXISTS en DROP PROCEDURE)
DROP PROCEDURE bdm_datos.sp_unificacion_r2_motor_nit_empates_nuevas_direcciones(VARCHAR,INTEGER);
