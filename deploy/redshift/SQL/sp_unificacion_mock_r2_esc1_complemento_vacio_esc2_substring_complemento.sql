-- R2 Esc1 — complemento vacío absorbe con complemento
-- MODO MOCK — lee v_mock_*/bdm_stage; NO usa edf_views ni v_xpm_*
-- Escenario: R2 Esc2 — substring de complemento en mismo texto
-- Fuente: bdm_stage → bdm_tempo.v_mock_* | Salida: bdm_datos.unificacion_direccion_mock | MODO MOCK
-- Prerequisito: sp_unificacion_mock_r2_preparar_insumo
-- Generado: tools/gen_unificacion_mock_sps.py (espejo mock)

CREATE OR REPLACE PROCEDURE bdm_datos.sp_unificacion_mock_r2_esc1_complemento_vacio_esc2_substring_complemento(
    p_modo VARCHAR,   -- FULL | DELTA (modo efectivo de la corrida)
    p_lote INTEGER    -- Lote_Corrida externo (reemplaza el 1 hardcodeado)
)
NONATOMIC
LANGUAGE plpgsql
AS $$
BEGIN
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_regla2_esc1_pares;
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_regla2_e1;
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_regla2_esc2_pares;
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_regla2_e2;

  CREATE TABLE bdm_tempo.stg_mock_regla2_esc1_pares
  DISTSTYLE KEY DISTKEY(cod_dw_persona_ubic)
  AS
  SELECT cod_dw_persona_ubic, id_padre
  FROM (
    SELECT
      b.cod_dw_persona_ubic,
      a.cod_dw_persona_ubic AS id_padre,
      ROW_NUMBER() OVER (PARTITION BY b.cod_dw_persona_ubic ORDER BY a.cod_dw_persona_ubic DESC) AS rn
    FROM bdm_tempo.stg_mock_regla2_insumo a
    JOIN bdm_tempo.stg_mock_regla2_insumo b
      ON a.id_buro_persona = b.id_buro_persona
     AND a.texto_ubicacion = b.texto_ubicacion
     AND a.cod_dw_tipo_ubicacion_dir = b.cod_dw_tipo_ubicacion_dir
     AND a.cod_dw_municipio = b.cod_dw_municipio
     AND a.cod_dw_persona_ubic <> b.cod_dw_persona_ubic
    WHERE a.complemento IS NOT NULL
      AND LENGTH(a.complemento) > 0
      AND (b.complemento IS NULL OR LENGTH(b.complemento) = 0)
  )
  WHERE rn = 1;

  CREATE TABLE bdm_tempo.stg_mock_regla2_e1
  DISTSTYLE KEY DISTKEY(id_buro_persona)
  AS
  SELECT
    a.cod_dw_persona_ubic,
    b.id_padre,
    a.id_buro_persona,
    a.cod_dw_tipo_ubicacion_dir,
    a.cod_dw_ubic,
    a.texto_ubicacion,
    a.cod_dw_direccion_fisica,
    a.complemento,
    a.cod_dw_municipio,
    a.numero_entidades_reportan,
    a.fecha_relacion_persona_ubicaci,
    CASE WHEN b.cod_dw_persona_ubic IS NOT NULL THEN 'S' ELSE 'N' END AS ind_unificacion,
    CASE WHEN b.cod_dw_persona_ubic IS NOT NULL THEN 'H1' END AS n_id,
    ROW_NUMBER() OVER (
      PARTITION BY a.id_buro_persona, a.cod_dw_ubic,
        CASE WHEN b.cod_dw_persona_ubic IS NOT NULL THEN 'S' ELSE 'N' END,
        a.cod_dw_tipo_ubicacion_dir
      ORDER BY a.complemento
    ) AS row_u
  FROM bdm_tempo.stg_mock_regla2_insumo a
  LEFT JOIN bdm_tempo.stg_mock_regla2_esc1_pares b
    ON a.cod_dw_persona_ubic = b.cod_dw_persona_ubic;

  CREATE TABLE bdm_tempo.stg_mock_regla2_esc2_pares
  DISTSTYLE KEY DISTKEY(cod_dw_persona_ubic)
  AS
  SELECT cod_dw_persona_ubic, id_padre
  FROM (
    SELECT
      b.cod_dw_persona_ubic,
      a.cod_dw_persona_ubic AS id_padre,
      ROW_NUMBER() OVER (PARTITION BY b.cod_dw_persona_ubic ORDER BY b.cod_dw_persona_ubic DESC) AS rn
    FROM bdm_tempo.stg_mock_regla2_e1 a
    JOIN bdm_tempo.stg_mock_regla2_e1 b
      ON a.id_buro_persona = b.id_buro_persona
     AND a.texto_ubicacion = b.texto_ubicacion
     AND a.cod_dw_tipo_ubicacion_dir = b.cod_dw_tipo_ubicacion_dir
     AND a.cod_dw_municipio = b.cod_dw_municipio
     AND a.cod_dw_persona_ubic <> b.cod_dw_persona_ubic
     AND a.complemento <> b.complemento
    WHERE a.complemento LIKE '%' || b.complemento || '%'
      AND a.ind_unificacion = 'N'
      AND b.ind_unificacion = 'N'
      AND LENGTH(b.complemento) > 0
  )
  WHERE rn = 1;

  CREATE TABLE bdm_tempo.stg_mock_regla2_e2
  DISTSTYLE KEY DISTKEY(id_buro_persona)
  AS
  SELECT
    a.cod_dw_persona_ubic,
    CASE WHEN a.id_padre IS NOT NULL THEN a.id_padre ELSE b.id_padre END AS id_padre,
    a.id_buro_persona,
    a.cod_dw_tipo_ubicacion_dir,
    a.cod_dw_ubic,
    a.texto_ubicacion,
    a.cod_dw_direccion_fisica,
    a.complemento,
    a.cod_dw_municipio,
    a.numero_entidades_reportan,
    a.fecha_relacion_persona_ubicaci,
    CASE WHEN a.ind_unificacion = 'S' THEN 'S'
         WHEN b.cod_dw_persona_ubic IS NOT NULL THEN 'S'
         ELSE 'N' END AS ind_unificacion,
    CASE WHEN a.n_id IS NOT NULL THEN a.n_id
         WHEN b.cod_dw_persona_ubic IS NOT NULL THEN 'K2' END AS n_id,
    ROW_NUMBER() OVER (
      PARTITION BY a.id_buro_persona, a.cod_dw_ubic,
        CASE WHEN a.ind_unificacion = 'S' THEN 'S'
             WHEN b.cod_dw_persona_ubic IS NOT NULL THEN 'S'
             ELSE 'N' END,
        a.cod_dw_tipo_ubicacion_dir
      ORDER BY a.complemento
    ) AS row_u
  FROM bdm_tempo.stg_mock_regla2_e1 a
  LEFT JOIN bdm_tempo.stg_mock_regla2_esc2_pares b
    ON a.cod_dw_persona_ubic = b.cod_dw_persona_ubic;

  -- Persistencia condicional al modo (Tarea 6.1, Req 5.1..5.6).
  -- 1) Materializar el resultado de la regla (SELECT DISTINCT, Req 5.5).
  DROP TABLE IF EXISTS bdm_tempo.sp_unificacion_mock_r2_esc1_complemento_vacio_esc2_substring_complemento_persist;
  CREATE TABLE bdm_tempo.sp_unificacion_mock_r2_esc1_complemento_vacio_esc2_substring_complemento_persist
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
  FROM bdm_tempo.stg_mock_regla2_e2
  WHERE ind_unificacion = 'S'
    AND id_padre IS NOT NULL;

  IF p_modo = 'FULL' THEN
    -- FULL: append (el TRUNCATE lo hizo el orquestador una vez).
    INSERT INTO bdm_datos.unificacion_direccion_mock
      (cod_dw_persona_ubic, cod_dw_direccion_unificada, unifica_atributos, fecha_unificacion, lote, severidad, usuario_bd)
    SELECT DISTINCT cod_dw_persona_ubic, cod_dw_direccion_unificada, unifica_atributos, fecha_unificacion, lote, severidad, usuario_bd
    FROM bdm_tempo.sp_unificacion_mock_r2_esc1_complemento_vacio_esc2_substring_complemento_persist;
  ELSE
    -- DELTA UPSERT fiel al legado Teradata (SLCOPRBA-1355).
    -- Patron 'INSERT FOR MISSING UPDATE ROWS' de
    -- P0020_UNIFICACION_DIRECCION_130.TPT (STEP Load_UNIFICACION_DIRECCION):
    --   1) UPDATE de las filas que YA existen con la misma Clave_Unificacion
    --      (cod_dw_persona_ubic, cod_dw_direccion_unificada).
    --   2) INSERT de las que faltan.
    -- El UPDATE NO reescribe 'lote' ni 'unifica_atributos': en el legado el
    -- Lote identifica la corrida que CREO la unificacion y es inmutable; solo
    -- se sellan Lote_Actualizacion / Fecha_Modificacion / Usuario_BD.
    -- NO se usa MERGE: el cluster Redshift no acepta alias en MERGE.
    -- NO se usa DELETE+INSERT (version anterior): reescribia 'lote' con el de
    -- la corrida en curso, perdiendo la trazabilidad de que corrida origino
    -- cada unificacion y haciendo ininterpretable total_unificaciones.
    -- NOTA Redshift: en UPDATE ... FROM la tabla destino NO admite alias; se
    -- referencia con su nombre calificado completo (igual que el DELETE USING).
    UPDATE bdm_datos.unificacion_direccion_mock
       SET lote_actualizacion = p_lote,
           fecha_modificacion = CURRENT_DATE,
           usuario_bd         = CURRENT_USER
      FROM bdm_tempo.sp_unificacion_mock_r2_esc1_complemento_vacio_esc2_substring_complemento_persist s
     WHERE bdm_datos.unificacion_direccion_mock.cod_dw_persona_ubic = s.cod_dw_persona_ubic
       AND bdm_datos.unificacion_direccion_mock.cod_dw_direccion_unificada = s.cod_dw_direccion_unificada;

    INSERT INTO bdm_datos.unificacion_direccion_mock
      (cod_dw_persona_ubic, cod_dw_direccion_unificada, unifica_atributos, fecha_unificacion, lote, severidad, usuario_bd)
    SELECT DISTINCT s.cod_dw_persona_ubic, s.cod_dw_direccion_unificada, s.unifica_atributos,
           s.fecha_unificacion, s.lote, s.severidad, s.usuario_bd
    FROM bdm_tempo.sp_unificacion_mock_r2_esc1_complemento_vacio_esc2_substring_complemento_persist s
    WHERE NOT EXISTS (
      SELECT 1
      FROM bdm_datos.unificacion_direccion_mock u
      WHERE u.cod_dw_persona_ubic = s.cod_dw_persona_ubic
        AND u.cod_dw_direccion_unificada = s.cod_dw_direccion_unificada);
  END IF;

  DROP TABLE IF EXISTS bdm_tempo.sp_unificacion_mock_r2_esc1_complemento_vacio_esc2_substring_complemento_persist;


END;
$$;
-- SLCOPRBA-1355: re-DPLY DEV post DROP SCHEMA strct #256
