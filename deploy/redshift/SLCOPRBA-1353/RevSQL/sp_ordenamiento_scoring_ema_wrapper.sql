-- Rollback de sp_ordenamiento_scoring_ema_wrapper (Redshift no soporta IF EXISTS en DROP PROCEDURE)
DROP PROCEDURE bdm_stage.sp_ordenamiento_scoring_ema(VARCHAR,VARCHAR,VARCHAR,VARCHAR,VARCHAR,VARCHAR);
