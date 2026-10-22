-- ============================================================
-- sp_novedades_movilidad_edf.sql
-- SLCOPRBA-1399: dominio MOVILIDAD de Novedades (d6), via REAL.
-- (repo pgm / db_rcncr_btch_rdshft_pgm)
-- UTF-8 sin BOM. Sin acentos a proposito.
--
-- LEGADO: PRO_Novedad_Linea_Indic_Movilidad (Novedad.sql:1508-2165) y
-- P0029_INDICADORES_MOVILIDAD (4 archivos). Los dos estan en el repo; lo que
-- NO esta es el productor de REC_STAGE.MTCalcularIndicadoresMovilidad, que el
-- MANIFIESTO.md:68 ya listaba como hueco. Este SP lo construye.
--
-- ------------------------------------------------------------
-- DOS PARTES, Y EL ORDEN IMPORTA:
--   1. COMPARAR contra la foto anterior y emitir los eventos.
--   2. TOMAR la foto de hoy.
-- En ese orden y no al reves: si la foto se tomara primero, la comparacion se
-- haria contra si misma y no detectaria nada. Es el error de secuencia que ya
-- costo el ciclo GEO y el orden de Novedades entera.
--
-- ES UNA TABLA DE EVENTOS, NO DE BANDERAS. Las cuatro ramas del legado
-- (P0029_INDICADORES_MOVILIDAD_111.BTQ:62-68) son UNION ALL y cada una filtra
-- por SU propio cambio, de modo que una fila existe solo cuando ese cambio se
-- detecto. No hay fila que diga "no cambio de estrato" y pueda ser falsa.
--   De eso depende poder portar tres de los cuatro sin mentir: un atributo con
--   poco dato da MENOS FILAS, no filas equivocadas.
--
-- LAS CUATRO RAMAS EXIGEN CambioDir = 1, y aqui se reproduce literal: los tres
-- indicadores salen del MISMO evento de cambio de direccion. Un estrato que
-- cambie sin que cambie la direccion NO produce fila, igual que en el legado.
--
-- SE PORTAN TRES DE LOS CUATRO. Falta Cambio de Localidad: LOCALIDAD / comuna
-- no existe en EDF por ninguna via (buscado en el inventario de 1.072
-- columnas del datashare y en Confluence, espacios CCBR y EDCLMI).
--   Y EL CATALOGO DE HOMOLOGACION ABARATA ESA AUSENCIA, cosa que no se
--   sabia hasta el 2026-10-22: Localidad y Direccion homologan LAS DOS a
--   CAM_LOC, de modo que Linea no las distingue. Como las cuatro ramas
--   exigen CambioDir = 1, toda fila de Localidad convive con una de
--   Direccion de la misma persona. La rama que falta no aporta ni un
--   codigo de Linea nuevo: los tres portados cubren los TRES codigos
--   distintos del catalogo (CAM_LOC, CAM_CIU, CAM_EST).
--
-- ------------------------------------------------------------
-- EL UNIVERSO ES LA INTERSECCION DE UBICACION E INFO BASICA, y es paridad
-- real: el legado construye TMP_LUL como
--   etapa 9 de Ubicacion INNER JOIN etapa 10 de Info Basica
-- (Novedad.sql:1719-1725) y une el indicador contra ella (:1999-2000). Una
-- persona sin ubicacion validada o sin info basica no publica movilidad.
--   Esto se puede portar HOY porque d4 existe desde el 2026-10-21. Antes no
--   habia con que hacer esa interseccion.
--
-- GRANO: una fila por (persona, indicador). El legado deduplica con Row_Pim
-- (P0029:61) y rechaza las repetidas con Cod_Rechazo '002902'; aqui se
-- consigue con el ROW_NUMBER de la comparacion, que deja un solo evento por
-- ubicacion -- el mas reciente -- antes de abrir las tres ramas.
--
-- CONTRATO DE CARGA: FOTO COMPLETA (111.BTQ:820). TRUNCATE + INSERT.
--
-- FIRMA: (INTEGER). No es orquestador. NONATOMIC en toda la cadena de CALL.
-- ============================================================
CREATE OR REPLACE PROCEDURE bdm_datos.sp_novedades_movilidad_edf(
    p_lote INTEGER
)
NONATOMIC
LANGUAGE plpgsql
AS $$
DECLARE
  v_hoy DATE;
BEGIN

  v_hoy := TRUNC(GETDATE());

  -- ------------------------------------------------------------
  -- Paso 1: el universo de hoy. La interseccion del legado (TMP_LUL), mas los
  -- tres atributos que se comparan.
  -- ------------------------------------------------------------
  DROP TABLE IF EXISTS bdm_tempo.stg_nov_movil_hoy;
  CREATE TABLE bdm_tempo.stg_nov_movil_hoy
  DISTSTYLE KEY DISTKEY (cod_dw_persona_ubic)
  AS
  SELECT e9.id                  AS cod_dw_persona_ubic,
         e9.info_basica         AS id_buro_persona,
         e9.cod_pin_persona,
         e9.dato,
         e9.codigo_dane,
         e9.ciudad,
         e9.estrato,
         e9.tipo_identificacion
  FROM      bdm_tempo.stg_nov_ubica_etapa_9 e9
  -- La interseccion con Info Basica, igual que TMP_LUL.
  INNER JOIN bdm_datos.mat_info_basica ib
         ON ib.id = e9.info_basica
  WHERE e9.id IS NOT NULL
    AND e9.info_basica IS NOT NULL;

  -- ------------------------------------------------------------
  -- Paso 2: la ULTIMA foto de cada ubicacion. Va en su propia tabla y no en
  -- una subconsulta correlacionada: Redshift rechaza en EJECUCION una
  -- subconsulta escalar en la proyeccion y el banco sobre PostgreSQL no lo
  -- caza (es el tercer punto ciego, el del job #407 en NOV-UB-14).
  -- ------------------------------------------------------------
  DROP TABLE IF EXISTS bdm_tempo.stg_nov_movil_prev;
  CREATE TABLE bdm_tempo.stg_nov_movil_prev
  DISTSTYLE KEY DISTKEY (cod_dw_persona_ubic)
  AS
  SELECT q.cod_dw_persona_ubic, q.fecha_foto, q.dato, q.codigo_dane,
         q.ciudad, q.estrato
  FROM (
    SELECT f.cod_dw_persona_ubic, f.fecha_foto, f.dato, f.codigo_dane,
           f.ciudad, f.estrato,
           ROW_NUMBER() OVER (PARTITION BY f.cod_dw_persona_ubic
                              ORDER BY f.fecha_foto DESC NULLS LAST,
                                       f.fecha_actualizacion DESC NULLS LAST) AS rn
    FROM bdm_datos.nov_movilidad_foto f
  ) q
  WHERE q.rn = 1;

  -- ------------------------------------------------------------
  -- Paso 3: EL EVENTO. Una ubicacion cuyo texto de direccion difiere de su
  -- ultima foto es un Cambio de Direccion, que es la condicion CambioDir = 1
  -- de la que cuelgan los otros dos indicadores.
  --   Sin foto previa NO hay evento: una persona vista por primera vez no se
  --   mudo. Por eso es INNER JOIN y no LEFT.
  --   La comparacion usa COALESCE a un centinela porque NULL <> 'X' da UNKNOWN
  --   y perderia el caso "antes no habia dato y ahora si", que es un cambio.
  -- ------------------------------------------------------------
  DROP TABLE IF EXISTS bdm_tempo.stg_nov_movil_evento;
  CREATE TABLE bdm_tempo.stg_nov_movil_evento
  DISTSTYLE KEY DISTKEY (id_buro_persona)
  AS
  SELECT h.cod_dw_persona_ubic,
         h.id_buro_persona,
         h.cod_pin_persona,
         h.tipo_identificacion,
         CASE WHEN COALESCE(h.codigo_dane, '@') <> COALESCE(p.codigo_dane, '@')
                OR COALESCE(h.ciudad,      '@') <> COALESCE(p.ciudad,      '@')
              THEN 1 ELSE 0 END  AS cambio_ciudad,
         CASE WHEN COALESCE(h.estrato, '@') <> COALESCE(p.estrato, '@')
              THEN 1 ELSE 0 END  AS cambio_estrato
  FROM      bdm_tempo.stg_nov_movil_hoy  h
  INNER JOIN bdm_tempo.stg_nov_movil_prev p
         ON p.cod_dw_persona_ubic = h.cod_dw_persona_ubic
  WHERE COALESCE(h.dato, '@') <> COALESCE(p.dato, '@');

  -- ------------------------------------------------------------
  -- Paso 4: la tabla final. Las tres ramas del legado, en UNION ALL, cada una
  -- con su propio filtro y su propia descripcion -- los literales son los que
  -- el propio P0029 escribe en su WHERE
  -- (P0029_INDICADORES_MOVILIDAD_111.BTQ:62-68).
  --
  -- UN EVENTO POR UBICACION Y POR INDICADOR. El legado deduplica con Row_Pim
  -- y rechaza las repetidas con Cod_Rechazo '002902'; aqui la ubicacion es
  -- unica en stg_nov_movil_evento, de modo que la combinacion ya lo es.
  --
  -- descripcion y novedad_2 SALEN DE CATALOGO desde el 2026-10-22, que es
  -- cuando llegaron V_INDICADOR_MOVILIDAD y V_Hom_Ind_Mov_Linea
  -- (26_ddl_catalogo_movilidad.sql). Hasta esa fecha iban NULL.
  --   OJO AL REPARTO, QUE EL LEGADO LO CRUZA: `descripcion` lleva la FRASE
  --   LARGA (VIM.Valor_Indicador_Movilidad) y `novedad` el NOMBRE CORTO
  --   (VIM.Descripcion_Indicador_Movilida), al reves de lo que sugieren los
  --   nombres de las columnas del catalogo (Novedad.sql:1782-1783).
  --   `novedad` ya se poblaba con ese nombre corto, de modo que el literal
  --   que ya estaba escrito es tambien la LLAVE de los dos joins.
  --   Los dos van por LEFT JOIN, como en el legado (:1788, :1923): un
  --   indicador fuera de catalogo deja la columna en NULL y NO pierde la
  --   fila.
  --
  -- El id se DERIVA con FNV_HASH de (persona, indicador, fecha), porque
  -- COD_DW_PERSONA_IND_MOVIL es un correlativo que el legado saca de
  -- REC_MTDAT.MAX_ID (P0029:75) y no tenemos esa secuencia. Mismo patron que
  -- el id de d7.
  -- ------------------------------------------------------------
  TRUNCATE TABLE bdm_datos.mat_info_movilidad;

  INSERT INTO bdm_datos.mat_info_movilidad (
    id, fecha, descripcion, novedad, info_basica_id, novedad_2,
    tipo_identificacion, numero_identificacion,
    lote, fecha_actualizacion, usuario_bd
  )
  SELECT FNV_HASH(CAST(e.id_buro_persona AS VARCHAR) || '|' || e.novedad
                  || '|' || CAST(v_hoy AS VARCHAR))   AS id,
         v_hoy                                        AS fecha,
         vim.descripcion                              AS descripcion,
         e.novedad,
         e.id_buro_persona                            AS info_basica_id,
         him.descripcion                              AS novedad_2,
         e.tipo_identificacion,
         e.cod_pin_persona                            AS numero_identificacion,
         p_lote, GETDATE(), CURRENT_USER
  FROM (
    SELECT id_buro_persona, cod_pin_persona, tipo_identificacion,
           CAST('Cambio de Direccion' AS VARCHAR(1000)) AS novedad
    FROM bdm_tempo.stg_nov_movil_evento
    UNION ALL
    SELECT id_buro_persona, cod_pin_persona, tipo_identificacion,
           'Cambio de Ciudad'
    FROM bdm_tempo.stg_nov_movil_evento
    WHERE cambio_ciudad = 1
    UNION ALL
    SELECT id_buro_persona, cod_pin_persona, tipo_identificacion,
           'Cambio de Estrato'
    FROM bdm_tempo.stg_nov_movil_evento
    WHERE cambio_estrato = 1
  ) e
  -- Ninguno de los dos multiplica: catalogo_indicador_movilidad trae una
  -- fila por nombre corto -- la quinta del volcado, el duplicado de
  -- direccion, se descarto al cargarlo -- y los cuatro valor_fuente de
  -- catalogo_hom_ind_mov son distintos entre si.
  LEFT JOIN bdm_datos.catalogo_indicador_movilidad vim
    ON vim.novedad = e.novedad
  LEFT JOIN bdm_datos.catalogo_hom_ind_mov him
    ON him.valor_fuente = e.novedad;

  -- ------------------------------------------------------------
  -- Paso 5: AHORA se toma la foto de hoy, y solo de lo que cambio o es nuevo.
  -- INSERT-ONLY: una fila nueva ES el evento, igual que en la tabla de hash
  -- de la Fase 3. Si escribiera una fila por corrida y ubicacion creceria sin
  -- tope y sin informacion.
  -- ------------------------------------------------------------
  INSERT INTO bdm_datos.nov_movilidad_foto (
    cod_dw_persona_ubic, id_buro_persona, cod_pin_persona, fecha_foto,
    dato, codigo_dane, ciudad, estrato, tipo_identificacion,
    lote, fecha_actualizacion, usuario_bd
  )
  SELECT h.cod_dw_persona_ubic, h.id_buro_persona, h.cod_pin_persona, v_hoy,
         h.dato, h.codigo_dane, h.ciudad, h.estrato, h.tipo_identificacion,
         p_lote, GETDATE(), CURRENT_USER
  FROM      bdm_tempo.stg_nov_movil_hoy  h
  LEFT JOIN bdm_tempo.stg_nov_movil_prev p
         ON p.cod_dw_persona_ubic = h.cod_dw_persona_ubic
  WHERE p.cod_dw_persona_ubic IS NULL
     OR COALESCE(h.dato,        '@') <> COALESCE(p.dato,        '@')
     OR COALESCE(h.codigo_dane, '@') <> COALESCE(p.codigo_dane, '@')
     OR COALESCE(h.ciudad,      '@') <> COALESCE(p.ciudad,      '@')
     OR COALESCE(h.estrato,     '@') <> COALESCE(p.estrato,     '@');

  -- bdm_tempo es compartido: una tabla huerfana confunde al siguiente.
  DROP TABLE IF EXISTS bdm_tempo.stg_nov_movil_hoy;
  DROP TABLE IF EXISTS bdm_tempo.stg_nov_movil_prev;
  DROP TABLE IF EXISTS bdm_tempo.stg_nov_movil_evento;

END;
$$;
