-- ============================================================
-- sp_ordenamiento_ejecucion_mock.sql
-- Mock Ordenamiento FULL/DELTA con observabilidad en bdm_stage.
-- Firma 6 VARCHAR alineada a Framework_Batch / sp_ordenamiento_ciclo.
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
    v_modo      VARCHAR(10);
    v_lote_txt  VARCHAR;
    v_lote      INTEGER;
    v_fecha_txt VARCHAR;
    v_inicio    TIMESTAMP;
    v_corrida   BIGINT;
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

    v_inicio := GETDATE();
    INSERT INTO bdm_stage.mock_ord_control (
        lote, modo, bootstrap, fecha_proceso, watermark_anterior,
        estado, fecha_hora_inicio, usuario_bd
    )
    VALUES (
        v_lote, v_modo, FALSE, v_fecha_txt::DATE, NULL,
        'enproceso', v_inicio, CURRENT_USER
    );
    SELECT MAX(corrida_id) INTO v_corrida
      FROM bdm_stage.mock_ord_control
     WHERE fecha_hora_inicio = v_inicio AND lote = v_lote;

    INSERT INTO bdm_stage.mock_ord_control_etapa (
        corrida_id, lote, etapa, estado, fecha_hora_inicio, usuario_bd
    ) VALUES (v_corrida, v_lote, 'seed_validar', 'enproceso', GETDATE(), CURRENT_USER);

    CALL bdm_datos.sp_ordenamiento_cargar_seed_mock();
    CALL bdm_datos.sp_ordenamiento_validar_mock();

    UPDATE bdm_stage.mock_ord_control_etapa
       SET estado = 'completado', fecha_hora_fin = GETDATE()
     WHERE corrida_id = v_corrida AND etapa = 'seed_validar';

    UPDATE bdm_stage.mock_ord_control
       SET estado = 'completado',
           watermark_nuevo = v_fecha_txt::DATE,
           fecha_hora_fin = GETDATE()
     WHERE corrida_id = v_corrida;
END;
$$;

-- SLCOPRBA-1355: re-DPLY DEV post DROP SCHEMA strct #256
