-- ============================================================
-- sp_geo_ciclo_lote  (Reconocer / Enriquecimiento GEO - Regla 3)
-- Orquestador SQL (task 9.1):
--   Coordina, por Lote, la cadena de carga + reenganche una vez que
--   ArcGIS_Externo entrego sus salidas y la orquestacion externa notifico las
--   rutas S3:
--       sp_geo_cargar_georreferenciacion (georef, 1:1)
--         -> sp_geo_cargar_distancias      (distancias, 1:N)
--         -> sp_geo_reenganchar_r3         (R3 condicional)
--   aplicando la politica de reintentos por Lote (Req 13) y actualizando la
--   maquina de estados / contadores en bdm_datos.geo_lote_control.
--
-- Firma elegida (documentada):
--   sp_geo_ciclo_lote(in_lote INTEGER,
--                     in_s3_path_georef VARCHAR,
--                     in_s3_path_distancias VARCHAR)
--   Justificacion: el ciclo necesita el Lote y las DOS rutas S3 que la
--   orquestacion externa entrega en la notificacion (una por cada salida de
--   ArcGIS_Externo: GEOCODE y DISTANCIAS). El reenganche de R3 no requiere
--   ruta (opera sobre geo_atributos ya poblada), por lo que solo se propaga
--   in_lote. El ambiente NO se pasa como argumento: se resuelve del snapshot
--   registrado en geo_lote_control al exportar el Lote (Req 8.x), evitando
--   desajustes cuenta/ambiente.
--
-- Comportamiento (Req 7.3, 13.1, 13.2, 13.3, 13.4, 13.5, 13.6):
--   1) Cadena idempotente por Lote: cada paso (sp_geo_cargar_*, reenganche)
--      ya es idempotente por Lote; reejecutar el ciclo sobre el mismo Lote
--      produce el mismo estado final (Req 7.3, 13.3).
--   2) Deteccion de fallo por estado: los SP encadenados NO propagan
--      excepcion en un fallo local (usan RAISE INFO + marca 'fallido' en
--      geo_lote_control). Por eso, tras CADA paso, este orquestador RELEE el
--      estado del Lote; si quedo 'fallido' detiene la cadena de ese Lote y
--      pasa a la politica de reintentos. Asi no se ejecuta un paso posterior
--      sobre un Lote ya fallido.
--   3) Reintentos hasta max_retries (Req 13.1, 13.2): el numero maximo se lee
--      de geo_config (parametro 'max_retries') para el ambiente del Lote, con
--      respaldo al snapshot max_reintentos de geo_lote_control. En cada fallo
--      se incrementa geo_lote_control.intentos; mientras intentos < max_retries
--      el Lote se deja 'fallido' (disponible para reintento) y el orquestador
--      lo reintenta en la misma invocacion (bucle acotado), reaplicando la
--      cadena idempotente.
--   4) Agotamiento de reintentos (Req 13.4): al alcanzar intentos >=
--      max_retries sin exito, el Lote transita a 'fallido definitivo',
--      conservando fase_fallo y ultimo_error, disponible para intervencion
--      manual. No se relanza automaticamente.
--   5) Aislamiento del pipeline (Req 13.5): un fallo (transitorio o
--      definitivo) de un Lote es LOCAL; este SP usa RAISE INFO (no EXCEPTION)
--      para los fallos por-Lote, de modo que los demas Lotes y el pipeline
--      (Unificacion R1+R2 y Ordenamiento) continuan sin abortar el global.
--   6) Backoff delegado (Req 13.6): Redshift no ofrece un sleep confiable en
--      PLpgSQL, por lo que la ESPERA entre reintentos NO se hace dentro del
--      SP. El orquestador externo (Framework Batch / Step Functions) aplica
--      retry_backoff_seconds entre reinvocaciones; este SP se limita a
--      registrar 'intentos' y los timestamps (fecha_actualizacion) en
--      geo_lote_control para que la orquestacion respete el intervalo. El
--      bucle interno de reintentos NO duerme: reintenta de inmediato la
--      cadena idempotente; la cadencia temporal la gobierna el orquestador.
--
-- Objeto en bdm_datos; idempotente (CREATE OR REPLACE PROCEDURE).
-- NONATOMIC y consistente con la cadena de CALL: todos los SP invocados
-- (sp_geo_cargar_georreferenciacion, sp_geo_cargar_distancias,
-- sp_geo_reenganchar_r3) son NONATOMIC; mezclar modos atomic/nonatomic en la
-- cadena produce P0001, por lo que este orquestador tambien es NONATOMIC.
-- UTF-8 sin BOM. Nunca GRANT ... TO PUBLIC.
-- Prerrequisitos: _strct desplegado (geo_lote_control, geo_config, funcion
--   geo_get_config); _pgm con sp_geo_cargar_georreferenciacion,
--   sp_geo_cargar_distancias y sp_geo_reenganchar_r3 desplegados.
-- Ref: .kiro/specs/geo-enriquecimiento-regla3/design.md
--      (Orquestador SQL - sp_geo_ciclo_lote; seccion Reintentos (Req 13))
--      Requisitos: 7.3, 13.1, 13.2, 13.3, 13.4, 13.5, 13.6.
-- ============================================================

CREATE OR REPLACE PROCEDURE bdm_datos.sp_geo_ciclo_lote(in_lote INTEGER, in_s3_path_georef VARCHAR, in_s3_path_distancias VARCHAR)
NONATOMIC
LANGUAGE plpgsql
AS $$
DECLARE
  v_estado         VARCHAR(40);
  v_ambiente       VARCHAR(10);
  v_max_reints     SMALLINT;
  v_max_cfg        VARCHAR(500);
  v_intentos       SMALLINT;
  v_exito          BOOLEAN;
  v_intento_actual SMALLINT;
  v_max_pasadas    SMALLINT;
BEGIN

  -- ----------------------------------------------------------
  -- 1) Validaciones de entrada minimas: Lote y ambas rutas S3 requeridas.
  -- ----------------------------------------------------------
  IF in_lote IS NULL THEN
    RAISE EXCEPTION 'sp_geo_ciclo_lote: in_lote es obligatorio (NULL recibido).';
  END IF;
  IF in_s3_path_georef IS NULL OR BTRIM(in_s3_path_georef) = '' THEN
    RAISE EXCEPTION 'sp_geo_ciclo_lote: in_s3_path_georef es obligatorio (Lote %).', in_lote;
  END IF;
  IF in_s3_path_distancias IS NULL OR BTRIM(in_s3_path_distancias) = '' THEN
    RAISE EXCEPTION 'sp_geo_ciclo_lote: in_s3_path_distancias es obligatorio (Lote %).', in_lote;
  END IF;

  -- ----------------------------------------------------------
  -- 2) Localizar el Lote en la maquina de estados y resolver el limite de
  --    reintentos. El ambiente proviene del snapshot registrado al exportar.
  --    Si el Lote no existe, se aisla con RAISE INFO (no aborta el global).
  -- ----------------------------------------------------------
  SELECT estado, ambiente, max_reintentos, COALESCE(intentos, 0)
    INTO v_estado, v_ambiente, v_max_reints, v_intentos
  FROM bdm_datos.geo_lote_control
  WHERE lote = in_lote;

  IF v_estado IS NULL THEN
    RAISE INFO 'sp_geo_ciclo_lote: Lote % inexistente en geo_lote_control; ciclo omitido, sin cambios. Ejecucion global NO abortada.',
      in_lote;
    RETURN;
  END IF;

  -- 2.a) Un Lote ya 'fallido definitivo' no se reintenta automaticamente
  --      (Req 13.4): queda para intervencion manual. Se aisla y continua.
  IF v_estado = 'fallido definitivo' THEN
    RAISE INFO 'sp_geo_ciclo_lote: Lote % en "fallido definitivo"; requiere intervencion manual, no se reintenta automaticamente. Ejecucion global NO abortada.',
      in_lote;
    RETURN;
  END IF;

  -- 2.b) Resolver max_retries efectivo (Req 13.1, 13.2): preferir el valor
  --      vigente en geo_config para el ambiente del Lote; si no se puede
  --      resolver (parametro/ambiente ausente), usar el snapshot
  --      max_reintentos del Lote; en ultima instancia, un valor conservador.
  v_max_cfg := NULL;
  IF v_ambiente IS NOT NULL AND BTRIM(v_ambiente) <> '' THEN
    SELECT valor INTO v_max_cfg
    FROM bdm_datos.geo_config
    WHERE ambiente = v_ambiente AND parametro = 'max_retries';
  END IF;

  IF v_max_cfg IS NOT NULL AND REGEXP_COUNT(BTRIM(v_max_cfg), '^[0-9]+$') = 1 THEN
    v_max_reints := BTRIM(v_max_cfg)::SMALLINT;
  ELSIF v_max_reints IS NULL THEN
    -- Sin configuracion ni snapshot: respaldo conservador (0 reintentos extra).
    v_max_reints := 0;
  END IF;

  -- RAISE INFO en Redshift solo admite variables (no expresiones como +1).
  v_max_pasadas := v_max_reints + 1;

  -- ----------------------------------------------------------
  -- 3) Bucle de intentos acotado por max_retries (Req 13.1, 13.2, 13.3).
  --    Cada iteracion aplica la cadena idempotente completa; si la cadena
  --    tiene exito (Lote 'cargado' y sin marca de fallo), se sale con exito.
  --    Si falla, se incrementa 'intentos' y, mientras queden reintentos, se
  --    vuelve a intentar la MISMA cadena idempotente (Req 13.3). El backoff
  --    temporal NO se ejecuta aqui: lo aplica el orquestador externo entre
  --    reinvocaciones (Req 13.6); el bucle interno solo agota los reintentos
  --    disponibles registrando intentos/timestamps.
  --    Total de pasadas permitidas = 1 (inicial) + max_reints reintentos =
  --    max_reints + 1, de modo que el numero de REINTENTOS nunca supere
  --    max_retries (Req 13.1).
  -- ----------------------------------------------------------
  v_exito := FALSE;

  WHILE v_intentos < v_max_pasadas AND NOT v_exito LOOP
    v_intento_actual := v_intentos + 1;

    RAISE INFO 'sp_geo_ciclo_lote: Lote % - intento %/% de la cadena de carga+reenganche.',
      in_lote, v_intento_actual, v_max_pasadas;

    -- 3.1) Paso 1: cargar georreferenciacion (1:1). El SP es idempotente por
    --      Lote y, ante fallo local, marca el Lote 'fallido' sin excepcion.
    CALL bdm_datos.sp_geo_cargar_georreferenciacion(in_lote, in_s3_path_georef);

    -- Releer estado tras el paso: si quedo 'fallido', no se ejecuta el
    -- siguiente paso sobre un Lote fallido (deteccion por estado).
    SELECT estado INTO v_estado
    FROM bdm_datos.geo_lote_control
    WHERE lote = in_lote;

    IF v_estado = 'fallido' THEN
      RAISE INFO 'sp_geo_ciclo_lote: Lote % fallo en fase georreferenciacion (intento %); cadena detenida para este Lote.',
        in_lote, v_intento_actual;
    ELSE
      -- 3.2) Paso 2: cargar distancias (1:N, DELETE+INSERT atomico). Idempotente.
      CALL bdm_datos.sp_geo_cargar_distancias(in_lote, in_s3_path_distancias);

      SELECT estado INTO v_estado
      FROM bdm_datos.geo_lote_control
      WHERE lote = in_lote;

      IF v_estado = 'fallido' THEN
        RAISE INFO 'sp_geo_ciclo_lote: Lote % fallo en fase distancias (intento %); cadena detenida para este Lote.',
          in_lote, v_intento_actual;
      ELSE
        -- 3.3) Paso 3: reenganche condicional de la Regla 3. Idempotente; ante
        --      fallo local marca 'fallido' (fase reenganche_r3) sin excepcion.
        CALL bdm_datos.sp_geo_reenganchar_r3(in_lote);

        SELECT estado INTO v_estado
        FROM bdm_datos.geo_lote_control
        WHERE lote = in_lote;

        IF v_estado = 'fallido' THEN
          RAISE INFO 'sp_geo_ciclo_lote: Lote % fallo en fase reenganche_r3 (intento %); cadena detenida para este Lote.',
            in_lote, v_intento_actual;
        ELSE
          -- Cadena completa sin marca de fallo: exito del ciclo para el Lote.
          v_exito := TRUE;
        END IF;
      END IF;
    END IF;

    IF v_exito THEN
      -- 3.4) Exito: registrar intento efectivo y cierre limpio del ciclo. El
      --      estado 'cargado' lo fijan los SP encadenados; aqui se consolidan
      --      contadores y timestamp de trazabilidad (Req 7.3).
      UPDATE bdm_datos.geo_lote_control
      SET intentos            = v_intento_actual,
          fecha_actualizacion = GETDATE()
      WHERE lote = in_lote;

      RAISE INFO 'sp_geo_ciclo_lote: Lote % completado con exito en el intento %/%. Ciclo GEO cerrado (carga + reenganche R3).',
        in_lote, v_intento_actual, v_max_pasadas;
    ELSE
      -- 3.5) Fallo del intento: incrementar 'intentos' y registrar timestamp
      --      (el orquestador externo usa intentos + fecha_actualizacion para
      --      aplicar retry_backoff_seconds antes de la proxima reinvocacion,
      --      Req 13.6). fase_fallo y ultimo_error ya los dejo el SP que fallo.
      v_intentos := v_intento_actual;

      UPDATE bdm_datos.geo_lote_control
      SET intentos            = v_intentos,
          fecha_actualizacion = GETDATE()
      WHERE lote = in_lote;

      IF v_intentos < v_max_pasadas THEN
        -- Quedan reintentos automaticos: el Lote permanece 'fallido'
        -- (disponible para reintento). El bucle reintenta la cadena
        -- idempotente sin dormir (backoff delegado, Req 13.3, 13.6).
        RAISE INFO 'sp_geo_ciclo_lote: Lote % fallido en el intento %/%; disponible para reintento (idempotente). Backoff delegado al orquestador.',
          in_lote, v_intento_actual, v_max_pasadas;
      END IF;
    END IF;

  END LOOP;

  -- ----------------------------------------------------------
  -- 4) Agotamiento de reintentos (Req 13.4): si tras el bucle el Lote no
  --    tuvo exito y ya se consumieron todos los intentos permitidos, transita
  --    a 'fallido definitivo', conservando fase_fallo y ultimo_error para el
  --    diagnostico, disponible para intervencion manual. No se relanza
  --    automaticamente. El fallo es LOCAL al Lote (RAISE INFO): los demas
  --    Lotes y el pipeline continuan (Req 13.5).
  -- ----------------------------------------------------------
  IF NOT v_exito THEN
    UPDATE bdm_datos.geo_lote_control
    SET estado              = 'fallido definitivo',
        fecha_actualizacion = GETDATE()
    WHERE lote = in_lote;

    RAISE INFO 'sp_geo_ciclo_lote: Lote % agoto los % intento(s) permitido(s) sin exito -> "fallido definitivo" (disponible para intervencion manual). Los demas Lotes y el pipeline continuan; ejecucion global NO abortada.',
      in_lote, v_max_pasadas;
  END IF;

EXCEPTION WHEN OTHERS THEN
  -- Salvaguarda: un error inesperado del orquestador (no de los SP
  -- encadenados, que se aislan solos) no debe abortar el global. Se marca el
  -- Lote 'fallido' con la causa y se registra; el pipeline y los demas Lotes
  -- continuan (Req 13.5).
  UPDATE bdm_datos.geo_lote_control
  SET estado              = 'fallido',
      fase_fallo          = COALESCE(fase_fallo, 'ciclo'),
      ultimo_error        = LEFT('sp_geo_ciclo_lote error inesperado: ' || SQLERRM, 500),
      fecha_actualizacion = GETDATE()
  WHERE lote = in_lote;

  RAISE INFO 'sp_geo_ciclo_lote: Lote % con error inesperado del orquestador: %. Lote marcado "fallido"; ejecucion global NO abortada.',
    in_lote, SQLERRM;
END;
$$;
-- SLCOPRBA-1355: re-DPLY DEV post DROP SCHEMA strct #256
