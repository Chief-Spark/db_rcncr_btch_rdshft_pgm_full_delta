-- ============================================================
-- sp_ordenamiento_scoring_tel_wrapper.sql
-- NIVEL 3 del Framework Batch, rama TEL: puntua el canal de telefonos.
--
-- Objeto en bdm_stage; idempotente (CREATE OR REPLACE PROCEDURE). NONATOMIC
-- consistente con la cadena de CALL. UTF-8 sin BOM. Nunca GRANT ... TO PUBLIC.
--
-- POR QUE EXISTE: bdm_datos.sp_ordenamiento_scoring_tel_edf esta declarado
--   SIN PARAMETROS (sp_ordenamiento_scoring_tel_edf.sql:4) y el Builder del
--   Framework renderiza SIEMPRE un CALL de seis argumentos posicionales
--   (step_function_definition_builder.py:93). Sin este wrapper el nivel muere
--   con "procedure does not exist". Mismo patron que
--   sp_geo_exportar_insumo_wrapper.sql.
--
-- POR QUE LOS CUATRO CANALES PUEDEN CORRER A LA VEZ: cada uno borra SOLO SU
--   PARTICION antes de insertar -- DELETE ... WHERE canal = 'TEL' AND
--   id_buro_persona IN (stg_ord_personas_alcance). Las cuatro escrituras sobre
--   score_ordenamiento son disjuntas y ninguna pisa a otra.
--
-- LA TRAZA NO SE PIERDE: escribe ord_control_etapa con el MISMO literal de
--   etapa que el orquestador monolitico ('scoring_tel'), de modo que las
--   consultas de DRILLDOWN_VIA_REAL.sql siguen sirviendo. La corrida se
--   recupera por lote porque corrida_id es variable local y cada nivel del
--   Framework es otra sesion del Data API.
-- ============================================================


CREATE OR REPLACE PROCEDURE bdm_stage.sp_ordenamiento_scoring_tel(
    in_solicitud        VARCHAR,   -- Framework_Batch (no usado)
    in_nit_suscriptor   VARCHAR,   -- Framework_Batch (no usado)
    in_path_archivo     VARCHAR,   -- Framework_Batch (no usado)
    in_nemotecnico      VARCHAR,   -- MODO (no usado: el alcance ya esta fijado)
    in_id_facturacion   VARCHAR,   -- LOTE (es el que localiza la corrida)
    in_fecha_ejecucion  VARCHAR    -- FECHA (no usado)
)
NONATOMIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_lote_txt   VARCHAR;
    v_lote       INTEGER;
    v_corrida_id BIGINT;
BEGIN
    v_lote_txt := bdm_datos.unif_resolver_param('LOTE', in_id_facturacion);

    IF v_lote_txt IS NULL THEN
        RAISE EXCEPTION 'ORDENAMIENTO scoring_tel: lote obligatorio, in_id_facturacion vacio';
    END IF;
    BEGIN
        v_lote := v_lote_txt::INTEGER;
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'ORDENAMIENTO scoring_tel: lote no entero: %', v_lote_txt;
    END;

    -- Mismo patron de lectura que sp_rcn_ctl_ord_abrir.sql:44-49.
    SELECT MAX(corrida_id)
      INTO v_corrida_id
      FROM bdm_datos.ord_control
     WHERE estado = 'enproceso'
       AND lote = v_lote;

    -- Morir aqui es mejor que puntuar sin traza: si no hay corrida abierta, el
    -- nivel 2 no corrio o ya la cerro, y el staging puede no existir.
    IF v_corrida_id IS NULL THEN
        RAISE EXCEPTION 'ORDENAMIENTO scoring_tel: no hay corrida abierta para el lote %. El nivel 2 sp_ordenamiento_preparar no corrio o ya cerro', v_lote;
    END IF;

    BEGIN
        CALL bdm_datos.sp_rcn_ctl_ord_traza_inicio(v_corrida_id, v_lote, 'scoring_tel');
        CALL bdm_datos.sp_ordenamiento_scoring_tel_edf();
        CALL bdm_datos.sp_rcn_ctl_ord_traza_fin(v_corrida_id, 'scoring_tel', 'completado', 0, 0);
    EXCEPTION
        WHEN OTHERS THEN
            -- El cierre va AQUI y no solo en el nivel 4: si una rama cae, el
            -- nivel 4 no llega a correr y la corrida se quedaria en
            -- 'enproceso' para siempre, envenenando el MAX(corrida_id) de la
            -- siguiente. El UPDATE va por corrida_id, asi que que lo intenten
            -- varias ramas a la vez es idempotente.
            CALL bdm_datos.sp_rcn_ctl_ord_traza_fin(
                v_corrida_id, 'scoring_tel', 'fallido', 0, 0
            );
            CALL bdm_datos.sp_rcn_ctl_ord_cerrar(
                v_corrida_id, 'fallido', NULL, 0, 0, 0
            );
            RAISE;
    END;
END;
$$;
