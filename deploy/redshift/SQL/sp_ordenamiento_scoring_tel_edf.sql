-- 12_sp_ordenamiento_scoring_tel_edf.sql (generado — staging EDF, una lectura datashare en preparar)
-- Regenerar: py -3 tools/gen_ordenamiento_sps_edf.py

CREATE OR REPLACE PROCEDURE bdm_datos.sp_ordenamiento_scoring_tel_edf()
NONATOMIC
LANGUAGE plpgsql
AS $$
BEGIN
  -- ============================================================
  -- 03_scoring_tel.sql — Scoring Teléfono Fijo (canal TEL)
  -- 82 sentencias Teradata → 1 query con CTEs
  -- 11 características: TEL001-TEL025
  -- ============================================================

  DELETE FROM bdm_datos.score_ordenamiento
  WHERE canal = 'TEL'
    AND id_buro_persona IN (SELECT id_buro_persona FROM bdm_tempo.stg_ord_personas_alcance);

  INSERT INTO bdm_datos.score_ordenamiento (
    cod_dw_persona_ubic, cod_pin_persona, id_buro_persona, canal, score, lugar
  )
  WITH
  base_agg AS (
    SELECT
      MIN(cod_dw_persona_ubic) AS cod_dw_persona_ubic,
      MIN(cod_pin_persona) AS cod_pin_persona,
      id_buro_persona,
      direccion_fisica,
      -- TEL001: % meses con reporte (meses_reporte / total_meses * 100)
      CAST(100.0 * COUNT(CASE WHEN descripcion_gestion <> 'NO VALIDA' OR descripcion_gestion IS NULL THEN 1 END)
        / NULLIF(COUNT(*), 0) AS DECIMAL(18,2)) AS tel001,
      -- TEL002: total reportes válidos
      COUNT(CASE WHEN descripcion_gestion <> 'NO VALIDA' OR descripcion_gestion IS NULL THEN 1 END) AS tel002,
      -- TEL003: meses desde primer reporte
      MAX(meses_reporte) AS tel003,
      -- TEL006: % reportes últimos 12 meses
      CAST(100.0 * SUM(CASE WHEN meses_reporte <= 12 AND (descripcion_gestion <> 'NO VALIDA' OR descripcion_gestion IS NULL) THEN 1 ELSE 0 END)
        / NULLIF(COUNT(CASE WHEN descripcion_gestion <> 'NO VALIDA' OR descripcion_gestion IS NULL THEN 1 END), 0) AS DECIMAL(18,2)) AS tel006,
      -- TEL007: reportes últimos 6 meses
      SUM(CASE WHEN meses_reporte <= 6 THEN 1 ELSE 0 END) AS tel007,
      -- TEL010: % reportes con coincidencia geo
      CAST(100.0 * SUM(CASE WHEN coincidencia_geo = 1 THEN 1 ELSE 0 END)
        / NULLIF(COUNT(*), 0) AS DECIMAL(18,2)) AS tel010,
      -- TEL017: % reportes sector financiero
      CAST(100.0 * SUM(CASE WHEN sector_financiero = 1 THEN 1 ELSE 0 END)
        / NULLIF(COUNT(*), 0) AS DECIMAL(18,2)) AS tel017,
      -- TEL019: % reportes tipo cuenta
      CAST(100.0 * SUM(CASE WHEN tipo_cuenta = 'FIJA' THEN 1 ELSE 0 END)
        / NULLIF(COUNT(*), 0) AS DECIMAL(18,2)) AS tel019,
      -- TEL020: tiene coincidencia geo (binario)
      MAX(coincidencia_geo) AS tel020,
      -- TEL023: % reportes locales (ciudad DANE)
      CAST(100.0 * COUNT(DISTINCT CASE WHEN cod_dane_ciudad IS NOT NULL THEN id_buro_suscriptor END)
        / NULLIF(COUNT(DISTINCT id_buro_suscriptor), 0) AS DECIMAL(18,2)) AS tel023,
      -- TEL025: % meses último reporte
      CAST(100.0 * MIN(meses_reporte) / NULLIF(MAX(meses_reporte), 0) AS DECIMAL(18,2)) AS tel025
    FROM bdm_tempo.stg_insumo_telefono
    GROUP BY id_buro_persona, direccion_fisica
  ),
  categorized AS (
    SELECT cod_dw_persona_ubic, cod_pin_persona, id_buro_persona,
      CASE WHEN tel001 < 8.33 THEN 1 WHEN tel001 < 18.18 THEN 2 WHEN tel001 < 40 THEN 3 WHEN tel001 >= 40 THEN 4 ELSE 0 END AS c01,
      CASE WHEN tel002 < 3 THEN 1 WHEN tel002 < 6 THEN 2 WHEN tel002 < 74 THEN 3 WHEN tel002 >= 74 THEN 4 ELSE 0 END AS c02,
      CASE WHEN tel003 < 39 THEN 1 WHEN tel003 < 65 THEN 2 WHEN tel003 < 119 THEN 3 WHEN tel003 >= 119 THEN 4 ELSE 0 END AS c03,
      CASE WHEN tel006 < 10 THEN 1 WHEN tel006 < 40 THEN 2 WHEN tel006 < 70 THEN 3 WHEN tel006 >= 70 THEN 4 ELSE 0 END AS c06,
      CASE WHEN tel007 < 2 THEN 1 WHEN tel007 < 3 THEN 2 WHEN tel007 < 6 THEN 3 WHEN tel007 >= 6 THEN 4 ELSE 0 END AS c07,
      CASE WHEN tel010 < 20 THEN 1 WHEN tel010 < 50 THEN 2 WHEN tel010 < 70 THEN 3 WHEN tel010 >= 70 THEN 4 ELSE 0 END AS c10,
      CASE WHEN tel017 < 1 THEN 1 WHEN tel017 < 63.33 THEN 2 WHEN tel017 < 95 THEN 3 WHEN tel017 >= 95 THEN 4 ELSE 0 END AS c17,
      CASE WHEN tel019 < 16.67 THEN 1 WHEN tel019 < 75 THEN 2 WHEN tel019 >= 75 THEN 3 ELSE 0 END AS c19,
      CASE WHEN tel020 <= 0 THEN 1 WHEN tel020 > 0 THEN 4 ELSE 0 END AS c20,
      CASE WHEN tel023 < 33.33 THEN 1 WHEN tel023 < 50 THEN 2 WHEN tel023 < 75 THEN 3 WHEN tel023 >= 75 THEN 4 ELSE 0 END AS c23,
      CASE WHEN tel025 < 17.5 THEN 1 WHEN tel025 < 45.75 THEN 2 WHEN tel025 < 76.65 THEN 3 WHEN tel025 >= 76.65 THEN 4 ELSE 0 END AS c25
    FROM base_agg
  ),
  scored AS (
    SELECT c.cod_dw_persona_ubic, c.cod_pin_persona, c.id_buro_persona,
      COALESCE((CAST(c.c01 AS FLOAT)/4)*b01.valor_beta,0) + COALESCE((CAST(c.c02 AS FLOAT)/4)*b02.valor_beta,0)
      + COALESCE((CAST(c.c03 AS FLOAT)/4)*b03.valor_beta,0) + COALESCE((CAST(c.c06 AS FLOAT)/4)*b06.valor_beta,0)
      + COALESCE((CAST(c.c07 AS FLOAT)/4)*b07.valor_beta,0) + COALESCE((CAST(c.c10 AS FLOAT)/4)*b10.valor_beta,0)
      + COALESCE((CAST(c.c17 AS FLOAT)/4)*b17.valor_beta,0) + COALESCE((CAST(c.c19 AS FLOAT)/3)*b19.valor_beta,0)
      -- TEL020: se calcula (c20) pero no entra en SCORE (baseline Teradata / caso TEL-02)
      + COALESCE((CAST(c.c23 AS FLOAT)/4)*b23.valor_beta,0)
      + COALESCE((CAST(c.c25 AS FLOAT)/4)*b25.valor_beta,0) AS score
    FROM categorized c
    LEFT JOIN bdm_datos.beta_ordenamiento b01 ON b01.canal='TEL' AND b01.cod_caracteristica='CO01TEL001'
    LEFT JOIN bdm_datos.beta_ordenamiento b02 ON b02.canal='TEL' AND b02.cod_caracteristica='CO01TEL002'
    LEFT JOIN bdm_datos.beta_ordenamiento b03 ON b03.canal='TEL' AND b03.cod_caracteristica='CO01TEL003'
    LEFT JOIN bdm_datos.beta_ordenamiento b06 ON b06.canal='TEL' AND b06.cod_caracteristica='CO01TEL006'
    LEFT JOIN bdm_datos.beta_ordenamiento b07 ON b07.canal='TEL' AND b07.cod_caracteristica='CO01TEL007'
    LEFT JOIN bdm_datos.beta_ordenamiento b10 ON b10.canal='TEL' AND b10.cod_caracteristica='CO01TEL010'
    LEFT JOIN bdm_datos.beta_ordenamiento b17 ON b17.canal='TEL' AND b17.cod_caracteristica='CO01TEL017'
    LEFT JOIN bdm_datos.beta_ordenamiento b19 ON b19.canal='TEL' AND b19.cod_caracteristica='CO01TEL019'
    LEFT JOIN bdm_datos.beta_ordenamiento b20 ON b20.canal='TEL' AND b20.cod_caracteristica='CO01TEL020'
    LEFT JOIN bdm_datos.beta_ordenamiento b23 ON b23.canal='TEL' AND b23.cod_caracteristica='CO01TEL023'
    LEFT JOIN bdm_datos.beta_ordenamiento b25 ON b25.canal='TEL' AND b25.cod_caracteristica='CO01TEL025'
  )
  SELECT cod_dw_persona_ubic, cod_pin_persona, id_buro_persona, 'TEL',
    CAST(score AS DECIMAL(18,4)),
    ROW_NUMBER() OVER (PARTITION BY id_buro_persona ORDER BY score DESC)
  FROM scored;
END;
$$;
-- SLCOPRBA-1355: re-DPLY DEV post DROP SCHEMA strct #256
