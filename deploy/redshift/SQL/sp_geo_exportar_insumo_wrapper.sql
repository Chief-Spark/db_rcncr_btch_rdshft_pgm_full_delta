-- ============================================================
-- sp_geo_exportar_insumo_wrapper  (Reconocer / Enriquecimiento GEO - Regla 3)
-- Wrapper Framework Batch (task 10.1) del Exportador_GEO.
--
-- Expone la firma estandar de 6 parametros VARCHAR que el Framework Batch
-- invoca (via CALL/run_*) y delega en el helper interno
--   bdm_datos.sp_geo_exportar_insumo (que tambien migro a la firma de 6
--   parametros del Framework_Batch; ver seccion "Alineacion FULL/DELTA").
--
-- Objeto en bdm_stage (schema de entrada del Framework Batch); idempotente
-- (CREATE OR REPLACE PROCEDURE). NONATOMIC consistente con la cadena de CALL
-- (el helper hace UNLOAD, que no admite transaccion implicita; mezclar modos
-- produce P0001). UTF-8 sin BOM. Nunca GRANT ... TO PUBLIC.
--
-- Mapeo de parametros (Req 8.1, 8.2, 8.3):
--   El Exportador_GEO se dispara al final de la malla sincrona de Unificacion
--   (tras la Regla 2). No recibe Lote ni ruta S3: SELECCIONA los candidatos
--   por cuenta propia y AUTODETECTA el ambiente (cuenta AWS / current_database).
--   Por eso ninguno de los 6 parametros genericos del Framework Batch se usa
--   para seleccionar candidatos; el wrapper llama al helper con Modo_Full en el
--   slot 4 (barrido completo) y deja que el helper autodetecte el ambiente.
--     in_solicitud       -> no usado
--     in_nit_suscriptor  -> no usado
--     in_path_archivo    -> no usado (la ruta de salida se resuelve de geo_config)
--     in_nemotecnico     -> no usado
--     in_id_facturacion  -> no usado
--     in_fecha_ejecucion -> no usado (la fecha del nombre de archivo la calcula el helper)
--
-- Alineacion FULL/DELTA (spec unificacion-full-delta, Task 8.1):
--   El helper bdm_datos.sp_geo_exportar_insumo migro a la firma de 6 parametros
--   del Framework_Batch (in_nemotecnico=Modo_Corrida). Este wrapper de entrada
--   independiente (malla GEO standalone que NO pasa por sp_unificacion_ciclo)
--   delega en el helper con Modo_Full explicito en el slot 4, forzando el
--   barrido completo y la autodeteccion de ambiente que este wrapper ya asumia.
--   El orquestador sp_unificacion_ciclo invoca al helper directamente re-emitiendo
--   el modo real de la corrida, sin pasar por este wrapper.
--
-- Ref: .kiro/specs/geo-enriquecimiento-regla3/design.md
--      (Contrato del Framework Batch (6 parametros) / Exportador_GEO)
--      Requisitos: 8.1, 8.2, 8.3
-- ============================================================

CREATE OR REPLACE PROCEDURE bdm_stage.sp_geo_exportar_insumo(
    in_solicitud       VARCHAR,
    in_nit_suscriptor  VARCHAR,
    in_path_archivo    VARCHAR,
    in_nemotecnico     VARCHAR,
    in_id_facturacion  VARCHAR,
    in_fecha_ejecucion VARCHAR
)
NONATOMIC
LANGUAGE plpgsql
AS $$
BEGIN

  -- Barrido completo (Modo_Full en el slot 4) + autodeteccion de ambiente en el
  -- helper. Los slots 1-3, 5 y 6 no los usa el Exportador_GEO.
  CALL bdm_datos.sp_geo_exportar_insumo('', '', '', 'FULL', '', '');

EXCEPTION WHEN OTHERS THEN
  RAISE EXCEPTION 'sp_geo_exportar_insumo_wrapper failed: %', SQLERRM;
END;
$$;
-- SLCOPRBA-1355: re-DPLY DEV post DROP SCHEMA strct #256
