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
      -- DIR002TO (Caracteristicas.txt:2916): MAX de meses_reporte de ESTA
      -- direccion, con guarda de texto vacio. Antes era COUNT(*), que es otra
      -- magnitud: un conteo, no una recencia. No estaba en la lista de las
      -- seis; entra porque alimenta DIR059.
      MAX(CASE WHEN direccion_fisica <> '' THEN meses_reporte ELSE NULL END) AS dir002to,
      -- Conteo de reportes de la direccion. Unico insumo de DIR050TO, que se
      -- deja como estaba: el DIR050TO del legado (:3117-3121) necesita
      -- CO00MOR037/CO00MOR038 de Insumo_Caracteristica, que es F1-F3 y no
      -- tenemos. Se aisla aqui para que el arreglo de DIR002TO no lo corrompa
      -- en silencio.
      COUNT(*) AS cnt_reportes,
      SUM(CASE WHEN meses_reporte <= 12 THEN 1 ELSE 0 END) AS dir004ro,
      -- DIR007TO (:2919): ventana de 24 meses, no de 6, y con guarda de texto
      -- vacio que devuelve NULL (no 0) a la direccion vacia -- la categoria
      -- distingue NULL de 0 (:2664-2665), asi que la diferencia puntua.
      SUM(CASE WHEN direccion_fisica <> ''
               THEN (CASE WHEN meses_reporte <= 24 THEN 1 ELSE 0 END)
               ELSE NULL END) AS dir007to,
      CAST(100.0 * SUM(CASE WHEN sector_financiero = 1 THEN 1 ELSE 0 END)
        / NULLIF(COUNT(*), 0) AS DECIMAL(18,2)) AS dir010fi,
      CAST(100.0 * SUM(CASE WHEN sector_financiero = 0 THEN 1 ELSE 0 END)
        / NULLIF(COUNT(*), 0) AS DECIMAL(18,2)) AS dir013ot,
      -- DIR017 (:1795): conteo de reportes de tipo 'LAB' de esta direccion.
      -- No es un codigo ordinal de tipo de ubicacion.
      SUM(CASE WHEN TRIM(tipo_ubicacion) = 'LAB' AND direccion_fisica <> ''
               THEN 1 ELSE NULL END) AS dir017,
      -- DIR016 (:1794): no puntua por si misma, pero es el insumo de DIR009.
      SUM(CASE WHEN TRIM(tipo_ubicacion) = 'CRR' AND direccion_fisica <> ''
               THEN 1 ELSE NULL END) AS dir016,
      -- DIR019 (:1796-1799): bandera 0/1 -- la direccion esta reportada a la
      -- vez como 'RES' y como 'CRR'. No tiene nada que ver con la recencia.
      CASE WHEN SUM(CASE WHEN TRIM(tipo_ubicacion) = 'RES' AND direccion_fisica <> ''
                         THEN 1 ELSE NULL END) > 0
            AND SUM(CASE WHEN TRIM(tipo_ubicacion) = 'CRR' AND direccion_fisica <> ''
                         THEN 1 ELSE NULL END) > 0
           THEN 1 ELSE 0 END AS dir019,
      CAST(100.0 * SUM(CASE WHEN sector_financiero = 1 AND meses_reporte <= 12 THEN 1 ELSE 0 END)
        / NULLIF(SUM(CASE WHEN meses_reporte <= 12 THEN 1 ELSE 0 END), 0) AS DECIMAL(18,2)) AS dir034fi,
      -- DIR057 (:485-487): conteo de reportes no vacios de ESTA direccion.
      -- Estaba a grano de persona (numero de direcciones distintas), que es
      -- otra cosa: el legado agrupa por (persona, Direccion_Fisica) en :489.
      SUM(CASE WHEN direccion_fisica <> '' THEN 1 ELSE NULL END) AS dir057
      -- DIR009 sale de aqui: el legado lo calcula a grano de PERSONA
      -- (GROUP BY 1,2 en :2396) y lo reparte a todas sus direcciones.
      -- Ver persona_stats.
    FROM bdm_tempo.stg_insumo_direccion
    GROUP BY id_buro_persona, direccion_fisica
  ),

  -- Métricas a nivel persona (window functions separadas del GROUP BY)
  persona_stats AS (
    SELECT id_buro_persona,
      SUM(cnt_reportes) AS dir050to,
      -- DIR009 (:2390-2396): cuantas direcciones de la persona son de
      -- correspondencia, es decir tienen al menos un reporte 'CRR'. Antes era
      -- COUNT(DISTINCT id_buro_suscriptor), que ademas colgaba de la cubeta de
      -- hash documentada como ruido.
      SUM(CASE WHEN direccion_fisica <> '' AND dir016 > 0 THEN 1 ELSE 0 END) AS dir009
    FROM base_agg
    GROUP BY id_buro_persona
  ),

  -- Extremos de recencia por PERSONA, sobre las filas de reporte.
  -- Portado de REC_STAGE.TMP_V_DIR_VDDF_PIDR (:3000-3005). Son los Valor1,
  -- Valor2 y Suma de DIR059. Se agrega desde el insumo, no desde base_agg:
  -- el legado toma el MAX/MIN de Meses_Reporte de todas las filas de la
  -- persona, no de los maximos por direccion.
  persona_dir AS (
    SELECT id_buro_persona,
      MAX(meses_reporte) AS valor1,
      MIN(meses_reporte) AS valor2,
      COUNT(*)           AS suma
    FROM bdm_tempo.stg_insumo_direccion
    GROUP BY id_buro_persona
  ),

  base AS (
    SELECT
      a.*,
      p.dir050to AS dir050to_raw,
      p.dir009,
      -- DIR059 (:439-444): normalizacion min-max de la recencia de la
      -- direccion contra el rango de recencias de la persona, NO un porcentaje
      -- de reportes. Vale 100 cuando la persona tiene una sola recencia, y
      -- crece cuanto MAS RECIENTE es la direccion (dir002to bajo => numerador
      -- alto), que es lo que la escala de categorias premia.
      CAST(100.0 * (CASE WHEN pd.valor1 = pd.valor2 AND pd.suma <> 0 THEN 1.0
                         WHEN pd.suma = 0 THEN NULL
                         ELSE CAST(pd.valor1 - a.dir002to AS DECIMAL(18,6))
                              / NULLIF(pd.valor1 - pd.valor2, 0)
                    END) AS DECIMAL(18,2)) AS dir059
    FROM base_agg a
    JOIN persona_stats p ON a.id_buro_persona = p.id_buro_persona
    JOIN persona_dir  pd ON a.id_buro_persona = pd.id_buro_persona
  ),

  -- Categorización (CASE WHEN → 1..N)
  categorized AS (
    SELECT
      cod_dw_persona_ubic, cod_pin_persona, id_buro_persona, direccion_fisica,
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
      -- DIR019: el legado NO tiene tabla _Cat para esta. Su _Peso (:456) usa
      -- el valor crudo 0/1 con divisor 2. El mapeo 0->1 / 1->2 que habia aqui
      -- sumaba beta/2 constante a TODAS las filas: no movia el ranking, pero
      -- no era el score del legado.
      dir019 AS cat_019,
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
      c.cod_dw_persona_ubic, c.cod_pin_persona, c.id_buro_persona, c.direccion_fisica,
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
                                direccion_fisica,
                                cod_dw_persona_ubic) AS lugar
  FROM scored;
END;
$$;
-- SLCOPRBA-1355: re-DPLY DEV post DROP SCHEMA strct #256
