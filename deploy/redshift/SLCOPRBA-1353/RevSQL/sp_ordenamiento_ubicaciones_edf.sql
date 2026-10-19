-- Rollback: Fase 3 del Ordenamiento (hash de atributos de ubicacion).
-- Redshift no admite DROP PROCEDURE IF EXISTS (leccion #12); la firma se
-- repite EXACTA, como en el CREATE (leccion #14).
DROP PROCEDURE bdm_datos.sp_ordenamiento_ubicaciones_edf(INTEGER);
