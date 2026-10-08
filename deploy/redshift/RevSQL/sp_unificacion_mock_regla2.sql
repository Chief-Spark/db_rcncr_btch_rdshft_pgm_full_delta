-- Rollback de sp_unificacion_mock_regla2 (Redshift no soporta IF EXISTS en DROP PROCEDURE)
DROP PROCEDURE bdm_datos.sp_unificacion_mock_regla2(VARCHAR,INTEGER,DATE);
