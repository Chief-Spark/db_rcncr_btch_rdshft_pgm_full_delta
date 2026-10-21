-- Novedades - orquestador del ciclo
-- Encadena el control de corrida y los TRES dominios portados -- UBICACION,
-- ACTIVIDAD ECONOMICA y UBICACION AGREGADA -- con la carga de sus tablas
-- finales. Los cinco que faltan se enganchan aqui cuando se porten: el
-- catalogo de etapas de nov_control_etapa ya los nombra.
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
    v_modo        VARCHAR(64);
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
    v_entrada_ct  BIGINT;
    v_personas_ct BIGINT;
    v_entrada_ib  BIGINT;
    v_personas_ib BIGINT;
    v_entrada_pi  BIGINT;
    v_ubic_pi     BIGINT;
BEGIN
    -- SLCOPRBA-1398: el slot 4 trae el MNEMOTECNICO, no el modo.
    v_modo  := bdm_datos.fw_resolver_param('MODO', in_nemotecnico);
    v_lote  := CAST(in_id_facturacion AS INTEGER);
    -- El slot 6 trae 'YYMM'. Traducido, y si no es derivable, CURRENT_DATE.
    v_fecha := CASE WHEN NULLIF(bdm_datos.fw_resolver_param('FECHA', in_fecha_ejecucion), '') IS NULL
                    THEN CURRENT_DATE
                    ELSE CAST(bdm_datos.fw_resolver_param('FECHA', in_fecha_ejecucion) AS DATE) END;

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

    CALL bdm_datos.sp_rcn_ctl_nov_abrir(v_modo, v_lote, v_fecha,
                                     v_watermark, v_bootstrap, v_corrida_id);

    -- ---------- dominio UBICACION ----------
    CALL bdm_datos.sp_rcn_ctl_nov_etapa_marcar(v_corrida_id, v_lote, 'ubicacion',
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

    CALL bdm_datos.sp_rcn_ctl_nov_etapa_marcar(v_corrida_id, v_lote, 'ubicacion',
                                            'completado', v_entrada, v_personas,
                                            v_altas, v_cambios, v_bajas);

    -- ---------- dominio ACTIVIDAD ECONOMICA ----------
  -- Va DESPUES de Ubicacion y no en paralelo, aunque no lea ninguna de sus
  -- dos etapas: el legado invoca los diez SP en serie y el orden de la malla
  -- es parte de lo que se porta. Cuando entren los dominios que SI leen las
  -- salidas de Ubicacion (Catalogo, Contact, Historial, PICalculados_Ctls y
  -- Ubi_Agregada), el orden dejara de ser una convencion y sera un requisito.
  CALL bdm_datos.sp_rcn_ctl_nov_etapa_marcar(v_corrida_id, v_lote, 'actividad_economica',
                                          'en proceso', NULL, NULL, NULL, NULL, NULL);

  CALL bdm_datos.sp_novedades_actividad_economica_edf(v_modo, v_watermark);
  CALL bdm_datos.sp_novedades_cargar_mat_acteco_edf(v_lote);

  SELECT COUNT(*),
         COUNT(DISTINCT info_basica_id),
         SUM(CASE WHEN flag_op = 'I' THEN 1 ELSE 0 END),
         SUM(CASE WHEN flag_op = 'A' THEN 1 ELSE 0 END)
    INTO v_entrada_ae, v_personas_ae, v_altas_ae, v_cambios_ae
    FROM bdm_tempo.stg_nov_acteco_etapa_1;

  -- SUM() sobre cero filas devuelve NULL, no 0. Mismo cuidado que arriba.
  v_altas_ae   := COALESCE(v_altas_ae, 0);
  v_cambios_ae := COALESCE(v_cambios_ae, 0);

  -- Las bajas van a 0 LITERAL y no a un conteo: este dominio no las emite
  -- nunca. Su Severidad no tiene rama que devuelva 2 (120.TPT:186-197), de
  -- modo que el DELETE del 130.TPT:753 es codigo muerto. Contar 'E' aqui
  -- sugeriria que puede haberlas.
  CALL bdm_datos.sp_rcn_ctl_nov_etapa_marcar(v_corrida_id, v_lote, 'actividad_economica',
                                          'completado', v_entrada_ae, v_personas_ae,
                                          v_altas_ae, v_cambios_ae, 0);

  -- ---------- dominio UBICACION AGREGADA ----------
  -- Va DESPUES de Ubicacion porque LEE SUS DOS ETAPAS -- once puntos de
  -- lectura, cinco de la etapa 2 y seis de la etapa 9 -- y no por convencion.
  -- Invertido el orden saldria vacio por un efecto de secuencia y no por un
  -- defecto, que es la misma leccion del ciclo GEO y de Novedades entera.
  -- Y despues de Actividad Economica, que es el orden en que el 111.BTQ
  -- invoca los diez SP del legado.
  CALL bdm_datos.sp_rcn_ctl_nov_etapa_marcar(v_corrida_id, v_lote, 'ubi_agregada',
                                          'en proceso', NULL, NULL, NULL, NULL, NULL);

  CALL bdm_datos.sp_novedades_ubi_agregada_edf();
  CALL bdm_datos.sp_novedades_cargar_mat_ubi_agregada_edf(v_lote);

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
    FROM bdm_tempo.stg_nov_ubiagr_sev;

  -- SUM() sobre cero filas devuelve NULL, no 0. Mismo cuidado que arriba.
  v_altas_ag   := COALESCE(v_altas_ag, 0);
  v_cambios_ag := COALESCE(v_cambios_ag, 0);

  -- Las bajas van a 0 LITERAL, igual que en Actividad Economica: la Severidad
  -- de este dominio no tiene rama que devuelva 2 (120.TPT:406-442), de modo
  -- que el DELETE del 130.TPT:1135-1147 es codigo muerto.
  CALL bdm_datos.sp_rcn_ctl_nov_etapa_marcar(v_corrida_id, v_lote, 'ubi_agregada',
                                          'completado', v_entrada_ag, v_personas_ag,
                                          v_altas_ag, v_cambios_ag, 0);

  -- Ahora si: bdm_tempo es compartido y una tabla huerfana confunde al
  -- siguiente que mire.
  DROP TABLE IF EXISTS bdm_tempo.stg_nov_ubiagr_sev;

  -- ---------- CONTACTABILIDAD ----------
  -- VA DESPUES DE UBICACION PORQUE SU UNIVERSO ES LA ETAPA 9, igual que en
  -- el legado: las cuatro consultas que leen V_CONTACTABILIDAD la cruzan con
  -- INNER JOIN TMP_UBICA_ETAPA_9 (Novedad.sql:272, :357, :432, :618).
  -- Invertido el orden saldria vacio por un efecto de secuencia y no por un
  -- defecto, que es la leccion del ciclo GEO y de Novedades entera.
  --
  -- ESTE DOMINIO SALE CON DIEZ DE SUS DOCE COLUMNAS EN NULL, y es
  -- deliberado: no existe la fuente de gestion (D-NOV-08, justificado en
  -- sp_novedades_contactabilidad_edf.sql). Las metricas que se registran lo
  -- reflejan sin disfrazarlo.
  CALL bdm_datos.sp_rcn_ctl_nov_etapa_marcar(v_corrida_id, v_lote, 'contactabilidad',
                                          'en proceso', NULL, NULL, NULL, NULL, NULL);

  CALL bdm_datos.sp_novedades_contactabilidad_edf(v_lote);

  SELECT COUNT(*), COUNT(DISTINCT ubicacion_id)
    INTO v_entrada_ct, v_personas_ct
    FROM bdm_datos.mat_info_contactabilidad;

  -- ALTAS, CAMBIOS Y BAJAS VAN A NULL Y NO A CERO, y la diferencia importa:
  -- el contrato de este dominio es FOTO COMPLETA (TRUNCATE + INSERT, como el
  -- DELETE ... ALL de 111.BTQ:820), de modo que no hay estado previo contra
  -- el que calcular un delta. Un 0 diria "las busque y no habia"; NULL dice
  -- "no hay con que medirlas". Es la misma distincion de las columnas por_*
  -- del censo de Ordenamiento (F1-08) y la leccion de NOV-UB-12.
  --   personas_ct cuenta UBICACIONES DISTINTAS, no personas: el grano de esta
  --   tabla es la ubicacion porque id y sector salen en NULL. La columna del
  --   control se llama personas y aqui lleva ubicaciones; queda dicho.
  CALL bdm_datos.sp_rcn_ctl_nov_etapa_marcar(v_corrida_id, v_lote, 'contactabilidad',
                                          'completado', v_entrada_ct, v_personas_ct,
                                          NULL, NULL, NULL);

  -- ---------- INFO BASICA ----------
  -- ESTE DOMINIO NO DEPENDE DE UBICACION, al contrario de los otros cuatro.
  -- El legado arranca de la RPU pero termina en la UNION de dos ramas
  -- (Novedad.sql:3778-3784): personas CON datos de ubicacion y personas SIN
  -- ellos, de modo que la union vuelve a abrir el universo a toda persona.
  -- Va aqui por el orden en que el 111.BTQ invoca los SP del legado, no por
  -- una dependencia: podria ir primero sin cambiar el resultado.
  --
  -- DIECINUEVE de las 22 columnas se pueblan. Las tres que no:
  -- tipo_identificacion (falta el catalogo C37), pagina_web (NO EXISTE en
  -- EDF, CCBR 251264543) y mosaic_id (decision legal, D-NOV-07). Detalle en
  -- sp_novedades_info_basica_edf.sql.
  CALL bdm_datos.sp_rcn_ctl_nov_etapa_marcar(v_corrida_id, v_lote, 'info_basica',
                                          'en proceso', NULL, NULL, NULL, NULL, NULL);

  CALL bdm_datos.sp_novedades_info_basica_edf(v_lote);

  SELECT COUNT(*), COUNT(DISTINCT id)
    INTO v_entrada_ib, v_personas_ib
    FROM bdm_datos.mat_info_basica;

  -- ALTAS, CAMBIOS Y BAJAS VAN A NULL Y NO A CERO, por el mismo motivo que en
  -- CONTACTABILIDAD: el contrato es FOTO COMPLETA (TRUNCATE + INSERT, como el
  -- DELETE ... ALL de 111.BTQ:820) y no hay estado previo contra el que
  -- calcular un delta. Un 0 diria "los busque y no habia".
  --   entrada y personas DEBEN COINCIDIR: el grano es una fila por persona y
  --   la vista ya lo garantiza. Si divergen, hay fan-out y es un defecto.
  CALL bdm_datos.sp_rcn_ctl_nov_etapa_marcar(v_corrida_id, v_lote, 'info_basica',
                                          'completado', v_entrada_ib, v_personas_ib,
                                          NULL, NULL, NULL);

  -- ---------- PUNTO DE INTERES ----------
  -- VA DESPUES DE UBICACION porque su universo se acota por la etapa 9: el
  -- legado parte de (SELECT COD_DW_UBIC ... FROM TMP_UBICA_ETAPA_9 GROUP BY 1)
  -- e INNER JOIN contra la relacion (Novedad.sql:4807-4808).
  --
  -- Y DEPENDE DE QUE LAS DISTANCIAS GEO YA ESTEN CARGADAS. En la via REAL lo
  -- estan: sp_rcn_geo_02_buscar_resultados hace el COPY de
  -- distancias_result_* dentro del ciclo de Unificacion, que corre antes que
  -- Novedades. En la via MOCK no, y a proposito: el ciclo GEO mock corre
  -- ENTRE la convergencia y el tablero, nunca dentro del e2e, porque metido
  -- dentro tumbaria CA-01 por un efecto de orden. De modo que en mock esta
  -- etapa registra cero en las tres fases -- que es la verdad en ese
  -- instante -- y la tabla la puebla run_geo_ciclo_mock.sql despues. Es la
  -- misma leccion del orden que ya costo el ciclo GEO y Novedades entera.
  --
  -- SIETE de las diez columnas se pueblan. Las tres que no: tipo (falta
  -- V_Hom_Tipo_Pto_Int_Linea), nombre_entidad y nit_entidad (falta
  -- RELACION_PUNTO_INTERES_X_PERS, que no viaja en el contrato de
  -- distancias). Detalle en sp_novedades_punto_interes_edf.sql.
  CALL bdm_datos.sp_rcn_ctl_nov_etapa_marcar(v_corrida_id, v_lote, 'punto_interes',
                                          'en proceso', NULL, NULL, NULL, NULL, NULL);

  CALL bdm_datos.sp_novedades_punto_interes_edf(v_lote);

  SELECT COUNT(*), COUNT(DISTINCT ubicacion_id)
    INTO v_entrada_pi, v_ubic_pi
    FROM bdm_datos.mat_info_punto_interes;

  -- ALTAS, CAMBIOS Y BAJAS EN NULL, igual que en los otros dos dominios de
  -- foto completa: no hay estado previo contra el que calcular un delta.
  --   entrada > ubicaciones es LO ESPERADO aqui, al contrario de INFO
  --   BASICA: el grano es (ubicacion, punto de interes) y una ubicacion
  --   tiene varios puntos. Si fueran iguales, el 1:N no se estaria
  --   ejercitando.
  CALL bdm_datos.sp_rcn_ctl_nov_etapa_marcar(v_corrida_id, v_lote, 'punto_interes',
                                          'completado', v_entrada_pi, v_ubic_pi,
                                          NULL, NULL, NULL);

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

    CALL bdm_datos.sp_rcn_ctl_nov_cerrar(v_corrida_id, 'completado', v_wm_nuevo,
                                      v_entrada, v_personas, v_escritas);

    RAISE INFO 'sp_novedades_ciclo_edf: corrida % lote % modo % completada; entrada %, personas %, altas %, cambios %, bajas %.',
      v_corrida_id, v_lote, v_modo, v_entrada, v_personas, v_altas, v_cambios, v_bajas;

END;
$$;
