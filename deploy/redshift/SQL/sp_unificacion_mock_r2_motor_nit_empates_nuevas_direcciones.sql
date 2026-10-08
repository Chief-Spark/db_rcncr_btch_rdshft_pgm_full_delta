-- R2 Motor — NIT y empates (Esc3/Esc5/Esc6)
-- MODO MOCK — lee v_mock_*/bdm_stage; NO usa edf_views ni v_xpm_*
-- Escenario: Genera nuevas direcciones en staging stg_motor_insumo
-- Fuente: bdm_stage → bdm_tempo.v_mock_* | Salida: bdm_datos.unificacion_direccion_mock | MODO MOCK
-- Prerequisito: sp_unificacion_mock_r2_esc6_frecuencia_complemento_gana
-- Generado: tools/gen_unificacion_mock_sps.py (espejo mock)

CREATE OR REPLACE PROCEDURE bdm_datos.sp_unificacion_mock_r2_motor_nit_empates_nuevas_direcciones(
    p_modo VARCHAR,   -- FULL | DELTA (modo efectivo de la corrida)
    p_lote INTEGER    -- Lote_Corrida externo (reemplaza el 1 hardcodeado)
)
NONATOMIC
LANGUAGE plpgsql
AS $$
BEGIN
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_motor_keys;
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_motor_ranked;
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_motor_insumo;

  -- Motor R2 (XPM real): Esc3 NIT / Esc5 / Esc6 -> ifr_data.generada_enriquecida=1 + RPU sintetica
  CREATE TABLE bdm_tempo.stg_mock_motor_keys
  DISTSTYLE KEY DISTKEY(id_buro_persona)
  AS
  SELECT DISTINCT id_buro_persona, texto_ubicacion, cod_dw_tipo_ubicacion_dir, cod_dw_municipio
  FROM (
    SELECT e.id_buro_persona, e.texto_ubicacion, e.cod_dw_tipo_ubicacion_dir, e.cod_dw_municipio
    FROM bdm_tempo.stg_mock_regla2_e2 e
    JOIN bdm_tempo.stg_mock_regla2_insumo i ON i.cod_dw_persona_ubic = e.cod_dw_persona_ubic
    WHERE e.ind_unificacion = 'N' AND COALESCE(i.cod_tipo_ident_fte, '') = '3'
    GROUP BY 1, 2, 3, 4
    HAVING COUNT(DISTINCT e.cod_dw_persona_ubic) >= 2

    UNION

    SELECT DISTINCT a.id_buro_persona, a.texto_ubicacion, a.cod_dw_tipo_ubicacion_dir, a.cod_dw_municipio
    FROM bdm_tempo.stg_mock_regla2_e05_a a
    JOIN bdm_tempo.stg_mock_regla2_e05_a b
      ON a.id_buro_persona = b.id_buro_persona
     AND a.texto_ubicacion = b.texto_ubicacion
     AND a.cod_dw_tipo_ubicacion_dir = b.cod_dw_tipo_ubicacion_dir
     AND a.cod_dw_municipio = b.cod_dw_municipio
     AND a.cod_dw_persona_ubic <> b.cod_dw_persona_ubic
     AND COALESCE(a.nivel_pri, 99) <> COALESCE(b.nivel_pri, 99)
    WHERE a.nomenclatura_pri IS NOT NULL AND b.nomenclatura_pri IS NOT NULL

    UNION

    SELECT DISTINCT a.id_buro_persona, a.texto_ubicacion, a.cod_dw_tipo_ubicacion_dir, a.cod_dw_municipio
    FROM (SELECT * FROM bdm_tempo.stg_mock_regla2_e2 WHERE ind_unificacion = 'N') a
    JOIN (SELECT * FROM bdm_tempo.stg_mock_regla2_e2 WHERE ind_unificacion = 'N') b
      ON a.id_buro_persona = b.id_buro_persona
     AND a.texto_ubicacion = b.texto_ubicacion
     AND a.cod_dw_tipo_ubicacion_dir = b.cod_dw_tipo_ubicacion_dir
     AND a.cod_dw_municipio = b.cod_dw_municipio
     AND a.cod_dw_persona_ubic <> b.cod_dw_persona_ubic
     AND a.complemento <> b.complemento
    JOIN bdm_tempo.stg_mock_regla2_e06_freq fa ON a.cod_dw_persona_ubic = fa.cod_dw_persona_ubic
    JOIN bdm_tempo.stg_mock_regla2_e06_freq fb ON b.cod_dw_persona_ubic = fb.cod_dw_persona_ubic
    WHERE fa.freq = fb.freq
  ) motor_src;

  CREATE TABLE bdm_tempo.stg_mock_motor_ranked
  DISTSTYLE KEY DISTKEY(id_buro_persona)
  AS
  SELECT
    e.*,
    ROW_NUMBER() OVER (
      PARTITION BY e.id_buro_persona, e.texto_ubicacion, e.cod_dw_tipo_ubicacion_dir, e.cod_dw_municipio
      ORDER BY e.cod_dw_persona_ubic
    ) AS motor_rn
  FROM bdm_tempo.stg_mock_regla2_e2 e
  JOIN bdm_tempo.stg_mock_motor_keys k
    ON k.id_buro_persona = e.id_buro_persona
   AND k.texto_ubicacion = e.texto_ubicacion
   AND k.cod_dw_tipo_ubicacion_dir = e.cod_dw_tipo_ubicacion_dir
   AND k.cod_dw_municipio = e.cod_dw_municipio
  WHERE e.ind_unificacion = 'N';

  CREATE TABLE bdm_tempo.stg_mock_motor_insumo
  DISTSTYLE KEY DISTKEY(id_buro_persona)
  AS
  SELECT
    ra.id_buro_persona,
    i.cod_pin_persona,
    ra.cod_dw_ubic,
    ra.cod_dw_tipo_ubicacion_dir,
    ra.fecha_relacion_persona_ubicaci,
    i.lote,
    i.cod_tipo_ident_fte,
    dfa.tipo_via_principal,
    dfa.via_principal,
    dfa.via_generadora,
    dfa.numero_puerta,
    FNV_HASH(CAST(ra.id_buro_persona AS VARCHAR) || '|MOTOR|DF|' || ra.texto_ubicacion) AS cod_dw_direccion_fisica,
    FNV_HASH(CAST(ra.id_buro_persona AS VARCHAR) || '|MOTOR|RPU|' || ra.texto_ubicacion) AS cod_dw_persona_ubic,
    TRIM(
      TRIM(COALESCE(ra.complemento, '')) || ' ' || TRIM(COALESCE(rb.complemento, ''))
    ) AS complemento_motor,
    CAST(1 AS INTEGER) AS generada_enriquecida
  FROM bdm_tempo.stg_mock_motor_ranked ra
  JOIN bdm_tempo.stg_mock_motor_ranked rb
    ON ra.id_buro_persona = rb.id_buro_persona
   AND ra.texto_ubicacion = rb.texto_ubicacion
   AND ra.cod_dw_tipo_ubicacion_dir = rb.cod_dw_tipo_ubicacion_dir
   AND ra.cod_dw_municipio = rb.cod_dw_municipio
   AND ra.motor_rn = 1
   AND rb.motor_rn = 2
  JOIN bdm_tempo.stg_mock_regla2_insumo i
    ON i.cod_dw_persona_ubic = ra.cod_dw_persona_ubic
  JOIN bdm_tempo.v_mock_direccion_fisica dfa
    ON dfa.cod_dw_direccion_fisica = ra.cod_dw_direccion_fisica;

  -- Salida motor en staging (sin INSERT a ifr_data; pipeline materializa tablas físicas)


END;
$$;
-- SLCOPRBA-1355: re-DPLY DEV post DROP SCHEMA strct #256
