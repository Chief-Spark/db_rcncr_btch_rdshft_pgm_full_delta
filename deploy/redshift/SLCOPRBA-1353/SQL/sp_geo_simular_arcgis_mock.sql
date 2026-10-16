-- ============================================================
-- sp_geo_simular_arcgis_mock  (Reconocer / GEO MOCK - SLCOPRBA-1355)
--
-- ESTO NO ES UN PORT. Es el doble del sistema EXTERNO ArcGIS_Externo, y se
-- llama asi para que nadie lo confunda con logica migrada del legado. Ocupa
-- el hueco que en el camino real llenan tres cosas que no tenemos en DEV: el
-- UNLOAD a S3, el proceso de geocodificacion de ArcGIS, y la notificacion
-- (SQS + Lambda ResultTransfer) que devuelve el archivo.
--
-- QUE HACE, y nada mas que esto:
--   1. escribe bdm_stage.mock_geo_respuesta -- el "archivo de vuelta" -- con
--      una fila por candidato del Lote, en el contrato de 32 columnas;
--   2. mueve el Lote a 'procesado por ArcGIS_Externo', que es el unico estado
--      desde el que el cargador admite cargar (gate de estado, Req 7.5).
--
-- LOS DOS MODOS son los que permiten certificar las dos ramas del
-- reenganche con el mismo codigo:
--   'M' -> todas las ubicaciones vuelven geocodificadas, con coordenadas.
--          Ejercita CA-02, CA-03 y la rama CON coordenadas de CA-04.
--   'U' -> todas vuelven no geocodificadas, sin coordenadas. Ejercita la
--          rama SIN coordenadas de CA-05, donde la Regla 3 se omite como
--          estado esperado.
--
-- LAS COORDENADAS QUE DEVUELVE SON LAS QUE EL MOCK YA SIRVE, no inventadas,
-- y esa decision es deliberada. Un simulador que geocodificara las ~103.000
-- ubicaciones candidatas le daria a la Regla 3 coordenadas que antes no
-- tenia, apareceria con pares nuevos y MOVERIA EL TABLERO DE UNIFICACION,
-- que esta en 45/45 y cuyos criterios R3-02..R3-10 afirman conteos exactos.
-- Certificar GEO rompiendo Unificacion no es certificar.
--
-- Por eso el modo 'M' solo marca geocodificada la ubicacion que YA tiene
-- latitud y longitud en bdm_tempo.v_mock_ubicacion_estandarizada, y les
-- devuelve esos mismos valores. El resto vuelve 'U'. El insumo de la Regla 3
-- queda byte a byte como estaba y lo que se certifica sigue siendo lo que el
-- criterio pide: que el cargador escriba Status y coordenadas en
-- geo_atributos_mock, y que el reenganche decida con eso.
--
-- Las coordenadas se escriben con punto decimal, que es lo que el cargador
-- exige (Req 5.4), y caen dentro de los rangos que valida ([-90,90] y
-- [-180,180]) porque son coordenadas reales del mock.
--
-- Objeto en bdm_datos; idempotente: limpia las filas previas del Lote antes
-- de escribir, de modo que reinvocarlo deja el mismo estado.
-- NONATOMIC y consistente con la cadena de CALL. UTF-8 sin BOM.
-- ============================================================

CREATE OR REPLACE PROCEDURE bdm_datos.sp_geo_simular_arcgis_mock(in_lote INTEGER, in_modo VARCHAR)
NONATOMIC
LANGUAGE plpgsql
AS $$
DECLARE
  v_modo    VARCHAR(1);
  v_estado  VARCHAR(40);
  v_filas   INTEGER;
BEGIN

  IF in_lote IS NULL THEN
    RAISE EXCEPTION 'sp_geo_simular_arcgis_mock: in_lote es obligatorio (NULL recibido).';
  END IF;

  IF in_modo IS NULL OR BTRIM(in_modo) = '' THEN
    v_modo := 'M';
  ELSE
    v_modo := UPPER(LEFT(BTRIM(in_modo), 1));
  END IF;

  IF v_modo NOT IN ('M', 'U') THEN
    RAISE EXCEPTION 'sp_geo_simular_arcgis_mock: in_modo debe ser M o U (recibido: %).', in_modo;
  END IF;

  -- El Lote tiene que existir y venir de una exportacion. Si no, se rechaza
  -- sin tocar nada: igual que el cargador, el rechazo es local al Lote.
  SELECT estado INTO v_estado
  FROM bdm_datos.geo_lote_control_mock
  WHERE lote = in_lote;

  IF v_estado IS NULL THEN
    RAISE INFO 'sp_geo_simular_arcgis_mock: Lote % inexistente en geo_lote_control_mock; nada que simular.',
      in_lote;
    RETURN;
  END IF;

  -- Idempotencia: el "archivo" del Lote se reescribe entero.
  DELETE FROM bdm_stage.mock_geo_respuesta
  WHERE BTRIM(col02) = in_lote::VARCHAR;

  -- Una fila por candidato del Lote, en el contrato de 32 columnas. Solo
  -- cinco llevan dato; las otras 27 existen para que la forma coincida con
  -- la del archivo real.
  -- En modo 'M' vuelve geocodificada SOLO la ubicacion que ya tiene
  -- coordenadas en el mock, y con esas mismas coordenadas; las demas vuelven
  -- 'U'. En modo 'U' vuelven todas 'U'. El LEFT JOIN decide la rama por fila.
  INSERT INTO bdm_stage.mock_geo_respuesta (col01, col02, col03, col04, col05, col06)
  SELECT
    g.cod_dw_ubic::VARCHAR,
    in_lote::VARCHAR,
    CASE WHEN v_modo = 'M' AND u.latitud IS NOT NULL AND u.longitud IS NOT NULL
         THEN 'M' ELSE 'U' END,
    NULL,
    CASE WHEN v_modo = 'M' AND u.latitud IS NOT NULL AND u.longitud IS NOT NULL
         THEN CAST(CAST(u.latitud AS DECIMAL(10,6)) AS VARCHAR) END,
    CASE WHEN v_modo = 'M' AND u.latitud IS NOT NULL AND u.longitud IS NOT NULL
         THEN CAST(CAST(u.longitud AS DECIMAL(10,6)) AS VARCHAR) END
  FROM bdm_datos.geo_atributos_mock g
  LEFT JOIN bdm_tempo.v_mock_ubicacion_estandarizada u
    ON u.cod_dw_ubic = g.cod_dw_ubic
  WHERE g.lote = in_lote;

  GET DIAGNOSTICS v_filas = ROW_COUNT;

  -- Cerrar el ciclo externo: el Lote queda listo para que el cargador lo
  -- admita. Es el unico estado que su gate acepta.
  UPDATE bdm_datos.geo_lote_control_mock
  SET estado              = 'procesado por ArcGIS_Externo',
      fase_fallo          = NULL,
      ultimo_error        = NULL,
      fecha_actualizacion = GETDATE()
  WHERE lote = in_lote;

  RAISE INFO 'sp_geo_simular_arcgis_mock: Lote % simulado en modo % con % fila(s); estado movido a "procesado por ArcGIS_Externo".',
    in_lote, v_modo, v_filas;

EXCEPTION WHEN OTHERS THEN
  RAISE EXCEPTION 'sp_geo_simular_arcgis_mock failed: %', SQLERRM;
END;
$$;
