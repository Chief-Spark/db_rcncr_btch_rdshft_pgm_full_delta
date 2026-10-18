-- Novedades - orquestador del ciclo (ESPEJO MOCK)
-- Espejo de sp_novedades_ciclo_edf.sql. Generado por SUSTITUCION DE
-- FUENTES: no se edita a mano. Regenerar con
-- tools/gen_novedades_espejo_mock_resto.py.
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
    v_entrada_ae  BIGINT;
    v_personas_ae BIGINT;
    v_altas_ae    BIGINT;
    v_cambios_ae  BIGINT;
    v_entrada_ag  BIGINT;
    v_personas_ag BIGINT;
    v_altas_ag    BIGINT;
    v_cambios_ag  BIGINT;
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

    -- ---------- dominio ACTIVIDAD ECONOMICA ----------
  -- Va DESPUES de Ubicacion y no en paralelo, aunque no lea ninguna de sus
  -- dos etapas: el legado invoca los diez SP en serie y el orden de la malla
  -- es parte de lo que se porta. Cuando entren los dominios que SI leen las
  -- salidas de Ubicacion (Catalogo, Contact, Historial, PICalculados_Ctls y
  -- Ubi_Agregada), el orden dejara de ser una convencion y sera un requisito.
  CALL bdm_datos.nov_control_mock_etapa_marcar(v_corrida_id, v_lote, 'actividad_economica',
                                          'en proceso', NULL, NULL, NULL, NULL, NULL);

  CALL bdm_datos.sp_novedades_actividad_economica_mock(v_modo, v_watermark);
  CALL bdm_datos.sp_novedades_cargar_mat_acteco_mock(v_lote);

  SELECT COUNT(*),
         COUNT(DISTINCT info_basica_id),
         SUM(CASE WHEN flag_op = 'I' THEN 1 ELSE 0 END),
         SUM(CASE WHEN flag_op = 'A' THEN 1 ELSE 0 END)
    INTO v_entrada_ae, v_personas_ae, v_altas_ae, v_cambios_ae
    FROM bdm_tempo.stg_nov_acteco_etapa_1_mock;

  -- SUM() sobre cero filas devuelve NULL, no 0. Mismo cuidado que arriba.
  v_altas_ae   := COALESCE(v_altas_ae, 0);
  v_cambios_ae := COALESCE(v_cambios_ae, 0);

  -- Las bajas van a 0 LITERAL y no a un conteo: este dominio no las emite
  -- nunca. Su Severidad no tiene rama que devuelva 2 (120.TPT:186-197), de
  -- modo que el DELETE del 130.TPT:753 es codigo muerto. Contar 'E' aqui
  -- sugeriria que puede haberlas.
  CALL bdm_datos.nov_control_mock_etapa_marcar(v_corrida_id, v_lote, 'actividad_economica',
                                          'completado', v_entrada_ae, v_personas_ae,
                                          v_altas_ae, v_cambios_ae, 0);

  -- ---------- dominio UBICACION AGREGADA ----------
  -- Va DESPUES de Ubicacion porque LEE SUS DOS ETAPAS -- once puntos de
  -- lectura, cinco de la etapa 2 y seis de la etapa 9 -- y no por convencion.
  -- Invertido el orden saldria vacio por un efecto de secuencia y no por un
  -- defecto, que es la misma leccion del ciclo GEO y de Novedades entera.
  -- Y despues de Actividad Economica, que es el orden en que el 111.BTQ
  -- invoca los diez SP del legado.
  CALL bdm_datos.nov_control_mock_etapa_marcar(v_corrida_id, v_lote, 'ubi_agregada',
                                          'en proceso', NULL, NULL, NULL, NULL, NULL);

  CALL bdm_datos.sp_novedades_ubi_agregada_mock();
  CALL bdm_datos.sp_novedades_cargar_mat_ubi_agregada_mock(v_lote);

  -- LAS METRICAS SALEN DE LA SEVERIDAD, NO DE flag_op. En este dominio
  -- flag_op es 'I' LITERAL (Novedad.sql:7170): contar altas por ahi diria que
  -- todo es alta incluso cuando la Severidad lo trata como cambio. Por eso el
  -- cargador deja viva stg_nov_ubiagr_sev y la leemos aqui.
  --   severidad = 1 y ya_estaba = 0 -> alta
  --   severidad = 1 y ya_estaba = 1 -> cambio
  --   severidad = -1                -> no cambio nada, no se escribio
  SELECT COUNT(*),
         COUNT(DISTINCT info_basica),
         SUM(CASE WHEN severidad = 1 AND ya_estaba = 0 THEN 1 ELSE 0 END),
         SUM(CASE WHEN severidad = 1 AND ya_estaba = 1 THEN 1 ELSE 0 END)
    INTO v_entrada_ag, v_personas_ag, v_altas_ag, v_cambios_ag
    FROM bdm_tempo.stg_mock_nov_ubiagr_sev;

  -- SUM() sobre cero filas devuelve NULL, no 0. Mismo cuidado que arriba.
  v_altas_ag   := COALESCE(v_altas_ag, 0);
  v_cambios_ag := COALESCE(v_cambios_ag, 0);

  -- Las bajas van a 0 LITERAL, igual que en Actividad Economica: la Severidad
  -- de este dominio no tiene rama que devuelva 2 (120.TPT:406-442), de modo
  -- que el DELETE del 130.TPT:1135-1147 es codigo muerto.
  CALL bdm_datos.nov_control_mock_etapa_marcar(v_corrida_id, v_lote, 'ubi_agregada',
                                          'completado', v_entrada_ag, v_personas_ag,
                                          v_altas_ag, v_cambios_ag, 0);

  -- Ahora si: bdm_tempo es compartido y una tabla huerfana confunde al
  -- siguiente que mire.
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_nov_ubiagr_sev;

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
      FROM bdm_tempo.v_mock_relacion_persona_ubicacion rpu
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
    SELECT COUNT(*) INTO v_escritas FROM bdm_datos.mat_info_ubicacion_mock;

    CALL bdm_datos.nov_control_mock_cerrar(v_corrida_id, 'completado', v_wm_nuevo,
                                      v_entrada, v_personas, v_escritas);

    RAISE INFO 'sp_novedades_mock_ciclo: corrida % lote % modo % completada; entrada %, personas %, altas %, cambios %, bajas %.',
      v_corrida_id, v_lote, v_modo, v_entrada, v_personas, v_altas, v_cambios, v_bajas;

END;
$$;
