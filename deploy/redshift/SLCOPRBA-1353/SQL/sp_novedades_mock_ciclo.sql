-- Novedades - orquestador del ciclo (ESPEJO MOCK)
-- Espejo de sp_novedades_ciclo_edf.sql. Generado por SUSTITUCION DE
-- FUENTES: no se edita a mano. Regenerar con scratchpad/gen_nov_mocks2.py.
-- Solo cambian los nombres de los objetos: _edf -> _mock en los
-- procedimientos, y sufijo _mock en las tablas que lee y escribe.
-- El diff contra el real debe salir vacio modulo esos nombres.

CREATE OR REPLACE PROCEDURE bdm_datos.sp_novedades_mock_ciclo(
    in_solicitud       VARCHAR,   -- no se usa; parte de la firma del Framework
    in_nit_suscriptor  VARCHAR,   -- no se usa; parte de la firma del Framework
    in_path_archivo    VARCHAR,   -- no se usa; parte de la firma del Framework
    in_nemotecnico     VARCHAR,   -- MODO
    in_id_facturacion  VARCHAR,   -- LOTE
    in_fecha_ejecucion VARCHAR    -- FECHA
)
NONATOMIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_modo        VARCHAR(10);
    v_lote        INTEGER;
    v_fecha       DATE;
    v_watermark   DATE;
    v_bootstrap   BOOLEAN;
    v_corrida_id  BIGINT;
    v_entrada     BIGINT;
    v_personas    BIGINT;
    v_altas       BIGINT;
    v_cambios     BIGINT;
    v_bajas       BIGINT;
    v_escritas    BIGINT;
BEGIN
    v_modo  := UPPER(COALESCE(in_nemotecnico, 'FULL'));
    v_lote  := CAST(in_id_facturacion AS INTEGER);
    v_fecha := CASE WHEN NULLIF(BTRIM(COALESCE(in_fecha_ejecucion, '')), '') IS NULL
                    THEN CURRENT_DATE
                    ELSE CAST(in_fecha_ejecucion AS DATE) END;

    -- Watermark efectivo: el mayor de las corridas completadas. Si no hay
    -- ninguna, la corrida es un Bootstrap FULL aunque pidan DELTA -- mismo
    -- criterio que la Unificacion, y la unica forma de que un DELTA sin
    -- historico no devuelva el universo vacio.
    SELECT MAX(watermark_nuevo) INTO v_watermark
      FROM bdm_datos.nov_control_mock
     WHERE estado = 'completado';

    v_bootstrap := (v_watermark IS NULL);
    IF v_bootstrap THEN
        v_modo := 'FULL';
    END IF;

    CALL bdm_datos.nov_control_mock_abrir(v_modo, v_lote, v_fecha,
                                     v_watermark, v_bootstrap, v_corrida_id);

    -- ---------- dominio UBICACION ----------
    CALL bdm_datos.nov_control_mock_etapa_marcar(v_corrida_id, v_lote, 'ubicacion',
                                            'en proceso', NULL, NULL, NULL, NULL, NULL);

    CALL bdm_datos.sp_novedades_ubicacion_mock(v_modo, v_watermark);
    CALL bdm_datos.sp_novedades_cargar_mat_ubicacion_mock(v_lote);

    -- Conteos de la etapa. Se leen con un solo SELECT por el mismo motivo por
    -- el que no se ponen subconsultas escalares en una agregacion: Redshift no
    -- las resuelve de forma fiable.
    SELECT COUNT(*),
           COUNT(DISTINCT info_basica),
           SUM(CASE WHEN flag_op = 'I' THEN 1 ELSE 0 END),
           SUM(CASE WHEN flag_op = 'A' THEN 1 ELSE 0 END),
           SUM(CASE WHEN flag_op = 'E' THEN 1 ELSE 0 END)
      INTO v_entrada, v_personas, v_altas, v_cambios, v_bajas
      FROM bdm_tempo.stg_nov_ubica_etapa_9_mock;

    -- SUM() sobre cero filas devuelve NULL, no 0: se normaliza aqui para que
    -- la traza no mienta diciendo "sin dato" cuando el dato es cero.
    v_altas   := COALESCE(v_altas, 0);
    v_cambios := COALESCE(v_cambios, 0);
    v_bajas   := COALESCE(v_bajas, 0);

    CALL bdm_datos.nov_control_mock_etapa_marcar(v_corrida_id, v_lote, 'ubicacion',
                                            'completado', v_entrada, v_personas,
                                            v_altas, v_cambios, v_bajas);

    -- ---------- cierre de la corrida ----------
    SELECT COUNT(*) INTO v_escritas FROM bdm_datos.mat_info_ubicacion_mock;

    CALL bdm_datos.nov_control_mock_cerrar(v_corrida_id, 'completado', v_fecha,
                                      v_entrada, v_personas, v_escritas);

    RAISE INFO 'sp_novedades_mock_ciclo: corrida % lote % modo % completada; entrada %, personas %, altas %, cambios %, bajas %.',
      v_corrida_id, v_lote, v_modo, v_entrada, v_personas, v_altas, v_cambios, v_bajas;

END;
$$;
