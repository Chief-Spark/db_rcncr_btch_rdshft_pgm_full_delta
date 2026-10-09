-- ============================================================
-- 15b_sp_unif_control_mock_abrir_cerrar.sql
-- Control de corrida de la Unificacion MOCK:
--   bdm_datos.unif_control_mock_abrir  -> abre la corrida 'en proceso'
--   bdm_datos.unif_control_mock_cerrar -> cierra (completado|fallido)
-- (repo pgm / db_rcncr_btch_rdshft_pgm)
-- Cluster consumidor: reconocerbatch / dba_rncr_batch
-- Objetos permanentes en bdm_datos. Idempotente (CREATE OR REPLACE).
-- Codificacion: UTF-8 sin BOM. Nunca GRANT ... TO PUBLIC.
-- Spec: unificacion-full-delta -- certificacion con datos mock
-- ------------------------------------------------------------
-- SLCOPRBA-1355: espejo de 15_sp_unif_control_abrir_cerrar.sql sobre
-- bdm_datos.unif_control_mock. Watermark independiente del real.
--
-- NONATOMIC en toda la cadena (leccion #13).
-- Rollback con DROP PROCEDURE nombre(<firma exacta>) SIN IF EXISTS
-- (lecciones #12/#14). Firmas exactas:
--   bdm_datos.unif_control_mock_abrir(VARCHAR, INTEGER, DATE, DATE, BOOLEAN, BIGINT)
--   bdm_datos.unif_control_mock_cerrar(BIGINT, VARCHAR, DATE, BIGINT, BIGINT, BIGINT)
-- ============================================================

CREATE SCHEMA IF NOT EXISTS bdm_datos;

-- ============================================================
-- bdm_datos.unif_control_mock_abrir
-- Inserta la fila de apertura SIN especificar corrida_id (lo genera la columna
-- IDENTITY(1,1)) y lo DEVUELVE por el parametro INOUT para que el orquestador
-- lo propague a la traza y al cierre.
--
-- Recuperacion del corrida_id generado por IDENTITY (patron Redshift):
-- Redshift no expone lastval()/RETURNING utilizable en un OUT de procedimiento,
-- por lo que se recupera el MAX(corrida_id) acotando por la marca de tiempo de
-- inicio capturada en esta misma invocacion, mas lote/modo/estado. corrida_id
-- es IDENTITY monotonica creciente y unica, de modo que el MAX sobre la fila
-- abierta en este instante la identifica de forma univoca (no se asume
-- consecutividad).
-- ============================================================
CREATE OR REPLACE PROCEDURE bdm_datos.unif_control_mock_abrir(
    p_modo               VARCHAR,     -- modo efectivamente aplicado (FULL|DELTA)
    p_lote               INTEGER,     -- Lote_Corrida externo
    p_fecha_proceso      DATE,        -- Fecha_Proceso
    p_watermark_anterior DATE,        -- watermark de partida (NULL en Bootstrap)
    p_bootstrap          BOOLEAN,     -- TRUE si fue Bootstrap FULL forzado
    p_corrida_id         INOUT BIGINT -- SALIDA: corrida_id generado por IDENTITY
)
NONATOMIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_inicio TIMESTAMP;
BEGIN
    v_inicio := GETDATE();

    INSERT INTO bdm_datos.unif_control_mock (
        lote, modo, bootstrap, fecha_proceso,
        watermark_anterior, estado, fecha_hora_inicio, usuario_bd
    )
    VALUES (
        p_lote, p_modo, p_bootstrap, p_fecha_proceso,
        p_watermark_anterior, 'en proceso', v_inicio, CURRENT_USER
    );

    SELECT MAX(corrida_id)
      INTO p_corrida_id
      FROM bdm_datos.unif_control_mock
     WHERE estado            = 'en proceso'
       AND lote              = p_lote
       AND modo              = p_modo
       AND fecha_hora_inicio = v_inicio;
END;
$$;

-- ============================================================
-- bdm_datos.unif_control_mock_cerrar
-- Cierra la corrida mock:
--   * 'completado' -> fija watermark_nuevo y conteos globales.
--   * 'fallido'    -> NO fija watermark_nuevo, de modo que el
--                     MAX(watermark_nuevo) de la siguiente corrida no lo tome
--                     como avance y el Watermark se conserve.
-- ============================================================
CREATE OR REPLACE PROCEDURE bdm_datos.unif_control_mock_cerrar(
    p_corrida_id          BIGINT,   -- corrida a cerrar
    p_estado              VARCHAR,  -- 'completado' | 'fallido'
    p_watermark_nuevo     DATE,     -- watermark resultante (solo si 'completado')
    p_relaciones_entrada  BIGINT,   -- Metricas_Corrida globales
    p_personas_distintas  BIGINT,   -- distinct id_buro_persona
    p_total_unificaciones BIGINT
)
NONATOMIC
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE bdm_datos.unif_control_mock
       SET estado              = p_estado,
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
