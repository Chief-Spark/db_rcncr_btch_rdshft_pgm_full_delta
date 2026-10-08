-- ============================================================
-- 18_sp_ord_traza.sql — traza no bloqueante Ordenamiento
-- ============================================================

CREATE OR REPLACE PROCEDURE bdm_datos.ord_traza_inicio(
    p_corrida_id BIGINT,
    p_lote       INTEGER,
    p_etapa      VARCHAR
)
NONATOMIC
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO bdm_datos.ord_control_etapa (
        corrida_id, lote, etapa, estado, fecha_hora_inicio, usuario_bd
    )
    VALUES (p_corrida_id, p_lote, p_etapa, 'enproceso', GETDATE(), CURRENT_USER);
EXCEPTION
    WHEN OTHERS THEN
        NULL;
END;
$$;

CREATE OR REPLACE PROCEDURE bdm_datos.ord_traza_fin(
    p_corrida_id    BIGINT,
    p_etapa         VARCHAR,
    p_estado        VARCHAR,
    p_filas_entrada BIGINT,
    p_filas_salida  BIGINT
)
NONATOMIC
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE bdm_datos.ord_control_etapa
       SET estado = p_estado,
           fecha_hora_fin = GETDATE(),
           filas_entrada = p_filas_entrada,
           filas_salida = p_filas_salida
     WHERE corrida_id = p_corrida_id
       AND etapa = p_etapa
       AND estado = 'enproceso';
EXCEPTION
    WHEN OTHERS THEN
        NULL;
END;
$$;

-- SLCOPRBA-1355: re-DPLY DEV post DROP SCHEMA strct #256
