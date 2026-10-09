-- ============================================================
-- sp_geo_exportar_insumo_mock.sql
-- Exportador_GEO de la via MOCK: genera Ubicacion_Candidata desde el universo
-- mock, las etiqueta con un Lote y lanza el UNLOAD.
-- (repo pgm / db_rcncr_btch_rdshft_pgm)
-- Cluster consumidor: reconocerbatch / dba_rncr_batch
-- Objeto permanente en bdm_datos. Idempotente (CREATE OR REPLACE).
-- Codificacion: UTF-8 sin BOM. Nunca GRANT ... TO PUBLIC.
-- Spec: unificacion-full-delta -- certificacion con datos mock
-- ------------------------------------------------------------
-- SLCOPRBA-1355: espejo de sp_geo_exportar_insumo.sql. Misma logica, tablas
-- independientes:
--     geo_config         -> geo_config_mock
--     geo_atributos      -> geo_atributos_mock
--     geo_lote_control   -> geo_lote_control_mock
--     v_xpm_ubicacion_*  -> v_mock_ubicacion_estandarizada
--     stg_geo_*          -> stg_mock_geo_*
--     stg_unif_delta_ubic-> stg_mock_unif_delta_ubic
--
-- ALCANCE: SOLO generacion de candidatos. No hay carga de georreferenciacion ni
-- de distancias en la via mock, porque no hay enriquecimiento disponible; por
-- eso la Regla 3 queda fuera de la certificacion mock.
--
-- EL UNLOAD DEBE FALLAR Y ESO ES RESULTADO ESPERADO:
--   el rol IAM rcncr-batch-redshift-geo no esta asociado al cluster DEV. El
--   fallo de exportacion NO es bloqueante por diseno (Req 2.10, 2.11): se marca
--   el Lote 'fallido' en geo_lote_control_mock con RAISE INFO (no EXCEPTION) y
--   el flujo continua con R1+R2 hacia Ordenamiento. La certificacion verifica
--   justamente eso: que GEO falle sin tumbar la corrida.
--
-- CONSECUENCIA EN LA SEGUNDA CORRIDA (tambien esperada):
--   el predicado de candidatos excluye toda ubicacion ya etiquetada en un Lote
--   cuyo estado no sea 'cargado'. Tras el FULL, el Lote 1 mock queda 'fallido'
--   con todas las ubicaciones etiquetadas, de modo que el DELTA posterior
--   encuentra 0 candidatos. Eso certifica el Req 1.5 ("no re-exportar lo ya
--   enviado y aun sin cargar"), no es un defecto.
--
-- Firma: 6 params VARCHAR del Framework_Batch (leccion #11), igual que el real.
-- NONATOMIC en toda la cadena (leccion #13).
-- Rollback: DROP PROCEDURE nombre(<firma exacta>) SIN IF EXISTS (#12/#14).
-- ============================================================

CREATE SCHEMA IF NOT EXISTS bdm_datos;

CREATE OR REPLACE PROCEDURE bdm_datos.sp_geo_exportar_insumo_mock(
    in_solicitud       VARCHAR,   -- Framework_Batch (no usado)
    in_nit_suscriptor  VARCHAR,   -- Framework_Batch (no usado)
    in_path_archivo    VARCHAR,   -- Framework_Batch (no usado)
    in_nemotecnico     VARCHAR,   -- MODO (FULL | DELTA)
    in_id_facturacion  VARCHAR,   -- LOTE (no usado aqui: el Lote GEO es propio)
    in_fecha_ejecucion VARCHAR    -- Watermark (no usado aqui)
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
  v_maxfilesize_mb  VARCHAR(500);
  v_s3_prefix       VARCHAR(500);
  v_delimiter       VARCHAR(500);
  v_compression     VARCHAR(500);
  v_null_string     VARCHAR(500);
  v_bucket          VARCHAR(500);
  v_iam_role        VARCHAR(500);
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
  v_cuenta_actual := CURRENT_AWS_ACCOUNT;
  v_db_actual     := CURRENT_DATABASE();

  IF in_nemotecnico IS NULL OR BTRIM(in_nemotecnico) = '' THEN
    v_modo := 'FULL';
  ELSE
    v_modo := UPPER(BTRIM(in_nemotecnico));
  END IF;

  -- Resolucion del Ambiente por la cuenta AWS del cluster que ejecuta.
  SELECT ambiente INTO v_ambiente
  FROM bdm_datos.geo_config_mock
  WHERE parametro = 'arcgis_account_id'
    AND valor = v_cuenta_actual;

  IF v_ambiente IS NULL THEN
    RAISE EXCEPTION
      'sp_geo_exportar_insumo_mock: no se pudo resolver el Ambiente para la cuenta AWS % (base %). Verifique geo_config_mock.arcgis_account_id.',
      v_cuenta_actual, v_db_actual;
  END IF;

  SELECT valor INTO v_cuenta_ambiente
  FROM bdm_datos.geo_config_mock
  WHERE ambiente = v_ambiente AND parametro = 'arcgis_account_id';

  IF v_cuenta_ambiente <> v_cuenta_actual THEN
    RAISE EXCEPTION
      'sp_geo_exportar_insumo_mock: desajuste cuenta/Ambiente. Ambiente % espera cuenta %; cuenta de ejecucion %.',
      v_ambiente, v_cuenta_ambiente, v_cuenta_actual;
  END IF;

  SELECT valor INTO v_maxfilesize_mb
  FROM bdm_datos.geo_config_mock WHERE ambiente = v_ambiente AND parametro = 'maxfilesize_mb';
  IF v_maxfilesize_mb IS NULL THEN
    RAISE EXCEPTION 'sp_geo_exportar_insumo_mock: parametro ausente: maxfilesize_mb (ambiente %).', v_ambiente;
  END IF;

  SELECT valor INTO v_s3_prefix
  FROM bdm_datos.geo_config_mock WHERE ambiente = v_ambiente AND parametro = 's3_prefix';
  IF v_s3_prefix IS NULL THEN
    RAISE EXCEPTION 'sp_geo_exportar_insumo_mock: parametro ausente: s3_prefix (ambiente %).', v_ambiente;
  END IF;

  SELECT valor INTO v_delimiter
  FROM bdm_datos.geo_config_mock WHERE ambiente = v_ambiente AND parametro = 'delimiter';
  IF v_delimiter IS NULL THEN
    RAISE EXCEPTION 'sp_geo_exportar_insumo_mock: parametro ausente: delimiter (ambiente %).', v_ambiente;
  END IF;

  SELECT valor INTO v_compression
  FROM bdm_datos.geo_config_mock WHERE ambiente = v_ambiente AND parametro = 'compression';
  IF v_compression IS NULL THEN
    RAISE EXCEPTION 'sp_geo_exportar_insumo_mock: parametro ausente: compression (ambiente %).', v_ambiente;
  END IF;

  SELECT valor INTO v_null_string
  FROM bdm_datos.geo_config_mock WHERE ambiente = v_ambiente AND parametro = 'null_string';
  IF v_null_string IS NULL THEN
    RAISE EXCEPTION 'sp_geo_exportar_insumo_mock: parametro ausente: null_string (ambiente %).', v_ambiente;
  END IF;

  SELECT valor INTO v_bucket
  FROM bdm_datos.geo_config_mock WHERE ambiente = v_ambiente AND parametro = 'bucket';
  IF v_bucket IS NULL THEN
    RAISE EXCEPTION 'sp_geo_exportar_insumo_mock: parametro ausente: bucket (ambiente %).', v_ambiente;
  END IF;

  SELECT valor INTO v_iam_role
  FROM bdm_datos.geo_config_mock WHERE ambiente = v_ambiente AND parametro = 'iam_role';
  IF v_iam_role IS NULL THEN
    RAISE EXCEPTION 'sp_geo_exportar_insumo_mock: parametro ausente: iam_role (ambiente %).', v_ambiente;
  END IF;

  SELECT NULLIF(valor, '')::INTEGER INTO v_max_records
  FROM bdm_datos.geo_config_mock WHERE ambiente = v_ambiente AND parametro = 'max_records';
  IF v_max_records IS NULL THEN
    RAISE EXCEPTION 'sp_geo_exportar_insumo_mock: parametro ausente: max_records (ambiente %).', v_ambiente;
  END IF;

  -- ----------------------------------------------------------
  -- Ubicacion_Candidata = ubicacion mock sin coordenadas disponibles, excluidas
  -- las que ya estan en un Lote cuyo estado no es 'cargado' (Req 1.5).
  -- En DELTA se intersecta con el universo delta mock materializado por el
  -- orquestador tras R2 (Req 8.2); en FULL es barrido completo (Req 8.1).
  -- Orden estable por cod_dw_ubic para que el corte por max_records sea
  -- determinista (Req 1.3, 1.4).
  -- ----------------------------------------------------------
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_geo_candidatos;
  CREATE TABLE bdm_tempo.stg_mock_geo_candidatos
  DISTSTYLE KEY DISTKEY(cod_dw_ubic)
  AS
  SELECT cod_dw_ubic
  FROM (
    SELECT
      ubi.cod_dw_ubic,
      ROW_NUMBER() OVER (ORDER BY ubi.cod_dw_ubic) AS rn
    FROM bdm_tempo.v_mock_ubicacion_estandarizada ubi
    LEFT JOIN bdm_datos.geo_atributos_mock g
      ON ubi.cod_dw_ubic = g.cod_dw_ubic
    WHERE (g.cod_dw_ubic IS NULL
        OR g.latitud IS NULL
        OR g.longitud IS NULL)
      AND ( v_modo <> 'DELTA'
         OR EXISTS (
              SELECT 1
              FROM bdm_tempo.stg_mock_unif_delta_ubic d
              WHERE d.cod_dw_ubic = ubi.cod_dw_ubic
            ) )
      AND NOT EXISTS (
        SELECT 1
        FROM bdm_datos.geo_atributos_mock ga
        JOIN bdm_datos.geo_lote_control_mock lc
          ON ga.lote = lc.lote
        WHERE ga.cod_dw_ubic = ubi.cod_dw_ubic
          AND lc.estado <> 'cargado'
      )
  ) q
  WHERE q.rn <= v_max_records;

  SELECT COUNT(*) INTO v_conteo FROM bdm_tempo.stg_mock_geo_candidatos;

  -- Sin candidatos: no se asigna Lote ni se exporta (Req 1.6, 2.2).
  IF v_conteo = 0 THEN
    DROP TABLE IF EXISTS bdm_tempo.stg_mock_geo_candidatos;
    RAISE INFO 'sp_geo_exportar_insumo_mock: 0 Ubicacion_Candidata (ambiente %); no se asigna Lote ni se exporta.', v_ambiente;
    RETURN;
  END IF;

  -- Lote monotono creciente propio de la via mock.
  SELECT COALESCE(MAX(lote), 0) + 1 INTO v_lote
  FROM bdm_datos.geo_lote_control_mock;

  UPDATE bdm_datos.geo_atributos_mock
  SET lote                = v_lote,
      estado_geo          = 'pendiente de geocodificacion',
      fecha_actualizacion = CURRENT_DATE,
      usuario_bd          = v_usuario
  FROM bdm_tempo.stg_mock_geo_candidatos c
  WHERE bdm_datos.geo_atributos_mock.cod_dw_ubic = c.cod_dw_ubic;

  INSERT INTO bdm_datos.geo_atributos_mock (
    cod_dw_ubic, latitud, longitud, barrio, estrato, status_match,
    estado_geo, lote, fecha_actualizacion, usuario_bd
  )
  SELECT
    c.cod_dw_ubic, NULL, NULL, NULL, NULL, NULL,
    'pendiente de geocodificacion', v_lote, CURRENT_DATE, v_usuario
  FROM bdm_tempo.stg_mock_geo_candidatos c
  LEFT JOIN bdm_datos.geo_atributos_mock g
    ON c.cod_dw_ubic = g.cod_dw_ubic
  WHERE g.cod_dw_ubic IS NULL;

  INSERT INTO bdm_datos.geo_lote_control_mock (
    lote, estado, fase_fallo, conteo_esperado, conteo_cargado,
    intentos, max_reintentos, ambiente, ultimo_error,
    fecha_exportacion, fecha_carga, fecha_actualizacion
  )
  VALUES (
    v_lote, 'exportado', NULL, v_conteo, NULL, 0,
    (SELECT NULLIF(valor, '')::SMALLINT FROM bdm_datos.geo_config_mock WHERE ambiente = v_ambiente AND parametro = 'max_retries'),
    v_ambiente, NULL, GETDATE(), NULL, GETDATE()
  );

  -- MAXFILESIZE valido en Redshift: [1, 6144] MB (Req 2.5).
  v_maxfilesize_int := NULLIF(BTRIM(v_maxfilesize_mb), '')::INTEGER;
  IF v_maxfilesize_int IS NULL OR v_maxfilesize_int < 1 OR v_maxfilesize_int > 6144 THEN
    -- RAISE INFO en Redshift solo admite variables, no expresiones COALESCE.
    v_dbg := COALESCE(v_maxfilesize_mb, '<null>');
    UPDATE bdm_datos.geo_lote_control_mock
    SET estado              = 'fallido',
        fase_fallo          = 'exportacion',
        ultimo_error        = LEFT('maxfilesize_mb invalido (' || v_dbg
                                   || '); debe estar en [1, 6144] MB.', 4000),
        fecha_actualizacion = GETDATE()
    WHERE lote = v_lote;

    RAISE INFO 'sp_geo_exportar_insumo_mock: Lote % marcado fallido (fase exportacion): maxfilesize_mb invalido (%). Pipeline NO bloqueado.',
      v_lote, v_dbg;

    DROP TABLE IF EXISTS bdm_tempo.stg_mock_geo_candidatos;
    DROP TABLE IF EXISTS bdm_tempo.stg_mock_geo_insumo;
    RETURN;
  END IF;

  -- Insumo_GEO con EXACTAMENTE 5 columnas (Req 2.3) y el estandar de nulos
  -- aplicado de forma identica a todas (Req 2.7).
  -- NOTA: en la via mock municipio y departamento son constantes NULL en
  -- v_mock_ubicacion_estandarizada (bdm_stage.ubicacion_estandarizada no los
  -- almacena), por lo que saldran con el marcador de nulo. No afecta la
  -- certificacion, cuyo objeto es la GENERACION de candidatos.
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_geo_insumo;
  CREATE TABLE bdm_tempo.stg_mock_geo_insumo
  DISTSTYLE KEY DISTKEY(cod_dw_ubic)
  AS
  SELECT
    COALESCE(CAST(ubi.cod_dw_ubic AS VARCHAR(50)), v_null_string) AS cod_dw_ubic,
    COALESCE(CAST(v_lote AS VARCHAR(50)), v_null_string)          AS lote,
    COALESCE(LEFT(ubi.texto_ubicacion, 250), v_null_string)       AS "DIRECCION",
    COALESCE(LEFT(ubi.municipio, 50), v_null_string)              AS "MUNICIPIO",
    COALESCE(LEFT(ubi.departamento, 40), v_null_string)           AS "DEPARTAMENTO"
  FROM bdm_tempo.stg_mock_geo_candidatos c
  JOIN bdm_tempo.v_mock_ubicacion_estandarizada ubi
    ON ubi.cod_dw_ubic = c.cod_dw_ubic;

  v_fecha := TO_CHAR(CURRENT_DATE, 'YYYYMMDD');
  v_s3_target := 's3://' || v_bucket || '/' || v_s3_prefix
              || 'delta_geo_mock_' || LOWER(v_ambiente) || '_' || v_lote::VARCHAR
              || '_' || v_fecha || '.csv.gz';

  v_delim_lit := REPLACE(v_delimiter, '''', '''''');
  v_null_lit  := REPLACE(v_null_string, '''', '''''');

  v_unload_select :=
    'SELECT cod_dw_ubic, lote, "DIRECCION", "MUNICIPIO", "DEPARTAMENTO" '
    || 'FROM bdm_tempo.stg_mock_geo_insumo';

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

  -- Fallo de exportacion NO bloqueante (Req 2.10, 2.11): RAISE INFO, no
  -- EXCEPTION, para que la corrida continue con R1+R2 hacia Ordenamiento.
  -- En DEV se espera que caiga aqui por el rol IAM no asociado al cluster.
  BEGIN
    EXECUTE v_unload_sql;

    RAISE INFO 'sp_geo_exportar_insumo_mock: Lote % exportado (% candidatos, ambiente %) a %.',
      v_lote, v_conteo, v_ambiente, v_s3_target;

  EXCEPTION WHEN OTHERS THEN
    UPDATE bdm_datos.geo_lote_control_mock
    SET estado              = 'fallido',
        fase_fallo          = 'exportacion',
        ultimo_error        = LEFT('UNLOAD fallido: ' || SQLERRM, 4000),
        fecha_actualizacion = GETDATE()
    WHERE lote = v_lote;

    RAISE INFO 'sp_geo_exportar_insumo_mock: Lote % marcado fallido (fase exportacion): %. Pipeline NO bloqueado; continua a Ordenamiento con R1+R2.',
      v_lote, SQLERRM;
  END;

  DROP TABLE IF EXISTS bdm_tempo.stg_mock_geo_insumo;
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_geo_candidatos;

EXCEPTION WHEN OTHERS THEN
  RAISE EXCEPTION 'sp_geo_exportar_insumo_mock failed: %', SQLERRM;
END;
$$;
