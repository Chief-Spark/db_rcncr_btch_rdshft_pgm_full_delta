-- ============================================================
-- 12b_fn_fw_resolver_param.sql
-- SLCOPRBA-1398: normaliza lo que el Framework Batch MANDA DE VERDAD a lo
-- que los orquestadores esperan.
-- (repo pgm / db_rcncr_btch_rdshft_pgm)
-- Cluster consumidor: reconocerbatch / dba_rncr_batch
-- Objeto permanente en bdm_datos. Idempotente (CREATE OR REPLACE).
-- Codificacion: UTF-8 sin BOM. Nunca GRANT ... TO PUBLIC.
-- ------------------------------------------------------------
-- POR QUE ESTA FUNCION ES NUEVA Y NO UN CASO MAS EN unif_resolver_param:
--   aquel helper esta certificado y lo comparten la via real y la mock. Aqui
--   se anade comportamiento, no se cambia ninguno de los suyos. Un orquestador
--   que quiera la semantica vieja la sigue teniendo intacta.
--
-- LO QUE EL FRAMEWORK MANDA, MEDIDO Y NO SUPUESTO.
--   El Builder arma la llamada en tf_fw_dynbtch,
--   step_function_definition_builder.py:93:
--
--     CALL <sp>(execution_id, nit, folder_path, client_id,
--               billing_id, year_month)
--
--   de modo que los tres slots que nos importan traen:
--     slot 4 (in_nemotecnico)     el MNEMOTECNICO, p.ej. 'reconocermockval'
--     slot 5 (in_id_facturacion)  el id de facturacion, numerico
--     slot 6 (in_fecha_ejecucion) el ANIO-MES del nombre del .val, 'YYMM'
--
--   Comprobado en DEV con tres ejecuciones reales:
--     'invalid input syntax for type date: "0826"' y '"2610"'
--     'value too long for type character varying(10)' al asignar
--     'RECONOCERMOCKVAL' a una variable de 10.
--
-- Y NOSOTROS DISCREPAMOS CON NOSOTROS MISMOS, que es lo que esta funcion
-- cierra: diez SP leen el slot 4 como MODO y
-- sp_geo_ciclo_lote_wrapper.sql:57-62 lo lee como LOTE entero.
--
-- CONTRATO DE SALIDA: SIEMPRE CADENA, NUNCA EXCEPCION.
--   Devuelve cadena vacia cuando no puede derivar un valor, y es quien llama
--   el que decide si eso aborta o cae a un default. Una funcion que lanzara
--   excepcion volveria a atar el fallo al sitio equivocado -- justo el defecto
--   que tienen hoy los tres sp_unificacion_regla*, que castean en el DECLARE.
--
-- STABLE y no VOLATILE: para una misma entrada el resultado no depende del
-- contenido de la base. CURRENT_DATE es estable por sentencia.
-- ============================================================

CREATE OR REPLACE FUNCTION bdm_datos.fw_resolver_param(
    p_clave     VARCHAR,   -- 'MODO' | 'LOTE' | 'FECHA'
    p_valor_in  VARCHAR    -- valor crudo del slot del Framework Batch
)
RETURNS VARCHAR
STABLE
AS $$
    SELECT CASE UPPER(TRIM($1))

        -- ----------------------------------------------------
        -- MODO. El slot 4 trae el mnemotecnico, nunca FULL ni DELTA.
        --
        -- Se decide por lo que el nombre CONTIENE y no por igualdad, para que
        -- valga con cualquier mnemotecnico que siga la convencion del
        -- Framework: todos terminan en 'val' porque esa es la extension del
        -- archivo disparador (FILE_NAME_PATTERN, constants.py:8).
        --
        -- DELTA se mira ANTES que FULL a proposito: un nombre que llevara los
        -- dos debe entrar por el mas restrictivo.
        -- ----------------------------------------------------
        WHEN 'MODO' THEN
            CASE
                WHEN $2 IS NULL OR TRIM($2) = ''                 THEN 'FULL'
                WHEN POSITION('DELTA' IN UPPER(TRIM($2))) > 0    THEN 'DELTA'
                WHEN POSITION('FULL'  IN UPPER(TRIM($2))) > 0    THEN 'FULL'
                -- Un mnemotecnico sin modo en el nombre ('reconocermockval')
                -- es legitimo y significa FULL, el default del proyecto.
                WHEN RIGHT(UPPER(TRIM($2)), 3) = 'VAL'           THEN 'FULL'
                -- Desconocido: cadena vacia. NO se cae a FULL en silencio,
                -- porque eso esconderia un cambio de contrato.
                ELSE ''
            END

        -- ----------------------------------------------------
        -- LOTE. El slot 5 ya viene numerico, pero no se da por hecho.
        -- ----------------------------------------------------
        WHEN 'LOTE' THEN
            CASE
                WHEN $2 IS NULL                     THEN ''
                WHEN TRIM($2) ~ '^[0-9]+$'          THEN TRIM($2)
                ELSE ''
            END

        -- ----------------------------------------------------
        -- FECHA. El slot 6 trae 'YYMM': cuatro digitos del nombre del .val,
        -- no una fecha. Se convierte al PRIMER DIA de ese mes.
        --
        -- Si el mes no esta entre 1 y 12 se devuelve cadena vacia en vez de
        -- inventar un dia. Es lo que pasa con '0826', que es MMYY mal puesto
        -- y fue el primer error que vimos en DEV.
        --
        -- Una fecha ISO se acepta tal cual: asi la funcion sirve igual cuando
        -- la llamada no viene del Framework (el banco, una prueba a mano).
        -- ----------------------------------------------------
        WHEN 'FECHA' THEN
            CASE
                WHEN $2 IS NULL OR TRIM($2) = ''                       THEN ''
                WHEN TRIM($2) ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'         THEN TRIM($2)
                WHEN TRIM($2) ~ '^[0-9]{4}$'
                     AND CAST(SUBSTRING(TRIM($2), 3, 2) AS INTEGER) BETWEEN 1 AND 12
                     THEN CAST(2000 + CAST(SUBSTRING(TRIM($2), 1, 2) AS INTEGER) AS VARCHAR)
                          || '-' || SUBSTRING(TRIM($2), 3, 2) || '-01'
                ELSE ''
            END
    END
$$ LANGUAGE sql;
