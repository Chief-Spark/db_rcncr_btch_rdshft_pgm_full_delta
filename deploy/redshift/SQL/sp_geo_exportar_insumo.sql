-- ============================================================
-- sp_geo_exportar_insumo  (Reconocer / Enriquecimiento GEO - Regla 3)
-- Exportador_GEO: seleccion de Ubicacion_Candidata post-Regla 2,
-- asignacion de Lote unico, registro de estado 'exportado' y (task 3.5)
-- UNLOAD del Insumo_GEO a reconocer_input/.
--
-- Objeto en bdm_datos; idempotente (CREATE OR REPLACE PROCEDURE).
-- NONATOMIC (el UNLOAD de la task 3.5 no admite transaccion implicita).
-- UTF-8 sin BOM. Nunca GRANT ... TO PUBLIC.
-- Prerrequisitos: _strct desplegado (geo_atributos, geo_lote_control,
--   geo_config, funcion geo_get_config).
-- Ref: .kiro/specs/geo-enriquecimiento-regla3/design.md
--      (Exportador_GEO - sp_geo_exportar_insumo)
--      Requisitos: 1.1, 1.2, 1.3, 1.4, 1.5, 1.6 (seleccion/Lote),
--                  2.1, 2.2, 2.3, 2.4, 2.5, 2.6, 2.7, 2.8, 2.9, 2.10, 2.11 (UNLOAD),
--                  8.1, 8.2, 8.5, 8.6 (configuracion/ambiente)
--
-- Alineacion FULL/DELTA (spec unificacion-full-delta, Task 8.1):
--   El Exportador_GEO conserva la firma estandar de 6 parametros VARCHAR del
--   Framework_Batch. El orquestador (sp_unificacion_ciclo) lo invoca re-emitiendo
--   el modo/lote/watermark en los slots 4/5/6:
--     in_solicitud       -> no usado (contexto Framework_Batch)
--     in_nit_suscriptor  -> no usado
--     in_path_archivo    -> no usado (la ruta S3 se resuelve de geo_config)
--     in_nemotecnico     = Modo_Corrida efectivo (FULL | DELTA | '')
--     in_id_facturacion  = Lote_Corrida de la Unificacion (NO usado por el GEO:
--                          el Ciclo_GEO mantiene su propio 'lote' en
--                          geo_lote_control, independiente del Lote_Corrida;
--                          Req 8.4, 8.5)
--     in_fecha_ejecucion = Watermark (frontera inferior inclusiva; solo informa,
--                          el universo delta ya viene materializado en
--                          bdm_tempo.stg_unif_delta_ubic)
--   En Modo_Full hace el barrido completo (comportamiento actual, Req 8.1). En
--   Modo_Delta intersecta los candidatos "sin coordenadas" con las cod_dw_ubic
--   del universo del delta de la corrida (bdm_tempo.stg_unif_delta_ubic,
--   materializada por el orquestador tras R2), de modo que solo se exporten las
--   ubicaciones del delta; las restantes se conservan pendientes para una corrida
--   DELTA posterior o para un FULL de reconciliacion (Req 8.2, 8.3).
--
-- Estructura:
--   Pasos 1-7 : seleccion de candidatos, asignacion de Lote unico y registro
--               'exportado' (task 3.1).
--   SECCION UNLOAD (task 3.5): construccion del Insumo_GEO de 5 columnas y
--               UNLOAD dinamico a reconocer_input/, con manejo de fallo NO
--               bloqueante (marca Lote 'fallido' sin abortar la cascada).
-- ============================================================

-- Nota: no hacer DROP de la firma historica (VARCHAR) aqui. En DEV limpio no
-- existe y Jenkins trata el error 42883 como fallo de DPLY (REDSHIFT:112).
-- CREATE OR REPLACE de la firma 6 VARCHAR es suficiente cuando no hay overload.

CREATE OR REPLACE PROCEDURE bdm_datos.sp_geo_exportar_insumo(
    in_solicitud       VARCHAR,
    in_nit_suscriptor  VARCHAR,
    in_path_archivo    VARCHAR,
    in_nemotecnico     VARCHAR,
    in_id_facturacion  VARCHAR,
    in_fecha_ejecucion VARCHAR
)
NONATOMIC
LANGUAGE plpgsql
AS $$
DECLARE
  v_modo            VARCHAR(10);
  v_ambiente        VARCHAR(10);
  v_cuenta_actual   VARCHAR(20);
  v_cuenta_ambiente VARCHAR(20);
  v_db_actual       VARCHAR(128);
  v_max_records     INTEGER;
  v_lote            INTEGER;
  v_conteo          INTEGER;
  v_usuario         VARCHAR(100);
  -- Parametros de configuracion (Req 8.1, 8.2, 8.5). Se validan al leerlos y
  -- se consumen en la SECCION UNLOAD (task 3.5).
  v_maxfilesize_mb  VARCHAR(500);
  v_s3_prefix       VARCHAR(500);
  v_delimiter       VARCHAR(500);
  v_compression     VARCHAR(500);
  v_null_string     VARCHAR(500);
  v_bucket          VARCHAR(500);
  v_iam_role        VARCHAR(500);
  -- Variables de la SECCION UNLOAD (task 3.5).
  v_maxfilesize_int INTEGER;
  v_fecha           VARCHAR(8);
  v_s3_target       VARCHAR(1000);
  v_null_lit        VARCHAR(1000);
  v_delim_lit       VARCHAR(50);
  v_unload_select   VARCHAR(2000);
  v_unload_sql      VARCHAR(8000);
  v_dbg             VARCHAR(500);
BEGIN

  v_usuario       := LEFT(CURRENT_USER, 100);
  v_cuenta_actual := CURRENT_AWS_ACCOUNT;   -- cuenta AWS del cluster que ejecuta (Req 8.6)
  v_db_actual     := CURRENT_DATABASE();

  -- ----------------------------------------------------------
  -- 0) Resolver el Modo_Corrida (Req 8.1, 8.2). Llega en el slot 4 del
  --    Framework_Batch (in_nemotecnico). Vacio/NULL -> FULL (default que
  --    preserva el comportamiento actual y el uso del wrapper de autodeteccion);
  --    si no, se normaliza a mayusculas. El orquestador ya valido el modo antes
  --    de encadenar; aqui solo se distingue DELTA de todo lo demas (barrido
  --    completo por defecto), de modo que ningun valor inesperado acote el
  --    universo sin querer.
  -- ----------------------------------------------------------
  IF in_nemotecnico IS NULL OR BTRIM(in_nemotecnico) = '' THEN
    v_modo := 'FULL';
  ELSE
    v_modo := UPPER(BTRIM(in_nemotecnico));
  END IF;

  -- ----------------------------------------------------------
  -- 1) Resolver el Ambiente.
  --    Se autodetecta por la cuenta AWS actual (arcgis_account_id de geo_config
  --    coincide con la cuenta consumidora por ambiente). El Exportador_GEO no
  --    recibe ambiente por parametro: los slots 1-3 del Framework_Batch no se
  --    usan y la ruta de salida se resuelve de geo_config. (Req 8.4, 8.6)
  -- ----------------------------------------------------------
  SELECT ambiente INTO v_ambiente
  FROM bdm_datos.geo_config
  WHERE parametro = 'arcgis_account_id'
    AND valor = v_cuenta_actual;

  IF v_ambiente IS NULL THEN
    RAISE EXCEPTION
      'sp_geo_exportar_insumo: no se pudo resolver el Ambiente para la cuenta AWS % (base %). Verifique geo_config.arcgis_account_id.',
      v_cuenta_actual, v_db_actual;
  END IF;

  -- ----------------------------------------------------------
  -- 2) Validar cuenta AWS vs Ambiente resuelto (Req 8.6).
  --    La cuenta esperada del Ambiente esta en geo_config (arcgis_account_id
  --    identifica la cuenta consumidora por ambiente). Aborta si desajuste.
  -- ----------------------------------------------------------
  SELECT valor INTO v_cuenta_ambiente
  FROM bdm_datos.geo_config
  WHERE ambiente = v_ambiente AND parametro = 'arcgis_account_id';
  IF v_cuenta_ambiente IS NULL THEN
    RAISE EXCEPTION
      'sp_geo_exportar_insumo: parametro de configuracion ausente: arcgis_account_id (ambiente %).',
      v_ambiente;
  END IF;
  IF v_cuenta_ambiente <> v_cuenta_actual THEN
    RAISE EXCEPTION
      'sp_geo_exportar_insumo: desajuste cuenta/Ambiente. Ambiente % espera cuenta %; cuenta de ejecucion %.',
      v_ambiente, v_cuenta_ambiente, v_cuenta_actual;
  END IF;

  -- ----------------------------------------------------------
  -- 3) Leer parametros de geo_config (Req 8.1, 8.2). Cada parametro
  --    requerido debe existir; si falta, abortar identificandolo (Req 8.5).
  --    max_records se usa en la seleccion (paso 4); el resto se validan aqui
  --    y se consumen en la SECCION UNLOAD (task 3.5).
  -- ----------------------------------------------------------
  SELECT valor INTO v_maxfilesize_mb
  FROM bdm_datos.geo_config
  WHERE ambiente = v_ambiente AND parametro = 'maxfilesize_mb';
  IF v_maxfilesize_mb IS NULL THEN
    RAISE EXCEPTION 'sp_geo_exportar_insumo: parametro de configuracion ausente: maxfilesize_mb (ambiente %).', v_ambiente;
  END IF;

  SELECT valor INTO v_s3_prefix
  FROM bdm_datos.geo_config
  WHERE ambiente = v_ambiente AND parametro = 's3_prefix';
  IF v_s3_prefix IS NULL THEN
    RAISE EXCEPTION 'sp_geo_exportar_insumo: parametro de configuracion ausente: s3_prefix (ambiente %).', v_ambiente;
  END IF;

  SELECT valor INTO v_delimiter
  FROM bdm_datos.geo_config
  WHERE ambiente = v_ambiente AND parametro = 'delimiter';
  IF v_delimiter IS NULL THEN
    RAISE EXCEPTION 'sp_geo_exportar_insumo: parametro de configuracion ausente: delimiter (ambiente %).', v_ambiente;
  END IF;

  SELECT valor INTO v_compression
  FROM bdm_datos.geo_config
  WHERE ambiente = v_ambiente AND parametro = 'compression';
  IF v_compression IS NULL THEN
    RAISE EXCEPTION 'sp_geo_exportar_insumo: parametro de configuracion ausente: compression (ambiente %).', v_ambiente;
  END IF;

  SELECT valor INTO v_null_string
  FROM bdm_datos.geo_config
  WHERE ambiente = v_ambiente AND parametro = 'null_string';
  IF v_null_string IS NULL THEN
    RAISE EXCEPTION 'sp_geo_exportar_insumo: parametro de configuracion ausente: null_string (ambiente %).', v_ambiente;
  END IF;

  SELECT valor INTO v_bucket
  FROM bdm_datos.geo_config
  WHERE ambiente = v_ambiente AND parametro = 'bucket';
  IF v_bucket IS NULL THEN
    RAISE EXCEPTION 'sp_geo_exportar_insumo: parametro de configuracion ausente: bucket (ambiente %).', v_ambiente;
  END IF;

  SELECT valor INTO v_iam_role
  FROM bdm_datos.geo_config
  WHERE ambiente = v_ambiente AND parametro = 'iam_role';
  IF v_iam_role IS NULL THEN
    RAISE EXCEPTION 'sp_geo_exportar_insumo: parametro de configuracion ausente: iam_role (ambiente %).', v_ambiente;
  END IF;

  -- max_records: requerido; parsear a INTEGER (Req 1.3, 8.5).
  SELECT NULLIF(valor, '')::INTEGER INTO v_max_records
  FROM bdm_datos.geo_config
  WHERE ambiente = v_ambiente AND parametro = 'max_records';
  IF v_max_records IS NULL THEN
    RAISE EXCEPTION 'sp_geo_exportar_insumo: parametro de configuracion ausente: max_records (ambiente %).', v_ambiente;
  END IF;

  -- ----------------------------------------------------------
  -- 4) Seleccionar Ubicacion_Candidata y particionar por max_records.
  --    Candidata = ubicacion sin coordenadas disponibles: no existe fila en
  --    geo_atributos, o existe con latitud/longitud NULL (Req 1.1).
  --    Se EXCLUYEN las ubicaciones que ya estan en un Lote cuyo estado
  --    registrado no es 'cargado' (ya enviadas y aun sin cargar) (Req 1.5).
  --
  --    La fuente de ubicaciones post-R2 es la vista del datashare
  --    v_xpm_ubicacion_estandarizada (universo de cod_dw_ubic vigentes).
  --    Orden estable por cod_dw_ubic para que el corte por max_records sea
  --    determinista y no pierda registros entre ejecuciones (Req 1.3, 1.4).
  --
  --    Alineacion FULL/DELTA (Task 8.1, Req 8.1/8.2/8.3):
  --      * FULL: barrido completo -> se seleccionan TODAS las ubicaciones sin
  --        coordenadas disponibles (comportamiento actual).
  --      * DELTA: se INTERSECTA el criterio "sin coordenadas" con las cod_dw_ubic
  --        del universo del delta de la corrida, materializadas por el
  --        orquestador (sp_unificacion_ciclo) tras R2 en
  --        bdm_tempo.stg_unif_delta_ubic. La interseccion se aplica con un
  --        predicado EXISTS gobernado por el modo (ver WHERE) para acotar los
  --        candidatos al delta sin alterar la cardinalidad; toda ubicacion sin
  --        coordenadas que NO este en el delta queda fuera del Lote de esta
  --        corrida y se conserva pendiente para una corrida DELTA posterior que
  --        la incluya o para un FULL de reconciliacion (Req 8.3). El predicado
  --        se activa solo en DELTA; en FULL es TRUE y se conserva el barrido total.
  --      Nota: el universo delta ya viene acotado por el Watermark (frontera
  --      inferior inclusiva) + nulos en la materializacion del orquestador; aqui
  --      solo se intersecta por cod_dw_ubic.
  -- ----------------------------------------------------------
  DROP TABLE IF EXISTS bdm_tempo.stg_geo_candidatos;
  CREATE TABLE bdm_tempo.stg_geo_candidatos
  DISTSTYLE KEY DISTKEY(cod_dw_ubic)
  AS
  SELECT cod_dw_ubic
  FROM (
    SELECT
      ubi.cod_dw_ubic,
      ROW_NUMBER() OVER (ORDER BY ubi.cod_dw_ubic) AS rn
    FROM bdm_tempo.v_xpm_ubicacion_estandarizada ubi
    LEFT JOIN bdm_datos.geo_atributos g
      ON ubi.cod_dw_ubic = g.cod_dw_ubic
    WHERE (g.cod_dw_ubic IS NULL          -- sin fila en geo_atributos
        OR g.latitud IS NULL
        OR g.longitud IS NULL)            -- coordenadas no disponibles (Req 1.1)
      -- Interseccion con el universo delta SOLO en Modo_Delta (Req 8.2). Se usa
      -- un predicado EXISTS gobernado por el modo (no un JOIN) para NO multiplicar
      -- filas ni alterar la cardinalidad del barrido: en FULL el predicado
      -- completo es TRUE y se conserva el barrido total (Req 8.1); en DELTA solo
      -- pasan las cod_dw_ubic presentes en el universo del delta materializado por
      -- el orquestador tras R2 (Req 8.2). Las ubicaciones sin coordenadas fuera
      -- del delta quedan pendientes para una corrida posterior (Req 8.3).
      AND ( v_modo <> 'DELTA'
         OR EXISTS (
              SELECT 1
              FROM bdm_tempo.stg_unif_delta_ubic d
              WHERE d.cod_dw_ubic = ubi.cod_dw_ubic
            ) )
      -- Excluir ubicaciones cuyo Lote registrado no esta 'cargado' (Req 1.5)
      AND NOT EXISTS (
        SELECT 1
        FROM bdm_datos.geo_atributos ga
        JOIN bdm_datos.geo_lote_control lc
          ON ga.lote = lc.lote
        WHERE ga.cod_dw_ubic = ubi.cod_dw_ubic
          AND lc.estado <> 'cargado'
      )
  ) q
  WHERE q.rn <= v_max_records;   -- limitar a max_records (Req 1.3, 1.4)

  SELECT COUNT(*) INTO v_conteo FROM bdm_tempo.stg_geo_candidatos;

  -- ----------------------------------------------------------
  -- 5) Si no hay candidatos: registrar cero y NO asignar Lote ni ejecutar
  --    UNLOAD (Req 1.6, 2.2). Se limpia el staging y se termina.
  -- ----------------------------------------------------------
  IF v_conteo = 0 THEN
    DROP TABLE IF EXISTS bdm_tempo.stg_geo_candidatos;
    RAISE INFO 'sp_geo_exportar_insumo: 0 Ubicacion_Candidata (ambiente %); no se asigna Lote ni se exporta.', v_ambiente;
    RETURN;
  END IF;

  -- ----------------------------------------------------------
  -- 6) Asignar un identificador de Lote unico (Req 1.2). Se toma el maximo
  --    lote existente en geo_lote_control + 1 (monotono creciente).
  -- ----------------------------------------------------------
  SELECT COALESCE(MAX(lote), 0) + 1 INTO v_lote
  FROM bdm_datos.geo_lote_control;

  -- Etiquetar los candidatos seleccionados con el Lote asignado en
  -- geo_atributos (upsert por cod_dw_ubic): las ubicaciones existentes se
  -- re-etiquetan al nuevo Lote y las que no tienen fila se insertan con
  -- lat/long NULL (Req 11.6). Esto deja trazabilidad del Lote por ubicacion.
  UPDATE bdm_datos.geo_atributos g
  SET lote                = v_lote,
      estado_geo          = 'pendiente de geocodificacion',
      fecha_actualizacion = CURRENT_DATE,
      usuario_bd          = v_usuario
  FROM bdm_tempo.stg_geo_candidatos c
  WHERE g.cod_dw_ubic = c.cod_dw_ubic;

  INSERT INTO bdm_datos.geo_atributos (
    cod_dw_ubic, latitud, longitud, barrio, estrato, status_match,
    estado_geo, lote, fecha_actualizacion, usuario_bd
  )
  SELECT
    c.cod_dw_ubic, NULL, NULL, NULL, NULL, NULL,
    'pendiente de geocodificacion', v_lote, CURRENT_DATE, v_usuario
  FROM bdm_tempo.stg_geo_candidatos c
  LEFT JOIN bdm_datos.geo_atributos g
    ON c.cod_dw_ubic = g.cod_dw_ubic
  WHERE g.cod_dw_ubic IS NULL;

  -- ----------------------------------------------------------
  -- 7) Registrar el Lote en geo_lote_control con estado 'exportado'
  --    (Req 7.4). max_reintentos = snapshot de max_retries; conteo_esperado
  --    = numero de candidatos del Lote.
  -- ----------------------------------------------------------
  INSERT INTO bdm_datos.geo_lote_control (
    lote, estado, fase_fallo, conteo_esperado, conteo_cargado,
    intentos, max_reintentos, ambiente, ultimo_error,
    fecha_exportacion, fecha_carga, fecha_actualizacion
  )
  VALUES (
    v_lote,
    'exportado',
    NULL,
    v_conteo,
    NULL,
    0,
    (SELECT NULLIF(valor, '')::SMALLINT FROM bdm_datos.geo_config WHERE ambiente = v_ambiente AND parametro = 'max_retries'),
    v_ambiente,
    NULL,
    GETDATE(),
    NULL,
    GETDATE()
  );

  -- ==========================================================
  -- SECCION UNLOAD (task 3.5)
  -- ----------------------------------------------------------
  -- Construye el Insumo_GEO (5 columnas) y hace UNLOAD a reconocer_input/.
  -- Requisitos: 2.1, 2.3, 2.4, 2.5, 2.6, 2.7, 2.8, 2.9, 2.10, 2.11.
  -- Solo se ejecuta cuando hay candidatos (v_conteo > 0); el caso de cero
  -- candidatos retorna antes (paso 5), cumpliendo la omision del UNLOAD
  -- (Req 2.2).
  -- ==========================================================

  -- 8a) Validar MAXFILESIZE en el rango soportado por Redshift [1, 6144] MB
  --     (Req 2.5). Un valor invalido no debe generar un UNLOAD malformado:
  --     se trata como fallo de exportacion (no bloqueante) mas abajo, por lo
  --     que aqui solo lo parseamos y validamos, marcando el Lote 'fallido'
  --     si esta fuera de rango.
  v_maxfilesize_int := NULLIF(BTRIM(v_maxfilesize_mb), '')::INTEGER;
  IF v_maxfilesize_int IS NULL OR v_maxfilesize_int < 1 OR v_maxfilesize_int > 6144 THEN
    -- RAISE INFO en Redshift solo admite variables (no expresiones COALESCE).
    v_dbg := COALESCE(v_maxfilesize_mb, '<null>');
    UPDATE bdm_datos.geo_lote_control
    SET estado              = 'fallido',
        fase_fallo          = 'exportacion',
        ultimo_error        = LEFT('maxfilesize_mb invalido (' || v_dbg
                                   || '); debe estar en [1, 6144] MB.', 4000),
        fecha_actualizacion = GETDATE()
    WHERE lote = v_lote;

    RAISE INFO 'sp_geo_exportar_insumo: Lote % marcado fallido (fase exportacion): maxfilesize_mb invalido (%). Pipeline NO bloqueado.',
      v_lote, v_dbg;

    DROP TABLE IF EXISTS bdm_tempo.stg_geo_candidatos;
    DROP TABLE IF EXISTS bdm_tempo.stg_geo_insumo;
    RETURN;
  END IF;

  -- 8b) Construir el Insumo_GEO con EXACTAMENTE 5 columnas en el orden
  --     cod_dw_ubic, lote, DIRECCION, MUNICIPIO, DEPARTAMENTO (Req 2.3).
  --     Origen: vista del datashare v_xpm_ubicacion_estandarizada
  --       DIRECCION    <- texto_ubicacion  (truncar a 250)  (Req 2.8, 2.9)
  --       MUNICIPIO    <- municipio        (truncar a 50)   (Req 2.8, 2.9)
  --       DEPARTAMENTO <- departamento     (truncar a 40)   (Req 2.8, 2.9)
  --     Estandar de nulos (Req 2.7): v_null_string es un unico valor
  --     (cadena vacia o '\N') aplicado de forma identica a las 5 columnas.
  --     Se materializa cada columna como texto ya con el estandar aplicado
  --     (COALESCE), de modo que el archivo contenga el mismo marcador de nulo
  --     en todas las columnas. cod_dw_ubic y lote nunca son nulos, pero se
  --     aplica COALESCE por uniformidad del estandar.
  DROP TABLE IF EXISTS bdm_tempo.stg_geo_insumo;
  CREATE TABLE bdm_tempo.stg_geo_insumo
  DISTSTYLE KEY DISTKEY(cod_dw_ubic)
  AS
  SELECT
    COALESCE(CAST(ubi.cod_dw_ubic AS VARCHAR(50)), v_null_string) AS cod_dw_ubic,
    COALESCE(CAST(v_lote AS VARCHAR(50)), v_null_string)          AS lote,
    COALESCE(LEFT(ubi.texto_ubicacion, 250), v_null_string)       AS "DIRECCION",
    COALESCE(LEFT(ubi.municipio, 50), v_null_string)              AS "MUNICIPIO",
    COALESCE(LEFT(ubi.departamento, 40), v_null_string)           AS "DEPARTAMENTO"
  FROM bdm_tempo.stg_geo_candidatos c
  JOIN bdm_tempo.v_xpm_ubicacion_estandarizada ubi
    ON ubi.cod_dw_ubic = c.cod_dw_ubic;

  -- 8c) Componer el UNLOAD dinamico (EXECUTE). El nombre de archivo lleva
  --     lote/fecha, por lo que la ruta S3 se construye en tiempo de ejecucion
  --     (Req 2.6). Con PARALLEL OFF Redshift produce un unico objeto bajo el
  --     prefijo dado. La consulta interna se pasa entre comillas simples
  --     escapadas ('') como exige UNLOAD.
  v_fecha := TO_CHAR(CURRENT_DATE, 'YYYYMMDD');

  -- s3://<bucket>/<s3_prefix>delta_geo_<ambiente>_<lote>_<AAAAMMDD>.csv.gz
  v_s3_target := 's3://' || v_bucket || '/' || v_s3_prefix
              || 'delta_geo_' || LOWER(v_ambiente) || '_' || v_lote::VARCHAR
              || '_' || v_fecha || '.csv.gz';

  -- Literales para DELIMITER y NULL AS. Se escapan las comillas simples
  -- internas duplicandolas para embeberlos en el string del UNLOAD.
  v_delim_lit := REPLACE(v_delimiter, '''', '''''');
  v_null_lit  := REPLACE(v_null_string, '''', '''''');

  -- SELECT interno del UNLOAD: filas del insumo. Las comillas simples del
  -- string SQL embebido se escriben duplicadas ('').
  v_unload_select :=
    'SELECT cod_dw_ubic, lote, "DIRECCION", "MUNICIPIO", "DEPARTAMENTO" '
    || 'FROM bdm_tempo.stg_geo_insumo';

  v_unload_sql :=
       'UNLOAD (''' || REPLACE(v_unload_select, '''', '''''') || ''')'
    || ' TO ''' || v_s3_target || ''''
    || ' IAM_ROLE ''' || v_iam_role || ''''
    || ' DELIMITER AS ''' || v_delim_lit || ''''
    || ' NULL AS ''' || v_null_lit || ''''
    || ' ADDQUOTES'
    || ' HEADER'
    || ' PARALLEL OFF'
    || ' ALLOWOVERWRITE'
    || ' GZIP'
    || ' MAXFILESIZE ' || v_maxfilesize_int::VARCHAR || ' MB';

  -- 8d) Ejecutar el UNLOAD dentro de manejo de excepciones. Si falla por
  --     cualquier causa (incluye Access Denied / falta de s3:PutObject),
  --     marcar el Lote 'fallido' con la causa y NO bloquear la cascada de
  --     Unificacion ni Ordenamiento: se usa RAISE INFO (no EXCEPTION) para
  --     que el pipeline continue con R1+R2 y el Lote quede disponible para un
  --     ciclo GEO posterior (Req 2.10, 2.11).
  BEGIN
    EXECUTE v_unload_sql;

    RAISE INFO 'sp_geo_exportar_insumo: Lote % exportado (% candidatos, ambiente %) a %.',
      v_lote, v_conteo, v_ambiente, v_s3_target;

  EXCEPTION WHEN OTHERS THEN
    UPDATE bdm_datos.geo_lote_control
    SET estado              = 'fallido',
        fase_fallo          = 'exportacion',
        ultimo_error        = LEFT('UNLOAD fallido: ' || SQLERRM, 4000),
        fecha_actualizacion = GETDATE()
    WHERE lote = v_lote;

    -- No relanzar: el fallo de exportacion no es bloqueante (Req 2.10, 2.11).
    RAISE INFO 'sp_geo_exportar_insumo: Lote % marcado fallido (fase exportacion): %. Pipeline NO bloqueado; continua a Ordenamiento con R1+R2.',
      v_lote, SQLERRM;
  END;

  DROP TABLE IF EXISTS bdm_tempo.stg_geo_insumo;
  DROP TABLE IF EXISTS bdm_tempo.stg_geo_candidatos;

EXCEPTION WHEN OTHERS THEN
  RAISE EXCEPTION 'sp_geo_exportar_insumo failed: %', SQLERRM;
END;
$$;
-- SLCOPRBA-1355: re-DPLY DEV post DROP SCHEMA strct #256
