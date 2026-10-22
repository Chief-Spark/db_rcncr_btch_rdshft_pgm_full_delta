-- ============================================================
-- sp_novedades_punto_interes_edf.sql
-- SLCOPRBA-1399: dominio PUNTO DE INTERES de Novedades (d7), via REAL.
-- (repo pgm / db_rcncr_btch_rdshft_pgm)
-- UTF-8 sin BOM. Sin acentos a proposito.
--
-- LEGADO: PRO_Novedad_Linea_Punto_Interes (Novedad.sql:4585-5031).
--
-- ------------------------------------------------------------
-- LA FUENTE ES NUESTRA PROPIA geo_distancias, Y ESO ES LO QUE DESBLOQUEO EL
-- DOMINIO. El legado cruza cuatro vistas de Teradata --
-- V_RELACION_UBICACION_PUNTO_INT, V_PUNTO_DE_INTERES_GEO,
-- V_TIPO_PUNTO_INTERES y RELACION_PUNTO_INTERES_X_PERS
-- (Novedad.sql:4807-4811) -- que son la version Teradata de la respuesta de
-- ArcGIS al contrato Salida_Distancias. Esa respuesta ya la cargamos
-- nosotros.
--
-- EL NOMBRE DEL PUNTO LLEGABA Y SE TIRABA, y la nota estaba escrita:
-- sp_geo_cargar_distancias.sql decia "col08 Nombre_Punto_Interes (no se
-- guarda: geo_distancias no tiene columna; va con Novedades d7)". Hoy
-- geo_distancias tiene la columna y el cargador la persiste.
--   CORRIGE UNA AFIRMACION DEL TABLERO: decia que d7 estaba bloqueada
--   porque "el contrato de distancias no persiste el nombre". El contrato SI
--   lo trae, en col08; era nuestra tabla la que no tenia donde ponerlo.
--
-- ------------------------------------------------------------
-- OCHO DE LAS DIEZ COLUMNAS SE POBLAN. Las dos que no, y por que:
--   nombre_entidad -> salen de RELACION_PUNTO_INTERES_X_PERS
--   nit_entidad       (NOMBRE_SUSCRIPTOR y NUM_IDENT, Novedad.sql:4801-4802),
--                     una tabla que no existe de este lado y que NO viaja en
--                     el contrato de distancias. Es peticion, no codigo.
-- Van en NULL y no en un valor por defecto: NULL dice "no hay con que
-- medir". La distincion de F1-08 y de NOV-UB-12.
--
-- `tipo` ENTRO EL 2026-10-22 con V_Hom_Tipo_Pto_Int_Linea
-- (27_ddl_catalogo_hom_tipo_pto_int.sql, 34 filas sin un Valor_Fuente
-- repetido). El legado hace TIPO = h2.Descripcion_Hom_Tipo_Pto_Int_Linea
-- uniendo por Cod_Tipo_Punto_Interes_Host (Novedad.sql:4879, :4891).
--   LA LLAVE NO ES LA MISMA Y ESO HAY QUE DECIRLO: ese
--   Cod_Tipo_Punto_Interes_Host es una columna de V_TIPO_PUNTO_INTERES
--   (:4806), el catalogo que NO se ha entregado. Unimos por
--   geo_distancias.tipo_punto_interes, la col07 del contrato
--   Salida_Distancias. Los 34 Valor_Fuente son codigos SIC de cuatro
--   digitos y casan uno a uno con su descripcion, que es la taxonomia con
--   la que ArcGIS clasifica un POI; que col07 traiga ese codigo y no la
--   descripcion es HIPOTESIS, no esta probado, y no hay con que probarlo
--   hasta que llegue un archivo de distancias real. La consulta que lo
--   cierra en una linea esta escrita en la cabecera del catalogo.
--   El riesgo de cablearlo antes es nulo: va por LEFT JOIN, de modo que
--   una llave equivocada deja `tipo` en NULL, que es donde estaba.
--
-- ------------------------------------------------------------
-- EL id SE DERIVA, Y HAY QUE SABERLO ANTES DE COMPARARLO CON TERADATA.
-- El legado usa COD_DW_UBIC_PUNTO_INTERES, la llave de la fila de relacion
-- ubicacion-punto, que no viaja en el contrato. Se deriva con FNV_HASH de
-- las tres columnas que SI viajan y que forman esa misma relacion:
-- (cod_dw_ubic, tipo_punto_interes, cod_punto_interes_host), que es la clave
-- 1:N declarada del contrato. Es el mismo patron que cod_dw_persona_ubic,
-- derivado de (id, index).
--   DIVERGENCIA ANOTADA: el VALOR no coincide con el de Teradata. La
--   IDENTIDAD de la fila si, y es estable entre corridas, que es lo que el
--   UPSERT necesita.
--
-- EL UNIVERSO SE ACOTA POR LA ETAPA 9 DE UBICACION, y es paridad real: el
-- legado parte de (SELECT COD_DW_UBIC, COUNT(1) FROM TMP_UBICA_ETAPA_9
-- GROUP BY 1) e INNER JOIN contra la relacion (Novedad.sql:4807-4808). Un
-- punto de interes de una ubicacion que Ubicacion no valido no se publica.
-- Por eso este SP corre DESPUES de Ubicacion.
--   EL GROUP BY DEL LEGADO ES LO QUE EVITA EL FAN-OUT: la etapa 9 tiene una
--   fila por persona-ubicacion y puede haber varias por cod_dw_ubic. Sin
--   agrupar, cada punto de interes se multiplicaria por ellas. Aqui se
--   reproduce con un SELECT DISTINCT, que da el mismo universo y no arrastra
--   el COUNT que el legado calcula y no usa.
--
-- GRANO: una fila por (ubicacion, punto de interes). La llave de la tabla
-- son las DOS columnas (ID, UBICACION_ID) -- 120.TPT:367-368 --, y
-- geo_distancias ya es unica por su clave 1:N, que el cargador deduplica.
--
-- CONTRATO DE CARGA: FOTO COMPLETA (111.BTQ:820). TRUNCATE + INSERT.
--
-- FIRMA: (INTEGER). No es orquestador: recibe solo el lote.
-- NONATOMIC en toda la cadena de CALL.
-- ============================================================
CREATE OR REPLACE PROCEDURE bdm_datos.sp_novedades_punto_interes_edf(
    p_lote INTEGER
)
NONATOMIC
LANGUAGE plpgsql
AS $$
BEGIN

  TRUNCATE TABLE bdm_datos.mat_info_punto_interes;

  INSERT INTO bdm_datos.mat_info_punto_interes (
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
         hpi.descripcion                                AS tipo,
         p_lote, GETDATE(), CURRENT_USER
  FROM bdm_datos.geo_distancias d
  -- El universo de Ubicacion, agrupado por cod_dw_ubic. Va en subconsulta
  -- con DISTINCT y no como join directo a la etapa 9: esa tabla tiene una
  -- fila por persona-ubicacion y multiplicaria cada punto de interes.
  INNER JOIN (
    SELECT DISTINCT e9.cod_dw_ubic
    FROM bdm_tempo.stg_nov_ubica_etapa_9 e9
    WHERE e9.cod_dw_ubic IS NOT NULL
  ) u
    ON u.cod_dw_ubic = d.cod_dw_ubic
  -- No multiplica: los 34 valor_fuente del catalogo son distintos entre si.
  LEFT JOIN bdm_datos.catalogo_hom_tipo_pto_int hpi
    ON hpi.valor_fuente = d.tipo_punto_interes;

END;
$$;
