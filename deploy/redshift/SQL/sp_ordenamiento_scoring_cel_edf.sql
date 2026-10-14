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
  -- SLCOPRBA-1355: contadores de reporte por ventana, por PERSONA.
  -- Portados de REC_STAGE.NUM_TOTAL_REPORTE_CEL (Caracteristicas.txt:380-400),
  -- que agrupa por (Cod_Pin_Persona, Id_Buro_Persona) -- la misma llave que
  -- id_buro_persona, por FNV_HASH. Son los divisores de CEL006/014/015/017.
  ventanas AS (
    SELECT id_buro_persona,
           SUM(CASE WHEN meses_reporte <=  3 THEN 1 ELSE 0 END) AS tr_3,
           SUM(CASE WHEN meses_reporte <=  6 THEN 1 ELSE 0 END) AS tr_6,
           SUM(CASE WHEN meses_reporte <= 12 THEN 1 ELSE 0 END) AS tr_12,
           SUM(CASE WHEN meses_reporte <= 24 THEN 1 ELSE 0 END) AS tr_24,
           SUM(CASE WHEN meses_reporte >  24 THEN 1 ELSE 0 END) AS tr_24m,
           -- Divisor de CEL023 (Caracteristicas.txt:3130-3139): la recencia
           -- MAS VIEJA entre TODOS los celulares de la persona.
           MAX(meses_reporte) AS max_meses_persona
      FROM bdm_tempo.stg_insumo_celular
     GROUP BY id_buro_persona
  ),
  base_agg AS (
    SELECT
      MIN(ic.cod_dw_persona_ubic) AS cod_dw_persona_ubic,
      MIN(ic.cod_pin_persona) AS cod_pin_persona,
      ic.id_buro_persona,
      ic.celular,
      MAX(ic.meses_reporte) AS cel003,
      -- CEL006 (Caracteristicas.txt:2444-2447): cuota de la ventana <= 3 meses
      -- sobre Total_Reportes_3. Antes era la ventana de 12 meses sobre COUNT(*)
      -- del grupo: ni la ventana ni el divisor eran los del legado.
      CAST(100.0 * SUM(CASE WHEN ic.meses_reporte <= 3
                            THEN 1.0 / GREATEST(v.tr_3, 1) ELSE 0 END) AS DECIMAL(18,2)) AS cel006,
      -- CEL007 (:2448): conteo pelado. Ya era correcta; lo que estaba mal era
      -- su categoria (ver mas abajo).
      SUM(CASE WHEN ic.meses_reporte <= 6 THEN 1 ELSE 0 END) AS cel007,
      -- CEL013 (:2449): conteo de reportes de mas de 24 meses. Es la excepcion
      -- del bloque: sin divisor y sin *100, confirmado por sus umbrales de
      -- categoria (:2348-2354, <1 <2 <3 >=3). Antes era una bandera sobre el
      -- prefijo del operador, que el legado no mira en ningun sitio.
      SUM(CASE WHEN ic.meses_reporte > 24 THEN 1 ELSE 0 END) AS cel013,
      -- CEL014 (:2450-2453): cuota de la ventana > 24 meses sobre
      -- Total_Reportes_24m. NO depende de tipo_cuenta: la bandera POSPAGO que
      -- habia aqui es la que tenia 124,48 de beta inmovilizados en el mock.
      CAST(100.0 * SUM(CASE WHEN ic.meses_reporte > 24
                            THEN 1.0 / GREATEST(v.tr_24m, 1) ELSE 0 END) AS DECIMAL(18,2)) AS cel014,
      -- CEL015 (:2454-2458): cuota de la ventana (3, 6] sobre
      -- (Total_Reportes_6 - Total_Reportes_3). No cuenta suscriptores.
      CAST(100.0 * SUM(CASE WHEN ic.meses_reporte > 3 AND ic.meses_reporte <= 6
                            THEN 1.0 / GREATEST(v.tr_6 - v.tr_3, 1) ELSE 0 END) AS DECIMAL(18,2)) AS cel015,
      -- CEL017 (:2459-2463): cuota de la ventana (12, 24] sobre
      -- (Total_Reportes_24 - Total_Reportes_12). NO depende de
      -- sector_financiero: otros 41,49 de beta que estaban clavados.
      CAST(100.0 * SUM(CASE WHEN ic.meses_reporte > 12 AND ic.meses_reporte <= 24
                            THEN 1.0 / GREATEST(v.tr_24 - v.tr_12, 1) ELSE 0 END) AS DECIMAL(18,2)) AS cel017,
      -- CEL018 (:908-909): peso del operador por el prefijo de 3 digitos.
      -- El legado devuelve 0 cuando el prefijo no esta en el catalogo
      -- ("CASE WHEN Valor_CO01CEL018 IS NULL THEN 0 ELSE ... END"); aqui
      -- habia un 0,22 inventado.
      --   Y es la COMPUERTA del canal: un 0 aqui saca la fila del ranking.
      --   Ver el WHERE del SELECT final.
      CAST(100.0 * COALESCE(MAX(ooc.valor), 0) AS DECIMAL(18,2)) AS cel018,
      CAST(100.0 * SUM(CASE WHEN ic.tipo_cuenta = 'POSPAGO' THEN 1 ELSE 0 END) / NULLIF(COUNT(*), 0) AS DECIMAL(18,2)) AS cel019,
      COUNT(*) AS cel020_raw,
      -- CEL023 se calcula en 'base': necesita el maximo por persona.
      COUNT(*) AS cel023_filas
    FROM bdm_tempo.stg_insumo_celular ic
    INNER JOIN ventanas v
      ON v.id_buro_persona = ic.id_buro_persona
    LEFT JOIN bdm_datos.catalogo_operador_ord_cel ooc
      ON ooc.cod_operador = LEFT(ic.celular, 3)
    GROUP BY ic.id_buro_persona, ic.celular
  ),
  persona_cel AS (
    SELECT id_buro_persona, SUM(cel020_raw) AS total_reportes FROM base_agg GROUP BY 1
  ),
  base AS (
    SELECT a.*,
      CAST(100.0 * a.cel020_raw / NULLIF(p.total_reportes, 0) AS DECIMAL(18,2)) AS cel020,
      -- CEL023 (:785-786): (recencia mas vieja de la PERSONA - la de ESTE
      -- celular) / la de la persona. Es la MISMA forma que EMA023 y TEL025;
      -- antes era una bandera de "tiene texto de ubicacion", que no se
      -- parece en nada.
      --   OJO: en el legado esta caracteristica se llama LOCALS/Total igual
      --   que CEL020, pero ahi son CONTEOS y aqui son MAX(Meses_Reporte)
      --   (:1566-1568 y :3133-3135). Portarla por analogia con CEL020 da un
      --   numero equivocado.
      CAST(100.0 * (CAST(v.max_meses_persona AS DECIMAL(18,6)) - a.cel003)
           / NULLIF(v.max_meses_persona, 0) AS DECIMAL(18,2)) AS cel023
    FROM base_agg a
    JOIN persona_cel p ON a.id_buro_persona = p.id_buro_persona
    JOIN ventanas   v ON v.id_buro_persona = a.id_buro_persona
  ),
  categorized AS (
    SELECT cod_dw_persona_ubic, cod_pin_persona, id_buro_persona, celular,
      cel018,   -- se arrastra crudo: es la compuerta del ranking, ver el WHERE final
      CASE WHEN cel003 < 21 THEN 1 WHEN cel003 < 33 THEN 2 WHEN cel003 < 54 THEN 3 WHEN cel003 >= 54 THEN 4 ELSE 0 END AS c03,
      CASE WHEN cel006 < 5 THEN 1 WHEN cel006 < 90 THEN 2 WHEN cel006 >= 90 THEN 3 ELSE 0 END AS c06,
      -- Umbrales de CARACTERISTICA_CAT_CEL (Caracteristicas.txt:332-371).
      -- Los cinco de abajo estaban calibrados contra los valores viejos.
      -- c07 cambia aunque CEL007 no cambie: su categoria nunca fue la del
      -- legado (teniamos 2/3/6, el legado 1/2/3).
      CASE WHEN cel007 < 1 THEN 1 WHEN cel007 < 2 THEN 2 WHEN cel007 < 3 THEN 3 WHEN cel007 >= 3 THEN 4 ELSE 0 END AS c07,
      CASE WHEN cel013 < 1 THEN 1 WHEN cel013 < 2 THEN 2 WHEN cel013 < 3 THEN 3 WHEN cel013 >= 3 THEN 4 ELSE 0 END AS c13,
      CASE WHEN cel014 < 5 THEN 1 WHEN cel014 < 50 THEN 2 WHEN cel014 < 100 THEN 3 WHEN cel014 >= 100 THEN 4 ELSE 0 END AS c14,
      CASE WHEN cel015 <= 0 THEN 1 WHEN cel015 > 0 THEN 4 ELSE 0 END AS c15,
      CASE WHEN cel017 <= 0 THEN 1 WHEN cel017 > 0 THEN 4 ELSE 0 END AS c17,
      CASE WHEN cel018 < 51.11 THEN 1 WHEN cel018 < 61.48 THEN 2 WHEN cel018 < 73.33 THEN 3 WHEN cel018 >= 73.33 THEN 4 ELSE 0 END AS c18,
      CASE WHEN cel019 < 35 THEN 1 WHEN cel019 < 80 THEN 2 WHEN cel019 >= 80 THEN 3 ELSE 0 END AS c19,
      CASE WHEN cel020 < 33.33 THEN 1 WHEN cel020 < 45.67 THEN 2 WHEN cel020 < 100 THEN 3 WHEN cel020 >= 100 THEN 4 ELSE 0 END AS c20,
      CASE WHEN cel023 <= 0 THEN 1 WHEN cel023 > 0 THEN 4 ELSE 0 END AS c23   -- :202-208, sin cubetas 2 ni 3
    FROM base
  ),
  scored AS (
    SELECT c.cod_dw_persona_ubic, c.cod_pin_persona, c.id_buro_persona, c.celular, c.cel018,
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
                                celular,
                                cod_dw_persona_ubic)
  FROM scored
  -- COMPUERTA DE ELEGIBILIDAD DEL CANAL (Caracteristicas.txt:890-900).
  --
  --   Orden_Celular del legado no ordena todo lo que puntua: une el score
  --   con CO01CEL018 y filtra "WHERE CEl018.CO01CEL018 <> 0" (:899). Un
  --   celular cuyo prefijo de 3 digitos no esta en el catalogo de operadores
  --   vale 0 en CEL018 (:909, "CASE WHEN Valor_CO01CEL018 IS NULL THEN 0")
  --   y queda FUERA del ranking: no es que puntue bajo, es que no se
  --   contacta.
  --
  --   El WHERE va aqui, no en una CTE anterior, y eso importa: en SQL el
  --   WHERE se aplica ANTES de las funciones de ventana, de modo que el
  --   ROW_NUMBER numera 1..N sobre las filas que sobreviven. Es lo que hace
  --   el legado, que tiene el filtro y el ROW_NUMBER en el mismo SELECT.
  --
  --   ESTO QUITA FILAS de score_ordenamiento, no solo cambia su score. Es
  --   el comportamiento del legado y se aplica por decision expresa.
  --   Los otros tres canales NO llevan compuerta: EMA no tiene ninguna
  --   (Orden_Email, :804-813, un ROW_NUMBER pelado) y la de TEL cuelga de
  --   CO01TEL022 (:1213), caracteristica que no calculamos.
  WHERE cel018 <> 0;
END;
$$;
-- SLCOPRBA-1355: re-DPLY DEV post DROP SCHEMA strct #256
