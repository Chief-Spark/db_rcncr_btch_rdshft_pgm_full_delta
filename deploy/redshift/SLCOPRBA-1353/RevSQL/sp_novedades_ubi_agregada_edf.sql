-- Rollback de sp_novedades_ubi_agregada_edf.sql
-- (repo pgm / db_rcncr_btch_rdshft_pgm). UTF-8 sin BOM.
-- Redshift NO soporta DROP PROCEDURE IF EXISTS: firma EXACTA (leccion #12).
-- Este SP no lleva parametros: su universo son las dos etapas de Ubicacion,
-- que ya vienen acotadas. La firma vacia tambien hay que escribirla.
DROP PROCEDURE bdm_datos.sp_novedades_ubi_agregada_edf();
