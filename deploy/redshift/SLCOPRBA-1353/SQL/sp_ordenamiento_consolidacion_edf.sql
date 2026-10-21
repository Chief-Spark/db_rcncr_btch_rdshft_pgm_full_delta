-- Consolidacion EDF - UPSERT por personas del alcance (FULL/DELTA)
--
-- EL RANKING ES POR CANAL (D-ORD-10, 2026-10-21). Este SP escribia una fila
-- por RPU con MIN(s.lugar) MEZCLANDO los cuatro canales, y eso perdia el dato
-- que el Batch necesita.
--
-- EL LEGADO NO TIENE ESTE PROBLEMA Y POR ESO NO SE VE AL LEERLO. Alli cada
-- canal se ordena por separado (Caracteristicas.txt:72 EMA, :79 CEL, :88 DIR,
-- :105 TEL) sobre DIRECCIONES_TEMP, donde una fila es UN reporte de UNA clase:
-- un Cod_DW_Persona_Ubic pertenece a un solo canal, de modo que el
-- P0027_UBI_ORDENAMIENTO_130.TPT:140 puede escribir Orden_Prioridad = :IN_Lugar
-- con la RPU como llave y no se pisa nada.
--
-- EN NUESTRO MODELO SI SE PISA: v_xpm_contacto_canal ata cada canal a la
-- direccion de su reporte, asi que el mismo cod_dw_persona_ubic recibe lugar
-- en DIR y tambien en TEL, CEL o EMA. El MIN se quedaba con el mejor de los
-- cuatro y los otros tres desaparecian.
--
-- Y EL BATCH LOS NECESITA LOS CUATRO: entrega UN CUBO POR CANAL
-- (Sps_Batch.sql:5416-5796) y en cada uno Orden_Prioridad es el lugar DENTRO
-- de ese canal (P0033_BATCH2_CUBOEXPORT_120.BTQ:134, :391, :637, :894; RF
-- CA-F01). Si es NULL, el Batch descarta la fila.
--
-- LOS CONSUMIDORES DE HOY NO CAMBIAN DE VALOR, y es deliberado: los tres que
-- leen esta tabla agregan con MIN(orden_prioridad) GROUP BY cod_dw_persona_ubic
-- -- v_rpu_post_unificacion, sp_novedades_ubicacion_*.sql:123 y el evaluador --
-- de modo que obtienen el mismo numero que antes. El cambio ANADE filas, no
-- reemplaza las que habia.
--
-- EL MOCK REUTILIZA ESTE SP (no tiene espejo), asi que vale para las dos vias.
CREATE OR REPLACE PROCEDURE bdm_datos.sp_ordenamiento_consolidacion_edf()
NONATOMIC
LANGUAGE plpgsql
AS $$
BEGIN
  DELETE FROM bdm_datos.rpu_orden_prioridad
  WHERE id_buro_persona IN (
    SELECT id_buro_persona FROM bdm_tempo.stg_ord_personas_alcance
  );

  -- ------------------------------------------------------------
  -- LA COMPUERTA DIR053 (T4, 2026-10-21): UNA DIRECCION SIN CIUDAD DANE NO SE
  -- ENTREGA.
  --
  -- El legado la aplica en la tabla que lleva el Lugar, con un
  -- "WHERE CODIR53.CO00DIR053 IS NOT NULL" (Caracteristicas.txt CR:1784), y
  -- CO00DIR053 se construye en CR:2551-2578 asi:
  --   TMP_AGR_VDTEMP_DF cuenta reportes por (persona, direccion, dane), solo
  --   con direccion <> '' (CR:684-695); Maximo es el MAX de esa cuenta por
  --   (persona, direccion); y DIR053 es el MIN del dane de las filas que
  --   empatan en ese maximo, con el '' convertido a NULL.
  --
  -- DOS DETALLES DEL LEGADO QUE SE PORTAN LITERALES:
  --   * el MIN ignora los NULL, de modo que si el dane vacio EMPATA con uno
  --     real en numero de reportes, gana el real y la direccion SI se
  --     entrega. Solo cae cuando el mas reportado es el vacio.
  --   * la compuerta va DESPUES del ranking y no antes: el lugar ya esta
  --     calculado y numerado, asi que la serie entregada puede tener huecos.
  --     Recalcularlo seria otra cosa de la que el legado hace.
  --
  -- VA AQUI Y NO EN EL SCORING, y es deliberado: el legado deja la fila en su
  -- tabla de score (Sumatoria_Score_Direcc_AGR) y la quita de la de entrega.
  -- Gatear score_ordenamiento cambiaria lo que miden los criterios F4 y CA-F03,
  -- que leen el score, no la entrega.
  --
  -- QUE MUEVE, MEDIDO ANTES DE ESCRIBIRLA (condicion de T4): en el mock,
  -- CERO. Las 19.000 direcciones sembradas traen cod_dw_ciudad, de modo que
  -- ninguna cae y el tablero no se mueve. En la via REAL si dispara: en QA
  -- solo el 54-76 % de las direcciones de suscriptor traen DANE (RESULTADOS
  -- seccion 15), asi que el resto deja de entregarse, que es justo lo que el
  -- legado hace y nosotros no haciamos.
  --
  -- EL MOCK NO LA EJERCITA, y conviene decirlo en vez de dar por certificada
  -- una rama que no se toca: hace falta un arquetipo con una direccion sin
  -- DANE para medirla. Queda anotado, no implementado aqui.
  -- ------------------------------------------------------------
  DROP TABLE IF EXISTS bdm_tempo.stg_ord_dir053;
  CREATE TABLE bdm_tempo.stg_ord_dir053
  DISTSTYLE KEY DISTKEY(id_buro_persona)
  AS
  SELECT g.id_buro_persona,
         g.direccion_fisica,
         MIN(CASE WHEN g.numero = m.maximo
                  THEN NULLIF(TRIM(CAST(g.cod_dane_ciudad AS VARCHAR)), '')
                  ELSE NULL END) AS codigo_ciudad
  FROM ( SELECT id_buro_persona,
                direccion_fisica,
                cod_dane_ciudad,
                COUNT(*) AS numero
           FROM bdm_tempo.stg_insumo_direccion
          WHERE direccion_fisica IS NOT NULL
            AND TRIM(direccion_fisica) <> ''
          GROUP BY 1, 2, 3 ) g
  INNER JOIN ( SELECT id_buro_persona,
                      direccion_fisica,
                      MAX(numero) AS maximo
                 FROM ( SELECT id_buro_persona,
                               direccion_fisica,
                               cod_dane_ciudad,
                               COUNT(*) AS numero
                          FROM bdm_tempo.stg_insumo_direccion
                         WHERE direccion_fisica IS NOT NULL
                           AND TRIM(direccion_fisica) <> ''
                         GROUP BY 1, 2, 3 ) g2
                GROUP BY 1, 2 ) m
          ON  m.id_buro_persona  = g.id_buro_persona
          AND m.direccion_fisica = g.direccion_fisica
  GROUP BY 1, 2;

  -- La RPU con la que el scoring representa cada grupo (persona, direccion):
  -- es el MIN(cod_dw_persona_ubic) de base_agg en
  -- sp_ordenamiento_scoring_dir_edf, y se reproduce aqui para poder atar la
  -- compuerta a la fila de score que le corresponde.
  DROP TABLE IF EXISTS bdm_tempo.stg_ord_dir053_rpu;
  CREATE TABLE bdm_tempo.stg_ord_dir053_rpu
  DISTSTYLE KEY DISTKEY(id_buro_persona)
  AS
  SELECT MIN(i.cod_dw_persona_ubic) AS cod_dw_persona_ubic,
         i.id_buro_persona,
         d.codigo_ciudad
  FROM bdm_tempo.stg_insumo_direccion i
  INNER JOIN bdm_tempo.stg_ord_dir053 d
          ON  d.id_buro_persona  = i.id_buro_persona
          AND d.direccion_fisica = i.direccion_fisica
  GROUP BY i.id_buro_persona, i.direccion_fisica, d.codigo_ciudad;

  INSERT INTO bdm_datos.rpu_orden_prioridad (
    cod_dw_persona_ubic, id_buro_persona, canal, orden_prioridad, fecha_actualizacion
  )
  SELECT
    best.cod_dw_persona_ubic,
    best.id_buro_persona,
    best.canal,
    best.lugar,
    GETDATE()
  FROM (
    SELECT
      s.cod_dw_persona_ubic,
      s.id_buro_persona,
      s.canal,
      -- MIN DENTRO DEL CANAL, no entre canales. Un mismo RPU puede tener dos
      -- filas de score en el MISMO canal cuando la persona reporta dos datos
      -- de contacto distintos desde la misma direccion; ahi el lugar del RPU
      -- en ese canal es el mejor de los dos, que es lo que el ranking del
      -- legado produce para esa ubicacion.
      MIN(s.lugar) AS lugar
    FROM bdm_datos.score_ordenamiento s
    INNER JOIN bdm_tempo.stg_rpu_post_unificacion rpu
      ON rpu.cod_dw_persona_ubic = s.cod_dw_persona_ubic
     AND COALESCE(rpu.ind_unificacion, 0) <> 1
    WHERE s.id_buro_persona IN (
      SELECT id_buro_persona FROM bdm_tempo.stg_ord_personas_alcance
    )
    GROUP BY 1, 2, 3
  ) best
  -- La compuerta: solo el canal DIR, y solo si su DIR053 tiene valor. Los
  -- otros tres canales pasan enteros -- el legado no les pone compuerta de
  -- ciudad.
  LEFT JOIN bdm_tempo.stg_ord_dir053_rpu g53
         ON g53.cod_dw_persona_ubic = best.cod_dw_persona_ubic
  WHERE best.canal <> 'DIR'
     OR g53.codigo_ciudad IS NOT NULL;

  DROP TABLE IF EXISTS bdm_tempo.stg_ord_dir053;
  DROP TABLE IF EXISTS bdm_tempo.stg_ord_dir053_rpu;
END;
$$;
-- SLCOPRBA-1355: re-DPLY DEV post DROP SCHEMA strct #256
