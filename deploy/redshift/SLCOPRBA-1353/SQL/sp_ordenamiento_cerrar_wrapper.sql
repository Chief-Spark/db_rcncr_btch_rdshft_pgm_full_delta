-- ============================================================
-- sp_ordenamiento_cerrar_wrapper.sql
-- NIVEL 4 del Framework Batch: consolida el ranking, levanta el censo de
-- alcance, suelta el staging y cierra la corrida de Ordenamiento.
--
-- Objeto en bdm_stage; idempotente (CREATE OR REPLACE PROCEDURE). NONATOMIC
-- consistente con la cadena de CALL. UTF-8 sin BOM. Nunca GRANT ... TO PUBLIC.
--
-- POR QUE EXISTE: el Builder del Framework renderiza SIEMPRE un CALL de seis
--   argumentos posicionales (step_function_definition_builder.py:93), de modo
--   que al YAML solo entra un SP con la firma del Framework.
--
-- QUE ETAPAS SE LLEVA: consolidacion y cleanup. Es corte literal de
--   19_sp_ordenamiento_ciclo.sql:122-237. No se reescribe logica de negocio.
--
-- EL CONTROL SE CONSERVA ENTERO, y es el motivo de que este nivel exista por
--   separado en vez de dejar que cada rama del nivel 3 cierre lo suyo:
--     ord_control        -> una sola fila por lote, cerrada aqui con
--                           watermark_nuevo y los tres conteos de salida
--     ord_control_etapa  -> las nueve etapas con sus literales de siempre
--     ord_alcance_censo  -> una fila por corrida, y los ocho criterios
--                           F1-01..08 dependen de ella
--
-- EL ORDEN DENTRO DE cleanup NO ES NEGOCIABLE: el censo se escribe ANTES de
--   sp_ordenamiento_drop_staging_edf, porque lee el staging y el drop lo
--   borra; los residuales de F1-05 se cuentan DESPUES, que es lo unico que ese
--   criterio puede afirmar.
--
-- NO SUSTITUYE a bdm_datos.sp_ordenamiento_ciclo, que sigue intacto para
--   deploy.par, la bateria mock y la via manual.
-- ============================================================


CREATE OR REPLACE PROCEDURE bdm_stage.sp_ordenamiento_cerrar(
    in_solicitud        VARCHAR,   -- Framework_Batch (no usado)
    in_nit_suscriptor   VARCHAR,   -- Framework_Batch (no usado)
    in_path_archivo     VARCHAR,   -- Framework_Batch (no usado)
    in_nemotecnico      VARCHAR,   -- MODO (informativo: manda el de ord_control)
    in_id_facturacion   VARCHAR,   -- LOTE (es el que localiza la corrida)
    in_fecha_ejecucion  VARCHAR    -- FECHA (no usado)
)
NONATOMIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_lote_txt      VARCHAR;
    v_lote          INTEGER;
    v_corrida_id    BIGINT;
    v_modo_efectivo VARCHAR(64);
    v_bootstrap     BOOLEAN := FALSE;
    v_wm_anterior   DATE;
    v_wm_nuevo      DATE;
    v_pers          BIGINT := 0;
    v_contactos     BIGINT := 0;
    v_scores        BIGINT := 0;
    v_etapa_actual  VARCHAR(30);
    -- F1-05: cuantas de las dieciocho stg_* siguen vivas tras el drop.
    -- Se lee a variable porque pg_tables es leader-node (ver abajo).
    v_stg_vivas     INTEGER := 0;
BEGIN
    v_lote_txt := bdm_datos.unif_resolver_param('LOTE', in_id_facturacion);

    IF v_lote_txt IS NULL THEN
        RAISE EXCEPTION 'ORDENAMIENTO cerrar: lote obligatorio, in_id_facturacion vacio';
    END IF;
    BEGIN
        v_lote := v_lote_txt::INTEGER;
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'ORDENAMIENTO cerrar: lote no entero: %', v_lote_txt;
    END;

    -- Mismo patron de lectura que sp_rcn_ctl_ord_abrir.sql:44-49.
    SELECT MAX(corrida_id)
      INTO v_corrida_id
      FROM bdm_datos.ord_control
     WHERE estado = 'enproceso'
       AND lote = v_lote;

    IF v_corrida_id IS NULL THEN
        RAISE EXCEPTION 'ORDENAMIENTO cerrar: no hay corrida abierta para el lote %. El nivel 2 sp_ordenamiento_preparar no corrio o una rama del nivel 3 ya la cerro como fallida', v_lote;
    END IF;

    -- EL MODO, EL BOOTSTRAP Y EL WATERMARK SALEN DEL CONTROL, NO DEL SLOT 4.
    -- El nivel 2 ya resolvio si la corrida era Bootstrap, y el censo tiene que
    -- registrar lo que de verdad se ejecuto. Van en SELECT aparte y no en una
    -- subconsulta: Redshift rechaza el patron correlacionado en la proyeccion.
    SELECT modo, bootstrap, watermark_anterior
      INTO v_modo_efectivo, v_bootstrap, v_wm_anterior
      FROM bdm_datos.ord_control
     WHERE corrida_id = v_corrida_id;

    BEGIN
        v_etapa_actual := 'consolidacion';
        CALL bdm_datos.sp_rcn_ctl_ord_traza_inicio(v_corrida_id, v_lote, 'consolidacion');
        CALL bdm_datos.sp_ordenamiento_consolidacion_edf();
        CALL bdm_datos.sp_rcn_ctl_ord_traza_fin(v_corrida_id, 'consolidacion', 'completado', 0, 0);

        v_etapa_actual := 'cleanup';
        CALL bdm_datos.sp_rcn_ctl_ord_traza_inicio(v_corrida_id, v_lote, 'cleanup');
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
        -- Las columnas por_* que quedan en NULL no estan sin medir: no hay con
        -- que medirlas. NULL dice "no hay senal", 0 diria "la busque y no
        -- habia". Esa diferencia ES la evidencia de F1-08.
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
               NULL, NULL, org.por_cta, NULL,
               NULL, NULL,
               NULL, GETDATE(), CURRENT_USER
          FROM ( SELECT COUNT(*)                        AS filas,
                        COUNT(DISTINCT id_buro_persona) AS personas
                   FROM bdm_tempo.stg_ord_personas_alcance ) alc
          CROSS JOIN
               ( SELECT COUNT(DISTINCT CASE WHEN origen = 'UBICACION'
                                            THEN id_buro_persona END) AS por_ubic,
                        COUNT(DISTINCT CASE WHEN origen = 'UNIFICACION'
                                            THEN id_buro_persona END) AS por_unif,
                        COUNT(DISTINCT CASE WHEN origen = 'CUENTA'
                                            THEN id_buro_persona END) AS por_cta
                   FROM bdm_tempo.stg_ord_alcance_origen ) org;

        CALL bdm_datos.sp_ordenamiento_drop_staging_edf();

        -- F1-05: despues del drop no puede quedar ninguna de las dieciocho.
        --
        -- EL CONTEO VA A UNA VARIABLE ANTES DEL UPDATE, y no dentro de el.
        -- pg_tables vive en el leader node y Redshift NO admite mezclar un
        -- catalogo de sistema con una escritura a tabla de usuario en la misma
        -- sentencia: "Specified types or functions not supported on Redshift
        -- tables". PostgreSQL la ejecuta sin una queja, de modo que el banco
        -- no la veria.
        SELECT COUNT(*) INTO v_stg_vivas
          FROM pg_tables
         WHERE schemaname = 'bdm_tempo'
           AND tablename IN (
                 'stg_contacto_canal','stg_contacto_direccion_rpu','stg_dir_conteo_persona',
                     'stg_insumo_celular','stg_insumo_direccion','stg_insumo_email',
                     'stg_insumo_telefono','stg_ord_alcance_origen',
                     'stg_ord_cta_base','stg_ord_cta_hash','stg_ord_cta_vector',
                     'stg_ord_personas_alcance','stg_ord_ubic_hash',
                     'stg_persona_dir_ganadora',
                     'stg_persona_dir_ref','stg_reporte_rpu','stg_rpu_dir_ref',
                     'stg_rpu_post_unificacion' );

        UPDATE bdm_datos.ord_alcance_censo
           SET stg_residuales = v_stg_vivas
         WHERE corrida_id = v_corrida_id;
        CALL bdm_datos.sp_rcn_ctl_ord_traza_fin(v_corrida_id, 'cleanup', 'completado', 0, 0);

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

        CALL bdm_datos.sp_rcn_ctl_ord_cerrar(
            v_corrida_id, 'completado', v_wm_nuevo, v_pers, v_contactos, v_scores
        );
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
