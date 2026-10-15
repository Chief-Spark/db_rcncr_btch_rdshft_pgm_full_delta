-- ============================================================
-- 14b_traza_mock_procedures.sql
-- Procedimientos de traza por etapa de la Unificacion MOCK
-- (repo pgm / db_rcncr_btch_rdshft_pgm)
-- Cluster consumidor: reconocerbatch / dba_rncr_batch
-- Objetos permanentes en bdm_datos. Codificacion: UTF-8 sin BOM.
-- Nunca GRANT ... TO PUBLIC.
-- Spec: unificacion-full-delta -- certificacion con datos mock
-- ------------------------------------------------------------
-- SLCOPRBA-1355: espejo de 14_traza_procedures.sql sobre
-- bdm_datos.unif_control_etapa_mock.
--
-- Observabilidad NO bloqueante: tanto el inicio como el fin envuelven su
-- INSERT/UPDATE en un bloque EXCEPTION WHEN OTHERS que se traga silenciosamente
-- cualquier error, de modo que un fallo de traza nunca aborta la corrida mock.
-- Los conteos son de monitoreo, no de control de flujo.
--
-- NONATOMIC: toda la cadena de CALL de la unificacion mock corre en modo
-- NONATOMIC consistente; mezclar modos rompe con
--   "P0001: created in one transaction mode cannot be invoked from another"
-- (leccion #13 del pipeline).
--
-- Rollback: Redshift NO soporta DROP PROCEDURE IF EXISTS (lecciones #12/#14).
-- Firmas exactas de este archivo:
--   bdm_datos.unif_traza_mock_inicio(BIGINT, INTEGER, VARCHAR)
--   bdm_datos.unif_traza_mock_fin(BIGINT, VARCHAR, VARCHAR, BIGINT, BIGINT, BIGINT, BIGINT, BIGINT)
-- ============================================================

CREATE SCHEMA IF NOT EXISTS bdm_datos;

-- ============================================================
-- bdm_datos.unif_traza_mock_inicio
-- Inserta la fila de una etapa mock en estado 'en proceso'.
--   p_corrida_id : corrida mock (FK logico a unif_control_mock)
--   p_lote       : Lote_Corrida externo
--   p_etapa      : regla1 | regla2 | regla2_escN | geo
--                  (NO existe 'regla3': fuera de alcance en mock)
-- NO bloqueante: cualquier fallo del INSERT se traga.
-- ============================================================
CREATE OR REPLACE PROCEDURE bdm_datos.unif_traza_mock_inicio(
    p_corrida_id BIGINT,
    p_lote       INTEGER,
    p_etapa      VARCHAR
)
NONATOMIC
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO bdm_datos.unif_control_etapa_mock (
        corrida_id, lote, etapa, estado, fecha_hora_inicio, usuario_bd
    )
    VALUES (
        p_corrida_id, p_lote, p_etapa, 'en proceso', GETDATE(), CURRENT_USER
    );
EXCEPTION
    WHEN OTHERS THEN
        -- Observabilidad no bloqueante: se traga el error de traza.
        NULL;
END;
$$;

-- ============================================================
-- bdm_datos.unif_traza_mock_fin
-- Cierra la etapa mock con su estado final y las Metricas_Corrida por etapa.
-- A diferencia de la via real (donde los conteos se pasan como literales 0),
-- aqui el orquestador mock SI calcula y pasa metricas reales por etapa: la
-- certificacion necesita poder afirmar cuantas unificaciones produjo cada
-- regla, no solo que la etapa termino.
--   p_geo_export / p_geo_cargados: solo se fijan en la etapa 'geo'; NULL en el
--   resto (mismo comportamiento que la traza real).
-- NO bloqueante: cualquier fallo del UPDATE se traga.
-- ============================================================
CREATE OR REPLACE PROCEDURE bdm_datos.unif_traza_mock_fin(
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
    UPDATE bdm_datos.unif_control_etapa_mock
       SET estado                    = p_estado,
           fecha_hora_fin            = GETDATE(),
           relaciones_entrada        = p_rel,
           personas_distintas        = p_pers,
           unificaciones_producidas  = p_unif,
           candidatos_geo_exportados = CASE WHEN p_etapa = 'geo' THEN p_geo_export   ELSE candidatos_geo_exportados END,
           candidatos_geo_cargados   = CASE WHEN p_etapa = 'geo' THEN p_geo_cargados ELSE candidatos_geo_cargados   END
     WHERE corrida_id = p_corrida_id
       AND etapa      = p_etapa;
EXCEPTION
    WHEN OTHERS THEN
        -- Observabilidad no bloqueante: se traga el error de traza.
        NULL;
END;
$$;
