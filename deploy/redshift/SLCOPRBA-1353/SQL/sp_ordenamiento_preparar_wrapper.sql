-- ============================================================
-- sp_ordenamiento_preparar_wrapper.sql
-- NIVEL 2 del Framework Batch: abre la corrida de Ordenamiento y deja el
-- insumo listo para que los cuatro canales puntuen EN PARALELO en el nivel 3.
--
-- Objeto en bdm_stage; idempotente (CREATE OR REPLACE PROCEDURE). NONATOMIC
-- consistente con la cadena de CALL. UTF-8 sin BOM. Nunca GRANT ... TO PUBLIC.
--
-- POR QUE EXISTE, y no se llama directo a los SP de etapa:
--   El Builder del Framework renderiza SIEMPRE un CALL de SEIS argumentos
--   posicionales (step_function_definition_builder.py:93), de modo que al YAML
--   solo puede entrar un SP con la firma del Framework. Mismo patron que
--   sp_geo_exportar_insumo_wrapper.sql.
--
-- QUE ETAPAS SE LLEVA: preparar, cuentas y ubicaciones. Es corte literal de
--   19_sp_ordenamiento_ciclo.sql:38-100. No se reescribe logica de negocio.
--
-- CONTROL: abre bdm_datos.ord_control con sp_rcn_ctl_ord_abrir y traza las
--   tres etapas en ord_control_etapa, igual que el orquestador monolitico.
--   La corrida queda en 'enproceso' a proposito: la cierra el nivel 4
--   (bdm_stage.sp_ordenamiento_cerrar), que es quien conoce el resultado.
--
-- SE DEJA EL STAGING EN PIE: las bdm_tempo.stg_* son tablas PERMANENTES
--   (sp_ordenamiento_preparar_insumos_edf.sql:43 y siguientes), por eso las
--   cuatro ramas del nivel 3 las leen aunque cada una sea otra sesion.
--
-- NO SUSTITUYE a bdm_datos.sp_ordenamiento_ciclo, que sigue intacto para
--   deploy.par, la bateria mock y la via manual.
-- ============================================================


CREATE OR REPLACE PROCEDURE bdm_stage.sp_ordenamiento_preparar(
    in_solicitud        VARCHAR,   -- Framework_Batch (no usado)
    in_nit_suscriptor   VARCHAR,   -- Framework_Batch (no usado)
    in_path_archivo     VARCHAR,   -- Framework_Batch (no usado)
    in_nemotecnico      VARCHAR,   -- MODO
    in_id_facturacion   VARCHAR,   -- LOTE
    in_fecha_ejecucion  VARCHAR    -- FECHA
)
NONATOMIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_modo          VARCHAR(64);
    v_lote_txt      VARCHAR;
    v_lote          INTEGER;
    v_fecha_txt     VARCHAR;
    v_fecha         DATE;
    v_wm_anterior   DATE;
    v_modo_efectivo VARCHAR(64);
    v_bootstrap     BOOLEAN := FALSE;
    v_corrida_id    BIGINT;
    v_etapa_actual  VARCHAR(30);
BEGIN
    v_modo      := bdm_datos.fw_resolver_param('MODO',  in_nemotecnico);
    v_lote_txt  := bdm_datos.unif_resolver_param('LOTE',  in_id_facturacion);
    v_fecha_txt := bdm_datos.unif_resolver_param('FECHA',
                     bdm_datos.fw_resolver_param('FECHA', in_fecha_ejecucion));

    IF v_lote_txt IS NULL THEN
        RAISE EXCEPTION 'ORDENAMIENTO preparar: lote obligatorio, in_id_facturacion vacio';
    END IF;
    BEGIN
        v_lote := v_lote_txt::INTEGER;
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'ORDENAMIENTO preparar: lote no entero: %', v_lote_txt;
    END;

    IF v_modo NOT IN ('FULL', 'DELTA') THEN
        RAISE EXCEPTION 'ORDENAMIENTO preparar: modo invalido FULL o DELTA. Slot 4 recibido: "%", traducido a: "%"', in_nemotecnico, v_modo;
    END IF;

    v_fecha := v_fecha_txt::DATE;

    SELECT MAX(watermark_nuevo)
      INTO v_wm_anterior
      FROM bdm_datos.ord_control
     WHERE estado = 'completado'
       AND watermark_nuevo IS NOT NULL;

    -- Misma regla que 19_sp_ordenamiento_ciclo.sql:70-74 y que
    -- 16_sp_unificacion_ciclo.sql:167-178: sin Watermark previo la corrida es
    -- Bootstrap, se haya pedido FULL o DELTA.
    v_modo_efectivo := v_modo;
    IF v_wm_anterior IS NULL THEN
        v_modo_efectivo := 'FULL';
        v_bootstrap := TRUE;
    END IF;

    -- UNA SOLA CORRIDA POR LOTE: la abre este nivel y la cierra el nivel 4.
    -- Los niveles 3 y 4 la recuperan por lote, porque corrida_id es variable
    -- local y cada nivel del Framework es otra sesion del Data API.
    v_corrida_id := NULL;
    CALL bdm_datos.sp_rcn_ctl_ord_abrir(
        v_modo_efectivo, v_lote, v_fecha, v_wm_anterior, v_bootstrap, v_corrida_id
    );

    BEGIN
        v_etapa_actual := 'preparar';
        CALL bdm_datos.sp_rcn_ctl_ord_traza_inicio(v_corrida_id, v_lote, 'preparar');
        CALL bdm_datos.sp_ordenamiento_preparar_insumos_edf(
            v_modo_efectivo, v_lote, v_wm_anterior
        );
        CALL bdm_datos.sp_rcn_ctl_ord_traza_fin(v_corrida_id, 'preparar', 'completado', 0, 0);

        -- Fase 2 antes de la 3: el Portafolio es insumo del vector.
        v_etapa_actual := 'cuentas';
        CALL bdm_datos.sp_rcn_ctl_ord_traza_inicio(v_corrida_id, v_lote, 'cuentas');
        CALL bdm_datos.sp_ordenamiento_cuentas_edf(v_lote);
        CALL bdm_datos.sp_rcn_ctl_ord_traza_fin(v_corrida_id, 'cuentas', 'completado', 0, 0);

        v_etapa_actual := 'ubicaciones';
        CALL bdm_datos.sp_rcn_ctl_ord_traza_inicio(v_corrida_id, v_lote, 'ubicaciones');
        CALL bdm_datos.sp_ordenamiento_ubicaciones_edf(v_lote);
        CALL bdm_datos.sp_rcn_ctl_ord_traza_fin(v_corrida_id, 'ubicaciones', 'completado', 0, 0);
    EXCEPTION
        WHEN OTHERS THEN
            IF v_etapa_actual IS NOT NULL THEN
                CALL bdm_datos.sp_rcn_ctl_ord_traza_fin(
                    v_corrida_id, v_etapa_actual, 'fallido', 0, 0
                );
            END IF;
            CALL bdm_datos.sp_rcn_ctl_ord_cerrar(
                v_corrida_id, 'fallido', NULL, 0, 0, 0
            );
            RAISE;
    END;
END;
$$;
