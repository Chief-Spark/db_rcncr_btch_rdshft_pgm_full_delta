-- ============================================================
-- sp_mock_ciclo.sql
-- SLCOPRBA-1398: TRADUCTOR entre el Framework Batch y los tres ciclos mock.
-- (repo pgm / db_rcncr_btch_rdshft_pgm)
-- UTF-8 sin BOM. Sin acentos a proposito.
--
-- POR QUE EXISTE, Y NO ES UN CAPRICHO: EL CONTRATO DE LOS SEIS PARAMETROS SE
-- ENTENDIO DISTINTO EN LOS DOS LADOS.
--   El Framework arma la llamada asi (tf_fw_dynbtch, Lambda Builder,
--   step_function_definition_builder.py:93):
--
--     CALL <sp>(execution_id, nit, folder_path, client_id, billing_id, year_month)
--
--   de modo que lo que llega de verdad es:
--
--     slot 4 (in_nemotecnico)     = el MNEMOTECNICO, p.ej. 'reconocermockval'
--     slot 5 (in_id_facturacion)  = el id de facturacion, numerico
--     slot 6 (in_fecha_ejecucion) = el ANIO-MES del nombre del .val, 'YYMM'
--
--   y nuestros orquestadores leen esos mismos slots como MODO, LOTE y FECHA.
--   Comprobado en DEV con dos ejecuciones reales:
--     'invalid input syntax for type date: "0826"'  -> el slot 6 no es fecha
--     'value too long for type character varying(10)' al asignar
--     'RECONOCERMOCKVAL' a v_modo VARCHAR(64)       -> el slot 4 no es modo
--
-- ESTE SP NO TIENE LOGICA DE NEGOCIO. Normaliza los tres valores y llama a los
-- ciclos que ya existen, sin tocarlos.
--
-- NO SIEMBRA NI RESETEA. Corre sobre los datos mock que ya dejo el job dt. Un
-- reset aqui borraria la unica evidencia de QA que hay en el cluster.
--
-- EL MISMO PATRON SIRVE PARA LA VIA REAL, cambiando a que ciclos llama: los
-- cuatro orquestadores reales tienen el mismo v_modo VARCHAR(64), y los tres
-- sp_unificacion_regla{1,2,3} castean la fecha en el DECLARE -- antes de
-- BEGIN, donde no hay IF que valga.
--
-- Leccion #11: la firma es la del Framework Batch, seis VARCHAR en ese orden.
-- Leccion #13: NONATOMIC en toda la cadena de CALL.
-- ============================================================

CREATE OR REPLACE PROCEDURE bdm_datos.sp_mock_ciclo(
    in_solicitud       VARCHAR,   -- Framework: execution_id   (no se usa)
    in_nit_suscriptor  VARCHAR,   -- Framework: nit            (no se usa)
    in_path_archivo    VARCHAR,   -- Framework: folder_path    (no se usa)
    in_nemotecnico     VARCHAR,   -- Framework: client_id   -> se traduce a MODO
    in_id_facturacion  VARCHAR,   -- Framework: billing_id  -> se traduce a LOTE
    in_fecha_ejecucion VARCHAR    -- Framework: year_month  -> se traduce a FECHA
)
NONATOMIC
LANGUAGE plpgsql
AS $$
DECLARE
    -- VARCHAR(64) y no (10): aqui entra el mnemotecnico crudo, que es largo.
    -- Estrechar esta variable es exactamente el defecto que este SP evita.
    v_entrada   VARCHAR(64);
    v_modo      VARCHAR(64);
    v_lote      INTEGER;
    v_lote_txt  VARCHAR(32);
    v_fecha_txt VARCHAR(32);
    v_anio      INTEGER;
    v_mes       INTEGER;
BEGIN

    -- ------------------------------------------------------------
    -- (1) MODO. El slot 4 trae el mnemotecnico, nunca FULL ni DELTA.
    --
    -- Se decide por lo que el nombre CONTIENE y no por igualdad, para que
    -- valga con cualquier mnemotecnico que siga la convencion: todos terminan
    -- en 'val' porque esa es la extension del archivo disparador.
    --
    -- El orden importa: DELTA se mira ANTES que FULL. Un mnemotecnico que
    -- llevara los dos nombres debe entrar por el mas restrictivo.
    -- ------------------------------------------------------------
    v_entrada := UPPER(BTRIM(COALESCE(in_nemotecnico, '')));

    IF POSITION('DELTA' IN v_entrada) > 0 THEN
        v_modo := 'DELTA';
    ELSIF POSITION('FULL' IN v_entrada) > 0 THEN
        v_modo := 'FULL';
    ELSIF v_entrada = '' THEN
        -- Igual que unif_resolver_param: vacio significa FULL.
        v_modo := 'FULL';
    ELSIF RIGHT(v_entrada, 3) = 'VAL' THEN
        -- Un mnemotecnico sin modo en el nombre (p.ej. 'reconocermockval').
        -- Es legitimo y significa FULL, que es el default del proyecto.
        v_modo := 'FULL';
    ELSE
        -- NO se cae a FULL en silencio: un valor que no reconocemos es una
        -- senal de que el contrato cambio, y hay que verlo en el log.
        RAISE EXCEPTION 'sp_mock_ciclo: no se puede derivar el MODO del slot 4 (valor recibido: "%"). Se espera un mnemotecnico terminado en val, o FULL/DELTA.', v_entrada;
    END IF;

    -- ------------------------------------------------------------
    -- (2) LOTE. El slot 5 ya viene numerico, pero no se da por hecho: si no
    -- castea, se deriva del control en vez de abortar la corrida.
    -- ------------------------------------------------------------
    BEGIN
        v_lote := CAST(NULLIF(BTRIM(COALESCE(in_id_facturacion, '')), '') AS INTEGER);
    EXCEPTION
        WHEN OTHERS THEN
            v_lote := NULL;
    END;

    IF v_lote IS NULL THEN
        SELECT COALESCE(MAX(lote), 0) + 1 INTO v_lote
          FROM bdm_datos.unif_control_mock;
    END IF;

    v_lote_txt := CAST(v_lote AS VARCHAR);

    -- ------------------------------------------------------------
    -- (3) FECHA. El slot 6 trae 'YYMM', cuatro digitos sacados del nombre del
    -- .val -- no una fecha. Se convierte al PRIMER DIA de ese mes.
    --
    -- Si el mes no es valido (p.ej. '0826', que es MMYY mal puesto) se manda
    -- CADENA VACIA y el ciclo aplica su propio default, CURRENT_DATE. Mejor
    -- un default documentado que inventar un dia.
    -- ------------------------------------------------------------
    v_fecha_txt := BTRIM(COALESCE(in_fecha_ejecucion, ''));

    IF v_fecha_txt ~ '^[0-9]{4}$' THEN
        v_anio := 2000 + CAST(SUBSTRING(v_fecha_txt, 1, 2) AS INTEGER);
        v_mes  := CAST(SUBSTRING(v_fecha_txt, 3, 2) AS INTEGER);

        IF v_mes BETWEEN 1 AND 12 THEN
            v_fecha_txt := CAST(v_anio AS VARCHAR)
                           || '-' || LPAD(CAST(v_mes AS VARCHAR), 2, '0')
                           || '-01';
        ELSE
            v_fecha_txt := '';
        END IF;
    ELSIF v_fecha_txt !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN
        -- Ni YYMM ni una fecha ISO: no se adivina.
        v_fecha_txt := '';
    END IF;

    RAISE INFO 'sp_mock_ciclo: modo=%, lote=%, fecha=%', v_modo, v_lote_txt, v_fecha_txt;

    -- ------------------------------------------------------------
    -- (4) Los tres ciclos, en su orden obligatorio.
    --
    -- Novedades va DESPUES de Ordenamiento porque su etapa 1 filtra por orden
    -- de prioridad no nulo (Novedad.sql:7593). Al reves saldria vacio por un
    -- efecto de secuencia y no por un defecto.
    --
    -- Los tres primeros parametros van vacios a proposito: no se usan en
    -- ninguno de los ciclos y forman parte de la firma (leccion #11).
    -- ------------------------------------------------------------
    CALL bdm_datos.sp_unificacion_mock_ciclo('', '', '', v_modo, v_lote_txt, v_fecha_txt);
    CALL bdm_datos.sp_ordenamiento_ejecucion_mock('', '', '', v_modo, v_lote_txt, v_fecha_txt);
    CALL bdm_datos.sp_novedades_mock_ciclo('', '', '', v_modo, v_lote_txt, v_fecha_txt);

END;
$$;
