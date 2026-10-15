-- ============================================================
-- 17_sp_ord_control_abrir_cerrar.sql
-- Control de corrida Ordenamiento FULL/DELTA (espejo unif_control_*).
-- UTF-8 sin BOM. Nunca GRANT TO PUBLIC. NONATOMIC.
-- ============================================================

CREATE SCHEMA IF NOT EXISTS bdm_datos;

CREATE OR REPLACE PROCEDURE bdm_datos.ord_control_abrir(
    p_modo               VARCHAR,
    p_lote               INTEGER,
    p_fecha_proceso      DATE,
    p_watermark_anterior DATE,
    p_bootstrap          BOOLEAN,
    p_corrida_id         INOUT BIGINT
)
NONATOMIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_inicio TIMESTAMP;
BEGIN
    v_inicio := GETDATE();
    INSERT INTO bdm_datos.ord_control (
        lote, modo, bootstrap, fecha_proceso,
        watermark_anterior, estado, fecha_hora_inicio, usuario_bd
    )
    VALUES (
        p_lote, p_modo, p_bootstrap, p_fecha_proceso,
        p_watermark_anterior, 'enproceso', v_inicio, CURRENT_USER
    );
    SELECT MAX(corrida_id)
      INTO p_corrida_id
      FROM bdm_datos.ord_control
     WHERE estado = 'enproceso'
       AND lote = p_lote
       AND modo = p_modo
       AND fecha_hora_inicio = v_inicio;
END;
$$;

CREATE OR REPLACE PROCEDURE bdm_datos.ord_control_cerrar(
    p_corrida_id         BIGINT,
    p_estado             VARCHAR,
    p_watermark_nuevo    DATE,
    p_personas_entrada   BIGINT,
    p_contactos_entrada  BIGINT,
    p_scores_generados   BIGINT
)
NONATOMIC
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE bdm_datos.ord_control
       SET estado = p_estado,
           watermark_nuevo = CASE WHEN p_estado = 'completado' THEN p_watermark_nuevo ELSE watermark_nuevo END,
           personas_entrada = p_personas_entrada,
           contactos_entrada = p_contactos_entrada,
           scores_generados = p_scores_generados,
           fecha_hora_fin = GETDATE()
     WHERE corrida_id = p_corrida_id;
END;
$$;

-- SLCOPRBA-1355: re-DPLY DEV post DROP SCHEMA strct #256
