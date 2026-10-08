-- ============================================================
-- 14_traza_procedures.sql
-- Procedimientos de traza por etapa de la Unificacion (repo pgm / db_rcncr_btch_rdshft_pgm)
-- Cluster consumidor: reconocerbatch / dba_rncr_batch
-- Objetos permanentes en bdm_datos. Codificacion: UTF-8 sin BOM.
-- Nunca GRANT ... TO PUBLIC.
-- Spec: unificacion-full-delta (Task 3.3)
-- Requirements: 13.4, 13.5, 13.6, 13.7, 13.8, 13.9
-- ------------------------------------------------------------
-- Observabilidad NO bloqueante (Req 13.8): tanto unif_traza_inicio como
-- unif_traza_fin envuelven su INSERT/UPDATE en un bloque EXCEPTION WHEN OTHERS
-- que se traga silenciosamente cualquier error (NULL, no re-lanza), de modo que
-- un fallo de traza (contencion, error transitorio) nunca aborta la unificacion.
-- Los conteos son de monitoreo, no de control de flujo.
--
-- NONATOMIC: toda la cadena de CALL de la unificacion corre en modo NONATOMIC
-- consistente; mezclar modos rompe con
-- "P0001: created in one transaction mode cannot be invoked from another".
-- Por eso ambos procedimientos se declaran LANGUAGE plpgsql NONATOMIC.
--
-- Rollback (PROCEDIMIENTOS): Redshift NO soporta DROP PROCEDURE IF EXISTS
-- (lecciones #12/#14). El rollback usa DROP PROCEDURE nombre(<firma exacta>);
-- sin IF EXISTS. Ver rev-sql/14_rollback_traza_procedures.sql.
-- Firmas exactas de este archivo:
--   bdm_datos.unif_traza_inicio(BIGINT, INTEGER, VARCHAR)
--   bdm_datos.unif_traza_fin(BIGINT, VARCHAR, VARCHAR, BIGINT, BIGINT, BIGINT, BIGINT, BIGINT)
-- ============================================================

CREATE SCHEMA IF NOT EXISTS bdm_datos;

-- ============================================================
-- bdm_datos.unif_traza_inicio (Task 3.3) -- Req 13.4, 13.8, 13.9
-- Inserta la fila de una etapa en estado 'en proceso' con su fecha_hora_inicio.
-- Parametros:
--   p_corrida_id : corrida a la que pertenece la etapa (FK logico a unif_control)
--   p_lote       : Lote_Corrida externo (Req 13.1)
--   p_etapa      : regla1 | regla2 | regla2_escN | geo | regla3 (Req 13.2, 13.3)
-- Las metricas y los conteos GEO se completan al cierre (unif_traza_fin).
-- NO bloqueante: cualquier fallo del INSERT se traga (Req 13.8).
-- ============================================================
CREATE OR REPLACE PROCEDURE bdm_datos.unif_traza_inicio(
    p_corrida_id BIGINT,
    p_lote       INTEGER,
    p_etapa      VARCHAR
)
NONATOMIC
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO bdm_datos.unif_control_etapa (
        corrida_id,
        lote,
        etapa,
        estado,
        fecha_hora_inicio,
        usuario_bd
    )
    VALUES (
        p_corrida_id,
        p_lote,
        p_etapa,
        'en proceso',
        GETDATE(),
        CURRENT_USER
    );
EXCEPTION
    WHEN OTHERS THEN
        -- Observabilidad no bloqueante: se traga el error de traza (Req 13.8)
        NULL;
END;
$$;

-- ============================================================
-- bdm_datos.unif_traza_fin (Task 3.3) -- Req 13.5, 13.6, 13.7, 13.8, 13.9
-- Actualiza la fila de la etapa con el estado final, su fecha_hora_fin y las
-- Metricas_Corrida por etapa: relaciones de entrada, personas distintas y
-- unificaciones producidas (Req 13.6). Cuando la etapa es 'geo' fija tambien
-- los conteos GEO (candidatos exportados/cargados, Req 13.7); para las demas
-- etapas estos llegan como NULL.
-- Parametros:
--   p_corrida_id  : corrida a la que pertenece la etapa
--   p_etapa       : etapa a cerrar (debe coincidir con la abierta en inicio)
--   p_estado      : completado | fallido (Req 13.5)
--   p_rel         : relaciones_entrada (Req 13.6)
--   p_pers        : personas_distintas (distinct id_buro_persona)
--   p_unif        : unificaciones_producidas
--   p_geo_export  : candidatos_geo_exportados (solo etapa 'geo', Req 13.7)
--   p_geo_cargados: candidatos_geo_cargados  (solo etapa 'geo', Req 13.7)
-- NO bloqueante: cualquier fallo del UPDATE se traga (Req 13.8).
-- ============================================================
CREATE OR REPLACE PROCEDURE bdm_datos.unif_traza_fin(
    p_corrida_id   BIGINT,
    p_etapa        VARCHAR,
    p_estado       VARCHAR,
    p_rel          BIGINT,
    p_pers         BIGINT,
    p_unif         BIGINT,
    p_geo_export   BIGINT,
    p_geo_cargados BIGINT
)
NONATOMIC
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE bdm_datos.unif_control_etapa
       SET estado                    = p_estado,
           fecha_hora_fin            = GETDATE(),
           relaciones_entrada        = p_rel,
           personas_distintas        = p_pers,
           unificaciones_producidas  = p_unif,
           -- Conteos GEO solo para la etapa 'geo' (Req 13.7); NULL en el resto
           candidatos_geo_exportados = CASE WHEN p_etapa = 'geo' THEN p_geo_export   ELSE candidatos_geo_exportados END,
           candidatos_geo_cargados   = CASE WHEN p_etapa = 'geo' THEN p_geo_cargados ELSE candidatos_geo_cargados   END
     WHERE corrida_id = p_corrida_id
       AND etapa      = p_etapa;
EXCEPTION
    WHEN OTHERS THEN
        -- Observabilidad no bloqueante: se traga el error de traza (Req 13.8)
        NULL;
END;
$$;

-- SLCOPRBA-1355: re-DPLY DEV post DROP SCHEMA strct #256
