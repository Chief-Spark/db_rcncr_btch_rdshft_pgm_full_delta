-- ============================================================
-- sp_geo_reenganchar_r3  (Reconocer / Enriquecimiento GEO - Regla 3)
-- Reenganchador_R3 (task 8.1):
--   Dispara de forma CONDICIONAL la Regla 3 para un Lote una vez que las
--   coordenadas han sido cargadas en bdm_datos.geo_atributos por el
--   Cargador_GEO. Es el eslabon que reengancha la cascada de Unificacion con
--   la Regla 3 sin bloquear jamas el pipeline (R1+R2 y Ordenamiento nunca
--   esperan a ArcGIS_Externo).
--
-- Comportamiento (Req 6.1, 6.3, 6.5, 10.2, 10.4, 12.1, 12.2, 12.3, 12.4):
--   1) Si el Lote tiene al menos una ubicacion con latitud IS NOT NULL y
--      estado de geocodificacion distinto de 'U'/pendiente/no geocodificada
--      -> invocar la Regla 3 real
--      (sp_unificacion_r3_esc1_geo_misma_via_puerta_cercana), que lee las
--      coordenadas desde geo_atributos via el LEFT JOIN agregado en task 7.1.
--   2) Las ubicaciones con Status 'U' o pendientes NO tienen latitud poblada
--      (el Cargador_GEO conserva NULL para ellas), por lo que el filtro
--      WHERE latitud IS NOT NULL de la Regla 3 ya las excluye de forma
--      natural del emparejamiento (Req 6.3, 10.2, 10.4).
--   3) Si el Lote no tiene ninguna coordenada cargada -> OMITIR la Regla 3
--      registrando la omision como ESTADO ESPERADO (RAISE INFO, no error) y
--      continuar; el pipeline sigue hacia Ordenamiento con R1+R2 (Req 12.2,
--      12.3).
--   4) Si la invocacion de la Regla 3 falla -> NO insertar unificaciones,
--      marcar el Lote 'fallido' (fase reenganche_r3) disponible para
--      reintento, registrar el error, y permitir que el pipeline continue a
--      Ordenamiento SIN abortar la ejecucion global (Req 6.5).
--   5) Nunca bloquea la cascada de Unificacion ni Ordenamiento a la espera
--      del ciclo GEO de ArcGIS_Externo (Req 12.4).
--
-- Nota sobre el alcance del Lote y la firma de la Regla 3:
--   La Regla 3 real (sp_unificacion_r3_esc1_geo_misma_via_puerta_cercana)
--   NO recibe parametro de Lote: procesa todas las ubicaciones cuyas
--   coordenadas esten pobladas en geo_atributos (filtra WHERE latitud IS NOT
--   NULL). Este SP la invoca tal cual (sin argumentos). El scoping por Lote
--   se resuelve por datos: solo se invoca la Regla 3 cuando el Lote recien
--   cargado aporto coordenadas nuevas; una vez pobladas, la Regla 3 opera
--   sobre el estado acumulado de geo_atributos y es idempotente respecto a
--   las unificaciones ya insertadas (INSERT ... SELECT DISTINCT + tipo 3).
--   Cuando la Regla 3 real reciba un parametro de Lote en el futuro, basta
--   propagar in_lote en la llamada de la seccion 4.
--
-- Objeto en bdm_datos; idempotente (CREATE OR REPLACE PROCEDURE).
-- NONATOMIC y consistente con la cadena de CALL (la Regla 3 que invoca es
-- NONATOMIC; mezclar modos produce P0001). UTF-8 sin BOM. Nunca GRANT ...
-- TO PUBLIC.
-- Prerrequisitos: _strct desplegado (geo_atributos, geo_lote_control);
--   _pgm con sp_unificacion_r3_esc1_geo_misma_via_puerta_cercana modificada
--   (task 7.1) para leer coordenadas de geo_atributos.
-- Ref: .kiro/specs/geo-enriquecimiento-regla3/design.md
--      (Reenganchador_R3 - sp_geo_reenganchar_r3)
--      Requisitos: 6.1, 6.3, 6.5, 10.2, 10.4, 12.1, 12.2, 12.3, 12.4.
-- ============================================================

CREATE OR REPLACE PROCEDURE bdm_datos.sp_geo_reenganchar_r3(in_lote INTEGER)
NONATOMIC
LANGUAGE plpgsql
AS $$
DECLARE
  v_cnt_con_coords  INTEGER;
BEGIN

  -- 1) Validacion de entrada minima: Lote requerido.
  IF in_lote IS NULL THEN
    RAISE EXCEPTION 'sp_geo_reenganchar_r3: in_lote es obligatorio (NULL recibido).';
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
  FROM bdm_datos.geo_atributos g
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
    RAISE INFO 'sp_geo_reenganchar_r3: Lote % sin coordenadas aptas en geo_atributos; Regla 3 OMITIDA (estado esperado, no error). Pipeline continua a Ordenamiento con R1+R2.',
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
  BEGIN
    CALL bdm_datos.sp_unificacion_r3_esc1_geo_misma_via_puerta_cercana();
  EXCEPTION WHEN OTHERS THEN
    -- 4.a) Fallo de la Regla 3 (Req 6.5): NO se insertan unificaciones del
    --      Lote (la propia Regla 3 hace su limpieza de staging al fallar),
    --      se marca el Lote 'fallido' (fase reenganche_r3) disponible para
    --      reintento, se registra el error, y se PERMITE que el pipeline
    --      continue a Ordenamiento sin abortar la ejecucion global.
    UPDATE bdm_datos.geo_lote_control
    SET estado              = 'fallido',
        fase_fallo          = 'reenganche_r3',
        ultimo_error        = LEFT('Reenganche Regla 3 fallido: ' || SQLERRM, 500),
        fecha_actualizacion = GETDATE()
    WHERE lote = in_lote;

    RAISE INFO 'sp_geo_reenganchar_r3: Lote % marcado fallido (fase reenganche_r3): %. Unificaciones no insertadas; pipeline continua a Ordenamiento, ejecucion global NO abortada.',
      in_lote, SQLERRM;
    RETURN;
  END;

  -- 5) Regla 3 aplicada correctamente para el Lote. Se registra la
  --    trazabilidad; el estado del Lote se mantiene 'cargado' (fase final del
  --    ciclo GEO). El pipeline continua a Ordenamiento con R1+R2+R3 (Req 12.5).
  UPDATE bdm_datos.geo_lote_control
  SET fase_fallo          = NULL,
      ultimo_error        = NULL,
      fecha_actualizacion = GETDATE()
  WHERE lote = in_lote;

  RAISE INFO 'sp_geo_reenganchar_r3: Lote % con % ubicacion(es) apta(s); Regla 3 aplicada (unificaciones tipo 3). Pipeline continua a Ordenamiento con R1+R2+R3.',
    in_lote, v_cnt_con_coords;

END;
$$;
-- SLCOPRBA-1355: re-DPLY DEV post DROP SCHEMA strct #256
