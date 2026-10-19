-- ============================================================
-- sp_ordenamiento_ejecucion_mock.sql
-- Orquestador del Ordenamiento MOCK FULL/DELTA con observabilidad en bdm_stage.
-- Firma 6 VARCHAR alineada a Framework_Batch / sp_ordenamiento_ciclo (SIN CAMBIO).
-- Codificacion: UTF-8 sin BOM. Nunca GRANT ... TO PUBLIC.
-- ------------------------------------------------------------
-- SLCOPRBA-1355: el Ordenamiento mock pasa a CONSUMIR LO QUE ENTREGA LA
-- UNIFICACION, con el MISMO universo y la MISMA logica que la via real.
--
-- QUE HACIA ANTES (y por que no servia para certificar):
--   llamaba a sp_ordenamiento_cargar_seed_mock + sp_ordenamiento_validar_mock.
--   Ese par es un fixture AUTONOMO: trunca bdm_stage.mock_ord_* y escribe
--   scores PRECALCULADOS a mano, que luego valida. Nunca leia
--   unificacion_direccion_mock y nunca ejecutaba la formula de scoring real,
--   de modo que no certificaba la logica que corre en produccion.
--
-- QUE HACE AHORA:
--   encadena exactamente la misma secuencia que sp_ordenamiento_ciclo:
--     preparar -> scoring DIR/TEL/CEL/EMA -> consolidacion -> cleanup
--   La UNICA pieza propia del mock es sp_ordenamiento_preparar_insumos_mock,
--   espejo generado del preparar real que solo cambia las FUENTES (v_mock_* y
--   unificacion_direccion_mock) y materializa las MISMAS tablas bdm_tempo.stg_*.
--   Los SP de scoring y consolidacion son los REALES, sin una sola modificacion:
--   no reciben parametros, leen stg_insumo_* y escriben score_ordenamiento /
--   rpu_orden_prioridad.
--
-- POR QUE ESCRIBE EN LAS TABLAS DE SALIDA REALES:
--   decision tomada con el equipo. Parametrizar el destino obligaria a cambiar
--   la firma de los 6 SP de scoring (trampa de la sobrecarga de Redshift,
--   leccion #14) y espejarlos duplicaria la formula en 6 archivos. En
--   produccion la via mock jamas se ejecuta.
--   No hace falta TRUNCATE: los SP de scoring borran de forma ACOTADA
--     DELETE ... WHERE canal = 'X' AND id_buro_persona IN (stg_ord_personas_alcance)
--   y el alcance mock solo contiene id_buro_persona de semillas (91xxxx/92xxxx),
--   que no colisionan con los reales (FNV_HASH del pin, valores de 64 bits). El
--   FULL mock, cuyo alcance es todo el universo mock, reescribe por completo lo
--   suyo sin tocar lo real.
--
-- sp_ordenamiento_cargar_seed_mock y sp_ordenamiento_validar_mock se RETIRARON
-- (SLCOPRBA-1355). Dejaron de ser una verificacion independiente en cuanto
-- reset_mock.sql:51-57 empezo a truncar bdm_stage.mock_ord_*: sobre tablas
-- vacias, CA-O03, CA-O05 y CA-O07 son predicados de "cero filas malas" y daban
-- PASSED. Eran una trampa de falso verde, desplegada en cada release y sin un
-- solo llamador. Lo que pretendian cubrir lo cubre ahora el tablero de 90
-- criterios (cert_criterio_ord), que mide la formula real.
-- La evidencia del E2E sale de los gates sobre score_ordenamiento y
-- rpu_orden_prioridad.
--
-- NONATOMIC en toda la cadena (leccion #13).
-- Rollback: DROP PROCEDURE nombre(<firma exacta>) SIN IF EXISTS (#12/#14).
-- ============================================================

CREATE OR REPLACE PROCEDURE bdm_datos.sp_ordenamiento_ejecucion_mock(
    in_solicitud        VARCHAR,
    in_nit_suscriptor   VARCHAR,
    in_path_archivo     VARCHAR,
    in_nemotecnico      VARCHAR,
    in_id_facturacion   VARCHAR,
    in_fecha_ejecucion  VARCHAR
)
NONATOMIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_modo          VARCHAR(64);
    v_modo_efectivo VARCHAR(64);
    v_bootstrap     BOOLEAN := FALSE;
    v_lote_txt      VARCHAR;
    v_lote          INTEGER;
    v_fecha_txt     VARCHAR;
    v_wm_anterior   DATE;
    v_wm_nuevo      DATE;
    v_inicio        TIMESTAMP;
    v_corrida       BIGINT;
    v_personas      BIGINT := 0;
    v_contactos     BIGINT := 0;
    v_scores        BIGINT := 0;
    v_etapa_actual  VARCHAR(30);
    -- F1-05: cuantas de las catorce stg_* siguen vivas tras el drop.
    -- Se lee a variable porque pg_tables es leader-node (ver abajo).
    v_stg_vivas     INTEGER := 0;
BEGIN
    -- SLCOPRBA-1398: el slot 4 del Framework trae el MNEMOTECNICO, no el
    -- modo (step_function_definition_builder.py:93). fw_resolver_param lo
    -- traduce; devuelve cadena vacia si no lo reconoce, y la validacion de
    -- abajo aborta nombrando el valor crudo.
    v_modo := bdm_datos.fw_resolver_param('MODO', in_nemotecnico);
    v_lote_txt := NULLIF(TRIM(in_id_facturacion), '');
    IF v_lote_txt IS NULL THEN
        RAISE EXCEPTION 'ORD MOCK: lote obligatorio';
    END IF;
    v_lote := v_lote_txt::INTEGER;
    -- El slot 6 trae 'YYMM', no una fecha. fw_resolver_param lo lleva al
    -- primer dia del mes; si no es derivable devuelve vacio y aqui se cae a
    -- CURRENT_DATE, que es el default de siempre.
    v_fecha_txt := NULLIF(bdm_datos.fw_resolver_param('FECHA', in_fecha_ejecucion), '');
    IF v_fecha_txt IS NULL THEN
        v_fecha_txt := TO_CHAR(CURRENT_DATE, 'YYYY-MM-DD');
    END IF;

    IF v_modo NOT IN ('FULL', 'DELTA') THEN
        RAISE EXCEPTION 'ORD MOCK: modo invalido. Slot 4 recibido: "%", traducido a: "%"', in_nemotecnico, v_modo;
    END IF;

    -- Watermark y Bootstrap, sobre el control MOCK del Ordenamiento.
    -- Si no hay corrida mock 'completado' previa se fuerza FULL aunque se pida
    -- DELTA: sin frontera no hay ventana que aplicar.
    SELECT MAX(watermark_nuevo) INTO v_wm_anterior
      FROM bdm_stage.mock_ord_control
     WHERE estado = 'completado';

    IF v_wm_anterior IS NULL THEN
        v_modo_efectivo := 'FULL';
        v_bootstrap     := TRUE;
    ELSE
        v_modo_efectivo := v_modo;
        v_bootstrap     := FALSE;
    END IF;

    v_inicio := GETDATE();
    INSERT INTO bdm_stage.mock_ord_control (
        lote, modo, bootstrap, fecha_proceso, watermark_anterior,
        estado, fecha_hora_inicio, usuario_bd
    )
    VALUES (
        v_lote, v_modo_efectivo, v_bootstrap, v_fecha_txt::DATE, v_wm_anterior,
        'enproceso', v_inicio, CURRENT_USER
    );
    SELECT MAX(corrida_id) INTO v_corrida
      FROM bdm_stage.mock_ord_control
     WHERE fecha_hora_inicio = v_inicio AND lote = v_lote;

    BEGIN
    -- ---- preparar ----------------------------------------------------------
    v_etapa_actual := 'preparar';
    INSERT INTO bdm_stage.mock_ord_control_etapa
        (corrida_id, lote, etapa, estado, fecha_hora_inicio, usuario_bd)
    VALUES (v_corrida, v_lote, 'preparar', 'enproceso', GETDATE(), CURRENT_USER);

    CALL bdm_datos.sp_ordenamiento_preparar_insumos_mock(v_modo_efectivo, v_lote, v_wm_anterior);

    SELECT COUNT(*) INTO v_personas  FROM bdm_tempo.stg_ord_personas_alcance;
    SELECT COUNT(*) INTO v_contactos FROM bdm_tempo.stg_contacto_canal;

    UPDATE bdm_stage.mock_ord_control_etapa
       SET estado = 'completado', fecha_hora_fin = GETDATE(),
           filas_entrada = v_personas, filas_salida = v_contactos
     WHERE corrida_id = v_corrida AND etapa = 'preparar';

    -- ---- ubicaciones (Fase 3) ---------------------------------------------
    -- Va DESPUES de preparar porque lee stg_insumo_direccion, y ANTES del
    -- scoring porque es la fase que la precede en el legado.
    v_etapa_actual := 'ubicaciones';
    INSERT INTO bdm_stage.mock_ord_control_etapa
        (corrida_id, lote, etapa, estado, fecha_hora_inicio, usuario_bd)
    VALUES (v_corrida, v_lote, 'ubicaciones', 'enproceso', GETDATE(), CURRENT_USER);

    CALL bdm_datos.sp_ordenamiento_ubicaciones_mock(v_lote);

    UPDATE bdm_stage.mock_ord_control_etapa
       SET estado = 'completado', fecha_hora_fin = GETDATE()
     WHERE corrida_id = v_corrida AND etapa = 'ubicaciones';

    -- ---- scoring por canal (SP REALES, sin modificacion) -------------------
    v_etapa_actual := 'scoring_dir';
    INSERT INTO bdm_stage.mock_ord_control_etapa
        (corrida_id, lote, etapa, estado, fecha_hora_inicio, usuario_bd)
    VALUES (v_corrida, v_lote, 'scoring_dir', 'enproceso', GETDATE(), CURRENT_USER);
    CALL bdm_datos.sp_ordenamiento_scoring_dir_edf();
    UPDATE bdm_stage.mock_ord_control_etapa
       SET estado = 'completado', fecha_hora_fin = GETDATE()
     WHERE corrida_id = v_corrida AND etapa = 'scoring_dir';

    v_etapa_actual := 'scoring_tel';
    INSERT INTO bdm_stage.mock_ord_control_etapa
        (corrida_id, lote, etapa, estado, fecha_hora_inicio, usuario_bd)
    VALUES (v_corrida, v_lote, 'scoring_tel', 'enproceso', GETDATE(), CURRENT_USER);
    CALL bdm_datos.sp_ordenamiento_scoring_tel_edf();
    UPDATE bdm_stage.mock_ord_control_etapa
       SET estado = 'completado', fecha_hora_fin = GETDATE()
     WHERE corrida_id = v_corrida AND etapa = 'scoring_tel';

    v_etapa_actual := 'scoring_cel';
    INSERT INTO bdm_stage.mock_ord_control_etapa
        (corrida_id, lote, etapa, estado, fecha_hora_inicio, usuario_bd)
    VALUES (v_corrida, v_lote, 'scoring_cel', 'enproceso', GETDATE(), CURRENT_USER);
    CALL bdm_datos.sp_ordenamiento_scoring_cel_edf();
    UPDATE bdm_stage.mock_ord_control_etapa
       SET estado = 'completado', fecha_hora_fin = GETDATE()
     WHERE corrida_id = v_corrida AND etapa = 'scoring_cel';

    v_etapa_actual := 'scoring_ema';
    INSERT INTO bdm_stage.mock_ord_control_etapa
        (corrida_id, lote, etapa, estado, fecha_hora_inicio, usuario_bd)
    VALUES (v_corrida, v_lote, 'scoring_ema', 'enproceso', GETDATE(), CURRENT_USER);
    CALL bdm_datos.sp_ordenamiento_scoring_ema_edf();
    UPDATE bdm_stage.mock_ord_control_etapa
       SET estado = 'completado', fecha_hora_fin = GETDATE()
     WHERE corrida_id = v_corrida AND etapa = 'scoring_ema';

    -- ---- consolidacion -----------------------------------------------------
    v_etapa_actual := 'consolidacion';
    INSERT INTO bdm_stage.mock_ord_control_etapa
        (corrida_id, lote, etapa, estado, fecha_hora_inicio, usuario_bd)
    VALUES (v_corrida, v_lote, 'consolidacion', 'enproceso', GETDATE(), CURRENT_USER);
    CALL bdm_datos.sp_ordenamiento_consolidacion_edf();

    -- Scores generados por esta corrida: se cuentan ANTES del cleanup, mientras
    -- stg_ord_personas_alcance sigue viva, para acotar al universo mock y no
    -- contar filas reales que convivan en score_ordenamiento.
    SELECT COUNT(*) INTO v_scores
      FROM bdm_datos.score_ordenamiento s
     WHERE EXISTS (SELECT 1 FROM bdm_tempo.stg_ord_personas_alcance a
                    WHERE a.id_buro_persona = s.id_buro_persona);

    UPDATE bdm_stage.mock_ord_control_etapa
       SET estado = 'completado', fecha_hora_fin = GETDATE(),
           filas_salida = v_scores
     WHERE corrida_id = v_corrida AND etapa = 'consolidacion';

    -- ---- cleanup -----------------------------------------------------------
    v_etapa_actual := 'cleanup';
    INSERT INTO bdm_stage.mock_ord_control_etapa
        (corrida_id, lote, etapa, estado, fecha_hora_inicio, usuario_bd)
    VALUES (v_corrida, v_lote, 'cleanup', 'enproceso', GETDATE(), CURRENT_USER);
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
    INSERT INTO bdm_stage.mock_ord_alcance_censo (
        corrida_id, lote, modo, watermark_usado, watermark_origen,
        alcance_filas, alcance_personas,
        por_ubicacion, por_unificacion,
        por_estandarizacion, por_bloqueo, por_cuenta, por_comportamiento,
        fuera_ventana_total, fuera_ventana_dentro,
        stg_residuales, fecha_hora, usuario_bd
    )
    SELECT v_corrida, v_lote, v_modo_efectivo, v_wm_anterior,
           CASE WHEN v_bootstrap THEN 'BOOTSTRAP' ELSE 'CONTROL' END,
           alc.filas, alc.personas, org.por_ubic, org.por_unif,
           NULL, NULL, NULL, NULL,
           fv.total, fv.dentro,
           NULL, GETDATE(), CURRENT_USER
      FROM ( SELECT COUNT(*)                        AS filas,
                    COUNT(DISTINCT id_buro_persona) AS personas
               FROM bdm_tempo.stg_ord_personas_alcance ) alc
      CROSS JOIN
           ( SELECT COUNT(DISTINCT CASE WHEN origen = 'UBICACION'
                                        THEN id_buro_persona END) AS por_ubic,
                    COUNT(DISTINCT CASE WHEN origen = 'UNIFICACION'
                                        THEN id_buro_persona END) AS por_unif
               FROM bdm_tempo.stg_ord_alcance_origen ) org
      CROSS JOIN
           ( SELECT COUNT(DISTINCT rpu.id_buro_persona) AS total,
                    COUNT(DISTINCT CASE WHEN alc2.id_buro_persona IS NOT NULL
                                        THEN rpu.id_buro_persona END) AS dentro
               FROM bdm_tempo.v_mock_relacion_persona_ubicacion rpu
               LEFT JOIN bdm_tempo.stg_ord_personas_alcance alc2
                      ON alc2.id_buro_persona = rpu.id_buro_persona
              WHERE rpu.id_buro_persona BETWEEN 9960000 AND 9969999 ) fv;

    CALL bdm_datos.sp_ordenamiento_drop_staging_edf();

    -- F1-05: despues del drop no puede quedar ninguna de las quince.
    -- (catorce hasta que la Fase 3 anadio stg_ord_ubic_hash).
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
                     'stg_ord_personas_alcance','stg_ord_ubic_hash',
                     'stg_persona_dir_ganadora',
                     'stg_persona_dir_ref','stg_reporte_rpu','stg_rpu_dir_ref',
                     'stg_rpu_post_unificacion' );

    UPDATE bdm_stage.mock_ord_alcance_censo
       SET stg_residuales = v_stg_vivas
     WHERE corrida_id = v_corrida;
    UPDATE bdm_stage.mock_ord_control_etapa
       SET estado = 'completado', fecha_hora_fin = GETDATE()
     WHERE corrida_id = v_corrida AND etapa = 'cleanup';

    -- ---- cierre ------------------------------------------------------------
    -- Watermark a nivel dia sobre el universo mock: MAX(fecha) no nula.
    -- FULL siembra; DELTA avanza solo si hubo fecha no nula, si no conserva.
    SELECT MAX(rpu.fecha_relacion_persona_ubicaci)
      INTO v_wm_nuevo
      FROM bdm_tempo.v_mock_relacion_persona_ubicacion rpu
     WHERE rpu.fecha_relacion_persona_ubicaci IS NOT NULL
       AND ( v_modo_efectivo = 'FULL'
             OR rpu.fecha_relacion_persona_ubicaci >= v_wm_anterior );

    IF v_modo_efectivo <> 'FULL' THEN
        IF v_wm_nuevo IS NULL THEN
            v_wm_nuevo := v_wm_anterior;
        ELSE
            v_wm_nuevo := GREATEST(v_wm_anterior, v_wm_nuevo);
        END IF;
    END IF;

    UPDATE bdm_stage.mock_ord_control
       SET estado            = 'completado',
           watermark_nuevo   = v_wm_nuevo,
           personas_entrada  = v_personas,
           contactos_entrada = v_contactos,
           scores_generados  = v_scores,
           fecha_hora_fin    = GETDATE()
     WHERE corrida_id = v_corrida;

    EXCEPTION
        WHEN OTHERS THEN
            -- Cierra la etapa en curso 'fallido', marca la corrida 'fallido'
            -- SIN avanzar el Watermark, y re-lanza el error al Framework_Batch.
            IF v_etapa_actual IS NOT NULL THEN
                UPDATE bdm_stage.mock_ord_control_etapa
                   SET estado = 'fallido', fecha_hora_fin = GETDATE()
                 WHERE corrida_id = v_corrida AND etapa = v_etapa_actual;
            END IF;

            UPDATE bdm_stage.mock_ord_control
               SET estado = 'fallido', fecha_hora_fin = GETDATE()
             WHERE corrida_id = v_corrida;

            RAISE;
    END;
END;
$$;

-- SLCOPRBA-1355: consume unificacion_direccion_mock via preparar_insumos_mock
