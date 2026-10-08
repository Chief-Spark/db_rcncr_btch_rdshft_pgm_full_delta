-- R2 Esc5 — nivel de nomenclatura
-- MODO MOCK — lee v_mock_*/bdm_stage; NO usa edf_views ni v_xpm_*
-- Escenario: Nomenclaturas distintas: menor nivel pierde
-- Fuente: bdm_stage → bdm_tempo.v_mock_* | Salida: bdm_datos.unificacion_direccion_mock | MODO MOCK
-- Prerequisito: sp_unificacion_mock_r2_esc4_diccionario_frecuencia_complemento
-- Generado: tools/gen_unificacion_mock_sps.py (espejo mock)

CREATE OR REPLACE PROCEDURE bdm_datos.sp_unificacion_mock_r2_esc5_nomenclatura_menor_nivel_pierde(
    p_modo VARCHAR,   -- FULL | DELTA (modo efectivo de la corrida)
    p_lote INTEGER    -- Lote_Corrida externo (reemplaza el 1 hardcodeado)
)
NONATOMIC
LANGUAGE plpgsql
AS $$
BEGIN
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_regla2_e05;
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_regla2_e05_a;
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_regla2_e05_pares;

  CREATE TABLE bdm_tempo.stg_mock_regla2_e05
  DISTSTYLE KEY DISTKEY(id_buro_persona)
  AS
  SELECT DISTINCT a.*
  FROM (SELECT * FROM bdm_tempo.stg_mock_regla2_e2 WHERE ind_unificacion = 'N') a
  JOIN (SELECT * FROM bdm_tempo.stg_mock_regla2_e2 WHERE ind_unificacion = 'N') b
    ON a.id_buro_persona = b.id_buro_persona
   AND a.texto_ubicacion = b.texto_ubicacion
   AND a.cod_dw_tipo_ubicacion_dir = b.cod_dw_tipo_ubicacion_dir
   AND a.cod_dw_municipio = b.cod_dw_municipio
   AND a.cod_dw_persona_ubic <> b.cod_dw_persona_ubic
   AND a.complemento <> b.complemento;

  CREATE TABLE bdm_tempo.stg_mock_regla2_e05_a
  DISTSTYLE KEY DISTKEY(id_buro_persona)
  AS
  SELECT DISTINCT
    a.*,
    nmc1.nomenclatura AS nomenclatura_pri,
    nmc1.nivel_complemento AS nivel_pri
  FROM bdm_tempo.stg_mock_regla2_e05 a
  LEFT JOIN bdm_stage.nomenclatura nmc1
    ON a.complemento LIKE TRIM(nmc1.nomenclatura) || ' %';

  CREATE TABLE bdm_tempo.stg_mock_regla2_e05_pares
  DISTSTYLE KEY DISTKEY(cod_dw_persona_ubic)
  AS
  SELECT DISTINCT
    b.cod_dw_persona_ubic,
    a.cod_dw_persona_ubic AS id_padre
  FROM bdm_tempo.stg_mock_regla2_e05_a a
  JOIN bdm_tempo.stg_mock_regla2_e05_a b
    ON a.id_buro_persona = b.id_buro_persona
   AND a.texto_ubicacion = b.texto_ubicacion
   AND a.cod_dw_tipo_ubicacion_dir = b.cod_dw_tipo_ubicacion_dir
   AND a.cod_dw_municipio = b.cod_dw_municipio
   AND a.cod_dw_persona_ubic <> b.cod_dw_persona_ubic
   AND a.complemento <> b.complemento
   AND COALESCE(a.nivel_pri,99) < COALESCE(b.nivel_pri,99)
  WHERE a.nomenclatura_pri IS NOT NULL
    AND b.nomenclatura_pri IS NOT NULL
    AND a.nomenclatura_pri <> b.nomenclatura_pri;

  -- Persistencia condicional al modo (Tarea 6.1, Req 5.1..5.6).
  -- 1) Materializar el resultado de la regla (SELECT DISTINCT, Req 5.5).
  DROP TABLE IF EXISTS bdm_tempo.sp_unificacion_mock_r2_esc5_nomenclatura_menor_nivel_pierde_persist;
  CREATE TABLE bdm_tempo.sp_unificacion_mock_r2_esc5_nomenclatura_menor_nivel_pierde_persist
  DISTSTYLE KEY DISTKEY(cod_dw_persona_ubic)
  AS
  SELECT DISTINCT
    cod_dw_persona_ubic AS cod_dw_persona_ubic,
    id_padre AS cod_dw_direccion_unificada,
    2 AS unifica_atributos,
    CURRENT_DATE AS fecha_unificacion,
    p_lote /* Lote_Corrida externo */ AS lote,
    1 AS severidad,
    LEFT(CURRENT_USER,30) AS usuario_bd
  FROM bdm_tempo.stg_mock_regla2_e05_pares;

  IF p_modo = 'FULL' THEN
    -- FULL: append (el TRUNCATE lo hizo el orquestador una vez).
    INSERT INTO bdm_datos.unificacion_direccion_mock
      (cod_dw_persona_ubic, cod_dw_direccion_unificada, unifica_atributos, fecha_unificacion, lote, severidad, usuario_bd)
    SELECT DISTINCT cod_dw_persona_ubic, cod_dw_direccion_unificada, unifica_atributos, fecha_unificacion, lote, severidad, usuario_bd
    FROM bdm_tempo.sp_unificacion_mock_r2_esc5_nomenclatura_menor_nivel_pierde_persist;
  ELSE
    -- DELTA UPSERT (DELETE+INSERT): cluster Redshift no acepta alias en MERGE.
    -- Misma Clave_Unificacion; sin truncar tabla completa (Req 5.1, 5.2, 5.6).
    DELETE FROM bdm_datos.unificacion_direccion_mock
    USING bdm_tempo.sp_unificacion_mock_r2_esc5_nomenclatura_menor_nivel_pierde_persist s
    WHERE bdm_datos.unificacion_direccion_mock.cod_dw_persona_ubic = s.cod_dw_persona_ubic
      AND bdm_datos.unificacion_direccion_mock.cod_dw_direccion_unificada = s.cod_dw_direccion_unificada;

    INSERT INTO bdm_datos.unificacion_direccion_mock
      (cod_dw_persona_ubic, cod_dw_direccion_unificada, unifica_atributos, fecha_unificacion, lote, severidad, usuario_bd)
    SELECT DISTINCT cod_dw_persona_ubic, cod_dw_direccion_unificada, unifica_atributos, fecha_unificacion, lote, severidad, usuario_bd
    FROM bdm_tempo.sp_unificacion_mock_r2_esc5_nomenclatura_menor_nivel_pierde_persist;
  END IF;

  DROP TABLE IF EXISTS bdm_tempo.sp_unificacion_mock_r2_esc5_nomenclatura_menor_nivel_pierde_persist;

  UPDATE bdm_tempo.stg_mock_regla2_e2
  SET id_padre = e.id_padre,
      ind_unificacion = 'S',
      n_id = 'E5'
  FROM bdm_tempo.stg_mock_regla2_e05_pares e
  WHERE bdm_tempo.stg_mock_regla2_e2.cod_dw_persona_ubic = e.cod_dw_persona_ubic
    AND bdm_tempo.stg_mock_regla2_e2.id_padre IS NULL;


END;
$$;
-- SLCOPRBA-1355: re-DPLY DEV post DROP SCHEMA strct #256
