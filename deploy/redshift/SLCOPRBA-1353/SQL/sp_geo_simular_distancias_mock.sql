-- ============================================================
-- sp_geo_simular_distancias_mock  (Reconocer / GEO MOCK - d7)
-- (repo pgm / db_rcncr_btch_rdshft_pgm). UTF-8 sin BOM, sin acentos.
--
-- ES EL DOBLE DEL SISTEMA EXTERNO, NO UN PORT, y el nombre lo dice. Hermano
-- de sp_geo_simular_arcgis_mock: ese produce el archivo de vuelta de
-- georreferenciacion y este el de distancias a puntos de interes. Ninguno de
-- los dos tiene contraparte en el legado porque lo que simulan es ArcGIS.
--
-- QUE ESCRIBE: bdm_stage.mock_geo_distancias, el contrato Salida_Distancias
-- de 12 columnas crudas. Dos puntos de interes por ubicacion geocodificada,
-- y DOS Y NO UNO a proposito: la clave del contrato es 1:N
-- (cod_dw_ubic, tipo_punto_interes, cod_punto_interes_host) y con un solo
-- punto por ubicacion el grano 1:N no se ejerceria. Con dos, cualquier
-- fan-out o colapso de la llave se ve en el conteo.
--
-- SOLO LAS GEOCODIFICADAS. Un punto de interes se mide por distancia desde
-- unas coordenadas: sin coordenadas no hay distancia que devolver. Es la
-- misma condicion que usa el simulador de georreferenciacion en modo 'M'.
--
-- NO TOCA NADA DE LA REGLA 3 NI DE LOS CINCO CRITERIOS GEO. Las distancias
-- no alimentan la Regla 3 -- eso son las coordenadas, que vienen de
-- geo_atributos_mock -- ni las lee ningun CA-0x. Lo unico que las consume es
-- la tabla dominio d7.
--
-- COORDENADAS Y DISTANCIA DERIVADAS DE LA UBICACION, no aleatorias: el punto
-- de interes queda a un desplazamiento fijo de la ubicacion y la distancia es
-- constante por tipo. Asi la corrida es REPETIBLE -- la misma semilla da el
-- mismo resultado en toda pasada --, que es lo que permite afirmar un conteo
-- exacto en un criterio.
--
-- Objeto en bdm_datos; idempotente (CREATE OR REPLACE PROCEDURE).
-- NONATOMIC, consistente con la cadena de CALL.
-- ============================================================
CREATE OR REPLACE PROCEDURE bdm_datos.sp_geo_simular_distancias_mock(in_lote INTEGER)
NONATOMIC
LANGUAGE plpgsql
AS $$
DECLARE
  v_filas INTEGER;
BEGIN

  -- Aislamiento por Lote: solo se rehace lo de este Lote, igual que el
  -- simulador de georreferenciacion.
  DELETE FROM bdm_stage.mock_geo_distancias
  WHERE BTRIM(col02) = in_lote::VARCHAR;

  INSERT INTO bdm_stage.mock_geo_distancias
    (col01, col02, col03, col04, col05, col06,
     col07, col08, col09, col10, col11, col12)
  SELECT
    g.cod_dw_ubic::VARCHAR                                        AS col01,
    in_lote::VARCHAR                                              AS col02,
    'DIRECCION MOCK ' || g.cod_dw_ubic::VARCHAR                   AS col03,
    CAST(g.latitud  AS VARCHAR)                                   AS col04,
    CAST(g.longitud AS VARCHAR)                                   AS col05,
    'DISTANCIAS'                                                  AS col06,
    p.tipo                                                        AS col07,
    p.nombre || ' ' || g.cod_dw_ubic::VARCHAR                     AS col08,
    CAST(CAST(g.latitud  + p.delta_lat AS DECIMAL(10,6)) AS VARCHAR) AS col09,
    CAST(CAST(g.longitud + p.delta_lon AS DECIMAL(10,6)) AS VARCHAR) AS col10,
    CAST(p.metros AS VARCHAR)                                     AS col11,
    p.host                                                        AS col12
  FROM bdm_datos.geo_atributos_mock g
  -- Los dos puntos de interes. Van en un UNION ALL y no en una tabla de
  -- catalogo porque son parte del DOBLE, no del modelo: el dia que el
  -- contrato traiga otros tipos, esto es lo que cambia.
  CROSS JOIN (
    SELECT CAST('BANCO'   AS VARCHAR(60))  AS tipo,
           CAST('SUCURSAL BANCARIA' AS VARCHAR(100)) AS nombre,
           CAST('PI-BANCO-001' AS VARCHAR(60)) AS host,
           CAST( 0.001000 AS DECIMAL(10,6)) AS delta_lat,
           CAST( 0.001000 AS DECIMAL(10,6)) AS delta_lon,
           CAST(  150 AS INTEGER)           AS metros
    UNION ALL
    SELECT CAST('COLEGIO' AS VARCHAR(60)),
           CAST('INSTITUCION EDUCATIVA' AS VARCHAR(100)),
           CAST('PI-COLEGIO-001' AS VARCHAR(60)),
           CAST(-0.002000 AS DECIMAL(10,6)),
           CAST( 0.002500 AS DECIMAL(10,6)),
           CAST(  420 AS INTEGER)
  ) p
  WHERE g.lote = in_lote
    AND g.latitud  IS NOT NULL
    AND g.longitud IS NOT NULL;

  GET DIAGNOSTICS v_filas = ROW_COUNT;

  RAISE INFO 'sp_geo_simular_distancias_mock: Lote % simulado con % fila(s) de distancia (2 puntos de interes por ubicacion geocodificada).',
    in_lote, v_filas;

END;
$$;
