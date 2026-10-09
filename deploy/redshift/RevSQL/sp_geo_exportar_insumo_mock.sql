-- Rollback de sp_geo_exportar_insumo_mock (Redshift no soporta IF EXISTS en
-- DROP PROCEDURE, leccion #12). Firma alineada al Framework_Batch
-- (6 parametros VARCHAR), igual que el exportador real (leccion #14).
DROP PROCEDURE bdm_datos.sp_geo_exportar_insumo_mock(VARCHAR,VARCHAR,VARCHAR,VARCHAR,VARCHAR,VARCHAR);
