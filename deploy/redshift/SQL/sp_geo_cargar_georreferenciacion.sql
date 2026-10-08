-- ============================================================
-- sp_geo_cargar_georreferenciacion  (Reconocer / Enriquecimiento GEO - Regla 3)
-- Cargador_GEO (georreferenciacion, relacion 1:1):
--   task 4.1: gate de estado del Lote, DROP/CREATE + COPY del archivo de
--             Salida_Georreferenciacion a staging temporal, y validacion de
--             conteo cargado vs esperado con aislamiento por Lote.
--   task 4.2: conciliacion de tipos y aplicacion por Status M/U a
--             bdm_datos.geo_atributos (ver SECCION APLICACION STATUS M/U).
--
-- Se activa por notificacion externa (SQS + Lambda ResultTransfer) que
-- entrega la referencia de Lote y de archivo; NO descubre archivos ni hace
-- polling del bucket (Req 3.1).
--
-- Objeto en bdm_datos; idempotente (CREATE OR REPLACE PROCEDURE).
-- NONATOMIC (el COPY no admite transaccion implicita) y consistente con la
-- cadena de CALL. UTF-8 sin BOM. Nunca GRANT ... TO PUBLIC.
-- Prerrequisitos: _strct desplegado (geo_atributos, geo_lote_control,
--   geo_config, funcion geo_get_config).
-- Ref: .kiro/specs/geo-enriquecimiento-regla3/design.md
--      (Cargador_GEO - sp_geo_cargar_georreferenciacion)
--      Requisitos: 3.1, 3.2, 3.3, 3.8, 3.9 (COPY/staging/gate de conteo),
--                  7.5 (gate de estado del Lote).
--
-- Estructura:
--   Pasos 1-6 : gate de estado, DROP/CREATE staging (32 columnas VARCHAR
--               crudas), COPY dinamico, gate de conteo cargado vs esperado
--               con aislamiento por Lote (task 4.1).
--   SECCION APLICACION STATUS M/U (task 4.2): conciliacion de tipos,
--               deduplicacion por clave (Cod_DW_Ubic, Lote), UPDATE/UPSERT a
--               geo_atributos segun Status, estados no geocodificada /
--               pendiente de geocodificacion, y marca del Lote 'cargado'.
-- ============================================================

CREATE OR REPLACE PROCEDURE bdm_datos.sp_geo_cargar_georreferenciacion(in_lote INTEGER, in_s3_path VARCHAR)
NONATOMIC
LANGUAGE plpgsql
AS $$
DECLARE
  v_estado          VARCHAR(40);
  v_ambiente        VARCHAR(10);
  v_conteo_esperado INTEGER;
  v_conteo_cargado  INTEGER;
  v_iam_role        VARCHAR(500);
  v_delimiter       VARCHAR(500);
  v_null_string     VARCHAR(500);
  v_delim_lit       VARCHAR(50);
  v_null_lit        VARCHAR(1000);
  v_s3_path_lit     VARCHAR(2000);
  v_copy_sql        VARCHAR(8000);
  v_lote_str        VARCHAR(50);
  v_usuario_bd      VARCHAR(100);
  v_hoy             DATE;
  v_cnt_status_inv  INTEGER;
  v_cnt_dup         INTEGER;
  v_cnt_huerfana    INTEGER;
  v_cnt_no_conv     INTEGER;
  v_cnt_fuera_rango INTEGER;
  v_cnt_aplicadas_m INTEGER;
  v_cnt_aplicadas_u INTEGER;
  v_cnt_pendientes  INTEGER;
BEGIN

  -- ----------------------------------------------------------
  -- 1) Validaciones de entrada minimas: Lote e in_s3_path requeridos.
  -- ----------------------------------------------------------
  IF in_lote IS NULL THEN
    RAISE EXCEPTION 'sp_geo_cargar_georreferenciacion: in_lote es obligatorio (NULL recibido).';
  END IF;
  IF in_s3_path IS NULL OR BTRIM(in_s3_path) = '' THEN
    RAISE EXCEPTION 'sp_geo_cargar_georreferenciacion: in_s3_path es obligatorio (Lote %).', in_lote;
  END IF;

  -- ----------------------------------------------------------
  -- 2) Gate de estado del Lote (Req 7.5).
  --    Solo se admite cargar un Lote cuyo estado registrado sea
  --    'procesado por ArcGIS_Externo'. Cualquier otro estado (o Lote
  --    inexistente) rechaza la carga SIN modificar las tablas permanentes,
  --    indicando el estado invalido. El rechazo es local al Lote (RAISE INFO)
  --    para no abortar la ejecucion global ni los demas Lotes.
  -- ----------------------------------------------------------
  SELECT estado, ambiente, conteo_esperado
    INTO v_estado, v_ambiente, v_conteo_esperado
  FROM bdm_datos.geo_lote_control
  WHERE lote = in_lote;

  IF v_estado IS NULL THEN
    RAISE INFO 'sp_geo_cargar_georreferenciacion: Lote % inexistente en geo_lote_control; carga rechazada, tablas permanentes sin cambios.',
      in_lote;
    RETURN;
  END IF;

  IF v_estado <> 'procesado por ArcGIS_Externo' THEN
    RAISE INFO 'sp_geo_cargar_georreferenciacion: Lote % en estado invalido "%" (se requiere "procesado por ArcGIS_Externo"); carga rechazada, tablas permanentes sin cambios.',
      in_lote, v_estado;
    RETURN;
  END IF;

  -- ----------------------------------------------------------
  -- 3) Leer parametros de geo_config necesarios para el COPY (Req 8.3).
  --    Si falta alguno, abortar identificando el parametro (Req 8.5). El
  --    ambiente se toma del Lote (snapshot al exportar).
  -- ----------------------------------------------------------
  IF v_ambiente IS NULL OR BTRIM(v_ambiente) = '' THEN
    RAISE EXCEPTION 'sp_geo_cargar_georreferenciacion: ambiente no registrado para el Lote % en geo_lote_control.', in_lote;
  END IF;

  SELECT valor INTO v_iam_role
  FROM bdm_datos.geo_config
  WHERE ambiente = v_ambiente AND parametro = 'iam_role';
  IF v_iam_role IS NULL THEN
    RAISE EXCEPTION 'sp_geo_cargar_georreferenciacion: parametro de configuracion ausente: iam_role (ambiente %).', v_ambiente;
  END IF;

  SELECT valor INTO v_delimiter
  FROM bdm_datos.geo_config
  WHERE ambiente = v_ambiente AND parametro = 'delimiter';
  IF v_delimiter IS NULL THEN
    RAISE EXCEPTION 'sp_geo_cargar_georreferenciacion: parametro de configuracion ausente: delimiter (ambiente %).', v_ambiente;
  END IF;

  SELECT valor INTO v_null_string
  FROM bdm_datos.geo_config
  WHERE ambiente = v_ambiente AND parametro = 'null_string';
  IF v_null_string IS NULL THEN
    RAISE EXCEPTION 'sp_geo_cargar_georreferenciacion: parametro de configuracion ausente: null_string (ambiente %).', v_ambiente;
  END IF;

  -- ----------------------------------------------------------
  -- 4) DROP/CREATE de la tabla de staging temporal de georreferenciacion.
  --    Salida_Georreferenciacion = 32 columnas, relacion 1:1, todas cargadas
  --    como VARCHAR crudo para tolerar el formato de origen; la conciliacion
  --    de tipos y validacion de rango se hace en la task 4.2 (Req 3.1, 5.x).
  --    Staging temporal y efimero en bdm_tempo (patron DROP-CREATE-usar-DROP,
  --    Req 3.9): se recrea en cada corrida y no persiste entre ejecuciones.
  -- ----------------------------------------------------------
  DROP TABLE IF EXISTS bdm_tempo.stg_arcgis_georeferenciacion;
  CREATE TABLE bdm_tempo.stg_arcgis_georeferenciacion (
    col01  VARCHAR(500),   -- Cod_DW_Ubic
    col02  VARCHAR(500),   -- Lote
    col03  VARCHAR(500),   -- Status (M | U)
    col04  VARCHAR(500),   -- Descripcion_Proceso (GEOCODE)
    col05  VARCHAR(500),   -- Latitud
    col06  VARCHAR(500),   -- Longitud
    col07  VARCHAR(500),
    col08  VARCHAR(500),
    col09  VARCHAR(500),
    col10  VARCHAR(500),
    col11  VARCHAR(500),
    col12  VARCHAR(500),
    col13  VARCHAR(500),
    col14  VARCHAR(500),
    col15  VARCHAR(500),
    col16  VARCHAR(500),
    col17  VARCHAR(500),
    col18  VARCHAR(500),
    col19  VARCHAR(500),
    col20  VARCHAR(500),
    col21  VARCHAR(500),
    col22  VARCHAR(500),
    col23  VARCHAR(500),
    col24  VARCHAR(500),
    col25  VARCHAR(500),
    col26  VARCHAR(500),
    col27  VARCHAR(500),
    col28  VARCHAR(500),
    col29  VARCHAR(500),
    col30  VARCHAR(500),
    col31  VARCHAR(500),
    col32  VARCHAR(500)
  )
  DISTSTYLE EVEN;

  -- ----------------------------------------------------------
  -- 5) COPY dinamico del archivo de Salida_Georreferenciacion a staging.
  --    La ruta S3 la entrega la orquestacion externa (in_s3_path); no hay
  --    descubrimiento ni polling (Req 3.1). Formato CSV GZIP UTF-8 con el
  --    delimitador y estandar de nulos configurados; IGNOREHEADER 1 (el
  --    contrato incluye cabecera). Un fallo de COPY es local al Lote: se
  --    marca 'fallido' (fase georreferenciacion) sin abortar el global.
  --    Los literales embebidos escapan comillas simples duplicandolas.
  -- ----------------------------------------------------------
  v_delim_lit   := REPLACE(v_delimiter, '''', '''''');
  v_null_lit    := REPLACE(v_null_string, '''', '''''');
  v_s3_path_lit := REPLACE(in_s3_path, '''', '''''');

  v_copy_sql :=
       'COPY bdm_tempo.stg_arcgis_georeferenciacion'
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
        fase_fallo          = 'georreferenciacion',
        ultimo_error        = LEFT('COPY georreferenciacion fallido: ' || SQLERRM, 500),
        fecha_actualizacion = GETDATE()
    WHERE lote = in_lote;

    DROP TABLE IF EXISTS bdm_tempo.stg_arcgis_georeferenciacion;
    RAISE INFO 'sp_geo_cargar_georreferenciacion: Lote % marcado fallido (fase georreferenciacion): %. R3 omitida; ejecucion global NO abortada.',
      in_lote, SQLERRM;
    RETURN;
  END;

  -- ----------------------------------------------------------
  -- 6) Gate de conteo cargado vs esperado, ANTES de aplicar cualquier
  --    actualizacion a geo_atributos (Req 3.3). Si no coincide: abortar la
  --    carga UNICAMENTE de este Lote, conservar geo_atributos sin cambios,
  --    marcar el Lote 'fallido' (fase georreferenciacion) disponible para
  --    reintento, omitir la Regla 3 para el Lote, registrar AMBOS conteos, y
  --    NO abortar la ejecucion global ni los demas Lotes (Req 3.8). Se aisla
  --    con RAISE INFO (no EXCEPTION) y RETURN.
  -- ----------------------------------------------------------
  SELECT COUNT(*) INTO v_conteo_cargado
  FROM bdm_tempo.stg_arcgis_georeferenciacion;

  IF v_conteo_cargado IS DISTINCT FROM v_conteo_esperado THEN
    UPDATE bdm_datos.geo_lote_control
    SET estado              = 'fallido',
        fase_fallo          = 'georreferenciacion',
        conteo_cargado      = v_conteo_cargado,
        ultimo_error        = LEFT('Mismatch de conteo georreferenciacion: esperado='
                                   || COALESCE(v_conteo_esperado::VARCHAR, '<null>')
                                   || ', cargado=' || COALESCE(v_conteo_cargado::VARCHAR, '<null>')
                                   || '.', 500),
        fecha_actualizacion = GETDATE()
    WHERE lote = in_lote;

    DROP TABLE IF EXISTS bdm_tempo.stg_arcgis_georeferenciacion;
    RAISE INFO 'sp_geo_cargar_georreferenciacion: Lote % con mismatch de conteo (esperado=%, cargado=%); carga abortada solo para este Lote, geo_atributos sin cambios, R3 omitida. Ejecucion global NO abortada.',
      in_lote, v_conteo_esperado, v_conteo_cargado;
    RETURN;
  END IF;

  -- Registrar el conteo cargado validado en el control del Lote (trazabilidad).
  UPDATE bdm_datos.geo_lote_control
  SET conteo_cargado      = v_conteo_cargado,
      fecha_actualizacion = GETDATE()
  WHERE lote = in_lote;

  -- ==========================================================
  -- SECCION APLICACION STATUS M/U (task 4.2)
  -- ----------------------------------------------------------
  -- Conciliacion de tipos desde el staging crudo VARCHAR, rechazo selectivo
  -- de filas invalidas conservando las validas, y aplicacion idempotente a
  -- bdm_datos.geo_atributos por cod_dw_ubic segun Status (Req 3.4-3.7, 5.x,
  -- 10.1, 10.3, 11.2). Al finalizar se marca el Lote 'cargado' y se limpia el
  -- staging temporal (Req 3.9).
  --
  -- Estrategia de casteo seguro (Redshift no ofrece TRY_CAST para todos los
  -- tipos): se valida el formato con REGEXP_COUNT anclado (^...$) ANTES de
  -- convertir, de modo que ninguna fila invalida llega a un CAST que abortaria
  -- la sentencia. El punto decimal se expresa con la clase [.] para no depender
  -- del escape de backslash. Las filas que no pasan el filtro se
  -- descartan (rechazo selectivo) y quedan cubiertas por el estado
  -- 'pendiente de geocodificacion' de sus candidatos (Req 5.6, 10.3).
  --
  -- Contrato de tipos (Req 5.1, 5.2, 5.3):
  --   col01 Cod_DW_Ubic -> INTEGER  (rango [-2147483648, 2147483647], Req 5.7)
  --   col02 Lote        -> VARCHAR (se compara como texto con in_lote)
  --   col03 Status      -> {M, U}
  --   col05 Latitud     -> VARCHAR(100) -> DECIMAL, rango [-90, 90]   (Req 5.3, 5.7)
  --   col06 Longitud    -> VARCHAR(100) -> DECIMAL, rango [-180, 180] (Req 5.3, 5.7)
  -- El separador decimal debe ser punto; la coma se rechaza (Req 5.4). Los
  -- patrones ^[+-]?[0-9]+(\.[0-9]+)?$ NO admiten coma, por lo que un valor con
  -- coma decimal cae en el conjunto de "no convertibles" y se descarta.
  -- ----------------------------------------------------------
  v_lote_str   := in_lote::VARCHAR;
  v_usuario_bd := CURRENT_USER;
  v_hoy        := TRUNC(GETDATE());

  -- 7.1) Vista normalizada del staging: recorta espacios y homogeneiza Status.
  --      Se materializa en una tabla temporal para poder clasificar filas
  --      (validas / invalidas) y reutilizarla en varios pasos sin releer S3.
  DROP TABLE IF EXISTS bdm_tempo.stg_geo_norm;
  CREATE TABLE bdm_tempo.stg_geo_norm AS
  SELECT
    BTRIM(col01)          AS cod_dw_ubic_raw,
    BTRIM(col02)          AS lote_raw,
    UPPER(BTRIM(col03))   AS status_raw,
    BTRIM(col05)          AS latitud_raw,
    BTRIM(col06)          AS longitud_raw
  FROM bdm_tempo.stg_arcgis_georeferenciacion;

  -- 7.2) Clasificacion de filas conciliadas. Una fila es CONCILIABLE cuando:
  --      - Cod_DW_Ubic es entero con signo opcional y cabe en INTEGER (Req 5.1, 5.7).
  --      - El Lote del archivo coincide con el Lote en proceso (contrato 1:1 por Lote).
  --      - Status es exactamente 'M' o 'U' (Req 3.7).
  --      - Para Status 'M': lat/long tienen formato decimal con punto (no coma,
  --        Req 5.4), son convertibles (Req 5.6) y estan en rango (Req 5.7).
  --        Para Status 'U' no se exige lat/long (se conserva la previa, Req 3.6).
  --      Se conservan expresiones intermedias para diagnosticar el motivo de
  --      rechazo en los conteos de log.
  DROP TABLE IF EXISTS bdm_tempo.stg_geo_clasif;
  CREATE TABLE bdm_tempo.stg_geo_clasif AS
  SELECT
    n.cod_dw_ubic_raw,
    n.lote_raw,
    n.status_raw,
    n.latitud_raw,
    n.longitud_raw,
    -- Cod_DW_Ubic: entero con signo opcional. Se usa REGEXP_COUNT con ancla
    -- (^...$) y el punto decimal se representa con la clase [.] para NO depender
    -- del escape de backslash dentro del literal dollar-quoted de Redshift.
    (REGEXP_COUNT(n.cod_dw_ubic_raw, '^[+-]?[0-9]+$') = 1)         AS cod_es_entero,
    -- rango INTEGER (se evalua solo si es entero, con CASE para no castear basura)
    (CASE WHEN REGEXP_COUNT(n.cod_dw_ubic_raw, '^[+-]?[0-9]+$') = 1
            AND LENGTH(REGEXP_REPLACE(n.cod_dw_ubic_raw, '[+-]', '')) <= 10
            AND n.cod_dw_ubic_raw::BIGINT BETWEEN -2147483648 AND 2147483647
          THEN TRUE ELSE FALSE END)                                AS cod_en_rango,
    (n.lote_raw = v_lote_str)                                      AS lote_coincide,
    (n.status_raw IN ('M','U'))                                    AS status_valido,
    (n.status_raw = 'M')                                           AS es_match,
    -- Latitud/Longitud: decimal con separador PUNTO (rechaza coma, Req 5.4).
    -- El punto se representa como clase de caracter [.] (literal, sin escape).
    (REGEXP_COUNT(n.latitud_raw,  '^[+-]?[0-9]+([.][0-9]+)?$') = 1) AS lat_formato_ok,
    (REGEXP_COUNT(n.longitud_raw, '^[+-]?[0-9]+([.][0-9]+)?$') = 1) AS lon_formato_ok,
    (CASE WHEN REGEXP_COUNT(n.latitud_raw, '^[+-]?[0-9]+([.][0-9]+)?$') = 1
            AND n.latitud_raw::DECIMAL(38,8) BETWEEN -90 AND 90
          THEN TRUE ELSE FALSE END)                                AS lat_en_rango,
    (CASE WHEN REGEXP_COUNT(n.longitud_raw, '^[+-]?[0-9]+([.][0-9]+)?$') = 1
            AND n.longitud_raw::DECIMAL(38,8) BETWEEN -180 AND 180
          THEN TRUE ELSE FALSE END)                                AS lon_en_rango
  FROM bdm_tempo.stg_geo_norm n;

  -- 7.3) Marca de validez final por fila (conciliacion de tipos + Status).
  --      Una fila 'M' valida requiere lat/long convertibles y en rango; una
  --      fila 'U' valida no requiere coordenadas (Req 3.6, 5.6, 5.7).
  DROP TABLE IF EXISTS bdm_tempo.stg_geo_valida;
  -- Los CAST del SELECT se guardan con las MISMAS condiciones de formato/rango
  -- del WHERE (no solo con es_match) para que ningun valor invalido llegue a un
  -- CAST aunque el planificador evalue la proyeccion antes que el filtro.
  CREATE TABLE bdm_tempo.stg_geo_valida AS
  SELECT
    CASE WHEN c.cod_es_entero AND c.cod_en_rango
         THEN c.cod_dw_ubic_raw::INTEGER END AS cod_dw_ubic,
    c.status_raw                             AS status_match,
    CASE WHEN c.es_match AND c.lat_formato_ok AND c.lat_en_rango
         THEN c.latitud_raw::DECIMAL(10,6)  END AS latitud,
    CASE WHEN c.es_match AND c.lon_formato_ok AND c.lon_en_rango
         THEN c.longitud_raw::DECIMAL(10,6) END AS longitud
  FROM bdm_tempo.stg_geo_clasif c
  WHERE c.cod_es_entero
    AND c.cod_en_rango
    AND c.lote_coincide
    AND c.status_valido
    AND ( c.es_match = FALSE
          OR (c.lat_formato_ok AND c.lon_formato_ok AND c.lat_en_rango AND c.lon_en_rango) );

  -- 7.4) Diagnostico: conteos de rechazo por motivo (Req 3.7, 5.6, 5.7). Se
  --      registran como INFO para trazabilidad sin abortar el Lote.
  SELECT COUNT(*) INTO v_cnt_status_inv
  FROM bdm_tempo.stg_geo_clasif
  WHERE status_valido = FALSE;

  SELECT COUNT(*) INTO v_cnt_no_conv
  FROM bdm_tempo.stg_geo_clasif
  WHERE cod_es_entero = FALSE
     OR (status_raw = 'M' AND (lat_formato_ok = FALSE OR lon_formato_ok = FALSE));

  SELECT COUNT(*) INTO v_cnt_fuera_rango
  FROM bdm_tempo.stg_geo_clasif
  WHERE (cod_es_entero AND cod_en_rango = FALSE)
     OR (status_raw = 'M' AND lat_formato_ok AND lat_en_rango = FALSE)
     OR (status_raw = 'M' AND lon_formato_ok AND lon_en_rango = FALSE);

  IF v_cnt_status_inv > 0 THEN
    RAISE INFO 'sp_geo_cargar_georreferenciacion: Lote %: % fila(s) con Status != M/U rechazadas (Req 3.7).',
      in_lote, v_cnt_status_inv;
  END IF;
  IF v_cnt_no_conv > 0 THEN
    RAISE INFO 'sp_geo_cargar_georreferenciacion: Lote %: % fila(s) no convertibles (formato invalido / coma decimal) rechazadas (Req 5.4, 5.6).',
      in_lote, v_cnt_no_conv;
  END IF;
  IF v_cnt_fuera_rango > 0 THEN
    RAISE INFO 'sp_geo_cargar_georreferenciacion: Lote %: % fila(s) fuera de rango (Cod_DW_Ubic/lat/long) rechazadas (Req 5.7).',
      in_lote, v_cnt_fuera_rango;
  END IF;

  -- 7.5) Rechazo de clave (Cod_DW_Ubic, Lote) DUPLICADA (Req 3.4). El contrato
  --      es 1:1 por (Cod_DW_Ubic, Lote); si una clave aparece mas de una vez,
  --      todas sus ocurrencias se descartan (no se puede decidir cual aplicar)
  --      conservando las demas filas validas.
  DROP TABLE IF EXISTS bdm_tempo.stg_geo_aplicar;
  CREATE TABLE bdm_tempo.stg_geo_aplicar AS
  SELECT v.cod_dw_ubic, v.status_match, v.latitud, v.longitud
  FROM bdm_tempo.stg_geo_valida v
  WHERE v.cod_dw_ubic IN (
    SELECT cod_dw_ubic
    FROM bdm_tempo.stg_geo_valida
    GROUP BY cod_dw_ubic
    HAVING COUNT(*) = 1
  );

  SELECT COUNT(*) INTO v_cnt_dup
  FROM (
    SELECT cod_dw_ubic
    FROM bdm_tempo.stg_geo_valida
    GROUP BY cod_dw_ubic
    HAVING COUNT(*) > 1
  ) d;

  IF v_cnt_dup > 0 THEN
    RAISE INFO 'sp_geo_cargar_georreferenciacion: Lote %: % clave(s) (Cod_DW_Ubic, Lote) duplicada(s) rechazada(s) conservando las validas (Req 3.4).',
      in_lote, v_cnt_dup;
  END IF;

  -- 7.6) Rechazo de clave HUERFANA (Req 3.4): filas cuyo cod_dw_ubic NO es un
  --      candidato del Lote. Un candidato del Lote es una fila de
  --      geo_atributos con lote = in_lote. Se descartan las huerfanas
  --      conservando las que si pertenecen al Lote.
  SELECT COUNT(*) INTO v_cnt_huerfana
  FROM bdm_tempo.stg_geo_aplicar a
  WHERE NOT EXISTS (
    SELECT 1 FROM bdm_datos.geo_atributos g
    WHERE g.cod_dw_ubic = a.cod_dw_ubic
      AND g.lote = in_lote
  );

  IF v_cnt_huerfana > 0 THEN
    RAISE INFO 'sp_geo_cargar_georreferenciacion: Lote %: % fila(s) huerfana(s) (cod_dw_ubic no candidato del Lote) rechazada(s) (Req 3.4).',
      in_lote, v_cnt_huerfana;
  END IF;

  DELETE FROM bdm_tempo.stg_geo_aplicar
  WHERE NOT EXISTS (
    SELECT 1 FROM bdm_datos.geo_atributos g
    WHERE g.cod_dw_ubic = bdm_tempo.stg_geo_aplicar.cod_dw_ubic
      AND g.lote = in_lote
  );

  -- 7.7) Aplicacion Status = 'M' (Req 3.5, 11.2): persistir lat/long y
  --      atributos, marcar geocodificada. UPDATE idempotente por cod_dw_ubic
  --      restringido al Lote en proceso. Los atributos barrio/estrato del
  --      contrato de 32 columnas son extensibles; no hay columna de origen
  --      fija en el staging, por lo que se dejan sin sobrescribir (NULL segun
  --      DDL) hasta pinnar su posicion en el contrato.
  UPDATE bdm_datos.geo_atributos g
  SET latitud             = a.latitud,
      longitud            = a.longitud,
      status_match        = 'M',
      estado_geo          = 'geocodificada',
      fecha_actualizacion = v_hoy,
      usuario_bd          = v_usuario_bd
  FROM bdm_tempo.stg_geo_aplicar a
  WHERE g.cod_dw_ubic = a.cod_dw_ubic
    AND g.lote        = in_lote
    AND a.status_match = 'M';

  GET DIAGNOSTICS v_cnt_aplicadas_m = ROW_COUNT;

  -- 7.8) Aplicacion Status = 'U' (Req 3.6, 10.1): registrar 'no geocodificada'
  --      y CONSERVAR la lat/long previa (no se tocan las columnas de coordenadas).
  UPDATE bdm_datos.geo_atributos g
  SET status_match        = 'U',
      estado_geo          = 'no geocodificada',
      fecha_actualizacion = v_hoy,
      usuario_bd          = v_usuario_bd
  FROM bdm_tempo.stg_geo_aplicar a
  WHERE g.cod_dw_ubic = a.cod_dw_ubic
    AND g.lote        = in_lote
    AND a.status_match = 'U';

  GET DIAGNOSTICS v_cnt_aplicadas_u = ROW_COUNT;

  -- 7.9) Candidatos del Lote SIN salida aplicada (Req 10.3): toda ubicacion
  --      candidata del Lote (fila en geo_atributos con lote = in_lote) que no
  --      quedo en el conjunto aplicado queda 'pendiente de geocodificacion',
  --      conservando sus atributos de entrada (lat/long previa sin modificar).
  --      Es idempotente: reaplicar el mismo Lote produce el mismo estado.
  UPDATE bdm_datos.geo_atributos g
  SET estado_geo          = 'pendiente de geocodificacion',
      fecha_actualizacion = v_hoy,
      usuario_bd          = v_usuario_bd
  WHERE g.lote = in_lote
    AND NOT EXISTS (
      SELECT 1 FROM bdm_tempo.stg_geo_aplicar a
      WHERE a.cod_dw_ubic = g.cod_dw_ubic
    );

  GET DIAGNOSTICS v_cnt_pendientes = ROW_COUNT;

  RAISE INFO 'sp_geo_cargar_georreferenciacion: Lote % aplicado: % M (geocodificada), % U (no geocodificada), % pendiente de geocodificacion.',
    in_lote, v_cnt_aplicadas_m, v_cnt_aplicadas_u, v_cnt_pendientes;

  -- 7.10) Marcar el Lote 'cargado' (Req 3.9 / maquina de estados) y registrar
  --       trazabilidad. El estado 'cargado' habilita el reenganche de R3.
  UPDATE bdm_datos.geo_lote_control
  SET estado              = 'cargado',
      fase_fallo          = NULL,
      ultimo_error        = NULL,
      fecha_actualizacion = GETDATE()
  WHERE lote = in_lote;

  -- 7.11) Limpieza del staging temporal y efimero (Req 3.9): el contenido no
  --       persiste entre corridas.
  DROP TABLE IF EXISTS bdm_tempo.stg_geo_valida;
  DROP TABLE IF EXISTS bdm_tempo.stg_geo_clasif;
  DROP TABLE IF EXISTS bdm_tempo.stg_geo_norm;
  DROP TABLE IF EXISTS bdm_tempo.stg_geo_aplicar;
  DROP TABLE IF EXISTS bdm_tempo.stg_arcgis_georeferenciacion;

EXCEPTION WHEN OTHERS THEN
  RAISE EXCEPTION 'sp_geo_cargar_georreferenciacion failed: %', SQLERRM;
END;
$$;
-- SLCOPRBA-1355: re-DPLY DEV post DROP SCHEMA strct #256
