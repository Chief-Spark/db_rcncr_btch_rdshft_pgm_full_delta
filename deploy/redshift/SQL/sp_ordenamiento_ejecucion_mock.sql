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
-- sp_ordenamiento_cargar_seed_mock y sp_ordenamiento_validar_mock siguen
-- desplegados y se pueden invocar aparte: son una verificacion independiente de
-- los criterios de aceptacion contra valores controlados. Ya no forman parte de
-- la cadena E2E, cuya evidencia sale de los gates sobre score_ordenamiento y
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
    v_modo          VARCHAR(10);
    v_modo_efectivo VARCHAR(10);
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
BEGIN
    v_modo := CASE
      WHEN in_nemotecnico IS NULL OR TRIM(in_nemotecnico) = '' THEN 'FULL'
      ELSE UPPER(TRIM(in_nemotecnico))
    END;
    v_lote_txt := NULLIF(TRIM(in_id_facturacion), '');
    IF v_lote_txt IS NULL THEN
        RAISE EXCEPTION 'ORD MOCK: lote obligatorio';
    END IF;
    v_lote := v_lote_txt::INTEGER;
    v_fecha_txt := CASE
      WHEN in_fecha_ejecucion IS NULL OR TRIM(in_fecha_ejecucion) = '' THEN TO_CHAR(CURRENT_DATE, 'YYYY-MM-DD')
      ELSE TRIM(in_fecha_ejecucion)
    END;

    IF v_modo NOT IN ('FULL', 'DELTA') THEN
        RAISE EXCEPTION 'ORD MOCK: modo invalido %', v_modo;
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
    CALL bdm_datos.sp_ordenamiento_drop_staging_edf();
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
