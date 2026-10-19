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
    v_modo          VARCHAR(64);
    v_lote_txt      VARCHAR;
    v_lote          INTEGER;
    v_fecha_txt     VARCHAR;
    v_fecha         DATE;
    v_wm_anterior   DATE;
    v_modo_efectivo VARCHAR(64);
    v_bootstrap     BOOLEAN := FALSE;
    v_corrida_id    BIGINT;
    v_wm_nuevo      DATE;
    v_pers          BIGINT := 0;
    v_contactos     BIGINT := 0;
    v_scores        BIGINT := 0;
    v_etapa_actual  VARCHAR(30);
    -- F1-05: cuantas de las catorce stg_* siguen vivas tras el drop.
    -- Se lee a variable porque pg_tables es leader-node (ver abajo).
    v_stg_vivas     INTEGER := 0;
BEGIN
    v_modo      := bdm_datos.fw_resolver_param('MODO',  in_nemotecnico);
    v_lote_txt  := bdm_datos.unif_resolver_param('LOTE',  in_id_facturacion);
    v_fecha_txt := bdm_datos.unif_resolver_param('FECHA',
                     bdm_datos.fw_resolver_param('FECHA', in_fecha_ejecucion));

    IF v_lote_txt IS NULL THEN
        RAISE EXCEPTION 'ORDENAMIENTO: lote obligatorio (in_id_facturacion vacio)';
    END IF;
    BEGIN
        v_lote := v_lote_txt::INTEGER;
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'ORDENAMIENTO: lote no entero: %', v_lote_txt;
    END;

    IF v_modo NOT IN ('FULL', 'DELTA') THEN
        RAISE EXCEPTION 'ORDENAMIENTO: modo invalido (FULL|DELTA). Slot 4 recibido: "%", traducido a: "%"', in_nemotecnico, v_modo;
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
        -- ------------------------------------------------------------
        -- SLCOPRBA-1355 -- CENSO DE ALCANCE (Fase 1, criterios F1-01..08).
        --
        -- Va AQUI y no mas abajo porque lee el staging, y la llamada siguiente
        -- lo borra. Los residuales se cuentan DESPUES del drop, que es lo unico
        -- que F1-05 puede afirmar.
        --
        -- CONTEOS MATERIALIZADOS Y UNIDOS CON CROSS JOIN, no subconsultas en la
        -- lista del SELECT. Redshift rechaza ese patron con
        -- "XX000: correlated subquery pattern is not supported", y ademas un
        -- SELECT sin FROM que lee tablas de usuario mezcla leader y compute.
        -- Es la salida que ya uso NOV-UB-14 despues del job #407.
        --
        -- Las cuatro columnas por_* que quedan en NULL no estan sin medir: no
        -- hay con que medirlas. El legado detecta seis tipos de cambio y
        -- nuestro alcance cubre dos; ubicacion_estandarizada no tiene fecha ni
        -- lote, 'bloqueado' es una bandera sin fecha y no hay tabla de cuentas.
        -- NULL dice "no hay senal", 0 diria "la busque y no habia". Esa
        -- diferencia ES la evidencia de F1-08.
        -- ------------------------------------------------------------
        INSERT INTO bdm_datos.ord_alcance_censo (
            corrida_id, lote, modo, watermark_usado, watermark_origen,
            alcance_filas, alcance_personas,
            por_ubicacion, por_unificacion,
            por_estandarizacion, por_bloqueo, por_cuenta, por_comportamiento,
            fuera_ventana_total, fuera_ventana_dentro,
            stg_residuales, fecha_hora, usuario_bd
        )
        SELECT v_corrida_id, v_lote, v_modo_efectivo, v_wm_anterior,
               CASE WHEN v_bootstrap THEN 'BOOTSTRAP' ELSE 'CONTROL' END,
               alc.filas, alc.personas, org.por_ubic, org.por_unif,
               NULL, NULL, NULL, NULL,
               NULL, NULL,
               NULL, GETDATE(), CURRENT_USER
          FROM ( SELECT COUNT(*)                        AS filas,
                        COUNT(DISTINCT id_buro_persona) AS personas
                   FROM bdm_tempo.stg_ord_personas_alcance ) alc
          CROSS JOIN
               ( SELECT COUNT(DISTINCT CASE WHEN origen = 'UBICACION'
                                            THEN id_buro_persona END) AS por_ubic,
                        COUNT(DISTINCT CASE WHEN origen = 'UNIFICACION'
                                            THEN id_buro_persona END) AS por_unif
                   FROM bdm_tempo.stg_ord_alcance_origen ) org;

        CALL bdm_datos.sp_ordenamiento_drop_staging_edf();

        -- F1-05: despues del drop no puede quedar ninguna de las catorce.
        --
        -- EL CONTEO VA A UNA VARIABLE ANTES DEL UPDATE, y no dentro de el.
        -- pg_tables vive en el leader node y Redshift NO admite mezclar un
        -- catalogo de sistema con una escritura a tabla de usuario en la misma
        -- sentencia: "Specified types or functions not supported on Redshift
        -- tables". Es la misma trampa que ya documenta CA-T03 en
        -- sp_cert_evaluar_criterios_ord_mock, y PostgreSQL la ejecuta sin una
        -- queja, de modo que el banco no la veria.
        SELECT COUNT(*) INTO v_stg_vivas
          FROM pg_tables
         WHERE schemaname = 'bdm_tempo'
           AND tablename IN (
                 'stg_contacto_canal','stg_contacto_direccion_rpu','stg_dir_conteo_persona',
                     'stg_insumo_celular','stg_insumo_direccion','stg_insumo_email',
                     'stg_insumo_telefono','stg_ord_alcance_origen',
                     'stg_ord_personas_alcance','stg_persona_dir_ganadora',
                     'stg_persona_dir_ref','stg_reporte_rpu','stg_rpu_dir_ref',
                     'stg_rpu_post_unificacion' );

        UPDATE bdm_datos.ord_alcance_censo
           SET stg_residuales = v_stg_vivas
         WHERE corrida_id = v_corrida_id;
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
