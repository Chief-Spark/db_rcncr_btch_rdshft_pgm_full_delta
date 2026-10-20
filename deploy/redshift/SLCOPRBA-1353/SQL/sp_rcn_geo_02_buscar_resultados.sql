-- ============================================================
-- sp_rcn_geo_02_buscar_resultados  (Reconocer / GEO no bloqueante)
-- 2026-10-20. UTF-8 sin BOM. Nunca GRANT ... TO PUBLIC.
--
-- QUE HACE: revisa si ArcGIS ya dejo resultados para los Lotes que esperan
-- respuesta ('exportado') y, si los hay, los carga. Lo llama el ciclo de
-- Unificacion despues de exportar y ANTES de la Regla 3, de modo que lo que
-- se cargue entra en la R3 de la misma corrida por el COALESCE con
-- geo_atributos de v_xpm_ubicacion_estandarizada (02_vistas_insumo_edf_views).
--
-- POR QUE EXISTE: los cargadores esperan que un orquestador externo (SQS +
-- Lambda ResultTransfer) les pase la ruta y deje el Lote en 'procesado por
-- ArcGIS_Externo'. Ese orquestador no existe todavia, ArcGIS no procesa, y
-- ningun SP real escribia ese estado. Regla del negocio (2026-10-20): GEO no
-- es restrictivo; se exporta, se revisa si hay datos enriquecidos y, si algo
-- falla, el proceso sigue.
--
-- NUNCA FALLA HACIA AFUERA. Cada paso que toca S3 o carga va en su propio
-- bloque de excepcion; un error deja un RAISE INFO y el procedimiento sigue
-- o termina normalmente. Un Lote sin resultados se queda en 'exportado', no
-- en 'fallido': que ArcGIS no haya respondido todavia no es un fallo.
--
-- COMO:
--   1. Lotes en espera: estado 'exportado'. Si no hay, termina.
--   2. Configuracion del ambiente del Lote mas reciente: bucket, iam_role,
--      delimiter, null_string y s3_output_prefix ('reconocer_output/' por
--      defecto). Si falta algo, termina.
--   3. Un COPY del prefijo geo_result_ (Salida_Geo.pdf) a
--      bdm_tempo.stg_geo_resultado_crudo, de 33 columnas: el PDF declara 32
--      y su registro de ejemplo trae 33; con FILLRECORD caben las dos. Si no
--      hay archivo o no hay permiso, termina y los Lotes siguen esperando.
--   4. Un COPY del prefijo distancias_result_ a
--      bdm_tempo.stg_geo_distancias_crudo. Si falla, la tabla queda vacia y
--      las distancias simplemente no se cargan en esta corrida.
--   5. Por cada Lote en espera con filas en el archivo: pasa a 'procesado
--      por ArcGIS_Externo' y se llaman los dos cargadores con origen
--      'bdm_tempo', que leen estas tablas en vez de hacer su propio COPY. Si
--      la georreferenciacion deja el Lote 'fallido', no se cargan sus
--      distancias (misma regla que sp_geo_ciclo_lote).
--
-- COSTO CONOCIDO: el COPY lee el prefijo entero, con todos los Lotes. Es lo
-- robusto mientras no se conozca el nombre exacto de los archivos (el PDF
-- solo dice geo_result_*). Si ArcGIS no archiva lo procesado, conviene
-- acotar el prefijo por Lote cuando se conozca el patron.
--
-- Espejo mock: sp_rcn_geo_02_buscar_resultados_mock, que lee
-- bdm_stage.mock_geo_respuesta en vez de S3.
-- ============================================================

CREATE OR REPLACE PROCEDURE bdm_datos.sp_rcn_geo_02_buscar_resultados()
NONATOMIC
LANGUAGE plpgsql
AS $$
DECLARE
  v_en_espera    INTEGER;
  v_ambiente     VARCHAR(10);
  v_bucket       VARCHAR(500);
  v_iam_role     VARCHAR(500);
  v_delimiter    VARCHAR(500);
  v_null_string  VARCHAR(500);
  v_prefijo      VARCHAR(500);
  v_base         VARCHAR(2000);
  v_opciones     VARCHAR(2000);
  v_copy_sql     VARCHAR(8000);
  v_filas_geo    INTEGER;
  v_filas_dist   INTEGER;
  v_n            INTEGER;
  v_i            INTEGER;
  v_lote         INTEGER;
  v_estado       VARCHAR(40);
  v_cargados     INTEGER;
  v_err          VARCHAR(2000);
BEGIN

  -- 1) Lotes esperando respuesta de ArcGIS.
  SELECT COUNT(*) INTO v_en_espera
  FROM bdm_datos.geo_lote_control
  WHERE estado = 'exportado';

  IF v_en_espera = 0 THEN
    RAISE INFO 'sp_rcn_geo_02_buscar_resultados: no hay Lotes esperando respuesta de ArcGIS.';
    RETURN;
  END IF;

  -- 2) Configuracion. El ambiente sale del Lote mas reciente, que es el
  --    snapshot que guardo el export.
  SELECT ambiente INTO v_ambiente
  FROM bdm_datos.geo_lote_control
  WHERE estado = 'exportado'
  ORDER BY lote DESC
  LIMIT 1;

  SELECT valor INTO v_bucket
  FROM bdm_datos.geo_config WHERE ambiente = v_ambiente AND parametro = 'bucket';
  SELECT valor INTO v_iam_role
  FROM bdm_datos.geo_config WHERE ambiente = v_ambiente AND parametro = 'iam_role';
  SELECT valor INTO v_delimiter
  FROM bdm_datos.geo_config WHERE ambiente = v_ambiente AND parametro = 'delimiter';
  SELECT valor INTO v_null_string
  FROM bdm_datos.geo_config WHERE ambiente = v_ambiente AND parametro = 'null_string';
  SELECT valor INTO v_prefijo
  FROM bdm_datos.geo_config WHERE ambiente = v_ambiente AND parametro = 's3_output_prefix';

  IF v_prefijo IS NULL OR BTRIM(v_prefijo) = '' THEN
    v_prefijo := 'reconocer_output/';
  END IF;

  IF v_bucket IS NULL OR v_iam_role IS NULL OR v_delimiter IS NULL OR v_null_string IS NULL THEN
    RAISE INFO 'sp_rcn_geo_02_buscar_resultados: configuracion incompleta en geo_config (ambiente %); no se buscan resultados. % Lote(s) siguen esperando.',
      v_ambiente, v_en_espera;
    RETURN;
  END IF;

  v_base := 's3://' || v_bucket || '/' || v_prefijo;
  v_opciones :=
       ' IAM_ROLE ''' || REPLACE(v_iam_role, '''', '''''') || ''''
    || ' DELIMITER ''' || REPLACE(v_delimiter, '''', '''''') || ''''
    || ' NULL AS ''' || REPLACE(v_null_string, '''', '''''') || ''''
    || ' REMOVEQUOTES'
    || ' IGNOREHEADER 1'
    || ' GZIP'
    || ' ACCEPTINVCHARS'
    || ' TRIMBLANKS'
    || ' FILLRECORD';

  -- 3) Resultados de georreferenciacion: todos los archivos del prefijo.
  DROP TABLE IF EXISTS bdm_tempo.stg_geo_resultado_crudo;
  CREATE TABLE bdm_tempo.stg_geo_resultado_crudo (
    col01 VARCHAR(500), col02 VARCHAR(500), col03 VARCHAR(500), col04 VARCHAR(500),
    col05 VARCHAR(500), col06 VARCHAR(500), col07 VARCHAR(500), col08 VARCHAR(500),
    col09 VARCHAR(500), col10 VARCHAR(500), col11 VARCHAR(500), col12 VARCHAR(500),
    col13 VARCHAR(500), col14 VARCHAR(500), col15 VARCHAR(500), col16 VARCHAR(500),
    col17 VARCHAR(500), col18 VARCHAR(500), col19 VARCHAR(500), col20 VARCHAR(500),
    col21 VARCHAR(500), col22 VARCHAR(500), col23 VARCHAR(500), col24 VARCHAR(500),
    col25 VARCHAR(500), col26 VARCHAR(500), col27 VARCHAR(500), col28 VARCHAR(500),
    col29 VARCHAR(500), col30 VARCHAR(500), col31 VARCHAR(500), col32 VARCHAR(500),
    col33 VARCHAR(500)
  )
  DISTSTYLE EVEN;

  v_copy_sql := 'COPY bdm_tempo.stg_geo_resultado_crudo FROM '''
             || REPLACE(v_base || 'geo_result_', '''', '''''') || '''' || v_opciones;
  BEGIN
    EXECUTE v_copy_sql;
  EXCEPTION WHEN OTHERS THEN
    v_err := LEFT(SQLERRM, 2000);
    DROP TABLE IF EXISTS bdm_tempo.stg_geo_resultado_crudo;
    RAISE INFO 'sp_rcn_geo_02_buscar_resultados: sin resultados de georreferenciacion disponibles (%). % Lote(s) siguen esperando; el proceso continua.',
      v_err, v_en_espera;
    RETURN;
  END;

  SELECT COUNT(*) INTO v_filas_geo FROM bdm_tempo.stg_geo_resultado_crudo;

  -- 4) Resultados de distancias. Opcionales: si no estan, se sigue sin ellos.
  DROP TABLE IF EXISTS bdm_tempo.stg_geo_distancias_crudo;
  CREATE TABLE bdm_tempo.stg_geo_distancias_crudo (
    col01 VARCHAR(500), col02 VARCHAR(500), col03 VARCHAR(500), col04 VARCHAR(500),
    col05 VARCHAR(500), col06 VARCHAR(500), col07 VARCHAR(500), col08 VARCHAR(500),
    col09 VARCHAR(500), col10 VARCHAR(500), col11 VARCHAR(500), col12 VARCHAR(500)
  )
  DISTSTYLE EVEN;

  v_copy_sql := 'COPY bdm_tempo.stg_geo_distancias_crudo FROM '''
             || REPLACE(v_base || 'distancias_result_', '''', '''''') || '''' || v_opciones;
  BEGIN
    EXECUTE v_copy_sql;
  EXCEPTION WHEN OTHERS THEN
    v_err := LEFT(SQLERRM, 2000);
    RAISE INFO 'sp_rcn_geo_02_buscar_resultados: sin resultados de distancias disponibles (%); se cargan solo las coordenadas.',
      v_err;
  END;

  SELECT COUNT(*) INTO v_filas_dist FROM bdm_tempo.stg_geo_distancias_crudo;

  -- 5) Lotes en espera que tienen filas en el archivo. Se materializan con un
  --    numero de orden y se recorren con WHILE, el mismo patron de
  --    sp_geo_ciclo_lote.
  DROP TABLE IF EXISTS bdm_tempo.stg_geo_lotes_con_resultado;
  CREATE TABLE bdm_tempo.stg_geo_lotes_con_resultado AS
  SELECT lc.lote,
         ROW_NUMBER() OVER (ORDER BY lc.lote) AS rn
  FROM bdm_datos.geo_lote_control lc
  WHERE lc.estado = 'exportado'
    AND lc.lote::VARCHAR IN (SELECT DISTINCT BTRIM(col02)
                             FROM bdm_tempo.stg_geo_resultado_crudo);

  SELECT COUNT(*) INTO v_n FROM bdm_tempo.stg_geo_lotes_con_resultado;
  v_i := 1;
  v_cargados := 0;

  WHILE v_i <= v_n LOOP
    SELECT lote INTO v_lote
    FROM bdm_tempo.stg_geo_lotes_con_resultado
    WHERE rn = v_i;

    UPDATE bdm_datos.geo_lote_control
    SET estado              = 'procesado por ArcGIS_Externo',
        fecha_actualizacion = GETDATE()
    WHERE lote = v_lote
      AND estado = 'exportado';

    BEGIN
      CALL bdm_datos.sp_geo_cargar_georreferenciacion(v_lote, 'bdm_tempo');
    EXCEPTION WHEN OTHERS THEN
      v_err := LEFT(SQLERRM, 2000);
      RAISE INFO 'sp_rcn_geo_02_buscar_resultados: la georreferenciacion del Lote % fallo (%); se sigue con los demas.',
        v_lote, v_err;
    END;

    SELECT estado INTO v_estado
    FROM bdm_datos.geo_lote_control
    WHERE lote = v_lote;

    IF v_estado = 'cargado' THEN
      v_cargados := v_cargados + 1;
      BEGIN
        CALL bdm_datos.sp_geo_cargar_distancias(v_lote, 'bdm_tempo');
      EXCEPTION WHEN OTHERS THEN
        v_err := LEFT(SQLERRM, 2000);
        RAISE INFO 'sp_rcn_geo_02_buscar_resultados: las distancias del Lote % fallaron (%); se sigue.',
          v_lote, v_err;
      END;
    END IF;

    v_i := v_i + 1;
  END LOOP;

  RAISE INFO 'sp_rcn_geo_02_buscar_resultados: % fila(s) de georreferenciacion y % de distancias leidas; % Lote(s) con resultados, % cargado(s); % Lote(s) esperaban respuesta.',
    v_filas_geo, v_filas_dist, v_n, v_cargados, v_en_espera;

  DROP TABLE IF EXISTS bdm_tempo.stg_geo_lotes_con_resultado;
  DROP TABLE IF EXISTS bdm_tempo.stg_geo_resultado_crudo;
  DROP TABLE IF EXISTS bdm_tempo.stg_geo_distancias_crudo;

EXCEPTION WHEN OTHERS THEN
  -- Ultimo recurso: nada de GEO tumba el proceso que llama.
  v_err := LEFT(SQLERRM, 2000);
  RAISE INFO 'sp_rcn_geo_02_buscar_resultados: busqueda de resultados interrumpida (%); el proceso continua.',
    v_err;
END;
$$;
