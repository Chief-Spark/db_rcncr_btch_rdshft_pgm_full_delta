-- 13_sp_ordenamiento_scoring_cel_edf.sql (generado — staging EDF, una lectura datashare en preparar)
-- Regenerar: py -3 tools/gen_ordenamiento_sps_edf.py

CREATE OR REPLACE PROCEDURE bdm_datos.sp_ordenamiento_scoring_cel_edf()
NONATOMIC
LANGUAGE plpgsql
AS $$
BEGIN
  -- ============================================================
  -- 04_scoring_cel.sql — Scoring Celular (canal CEL)
  -- 63 sentencias Teradata → 1 query con CTEs
  -- 11 características: CEL003-CEL023
  -- ============================================================

  DELETE FROM bdm_datos.score_ordenamiento
  WHERE canal = 'CEL'
    AND id_buro_persona IN (SELECT id_buro_persona FROM bdm_tempo.stg_ord_personas_alcance);

  INSERT INTO bdm_datos.score_ordenamiento (
    cod_dw_persona_ubic, cod_pin_persona, id_buro_persona, canal, score, lugar
  )
  WITH
  base_agg AS (
    SELECT
      MIN(ic.cod_dw_persona_ubic) AS cod_dw_persona_ubic,
      MIN(ic.cod_pin_persona) AS cod_pin_persona,
      ic.id_buro_persona,
      ic.celular,
      MAX(ic.meses_reporte) AS cel003,
      CAST(100.0 * SUM(CASE WHEN ic.meses_reporte <= 12 THEN 1 ELSE 0 END) / NULLIF(COUNT(*), 0) AS DECIMAL(18,2)) AS cel006,
      SUM(CASE WHEN ic.meses_reporte <= 6 THEN 1 ELSE 0 END) AS cel007,
      MAX(CASE WHEN ic.operador IN ('310','311','312','313','314') THEN 1 ELSE 0 END) AS cel013,
      MAX(CASE WHEN ic.tipo_cuenta = 'POSPAGO' THEN 1 ELSE 0 END) AS cel014,
      CAST(100.0 * COUNT(DISTINCT ic.id_buro_suscriptor) / NULLIF(COUNT(*), 0) AS DECIMAL(18,2)) AS cel015,
      CAST(100.0 * SUM(CASE WHEN ic.sector_financiero = 1 THEN 1 ELSE 0 END) / NULLIF(COUNT(*), 0) AS DECIMAL(18,2)) AS cel017,
      CAST(100.0 * COALESCE(MAX(ooc.valor), 0.22) AS DECIMAL(18,2)) AS cel018,
      CAST(100.0 * SUM(CASE WHEN ic.tipo_cuenta = 'POSPAGO' THEN 1 ELSE 0 END) / NULLIF(COUNT(*), 0) AS DECIMAL(18,2)) AS cel019,
      COUNT(*) AS cel020_raw,
      MAX(CASE WHEN ic.texto_ubicacion IS NOT NULL AND ic.texto_ubicacion <> '' THEN 1 ELSE 0 END) AS cel023
    FROM bdm_tempo.stg_insumo_celular ic
    LEFT JOIN bdm_datos.catalogo_operador_ord_cel ooc
      ON ooc.cod_operador = LEFT(ic.celular, 3)
    GROUP BY ic.id_buro_persona, ic.celular
  ),
  persona_cel AS (
    SELECT id_buro_persona, SUM(cel020_raw) AS total_reportes FROM base_agg GROUP BY 1
  ),
  base AS (
    SELECT a.*, CAST(100.0 * a.cel020_raw / NULLIF(p.total_reportes, 0) AS DECIMAL(18,2)) AS cel020
    FROM base_agg a JOIN persona_cel p ON a.id_buro_persona = p.id_buro_persona
  ),
  categorized AS (
    SELECT cod_dw_persona_ubic, cod_pin_persona, id_buro_persona,
      CASE WHEN cel003 < 21 THEN 1 WHEN cel003 < 33 THEN 2 WHEN cel003 < 54 THEN 3 WHEN cel003 >= 54 THEN 4 ELSE 0 END AS c03,
      CASE WHEN cel006 < 5 THEN 1 WHEN cel006 < 90 THEN 2 WHEN cel006 >= 90 THEN 3 ELSE 0 END AS c06,
      CASE WHEN cel007 < 2 THEN 1 WHEN cel007 < 3 THEN 2 WHEN cel007 < 6 THEN 3 WHEN cel007 >= 6 THEN 4 ELSE 0 END AS c07,
      CASE WHEN cel013 = 0 THEN 1 WHEN cel013 = 1 THEN 4 ELSE 0 END AS c13,
      CASE WHEN cel014 = 0 THEN 1 WHEN cel014 = 1 THEN 4 ELSE 0 END AS c14,
      CASE WHEN cel015 < 20 THEN 1 WHEN cel015 < 50 THEN 2 WHEN cel015 < 70 THEN 3 WHEN cel015 >= 70 THEN 4 ELSE 0 END AS c15,
      CASE WHEN cel017 < 1 THEN 1 WHEN cel017 < 63 THEN 2 WHEN cel017 < 95 THEN 3 WHEN cel017 >= 95 THEN 4 ELSE 0 END AS c17,
      CASE WHEN cel018 < 51.11 THEN 1 WHEN cel018 < 61.48 THEN 2 WHEN cel018 < 73.33 THEN 3 WHEN cel018 >= 73.33 THEN 4 ELSE 0 END AS c18,
      CASE WHEN cel019 < 35 THEN 1 WHEN cel019 < 80 THEN 2 WHEN cel019 >= 80 THEN 3 ELSE 0 END AS c19,
      CASE WHEN cel020 < 33.33 THEN 1 WHEN cel020 < 45.67 THEN 2 WHEN cel020 < 100 THEN 3 WHEN cel020 >= 100 THEN 4 ELSE 0 END AS c20,
      CASE WHEN cel023 <= 0 THEN 1 WHEN cel023 > 0 THEN 4 ELSE 0 END AS c23
    FROM base
  ),
  scored AS (
    SELECT c.cod_dw_persona_ubic, c.cod_pin_persona, c.id_buro_persona,
      COALESCE((CAST(c.c03 AS FLOAT)/4)*b03.valor_beta,0) + COALESCE((CAST(c.c06 AS FLOAT)/4)*b06.valor_beta,0)
      + COALESCE((CAST(c.c07 AS FLOAT)/4)*b07.valor_beta,0) + COALESCE((CAST(c.c13 AS FLOAT)/4)*b13.valor_beta,0)
      + COALESCE((CAST(c.c14 AS FLOAT)/4)*b14.valor_beta,0) + COALESCE((CAST(c.c15 AS FLOAT)/4)*b15.valor_beta,0)
      + COALESCE((CAST(c.c17 AS FLOAT)/4)*b17.valor_beta,0) + COALESCE((CAST(c.c18 AS FLOAT)/4)*b18.valor_beta,0)
      + COALESCE((CAST(c.c19 AS FLOAT)/4)*b19.valor_beta,0) + COALESCE((CAST(c.c20 AS FLOAT)/4)*b20.valor_beta,0)
      + COALESCE((CAST(c.c23 AS FLOAT)/4)*b23.valor_beta,0) AS score
    FROM categorized c
    LEFT JOIN bdm_datos.beta_ordenamiento b03 ON b03.canal='CEL' AND b03.cod_caracteristica='CO01CEL003'
    LEFT JOIN bdm_datos.beta_ordenamiento b06 ON b06.canal='CEL' AND b06.cod_caracteristica='CO01CEL006'
    LEFT JOIN bdm_datos.beta_ordenamiento b07 ON b07.canal='CEL' AND b07.cod_caracteristica='CO01CEL007'
    LEFT JOIN bdm_datos.beta_ordenamiento b13 ON b13.canal='CEL' AND b13.cod_caracteristica='CO01CEL013'
    LEFT JOIN bdm_datos.beta_ordenamiento b14 ON b14.canal='CEL' AND b14.cod_caracteristica='CO01CEL014'
    LEFT JOIN bdm_datos.beta_ordenamiento b15 ON b15.canal='CEL' AND b15.cod_caracteristica='CO01CEL015'
    LEFT JOIN bdm_datos.beta_ordenamiento b17 ON b17.canal='CEL' AND b17.cod_caracteristica='CO01CEL017'
    LEFT JOIN bdm_datos.beta_ordenamiento b18 ON b18.canal='CEL' AND b18.cod_caracteristica='CO01CEL018'
    LEFT JOIN bdm_datos.beta_ordenamiento b19 ON b19.canal='CEL' AND b19.cod_caracteristica='CO01CEL019'
    LEFT JOIN bdm_datos.beta_ordenamiento b20 ON b20.canal='CEL' AND b20.cod_caracteristica='CO01CEL020'
    LEFT JOIN bdm_datos.beta_ordenamiento b23 ON b23.canal='CEL' AND b23.cod_caracteristica='CO01CEL023'
  )
  SELECT cod_dw_persona_ubic, cod_pin_persona, id_buro_persona, 'CEL',
    CAST(score AS DECIMAL(18,4)),
    ROW_NUMBER() OVER (PARTITION BY id_buro_persona ORDER BY score DESC)
  FROM scored;
END;
$$;
-- SLCOPRBA-1355: re-DPLY DEV post DROP SCHEMA strct #256
