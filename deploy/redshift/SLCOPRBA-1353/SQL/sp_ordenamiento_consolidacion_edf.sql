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
  ) best;
END;
$$;
-- SLCOPRBA-1355: re-DPLY DEV post DROP SCHEMA strct #256
