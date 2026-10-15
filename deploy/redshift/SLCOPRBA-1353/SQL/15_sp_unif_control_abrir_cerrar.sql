-- ============================================================
-- 15_sp_unif_control_abrir_cerrar.sql
-- Procedimientos de control de corrida de la Unificacion FULL/DELTA:
--   bdm_datos.unif_control_abrir  -> abre la fila de corrida 'en proceso'
--   bdm_datos.unif_control_cerrar -> cierra la corrida (completado|fallido)
-- (repo pgm / db_rcncr_btch_rdshft_pgm)
-- Cluster consumidor: reconocerbatch / dba_rncr_batch
-- Objetos permanentes en bdm_datos. Idempotente (CREATE OR REPLACE).
-- Codificacion: UTF-8 sin BOM. Nunca GRANT ... TO PUBLIC.
-- Spec: unificacion-full-delta (Task 3.2)
-- Requirements: 4.2, 4.3, 4.4, 4.5, 14.1, 14.4
-- ------------------------------------------------------------
-- NONATOMIC: toda la cadena de CALL de la Unificacion se ejecuta en modo
-- NONATOMIC consistente; mezclar modos rompe con
--   "P0001: created in one transaction mode cannot be invoked from another".
-- Rollback (PROCEDIMIENTOS, no funciones): DROP PROCEDURE nombre(<firma exacta>)
-- SIN IF EXISTS (Redshift no soporta DROP PROCEDURE IF EXISTS) -- lecciones #12/#14.
-- ============================================================

-- ============================================================
-- bdm_datos.unif_control_abrir
-- Inserta la fila de apertura de la corrida en estado 'en proceso' SIN
-- especificar corrida_id (lo genera la columna IDENTITY(1,1) de unif_control) y
-- DEVUELVE el corrida_id generado por el parametro de salida p_corrida_id para
-- que el orquestador lo propague a la traza (unif_traza_*) y al cierre
-- (unif_control_cerrar).
--
-- Recuperacion del corrida_id generado por IDENTITY (patron Redshift):
-- Redshift no expone lastval()/RETURNING utilizable en un OUT de procedimiento,
-- por lo que se recupera el MAX(corrida_id) de la fila recien insertada,
-- acotando por la marca de tiempo de inicio (v_inicio) capturada en esta misma
-- invocacion, mas lote/modo/estado. Como corrida_id es IDENTITY monotonica
-- creciente y unica, el MAX sobre la fila abierta en este instante identifica
-- de forma univoca la corrida recien creada (no se asume consecutividad).
--
-- Requirements: 4.2 (fila 'en proceso'), 1.5 (modo efectivo), 2.3 (bootstrap),
--               14.1 (fecha_proceso)
-- ============================================================
CREATE OR REPLACE PROCEDURE bdm_datos.unif_control_abrir(
    p_modo               VARCHAR,     -- modo efectivamente aplicado (FULL|DELTA), Req 1.5
    p_lote               INTEGER,     -- Lote_Corrida externo
    p_fecha_proceso      DATE,        -- Fecha_Proceso, Req 14.1
    p_watermark_anterior DATE,        -- watermark de partida (NULL en Bootstrap)
    p_bootstrap          BOOLEAN,     -- TRUE si fue Bootstrap FULL forzado, Req 2.3
    p_corrida_id         INOUT BIGINT -- SALIDA: corrida_id generado por IDENTITY
)
NONATOMIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_inicio TIMESTAMP;
BEGIN
    -- Marca de tiempo de inicio de esta corrida (identifica la fila recien abierta).
    v_inicio := GETDATE();

    -- INSERT sin corrida_id: lo genera la columna IDENTITY(1,1) de unif_control.
    INSERT INTO bdm_datos.unif_control (
        lote, modo, bootstrap, fecha_proceso,
        watermark_anterior, estado, fecha_hora_inicio, usuario_bd
    )
    VALUES (
        p_lote, p_modo, p_bootstrap, p_fecha_proceso,
        p_watermark_anterior, 'en proceso', v_inicio, CURRENT_USER
    );

    -- Recuperar el corrida_id generado por IDENTITY para la fila recien abierta.
    SELECT MAX(corrida_id)
      INTO p_corrida_id
      FROM bdm_datos.unif_control
     WHERE estado            = 'en proceso'
       AND lote              = p_lote
       AND modo              = p_modo
       AND fecha_hora_inicio = v_inicio;
END;
$$;

-- ============================================================
-- bdm_datos.unif_control_cerrar
-- Actualiza la fila de la corrida al estado final:
--   * 'completado' -> fija watermark_nuevo (Req 4.3) y conteos globales.
--   * 'fallido'    -> conserva el watermark_anterior (NO fija watermark_nuevo),
--                     Req 4.4; el watermark efectivo de la siguiente corrida
--                     DELTA se deriva de MAX(watermark_nuevo) entre corridas
--                     'completado' (Req 4.5).
-- Fija fecha_hora_fin y las Metricas_Corrida globales (Req 14.4).
--
-- Requirements: 4.3 (completado + watermark_nuevo), 4.4 (fallido conserva
--               watermark), 4.5 (watermark efectivo), 14.4 (conteos globales)
-- ============================================================
CREATE OR REPLACE PROCEDURE bdm_datos.unif_control_cerrar(
    p_corrida_id          BIGINT,   -- corrida a cerrar (generado por IDENTITY en abrir)
    p_estado              VARCHAR,  -- 'completado' | 'fallido' (Req 4.3, 4.4)
    p_watermark_nuevo     DATE,     -- watermark resultante (solo si 'completado')
    p_relaciones_entrada  BIGINT,   -- Metricas_Corrida globales (Req 14.4)
    p_personas_distintas  BIGINT,   -- distinct id_buro_persona
    p_total_unificaciones BIGINT
)
NONATOMIC
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE bdm_datos.unif_control
       SET estado              = p_estado,
           -- Solo se fija watermark_nuevo en 'completado'; en 'fallido' se
           -- conserva NULL para que MAX(watermark_nuevo) NO lo tome como avance.
           watermark_nuevo     = CASE WHEN p_estado = 'completado'
                                      THEN p_watermark_nuevo
                                      ELSE watermark_nuevo END,
           relaciones_entrada  = p_relaciones_entrada,
           personas_distintas  = p_personas_distintas,
           total_unificaciones = p_total_unificaciones,
           fecha_hora_fin      = GETDATE()
     WHERE corrida_id = p_corrida_id;
END;
$$;

-- SLCOPRBA-1355: re-DPLY DEV post DROP SCHEMA strct #256
