-- ============================================================
-- sp_cert_geo_mock  (Reconocer / GEO MOCK - SLCOPRBA-1355)
--
-- Corre el ciclo GEO mock completo DOS VECES sobre el mismo Lote y escribe
-- el veredicto de CA-02, CA-03, CA-04 y CA-05 en bdm_datos.cert_resultado.
-- CA-01 NO se toca aqui: lo afirma sp_cert_evaluar_criterios_mock con el
-- Lote recien exportado, y desde que la exportacion mock omite el UNLOAD
-- (s3_enabled = '0') ese criterio se resuelve solo.
--
-- POR QUE DOS PASADAS. El reenganche tiene dos ramas y las dos son criterio:
--   pasada 'U' -> ninguna ubicacion vuelve con coordenadas -> la Regla 3 se
--                 OMITE como estado esperado. Es CA-05.
--   pasada 'M' -> vuelven con coordenadas -> la Regla 3 se INVOCA y el Lote
--                 se queda 'cargado'. Son CA-02, CA-03 y CA-04.
-- El orden importa: 'U' primero, porque 'M' deja el estado final que miran
-- los otros tres criterios. Si se invirtiera, la pasada 'U' borraria las
-- coordenadas que CA-02 tiene que ver.
--
-- POR QUE VA DESPUES DE LA BATERIA Y NO DENTRO. El cargador mueve el Lote a
-- 'cargado', y CA-01 exige verlo en 'exportado'. Metiendo esto dentro del
-- ciclo e2e, CA-01 se caeria por un efecto de orden y no por un defecto.
-- Corre entre la convergencia y el tablero.
--
-- SE INVOCA SIN ARGUMENTOS a proposito: el Lote se resuelve dentro con un
-- MAX(). Redshift no admite subconsultas como argumento de CALL, de modo que
-- un runner de dt no podria pasarselo.
--
-- Objeto en bdm_datos. NONATOMIC y consistente con la cadena de CALL.
-- UTF-8 sin BOM. Nunca GRANT ... TO PUBLIC.
-- ============================================================

CREATE OR REPLACE PROCEDURE bdm_datos.sp_cert_geo_mock()
NONATOMIC
LANGUAGE plpgsql
AS $$
DECLARE
  v_lote        INTEGER;
  v_estado      VARCHAR(40);
  v_fase        VARCHAR(40);
  v_error       VARCHAR(500);
  v_cnt_m       INTEGER;
  v_cnt_u       INTEGER;
  v_cnt_coords  INTEGER;
  v_cnt_r3      INTEGER;
  v_r3_antes    INTEGER;
  v_hoy         TIMESTAMP;
  v_usuario     VARCHAR(100);
BEGIN
  v_hoy     := GETDATE();
  v_usuario := LEFT(CURRENT_USER, 100);

  SELECT MAX(lote) INTO v_lote FROM bdm_datos.geo_lote_control_mock;

  -- Sin Lote no hay nada que afirmar. Se escriben los cuatro como SIN_DATO
  -- con la razon, que es lo que el tablero sabe interpretar.
  IF v_lote IS NULL THEN
    INSERT INTO bdm_datos.cert_resultado
      (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
    SELECT 0, 'GEO', c.criterio, 'SIN_DATO',
           'sin Lote en geo_lote_control_mock: la exportacion mock no asigno Lote, de modo que no hay ciclo GEO que cargar ni reenganchar.',
           v_hoy, v_usuario
    FROM (SELECT 'CA-02' AS criterio UNION ALL SELECT 'CA-03'
          UNION ALL SELECT 'CA-04' UNION ALL SELECT 'CA-05') c;
    RAISE INFO 'sp_cert_geo_mock: sin Lote mock; CA-02..CA-05 en SIN_DATO.';
    RETURN;
  END IF;

  -- Conteo de unificaciones tipo 3 ANTES de tocar nada, para poder afirmar
  -- en CA-04 que la Regla 3 del reenganche no destruye las que ya habia.
  SELECT COUNT(*) INTO v_r3_antes
  FROM bdm_datos.unificacion_direccion_mock
  WHERE unifica_atributos = 3;

  -- ==========================================================
  -- PASADA 'U': sin coordenadas. Certifica CA-05.
  -- ==========================================================
  CALL bdm_datos.sp_geo_simular_arcgis_mock(v_lote, 'U');
  CALL bdm_datos.sp_geo_cargar_georreferenciacion_mock(v_lote, 'mock://sin-s3');
  CALL bdm_datos.sp_geo_reenganchar_r3_mock(v_lote);

  SELECT estado, fase_fallo, ultimo_error
    INTO v_estado, v_fase, v_error
  FROM bdm_datos.geo_lote_control_mock WHERE lote = v_lote;

  SELECT COUNT(*) INTO v_cnt_coords
  FROM bdm_datos.geo_atributos_mock
  WHERE lote = v_lote AND latitud IS NOT NULL AND longitud IS NOT NULL
    AND COALESCE(status_match, '') <> 'U'
    AND COALESCE(estado_geo, '') NOT IN ('no geocodificada', 'pendiente de geocodificacion');

  SELECT COUNT(*) INTO v_cnt_r3
  FROM bdm_datos.unificacion_direccion_mock
  WHERE unifica_atributos = 3;

  INSERT INTO bdm_datos.cert_resultado
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT v_lote, 'GEO', 'CA-05',
         CASE WHEN v_cnt_coords = 0
               AND v_estado = 'cargado'
               AND v_fase IS NULL
               AND v_cnt_r3 = v_r3_antes THEN 'PASSED' ELSE 'FAILED' END,
         'pasada sin coordenadas: ubicaciones aptas del Lote=' || CAST(v_cnt_coords AS VARCHAR)
           || ' (esperado 0), estado del Lote=' || COALESCE(v_estado, '-')
           || ' (esperado cargado), fase_fallo=' || COALESCE(v_fase, 'NULL')
           || ' (esperado NULL), unificaciones tipo 3=' || CAST(v_cnt_r3 AS VARCHAR)
           || ' contra ' || CAST(v_r3_antes AS VARCHAR)
           || ' antes del ciclo (esperado igual: la Regla 3 se omite y no agrega ninguna).'
           || ' El SP no lanza excepcion: la omision es estado esperado, no error.',
         v_hoy, v_usuario;

  -- ==========================================================
  -- PASADA 'M': con coordenadas. Certifica CA-02, CA-03 y CA-04.
  -- ==========================================================
  CALL bdm_datos.sp_geo_simular_arcgis_mock(v_lote, 'M');
  CALL bdm_datos.sp_geo_cargar_georreferenciacion_mock(v_lote, 'mock://sin-s3');
  CALL bdm_datos.sp_geo_reenganchar_r3_mock(v_lote);

  SELECT estado, fase_fallo, ultimo_error
    INTO v_estado, v_fase, v_error
  FROM bdm_datos.geo_lote_control_mock WHERE lote = v_lote;

  SELECT COUNT(*) INTO v_cnt_m
  FROM bdm_datos.geo_atributos_mock
  WHERE lote = v_lote AND status_match = 'M' AND estado_geo = 'geocodificada'
    AND latitud IS NOT NULL AND longitud IS NOT NULL;

  SELECT COUNT(*) INTO v_cnt_u
  FROM bdm_datos.geo_atributos_mock
  WHERE lote = v_lote AND status_match = 'U' AND estado_geo = 'no geocodificada';

  SELECT COUNT(*) INTO v_cnt_r3
  FROM bdm_datos.unificacion_direccion_mock
  WHERE unifica_atributos = 3;

  -- CA-02: Status M aplicado con coordenadas pobladas.
  INSERT INTO bdm_datos.cert_resultado
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT v_lote, 'GEO', 'CA-02',
         CASE WHEN v_cnt_m > 0 THEN 'PASSED' ELSE 'FAILED' END,
         'ubicaciones del Lote con status_match=M, estado_geo=geocodificada y lat/long pobladas='
           || CAST(v_cnt_m AS VARCHAR) || ' (esperado > 0); con status_match=U y no geocodificada='
           || CAST(v_cnt_u AS VARCHAR) || '.'
           || ' Certificado sobre el cargador MOCK: el COPY desde S3 se sustituye por un INSERT'
           || ' desde bdm_stage.mock_geo_respuesta y el resto del SP es identico al real.',
         v_hoy, v_usuario;

  -- CA-03: el Lote cierra en 'cargado' con fase_fallo y ultimo_error en NULL.
  INSERT INTO bdm_datos.cert_resultado
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT v_lote, 'GEO', 'CA-03',
         CASE WHEN v_estado = 'cargado' AND v_fase IS NULL AND v_error IS NULL
              THEN 'PASSED' ELSE 'FAILED' END,
         'estado del Lote=' || COALESCE(v_estado, '-') || ' (esperado cargado), fase_fallo='
           || COALESCE(v_fase, 'NULL') || ', ultimo_error='
           || COALESCE(LEFT(v_error, 120), 'NULL') || ' (ambos esperados NULL).',
         v_hoy, v_usuario;

  -- CA-04: reenganche con coordenadas. La Regla 3 se invoca, las
  -- unificaciones tipo 3 siguen en pie y el Lote se mantiene 'cargado'.
  INSERT INTO bdm_datos.cert_resultado
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT v_lote, 'GEO', 'CA-04',
         CASE WHEN v_cnt_m > 0 AND v_estado = 'cargado' AND v_fase IS NULL
                   AND v_cnt_r3 >= v_r3_antes THEN 'PASSED' ELSE 'FAILED' END,
         'ubicaciones aptas que entraron a la Regla 3=' || CAST(v_cnt_m AS VARCHAR)
           || ', unificaciones tipo 3=' || CAST(v_cnt_r3 AS VARCHAR)
           || ' contra ' || CAST(v_r3_antes AS VARCHAR) || ' antes del ciclo, estado del Lote='
           || COALESCE(v_estado, '-') || ' (esperado cargado, fase_fallo NULL).'
           || ' El reenganche es idempotente por diseno: aporta coordenadas a direcciones que ya'
           || ' existen, de modo que el conteo no baja. Las coordenadas que devuelve el simulador'
           || ' son las que el mock ya servia, para no mover el tablero de Unificacion.',
         v_hoy, v_usuario;

  RAISE INFO 'sp_cert_geo_mock: Lote % certificado. M=%, U=%, tipo 3=% (antes %).',
    v_lote, v_cnt_m, v_cnt_u, v_cnt_r3, v_r3_antes;

EXCEPTION WHEN OTHERS THEN
  RAISE EXCEPTION 'sp_cert_geo_mock failed: %', SQLERRM;
END;
$$;
