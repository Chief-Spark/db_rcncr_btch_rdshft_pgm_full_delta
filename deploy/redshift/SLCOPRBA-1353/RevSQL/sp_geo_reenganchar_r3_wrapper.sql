-- Rollback de sp_geo_reenganchar_r3_wrapper (Redshift no soporta IF EXISTS en DROP PROCEDURE)
DROP PROCEDURE bdm_stage.sp_geo_reenganchar_r3(VARCHAR,VARCHAR,VARCHAR,VARCHAR,VARCHAR,VARCHAR);
