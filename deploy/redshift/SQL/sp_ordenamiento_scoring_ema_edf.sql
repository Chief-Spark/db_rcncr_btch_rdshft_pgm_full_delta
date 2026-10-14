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
  -- SLCOPRBA-1355: los contadores de ventana POR PERSONA del legado.
  --
  -- El legado los lleva en REC_STAGE.NUM_TOTAL_REPORTE, construidos asi
  -- (Caracteristicas.txt:380-400, bloque NUM_TOTAL_REPORTE_CEL, identico para
  -- los demas canales): cuenta de filas de reporte DE LA PERSONA -- todos sus
  -- contactos del canal -- dentro de cada ventana, agrupando por
  -- (Cod_Pin_Persona, Id_Buro_Persona).
  --
  -- Son el DENOMINADOR de cinco caracteristicas de EMA. Sin ellos no se puede
  -- expresar la magnitud que el legado mide, que es una CUOTA: "que parte de
  -- los reportes de esta persona en esta ventana corresponden a este correo".
  ventanas AS (
    SELECT id_buro_persona,
           SUM(CASE WHEN meses_reporte <=  3 THEN 1 ELSE 0 END) AS tr_3,
           SUM(CASE WHEN meses_reporte <=  6 THEN 1 ELSE 0 END) AS tr_6,
           SUM(CASE WHEN meses_reporte <= 12 THEN 1 ELSE 0 END) AS tr_12,
           SUM(CASE WHEN meses_reporte <= 24 THEN 1 ELSE 0 END) AS tr_24,
           SUM(CASE WHEN meses_reporte >  24 THEN 1 ELSE 0 END) AS tr_24m
      FROM bdm_tempo.stg_insumo_email
     GROUP BY id_buro_persona
  ),
  base_agg AS (
    SELECT
      MIN(e.cod_dw_persona_ubic) AS cod_dw_persona_ubic,
      MIN(e.cod_pin_persona) AS cod_pin_persona,
      e.id_buro_persona,
      e.email,
      MAX(e.meses_reporte) AS ema003,
      SUM(CASE WHEN e.meses_reporte <= 6 THEN 1 ELSE 0 END) AS ema007,
      -- EMA010/014/015/016/017 reescritas contra Caracteristicas.txt:1718-1742.
      -- GREATEST(x, 1) es el CASE WHEN divisor > 0 THEN divisor ELSE 1 END del
      -- legado: con cero reportes en la ventana el termino vale 0 de todas
      -- formas, y asi no hay division por cero.
      CAST(100.0 * SUM(CASE WHEN e.meses_reporte <= 12
                            THEN 1.0 / GREATEST(v.tr_12, 1) ELSE 0 END) AS DECIMAL(18,2)) AS ema010,
      CAST(100.0 * SUM(CASE WHEN e.meses_reporte > 24
                            THEN 1.0 / GREATEST(v.tr_24m, 1) ELSE 0 END) AS DECIMAL(18,2)) AS ema014,
      CAST(100.0 * SUM(CASE WHEN e.meses_reporte > 3 AND e.meses_reporte <= 6
                            THEN 1.0 / GREATEST(v.tr_6 - v.tr_3, 1) ELSE 0 END) AS DECIMAL(18,2)) AS ema015,
      CAST(100.0 * SUM(CASE WHEN e.meses_reporte > 6 AND e.meses_reporte <= 12
                            THEN 1.0 / GREATEST(v.tr_12 - v.tr_6, 1) ELSE 0 END) AS DECIMAL(18,2)) AS ema016,
      CAST(100.0 * SUM(CASE WHEN e.meses_reporte > 12 AND e.meses_reporte <= 24
                            THEN 1.0 / GREATEST(v.tr_24 - v.tr_12, 1) ELSE 0 END) AS DECIMAL(18,2)) AS ema017,
      MAX(CASE WHEN e.meses_reporte <= 3 THEN 1 ELSE 0 END) AS ema018,
      COUNT(*) AS ema020_raw,
      COUNT(*) AS ema021_raw,
      MAX(CASE WHEN e.sector_financiero = 1 THEN 1 ELSE 0 END) AS ema023_raw,
      MAX(CASE WHEN e.dominio NOT IN ('gmail.com','hotmail.com','yahoo.com','outlook.com') THEN 1 ELSE 0 END) AS ema024,
      CAST(100.0 * MIN(e.meses_reporte) / NULLIF(MAX(e.meses_reporte), 0) AS DECIMAL(18,2)) AS ema025
    FROM bdm_tempo.stg_insumo_email e
    INNER JOIN ventanas v ON v.id_buro_persona = e.id_buro_persona
    GROUP BY e.id_buro_persona, e.email
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
    SELECT cod_dw_persona_ubic, cod_pin_persona, id_buro_persona, email,
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
    SELECT c.cod_dw_persona_ubic, c.cod_pin_persona, c.id_buro_persona, c.email,
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
    -- DESEMPATE EXPLICITO Y NULLS LAST. Dos divergencias deliberadas frente al
    -- legado, las dos obligadas:
    --
    --   1) El legado ordena solo por 'score DESC' (Caracteristicas.txt:105, :79,
    --      :72, :88), sin columna de desempate. Con dos scores iguales -- y los
    --      empates son FRECUENTES, porque la categoria es un entero pequeno
    --      sobre un divisor fijo y el espacio de scores es discreto -- el lugar
    --      lo decide el orden fisico de los AMP. Eso NO es reproducible ni en el
    --      propio Teradata: dos corridas del mismo lote pueden intercambiar el 1
    --      y el 2. No hay comportamiento que copiar, asi que se fija uno:
    --      cod_dw_persona_ubic ascendente, que es unico dentro del grupo.
    --      Lo exigen RG-03 y CA-F04 (idempotencia).
    --
    --   2) NULLS LAST es DEFENSIVO, no correctivo: hoy no cambia nada. Redshift
    --      pone NULLS FIRST por defecto en ORDER BY ... DESC y Teradata hace lo
    --      contrario, pero aqui el score NUNCA es NULL porque cada termino va
    --      envuelto en COALESCE(..., 0): un beta ausente aporta cero, no NULL.
    --      Se deja escrito para el dia que alguien quite uno de esos COALESCE
    --      -- que es justo lo que hace el legado, cuya sumatoria enlaza los
    --      terminos con LEFT JOIN y los suma con '+' desnudo, de modo que un
    --      beta ausente le anula el score del canal entero.
    --
    --   3) Se ordena por el score YA REDONDEADO a DECIMAL(18,4), que es el que
    --      se persiste. La suma interna es FLOAT (cada termino es
    --      CAST(cat AS FLOAT)/div * beta) y la columna de salida es
    --      DECIMAL(18,4): ordenar por el FLOAT dejaria pares de filas que se
    --      guardan con el MISMO score y distinto lugar, por una diferencia que
    --      ya no existe en la tabla. El ranking tiene que ser funcion del valor
    --      que se guarda, o no hay forma de verificarlo leyendo la salida.
    --
    --   4) SLCOPRBA-1355: el desempate es la CLAVE DEL GRUPO, no la RPU.
    --      cod_dw_persona_ubic entra como MIN() sobre el GROUP BY, de modo que
    --      dos grupos distintos de la misma persona pueden compartirlo: una
    --      persona con dos celulares en la misma RPU, o con dos correos. Ahi el
    --      ORDER BY no determinaba nada y el lugar quedaba al azar del orden
    --      fisico. Medido en el banco local: 578 filas de 298 000 con el lugar
    --      distinto de un recalculo determinista, creciendo de 434 a 578 entre
    --      FULL y DELTA2. La clave del grupo SI es unica dentro de
    --      (persona, canal) por construccion, asi que el ranking vuelve a ser
    --      reproducible. cod_dw_persona_ubic se queda detras: no estorba y
    --      conserva el comportamiento donde la clave ya desempataba.
    ROW_NUMBER() OVER (PARTITION BY id_buro_persona
                       ORDER BY CAST(score AS DECIMAL(18,4)) DESC NULLS LAST,
                                email,
                                cod_dw_persona_ubic)
  FROM scored;
END;
$$;
-- SLCOPRBA-1355: re-DPLY DEV post DROP SCHEMA strct #256
