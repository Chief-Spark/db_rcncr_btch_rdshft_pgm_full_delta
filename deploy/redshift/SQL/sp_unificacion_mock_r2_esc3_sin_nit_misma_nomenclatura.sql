-- R2 Esc3 — misma nomenclatura sin NIT
-- MODO MOCK — lee v_mock_*/bdm_stage; NO usa edf_views ni v_xpm_*
-- Escenario: Excluye tipo identificación 3 (NIT)
-- Fuente: bdm_stage → bdm_tempo.v_mock_* | Salida: bdm_datos.unificacion_direccion_mock | MODO MOCK
-- Prerequisito: sp_unificacion_mock_r2_esc1_complemento_vacio_esc2_substring_complemento
-- Generado: tools/gen_unificacion_mock_sps.py (espejo mock)

CREATE OR REPLACE PROCEDURE bdm_datos.sp_unificacion_mock_r2_esc3_sin_nit_misma_nomenclatura(
    p_modo VARCHAR,   -- FULL | DELTA (modo efectivo de la corrida)
    p_lote INTEGER    -- Lote_Corrida externo (reemplaza el 1 hardcodeado)
)
NONATOMIC
LANGUAGE plpgsql
AS $$
BEGIN
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_regla2_e03;
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_regla2_e03_a;
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_regla2_e03_e1;

  CREATE TABLE bdm_tempo.stg_mock_regla2_e03
  DISTSTYLE KEY DISTKEY(id_buro_persona)
  AS
  SELECT a.*
  FROM bdm_tempo.stg_mock_regla2_e2 a
  JOIN bdm_tempo.v_mock_relacion_persona_ubicacion rpu
    ON a.cod_dw_persona_ubic = rpu.cod_dw_persona_ubic
  WHERE a.ind_unificacion = 'N'
    AND COALESCE(rpu.cod_tipo_ident_fte, '') <> '3';

  CREATE TABLE bdm_tempo.stg_mock_regla2_e03_a
  DISTSTYLE KEY DISTKEY(id_buro_persona)
  AS
  SELECT u1.*
  FROM (
    SELECT
      a.cod_dw_persona_ubic,
      COALESCE(CAST(REPLACE(CAST(a.fecha_relacion_persona_ubicaci AS VARCHAR), '-', '') AS BIGINT), 19000101)
        + (COALESCE(a.numero_entidades_reportan, 0) + 10000000) AS id,
      a.texto_ubicacion,
      a.fecha_relacion_persona_ubicaci,
      nmc1.nomenclatura,
      a.id_buro_persona,
      a.cod_dw_tipo_ubicacion_dir,
      a.cod_dw_municipio,
      ROW_NUMBER() OVER (
        PARTITION BY a.id_buro_persona, a.texto_ubicacion, a.cod_dw_tipo_ubicacion_dir,
          a.cod_dw_municipio, nmc1.nomenclatura
        ORDER BY COALESCE(CAST(REPLACE(CAST(a.fecha_relacion_persona_ubicaci AS VARCHAR), '-', '') AS BIGINT), 19000101)
          + (COALESCE(a.numero_entidades_reportan, 0) + 10000000)
      ) AS orden
    FROM bdm_tempo.stg_mock_regla2_e03 a
    JOIN bdm_tempo.stg_mock_regla2_e03 b
      ON a.id_buro_persona = b.id_buro_persona
     AND a.texto_ubicacion = b.texto_ubicacion
     AND a.cod_dw_tipo_ubicacion_dir = b.cod_dw_tipo_ubicacion_dir
     AND a.cod_dw_municipio = b.cod_dw_municipio
     AND a.cod_dw_persona_ubic <> b.cod_dw_persona_ubic
     AND a.complemento <> b.complemento
    JOIN bdm_stage.nomenclatura nmc1
      ON a.complemento LIKE nmc1.nomenclatura || '%'
    JOIN bdm_stage.nomenclatura nmc2
      ON b.complemento LIKE nmc2.nomenclatura || '%'
    WHERE nmc1.nomenclatura = nmc2.nomenclatura
  ) u1;

  CREATE TABLE bdm_tempo.stg_mock_regla2_e03_e1
  DISTSTYLE KEY DISTKEY(cod_dw_persona_ubic)
  AS
  SELECT DISTINCT
    b.cod_dw_persona_ubic,
    a.cod_dw_persona_ubic AS id_padre
  FROM bdm_tempo.stg_mock_regla2_e03_a a
  JOIN bdm_tempo.stg_mock_regla2_e03_a b
    ON a.id_buro_persona = b.id_buro_persona
   AND a.texto_ubicacion = b.texto_ubicacion
   AND a.cod_dw_tipo_ubicacion_dir = b.cod_dw_tipo_ubicacion_dir
   AND a.cod_dw_municipio = b.cod_dw_municipio
   AND a.nomenclatura = b.nomenclatura
   AND a.cod_dw_persona_ubic <> b.cod_dw_persona_ubic
   AND a.id > b.id
  JOIN (
    SELECT id_buro_persona, texto_ubicacion, cod_dw_tipo_ubicacion_dir, cod_dw_municipio, nomenclatura,
      MAX(orden) AS max_orden
    FROM bdm_tempo.stg_mock_regla2_e03_a
    GROUP BY 1,2,3,4,5
  ) mx
    ON a.id_buro_persona = mx.id_buro_persona
   AND a.texto_ubicacion = mx.texto_ubicacion
   AND a.cod_dw_tipo_ubicacion_dir = mx.cod_dw_tipo_ubicacion_dir
   AND a.cod_dw_municipio = mx.cod_dw_municipio
   AND a.nomenclatura = mx.nomenclatura
   AND a.orden = mx.max_orden;

  -- Persistencia condicional al modo (Tarea 6.1, Req 5.1..5.6).
  -- 1) Materializar el resultado de la regla (SELECT DISTINCT, Req 5.5).
  DROP TABLE IF EXISTS bdm_tempo.sp_unificacion_mock_r2_esc3_sin_nit_misma_nomenclatura_persist;
  CREATE TABLE bdm_tempo.sp_unificacion_mock_r2_esc3_sin_nit_misma_nomenclatura_persist
  DISTSTYLE KEY DISTKEY(cod_dw_persona_ubic)
  AS
  SELECT DISTINCT
    cod_dw_persona_ubic AS cod_dw_persona_ubic,
    id_padre AS cod_dw_direccion_unificada,
    2 AS unifica_atributos,
    CURRENT_DATE AS fecha_unificacion,
    p_lote /* Lote_Corrida externo */ AS lote,
    1 AS severidad,
    LEFT(CURRENT_USER, 30) AS usuario_bd
  FROM bdm_tempo.stg_mock_regla2_e03_e1;

  IF p_modo = 'FULL' THEN
    -- FULL: append (el TRUNCATE lo hizo el orquestador una vez).
    INSERT INTO bdm_datos.unificacion_direccion_mock
      (cod_dw_persona_ubic, cod_dw_direccion_unificada, unifica_atributos, fecha_unificacion, lote, severidad, usuario_bd)
    SELECT DISTINCT cod_dw_persona_ubic, cod_dw_direccion_unificada, unifica_atributos, fecha_unificacion, lote, severidad, usuario_bd
    FROM bdm_tempo.sp_unificacion_mock_r2_esc3_sin_nit_misma_nomenclatura_persist;
  ELSE
    -- DELTA UPSERT (DELETE+INSERT): cluster Redshift no acepta alias en MERGE.
    -- Misma Clave_Unificacion; sin truncar tabla completa (Req 5.1, 5.2, 5.6).
    DELETE FROM bdm_datos.unificacion_direccion_mock
    USING bdm_tempo.sp_unificacion_mock_r2_esc3_sin_nit_misma_nomenclatura_persist s
    WHERE bdm_datos.unificacion_direccion_mock.cod_dw_persona_ubic = s.cod_dw_persona_ubic
      AND bdm_datos.unificacion_direccion_mock.cod_dw_direccion_unificada = s.cod_dw_direccion_unificada;

    INSERT INTO bdm_datos.unificacion_direccion_mock
      (cod_dw_persona_ubic, cod_dw_direccion_unificada, unifica_atributos, fecha_unificacion, lote, severidad, usuario_bd)
    SELECT DISTINCT cod_dw_persona_ubic, cod_dw_direccion_unificada, unifica_atributos, fecha_unificacion, lote, severidad, usuario_bd
    FROM bdm_tempo.sp_unificacion_mock_r2_esc3_sin_nit_misma_nomenclatura_persist;
  END IF;

  DROP TABLE IF EXISTS bdm_tempo.sp_unificacion_mock_r2_esc3_sin_nit_misma_nomenclatura_persist;

  UPDATE bdm_tempo.stg_mock_regla2_e2
  SET id_padre = stg.id_padre,
      ind_unificacion = 'S',
      n_id = 'L3'
  FROM bdm_tempo.stg_mock_regla2_e03_e1 stg
  WHERE bdm_tempo.stg_mock_regla2_e2.cod_dw_persona_ubic = stg.cod_dw_persona_ubic
    AND bdm_tempo.stg_mock_regla2_e2.id_padre IS NULL;


END;
$$;
-- SLCOPRBA-1355: re-DPLY DEV post DROP SCHEMA strct #256
