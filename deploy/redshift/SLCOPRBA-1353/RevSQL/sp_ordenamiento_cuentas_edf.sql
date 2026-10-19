-- Rollback: Fase 2 del Ordenamiento (atributos de cuenta y su hash).
-- Sin IF EXISTS (leccion #12); la firma se repite EXACTA (leccion #14).
DROP PROCEDURE bdm_datos.sp_ordenamiento_cuentas_edf(INTEGER);
