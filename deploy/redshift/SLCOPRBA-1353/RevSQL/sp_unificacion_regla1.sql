-- Rollback de sp_unificacion_regla1 (Redshift no soporta IF EXISTS en DROP PROCEDURE)
DROP PROCEDURE bdm_datos.sp_unificacion_regla1(VARCHAR,VARCHAR,VARCHAR,VARCHAR,VARCHAR,VARCHAR);
