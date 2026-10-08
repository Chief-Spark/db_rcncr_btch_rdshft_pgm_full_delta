-- ============================================================
-- 16_sp_unificacion_ciclo.sql
-- Orquestador maestro de corrida de la Unificacion FULL/DELTA:
--   bdm_datos.sp_unificacion_ciclo -> resuelve params del Framework_Batch,
--   valida dominio, decide Bootstrap, abre control, coordina R1->R2->GEO->R3
--   con traza, avanza Watermark y cierra la corrida.
-- (repo pgm / db_rcncr_btch_rdshft_pgm)
-- Cluster consumidor: reconocerbatch / dba_rncr_batch
-- Objeto permanente en bdm_datos. Idempotente (CREATE OR REPLACE).
-- Codificacion: UTF-8 sin BOM. Nunca GRANT ... TO PUBLIC.
-- Spec: unificacion-full-delta (Task 4.1 / 4.2 / 4.3)
-- ------------------------------------------------------------
-- ALCANCE DE ESTE ARCHIVO EN LA OLA ACTUAL (Task 4.1):
--   * Resolucion de v_modo / v_lote / v_fecha via unif_resolver_param.
--   * Validacion de dominio: abortar SIN tocar la Tabla_Destino y registrar
--     error si v_lote ausente/no entero (Req 6.4) o si v_modo no es FULL/DELTA
--     (Req 1.3).
--   * Lectura del ultimo Watermark 'completado' de unif_control y decision de
--     Bootstrap: si no existe Watermark, forzar v_modo_efectivo = FULL y marcar
--     bootstrap = TRUE aunque se haya solicitado DELTA (Req 2.1, 2.3, 2.4).
--   * Apertura de la fila de corrida en unif_control (estado 'en proceso'),
--     recuperando el corrida_id generado por IDENTITY (Req 4.2, 1.5, 14.1).
--
-- ALCANCE AÑADIDO EN LA OLA ACTUAL (Task 4.2):
--   * TRUNCATE condicional al modo efectivo (solo FULL/Bootstrap, una vez al
--     inicio) sobre bdm_datos.unificacion_direccion (Req 5.3, 10.2).
--   * Encadenado R1 -> R2 -> GEO -> R3 propagando (v_modo_efectivo, v_lote,
--     v_fecha, v_wm_anterior) y envolviendo cada etapa con unif_traza_inicio /
--     unif_traza_fin, incluida una subfila por escenario de R2 (regla2_escN,
--     Req 13.3) (Req 1.4, 13.2, 13.3, 13.4, 13.5).
--   * Materializacion de bdm_tempo.stg_unif_delta_ubic tras R2 (patron
--     DROP-CREATE) con las cod_dw_ubic distintas del universo delta (Req 1.4).
--
-- ALCANCE AÑADIDO EN LA OLA ACTUAL (Task 4.3):
--   * El encadenado (Task 4.2) y el avance de Watermark + cierre 'completado'
--     (happy path) quedan envueltos en un BEGIN ... EXCEPTION WHEN OTHERS ... END
--     interno (habilitado por NONATOMIC): asi el fallo de cualquier etapa se
--     captura sin abortar la sesion entera.
--   * Calculo del watermark_nuevo = MAX(fecha_relacion_persona_ubicaci) a nivel
--     dia entre las relaciones con fecha NO NULA del universo procesado (mismo
--     predicado de ventana que stg_unif_delta_ubic): en FULL/Bootstrap SIEMBRA
--     (Req 2.2), en DELTA AVANZA solo si hubo fecha no nula, si no CONSERVA el
--     anterior (Req 3.4, 3.5).
--   * Conteos globales (relaciones_entrada, personas_distintas via DISTINCT
--     id_buro_persona, total_unificaciones por parejas de la Clave_Unificacion
--     del lote) y CALL unif_control_cerrar(..., 'completado', ...) (Req 4.3, 14.4).
--   * Bloque EXCEPTION WHEN OTHERS: cierra la etapa en curso 'fallido' (traza no
--     bloqueante, Req 13.8), marca la corrida 'fallido' con watermark_nuevo=NULL
--     (conserva el anterior; el Watermark NO avanza, Req 4.4, 16.1) y RE-lanza el
--     error para propagarlo al Framework_Batch.
-- ------------------------------------------------------------
-- Convencion de parametros del Framework_Batch (6 params VARCHAR obligatorios,
-- lecciones #7/#11): in_nemotecnico=MODO, in_id_facturacion=LOTE,
-- in_fecha_ejecucion=FECHA. Los tres primeros (in_solicitud, in_nit_suscriptor,
-- in_path_archivo) no se usan en la Unificacion pero forman parte de la firma
-- exacta que exige el Framework_Batch.
--
-- NONATOMIC: toda la cadena de CALL de la Unificacion corre en modo NONATOMIC
-- consistente; mezclar modos rompe con
--   "P0001: created in one transaction mode cannot be invoked from another".
--
-- Rollback (PROCEDIMIENTO, no funcion): DROP PROCEDURE nombre(<firma exacta>)
-- SIN IF EXISTS (Redshift no soporta DROP PROCEDURE IF EXISTS) -- lecciones #12/#14.
-- Firma exacta (6 VARCHAR): sp_unificacion_ciclo(VARCHAR, VARCHAR, VARCHAR,
-- VARCHAR, VARCHAR, VARCHAR). Ver rev-sql/16_rollback_sp_unificacion_ciclo.sql.
-- ============================================================

CREATE SCHEMA IF NOT EXISTS bdm_datos;

-- SLCOPRBA-1355: re-DPLY DEV (strct no debe DROP SCHEMA CASCADE).
CREATE OR REPLACE PROCEDURE bdm_datos.sp_unificacion_ciclo(
    in_solicitud        VARCHAR,   -- Framework_Batch (no usado en Unificacion)
    in_nit_suscriptor   VARCHAR,   -- Framework_Batch (no usado en Unificacion)
    in_path_archivo     VARCHAR,   -- Framework_Batch (no usado en Unificacion)
    in_nemotecnico      VARCHAR,   -- MODO  (FULL | DELTA | '')
    in_id_facturacion   VARCHAR,   -- LOTE  (Lote_Corrida externo, Req 6)
    in_fecha_ejecucion  VARCHAR    -- FECHA (Fecha_Proceso, Req 14.1/14.2)
)
NONATOMIC
LANGUAGE plpgsql
AS $$
DECLARE
    -- Parametros resueltos/normalizados (Req 1.1, 1.2, 6.1, 14.1, 14.2)
    v_modo          VARCHAR(10);   -- modo solicitado normalizado (FULL|DELTA|otro)
    v_lote_txt      VARCHAR;       -- lote crudo normalizado (NULL si vacio)
    v_lote          INTEGER;       -- Lote_Corrida entero validado (Req 6.4)
    v_fecha_txt     VARCHAR;       -- fecha resuelta 'YYYY-MM-DD'
    v_fecha         DATE;          -- Fecha_Proceso (Req 14.1, 14.2)

    -- Decision de modo efectivo / Bootstrap (Req 2.1, 2.3, 2.4)
    v_wm_anterior   DATE;          -- ultimo Watermark 'completado' (NULL => Bootstrap)
    v_modo_efectivo VARCHAR(10);   -- modo realmente aplicado (Req 1.5)
    v_bootstrap     BOOLEAN := FALSE; -- TRUE si se forzo Bootstrap FULL (Req 2.3)

    -- Corrida (Task 4.2/4.3 la propagan a traza y cierre)
    v_corrida_id    BIGINT;        -- generado por IDENTITY en unif_control_abrir

    -- Avance del Watermark y conteos globales -- Task 4.3 (Req 2.2, 3.4, 3.5, 14.4)
    v_wm_maximo     DATE;          -- MAX(fecha) no nula del universo procesado (NULL si no hubo)
    v_wm_nuevo      DATE;          -- Watermark resultante a persistir en el cierre 'completado'
    v_rel_entrada   BIGINT := 0;   -- relaciones del universo procesado (Metricas_Corrida, Req 14.4)
    v_pers_distintas BIGINT := 0;  -- distinct id_buro_persona del universo procesado
    v_total_unif    BIGINT := 0;   -- parejas de la Clave_Unificacion producidas para el lote

    -- Etapa en curso: permite cerrar 'fallido' exactamente la etapa que abortó
    -- dentro del bloque EXCEPTION del encadenado (Task 4.3, Req 13.8).
    v_etapa_actual  VARCHAR(20);
BEGIN
    -- ========================================================
    -- (1) RESOLUCION DE PARAMETROS (Req 1.1, 1.2, 6.1, 14.1, 14.2) -- Task 4.1
    -- Se centraliza el parseo en la funcion helper unif_resolver_param:
    --   MODO  : vacio/NULL -> 'FULL'; si no UPPER(TRIM(...)).
    --   LOTE  : NULLIF(TRIM(...), '') tal cual (aqui se valida presencia/entero).
    --   FECHA : vacio/NULL -> TO_CHAR(CURRENT_DATE,'YYYY-MM-DD'); si no TRIM(...).
    -- ========================================================
    v_modo      := bdm_datos.unif_resolver_param('MODO',  in_nemotecnico);
    v_lote_txt  := bdm_datos.unif_resolver_param('LOTE',  in_id_facturacion);
    v_fecha_txt := bdm_datos.unif_resolver_param('FECHA', in_fecha_ejecucion);

    -- ========================================================
    -- (2) VALIDACION DEL LOTE (Req 6.4) -- Task 4.1
    -- Abortar SIN tocar la Tabla_Destino si el Lote_Corrida esta ausente o no es
    -- un entero. El aborto ocurre ANTES de abrir la corrida y ANTES del TRUNCATE
    -- (Task 4.2), de modo que ni la Tabla_Destino_Real ni la Tabla_Destino_Mock
    -- se modifican (Property 9). RAISE EXCEPTION deja constancia del error con el
    -- valor recibido.
    -- ========================================================
    IF v_lote_txt IS NULL THEN
        RAISE EXCEPTION 'sp_unificacion_ciclo: Lote_Corrida ausente (in_id_facturacion vacio/NULL); se aborta sin modificar la Tabla_Destino (Req 6.4).';
    END IF;

    -- Validar que el lote sea entero. Si el TRIM no es un entero valido, el CAST
    -- lanza error; se captura para re-lanzar un mensaje explicito con el valor.
    BEGIN
        v_lote := CAST(v_lote_txt AS INTEGER);
    EXCEPTION
        WHEN OTHERS THEN
            RAISE EXCEPTION 'sp_unificacion_ciclo: Lote_Corrida no entero (valor recibido: "%"); se aborta sin modificar la Tabla_Destino (Req 6.4).', v_lote_txt;
    END;

    -- ========================================================
    -- (3) VALIDACION DEL MODO (Req 1.3) -- Task 4.1
    -- Abortar SIN tocar la Tabla_Destino si el modo solicitado no es FULL ni
    -- DELTA, identificando el valor no reconocido. (El default FULL para
    -- vacio/NULL ya lo aplico unif_resolver_param, por lo que aqui v_modo nunca
    -- es vacio salvo por un valor explicito no reconocido.)
    -- ========================================================
    IF v_modo NOT IN ('FULL', 'DELTA') THEN
        RAISE EXCEPTION 'sp_unificacion_ciclo: Modo_Corrida no reconocido (valor recibido: "%"); se aborta sin modificar la Tabla_Destino (Req 1.3). Valores validos: FULL | DELTA.', v_modo;
    END IF;

    -- Fecha_Proceso ya resuelta (default CURRENT_DATE cuando no se provee, Req 14.2).
    v_fecha := CAST(v_fecha_txt AS DATE);

    -- ========================================================
    -- (4) LECTURA DEL WATERMARK Y DECISION DE BOOTSTRAP -- Task 4.1
    -- (Req 2.1, 2.3, 2.4, 4.5)
    -- El Watermark de partida es el ultimo watermark_nuevo entre las corridas en
    -- estado 'completado' (Req 4.5): las corridas 'fallido' conservan
    -- watermark_nuevo NULL y por tanto MAX(...) no las toma como avance.
    -- ========================================================
    SELECT MAX(watermark_nuevo)
      INTO v_wm_anterior
      FROM bdm_datos.unif_control
     WHERE estado = 'completado';

    IF v_wm_anterior IS NULL THEN
        -- Bootstrap: no hay Watermark previo -> forzar FULL con independencia del
        -- modo solicitado (Req 2.1) y marcar que se ejecuto como Bootstrap FULL
        -- aunque se haya pedido DELTA (Req 2.3, 2.4).
        v_modo_efectivo := 'FULL';
        v_bootstrap     := TRUE;
    ELSE
        -- Ya existe Watermark: se respeta el modo solicitado (Req 1.1, 1.5).
        v_modo_efectivo := v_modo;
        v_bootstrap     := FALSE;
    END IF;

    -- ========================================================
    -- (5) APERTURA DE LA CORRIDA EN unif_control -- Task 4.1
    -- (Req 4.2, 1.5, 2.3, 14.1)
    -- Inserta la fila 'en proceso' con el modo EFECTIVO, el lote, la
    -- Fecha_Proceso, el watermark de partida y la bandera de Bootstrap. El
    -- corrida_id lo genera la columna IDENTITY(1,1) y unif_control_abrir lo
    -- devuelve por el parametro INOUT p_corrida_id para propagarlo a la traza
    -- por etapa (Task 4.2) y al cierre (Task 4.3).
    -- ========================================================
    v_corrida_id := NULL;
    CALL bdm_datos.unif_control_abrir(
        v_modo_efectivo,   -- p_modo (modo aplicado, Req 1.5)
        v_lote,            -- p_lote (Lote_Corrida)
        v_fecha,           -- p_fecha_proceso (Req 14.1)
        v_wm_anterior,     -- p_watermark_anterior (NULL en Bootstrap)
        v_bootstrap,       -- p_bootstrap (Req 2.3)
        v_corrida_id       -- INOUT: recibe el corrida_id generado por IDENTITY
    );

    -- ========================================================
    -- (6) TRUNCATE CONDICIONAL AL MODO EFECTIVO -- Task 4.2 (Req 5.3, 10.2)
    -- Solo el camino FULL/Bootstrap resetea la Tabla_Destino, y lo hace UNA sola
    -- vez al inicio de la corrida (antes de encadenar R1->R2->GEO->R3). En DELTA
    -- NO se trunca: la persistencia por escenario es UPSERT por la
    -- Clave_Unificacion (Task 6.1), de modo que reprocesar una ventana no
    -- des-unifica ni duplica. El TRUNCATE ya no vive en la malla del repo dt
    -- (Task 10.1 lo retira de run_unificacion_ejecucion_secuencial.sql): pasa a
    -- ser responsabilidad exclusiva del orquestador, condicional a FULL.
    -- ========================================================
    IF v_modo_efectivo = 'FULL' THEN
        TRUNCATE TABLE bdm_datos.unificacion_direccion;
    END IF;

    -- ========================================================
    -- (7) ENCADENADO R1 -> R2 -> GEO -> R3 CON TRAZA POR ETAPA -- Task 4.2
    -- (Req 1.4, 13.2, 13.3, 13.4, 13.5)
    -- Cada etapa se envuelve con unif_traza_inicio (fila 'en proceso') y
    -- unif_traza_fin (estado final + Metricas_Corrida). La traza es NO bloqueante
    -- (Req 13.8): sus procedimientos se tragan cualquier error internamente, por
    -- lo que envolver una etapa nunca aborta la unificacion por si mismo.
    --
    -- Modo unico propagado (Req 1.4): las 3 reglas y el GEO reciben el MISMO
    -- (v_modo_efectivo, v_lote, v_fecha, v_wm_anterior) resuelto una sola vez
    -- arriba; ningun SP re-parsea los parametros del Framework_Batch.
    --
    -- NOTA sobre la firma de los orquestadores de regla/GEO (contrato FINALIZADO
    -- en las Tasks 5.1/6.1 al regenerar los SP real y mock):
    --   sp_unificacion_regla1/2/3 y sp_geo_exportar_insumo conservan la firma
    --   estandar de 6 params VARCHAR del Framework_Batch. El modo/lote/watermark
    --   se re-emiten en los slots 4/5/6:
    --     in_nemotecnico     = v_modo_efectivo  (Modo_Corrida efectivo)
    --     in_id_facturacion  = v_lote           (Lote_Corrida)
    --     in_fecha_ejecucion = v_wm_anterior    (Watermark: frontera inferior
    --                                            inclusiva de la ventana DELTA)
    --   Los reglas derivan de ahi (p_modo, p_lote, p_watermark) y los propagan a
    --   preparar_insumo(p_modo, p_watermark) y a cada escenario(p_modo, p_lote)
    --   sin re-parsear. La Fecha_Proceso (v_fecha) NO la consumen las reglas
    --   (los escenarios sellan fecha_unificacion con CURRENT_DATE); vive en
    --   unif_control para el historico. El Watermark viaja por el slot 6 porque
    --   es el valor que ACOTA la ventana DELTA (mismo v_wm_anterior con el que se
    --   materializa stg_unif_delta_ubic mas abajo), garantizando que la ventana
    --   de preparar_insumo y el universo delta del GEO coincidan (Req 3.1-3.3).
    --
    -- Las Metricas_Corrida por etapa (relaciones, personas distintas,
    -- unificaciones, conteos GEO) se calculan/consolidan en la Task 4.3 al cerrar
    -- la corrida; en esta ola se cierran las etapas con conteos en 0 (marcadores)
    -- para dejar la estructura de traza completa. Se pasan 0 (no NULL) para
    -- respetar el tipo BIGINT de la firma de unif_traza_fin.

    -- ========================================================
    -- BLOQUE PROTEGIDO (Task 4.3): encadenado (Task 4.2) + avance de Watermark y
    -- cierre 'completado' (Task 4.3 happy path) envueltos en un BEGIN ... EXCEPTION
    -- WHEN OTHERS. NONATOMIC habilita el manejo de excepciones en PLpgSQL, de modo
    -- que el fallo de CUALQUIER etapa (R1/R2/GEO/R3) o del cierre se captura para:
    --   * marcar la corrida 'fallido' SIN avanzar el Watermark (conserva
    --     v_wm_anterior via unif_control_cerrar con watermark_nuevo=NULL, Req 4.4, 16.1),
    --   * cerrar la etapa en curso (v_etapa_actual) como 'fallido' (Req 13.6),
    --   * y RE-lanzar el error para propagarlo al Framework_Batch (Req 13.8: la
    --     traza nunca aborta por si misma; el que aborta es la etapa fallida).
    -- v_etapa_actual se actualiza ANTES de cada etapa para que el EXCEPTION sepa
    -- exactamente cual cerrar como 'fallido'.
    -- ========================================================
    BEGIN
    -- ---- Etapa R1: regla1 ---------------------------------------------------
    v_etapa_actual := 'regla1';
    CALL bdm_datos.unif_traza_inicio(v_corrida_id, v_lote, 'regla1');
    CALL bdm_datos.sp_unificacion_regla1(
        in_solicitud, in_nit_suscriptor, in_path_archivo,
        v_modo_efectivo, v_lote::VARCHAR, v_wm_anterior::VARCHAR
    );
    CALL bdm_datos.unif_traza_fin(v_corrida_id, 'regla1', 'completado', 0, 0, 0, NULL, NULL);

    -- ---- Etapa R2: regla2 (+ subfila por escenario regla2_escN, Req 13.3) ----
    -- El orquestador R2 encadena internamente sus escenarios (esc1..esc6 +
    -- motor de nuevas direcciones). Se abre/cierra una fila 'regla2' global y una
    -- subfila 'regla2_escN' por escenario para la granularidad de traza que exige
    -- el Req 13.3. La subtraza por escenario es un marcador de granularidad en
    -- esta ola; sus metricas por escenario las consolidara la Task 4.3.
    v_etapa_actual := 'regla2';
    CALL bdm_datos.unif_traza_inicio(v_corrida_id, v_lote, 'regla2');
    CALL bdm_datos.unif_traza_inicio(v_corrida_id, v_lote, 'regla2_esc1');
    CALL bdm_datos.unif_traza_inicio(v_corrida_id, v_lote, 'regla2_esc2');
    CALL bdm_datos.unif_traza_inicio(v_corrida_id, v_lote, 'regla2_esc3');
    CALL bdm_datos.unif_traza_inicio(v_corrida_id, v_lote, 'regla2_esc4');
    CALL bdm_datos.unif_traza_inicio(v_corrida_id, v_lote, 'regla2_esc5');
    CALL bdm_datos.unif_traza_inicio(v_corrida_id, v_lote, 'regla2_esc6');
    CALL bdm_datos.sp_unificacion_regla2(
        in_solicitud, in_nit_suscriptor, in_path_archivo,
        v_modo_efectivo, v_lote::VARCHAR, v_wm_anterior::VARCHAR
    );
    CALL bdm_datos.unif_traza_fin(v_corrida_id, 'regla2_esc1', 'completado', 0, 0, 0, NULL, NULL);
    CALL bdm_datos.unif_traza_fin(v_corrida_id, 'regla2_esc2', 'completado', 0, 0, 0, NULL, NULL);
    CALL bdm_datos.unif_traza_fin(v_corrida_id, 'regla2_esc3', 'completado', 0, 0, 0, NULL, NULL);
    CALL bdm_datos.unif_traza_fin(v_corrida_id, 'regla2_esc4', 'completado', 0, 0, 0, NULL, NULL);
    CALL bdm_datos.unif_traza_fin(v_corrida_id, 'regla2_esc5', 'completado', 0, 0, 0, NULL, NULL);
    CALL bdm_datos.unif_traza_fin(v_corrida_id, 'regla2_esc6', 'completado', 0, 0, 0, NULL, NULL);
    CALL bdm_datos.unif_traza_fin(v_corrida_id, 'regla2', 'completado', 0, 0, 0, NULL, NULL);

    -- ---- Materializacion del universo delta tras R2 -------------------------
    -- (Req 1.4; design "Materializacion del universo delta")
    -- Tabla temporal (patron DROP-CREATE) con las cod_dw_ubic DISTINTAS del
    -- universo del delta de la corrida. Es la fuente que el Exportador_GEO usa
    -- para acotar candidatos "sin coordenadas" en DELTA (Task 8.1). Se materializa
    -- SIEMPRE (para no dejar residuo de una corrida previa) pero el filtro de
    -- ventana solo acota en DELTA: en FULL/Bootstrap el predicado colapsa a TRUE y
    -- la tabla contiene todo el universo (el GEO en FULL hace barrido completo y
    -- no la usa). El watermark de acotacion es v_wm_anterior (frontera inferior
    -- inclusiva por dia) mas los nulos (Req 3.1, 3.2).
    -- Fuente: bdm_tempo.v_xpm_relacion_persona_ubicacion (vista EDF / datashare),
    -- alineada a R1/R2/R3 y a sp_ordenamiento_ciclo. No usar la tabla base
    -- bdm_datos.relacion_persona_ubicacion (no existe en el consumidor DEV).
    DROP TABLE IF EXISTS bdm_tempo.stg_unif_delta_ubic;
    CREATE TABLE bdm_tempo.stg_unif_delta_ubic AS
    SELECT DISTINCT rpu.cod_dw_ubic
    FROM   bdm_tempo.v_xpm_relacion_persona_ubicacion rpu
    WHERE  v_modo_efectivo = 'FULL'
       OR  rpu.fecha_relacion_persona_ubicaci >= v_wm_anterior
       OR  rpu.fecha_relacion_persona_ubicaci IS NULL;

    -- ---- Etapa GEO: geo ------------------------------------------------------
    -- Exportador_GEO alineado al modo (Task 8.1): en DELTA intersecta candidatos
    -- "sin coordenadas" con stg_unif_delta_ubic; en FULL barrido completo. Los
    -- conteos GEO (exportados/cargados) se consolidan en la Task 4.3.
    v_etapa_actual := 'geo';
    CALL bdm_datos.unif_traza_inicio(v_corrida_id, v_lote, 'geo');
    CALL bdm_datos.sp_geo_exportar_insumo(
        in_solicitud, in_nit_suscriptor, in_path_archivo,
        v_modo_efectivo, v_lote::VARCHAR, v_wm_anterior::VARCHAR
    );
    CALL bdm_datos.unif_traza_fin(v_corrida_id, 'geo', 'completado', 0, 0, 0, 0, 0);

    -- ---- Etapa R3: regla3 ----------------------------------------------------
    v_etapa_actual := 'regla3';
    CALL bdm_datos.unif_traza_inicio(v_corrida_id, v_lote, 'regla3');
    CALL bdm_datos.sp_unificacion_regla3(
        in_solicitud, in_nit_suscriptor, in_path_archivo,
        v_modo_efectivo, v_lote::VARCHAR, v_wm_anterior::VARCHAR
    );
    CALL bdm_datos.unif_traza_fin(v_corrida_id, 'regla3', 'completado', 0, 0, 0, NULL, NULL);

    -- ========================================================
    -- (8) CALCULO DEL WATERMARK NUEVO -- Task 4.3 (Req 2.2, 3.4, 3.5)
    -- El Watermark es a nivel dia: MAX(fecha_relacion_persona_ubicaci) entre las
    -- relaciones con FECHA NO NULA del universo procesado. El universo procesado
    -- se acota con el MISMO predicado de ventana que uso la materializacion tras
    -- R2 (seccion 7, stg_unif_delta_ubic): en FULL/Bootstrap el predicado colapsa
    -- a TRUE (universo completo) y en DELTA acota por v_wm_anterior (frontera
    -- inferior inclusiva por dia) mas los nulos. Las filas con fecha NULL no
    -- entran en el MAX (no aportan avance), pero SI cuentan en las Metricas_Corrida
    -- de entrada porque forman parte del universo procesado.
    --
    --   * Bootstrap/FULL: se SIEMBRA el Watermark con v_wm_maximo (Req 2.2). Si el
    --     universo no tuviera ninguna fecha no nula (v_wm_maximo NULL) se siembra
    --     NULL: no hay frontera que fijar todavia y el siguiente Bootstrap/FULL
    --     volveria a sembrar.
    --   * DELTA: se AVANZA solo si hubo al menos una fecha no nula (Req 3.4); si el
    --     delta no trajo ninguna fecha no nula (v_wm_maximo NULL) se CONSERVA el
    --     Watermark anterior (Req 3.5) para no retroceder ni perder la frontera.
    --     Como la frontera es inclusiva, GREATEST protege ademas de un eventual
    --     maximo por debajo del anterior (no puede retroceder el Watermark).
    -- ========================================================
    SELECT MAX(rpu.fecha_relacion_persona_ubicaci)
      INTO v_wm_maximo
      FROM bdm_tempo.v_xpm_relacion_persona_ubicacion rpu
     WHERE rpu.fecha_relacion_persona_ubicaci IS NOT NULL
       AND ( v_modo_efectivo = 'FULL'
             OR rpu.fecha_relacion_persona_ubicaci >= v_wm_anterior );

    IF v_modo_efectivo = 'FULL' THEN
        -- Bootstrap/FULL: sembrar con el maximo observado (puede ser NULL).
        v_wm_nuevo := v_wm_maximo;
    ELSE
        -- DELTA: avanzar solo si hubo fecha no nula; si no, conservar el anterior.
        IF v_wm_maximo IS NULL THEN
            v_wm_nuevo := v_wm_anterior;                    -- Req 3.5 (sin avance)
        ELSE
            v_wm_nuevo := GREATEST(v_wm_anterior, v_wm_maximo); -- Req 3.4 (no retrocede)
        END IF;
    END IF;

    -- ========================================================
    -- (9) CONTEOS GLOBALES DE LA CORRIDA -- Task 4.3 (Req 14.4)
    -- Metricas_Corrida globales que persiste unif_control_cerrar:
    --   * relaciones_entrada  : relaciones del universo procesado (mismo predicado
    --                           de ventana que el Watermark; incluye fecha NULL en
    --                           DELTA por ser parte del delta, Req 3.2).
    --   * personas_distintas  : DISTINCT id_buro_persona de ese universo.
    --   * total_unificaciones : parejas de la Clave_Unificacion producidas para el
    --                           lote en la Tabla_Destino (cod_dw_persona_ubic,
    --                           cod_dw_direccion_unificada), acotadas por v_lote.
    -- ========================================================
    SELECT COUNT(*),
           COUNT(DISTINCT rpu.id_buro_persona)
      INTO v_rel_entrada, v_pers_distintas
      FROM bdm_tempo.v_xpm_relacion_persona_ubicacion rpu
     WHERE v_modo_efectivo = 'FULL'
        OR rpu.fecha_relacion_persona_ubicaci >= v_wm_anterior
        OR rpu.fecha_relacion_persona_ubicaci IS NULL;

    SELECT COUNT(DISTINCT (ud.cod_dw_persona_ubic || '-' || ud.cod_dw_direccion_unificada))
      INTO v_total_unif
      FROM bdm_datos.unificacion_direccion ud
     WHERE ud.lote = v_lote;

    -- ========================================================
    -- (10) CIERRE 'completado' DE LA CORRIDA -- Task 4.3 (Req 4.3, 14.4)
    -- Fija watermark_nuevo (solo se persiste en 'completado', ver
    -- unif_control_cerrar) y las Metricas_Corrida globales. Firma exacta:
    -- unif_control_cerrar(BIGINT, VARCHAR, DATE, BIGINT, BIGINT, BIGINT).
    -- ========================================================
    CALL bdm_datos.unif_control_cerrar(
        v_corrida_id,      -- p_corrida_id
        'completado',      -- p_estado (Req 4.3)
        v_wm_nuevo,        -- p_watermark_nuevo (sembrado/avanzado/conservado)
        v_rel_entrada,     -- p_relaciones_entrada
        v_pers_distintas,  -- p_personas_distintas (distinct id_buro_persona)
        v_total_unif       -- p_total_unificaciones
    );

    EXCEPTION
        WHEN OTHERS THEN
            -- ================================================
            -- MANEJO DE ERROR DE LA CORRIDA -- Task 4.3 (Req 4.4, 16.1, 13.8)
            -- Se llega aqui si CUALQUIER etapa (R1/R2/GEO/R3) o el bloque de
            -- Watermark/cierre lanzo un error. Acciones:
            --   1. Cerrar la etapa en curso (v_etapa_actual) como 'fallido' con
            --      conteos en 0 (marcadores); unif_traza_fin es NO bloqueante
            --      (Req 13.8), no puede volver a abortar aqui.
            --   2. Marcar la corrida 'fallido' via unif_control_cerrar con
            --      watermark_nuevo = NULL: el procedimiento NO persiste el
            --      watermark en 'fallido', de modo que se CONSERVA el
            --      watermark_anterior y el Watermark NO avanza (Req 4.4, 16.1).
            --   3. RE-lanzar el error original para propagarlo al Framework_Batch;
            --      la corrida queda registrada como 'fallido' y una reejecucion
            --      DELTA reprocesa la misma ventana de forma idempotente (Req 16).
            -- ================================================
            IF v_etapa_actual IS NOT NULL THEN
                CALL bdm_datos.unif_traza_fin(
                    v_corrida_id, v_etapa_actual, 'fallido',
                    0, 0, 0, NULL, NULL
                );
            END IF;

            CALL bdm_datos.unif_control_cerrar(
                v_corrida_id,   -- p_corrida_id
                'fallido',      -- p_estado (Req 4.4)
                NULL,           -- p_watermark_nuevo NULL => conserva el anterior (Req 4.4, 16.1)
                0,              -- p_relaciones_entrada (marcador; la corrida fallo)
                0,              -- p_personas_distintas
                0               -- p_total_unificaciones
            );

            RAISE;  -- propaga el error original (Req 13.8: aborta la etapa, no la traza)
    END;
END;
$$;

