-- ============================================================
-- sp_geo_reenganchar_r3_mock  (Reconocer / GEO MOCK - Regla 3)
--
-- ESPEJO MOCK de sp_geo_reenganchar_r3, por sustitucion de fuentes:
--     geo_atributos                   -> geo_atributos_mock
--     geo_lote_control                -> geo_lote_control_mock
--     sp_unificacion_r3_esc1_geo_...  -> sp_unificacion_mock_r3_esc1_geo_...
--
-- NO HAY NINGUNA OTRA DIFERENCIA: la decision -- contar ubicaciones aptas
-- del Lote y, segun haya o no, invocar la Regla 3 u omitirla como estado
-- esperado -- es el mismo codigo, y el aislamiento del fallo tambien.
--
-- COMO LLEGAN LAS COORDENADAS HASTA LA REGLA 3, que es lo que hace que esto
-- certifique algo y no solo lo parezca: la Regla 3 mock no lee
-- geo_atributos_mock directamente, lee bdm_tempo.v_mock_ubicacion_
-- estandarizada, y esa vista ya trae
--     COALESCE de la latitud propia con la de geo_atributos_mock
-- por LEFT JOIN (02b_vistas_insumo_mock.sql). O sea que lo que el cargador
-- mock escribe entra en la Regla 3 por el mismo camino que en produccion.
-- El cableado ya estaba; lo que faltaba era quien escribiera.
--
-- LAS DOS RAMAS SE CERTIFICAN CON EL MISMO CODIGO, cambiando solo el modo
-- con que sp_geo_simular_arcgis_mock prepara el Lote:
--     modo M -> hay coordenadas aptas -> se invoca la Regla 3   = CA-04
--     modo U -> no hay                -> se omite, sin error    = CA-05
--
-- Objeto en bdm_datos; idempotente. NONATOMIC y consistente con la cadena
-- de CALL. UTF-8 sin BOM. Nunca GRANT ... TO PUBLIC.
-- ============================================================

CREATE OR REPLACE PROCEDURE bdm_datos.sp_geo_reenganchar_r3_mock(in_lote INTEGER)
NONATOMIC
LANGUAGE plpgsql
AS $$
DECLARE
  v_cnt_con_coords  INTEGER;
BEGIN

  -- 1) Validacion de entrada minima: Lote requerido.
  IF in_lote IS NULL THEN
    RAISE EXCEPTION 'sp_geo_reenganchar_r3_mock: in_lote es obligatorio (NULL recibido).';
  END IF;

  -- 2) Evaluar coordenadas del Lote (condicion de la Regla 3, Req 6.1, 12.1).
  --    Se cuentan las ubicaciones del Lote APTAS para la Regla 3: latitud
  --    (y longitud) no nula y estado de geocodificacion valido, es decir
  --    EXCLUYENDO explicitamente las ubicaciones con Status 'U' o en estado
  --    'no geocodificada' / 'pendiente de geocodificacion' (Req 6.3, 10.2,
  --    10.4). Aunque el Cargador_GEO conserva latitud NULL para esas
  --    ubicaciones (por lo que el filtro de la Regla 3 ya las descartaria),
  --    la exclusion se hace explicita aqui para dejar la condicion inequivoca.
  SELECT COUNT(*)
    INTO v_cnt_con_coords
  FROM bdm_datos.geo_atributos_mock g
  WHERE g.lote = in_lote
    AND g.latitud IS NOT NULL
    AND g.longitud IS NOT NULL
    AND COALESCE(g.status_match, '') <> 'U'
    AND COALESCE(g.estado_geo, '') NOT IN ('no geocodificada', 'pendiente de geocodificacion');

  -- 3) Rama SIN coordenadas: omitir la Regla 3 como estado esperado
  --    (Req 12.2, 12.3). NO es un error: se registra con RAISE INFO y el
  --    pipeline continua hacia Ordenamiento con el estado R1+R2 (Req 12.4).
  --    El Lote y sus ubicaciones quedan disponibles para un ciclo GEO
  --    posterior (Req 10.2, 10.4, 12.6).
  IF v_cnt_con_coords = 0 THEN
    RAISE INFO 'sp_geo_reenganchar_r3_mock: Lote % sin coordenadas aptas en geo_atributos; Regla 3 OMITIDA (estado esperado, no error). Pipeline continua a Ordenamiento con R1+R2.',
      in_lote;
    RETURN;
  END IF;

  -- 4) Rama CON coordenadas: invocar la Regla 3 (Req 6.1, 6.4, 12.1).
  --    La Regla 3 real lee lat/long desde geo_atributos (LEFT JOIN, task 7.1)
  --    e inserta las unificaciones con tipo 3 en bdm_datos.unificacion_direccion.
  --    Solo participan las ubicaciones con latitud IS NOT NULL (Req 6.2);
  --    las 'U'/pendientes/no geocodificadas quedan excluidas (Req 6.3, 10.2,
  --    10.4). La invocacion se aisla con un bloque de manejo de errores para
  --    que un fallo de la Regla 3 sea LOCAL al Lote y no aborte el global.
  --    SLCOPRBA-1355: LA LLAMADA IBA SIN ARGUMENTOS y la firma pide dos
  --    (p_modo, p_lote). No fallaba al desplegar -- CREATE OR REPLACE
  --    PROCEDURE no compila el cuerpo -- sino en la primera invocacion, que
  --    caia en el EXCEPTION de abajo y marcaba el Lote 'fallido' con un error
  --    de aridez disfrazado de fallo de la Regla 3. Es el primero de los dos
  --    defectos encadenados que CA-04 reporta; el segundo era que ninguna
  --    vista de insumo leia geo_atributos, ya corregido en strct.
  --    El reenganche es incremental por definicion: aporta coordenadas nuevas
  --    a direcciones que ya existen, de modo que el modo es DELTA (upsert) y
  --    nunca FULL. El Lote que sella las parejas es el Lote GEO, que es el que
  --    permite rastrear que reenganche las produjo.
  BEGIN
    CALL bdm_datos.sp_unificacion_mock_r3_esc1_geo_misma_via_puerta_cercana('DELTA', in_lote);
  EXCEPTION WHEN OTHERS THEN
    -- 4.a) Fallo de la Regla 3 (Req 6.5): NO se insertan unificaciones del
    --      Lote (la propia Regla 3 hace su limpieza de staging al fallar),
    --      se marca el Lote 'fallido' (fase reenganche_r3) disponible para
    --      reintento, se registra el error, y se PERMITE que el pipeline
    --      continue a Ordenamiento sin abortar la ejecucion global.
    UPDATE bdm_datos.geo_lote_control_mock
    SET estado              = 'fallido',
        fase_fallo          = 'reenganche_r3',
        ultimo_error        = LEFT('Reenganche Regla 3 fallido: ' || SQLERRM, 500),
        fecha_actualizacion = GETDATE()
    WHERE lote = in_lote;

    RAISE INFO 'sp_geo_reenganchar_r3_mock: Lote % marcado fallido (fase reenganche_r3): %. Unificaciones no insertadas; pipeline continua a Ordenamiento, ejecucion global NO abortada.',
      in_lote, SQLERRM;
    RETURN;
  END;

  -- 5) Regla 3 aplicada correctamente para el Lote. Se registra la
  --    trazabilidad; el estado del Lote se mantiene 'cargado' (fase final del
  --    ciclo GEO). El pipeline continua a Ordenamiento con R1+R2+R3 (Req 12.5).
  UPDATE bdm_datos.geo_lote_control_mock
  SET fase_fallo          = NULL,
      ultimo_error        = NULL,
      fecha_actualizacion = GETDATE()
  WHERE lote = in_lote;

  RAISE INFO 'sp_geo_reenganchar_r3_mock: Lote % con % ubicacion(es) apta(s); Regla 3 aplicada (unificaciones tipo 3). Pipeline continua a Ordenamiento con R1+R2+R3.',
    in_lote, v_cnt_con_coords;

END;
$$;
-- SLCOPRBA-1355: re-DPLY DEV post DROP SCHEMA strct #256
