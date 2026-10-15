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
  -- SLCOPRBA-1355: TRES GRANOS DE DIVISOR CONVIVEN EN ESTE CANAL.
  --   persona            -> TEL001 (total_reporte), TEL006 (tr_3), TEL010 (tr_12)
  --   telefono           -> TEL017 y TEL019 (total_reportes_telefono)
  --   maximo entre los
  --   telefonos de la
  --   persona            -> TEL023 y TEL025
  -- Confundirlos es lo que tenia a nueve de las once caracteristicas mal.

  -- Totales por PERSONA. Portado de REC_STAGE.Calculo_Meses1
  -- (Caracteristicas.txt:2676-2684) y del subselect de REC_STAGE.calculo_total
  -- (:1680-1686). Ojo: total_reporte SI filtra por gestion valida y los
  -- tr_* NO -- es asi en el legado, y la diferencia se nota.
  persona_tel AS (
    SELECT t.id_buro_persona,
      SUM(CASE WHEN (t.descripcion_gestion <> 'NO VALIDA' OR t.descripcion_gestion IS NULL) THEN 1 ELSE 0 END) AS total_reporte,
      SUM(CASE WHEN t.meses_reporte <=  3 THEN 1 ELSE 0 END) AS tr_3,
      SUM(CASE WHEN t.meses_reporte <=  6 THEN 1 ELSE 0 END) AS tr_6,
      SUM(CASE WHEN t.meses_reporte <= 12 THEN 1 ELSE 0 END) AS tr_12,
      MAX(CASE WHEN (t.descripcion_gestion <> 'NO VALIDA' OR t.descripcion_gestion IS NULL) THEN t.meses_reporte ELSE NULL END) AS max_meses_persona
    FROM bdm_tempo.stg_insumo_telefono t
    GROUP BY t.id_buro_persona
  ),

  -- Agregado por PERSONA + TELEFONO, que es la llave del legado
  -- (REC_STAGE.Calculo_Meses2, :2252-2262: agrupa por Direccion_Fisica y al
  -- resultado lo llama Total_Reportes_Telefono).
  base_agg AS (
    SELECT
      MIN(t.cod_dw_persona_ubic) AS cod_dw_persona_ubic,
      MIN(t.cod_pin_persona) AS cod_pin_persona,
      t.id_buro_persona,
      t.telefono,
      MIN(t.direccion_fisica) AS direccion_fisica,
      COUNT(*) AS n_reportes,
      SUM(CASE WHEN (t.descripcion_gestion <> 'NO VALIDA' OR t.descripcion_gestion IS NULL) THEN 1 ELSE 0 END) AS total_reportes_telefono,
      -- TEL002 (:1441): MIN de meses_reporte. Antes era un conteo de validos.
      MIN(t.meses_reporte) AS tel002,
      -- TEL003 (:554): MAX de meses_reporte. Ya estaba bien.
      MAX(t.meses_reporte) AS tel003,
      SUM(CASE WHEN t.meses_reporte <=  3 THEN 1 ELSE 0 END) AS cnt_3,
      -- TEL007 (:249): conteo pelado <= 6 meses. Ya estaba bien.
      SUM(CASE WHEN t.meses_reporte <=  6 THEN 1 ELSE 0 END) AS tel007,
      SUM(CASE WHEN t.meses_reporte <= 12 THEN 1 ELSE 0 END) AS cnt_12,
      SUM(CASE WHEN TRIM(t.tipo_ubicacion) = 'RES' THEN 1 ELSE 0 END) AS cnt_res,
      SUM(CASE WHEN TRIM(t.tipo_ubicacion) = 'LAB' THEN 1 ELSE 0 END) AS cnt_lab,
      -- TEL020 (:2137): bandera por 100. No entra en el score, ni aqui ni en
      -- el legado (:2830-2834); se calcula porque el tablero la mira.
      CASE WHEN SUM(t.coincidencia_geo) > 0 THEN 1 ELSE 0 END AS geo_flag,
      -- TEL023 (:220 y :924-932): suscriptores distintos de ESTE telefono.
      COUNT(DISTINCT CASE WHEN (t.descripcion_gestion <> 'NO VALIDA' OR t.descripcion_gestion IS NULL) THEN t.id_buro_suscriptor END) AS locals_023,
      -- TEL025 (:714 y :2054-2068): la recencia mas vieja de ESTE telefono.
      MAX(CASE WHEN (t.descripcion_gestion <> 'NO VALIDA' OR t.descripcion_gestion IS NULL) THEN t.meses_reporte ELSE NULL END) AS max_meses_tel
    FROM bdm_tempo.stg_insumo_telefono t
    GROUP BY t.id_buro_persona, t.telefono
  ),

  -- El divisor de TEL023 es el MAXIMO de locals entre los telefonos de la
  -- persona (REC_STAGE.CO01TEL023_3, :1466-1478), no la suma.
  persona_max AS (
    SELECT id_buro_persona, MAX(locals_023) AS total_023
    FROM base_agg
    GROUP BY id_buro_persona
  ),

  base AS (
    SELECT
      a.cod_dw_persona_ubic, a.cod_pin_persona, a.id_buro_persona,
      a.telefono, a.direccion_fisica,
      a.tel002, a.tel003, a.tel007,
      -- TEL001 (:588): el legado escribe SUM(1/total_reporte) sobre las filas
      -- del grupo; como el divisor es constante dentro de la persona, es
      -- COUNT(*)/total_reporte. Divisor de PERSONA, y SIN filtro de validez en
      -- el numerador -- lo que teniamos dividia el grupo por si mismo.
      CAST(100.0 * a.n_reportes / NULLIF(p.total_reporte, 0) AS DECIMAL(18,2)) AS tel001,
      -- TEL006 (:940-945): ventana <= 3 (no 12) sobre tr_3 de PERSONA.
      CAST(100.0 * a.cnt_3  / GREATEST(p.tr_3,  1) AS DECIMAL(18,2)) AS tel006,
      -- TEL010 (:2972-2977): ventana <= 12 sobre tr_12 de PERSONA. No tiene
      -- nada que ver con coincidencia_geo, que es lo que miraba antes.
      CAST(100.0 * a.cnt_12 / GREATEST(p.tr_12, 1) AS DECIMAL(18,2)) AS tel010,
      -- TEL017 (:2296-2298): cuota de reportes 'RES' sobre el total de ESTE
      -- telefono. Antes miraba sector_financiero.
      CAST(100.0 * a.cnt_res / NULLIF(a.total_reportes_telefono, 0) AS DECIMAL(18,2)) AS tel017,
      -- TEL019 (:2300-2302): idem con 'LAB'. Antes miraba tipo_cuenta.
      CAST(100.0 * a.cnt_lab / NULLIF(a.total_reportes_telefono, 0) AS DECIMAL(18,2)) AS tel019,
      100 * a.geo_flag AS tel020,
      -- TEL023 (:220): suscriptores de este telefono contra el maximo de la
      -- persona. DIVERGENCIA ANOTADA: el legado usa Cod_Suscriptor de
      -- CTA_TOTALES_PERSONAS_TMP3 (:1979), que es datashare; aqui va
      -- id_buro_suscriptor, que es la cubeta de hash ya documentada como
      -- ruido. La FORMA queda portada; el dato espera a F2.
      CAST(100.0 * a.locals_023 / NULLIF(m.total_023, 0) AS DECIMAL(18,2)) AS tel023,
      -- TEL025 (:714): (max de la persona - max de este telefono) / max de la
      -- persona. Premia al telefono MAS RECIENTE. Antes era MIN/MAX dentro del
      -- grupo, que no compara con nada.
      CAST(100.0 * (CAST(p.max_meses_persona AS DECIMAL(18,6)) - a.max_meses_tel)
           / NULLIF(p.max_meses_persona, 0) AS DECIMAL(18,2)) AS tel025
    FROM base_agg a
    JOIN persona_tel p ON p.id_buro_persona = a.id_buro_persona
    JOIN persona_max m ON m.id_buro_persona = a.id_buro_persona
  ),
  -- Umbrales de categoria: ya coincidian con el legado uno a uno y NO se
  -- tocan (:57-70, :1313-1325, :1773-1785, :2205-2217, :121-133, :856-868,
  -- :765-778, :1482-1494, :413-421, :2402-2414, :168-180). Lo que estaba mal
  -- eran los valores que entraban aqui.
  categorized AS (
    SELECT cod_dw_persona_ubic, cod_pin_persona, id_buro_persona, telefono, direccion_fisica,
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
    FROM base
  ),
  scored AS (
    SELECT c.cod_dw_persona_ubic, c.cod_pin_persona, c.id_buro_persona, c.telefono, c.direccion_fisica,
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
                                telefono,
                                cod_dw_persona_ubic)
  FROM scored;
END;
$$;
-- SLCOPRBA-1355: re-DPLY DEV post DROP SCHEMA strct #256
