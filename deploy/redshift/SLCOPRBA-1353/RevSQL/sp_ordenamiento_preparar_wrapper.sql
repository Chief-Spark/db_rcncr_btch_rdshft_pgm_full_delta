-- Rollback de sp_ordenamiento_preparar_wrapper (Redshift no soporta IF EXISTS en DROP PROCEDURE)
DROP PROCEDURE bdm_stage.sp_ordenamiento_preparar(VARCHAR,VARCHAR,VARCHAR,VARCHAR,VARCHAR,VARCHAR);
