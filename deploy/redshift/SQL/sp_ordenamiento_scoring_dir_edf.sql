-- 11_sp_ordenamiento_scoring_dir_edf.sql (generado — staging EDF, una lectura datashare en preparar)
-- Regenerar: py -3 tools/gen_ordenamiento_sps_edf.py

CREATE OR REPLACE PROCEDURE bdm_datos.sp_ordenamiento_scoring_dir_edf()
NONATOMIC
LANGUAGE plpgsql
AS $$
BEGIN
  -- ============================================================
  -- 02_scoring_dir.sql
  -- Scoring de Direcciones (canal DIR)
  -- Consolida ~70 sentencias Teradata en un solo query con CTEs
  -- Fuente: Caracteristicas.txt (1.3- Calc Caracteristica_Direc)
  -- ============================================================
  -- Input: bdm_tempo.stg_insumo_direccion + bdm_datos.beta_ordenamiento
  -- Output: INSERT en bdm_datos.score_ordenamiento (canal='DIR')
  --
  -- 12 características: DIR001IN, DIR004RO, DIR007TO, DIR010FI,
  --   DIR013OT, DIR017, DIR019, DIR034FI, DIR050TO, DIR057, DIR059, DIR009
  -- ============================================================

  DELETE FROM bdm_datos.score_ordenamiento
  WHERE canal = 'DIR'
    AND id_buro_persona IN (SELECT id_buro_persona FROM bdm_tempo.stg_ord_personas_alcance);

  INSERT INTO bdm_datos.score_ordenamiento (
    cod_dw_persona_ubic, cod_pin_persona, id_buro_persona, canal, score, lugar
  )
  WITH
  -- Paso base: agregar métricas por persona+dirección
  base_agg AS (
    SELECT
      MIN(cod_dw_persona_ubic) AS cod_dw_persona_ubic,
      MIN(cod_pin_persona) AS cod_pin_persona,
      id_buro_persona,
      direccion_fisica,
      MAX(tipo_ubicacion) AS tipo_ubicacion,
      MIN(meses_reporte) AS dir001in,
      COUNT(*) AS dir002to,
      SUM(CASE WHEN meses_reporte <= 12 THEN 1 ELSE 0 END) AS dir004ro,
      SUM(CASE WHEN meses_reporte <= 6 THEN 1 ELSE 0 END) AS dir007to,
      CAST(100.0 * SUM(CASE WHEN sector_financiero = 1 THEN 1 ELSE 0 END)
        / NULLIF(COUNT(*), 0) AS DECIMAL(18,2)) AS dir010fi,
      CAST(100.0 * SUM(CASE WHEN sector_financiero = 0 THEN 1 ELSE 0 END)
        / NULLIF(COUNT(*), 0) AS DECIMAL(18,2)) AS dir013ot,
      MAX(CASE WHEN tipo_ubicacion = 'RES' THEN 1
               WHEN tipo_ubicacion = 'LAB' THEN 2
               WHEN tipo_ubicacion = 'CRR' THEN 3 ELSE 0 END) AS dir017,
      MAX(CASE WHEN meses_reporte <= 3 THEN 1 ELSE 0 END) AS dir019,
      CAST(100.0 * SUM(CASE WHEN sector_financiero = 1 AND meses_reporte <= 12 THEN 1 ELSE 0 END)
        / NULLIF(SUM(CASE WHEN meses_reporte <= 12 THEN 1 ELSE 0 END), 0) AS DECIMAL(18,2)) AS dir034fi,
      COUNT(DISTINCT id_buro_suscriptor) AS dir009
    FROM bdm_tempo.stg_insumo_direccion
    GROUP BY id_buro_persona, direccion_fisica
  ),

  -- Métricas a nivel persona (window functions separadas del GROUP BY)
  persona_stats AS (
    SELECT id_buro_persona,
      SUM(dir002to) AS dir050to,
      COUNT(*) AS dir057
    FROM base_agg
    GROUP BY id_buro_persona
  ),

  base AS (
    SELECT
      a.*,
      p.dir050to AS dir050to_raw,
      p.dir057,
      CAST(100.0 * a.dir002to / NULLIF(p.dir050to, 0) AS DECIMAL(18,2)) AS dir059
    FROM base_agg a
    JOIN persona_stats p ON a.id_buro_persona = p.id_buro_persona
  ),

  -- Categorización (CASE WHEN → 1..N)
  categorized AS (
    SELECT
      cod_dw_persona_ubic, cod_pin_persona, id_buro_persona,
      -- DIR001IN: meses primer reporte
      CASE WHEN dir001in IS NULL THEN 1 WHEN dir001in <= 24 THEN 2 ELSE 3 END AS cat_001in,
      -- DIR004RO: reportes 12m
      CASE WHEN dir004ro IS NULL THEN 1 WHEN dir004ro <= 2 THEN 2 ELSE 3 END AS cat_004ro,
      -- DIR007TO: reportes 6m
      CASE WHEN dir007to IS NULL THEN 1 WHEN dir007to <= 0 THEN 2 WHEN dir007to <= 2 THEN 3
           WHEN dir007to <= 3 THEN 4 WHEN dir007to <= 6 THEN 5 ELSE 6 END AS cat_007to,
      -- DIR010FI: % financiero
      CASE WHEN dir010fi IS NULL THEN 1 WHEN dir010fi <= 2 THEN 2 ELSE 3 END AS cat_010fi,
      -- DIR013OT: % otros
      CASE WHEN dir013ot IS NULL THEN 1 WHEN dir013ot <= 4.35 THEN 2
           WHEN dir013ot <= 6.9 THEN 3 WHEN dir013ot <= 14.29 THEN 4 ELSE 5 END AS cat_013ot,
      -- DIR017: tipo ubicación
      CASE WHEN dir017 IS NULL THEN 1 WHEN dir017 <= 1 THEN 2 ELSE 3 END AS cat_017,
      -- DIR019: reportes recientes
      CASE WHEN dir019 IS NULL OR dir019 = 0 THEN 1 ELSE 2 END AS cat_019,
      -- DIR034FI: % financiero 12m
      CASE WHEN dir034fi IS NULL THEN 1 WHEN dir034fi <= 3.54 THEN 2 ELSE 3 END AS cat_034fi,
      -- DIR050TO: total reportes persona
      CASE WHEN dir050to_raw IS NULL THEN 1 WHEN dir050to_raw <= 0 THEN 2
           WHEN dir050to_raw <= 2 THEN 3 ELSE 4 END AS cat_050to,
      -- DIR057: conteo direcciones
      CASE WHEN dir057 IS NULL THEN 1 WHEN dir057 <= 1 THEN 2 WHEN dir057 <= 5 THEN 3
           WHEN dir057 <= 7 THEN 4 WHEN dir057 <= 16 THEN 5 ELSE 6 END AS cat_057,
      -- DIR059: % reportes dirección
      CASE WHEN dir059 IS NULL OR dir059 <= 22.83 THEN 1 WHEN dir059 <= 39.87 THEN 2
           WHEN dir059 <= 52.87 THEN 3 WHEN dir059 <= 58.52 THEN 4 ELSE 5 END AS cat_059,
      -- DIR009: entidades
      CASE WHEN dir009 IS NULL THEN 1 WHEN dir009 <= 1 THEN 2 ELSE 3 END AS cat_009
    FROM base
  ),

  -- Pesos: (cat / max_cat) × Beta
  scored AS (
    SELECT
      c.cod_dw_persona_ubic, c.cod_pin_persona, c.id_buro_persona,
      COALESCE((CAST(c.cat_001in AS FLOAT) / 3) * b01.valor_beta, 0)
      + COALESCE((CAST(c.cat_004ro AS FLOAT) / 3) * b04.valor_beta, 0)
      + COALESCE((CAST(c.cat_007to AS FLOAT) / 6) * b07.valor_beta, 0)
      + COALESCE((CAST(c.cat_010fi AS FLOAT) / 3) * b10.valor_beta, 0)
      + COALESCE((CAST(c.cat_013ot AS FLOAT) / 5) * b13.valor_beta, 0)
      + COALESCE((CAST(c.cat_017   AS FLOAT) / 3) * b17.valor_beta, 0)
      + COALESCE((CAST(c.cat_019   AS FLOAT) / 2) * b19.valor_beta, 0)
      + COALESCE((CAST(c.cat_034fi AS FLOAT) / 3) * b34.valor_beta, 0)
      + COALESCE((CAST(c.cat_050to AS FLOAT) / 4) * b50.valor_beta, 0)
      + COALESCE((CAST(c.cat_057   AS FLOAT) / 6) * b57.valor_beta, 0)
      + COALESCE((CAST(c.cat_059   AS FLOAT) / 5) * b59.valor_beta, 0)
      + COALESCE((CAST(c.cat_009   AS FLOAT) / 3) * b09.valor_beta, 0)
      AS score
    FROM categorized c
    LEFT JOIN bdm_datos.beta_ordenamiento b01 ON b01.canal='DIR' AND b01.cod_caracteristica='CO00DIR001IN'
    LEFT JOIN bdm_datos.beta_ordenamiento b04 ON b04.canal='DIR' AND b04.cod_caracteristica='CO00DIR004RO'
    LEFT JOIN bdm_datos.beta_ordenamiento b07 ON b07.canal='DIR' AND b07.cod_caracteristica='CO00DIR007TO'
    LEFT JOIN bdm_datos.beta_ordenamiento b10 ON b10.canal='DIR' AND b10.cod_caracteristica='CO00DIR010FI'
    LEFT JOIN bdm_datos.beta_ordenamiento b13 ON b13.canal='DIR' AND b13.cod_caracteristica='CO00DIR013OT'
    LEFT JOIN bdm_datos.beta_ordenamiento b17 ON b17.canal='DIR' AND b17.cod_caracteristica='CO00DIR017'
    LEFT JOIN bdm_datos.beta_ordenamiento b19 ON b19.canal='DIR' AND b19.cod_caracteristica='CO00DIR019'
    LEFT JOIN bdm_datos.beta_ordenamiento b34 ON b34.canal='DIR' AND b34.cod_caracteristica='CO00DIR034FI'
    LEFT JOIN bdm_datos.beta_ordenamiento b50 ON b50.canal='DIR' AND b50.cod_caracteristica='CO00DIR050TO'
    LEFT JOIN bdm_datos.beta_ordenamiento b57 ON b57.canal='DIR' AND b57.cod_caracteristica='CO00DIR057'
    LEFT JOIN bdm_datos.beta_ordenamiento b59 ON b59.canal='DIR' AND b59.cod_caracteristica='CO00DIR059'
    LEFT JOIN bdm_datos.beta_ordenamiento b09 ON b09.canal='DIR' AND b09.cod_caracteristica='CO01DIR009'
  )

  SELECT
    cod_dw_persona_ubic,
    cod_pin_persona,
    id_buro_persona,
    'DIR' AS canal,
    CAST(score AS DECIMAL(18,4)),
    ROW_NUMBER() OVER (PARTITION BY id_buro_persona ORDER BY score DESC) AS lugar
  FROM scored;
END;
$$;
-- SLCOPRBA-1355: re-DPLY DEV post DROP SCHEMA strct #256
