-- Orquestador Regla 3
-- Escenario: CALL R3 geo
-- Fuente: edf_views -> bdm_tempo.v_xpm_* | Salida: bdm_datos.unificacion_direccion
-- Generado: tools/gen_unificacion_sps_por_escenario.py

-- Firma Framework Batch (6 params VARCHAR): in_solicitud, in_nit_suscriptor,
-- in_path_archivo, in_nemotecnico, in_id_facturacion, in_fecha_ejecucion.
-- Los parametros no se usan en la logica de unificacion (procesa edf_views completo).
CREATE OR REPLACE PROCEDURE bdm_datos.sp_unificacion_regla3(
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
  -- (Tarea 6.1) El orquestador maestro re-emite en los slots 4/5/6 del
  -- Framework_Batch: in_nemotecnico=Modo_Corrida, in_id_facturacion=Lote_Corrida,
  -- in_fecha_ejecucion=Watermark (frontera inferior inclusiva de la ventana
  -- DELTA; NO es la Fecha_Proceso). Se derivan aqui y se propagan a
  -- preparar_insumo(p_modo, p_watermark) y a cada escenario(p_modo, p_lote);
  -- ningun escenario re-parsea el Framework_Batch.
  -- SLCOPRBA-1398: SE DECLARAN SIN VALOR Y SE ASIGNAN EN EL CUERPO.
  -- Antes se derivaban aqui mismo, en la zona de declaracion. Eso parece
  -- inocente y no lo es: un valor que no castea revienta ANTES de BEGIN, donde
  -- no entra un IF, ni un EXCEPTION, ni nada. Con el Framework Batch pasaba
  -- siempre -- el slot 6 trae 'YYMM' y no una fecha --, de modo que estos tres
  -- SP no podian correr bajo el orquestador, pasara lo que pasara.
  -- Comprobado en DEV: 'invalid input syntax for type date: "0826"' y '"2610"'.
  p_modo      VARCHAR(64);
  p_lote      INTEGER;
  p_watermark DATE;
  v_aux       VARCHAR(32);
BEGIN

  -- El slot 4 trae el MNEMOTECNICO, no el modo
  -- (tf_fw_dynbtch, step_function_definition_builder.py:93).
  p_modo := NULLIF(bdm_datos.fw_resolver_param('MODO', in_nemotecnico), '');
  IF p_modo IS NULL THEN
    p_modo := 'FULL';   -- FULL por defecto (no romper lo desplegado, Req 10.1).
  END IF;

  p_lote := CAST(NULLIF(bdm_datos.fw_resolver_param('LOTE', in_id_facturacion), '') AS INTEGER);

  -- El slot 6 trae 'YYMM'. Aqui es el WATERMARK, no la Fecha_Proceso (ver la
  -- cabecera): NULL es legitimo y significa que no hay frontera inferior.
  v_aux := NULLIF(bdm_datos.fw_resolver_param('FECHA', in_fecha_ejecucion), '');
  p_watermark := CAST(v_aux AS DATE);

  CALL bdm_datos.sp_unificacion_r3_esc1_geo_misma_via_puerta_cercana(p_modo, p_lote);

EXCEPTION WHEN OTHERS THEN
  RAISE EXCEPTION 'sp_unificacion_regla3 failed: %', SQLERRM;
END;
$$;
-- SLCOPRBA-1355: re-DPLY DEV post DROP SCHEMA strct #256
