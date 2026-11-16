-- Rollback de sp_ordenamiento_scoring_cel_wrapper (Redshift no soporta IF EXISTS en DROP PROCEDURE)
DROP PROCEDURE bdm_stage.sp_ordenamiento_scoring_cel(VARCHAR,VARCHAR,VARCHAR,VARCHAR,VARCHAR,VARCHAR);
