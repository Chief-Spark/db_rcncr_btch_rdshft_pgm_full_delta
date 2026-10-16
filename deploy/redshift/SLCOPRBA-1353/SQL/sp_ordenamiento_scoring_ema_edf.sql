-- 14_sp_ordenamiento_scoring_ema_edf.sql (generado - staging EDF, una lectura datashare en preparar)
-- Regenerar: py -3 tools/gen_ordenamiento_sps_edf.py

CREATE OR REPLACE PROCEDURE bdm_datos.sp_ordenamiento_scoring_ema_edf()
NONATOMIC
LANGUAGE plpgsql
AS $$
BEGIN
  -- ============================================================
  -- 05_scoring_ema.sql - Scoring Email (canal EMA)
  -- 38 sentencias Teradata -> 1 query con CTEs
  -- 13 caracteristicas: EMA003-EMA025
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
           SUM(CASE WHEN meses_reporte >  24 THEN 1 ELSE 0 END) AS tr_24m,
           -- Divisor de EMA023 (Caracteristicas.txt:2029-2036): la recencia
           -- MAS VIEJA entre TODOS los correos de la persona.
           MAX(meses_reporte) AS max_meses_persona
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
      -- EMA018 (:1090-1094): el dominio es de proveedor masivo. Antes era una
      -- bandera de recencia <= 3 meses, que no se parece en nada. El legado
      -- compara la parte anterior al primer punto, no el dominio entero.
      -- FUERA DE LA SUMA en el legado (:2936, literal 0) y aqui: se corrige
      -- por fidelidad, no cambia ningun score.
      MAX(CASE WHEN SPLIT_PART(e.dominio, '.', 1)
                    IN ('hotmail','gmail','yahoo','live','outlook')
               THEN 1 ELSE 0 END) * 100 AS ema018,
      -- EMA020 (:2703-2706): BLOQUEADA. El legado la lee de
      -- REC_VISTA.V_Ind_Efectiv_Orden_Peso_Email cruzando
      -- Gestion_Contactabilidad (:2713-2714). No tenemos ni la vista ni la
      -- columna. Lo que hay aqui es una invencion nuestra y su categoria
      -- tampoco es la del legado, que usa una cubeta NEGATIVA (-1) y deja un
      -- hueco entre 0 y 9 (:686-696). Portar la categoria sin el valor daria
      -- un score peor, no mejor. Espera al datashare.
      COUNT(*) AS ema020_raw,
      -- EMA021 (Caracteristicas.txt:235): suma de banderas por tipo de
      -- cuenta, 50/25/12/8/5, maximo 100. Ya NO esta bloqueada: el tipo de
      -- cuenta llega por location.val.accounttype. Lo que habia aqui era un
      -- COUNT(*), que no es esta caracteristica ni ninguna otra.
      --
      -- LA ASIMETRIA DEL '23' ES DEL LEGADO Y SE PORTA LITERAL. Cuatro de
      -- las cinco ramas hacen "cast(Cod_Tipo_Cta_Fte as integer) = '1'"; la
      -- del 23 compara la cadena cruda, "Cod_Tipo_Cta_Fte = '23'". Con un
      -- valor '023' las otras cuatro aciertan y esa falla. Manda el codigo.
      --   El CAST va guardado por el mismo motivo que en CEL019: en Redshift
      --   un valor sucio aborta la sentencia en vez de dar NULL (job #293).
      CASE WHEN SUM(CASE WHEN e.tipo_cta_num = 1 THEN 1 ELSE 0 END) >= 1 THEN 50 ELSE 0 END
      + CASE WHEN SUM(CASE WHEN e.tipo_cta_num = 2 THEN 1 ELSE 0 END) >= 1 THEN 25 ELSE 0 END
      + CASE WHEN SUM(CASE WHEN e.tipo_cta_num = 6 THEN 1 ELSE 0 END) >= 1 THEN 12 ELSE 0 END
      + CASE WHEN SUM(CASE WHEN e.cod_tipo_cta_fte = '23' THEN 1 ELSE 0 END) >= 1 THEN 8 ELSE 0 END
      + CASE WHEN SUM(CASE WHEN e.tipo_cta_num = 5 THEN 1 ELSE 0 END) >= 1 THEN 5 ELSE 0 END
        AS ema021_raw,
      -- EMA024 (:1406-1433): suscriptores distintos de ESTE correo. El
      -- divisor sale en persona_ema. Antes era una bandera de dominio
      -- corporativo, que es la logica de EMA018 mal colocada.
      COUNT(DISTINCT e.id_buro_suscriptor) AS locals_024,
      -- EMA025 (:1060-1071): escalon sobre el LARGO del buzon, no una razon
      -- de recencias. Ojo: la escala NO es monotona (5, 20, 34, 30, 10, 3) y
      -- se porta literal. FUERA DE LA SUMA en ambos (:2938).
      --   DIVERGENCIA ANOTADA: el legado toma Buzon de
      --   REC_VISTA.V_DIRECCION_ELECTRONICA (:2101-2102); aqui se deriva del
      --   propio correo, que es el mismo dato sin la vista.
      MAX(CASE
            WHEN LENGTH(TRIM(SPLIT_PART(e.email, '@', 1))) <  7 THEN  5
            WHEN LENGTH(TRIM(SPLIT_PART(e.email, '@', 1))) <  9 THEN 20
            WHEN LENGTH(TRIM(SPLIT_PART(e.email, '@', 1))) < 12 THEN 34
            WHEN LENGTH(TRIM(SPLIT_PART(e.email, '@', 1))) < 16 THEN 30
            WHEN LENGTH(TRIM(SPLIT_PART(e.email, '@', 1))) < 20 THEN 10
            ELSE 3
          END) AS ema025
    FROM (
      SELECT i.*,
             -- El CAST guardado que exige EMA021. Se hace aqui y no en el
             -- SELECT de arriba para no repetirlo cinco veces.
             CASE WHEN TRIM(i.cod_tipo_cta_fte) ~ '^[0-9]+$'
                   AND LENGTH(TRIM(i.cod_tipo_cta_fte)) <= 9
                  THEN CAST(TRIM(i.cod_tipo_cta_fte) AS INTEGER)
                  ELSE NULL END AS tipo_cta_num
      FROM bdm_tempo.stg_insumo_email i
    ) e
    INNER JOIN ventanas v ON v.id_buro_persona = e.id_buro_persona
    GROUP BY e.id_buro_persona, e.email
  ),
  persona_ema AS (
    SELECT id_buro_persona,
      SUM(ema020_raw) AS total_rep,
      -- Divisor de EMA024 (:1424-1432): el MAYOR conteo de suscriptores
      -- entre los correos de la persona. No es la suma; el "mejor" correo
      -- saca 100 por construccion.
      MAX(locals_024) AS total_024
    FROM base_agg GROUP BY 1
  ),
  base AS (
    SELECT a.*,
      CAST(100.0 * a.ema020_raw / NULLIF(p.total_rep, 0) AS DECIMAL(18,2)) AS ema020,
      a.ema021_raw AS ema021,
      -- EMA023 (:2007-2008): (recencia mas vieja de la PERSONA - la de ESTE
      -- correo) / la de la persona. Premia al correo mas reciente, y es la
      -- misma forma que TEL025. Antes miraba sector_financiero, que el legado
      -- no toca en esta caracteristica.
      CAST(100.0 * (CAST(v.max_meses_persona AS DECIMAL(18,6)) - a.ema003)
           / NULLIF(v.max_meses_persona, 0) AS DECIMAL(18,2)) AS ema023,
      -- EMA024: ver base_agg. Misma forma que TEL023.
      --   DIVERGENCIA ANOTADA: el legado cuenta Codigo_Suscriptor
      --   (:842, columna de la propia vista de correos); aqui va
      --   id_buro_suscriptor, la cubeta de hash documentada como ruido.
      CAST(100.0 * a.locals_024 / NULLIF(p.total_024, 0) AS DECIMAL(18,2)) AS ema024
    FROM base_agg a
    JOIN persona_ema p ON a.id_buro_persona = p.id_buro_persona
    JOIN ventanas v ON v.id_buro_persona = a.id_buro_persona
  ),
  categorized AS (
    SELECT cod_dw_persona_ubic, cod_pin_persona, id_buro_persona, email,
      CASE WHEN ema003 <= 26 THEN 1 WHEN ema003 <= 39 THEN 2 WHEN ema003 <= 54 THEN 3 WHEN ema003 > 54 THEN 4 ELSE 0 END AS c03,
      CASE WHEN ema007 <= 0 THEN 1 WHEN ema007 <= 1 THEN 2 WHEN ema007 <= 2 THEN 3 WHEN ema007 > 2 THEN 4 ELSE 0 END AS c07,
      CASE WHEN ema010 <= 1 THEN 1 WHEN ema010 <= 2 THEN 2 WHEN ema010 <= 3 THEN 3 WHEN ema010 > 3 THEN 4 ELSE 0 END AS c10,
      -- LAS CUATRO CATEGORIZACIONES DE ABAJO ESTABAN INVENTADAS
      -- (SLCOPRBA-1355). Las FORMULAS que las alimentan siempre fueron
      -- correctas -- misma ventana, mismo divisor, mismo *100, mismo
      -- DECIMAL(18,2) que el legado (Caracteristicas.txt:1723-1742) -- y los
      -- divisores de la suma tambien (/4 en los cuatro, :679 :700 :1852
      -- :3107). Lo unico que estaba mal era el CASE, y eran 229,51 puntos de
      -- beta mal asignados. Ahora son los de Caracteristicas.txt:1005-1024.
      --
      -- EMA014 (:1005-1012). Era `= 1 THEN 4 ELSE 1`: una bandera binaria
      -- olvidada comparada contra un porcentaje 0..100, de modo que solo
      -- disparaba con un 1,00% exacto. Con beta NEGATIVA (-130,80) el legado
      -- castiga al correo con mas del 85% de sus reportes por encima de 24
      -- meses -- buzon muerto --, y el nuestro no castigaba a casi nadie.
      CASE WHEN ema014 <= 8.33 THEN 1 WHEN ema014 <= 41.18 THEN 2
           WHEN ema014 <= 85 THEN 3 WHEN ema014 > 85 THEN 4 ELSE 0 END AS c14,
      -- EMA015 (:1013-1015) y EMA016 (:1016-1018) son BINARIAS en el legado,
      -- de la misma familia que CEL015, CEL017 y CEL023: saltan 1 -> 4 y se
      -- dividen entre 4, asi que el salto vale 3/4 de beta de golpe.
      -- Nosotros las graduabamos en cuatro bandas inventadas, y el `< 1` de
      -- EMA016 ni siquiera reproducia el `<= 0`: un 0,5% caia en 1 donde el
      -- legado da 4.
      CASE WHEN ema015 <= 0 THEN 1 ELSE 4 END AS c15,
      CASE WHEN ema016 <= 0 THEN 1 ELSE 4 END AS c16,
      -- EMA017 (:1019-1024) TOPA EN 3 y divide entre 4 (:679), de modo que
      -- aporta como mucho el 75% de su beta. Es el TERCER caso de esa familia
      -- junto a CEL019 y CEL006. Defecto del legado: se porta tal cual.
      -- Nosotros llegabamos a 4 y sobre-penalizabamos (beta -30,56).
      CASE WHEN ema017 <= 0 THEN 1 WHEN ema017 <= 66.67 THEN 2
           WHEN ema017 > 66.67 THEN 3 ELSE 0 END AS c17,
      CASE WHEN ema018 <= 0 THEN 1 ELSE 4 END AS c18,   -- :1342-1349 (era ELSE 3)
      CASE WHEN ema020 <= 0 THEN 1 WHEN ema020 <= 50 THEN 2 WHEN ema020 > 50 THEN 3 ELSE 0 END AS c20,
      CASE WHEN ema021 <= 5 THEN 1 WHEN ema021 <= 45 THEN 2 WHEN ema021 <= 50 THEN 3 WHEN ema021 > 50 THEN 4 ELSE 0 END AS c21,
      CASE WHEN ema023 <= 0 THEN 1 WHEN ema023 <= 44 THEN 2 WHEN ema023 > 44 THEN 3 ELSE 0 END AS c23,
      -- :2234-2241. Las dos ramas devolvian 1: la caracteristica entraba en
      -- la suma con su beta y aportaba la MISMA constante a todas las filas.
      CASE WHEN ema024 <= 50 THEN 1 ELSE 4 END AS c24,
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
