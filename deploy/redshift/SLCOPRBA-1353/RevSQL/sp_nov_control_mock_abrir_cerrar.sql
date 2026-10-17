-- Rollback de sp_nov_control_mock_abrir_cerrar.sql
-- (repo pgm / db_rcncr_btch_rdshft_pgm). UTF-8 sin BOM.
-- Redshift NO soporta DROP PROCEDURE IF EXISTS (syntax error at or near
-- "EXISTS"). Firma EXACTA, incluido el INOUT de salida -- lecciones #12 y #14.
-- Orden INVERSO al de creacion.
DROP PROCEDURE bdm_datos.nov_control_mock_etapa_marcar(BIGINT, INTEGER, VARCHAR, VARCHAR, BIGINT, BIGINT, BIGINT, BIGINT, BIGINT);
DROP PROCEDURE bdm_datos.nov_control_mock_cerrar(BIGINT, VARCHAR, DATE, BIGINT, BIGINT, BIGINT);
DROP PROCEDURE bdm_datos.nov_control_mock_abrir(VARCHAR, INTEGER, DATE, DATE, BOOLEAN, BIGINT);
