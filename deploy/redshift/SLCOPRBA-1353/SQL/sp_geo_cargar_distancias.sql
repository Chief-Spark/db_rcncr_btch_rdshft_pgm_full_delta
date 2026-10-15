-- ============================================================
-- sp_geo_cargar_distancias  (Reconocer / Enriquecimiento GEO - Regla 3)
-- Cargador_GEO (distancias, relacion 1:N):
--   task 5.1: DROP/CREATE + COPY del archivo de Salida_Distancias a staging
--             temporal (12 columnas VARCHAR crudas), validacion de clave 1:N
--             (Cod_DW_Ubic, Tipo_Punto_Interes, Cod_Punto_Interes_Host),
--             conciliacion de tipos y rango de distancia, y construccion del
--             delta validado en un temporal (bdm_tempo.stg_distancias_delta)
--             conservando las filas validas.
--   task 5.2: reemplazo atomico del delta (DELETE+INSERT) sobre
--             bdm_datos.geo_distancias (ver SECCION REEMPLAZO ATOMICO DELTA).
--
-- Se activa por notificacion externa (SQS + Lambda ResultTransfer) que
-- entrega la referencia de Lote y de archivo; NO descubre archivos ni hace
-- polling del bucket (Req 4.1).
--
-- Objeto en bdm_datos; idempotente (CREATE OR REPLACE PROCEDURE).
-- NONATOMIC (el COPY no admite transaccion implicita) y consistente con la
-- cadena de CALL. UTF-8 sin BOM. Nunca GRANT ... TO PUBLIC.
-- Prerrequisitos: _strct desplegado (geo_distancias, geo_lote_control,
--   geo_config, funcion geo_get_config).
-- Ref: .kiro/specs/geo-enriquecimiento-regla3/design.md
--      (Cargador_GEO - sp_geo_cargar_distancias)
--      Requisitos: 4.1, 4.2, 4.3, 4.5, 4.6, 4.7, 4.8 (COPY/staging/clave/rango),
--                  5.1, 5.2, 5.3 (conciliacion de tipos).
--
-- Contrato Salida_Distancias (ArcGIS -> reconocer_output/): 12 columnas,
-- relacion 1:N, Descripcion_Proceso = DISTANCIAS, clave logica
-- (Cod_DW_Ubic, Tipo_Punto_Interes, Cod_Punto_Interes_Host). Todas las
-- columnas se cargan como VARCHAR crudo para tolerar el formato de origen;
-- la conciliacion de tipos y validacion de rango se hace en SQL sobre el
-- staging (sin TRY_CAST: validacion por regex antes de castear).
--
-- Estructura:
--   Pasos 1-6 : validaciones de entrada, gate de estado del Lote, DROP/CREATE
--               staging (12 columnas VARCHAR crudas), COPY dinamico y
--               construccion del delta validado en bdm_tempo.stg_distancias_delta
--               conservando solo las filas validas (task 5.1).
--   SECCION REEMPLAZO ATOMICO DELTA (task 5.2): DELETE del Lote en
--               geo_distancias + INSERT del delta como transaccion atomica,
--               idempotencia por clave y marca del Lote 'cargado'.
-- ============================================================

CREATE OR REPLACE PROCEDURE bdm_datos.sp_geo_cargar_distancias(in_lote INTEGER, in_s3_path VARCHAR)
NONATOMIC
LANGUAGE plpgsql
AS $$
DECLARE
  v_estado          VARCHAR(40);
  v_ambiente        VARCHAR(10);
  v_iam_role        VARCHAR(500);
  v_delimiter       VARCHAR(500);
  v_null_string     VARCHAR(500);
  v_delim_lit       VARCHAR(50);
  v_null_lit        VARCHAR(1000);
  v_s3_path_lit     VARCHAR(2000);
  v_copy_sql        VARCHAR(8000);
  v_conteo_crudo    INTEGER;
  v_conteo_delta    INTEGER;
  v_conteo_rechazo  INTEGER;
  v_conteo_dup      INTEGER;
  v_conteo_previo   INTEGER;
  v_conteo_final    INTEGER;
BEGIN

  -- ----------------------------------------------------------
  -- 1) Validaciones de entrada minimas: Lote e in_s3_path requeridos.
  -- ----------------------------------------------------------
  IF in_lote IS NULL THEN
    RAISE EXCEPTION 'sp_geo_cargar_distancias: in_lote es obligatorio (NULL recibido).';
  END IF;
  IF in_s3_path IS NULL OR BTRIM(in_s3_path) = '' THEN
    RAISE EXCEPTION 'sp_geo_cargar_distancias: in_s3_path es obligatorio (Lote %).', in_lote;
  END IF;

  -- ----------------------------------------------------------
  -- 2) Gate de estado del Lote (coherente con georreferenciacion, Req 7.5).
  --    La carga de distancias forma parte del ciclo de carga del Lote; solo
  --    se admite si el estado registrado es 'procesado por ArcGIS_Externo'.
  --    Cualquier otro estado (o Lote inexistente) rechaza la carga SIN
  --    modificar geo_distancias. El rechazo es local al Lote (RAISE INFO)
  --    para no abortar la ejecucion global ni los demas Lotes.
  -- ----------------------------------------------------------
  SELECT estado, ambiente
    INTO v_estado, v_ambiente
  FROM bdm_datos.geo_lote_control
  WHERE lote = in_lote;

  IF v_estado IS NULL THEN
    RAISE INFO 'sp_geo_cargar_distancias: Lote % inexistente en geo_lote_control; carga rechazada, geo_distancias sin cambios.',
      in_lote;
    RETURN;
  END IF;

  IF v_estado <> 'procesado por ArcGIS_Externo' THEN
    RAISE INFO 'sp_geo_cargar_distancias: Lote % en estado invalido "%" (se requiere "procesado por ArcGIS_Externo"); carga rechazada, geo_distancias sin cambios.',
      in_lote, v_estado;
    RETURN;
  END IF;

  -- ----------------------------------------------------------
  -- 3) Leer parametros de geo_config necesarios para el COPY (Req 8.3).
  --    Si falta alguno, abortar identificando el parametro (Req 8.5). El
  --    ambiente se toma del Lote (snapshot al exportar).
  -- ----------------------------------------------------------
  IF v_ambiente IS NULL OR BTRIM(v_ambiente) = '' THEN
    RAISE EXCEPTION 'sp_geo_cargar_distancias: ambiente no registrado para el Lote % en geo_lote_control.', in_lote;
  END IF;

  SELECT valor INTO v_iam_role
  FROM bdm_datos.geo_config
  WHERE ambiente = v_ambiente AND parametro = 'iam_role';
  IF v_iam_role IS NULL THEN
    RAISE EXCEPTION 'sp_geo_cargar_distancias: parametro de configuracion ausente: iam_role (ambiente %).', v_ambiente;
  END IF;

  SELECT valor INTO v_delimiter
  FROM bdm_datos.geo_config
  WHERE ambiente = v_ambiente AND parametro = 'delimiter';
  IF v_delimiter IS NULL THEN
    RAISE EXCEPTION 'sp_geo_cargar_distancias: parametro de configuracion ausente: delimiter (ambiente %).', v_ambiente;
  END IF;

  SELECT valor INTO v_null_string
  FROM bdm_datos.geo_config
  WHERE ambiente = v_ambiente AND parametro = 'null_string';
  IF v_null_string IS NULL THEN
    RAISE EXCEPTION 'sp_geo_cargar_distancias: parametro de configuracion ausente: null_string (ambiente %).', v_ambiente;
  END IF;

  -- ----------------------------------------------------------
  -- 4) DROP/CREATE de la tabla de staging temporal de distancias.
  --    Salida_Distancias = 12 columnas, relacion 1:N, todas cargadas como
  --    VARCHAR crudo para tolerar el formato de origen; la conciliacion de
  --    tipos, la validacion de clave y de rango se hacen en el paso 6 sobre
  --    el staging (Req 4.1, 5.x). Staging temporal y efimero en bdm_tempo
  --    (patron DROP-CREATE-usar-DROP, Req 4.8): se recrea en cada corrida y
  --    no persiste entre ejecuciones.
  --    Mapeo de columnas crudas al contrato Salida_Distancias:
  --      col01 Cod_DW_Ubic              -> BIGINT
  --      col02 Lote                     -> INTEGER
  --      col03 Descripcion_Proceso      (DISTANCIAS)
  --      col04 Tipo_Punto_Interes       (clave 1:N)
  --      col05 Cod_Punto_Interes_Host   (clave 1:N)
  --      col06 Latitud                  -> DECIMAL(38,8) [-90, 90]
  --      col07 Longitud                 -> DECIMAL(38,8) [-180, 180]
  --      col08 Latitud_Punto_Interes    -> DECIMAL(38,8) [-90, 90]
  --      col09 Longitud_Punto_Interes   -> DECIMAL(38,8) [-180, 180]
  --      col10 Distancia_Punto_Interes  -> INTEGER metros [0, 2147483647]
  --      col11 col12                    reservadas del contrato (12 columnas)
  -- ----------------------------------------------------------
  DROP TABLE IF EXISTS bdm_tempo.stg_arcgis_distancias;
  CREATE TABLE bdm_tempo.stg_arcgis_distancias (
    col01  VARCHAR(500),   -- Cod_DW_Ubic
    col02  VARCHAR(500),   -- Lote
    col03  VARCHAR(500),   -- Descripcion_Proceso (DISTANCIAS)
    col04  VARCHAR(500),   -- Tipo_Punto_Interes
    col05  VARCHAR(500),   -- Cod_Punto_Interes_Host
    col06  VARCHAR(500),   -- Latitud
    col07  VARCHAR(500),   -- Longitud
    col08  VARCHAR(500),   -- Latitud_Punto_Interes
    col09  VARCHAR(500),   -- Longitud_Punto_Interes
    col10  VARCHAR(500),   -- Distancia_Punto_Interes
    col11  VARCHAR(500),
    col12  VARCHAR(500)
  )
  DISTSTYLE EVEN;

  -- ----------------------------------------------------------
  -- 5) COPY dinamico del archivo de Salida_Distancias a staging.
  --    La ruta S3 la entrega la orquestacion externa (in_s3_path); no hay
  --    descubrimiento ni polling (Req 4.1). Formato CSV GZIP UTF-8 con el
  --    delimitador y estandar de nulos configurados; IGNOREHEADER 1 (el
  --    contrato incluye cabecera). Un fallo de COPY es local al Lote: se
  --    marca 'fallido' (fase distancias) sin abortar el global.
  --    Los literales embebidos escapan comillas simples duplicandolas.
  -- ----------------------------------------------------------
  v_delim_lit   := REPLACE(v_delimiter, '''', '''''');
  v_null_lit    := REPLACE(v_null_string, '''', '''''');
  v_s3_path_lit := REPLACE(in_s3_path, '''', '''''');

  v_copy_sql :=
       'COPY bdm_tempo.stg_arcgis_distancias'
    || ' FROM ''' || v_s3_path_lit || ''''
    || ' IAM_ROLE ''' || v_iam_role || ''''
    || ' DELIMITER ''' || v_delim_lit || ''''
    || ' NULL AS ''' || v_null_lit || ''''
    || ' REMOVEQUOTES'
    || ' IGNOREHEADER 1'
    || ' GZIP'
    || ' ACCEPTINVCHARS'
    || ' TRIMBLANKS';

  BEGIN
    EXECUTE v_copy_sql;
  EXCEPTION WHEN OTHERS THEN
    UPDATE bdm_datos.geo_lote_control
    SET estado              = 'fallido',
        fase_fallo          = 'distancias',
        ultimo_error        = LEFT('COPY distancias fallido: ' || SQLERRM, 500),
        fecha_actualizacion = GETDATE()
    WHERE lote = in_lote;

    DROP TABLE IF EXISTS bdm_tempo.stg_arcgis_distancias;
    RAISE INFO 'sp_geo_cargar_distancias: Lote % marcado fallido (fase distancias): %. Ejecucion global NO abortada.',
      in_lote, SQLERRM;
    RETURN;
  END;

  SELECT COUNT(*) INTO v_conteo_crudo
  FROM bdm_tempo.stg_arcgis_distancias;

  -- ----------------------------------------------------------
  -- 6) Construccion del delta validado en bdm_tempo.stg_distancias_delta.
  --    Conciliacion de tipos y validacion por regex ANTES de castear (sin
  --    TRY_CAST): se conservan SOLO las filas validas (Req 4.3, 4.7, 5.6).
  --    Reglas de validacion aplicadas a cada fila del staging crudo:
  --      - Clave 1:N (col01, col04, col05) no nula ni vacia tras BTRIM (Req 4.2, 4.3).
  --      - Cod_DW_Ubic (col01): entero, convertible a BIGINT en rango
  --        [-9223372036854775808, 9223372036854775807] (Req 5.1, 5.7).
  --      - Lote (col02): entero, convertible a INTEGER en rango
  --        [-2147483648, 2147483647] cuando trae valor (Req 5.2, 5.7).
  --      - Latitud/Longitud/Lat_POI/Long_POI (col06-col09): decimal con punto
  --        como separador (se rechaza la coma decimal, Req 5.4), en rango
  --        [-90, 90] para latitudes y [-180, 180] para longitudes (Req 5.3).
  --      - Distancia_Punto_Interes (col10): entero NO negativo en rango
  --        [0, 2147483647]; se rechaza negativo o no entero (Req 4.6, 4.7).
  --    Las expresiones regulares (SIMILAR TO):
  --      entero con signo opcional:  [+-]?[0-9]+
  --      entero NO negativo:         [+]?[0-9]+
  --      decimal con punto:          [+-]?[0-9]+(\.[0-9]+)?
  --    Notas:
  --      - El rango de Cod_DW_Ubic/Lote se comprueba casteando a DECIMAL(38,0)
  --        (que no desborda) y comparando el valor antes del cast final al
  --        tipo de destino; asi se evita overflow de conversion.
  --      - Las latitudes/longitudes NO forman parte de la clave: se conservan
  --        como NULL si vienen nulas/vacias (estandar de nulos del COPY) y solo
  --        se validan cuando traen valor no vacio.
  -- ----------------------------------------------------------
  DROP TABLE IF EXISTS bdm_tempo.stg_distancias_delta;
  CREATE TABLE bdm_tempo.stg_distancias_delta (
    cod_dw_ubic               BIGINT       NOT NULL,
    lote                      INTEGER      NOT NULL,
    tipo_punto_interes        VARCHAR(60)  NOT NULL,
    cod_punto_interes_host    VARCHAR(60)  NOT NULL,
    latitud                   DECIMAL(38,8),
    longitud                  DECIMAL(38,8),
    latitud_punto_interes     DECIMAL(38,8),
    longitud_punto_interes    DECIMAL(38,8),
    distancia_punto_interes   INTEGER      NOT NULL
  )
  DISTSTYLE EVEN;

  INSERT INTO bdm_tempo.stg_distancias_delta (
    cod_dw_ubic, lote, tipo_punto_interes, cod_punto_interes_host,
    latitud, longitud, latitud_punto_interes, longitud_punto_interes,
    distancia_punto_interes
  )
  SELECT
      CAST(BTRIM(s.col01) AS BIGINT)                                  AS cod_dw_ubic,
      in_lote                                                         AS lote,
      BTRIM(s.col04)                                                  AS tipo_punto_interes,
      BTRIM(s.col05)                                                  AS cod_punto_interes_host,
      CASE WHEN s.col06 IS NULL OR BTRIM(s.col06) = '' THEN NULL
           ELSE CAST(BTRIM(s.col06) AS DECIMAL(38,8)) END             AS latitud,
      CASE WHEN s.col07 IS NULL OR BTRIM(s.col07) = '' THEN NULL
           ELSE CAST(BTRIM(s.col07) AS DECIMAL(38,8)) END             AS longitud,
      CASE WHEN s.col08 IS NULL OR BTRIM(s.col08) = '' THEN NULL
           ELSE CAST(BTRIM(s.col08) AS DECIMAL(38,8)) END             AS latitud_punto_interes,
      CASE WHEN s.col09 IS NULL OR BTRIM(s.col09) = '' THEN NULL
           ELSE CAST(BTRIM(s.col09) AS DECIMAL(38,8)) END             AS longitud_punto_interes,
      CAST(BTRIM(s.col10) AS INTEGER)                                 AS distancia_punto_interes
  FROM bdm_tempo.stg_arcgis_distancias s
  WHERE
    -- Clave 1:N no nula ni vacia (Req 4.2, 4.3)
        s.col01 IS NOT NULL AND BTRIM(s.col01) <> ''
    AND s.col04 IS NOT NULL AND BTRIM(s.col04) <> ''
    AND s.col05 IS NOT NULL AND BTRIM(s.col05) <> ''
    -- Cod_DW_Ubic entero convertible a BIGINT en rango (Req 5.1, 5.7)
    AND BTRIM(s.col01) SIMILAR TO '[+-]?[0-9]+'
    AND CAST(BTRIM(s.col01) AS DECIMAL(38,0)) BETWEEN -9223372036854775808 AND 9223372036854775807
    -- Lote entero convertible a INTEGER en rango cuando trae valor (Req 5.2, 5.7)
    AND (s.col02 IS NULL OR BTRIM(s.col02) = ''
         OR (BTRIM(s.col02) SIMILAR TO '[+-]?[0-9]+'
             AND CAST(BTRIM(s.col02) AS DECIMAL(38,0)) BETWEEN -2147483648 AND 2147483647))
    -- Longitud del campo clave dentro del tamano de destino (VARCHAR(60))
    AND LENGTH(BTRIM(s.col04)) <= 60
    AND LENGTH(BTRIM(s.col05)) <= 60
    -- Latitud/Longitud opcionales: si tienen valor, decimal con punto y rango (Req 5.3, 5.4)
    AND (s.col06 IS NULL OR BTRIM(s.col06) = ''
         OR (BTRIM(s.col06) SIMILAR TO '[+-]?[0-9]+(\.[0-9]+)?'
             AND CAST(BTRIM(s.col06) AS DECIMAL(38,8)) BETWEEN -90 AND 90))
    AND (s.col07 IS NULL OR BTRIM(s.col07) = ''
         OR (BTRIM(s.col07) SIMILAR TO '[+-]?[0-9]+(\.[0-9]+)?'
             AND CAST(BTRIM(s.col07) AS DECIMAL(38,8)) BETWEEN -180 AND 180))
    AND (s.col08 IS NULL OR BTRIM(s.col08) = ''
         OR (BTRIM(s.col08) SIMILAR TO '[+-]?[0-9]+(\.[0-9]+)?'
             AND CAST(BTRIM(s.col08) AS DECIMAL(38,8)) BETWEEN -90 AND 90))
    AND (s.col09 IS NULL OR BTRIM(s.col09) = ''
         OR (BTRIM(s.col09) SIMILAR TO '[+-]?[0-9]+(\.[0-9]+)?'
             AND CAST(BTRIM(s.col09) AS DECIMAL(38,8)) BETWEEN -180 AND 180))
    -- Distancia_Punto_Interes entero NO negativo en [0, 2147483647] (Req 4.6, 4.7)
    AND s.col10 IS NOT NULL AND BTRIM(s.col10) <> ''
    AND BTRIM(s.col10) SIMILAR TO '[+]?[0-9]+'
    AND CAST(BTRIM(s.col10) AS DECIMAL(38,0)) BETWEEN 0 AND 2147483647;

  SELECT COUNT(*) INTO v_conteo_delta
  FROM bdm_tempo.stg_distancias_delta;

  v_conteo_rechazo := COALESCE(v_conteo_crudo, 0) - COALESCE(v_conteo_delta, 0);

  RAISE INFO 'sp_geo_cargar_distancias: Lote % - filas crudas=%, delta valido=%, rechazadas=% (clave nula/vacia, no convertibles, coma decimal, fuera de rango o distancia negativa/no entera).',
    in_lote, v_conteo_crudo, v_conteo_delta, v_conteo_rechazo;

  -- ==========================================================
  -- SECCION REEMPLAZO ATOMICO DELTA (task 5.2)
  -- ----------------------------------------------------------
  -- Reemplaza el delta del Lote en bdm_datos.geo_distancias mediante
  -- DELETE (del Lote) + INSERT (del delta validado) con semantica atomica y
  -- garantia de idempotencia (Req 4.4, 7.2).
  --
  -- ENFOQUE DE ATOMICIDAD (Redshift NONATOMIC):
  --   Este SP es NONATOMIC porque el COPY no admite transaccion implicita, y
  --   debe ser coherente con la cadena de CALL (leccion aprendida: mezclar
  --   modos produce P0001). En un SP NONATOMIC de Redshift cada sentencia
  --   se auto-commitea, por lo que un fallo del INSERT despues del DELETE
  --   dejaria el Lote sin filas (perdida no deseada). Ademas Redshift NO
  --   permite control transaccional explicito (BEGIN/COMMIT/ROLLBACK) dentro
  --   de un bloque PL/pgSQL que tenga manejador de excepciones (subtransaccion),
  --   por lo que un "BEGIN ... ROLLBACK" no es viable aqui.
  --
  --   Se opta por el patron SNAPSHOT + RESTAURACION EN FALLO, que ofrece
  --   semantica de "todo o nada" a nivel del Lote sin depender de control
  --   transaccional explicito:
  --     a) Se copian a un temporal (stg_distancias_prev) las filas actuales
  --        del Lote ANTES de tocar la tabla permanente.
  --     b) DELETE de las filas del Lote + INSERT del delta se ejecutan dentro
  --        de un sub-bloque con EXCEPTION. Si el INSERT (o el DELETE) falla,
  --        el manejador re-inserta el snapshot para restaurar exactamente las
  --        filas previas del Lote y marca el Lote 'fallido' (fase distancias)
  --        sin abortar la ejecucion global (Req 4.4).
  --   El snapshot cubre tanto el fallo de INSERT (restaura tras DELETE) como
  --   un DELETE parcial. Como el snapshot solo contiene filas del Lote y el
  --   DELETE/INSERT tambien operan solo sobre ese Lote, la restauracion es
  --   exacta y no afecta a otros Lotes.
  --
  -- IDEMPOTENCIA (Req 7.2): el DELETE elimina todas las filas previas del Lote
  --   antes de insertar; reprocesar el mismo Lote deja el conteo == delta y sin
  --   duplicados. Ademas se deduplica el delta por la clave 1:N
  --   (cod_dw_ubic, tipo_punto_interes, cod_punto_interes_host) para garantizar
  --   unicidad aunque el archivo de origen traiga la clave repetida.
  -- ----------------------------------------------------------

  -- 7.1) Deduplicar el delta por clave 1:N antes del reemplazo. El contrato
  --      1:N admite varias filas por cod_dw_ubic (una por POI), pero la clave
  --      completa (cod_dw_ubic, tipo_punto_interes, cod_punto_interes_host)
  --      debe ser unica. Si el origen trae la clave repetida se conserva una
  --      sola fila (la de menor distancia, desempatando de forma estable) para
  --      no violar la unicidad por clave (Req 7.2).
  SELECT COUNT(*) - COUNT(DISTINCT cod_dw_ubic || '|' || tipo_punto_interes || '|' || cod_punto_interes_host)
    INTO v_conteo_dup
  FROM bdm_tempo.stg_distancias_delta;

  IF COALESCE(v_conteo_dup, 0) > 0 THEN
    DROP TABLE IF EXISTS bdm_tempo.stg_distancias_delta_dedup;
    CREATE TABLE bdm_tempo.stg_distancias_delta_dedup (LIKE bdm_tempo.stg_distancias_delta);

    INSERT INTO bdm_tempo.stg_distancias_delta_dedup (
      cod_dw_ubic, lote, tipo_punto_interes, cod_punto_interes_host,
      latitud, longitud, latitud_punto_interes, longitud_punto_interes,
      distancia_punto_interes
    )
    SELECT
      cod_dw_ubic, lote, tipo_punto_interes, cod_punto_interes_host,
      latitud, longitud, latitud_punto_interes, longitud_punto_interes,
      distancia_punto_interes
    FROM (
      SELECT d.*,
             ROW_NUMBER() OVER (
               PARTITION BY cod_dw_ubic, tipo_punto_interes, cod_punto_interes_host
               ORDER BY distancia_punto_interes ASC,
                        latitud_punto_interes, longitud_punto_interes
             ) AS rn
      FROM bdm_tempo.stg_distancias_delta d
    ) q
    WHERE q.rn = 1;

    DROP TABLE bdm_tempo.stg_distancias_delta;
    ALTER TABLE bdm_tempo.stg_distancias_delta_dedup RENAME TO stg_distancias_delta;

    SELECT COUNT(*) INTO v_conteo_delta FROM bdm_tempo.stg_distancias_delta;
    RAISE INFO 'sp_geo_cargar_distancias: Lote % - delta deduplicado por clave 1:N: % filas duplicadas descartadas, delta unico=%.',
      in_lote, v_conteo_dup, v_conteo_delta;
  END IF;

  -- 7.2) Snapshot de las filas actuales del Lote (para restaurar ante fallo).
  DROP TABLE IF EXISTS bdm_tempo.stg_distancias_prev;
  CREATE TABLE bdm_tempo.stg_distancias_prev (LIKE bdm_datos.geo_distancias);
  INSERT INTO bdm_tempo.stg_distancias_prev
  SELECT * FROM bdm_datos.geo_distancias WHERE lote = in_lote;

  SELECT COUNT(*) INTO v_conteo_previo FROM bdm_tempo.stg_distancias_prev;

  -- 7.3) Reemplazo atomico (DELETE del Lote + INSERT del delta) con
  --      restauracion del snapshot ante cualquier fallo.
  BEGIN
    DELETE FROM bdm_datos.geo_distancias WHERE lote = in_lote;

    INSERT INTO bdm_datos.geo_distancias (
      cod_dw_ubic, lote, tipo_punto_interes, cod_punto_interes_host,
      latitud, longitud, latitud_punto_interes, longitud_punto_interes,
      distancia_punto_interes, fecha_actualizacion, usuario_bd
    )
    SELECT
      cod_dw_ubic, lote, tipo_punto_interes, cod_punto_interes_host,
      latitud, longitud, latitud_punto_interes, longitud_punto_interes,
      distancia_punto_interes,
      TRUNC(GETDATE())   AS fecha_actualizacion,
      CURRENT_USER       AS usuario_bd
    FROM bdm_tempo.stg_distancias_delta;
  EXCEPTION WHEN OTHERS THEN
    -- Restaurar exactamente las filas previas del Lote (todo o nada).
    DELETE FROM bdm_datos.geo_distancias WHERE lote = in_lote;
    INSERT INTO bdm_datos.geo_distancias
    SELECT * FROM bdm_tempo.stg_distancias_prev;

    UPDATE bdm_datos.geo_lote_control
    SET estado              = 'fallido',
        fase_fallo          = 'distancias',
        ultimo_error        = LEFT('Reemplazo delta distancias fallido (restaurado): ' || SQLERRM, 500),
        fecha_actualizacion = GETDATE()
    WHERE lote = in_lote;

    DROP TABLE IF EXISTS bdm_tempo.stg_arcgis_distancias;
    DROP TABLE IF EXISTS bdm_tempo.stg_distancias_delta;
    DROP TABLE IF EXISTS bdm_tempo.stg_distancias_prev;

    RAISE INFO 'sp_geo_cargar_distancias: Lote % - fallo en reemplazo del delta; filas previas restauradas (% filas). Lote marcado fallido (fase distancias). Ejecucion global NO abortada: %.',
      in_lote, v_conteo_previo, SQLERRM;
    RETURN;
  END;

  -- 7.4) Verificacion de idempotencia: el conteo del Lote debe igualar al delta.
  SELECT COUNT(*) INTO v_conteo_final
  FROM bdm_datos.geo_distancias
  WHERE lote = in_lote;

  RAISE INFO 'sp_geo_cargar_distancias: Lote % - reemplazo atomico completado. Filas previas=%, insertadas (delta)=%, finales en geo_distancias=%.',
    in_lote, v_conteo_previo, v_conteo_delta, v_conteo_final;

  -- 7.5) Marcar el Lote 'cargado' (fase distancias completada, Req 4.4).
  UPDATE bdm_datos.geo_lote_control
  SET estado              = 'cargado',
      fase_fallo          = NULL,
      conteo_cargado      = v_conteo_final,
      ultimo_error        = NULL,
      fecha_actualizacion = GETDATE()
  WHERE lote = in_lote;

  -- 7.6) Limpieza del staging temporal y efimero (Req 4.8).
  DROP TABLE IF EXISTS bdm_tempo.stg_arcgis_distancias;
  DROP TABLE IF EXISTS bdm_tempo.stg_distancias_delta;
  DROP TABLE IF EXISTS bdm_tempo.stg_distancias_prev;

  -- ==========================================================

EXCEPTION WHEN OTHERS THEN
  RAISE EXCEPTION 'sp_geo_cargar_distancias failed: %', SQLERRM;
END;
$$;
-- SLCOPRBA-1355: re-DPLY DEV post DROP SCHEMA strct #256
