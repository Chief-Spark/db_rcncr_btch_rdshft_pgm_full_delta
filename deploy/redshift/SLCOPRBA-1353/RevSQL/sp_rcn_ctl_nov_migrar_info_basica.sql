-- Rollback de sp_rcn_ctl_nov_migrar_info_basica.sql
-- (repo pgm). UTF-8 sin BOM. Redshift NO soporta DROP PROCEDURE IF EXISTS:
-- firma EXACTA, lecciones #12 y #14.
DROP PROCEDURE bdm_datos.sp_rcn_ctl_nov_migrar_info_basica();
