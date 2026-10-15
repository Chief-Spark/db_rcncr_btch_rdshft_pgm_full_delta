-- ============================================================
-- sp_geo_reenganchar_r3_wrapper  (Reconocer / Enriquecimiento GEO - Regla 3)
-- Wrapper Framework Batch (task 10.1) del Reenganchador_R3.
--
-- Expone la firma estandar de 6 parametros VARCHAR que el Framework Batch
-- invoca (via CALL/run_*) y delega en el helper interno
--   bdm_datos.sp_geo_reenganchar_r3(in_lote INTEGER).
--
-- Objeto en bdm_stage (schema de entrada del Framework Batch); idempotente
-- (CREATE OR REPLACE PROCEDURE). NONATOMIC consistente con la cadena de CALL
-- (el helper invoca la Regla 3, declarada NONATOMIC; mezclar modos produce
-- P0001). UTF-8 sin BOM. Nunca GRANT ... TO PUBLIC.
--
-- Mapeo de parametros (Req 8.1, 8.2, 8.3):
--   El reenganche condicional de la Regla 3 opera sobre un Lote ya cargado en
--   geo_atributos y NO requiere ruta S3 (lee coordenadas de geo_atributos).
--   Solo necesita la referencia del Lote, que el batch transporta en
--   in_nemotecnico (patron "nemotecnico"=identificador logico):
--     in_solicitud       -> no usado
--     in_nit_suscriptor  -> no usado
--     in_path_archivo    -> no usado
--     in_nemotecnico     -> referencia del Lote (entero como texto) -> in_lote
--     in_id_facturacion  -> no usado
--     in_fecha_ejecucion -> no usado
--
--   El Lote se parsea de forma segura a INTEGER; si no viene un entero valido
--   el wrapper aborta identificando el valor recibido.
--
-- Ref: .kiro/specs/geo-enriquecimiento-regla3/design.md
--      (Contrato del Framework Batch (6 parametros) / Reenganchador_R3 - sp_geo_reenganchar_r3)
--      Requisitos: 8.1, 8.2, 8.3
-- ============================================================

CREATE OR REPLACE PROCEDURE bdm_stage.sp_geo_reenganchar_r3(
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
    RAISE EXCEPTION 'sp_geo_reenganchar_r3_wrapper: in_nemotecnico no contiene un Lote entero valido (recibido: %)', in_nemotecnico;
  END IF;
  v_lote := TRIM(in_nemotecnico)::INTEGER;

  CALL bdm_datos.sp_geo_reenganchar_r3(v_lote);

EXCEPTION WHEN OTHERS THEN
  RAISE EXCEPTION 'sp_geo_reenganchar_r3_wrapper failed: %', SQLERRM;
END;
$$;
-- SLCOPRBA-1355: re-DPLY DEV post DROP SCHEMA strct #256
