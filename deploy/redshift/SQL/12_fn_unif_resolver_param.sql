-- ============================================================
-- 12_fn_unif_resolver_param.sql
-- Funcion helper de resolucion/normalizacion de parametros del
-- Framework_Batch para la coexistencia FULL/DELTA de la Unificacion.
-- (repo pgm / db_rcncr_btch_rdshft_pgm)
-- Cluster consumidor: reconocerbatch / dba_rncr_batch
-- Objeto permanente en bdm_datos. Idempotente (CREATE OR REPLACE).
-- Codificacion: UTF-8 sin BOM. Nunca GRANT ... TO PUBLIC.
-- Spec: unificacion-full-delta (Task 3.1)
-- Requirements: 1.1, 1.2, 6.1, 14.1, 14.2
-- ------------------------------------------------------------
-- Centraliza y normaliza la convencion de parametros del Framework_Batch
-- (in_nemotecnico=MODO, in_id_facturacion=LOTE, in_fecha_ejecucion=FECHA) para
-- que ni los orquestadores ni las reglas dupliquen el parseo:
--   MODO  : vacio/NULL -> 'FULL'; si no, UPPER(TRIM(...)). La validacion de
--           dominio (abortar si no es FULL/DELTA) la hace el orquestador maestro.
--   LOTE  : NULLIF(TRIM(...), '') tal cual; el orquestador valida presencia y
--           que sea entero.
--   FECHA : vacio/NULL -> TO_CHAR(CURRENT_DATE,'YYYY-MM-DD'); si no, TRIM(...).
-- STABLE: el resultado no depende del contenido de la base para una misma
-- entrada dentro de una sentencia (CURRENT_DATE es estable por sentencia).
-- ============================================================

CREATE OR REPLACE FUNCTION bdm_datos.unif_resolver_param(
    p_clave     VARCHAR,   -- 'MODO' | 'LOTE' | 'FECHA'
    p_valor_in  VARCHAR    -- valor crudo del parametro Framework_Batch
)
RETURNS VARCHAR
STABLE
AS $$
    SELECT CASE UPPER(TRIM($1))
        -- MODO: default FULL; validacion de dominio la hace el orquestador
        WHEN 'MODO' THEN
            CASE
                WHEN $2 IS NULL OR TRIM($2) = '' THEN 'FULL'
                ELSE UPPER(TRIM($2))
            END
        -- LOTE: se devuelve tal cual (trim); el orquestador valida presencia y que sea entero
        WHEN 'LOTE' THEN NULLIF(TRIM($2), '')
        -- FECHA: default CURRENT_DATE si vacio/NULL
        WHEN 'FECHA' THEN
            CASE
                WHEN $2 IS NULL OR TRIM($2) = '' THEN TO_CHAR(CURRENT_DATE, 'YYYY-MM-DD')
                ELSE TRIM($2)
            END
    END
$$ LANGUAGE sql;

-- SLCOPRBA-1355: re-DPLY DEV post DROP SCHEMA strct #256
