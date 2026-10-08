-- ============================================================
-- sp_geo_ciclo_lote_wrapper  (Reconocer / Enriquecimiento GEO - Regla 3)
-- Wrapper Framework Batch (task 10.1) del Orquestador SQL del ciclo GEO.
--
-- Expone la firma estandar de 6 parametros VARCHAR que el Framework Batch
-- invoca (via CALL/run_*) y delega en el helper interno
--   bdm_datos.sp_geo_ciclo_lote(in_lote INTEGER,
--                               in_s3_path_georef VARCHAR,
--                               in_s3_path_distancias VARCHAR).
--
-- Objeto en bdm_stage (schema de entrada del Framework Batch); idempotente
-- (CREATE OR REPLACE PROCEDURE). NONATOMIC consistente con la cadena de CALL
-- (el helper encadena COPY/UNLOAD via los Cargadores; mezclar modos produce
-- P0001). UTF-8 sin BOM. Nunca GRANT ... TO PUBLIC.
--
-- Mapeo de parametros (Req 8.1, 8.2, 8.3):
--   El ciclo GEO se dispara en la malla DIFERIDA, gatillada por la
--   notificacion de la orquestacion externa (SQS/Lambda ResultTransfer) que
--   entrega la referencia del Lote y las DOS rutas S3 de las salidas de
--   ArcGIS_Externo (GEOCODE 1:1 y DISTANCIAS 1:N). El Framework Batch
--   transporta ese payload en sus 6 slots genericos; este wrapper los mapea a
--   los parametros reales del helper:
--     in_solicitud       -> no usado
--     in_nit_suscriptor  -> no usado
--     in_path_archivo    -> ruta S3 de la Salida_Georreferenciacion (GEOCODE) -> in_s3_path_georef
--     in_nemotecnico     -> referencia del Lote (entero como texto)           -> in_lote
--     in_id_facturacion  -> ruta S3 de la Salida_Distancias (DISTANCIAS)      -> in_s3_path_distancias
--     in_fecha_ejecucion -> no usado (el ambiente/fecha se resuelven del snapshot en geo_lote_control)
--
--   Justificacion del mapeo: el Framework Batch solo ofrece un slot natural de
--   "path" (in_path_archivo); como el ciclo necesita DOS rutas, se reutiliza
--   in_id_facturacion como segundo path (distancias) e in_nemotecnico como
--   portador del Lote (patron de "nemotecnico"=identificador logico ya usado
--   en el batch). El Lote se parsea de forma segura a INTEGER; si no viene un
--   entero valido el wrapper aborta identificando el valor recibido.
--
-- Ref: .kiro/specs/geo-enriquecimiento-regla3/design.md
--      (Contrato del Framework Batch (6 parametros) / Orquestador SQL - sp_geo_ciclo_lote)
--      Requisitos: 8.1, 8.2, 8.3
-- ============================================================

CREATE OR REPLACE PROCEDURE bdm_stage.sp_geo_ciclo_lote(
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
DECLARE
  v_lote INTEGER;
BEGIN

  -- Parseo seguro del Lote (in_nemotecnico -> INTEGER).
  IF in_nemotecnico IS NULL OR TRIM(in_nemotecnico) !~ '^[0-9]+$' THEN
    RAISE EXCEPTION 'sp_geo_ciclo_lote_wrapper: in_nemotecnico no contiene un Lote entero valido (recibido: %)', in_nemotecnico;
  END IF;
  v_lote := TRIM(in_nemotecnico)::INTEGER;

  -- in_path_archivo -> ruta GEOCODE ; in_id_facturacion -> ruta DISTANCIAS.
  CALL bdm_datos.sp_geo_ciclo_lote(v_lote, in_path_archivo, in_id_facturacion);

EXCEPTION WHEN OTHERS THEN
  RAISE EXCEPTION 'sp_geo_ciclo_lote_wrapper failed: %', SQLERRM;
END;
$$;
-- SLCOPRBA-1355: re-DPLY DEV post DROP SCHEMA strct #256
