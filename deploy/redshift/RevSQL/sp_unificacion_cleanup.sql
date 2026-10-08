-- Rollback de sp_unificacion_cleanup (Redshift no soporta IF EXISTS en DROP PROCEDURE)
DROP PROCEDURE bdm_datos.sp_unificacion_cleanup(VARCHAR,VARCHAR,VARCHAR,VARCHAR,VARCHAR,VARCHAR);
