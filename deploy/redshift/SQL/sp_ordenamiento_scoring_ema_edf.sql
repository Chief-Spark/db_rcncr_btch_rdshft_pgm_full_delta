-- 14_sp_ordenamiento_scoring_ema_edf.sql (generado — staging EDF, una lectura datashare en preparar)
-- Regenerar: py -3 tools/gen_ordenamiento_sps_edf.py

CREATE OR REPLACE PROCEDURE bdm_datos.sp_ordenamiento_scoring_ema_edf()
NONATOMIC
LANGUAGE plpgsql
AS $$
BEGIN
  -- ============================================================
  -- 05_scoring_ema.sql — Scoring Email (canal EMA)
  -- 38 sentencias Teradata → 1 query con CTEs
  -- 13 características: EMA003-EMA025
  -- ============================================================

  DELETE FROM bdm_datos.score_ordenamiento
  WHERE canal = 'EMA'
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
      email,
      MAX(meses_reporte) AS ema003,
      SUM(CASE WHEN meses_reporte <= 6 THEN 1 ELSE 0 END) AS ema007,
      COUNT(DISTINCT id_buro_suscriptor) AS ema010,
      MAX(CASE WHEN dominio IN ('gmail.com','hotmail.com','yahoo.com','outlook.com') THEN 1 ELSE 0 END) AS ema014,
      CAST(100.0 * COUNT(DISTINCT id_buro_suscriptor) / NULLIF(COUNT(*), 0) AS DECIMAL(18,2)) AS ema015,
      CAST(100.0 * SUM(CASE WHEN sector_financiero = 1 THEN 1 ELSE 0 END) / NULLIF(COUNT(*), 0) AS DECIMAL(18,2)) AS ema016,
      CAST(100.0 * SUM(CASE WHEN tipo_cuenta = 'PERSONAL' THEN 1 ELSE 0 END) / NULLIF(COUNT(*), 0) AS DECIMAL(18,2)) AS ema017,
      MAX(CASE WHEN meses_reporte <= 3 THEN 1 ELSE 0 END) AS ema018,
      COUNT(*) AS ema020_raw,
      COUNT(*) AS ema021_raw,
      MAX(CASE WHEN sector_financiero = 1 THEN 1 ELSE 0 END) AS ema023_raw,
      MAX(CASE WHEN dominio NOT IN ('gmail.com','hotmail.com','yahoo.com','outlook.com') THEN 1 ELSE 0 END) AS ema024,
      CAST(100.0 * MIN(meses_reporte) / NULLIF(MAX(meses_reporte), 0) AS DECIMAL(18,2)) AS ema025
    FROM bdm_tempo.stg_insumo_email
    GROUP BY id_buro_persona, email
  ),
  persona_ema AS (
    SELECT id_buro_persona, SUM(ema020_raw) AS total_rep FROM base_agg GROUP BY 1
  ),
  base AS (
    SELECT a.*,
      CAST(100.0 * a.ema020_raw / NULLIF(p.total_rep, 0) AS DECIMAL(18,2)) AS ema020,
      a.ema021_raw AS ema021,
      CAST(100.0 * a.ema023_raw AS DECIMAL(18,2)) AS ema023
    FROM base_agg a JOIN persona_ema p ON a.id_buro_persona = p.id_buro_persona
  ),
  categorized AS (
    SELECT cod_dw_persona_ubic, cod_pin_persona, id_buro_persona,
      CASE WHEN ema003 <= 26 THEN 1 WHEN ema003 <= 39 THEN 2 WHEN ema003 <= 54 THEN 3 WHEN ema003 > 54 THEN 4 ELSE 0 END AS c03,
      CASE WHEN ema007 <= 0 THEN 1 WHEN ema007 <= 1 THEN 2 WHEN ema007 <= 2 THEN 3 WHEN ema007 > 2 THEN 4 ELSE 0 END AS c07,
      CASE WHEN ema010 <= 1 THEN 1 WHEN ema010 <= 2 THEN 2 WHEN ema010 <= 3 THEN 3 WHEN ema010 > 3 THEN 4 ELSE 0 END AS c10,
      CASE WHEN ema014 = 1 THEN 4 ELSE 1 END AS c14,
      CASE WHEN ema015 < 20 THEN 1 WHEN ema015 < 50 THEN 2 WHEN ema015 < 70 THEN 3 WHEN ema015 >= 70 THEN 4 ELSE 0 END AS c15,
      CASE WHEN ema016 < 1 THEN 1 WHEN ema016 < 63 THEN 2 WHEN ema016 < 95 THEN 3 WHEN ema016 >= 95 THEN 4 ELSE 0 END AS c16,
      CASE WHEN ema017 < 20 THEN 1 WHEN ema017 < 50 THEN 2 WHEN ema017 < 80 THEN 3 WHEN ema017 >= 80 THEN 4 ELSE 0 END AS c17,
      CASE WHEN ema018 <= 0 THEN 1 ELSE 3 END AS c18,
      CASE WHEN ema020 <= 0 THEN 1 WHEN ema020 <= 50 THEN 2 WHEN ema020 > 50 THEN 3 ELSE 0 END AS c20,
      CASE WHEN ema021 <= 5 THEN 1 WHEN ema021 <= 45 THEN 2 WHEN ema021 <= 50 THEN 3 WHEN ema021 > 50 THEN 4 ELSE 0 END AS c21,
      CASE WHEN ema023 <= 0 THEN 1 WHEN ema023 <= 44 THEN 2 WHEN ema023 > 44 THEN 3 ELSE 0 END AS c23,
      CASE WHEN ema024 <= 0 THEN 1 ELSE 1 END AS c24,
      CASE WHEN ema025 <= 20 THEN 1 WHEN ema025 <= 30 THEN 2 WHEN ema025 > 30 THEN 3 ELSE 0 END AS c25
    FROM base
  ),
  scored AS (
    SELECT c.cod_dw_persona_ubic, c.cod_pin_persona, c.id_buro_persona,
      -- EMA003/007/018/025: calculadas pero fuera de SUM (baseline Teradata / caso EMA-03)
      COALESCE((CAST(c.c10 AS FLOAT)/4)*b10.valor_beta,0) + COALESCE((CAST(c.c14 AS FLOAT)/4)*b14.valor_beta,0)
      + COALESCE((CAST(c.c15 AS FLOAT)/4)*b15.valor_beta,0) + COALESCE((CAST(c.c16 AS FLOAT)/4)*b16.valor_beta,0)
      + COALESCE((CAST(c.c17 AS FLOAT)/4)*b17.valor_beta,0)
      + COALESCE((CAST(c.c20 AS FLOAT)/4)*b20.valor_beta,0) + COALESCE((CAST(c.c21 AS FLOAT)/4)*b21.valor_beta,0)
      + COALESCE((CAST(c.c23 AS FLOAT)/4)*b23.valor_beta,0) + COALESCE((CAST(c.c24 AS FLOAT)/4)*b24.valor_beta,0) AS score
    FROM categorized c
    LEFT JOIN bdm_datos.beta_ordenamiento b03 ON b03.canal='EMA' AND b03.cod_caracteristica='CO01EMA003'
    LEFT JOIN bdm_datos.beta_ordenamiento b07 ON b07.canal='EMA' AND b07.cod_caracteristica='CO01EMA007'
    LEFT JOIN bdm_datos.beta_ordenamiento b10 ON b10.canal='EMA' AND b10.cod_caracteristica='CO01EMA010'
    LEFT JOIN bdm_datos.beta_ordenamiento b14 ON b14.canal='EMA' AND b14.cod_caracteristica='CO01EMA014'
    LEFT JOIN bdm_datos.beta_ordenamiento b15 ON b15.canal='EMA' AND b15.cod_caracteristica='CO01EMA015'
    LEFT JOIN bdm_datos.beta_ordenamiento b16 ON b16.canal='EMA' AND b16.cod_caracteristica='CO01EMA016'
    LEFT JOIN bdm_datos.beta_ordenamiento b17 ON b17.canal='EMA' AND b17.cod_caracteristica='CO01EMA017'
    LEFT JOIN bdm_datos.beta_ordenamiento b18 ON b18.canal='EMA' AND b18.cod_caracteristica='CO01EMA018'
    LEFT JOIN bdm_datos.beta_ordenamiento b20 ON b20.canal='EMA' AND b20.cod_caracteristica='CO01EMA020'
    LEFT JOIN bdm_datos.beta_ordenamiento b21 ON b21.canal='EMA' AND b21.cod_caracteristica='CO01EMA021'
    LEFT JOIN bdm_datos.beta_ordenamiento b23 ON b23.canal='EMA' AND b23.cod_caracteristica='CO01EMA023'
    LEFT JOIN bdm_datos.beta_ordenamiento b24 ON b24.canal='EMA' AND b24.cod_caracteristica='CO01EMA024'
    LEFT JOIN bdm_datos.beta_ordenamiento b25 ON b25.canal='EMA' AND b25.cod_caracteristica='CO01EMA025'
  )
  SELECT cod_dw_persona_ubic, cod_pin_persona, id_buro_persona, 'EMA',
    CAST(score AS DECIMAL(18,4)),
    ROW_NUMBER() OVER (PARTITION BY id_buro_persona ORDER BY score DESC)
  FROM scored;
END;
$$;
-- SLCOPRBA-1355: re-DPLY DEV post DROP SCHEMA strct #256
