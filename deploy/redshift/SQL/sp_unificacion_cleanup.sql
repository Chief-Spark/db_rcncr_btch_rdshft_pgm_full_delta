-- Cleanup nivel 0 - Unificacion (datos reales feature/unificacion-edf-views)
-- SLCOPRBA-1284 / SLCOPRBA-1287: promoción a QA Unificación Alpha (edf_views)
-- Fuente: edf_views | Salida: bdm_datos.unificacion_direccion
-- Reset de la tabla de salida antes de aplicar R1/R2/R3 via Framework Batch.

-- Firma Framework Batch (6 params VARCHAR): in_solicitud, in_nit_suscriptor,
-- in_path_archivo, in_nemotecnico, in_id_facturacion, in_fecha_ejecucion.
-- Los parametros no se usan; el cleanup solo trunca la salida.
CREATE OR REPLACE PROCEDURE bdm_datos.sp_unificacion_cleanup(
    in_solicitud       VARCHAR,
    in_nit_suscriptor  VARCHAR,
    in_path_archivo    VARCHAR,
    in_nemotecnico     VARCHAR,
    in_id_facturacion  VARCHAR,
    in_fecha_ejecucion VARCHAR
)
NONATOMIC
LANGUAGE plpgsql
AS $$
BEGIN

  TRUNCATE TABLE bdm_datos.unificacion_direccion;

EXCEPTION WHEN OTHERS THEN
  RAISE EXCEPTION 'sp_unificacion_cleanup failed: %', SQLERRM;
END;
$$;
-- SLCOPRBA-1355: re-DPLY DEV post DROP SCHEMA strct #256
