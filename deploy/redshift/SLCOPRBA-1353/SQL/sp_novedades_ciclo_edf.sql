-- Novedades - orquestador del ciclo
-- Encadena el control de corrida, el dominio UBICACION y la carga de la
-- tabla final. Los otros siete dominios se enganchan aqui cuando se porten:
-- el catalogo de etapas de nov_control_etapa ya los nombra.
--
-- FIRMA DEL FRAMEWORK BATCH, SEIS PARAMETROS VARCHAR Y EN ESTE ORDEN.
-- Los tres primeros no se usan y aun asi forman parte de la firma; cambiarla
-- rompe la invocacion del Framework. Regla 1 del proyecto.
--   in_nemotecnico     = MODO   (FULL | DELTA)
--   in_id_facturacion  = LOTE
--   in_fecha_ejecucion = FECHA  (YYYY-MM-DD)
--
-- NONATOMIC en toda la cadena de CALL: mezclar modos rompe con
-- "P0001: created in one transaction mode cannot be invoked from another".

CREATE OR REPLACE PROCEDURE bdm_datos.sp_novedades_ciclo_edf(
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
    v_wm_maximo   DATE;
    v_wm_nuevo    DATE;
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
      FROM bdm_datos.nov_control
     WHERE estado = 'completado';

    v_bootstrap := (v_watermark IS NULL);
    IF v_bootstrap THEN
        v_modo := 'FULL';
    END IF;

    CALL bdm_datos.nov_control_abrir(v_modo, v_lote, v_fecha,
                                     v_watermark, v_bootstrap, v_corrida_id);

    -- ---------- dominio UBICACION ----------
    CALL bdm_datos.nov_control_etapa_marcar(v_corrida_id, v_lote, 'ubicacion',
                                            'en proceso', NULL, NULL, NULL, NULL, NULL);

    CALL bdm_datos.sp_novedades_ubicacion_edf(v_modo, v_watermark);
    CALL bdm_datos.sp_novedades_cargar_mat_ubicacion_edf(v_lote);

    -- Conteos de la etapa. Se leen con un solo SELECT por el mismo motivo por
    -- el que no se ponen subconsultas escalares en una agregacion: Redshift no
    -- las resuelve de forma fiable.
    SELECT COUNT(*),
           COUNT(DISTINCT info_basica),
           SUM(CASE WHEN flag_op = 'I' THEN 1 ELSE 0 END),
           SUM(CASE WHEN flag_op = 'A' THEN 1 ELSE 0 END),
           SUM(CASE WHEN flag_op = 'E' THEN 1 ELSE 0 END)
      INTO v_entrada, v_personas, v_altas, v_cambios, v_bajas
      FROM bdm_tempo.stg_nov_ubica_etapa_9;

    -- SUM() sobre cero filas devuelve NULL, no 0: se normaliza aqui para que
    -- la traza no mienta diciendo "sin dato" cuando el dato es cero.
    v_altas   := COALESCE(v_altas, 0);
    v_cambios := COALESCE(v_cambios, 0);
    v_bajas   := COALESCE(v_bajas, 0);

    CALL bdm_datos.nov_control_etapa_marcar(v_corrida_id, v_lote, 'ubicacion',
                                            'completado', v_entrada, v_personas,
                                            v_altas, v_cambios, v_bajas);

    -- ---------- el watermark nuevo ----------
    -- EL WATERMARK SALE DEL MAX DEL DATO, NUNCA DE LA FECHA DE EJECUCION.
    -- Esta linea pasaba v_fecha, que es CURRENT_DATE cuando el Framework no
    -- manda FECHA, y el efecto no lo veia el tablero: con la frontera en hoy
    -- y las relaciones fechadas en el pasado, el DELTA solo recogia la rama
    -- fecha IS NULL y daba PASSED sin haber mirado la ventana. Es el mismo
    -- bloque de 16_sp_unificacion_ciclo.sql:375-392 y se copia a proposito:
    -- dos procesos que acotan por la misma columna no pueden tener dos
    -- semanticas de watermark.
    --
    --   * FULL: se SIEMBRA con el maximo observado. Si el universo no tuviera
    --     ninguna fecha no nula queda NULL, y el siguiente FULL vuelve a
    --     sembrar.
    --   * DELTA: se AVANZA solo si el delta trajo alguna fecha no nula; si no,
    --     se CONSERVA el anterior para no perder la frontera. GREATEST protege
    --     ademas de un maximo por debajo del anterior: el watermark no
    --     retrocede.
    --
    -- Las filas con fecha NULL quedan fuera del MAX (no aportan avance) pero
    -- SI entran en v_entrada: forman parte del universo procesado.
    SELECT MAX(rpu.fecha_relacion_persona_ubicaci)
      INTO v_wm_maximo
      FROM bdm_tempo.v_xpm_relacion_persona_ubicacion rpu
     WHERE rpu.fecha_relacion_persona_ubicaci IS NOT NULL
       AND ( v_modo = 'FULL'
             OR rpu.fecha_relacion_persona_ubicaci >= v_watermark );

    IF v_modo = 'FULL' THEN
        v_wm_nuevo := v_wm_maximo;
    ELSE
        IF v_wm_maximo IS NULL THEN
            v_wm_nuevo := v_watermark;
        ELSE
            v_wm_nuevo := GREATEST(v_watermark, v_wm_maximo);
        END IF;
    END IF;

    -- ---------- cierre de la corrida ----------
    SELECT COUNT(*) INTO v_escritas FROM bdm_datos.mat_info_ubicacion;

    CALL bdm_datos.nov_control_cerrar(v_corrida_id, 'completado', v_wm_nuevo,
                                      v_entrada, v_personas, v_escritas);

    RAISE INFO 'sp_novedades_ciclo_edf: corrida % lote % modo % completada; entrada %, personas %, altas %, cambios %, bajas %.',
      v_corrida_id, v_lote, v_modo, v_entrada, v_personas, v_altas, v_cambios, v_bajas;

END;
$$;
