-- ============================================================
-- 16b_sp_unificacion_mock_ciclo.sql
-- Orquestador maestro de la corrida de Unificacion MOCK FULL/DELTA:
--   bdm_datos.sp_unificacion_mock_ciclo -> resuelve params del Framework_Batch,
--   valida dominio, decide Bootstrap, abre control, coordina R1->R2->GEO con
--   traza, avanza Watermark y cierra la corrida.
-- (repo pgm / db_rcncr_btch_rdshft_pgm)
-- Cluster consumidor: reconocerbatch / dba_rncr_batch
-- Objeto permanente en bdm_datos. Idempotente (CREATE OR REPLACE).
-- Codificacion: UTF-8 sin BOM. Nunca GRANT ... TO PUBLIC.
-- Spec: unificacion-full-delta -- certificacion con datos mock
-- ------------------------------------------------------------
-- SLCOPRBA-1355: espejo de 16_sp_unificacion_ciclo.sql para la via MOCK.
-- Hasta ahora la via mock NO tenia orquestador: solo se podia invocar
-- sp_unificacion_mock_regla1/2/3 de forma suelta desde el script de malla, sin
-- Bootstrap, sin Watermark, sin TRUNCATE condicional, sin traza y sin GEO. Este
-- SP cierra esa brecha y es el punto de entrada de la bateria de certificacion.
--
-- DIFERENCIAS DELIBERADAS CON EL ORQUESTADOR REAL
-- 1. SIN Regla 3. R3 exige coordenadas (geo_atributos.latitud/longitud) y en la
--    via mock no hay enriquecimiento, de modo que nunca produciria filas.
--    Incluirla solo agregaria una etapa vacia a la evidencia.
-- 2. El FULL resetea TAMBIEN las tablas GEO mock. Decision de la certificacion:
--    "el FULL borra todo y hace un nuevo primer calculo de toda la data". En la
--    via real el FULL NO toca geo_atributos (perderia el enriquecimiento ya
--    obtenido); en mock no hay enriquecimiento que perder y el reseteo hace la
--    bateria repetible.
-- 3. Las Metricas_Corrida POR ETAPA se calculan de verdad. El orquestador real
--    las cierra con literales 0 ("marcadores" que la Task 4.3 nunca consolido),
--    lo que hace que unif_control_etapa no sirva como evidencia. Aqui se
--    reportan valores reales.
-- 4. NO se abren subfilas regla2_escN. En el orquestador real se abren las 6
--    ANTES de llamar a regla2 y se cierran todas DESPUES, por lo que todas
--    comparten el mismo intervalo y llevan conteos 0: no miden nada. Las
--    unificaciones tampoco son atribuibles por escenario desde la tabla destino
--    (unifica_atributos distingue regla, no escenario). La evidencia por
--    escenario se obtiene de la matriz de semillas y sus gates, no de la traza.
--
-- Convencion Framework_Batch (6 params VARCHAR, lecciones #7/#11):
--   in_nemotecnico=MODO, in_id_facturacion=LOTE, in_fecha_ejecucion=FECHA.
-- NONATOMIC en toda la cadena de CALL (leccion #13).
-- Rollback: DROP PROCEDURE nombre(<firma exacta>) SIN IF EXISTS (#12/#14).
--   sp_unificacion_mock_ciclo(VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR)
-- ============================================================

CREATE SCHEMA IF NOT EXISTS bdm_datos;

CREATE OR REPLACE PROCEDURE bdm_datos.sp_unificacion_mock_ciclo(
    in_solicitud        VARCHAR,   -- Framework_Batch (no usado)
    in_nit_suscriptor   VARCHAR,   -- Framework_Batch (no usado)
    in_path_archivo     VARCHAR,   -- Framework_Batch (no usado)
    in_nemotecnico      VARCHAR,   -- MODO  (FULL | DELTA | '')
    in_id_facturacion   VARCHAR,   -- LOTE  (Lote_Corrida externo)
    in_fecha_ejecucion  VARCHAR    -- FECHA (Fecha_Proceso)
)
NONATOMIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_modo          VARCHAR(10);
    v_lote_txt      VARCHAR;
    v_lote          INTEGER;
    v_fecha_txt     VARCHAR;
    v_fecha         DATE;

    v_wm_anterior   DATE;
    v_modo_efectivo VARCHAR(10);
    v_bootstrap     BOOLEAN := FALSE;

    v_corrida_id    BIGINT;

    v_wm_maximo     DATE;
    v_wm_nuevo      DATE;
    v_rel_entrada   BIGINT := 0;
    v_pers_distintas BIGINT := 0;
    v_total_unif    BIGINT := 0;

    -- Metricas por etapa (reales, no marcadores)
    v_unif_r1       BIGINT := 0;
    v_unif_r2       BIGINT := 0;
    v_geo_lote_ini  INTEGER := 0;
    v_geo_lote_fin  INTEGER := 0;
    v_geo_export    BIGINT := 0;
    v_geo_cargados  BIGINT := 0;

    v_etapa_actual  VARCHAR(20);
BEGIN
    -- (1) RESOLUCION DE PARAMETROS -------------------------------------------
    -- Se reutiliza el helper real: el parseo de MODO/LOTE/FECHA es identico y
    -- no tiene nada de especifico de la via real.
    v_modo      := bdm_datos.unif_resolver_param('MODO',  in_nemotecnico);
    v_lote_txt  := bdm_datos.unif_resolver_param('LOTE',  in_id_facturacion);
    v_fecha_txt := bdm_datos.unif_resolver_param('FECHA', in_fecha_ejecucion);

    -- (2) VALIDACION DEL LOTE ------------------------------------------------
    -- Abortar SIN tocar la Tabla_Destino_Mock si el lote esta ausente o no es
    -- entero: el aborto ocurre ANTES de abrir la corrida y ANTES del TRUNCATE.
    IF v_lote_txt IS NULL THEN
        RAISE EXCEPTION 'sp_unificacion_mock_ciclo: Lote_Corrida ausente (in_id_facturacion vacio/NULL); se aborta sin modificar la Tabla_Destino_Mock.';
    END IF;

    BEGIN
        v_lote := CAST(v_lote_txt AS INTEGER);
    EXCEPTION
        WHEN OTHERS THEN
            RAISE EXCEPTION 'sp_unificacion_mock_ciclo: Lote_Corrida no entero (valor recibido: "%"); se aborta sin modificar la Tabla_Destino_Mock.', v_lote_txt;
    END;

    -- (3) VALIDACION DEL MODO ------------------------------------------------
    IF v_modo NOT IN ('FULL', 'DELTA') THEN
        RAISE EXCEPTION 'sp_unificacion_mock_ciclo: Modo_Corrida no reconocido (valor recibido: "%"); se aborta sin modificar la Tabla_Destino_Mock. Valores validos: FULL | DELTA.', v_modo;
    END IF;

    v_fecha := CAST(v_fecha_txt AS DATE);

    -- (4) WATERMARK Y BOOTSTRAP ----------------------------------------------
    -- Watermark de partida = ultimo watermark_nuevo entre corridas MOCK
    -- 'completado'. Lectura sobre unif_control_mock, NO sobre unif_control: los
    -- watermarks de mock y real son independientes.
    SELECT MAX(watermark_nuevo)
      INTO v_wm_anterior
      FROM bdm_datos.unif_control_mock
     WHERE estado = 'completado';

    IF v_wm_anterior IS NULL THEN
        -- Sin Watermark previo -> Bootstrap: se fuerza FULL aunque se pida DELTA.
        v_modo_efectivo := 'FULL';
        v_bootstrap     := TRUE;
    ELSE
        v_modo_efectivo := v_modo;
        v_bootstrap     := FALSE;
    END IF;

    -- (5) APERTURA DE LA CORRIDA ---------------------------------------------
    v_corrida_id := NULL;
    CALL bdm_datos.unif_control_mock_abrir(
        v_modo_efectivo, v_lote, v_fecha, v_wm_anterior, v_bootstrap, v_corrida_id
    );

    -- (6) RESET CONDICIONAL AL MODO ------------------------------------------
    -- Solo FULL/Bootstrap resetea, y una sola vez al inicio. En DELTA no se
    -- borra nada: la persistencia por escenario es UPSERT por la
    -- Clave_Unificacion, de modo que reprocesar una ventana no des-unifica ni
    -- duplica.
    IF v_modo_efectivo = 'FULL' THEN
        TRUNCATE TABLE bdm_datos.unificacion_direccion_mock;
        -- SLCOPRBA-1355 (M5): ver la nota del ciclo real. El FULL borra las
        -- direcciones generadas AQUI, antes de preparar el insumo.
        TRUNCATE TABLE bdm_datos.rpu_generada_mock;
        TRUNCATE TABLE bdm_datos.direccion_fisica_generada_mock;
        -- Reseteo del ciclo GEO mock (ver nota 2 de la cabecera).
        TRUNCATE TABLE bdm_datos.geo_atributos_mock;
        TRUNCATE TABLE bdm_datos.geo_lote_control_mock;
    END IF;

    -- (7) ENCADENADO R1 -> R2 -> GEO CON TRAZA -------------------------------
    -- Bloque protegido: el fallo de cualquier etapa se captura para cerrar la
    -- etapa en curso 'fallido', marcar la corrida 'fallido' sin avanzar el
    -- Watermark, y re-lanzar el error al Framework_Batch.
    -- Los orquestadores de regla mock conservan su firma propia
    -- (p_modo VARCHAR, p_lote INTEGER, p_watermark DATE): NO se homologan a los
    -- 6 VARCHAR del Framework_Batch porque cambiar una firma en Redshift crea
    -- una SOBRECARGA en vez de reemplazar, y el DROP del rollback (que va con
    -- firma exacta) dejaria el procedimiento viejo vivo.
    BEGIN
    -- ---- Etapa R1 ----------------------------------------------------------
    v_etapa_actual := 'regla1';
    CALL bdm_datos.unif_traza_mock_inicio(v_corrida_id, v_lote, 'regla1');
    CALL bdm_datos.sp_unificacion_mock_regla1(v_modo_efectivo, v_lote, v_wm_anterior);

    -- Unificaciones atribuibles a R1 en ESTA corrida: filas con
    -- unifica_atributos = 1 creadas (lote) o re-tocadas (lote_actualizacion)
    -- por este lote.
    SELECT COUNT(*)
      INTO v_unif_r1
      FROM bdm_datos.unificacion_direccion_mock
     WHERE unifica_atributos = 1
       AND (lote = v_lote OR lote_actualizacion = v_lote);

    CALL bdm_datos.unif_traza_mock_fin(v_corrida_id, 'regla1', 'completado',
                                       0, 0, v_unif_r1, NULL, NULL);

    -- ---- Etapa R2 ----------------------------------------------------------
    v_etapa_actual := 'regla2';
    CALL bdm_datos.unif_traza_mock_inicio(v_corrida_id, v_lote, 'regla2');
    CALL bdm_datos.sp_unificacion_mock_regla2(v_modo_efectivo, v_lote, v_wm_anterior);

    SELECT COUNT(*)
      INTO v_unif_r2
      FROM bdm_datos.unificacion_direccion_mock
     WHERE unifica_atributos = 2
       AND (lote = v_lote OR lote_actualizacion = v_lote);

    CALL bdm_datos.unif_traza_mock_fin(v_corrida_id, 'regla2', 'completado',
                                       0, 0, v_unif_r2, NULL, NULL);

    -- ---- Universo delta mock para el Exportador_GEO ------------------------
    -- Mismo criterio POR PERSONA que usa el insumo de R1/R2: se reutiliza el
    -- driver bdm_tempo.stg_mock_unif_delta_personas que materializo el ultimo
    -- preparar_insumo (el de R2). Asi el universo del GEO y el de las reglas
    -- coinciden. Patron DROP-CREATE para no arrastrar residuo de una corrida
    -- previa; en FULL el predicado colapsa a TRUE.
    DROP TABLE IF EXISTS bdm_tempo.stg_mock_unif_delta_ubic;
    CREATE TABLE bdm_tempo.stg_mock_unif_delta_ubic AS
    SELECT DISTINCT rpu.cod_dw_ubic
    FROM   bdm_tempo.v_mock_relacion_persona_ubicacion rpu
    WHERE  v_modo_efectivo = 'FULL'
       OR  EXISTS ( SELECT 1
                      FROM bdm_tempo.stg_mock_unif_delta_personas d
                     WHERE d.id_buro_persona = rpu.id_buro_persona );

    -- ---- Etapa GEO ---------------------------------------------------------
    -- Solo generacion de candidatos. Se espera que el UNLOAD falle (rol IAM no
    -- asociado al cluster) y que el fallo NO bloquee: el SP marca el Lote
    -- 'fallido' con RAISE INFO y retorna normalmente.
    v_etapa_actual := 'geo';
    CALL bdm_datos.unif_traza_mock_inicio(v_corrida_id, v_lote, 'geo');

    SELECT COALESCE(MAX(lote), 0) INTO v_geo_lote_ini
      FROM bdm_datos.geo_lote_control_mock;

    CALL bdm_datos.sp_geo_exportar_insumo_mock(
        in_solicitud, in_nit_suscriptor, in_path_archivo,
        v_modo_efectivo, v_lote::VARCHAR, v_wm_anterior::VARCHAR
    );

    SELECT COALESCE(MAX(lote), 0) INTO v_geo_lote_fin
      FROM bdm_datos.geo_lote_control_mock;

    -- Conteos GEO reales: si la corrida creo un Lote nuevo se leen de el; si no
    -- hubo candidatos no se creo Lote y los conteos quedan en 0.
    IF v_geo_lote_fin > v_geo_lote_ini THEN
        SELECT COALESCE(conteo_esperado, 0), COALESCE(conteo_cargado, 0)
          INTO v_geo_export, v_geo_cargados
          FROM bdm_datos.geo_lote_control_mock
         WHERE lote = v_geo_lote_fin;
    ELSE
        v_geo_export   := 0;
        v_geo_cargados := 0;
    END IF;

    CALL bdm_datos.unif_traza_mock_fin(v_corrida_id, 'geo', 'completado',
                                       0, 0, 0, v_geo_export, v_geo_cargados);

    -- (8) WATERMARK NUEVO ----------------------------------------------------
    -- Nivel dia: MAX(fecha) entre las relaciones con fecha NO NULA de la
    -- VENTANA (no del universo expandido por persona): la ventana es la que
    -- define que cambio. El universo expandido solo agrega filas mas antiguas,
    -- que no pueden mover el maximo.
    --   FULL/Bootstrap: se SIEMBRA con el maximo observado (puede ser NULL).
    --   DELTA: AVANZA solo si hubo fecha no nula; si no, CONSERVA el anterior.
    --   GREATEST protege de un eventual retroceso.
    SELECT MAX(rpu.fecha_relacion_persona_ubicaci)
      INTO v_wm_maximo
      FROM bdm_tempo.v_mock_relacion_persona_ubicacion rpu
     WHERE rpu.fecha_relacion_persona_ubicaci IS NOT NULL
       AND ( v_modo_efectivo = 'FULL'
             OR rpu.fecha_relacion_persona_ubicaci >= v_wm_anterior );

    IF v_modo_efectivo = 'FULL' THEN
        v_wm_nuevo := v_wm_maximo;
    ELSE
        IF v_wm_maximo IS NULL THEN
            v_wm_nuevo := v_wm_anterior;
        ELSE
            v_wm_nuevo := GREATEST(v_wm_anterior, v_wm_maximo);
        END IF;
    END IF;

    -- (9) CONTEOS GLOBALES ---------------------------------------------------
    -- Mismo universo que consumieron las reglas: por persona + filtro de estado
    -- del legado. En mock ind_unificacion es un campo REAL (no una constante),
    -- de modo que este filtro si descarta las relaciones ya unificadas.
    SELECT COUNT(*),
           COUNT(DISTINCT rpu.id_buro_persona)
      INTO v_rel_entrada, v_pers_distintas
      FROM bdm_tempo.v_mock_relacion_persona_ubicacion rpu
     WHERE rpu.ind_unificacion IS NULL
       AND COALESCE(rpu.bloqueado, 0) = 0
       AND ( v_modo_efectivo = 'FULL'
             OR EXISTS ( SELECT 1
                           FROM bdm_tempo.stg_mock_unif_delta_personas d
                          WHERE d.id_buro_persona = rpu.id_buro_persona ) );

    -- Parejas de la Clave_Unificacion vivas en la Tabla_Destino_Mock que esta
    -- corrida creo o re-toco. Con el UPSERT fiel al legado 'lote' es inmutable,
    -- por lo que hay que mirar tambien lote_actualizacion.
    SELECT COUNT(DISTINCT (ud.cod_dw_persona_ubic || '-' || ud.cod_dw_direccion_unificada))
      INTO v_total_unif
      FROM bdm_datos.unificacion_direccion_mock ud
     WHERE ud.lote = v_lote
        OR ud.lote_actualizacion = v_lote;

    -- (10) CIERRE 'completado' -----------------------------------------------
    CALL bdm_datos.unif_control_mock_cerrar(
        v_corrida_id, 'completado', v_wm_nuevo,
        v_rel_entrada, v_pers_distintas, v_total_unif
    );

    EXCEPTION
        WHEN OTHERS THEN
            -- Cierra la etapa en curso 'fallido' (traza no bloqueante), marca la
            -- corrida 'fallido' con watermark_nuevo NULL (conserva el anterior:
            -- el Watermark NO avanza) y re-lanza el error original.
            IF v_etapa_actual IS NOT NULL THEN
                CALL bdm_datos.unif_traza_mock_fin(
                    v_corrida_id, v_etapa_actual, 'fallido', 0, 0, 0, NULL, NULL
                );
            END IF;

            CALL bdm_datos.unif_control_mock_cerrar(
                v_corrida_id, 'fallido', NULL, 0, 0, 0
            );

            RAISE;
    END;
END;
$$;
