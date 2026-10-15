-- ============================================================
-- 19_sp_ordenamiento_ciclo.sql
-- Orquestador maestro Ordenamiento FULL/DELTA + observabilidad.
-- Firma Framework_Batch 6 VARCHAR (slots 4/5/6 = MODO/LOTE/FECHA).
-- Reutiliza unif_resolver_param. NONATOMIC. UTF-8 sin BOM.
-- ============================================================

CREATE SCHEMA IF NOT EXISTS bdm_datos;

CREATE OR REPLACE PROCEDURE bdm_datos.sp_ordenamiento_ciclo(
    in_solicitud        VARCHAR,
    in_nit_suscriptor   VARCHAR,
    in_path_archivo     VARCHAR,
    in_nemotecnico      VARCHAR,   -- MODO
    in_id_facturacion   VARCHAR,   -- LOTE
    in_fecha_ejecucion  VARCHAR    -- FECHA
)
NONATOMIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_modo          VARCHAR(10);
    v_lote_txt      VARCHAR;
    v_lote          INTEGER;
    v_fecha_txt     VARCHAR;
    v_fecha         DATE;
    v_wm_anterior   DATE;
    v_modo_efectivo VARCHAR(10);
    v_bootstrap     BOOLEAN := FALSE;
    v_corrida_id    BIGINT;
    v_wm_nuevo      DATE;
    v_pers          BIGINT := 0;
    v_contactos     BIGINT := 0;
    v_scores        BIGINT := 0;
    v_etapa_actual  VARCHAR(30);
BEGIN
    v_modo      := bdm_datos.unif_resolver_param('MODO',  in_nemotecnico);
    v_lote_txt  := bdm_datos.unif_resolver_param('LOTE',  in_id_facturacion);
    v_fecha_txt := bdm_datos.unif_resolver_param('FECHA', in_fecha_ejecucion);

    IF v_lote_txt IS NULL THEN
        RAISE EXCEPTION 'ORDENAMIENTO: lote obligatorio (in_id_facturacion vacio)';
    END IF;
    BEGIN
        v_lote := v_lote_txt::INTEGER;
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'ORDENAMIENTO: lote no entero: %', v_lote_txt;
    END;

    IF v_modo NOT IN ('FULL', 'DELTA') THEN
        RAISE EXCEPTION 'ORDENAMIENTO: modo invalido (FULL|DELTA): %', v_modo;
    END IF;

    v_fecha := v_fecha_txt::DATE;

    SELECT MAX(watermark_nuevo)
      INTO v_wm_anterior
      FROM bdm_datos.ord_control
     WHERE estado = 'completado'
       AND watermark_nuevo IS NOT NULL;

    v_modo_efectivo := v_modo;
    IF v_wm_anterior IS NULL AND v_modo = 'DELTA' THEN
        v_modo_efectivo := 'FULL';
        v_bootstrap := TRUE;
    END IF;

    v_corrida_id := NULL;
    CALL bdm_datos.ord_control_abrir(
        v_modo_efectivo, v_lote, v_fecha, v_wm_anterior, v_bootstrap, v_corrida_id
    );

    BEGIN
        v_etapa_actual := 'preparar';
        CALL bdm_datos.ord_traza_inicio(v_corrida_id, v_lote, 'preparar');
        CALL bdm_datos.sp_ordenamiento_preparar_insumos_edf(
            v_modo_efectivo, v_lote, v_wm_anterior
        );
        CALL bdm_datos.ord_traza_fin(v_corrida_id, 'preparar', 'completado', 0, 0);

        v_etapa_actual := 'scoring_dir';
        CALL bdm_datos.ord_traza_inicio(v_corrida_id, v_lote, 'scoring_dir');
        CALL bdm_datos.sp_ordenamiento_scoring_dir_edf();
        CALL bdm_datos.ord_traza_fin(v_corrida_id, 'scoring_dir', 'completado', 0, 0);

        v_etapa_actual := 'scoring_tel';
        CALL bdm_datos.ord_traza_inicio(v_corrida_id, v_lote, 'scoring_tel');
        CALL bdm_datos.sp_ordenamiento_scoring_tel_edf();
        CALL bdm_datos.ord_traza_fin(v_corrida_id, 'scoring_tel', 'completado', 0, 0);

        v_etapa_actual := 'scoring_cel';
        CALL bdm_datos.ord_traza_inicio(v_corrida_id, v_lote, 'scoring_cel');
        CALL bdm_datos.sp_ordenamiento_scoring_cel_edf();
        CALL bdm_datos.ord_traza_fin(v_corrida_id, 'scoring_cel', 'completado', 0, 0);

        v_etapa_actual := 'scoring_ema';
        CALL bdm_datos.ord_traza_inicio(v_corrida_id, v_lote, 'scoring_ema');
        CALL bdm_datos.sp_ordenamiento_scoring_ema_edf();
        CALL bdm_datos.ord_traza_fin(v_corrida_id, 'scoring_ema', 'completado', 0, 0);

        v_etapa_actual := 'consolidacion';
        CALL bdm_datos.ord_traza_inicio(v_corrida_id, v_lote, 'consolidacion');
        CALL bdm_datos.sp_ordenamiento_consolidacion_edf();
        CALL bdm_datos.ord_traza_fin(v_corrida_id, 'consolidacion', 'completado', 0, 0);

        v_etapa_actual := 'cleanup';
        CALL bdm_datos.ord_traza_inicio(v_corrida_id, v_lote, 'cleanup');
        -- Conteos antes de dropear staging
        SELECT COUNT(*) INTO v_pers FROM bdm_tempo.stg_ord_personas_alcance;
        SELECT COUNT(*) INTO v_contactos FROM bdm_tempo.stg_insumo_direccion;
        SELECT COUNT(*) INTO v_scores
          FROM bdm_datos.score_ordenamiento s
         WHERE s.id_buro_persona IN (
           SELECT id_buro_persona FROM bdm_tempo.stg_ord_personas_alcance
         );
        CALL bdm_datos.sp_ordenamiento_drop_staging_edf();
        CALL bdm_datos.ord_traza_fin(v_corrida_id, 'cleanup', 'completado', 0, 0);

        IF v_modo_efectivo = 'FULL' THEN
            SELECT MAX(rpu.fecha_relacion_persona_ubicaci)
              INTO v_wm_nuevo
              FROM bdm_tempo.v_xpm_relacion_persona_ubicacion rpu
             WHERE rpu.fecha_relacion_persona_ubicaci IS NOT NULL;
        ELSE
            SELECT MAX(rpu.fecha_relacion_persona_ubicaci)
              INTO v_wm_nuevo
              FROM bdm_tempo.v_xpm_relacion_persona_ubicacion rpu
             WHERE rpu.fecha_relacion_persona_ubicaci IS NOT NULL
               AND rpu.fecha_relacion_persona_ubicaci >= v_wm_anterior;
            IF v_wm_nuevo IS NULL THEN
                v_wm_nuevo := v_wm_anterior;
            ELSE
                v_wm_nuevo := GREATEST(v_wm_anterior, v_wm_nuevo);
            END IF;
        END IF;

        CALL bdm_datos.ord_control_cerrar(
            v_corrida_id, 'completado', v_wm_nuevo, v_pers, v_contactos, v_scores
        );
    EXCEPTION
        WHEN OTHERS THEN
            IF v_etapa_actual IS NOT NULL THEN
                CALL bdm_datos.ord_traza_fin(
                    v_corrida_id, v_etapa_actual, 'fallido', 0, 0
                );
            END IF;
            CALL bdm_datos.ord_control_cerrar(
                v_corrida_id, 'fallido', NULL, 0, 0, 0
            );
            RAISE;
    END;
END;
$$;

-- SLCOPRBA-1355: re-DPLY DEV post DROP SCHEMA strct #256
