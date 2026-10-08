-- Rollback de sp_geo_exportar_insumo (Redshift no soporta IF EXISTS en DROP PROCEDURE)
-- Firma alineada al Framework_Batch (6 parametros VARCHAR) tras la Task 8.1 de
-- la spec unificacion-full-delta (antes era (VARCHAR) con in_ambiente).
DROP PROCEDURE bdm_datos.sp_geo_exportar_insumo(VARCHAR,VARCHAR,VARCHAR,VARCHAR,VARCHAR,VARCHAR);
