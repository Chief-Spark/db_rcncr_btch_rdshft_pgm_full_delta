-- Novedades - control de corrida
-- Gemelo de 15_sp_unif_control_abrir_cerrar.sql, sobre bdm_datos.nov_control.
-- Objetos en bdm_datos; idempotentes.
--
-- POR QUE ESTE CONTROL ES DISENO Y NO PORT: el del legado (REC_MTDAT.LOG_TD)
-- esta inoperativo. La corrida borra su propio log al arrancar
-- (P0035_Extractor_Novedades_111.BTQ:64-65) y el watermark que los SPs leen es
-- MAX(FECHA_HORA_FIN) de esa misma tabla (Novedad.sql:242-247), de modo que
-- siempre devuelve NULL y toda corrida del legado es FULL. El cierre tampoco
-- ocurre: _140.BTQ declara FncUpdate_LogTD en :47-61 y no la llama (:853-858).
-- El detalle completo esta en 31_ddl_nov_control.sql.

-- ============================================================
-- bdm_datos.nov_control_abrir
-- Abre la corrida en estado 'en proceso' y devuelve su corrida_id.
-- ============================================================
CREATE OR REPLACE PROCEDURE bdm_datos.nov_control_abrir(
    p_modo               VARCHAR,     -- modo efectivamente aplicado (FULL|DELTA)
    p_lote               INTEGER,     -- Lote_Corrida externo
    p_fecha_proceso      DATE,
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
    -- Marca de tiempo de inicio de esta corrida (identifica la fila recien abierta).
    v_inicio := GETDATE();

    -- INSERT sin corrida_id: lo genera la columna IDENTITY(1,1) de nov_control.
    INSERT INTO bdm_datos.nov_control (
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
      FROM bdm_datos.nov_control
     WHERE estado            = 'en proceso'
       AND lote              = p_lote
       AND modo              = p_modo
       AND fecha_hora_inicio = v_inicio;
END;
$$;

-- ============================================================
-- bdm_datos.nov_control_cerrar
-- Cierra la corrida:
--   * 'completado' -> fija watermark_nuevo y los conteos globales.
--   * 'fallido'    -> conserva el watermark anterior y NO fija el nuevo, de
--                     modo que MAX(watermark_nuevo) no lo tome como avance.
-- ============================================================
CREATE OR REPLACE PROCEDURE bdm_datos.nov_control_cerrar(
    p_corrida_id         BIGINT,
    p_estado             VARCHAR,  -- 'completado' | 'fallido'
    p_watermark_nuevo    DATE,
    p_relaciones_entrada BIGINT,
    p_personas_distintas BIGINT,
    p_filas_mat_escritas BIGINT
)
NONATOMIC
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE bdm_datos.nov_control
       SET estado             = p_estado,
           watermark_nuevo    = CASE WHEN p_estado = 'completado'
                                     THEN p_watermark_nuevo
                                     ELSE watermark_nuevo END,
           relaciones_entrada = p_relaciones_entrada,
           personas_distintas = p_personas_distintas,
           filas_mat_escritas = p_filas_mat_escritas,
           fecha_hora_fin     = GETDATE()
     WHERE corrida_id = p_corrida_id;
END;
$$;

-- ============================================================
-- bdm_datos.nov_control_etapa_marcar
-- Traza por dominio. Un solo SP para abrir y cerrar: la etapa se identifica
-- por (corrida_id, etapa) y el UPDATE no encuentra fila la primera vez, de
-- modo que se inserta. Mismo idioma que la traza de Unificacion.
-- ============================================================
CREATE OR REPLACE PROCEDURE bdm_datos.nov_control_etapa_marcar(
    p_corrida_id         BIGINT,
    p_lote               INTEGER,
    p_etapa              VARCHAR,  -- ubicacion | catalogo | info_basica | ...
    p_estado             VARCHAR,  -- en proceso | completado | fallido
    p_relaciones_entrada BIGINT,
    p_personas_distintas BIGINT,
    p_filas_altas        BIGINT,
    p_filas_cambios      BIGINT,
    p_filas_bajas        BIGINT
)
NONATOMIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_existe INTEGER;
BEGIN
    SELECT COUNT(*) INTO v_existe
      FROM bdm_datos.nov_control_etapa
     WHERE corrida_id = p_corrida_id
       AND etapa      = p_etapa;

    IF v_existe = 0 THEN
        INSERT INTO bdm_datos.nov_control_etapa (
            corrida_id, lote, etapa, estado, fecha_hora_inicio,
            relaciones_entrada, personas_distintas,
            filas_altas, filas_cambios, filas_bajas, usuario_bd
        )
        VALUES (
            p_corrida_id, p_lote, p_etapa, p_estado, GETDATE(),
            p_relaciones_entrada, p_personas_distintas,
            p_filas_altas, p_filas_cambios, p_filas_bajas, CURRENT_USER
        );
    ELSE
        -- UPDATE ... sin alias: el destino de un UPDATE no lo admite en Redshift.
        UPDATE bdm_datos.nov_control_etapa
           SET estado             = p_estado,
               fecha_hora_fin     = GETDATE(),
               relaciones_entrada = p_relaciones_entrada,
               personas_distintas = p_personas_distintas,
               filas_altas        = p_filas_altas,
               filas_cambios      = p_filas_cambios,
               filas_bajas        = p_filas_bajas
         WHERE corrida_id = p_corrida_id
           AND etapa      = p_etapa;
    END IF;
END;
$$;
