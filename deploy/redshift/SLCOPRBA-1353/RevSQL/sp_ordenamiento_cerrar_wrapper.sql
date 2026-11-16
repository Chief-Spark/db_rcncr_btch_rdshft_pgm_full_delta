-- Rollback de sp_ordenamiento_cerrar_wrapper (Redshift no soporta IF EXISTS en DROP PROCEDURE)
DROP PROCEDURE bdm_stage.sp_ordenamiento_cerrar(VARCHAR,VARCHAR,VARCHAR,VARCHAR,VARCHAR,VARCHAR);
