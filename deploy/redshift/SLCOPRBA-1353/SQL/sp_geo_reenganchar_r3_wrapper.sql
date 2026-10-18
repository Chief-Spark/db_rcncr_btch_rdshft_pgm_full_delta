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
  v_lote     INTEGER;
  v_lote_txt VARCHAR(32);
BEGIN

  -- SLCOPRBA-1398: EL LOTE VIENE EN EL SLOT 5, NO EN EL 4.
  -- El Framework arma la llamada como
  --   CALL <sp>(execution_id, nit, folder_path, client_id, billing_id, year_month)
  -- (tf_fw_dynbtch, step_function_definition_builder.py:93), de modo que el
  -- slot 4 trae el MNEMOTECNICO y el Lote va en in_id_facturacion. Leerlo del
  -- 4, como se hacia aqui, hacia imposible invocar este wrapper desde el
  -- Framework: abortaba siempre.
  --
  -- Se intenta primero el slot 5 y DESPUES el 4, no al reves: asi sigue
  -- funcionando cualquier llamada manual que ya pusiera el Lote en el 4.
  v_lote_txt := bdm_datos.fw_resolver_param('LOTE', in_id_facturacion);
  IF v_lote_txt = '' THEN
    v_lote_txt := bdm_datos.fw_resolver_param('LOTE', in_nemotecnico);
  END IF;

  IF v_lote_txt = '' THEN
    RAISE EXCEPTION 'sp_geo_reenganchar_r3_wrapper: no se encontro un Lote entero ni en in_id_facturacion ni en in_nemotecnico (recibidos: "%" y "%")', in_id_facturacion, in_nemotecnico;
  END IF;
  v_lote := v_lote_txt::INTEGER;

  CALL bdm_datos.sp_geo_reenganchar_r3(v_lote);

EXCEPTION WHEN OTHERS THEN
  RAISE EXCEPTION 'sp_geo_reenganchar_r3_wrapper failed: %', SQLERRM;
END;
$$;
-- SLCOPRBA-1355: re-DPLY DEV post DROP SCHEMA strct #256
