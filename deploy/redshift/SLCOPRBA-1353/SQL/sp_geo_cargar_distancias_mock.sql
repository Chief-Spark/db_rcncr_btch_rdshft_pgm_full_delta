-- ============================================================
-- sp_geo_cargar_distancias_mock  (Reconocer / GEO MOCK - d7)
-- (repo pgm / db_rcncr_btch_rdshft_pgm). UTF-8 sin BOM, sin acentos.
--
-- ESPEJO MOCK de sp_geo_cargar_distancias. Generado por SUSTITUCION DE
-- FUENTES: no se edita a mano. Regenerar con
-- tools/gen_geo_espejo_distancias.py. Mapa:
--     geo_distancias            -> geo_distancias_mock
--     geo_lote_control          -> geo_lote_control_mock
--     geo_config                -> geo_config_mock
--     stg_arcgis_distancias     -> stg_mock_arcgis_distancias
--     stg_distancias_*          -> stg_mock_distancias_*
--     stg_geo_distancias_crudo  -> bdm_stage.mock_geo_distancias
--
-- DIFIERE DEL REAL EN EL ORIGEN Y EN NADA MAS. El real ya traia DOS
-- ORIGENES para el mismo contrato -- COPY cuando in_s3_path empieza por
-- 's3://' y lectura de una temporal en cualquier otro caso --, de modo que
-- el espejo no necesita tocar el COPY: basta que la rama alternativa lea
-- bdm_stage.mock_geo_distancias, que ES el archivo de vuelta con las mismas
-- 12 columnas crudas del contrato Salida_Distancias. A partir de ahi todo es
-- identico: gate de estado del Lote, gate de conteo, conciliacion de tipos
-- con validacion antes de castear, rechazo de filas invalidas, deduplicacion
-- por la clave 1:N, snapshot y reemplazo atomico del delta.
--
-- POR QUE EXISTE: hasta hoy la via mock NO TENIA DISTANCIAS -- 03b lo decia
-- en redondo: "sigue sin haber geo_distancias_mock: las distancias no entran
-- en ninguno de los cinco criterios GEO" --, y sin ellas la tabla dominio
-- mat_info_punto_interes (d7) saldria VACIA en la bateria. Una tabla vacia
-- no prueba nada: es la leccion de "un DELTA en cero no prueba que no haya
-- cambios".
--
-- LO QUE ESTO NO CERTIFICA, igual que en georreferenciacion: que el COPY
-- real lea de verdad un archivo de S3. Es una sentencia y su riesgo es de
-- permisos.
-- ============================================================

CREATE OR REPLACE PROCEDURE bdm_datos.sp_geo_cargar_distancias_mock(in_lote INTEGER, in_s3_path VARCHAR)
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
  FROM bdm_datos.geo_lote_control_mock
  WHERE lote = in_lote;

  IF v_estado IS NULL THEN
    RAISE INFO 'sp_geo_cargar_distancias: Lote % inexistente en geo_lote_control; carga rechazada, geo_distancias sin cambios.',
      in_lote;
    RETURN;
  END IF;

  IF v_estado NOT IN ('procesado por ArcGIS_Externo', 'cargado') THEN
    RAISE INFO 'sp_geo_cargar_distancias: Lote % en estado invalido "%" (se requiere "procesado por ArcGIS_Externo" o "cargado"); carga rechazada, geo_distancias sin cambios.',
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
  FROM bdm_datos.geo_config_mock
  WHERE ambiente = v_ambiente AND parametro = 'iam_role';
  IF v_iam_role IS NULL THEN
    RAISE EXCEPTION 'sp_geo_cargar_distancias: parametro de configuracion ausente: iam_role (ambiente %).', v_ambiente;
  END IF;

  SELECT valor INTO v_delimiter
  FROM bdm_datos.geo_config_mock
  WHERE ambiente = v_ambiente AND parametro = 'delimiter';
  IF v_delimiter IS NULL THEN
    RAISE EXCEPTION 'sp_geo_cargar_distancias: parametro de configuracion ausente: delimiter (ambiente %).', v_ambiente;
  END IF;

  SELECT valor INTO v_null_string
  FROM bdm_datos.geo_config_mock
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
  --    Mapeo de columnas crudas al contrato Salida_Distancias
  --    (Salida_Geo.pdf, seccion 3):
  --      col01 Cod_DW_Ubic              -> BIGINT
  --      col02 Lote                     -> INTEGER
  --      col03 Direccion                (no se guarda)
  --      col04 Latitud                  -> DECIMAL(38,8) [-90, 90]
  --      col05 Longitud                 -> DECIMAL(38,8) [-180, 180]
  --      col06 Descripcion_Proceso      (DISTANCIAS)
  --      col07 Tipo_Punto_Interes       (clave 1:N)
  --      col08 Nombre_Punto_Interes     -> VARCHAR(200) (2026-10-21, d7)
  --            Hasta hoy decia "no se guarda: geo_distancias no tiene
  --            columna; va con Novedades d7". Ya tiene columna: es la columna
  --            NOMBRE de MAT_INFO_PUNTO_INTERES (Novedad.sql:4794).
  --            NO SE VALIDA Y NO ENTRA EN NINGUN PREDICADO: es opcional, y
  --            meterla en el WHERE cambiaria el conteo de rechazo, que es
  --            justo lo que miden los criterios GEO. Solo se trunca a 200,
  --            que es el ancho del contrato de salida (SCHEMA P0035_13,
  --            130.TPT:149); el crudo llega en VARCHAR(500) y un literal mas
  --            largo que su columna es un [REDSHIFT:112].
  --      col09 Latitud_Punto_Interes    -> DECIMAL(38,8) [-90, 90]
  --      col10 Longitud_Punto_Interes   -> DECIMAL(38,8) [-180, 180]
  --      col11 Distancia_Punto_Interes  -> INTEGER metros [0, 2147483647]
  --      col12 Cod_Punto_Interes_Host   (clave 1:N)
  -- ----------------------------------------------------------
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_arcgis_distancias;
  CREATE TABLE bdm_tempo.stg_mock_arcgis_distancias (
    col01  VARCHAR(500),   -- Cod_DW_Ubic
    col02  VARCHAR(500),   -- Lote
    col03  VARCHAR(500),   -- Direccion
    col04  VARCHAR(500),   -- Latitud
    col05  VARCHAR(500),   -- Longitud
    col06  VARCHAR(500),   -- Descripcion_Proceso (DISTANCIAS)
    col07  VARCHAR(500),   -- Tipo_Punto_Interes
    col08  VARCHAR(500),   -- Nombre_Punto_Interes
    col09  VARCHAR(500),   -- Latitud_Punto_Interes
    col10  VARCHAR(500),   -- Longitud_Punto_Interes
    col11  VARCHAR(500),   -- Distancia_Punto_Interes
    col12  VARCHAR(500)    -- Cod_Punto_Interes_Host
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
       'COPY bdm_tempo.stg_mock_arcgis_distancias'
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
    IF LOWER(LEFT(BTRIM(in_s3_path), 5)) = 's3://' THEN
      EXECUTE v_copy_sql;
      -- Contrato por Lote: si la ruta trae varios Lotes, solo entran las
      -- filas del Lote en proceso.
      DELETE FROM bdm_tempo.stg_mock_arcgis_distancias
      WHERE COALESCE(BTRIM(col02), '') <> in_lote::VARCHAR;
    ELSE
      INSERT INTO bdm_tempo.stg_mock_arcgis_distancias
      SELECT col01, col02, col03, col04, col05, col06,
             col07, col08, col09, col10, col11, col12
      FROM bdm_stage.mock_geo_distancias
      WHERE BTRIM(col02) = in_lote::VARCHAR;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    UPDATE bdm_datos.geo_lote_control_mock
    SET estado              = 'fallido',
        fase_fallo          = 'distancias',
        ultimo_error        = LEFT('COPY distancias fallido: ' || SQLERRM, 500),
        fecha_actualizacion = GETDATE()
    WHERE lote = in_lote;

    DROP TABLE IF EXISTS bdm_tempo.stg_mock_arcgis_distancias;
    RAISE INFO 'sp_geo_cargar_distancias: Lote % marcado fallido (fase distancias): %. Ejecucion global NO abortada.',
      in_lote, SQLERRM;
    RETURN;
  END;

  SELECT COUNT(*) INTO v_conteo_crudo
  FROM bdm_tempo.stg_mock_arcgis_distancias;

  -- ----------------------------------------------------------
  -- 6) Construccion del delta validado en bdm_tempo.stg_mock_distancias_delta.
  --    Conciliacion de tipos y validacion por regex ANTES de castear (sin
  --    TRY_CAST): se conservan SOLO las filas validas (Req 4.3, 4.7, 5.6).
  --    Reglas de validacion aplicadas a cada fila del staging crudo:
  --      - Clave 1:N (col01, col07, col12) no nula ni vacia tras BTRIM (Req 4.2, 4.3).
  --      - Cod_DW_Ubic (col01): entero, convertible a BIGINT en rango
  --        [-9223372036854775808, 9223372036854775807] (Req 5.1, 5.7).
  --      - Lote (col02): entero, convertible a INTEGER en rango
  --        [-2147483648, 2147483647] cuando trae valor (Req 5.2, 5.7).
  --      - Latitud/Longitud (col04-col05) y Lat_POI/Long_POI (col09-col10): decimal con punto
  --        como separador (se rechaza la coma decimal, Req 5.4), en rango
  --        [-90, 90] para latitudes y [-180, 180] para longitudes (Req 5.3).
  --      - Distancia_Punto_Interes (col11): entero NO negativo en rango
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
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_distancias_delta;
  CREATE TABLE bdm_tempo.stg_mock_distancias_delta (
    cod_dw_ubic               BIGINT       NOT NULL,
    lote                      INTEGER      NOT NULL,
    tipo_punto_interes        VARCHAR(60)  NOT NULL,
    cod_punto_interes_host    VARCHAR(60)  NOT NULL,
    latitud                   DECIMAL(38,8),
    longitud                  DECIMAL(38,8),
    latitud_punto_interes     DECIMAL(38,8),
    longitud_punto_interes    DECIMAL(38,8),
    distancia_punto_interes   INTEGER      NOT NULL,
    nombre_punto_interes      VARCHAR(200)
  )
  DISTSTYLE EVEN;

  INSERT INTO bdm_tempo.stg_mock_distancias_delta (
    cod_dw_ubic, lote, tipo_punto_interes, cod_punto_interes_host,
    latitud, longitud, latitud_punto_interes, longitud_punto_interes,
    distancia_punto_interes, nombre_punto_interes
  )
  SELECT
      CAST(BTRIM(s.col01) AS BIGINT)                                  AS cod_dw_ubic,
      in_lote                                                         AS lote,
      BTRIM(s.col07)                                                  AS tipo_punto_interes,
      BTRIM(s.col12)                                                  AS cod_punto_interes_host,
      CASE WHEN s.col04 IS NULL OR BTRIM(s.col04) = '' THEN NULL
           ELSE CAST(BTRIM(s.col04) AS DECIMAL(38,8)) END             AS latitud,
      CASE WHEN s.col05 IS NULL OR BTRIM(s.col05) = '' THEN NULL
           ELSE CAST(BTRIM(s.col05) AS DECIMAL(38,8)) END             AS longitud,
      CASE WHEN s.col09 IS NULL OR BTRIM(s.col09) = '' THEN NULL
           ELSE CAST(BTRIM(s.col09) AS DECIMAL(38,8)) END             AS latitud_punto_interes,
      CASE WHEN s.col10 IS NULL OR BTRIM(s.col10) = '' THEN NULL
           ELSE CAST(BTRIM(s.col10) AS DECIMAL(38,8)) END             AS longitud_punto_interes,
      CAST(BTRIM(s.col11) AS INTEGER)                                 AS distancia_punto_interes,
      -- 2026-10-21 (d7). NULLIF para que un nombre vacio sea NULL y no '';
      -- LEFT a 200 porque el crudo es VARCHAR(500) y el destino 200.
      NULLIF(LEFT(BTRIM(s.col08), 200), '')                           AS nombre_punto_interes
  FROM bdm_tempo.stg_mock_arcgis_distancias s
  WHERE
    -- Clave 1:N no nula ni vacia (Req 4.2, 4.3)
        s.col01 IS NOT NULL AND BTRIM(s.col01) <> ''
    AND s.col07 IS NOT NULL AND BTRIM(s.col07) <> ''
    AND s.col12 IS NOT NULL AND BTRIM(s.col12) <> ''
    -- Cod_DW_Ubic entero convertible a BIGINT en rango (Req 5.1, 5.7)
    AND BTRIM(s.col01) SIMILAR TO '[+-]?[0-9]+'
    AND CAST(BTRIM(s.col01) AS DECIMAL(38,0)) BETWEEN -9223372036854775808 AND 9223372036854775807
    -- Lote entero convertible a INTEGER en rango cuando trae valor (Req 5.2, 5.7)
    AND (s.col02 IS NULL OR BTRIM(s.col02) = ''
         OR (BTRIM(s.col02) SIMILAR TO '[+-]?[0-9]+'
             AND CAST(BTRIM(s.col02) AS DECIMAL(38,0)) BETWEEN -2147483648 AND 2147483647))
    -- Longitud del campo clave dentro del tamano de destino (VARCHAR(60))
    AND LENGTH(BTRIM(s.col07)) <= 60
    AND LENGTH(BTRIM(s.col12)) <= 60
    -- Latitud/Longitud opcionales: si tienen valor, decimal con punto y rango (Req 5.3, 5.4)
    AND (s.col04 IS NULL OR BTRIM(s.col04) = ''
         OR (BTRIM(s.col04) SIMILAR TO '[+-]?[0-9]+(\.[0-9]+)?'
             AND CAST(BTRIM(s.col04) AS DECIMAL(38,8)) BETWEEN -90 AND 90))
    AND (s.col05 IS NULL OR BTRIM(s.col05) = ''
         OR (BTRIM(s.col05) SIMILAR TO '[+-]?[0-9]+(\.[0-9]+)?'
             AND CAST(BTRIM(s.col05) AS DECIMAL(38,8)) BETWEEN -180 AND 180))
    AND (s.col09 IS NULL OR BTRIM(s.col09) = ''
         OR (BTRIM(s.col09) SIMILAR TO '[+-]?[0-9]+(\.[0-9]+)?'
             AND CAST(BTRIM(s.col09) AS DECIMAL(38,8)) BETWEEN -90 AND 90))
    AND (s.col10 IS NULL OR BTRIM(s.col10) = ''
         OR (BTRIM(s.col10) SIMILAR TO '[+-]?[0-9]+(\.[0-9]+)?'
             AND CAST(BTRIM(s.col10) AS DECIMAL(38,8)) BETWEEN -180 AND 180))
    -- Distancia_Punto_Interes entero NO negativo en [0, 2147483647] (Req 4.6, 4.7)
    AND s.col11 IS NOT NULL AND BTRIM(s.col11) <> ''
    AND BTRIM(s.col11) SIMILAR TO '[+]?[0-9]+'
    AND CAST(BTRIM(s.col11) AS DECIMAL(38,0)) BETWEEN 0 AND 2147483647;

  SELECT COUNT(*) INTO v_conteo_delta
  FROM bdm_tempo.stg_mock_distancias_delta;

  v_conteo_rechazo := COALESCE(v_conteo_crudo, 0) - COALESCE(v_conteo_delta, 0);

  RAISE INFO 'sp_geo_cargar_distancias: Lote % - filas crudas=%, delta valido=%, rechazadas=% (clave nula/vacia, no convertibles, coma decimal, fuera de rango o distancia negativa/no entera).',
    in_lote, v_conteo_crudo, v_conteo_delta, v_conteo_rechazo;

  -- ==========================================================
  -- SECCION REEMPLAZO ATOMICO DELTA (task 5.2)
  -- ----------------------------------------------------------
  -- Reemplaza el delta del Lote en bdm_datos.geo_distancias_mock mediante
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
  FROM bdm_tempo.stg_mock_distancias_delta;

  IF COALESCE(v_conteo_dup, 0) > 0 THEN
    DROP TABLE IF EXISTS bdm_tempo.stg_mock_distancias_delta_dedup;
    CREATE TABLE bdm_tempo.stg_mock_distancias_delta_dedup (LIKE bdm_tempo.stg_mock_distancias_delta);

    INSERT INTO bdm_tempo.stg_mock_distancias_delta_dedup (
      cod_dw_ubic, lote, tipo_punto_interes, cod_punto_interes_host,
      latitud, longitud, latitud_punto_interes, longitud_punto_interes,
      distancia_punto_interes, nombre_punto_interes
    )
    SELECT
      cod_dw_ubic, lote, tipo_punto_interes, cod_punto_interes_host,
      latitud, longitud, latitud_punto_interes, longitud_punto_interes,
      distancia_punto_interes, nombre_punto_interes
    FROM (
      SELECT d.*,
             ROW_NUMBER() OVER (
               PARTITION BY cod_dw_ubic, tipo_punto_interes, cod_punto_interes_host
               ORDER BY distancia_punto_interes ASC,
                        latitud_punto_interes, longitud_punto_interes
             ) AS rn
      FROM bdm_tempo.stg_mock_distancias_delta d
    ) q
    WHERE q.rn = 1;

    DROP TABLE bdm_tempo.stg_mock_distancias_delta;
    ALTER TABLE bdm_tempo.stg_mock_distancias_delta_dedup RENAME TO stg_mock_distancias_delta;

    SELECT COUNT(*) INTO v_conteo_delta FROM bdm_tempo.stg_mock_distancias_delta;
    RAISE INFO 'sp_geo_cargar_distancias: Lote % - delta deduplicado por clave 1:N: % filas duplicadas descartadas, delta unico=%.',
      in_lote, v_conteo_dup, v_conteo_delta;
  END IF;

  -- 7.2) Snapshot de las filas actuales del Lote (para restaurar ante fallo).
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_distancias_prev;
  CREATE TABLE bdm_tempo.stg_mock_distancias_prev (LIKE bdm_datos.geo_distancias_mock);
  INSERT INTO bdm_tempo.stg_mock_distancias_prev
  SELECT * FROM bdm_datos.geo_distancias_mock WHERE lote = in_lote;

  SELECT COUNT(*) INTO v_conteo_previo FROM bdm_tempo.stg_mock_distancias_prev;

  -- 7.3) Reemplazo atomico (DELETE del Lote + INSERT del delta) con
  --      restauracion del snapshot ante cualquier fallo.
  BEGIN
    DELETE FROM bdm_datos.geo_distancias_mock WHERE lote = in_lote;

    INSERT INTO bdm_datos.geo_distancias_mock (
      cod_dw_ubic, lote, tipo_punto_interes, cod_punto_interes_host,
      latitud, longitud, latitud_punto_interes, longitud_punto_interes,
      distancia_punto_interes, nombre_punto_interes,
      fecha_actualizacion, usuario_bd
    )
    SELECT
      cod_dw_ubic, lote, tipo_punto_interes, cod_punto_interes_host,
      latitud, longitud, latitud_punto_interes, longitud_punto_interes,
      distancia_punto_interes, nombre_punto_interes,
      TRUNC(GETDATE())   AS fecha_actualizacion,
      CURRENT_USER       AS usuario_bd
    FROM bdm_tempo.stg_mock_distancias_delta;
  EXCEPTION WHEN OTHERS THEN
    -- Restaurar exactamente las filas previas del Lote (todo o nada).
    DELETE FROM bdm_datos.geo_distancias_mock WHERE lote = in_lote;
    INSERT INTO bdm_datos.geo_distancias_mock
    SELECT * FROM bdm_tempo.stg_mock_distancias_prev;

    UPDATE bdm_datos.geo_lote_control_mock
    SET estado              = 'fallido',
        fase_fallo          = 'distancias',
        ultimo_error        = LEFT('Reemplazo delta distancias fallido (restaurado): ' || SQLERRM, 500),
        fecha_actualizacion = GETDATE()
    WHERE lote = in_lote;

    DROP TABLE IF EXISTS bdm_tempo.stg_mock_arcgis_distancias;
    DROP TABLE IF EXISTS bdm_tempo.stg_mock_distancias_delta;
    DROP TABLE IF EXISTS bdm_tempo.stg_mock_distancias_prev;

    RAISE INFO 'sp_geo_cargar_distancias: Lote % - fallo en reemplazo del delta; filas previas restauradas (% filas). Lote marcado fallido (fase distancias). Ejecucion global NO abortada: %.',
      in_lote, v_conteo_previo, SQLERRM;
    RETURN;
  END;

  -- 7.4) Verificacion de idempotencia: el conteo del Lote debe igualar al delta.
  SELECT COUNT(*) INTO v_conteo_final
  FROM bdm_datos.geo_distancias_mock
  WHERE lote = in_lote;

  RAISE INFO 'sp_geo_cargar_distancias: Lote % - reemplazo atomico completado. Filas previas=%, insertadas (delta)=%, finales en geo_distancias=%.',
    in_lote, v_conteo_previo, v_conteo_delta, v_conteo_final;

  -- 7.5) Marcar el Lote 'cargado' (fase distancias completada, Req 4.4).
  -- 2026-10-20: ya no escribe conteo_cargado. Es el conteo de la
  -- georreferenciacion (su gate de conteo); las distancias lo pisaban con su
  -- propio total de filas, que es otro grano (1:N). Su conteo va al INFO.
  UPDATE bdm_datos.geo_lote_control_mock
  SET estado              = 'cargado',
      fase_fallo          = NULL,
      ultimo_error        = NULL,
      fecha_actualizacion = GETDATE()
  WHERE lote = in_lote;

  -- 7.6) Limpieza del staging temporal y efimero (Req 4.8).
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_arcgis_distancias;
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_distancias_delta;
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_distancias_prev;

  -- ==========================================================

EXCEPTION WHEN OTHERS THEN
  RAISE EXCEPTION 'sp_geo_cargar_distancias failed: %', SQLERRM;
END;
$$;
-- SLCOPRBA-1355: re-DPLY DEV post DROP SCHEMA strct #256
