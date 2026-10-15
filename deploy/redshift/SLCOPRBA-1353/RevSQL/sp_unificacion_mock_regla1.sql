-- Rollback de sp_unificacion_mock_regla1 (Redshift no soporta IF EXISTS en DROP PROCEDURE)
DROP PROCEDURE bdm_datos.sp_unificacion_mock_regla1(VARCHAR,INTEGER,DATE);
