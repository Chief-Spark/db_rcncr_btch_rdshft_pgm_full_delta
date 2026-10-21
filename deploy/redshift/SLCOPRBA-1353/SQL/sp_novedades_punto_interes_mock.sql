-- Novedades - dominio PUNTO DE INTERES (ESPEJO MOCK)
-- Espejo del real. Generado por
-- SUSTITUCION DE FUENTES: no se edita a mano. Regenerar con
-- tools/gen_novedades_espejo_pinter.py.
-- Cuatro nombres cambian: el procedimiento, la tabla final, las
-- distancias GEO y la etapa 9 de Ubicacion. El diff contra el real
-- debe salir vacio modulo esos nombres. Las justificaciones viven en
-- el archivo real.

CREATE OR REPLACE PROCEDURE bdm_datos.sp_novedades_punto_interes_mock(
    p_lote INTEGER
)
NONATOMIC
LANGUAGE plpgsql
AS $$
BEGIN

  TRUNCATE TABLE bdm_datos.mat_info_punto_interes_mock;

  INSERT INTO bdm_datos.mat_info_punto_interes_mock (
    id, nombre, distancia, descripcion_tipo_punto_interes, ubicacion_id,
    nombre_entidad, nit_entidad, latitud, longitud, tipo,
    lote, fecha_actualizacion, usuario_bd
  )
  SELECT FNV_HASH(CAST(d.cod_dw_ubic AS VARCHAR)
                  || '|' || d.tipo_punto_interes
                  || '|' || d.cod_punto_interes_host)   AS id,
         d.nombre_punto_interes                         AS nombre,
         d.distancia_punto_interes                      AS distancia,
         -- El valor CRUDO del contrato. El legado pone aqui la descripcion
         -- del catalogo V_TIPO_PUNTO_INTERES, que no tenemos.
         CAST(d.tipo_punto_interes AS VARCHAR(1000))    AS descripcion_tipo_punto_interes,
         d.cod_dw_ubic                                  AS ubicacion_id,
         CAST(NULL AS VARCHAR(1000))                    AS nombre_entidad,
         CAST(NULL AS VARCHAR(20))                      AS nit_entidad,
         -- Las del PUNTO DE INTERES, no las de la ubicacion. VARCHAR porque
         -- asi lo declara el contrato (SCHEMA P0035_13), que es lo que el
         -- 120.TPT castea al exportar.
         CAST(d.latitud_punto_interes AS VARCHAR(40))   AS latitud,
         CAST(d.longitud_punto_interes AS VARCHAR(40))  AS longitud,
         CAST(NULL AS VARCHAR(30))                      AS tipo,
         p_lote, GETDATE(), CURRENT_USER
  FROM bdm_datos.geo_distancias_mock d
  -- El universo de Ubicacion, agrupado por cod_dw_ubic. Va en subconsulta
  -- con DISTINCT y no como join directo a la etapa 9: esa tabla tiene una
  -- fila por persona-ubicacion y multiplicaria cada punto de interes.
  INNER JOIN (
    SELECT DISTINCT e9.cod_dw_ubic
    FROM bdm_tempo.stg_nov_ubica_etapa_9_mock e9
    WHERE e9.cod_dw_ubic IS NOT NULL
  ) u
    ON u.cod_dw_ubic = d.cod_dw_ubic;

END;
$$;
