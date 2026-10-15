-- Rollback de sp_cert_asercion_final.
-- Firma (p_alcance VARCHAR): lo invoca el script de la bateria.
-- Sin IF EXISTS y con la firma exacta (politica #12/#14).
DROP PROCEDURE bdm_datos.sp_cert_asercion_final(VARCHAR);
