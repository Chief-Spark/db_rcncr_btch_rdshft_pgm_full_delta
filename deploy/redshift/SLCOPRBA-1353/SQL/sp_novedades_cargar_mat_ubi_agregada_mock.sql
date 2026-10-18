-- Novedades - dominio UBICACION AGREGADA (ESPEJO MOCK)
-- Espejo del real. Generado por
-- SUSTITUCION DE FUENTES: no se edita a mano. Regenerar con
-- tools/gen_novedades_espejo_ubiagr.py.
-- Solo cambian los nombres de los objetos: _edf -> _mock en el
-- procedimiento, sufijo _mock en las dos etapas de entrada y en la de
-- salida, y stg_nov_ubiagr_* -> stg_mock_nov_ubiagr_* en las 16
-- intermedias. El diff contra el real debe salir vacio modulo esos
-- nombres.

CREATE OR REPLACE PROCEDURE bdm_datos.sp_novedades_cargar_mat_ubi_agregada_mock(
    p_lote INTEGER
)
NONATOMIC
LANGUAGE plpgsql
AS $$
BEGIN

  -- ------------------------------------------------------------
  -- Severidad, materializada. `ya_estaba` se guarda aparte de la Severidad
  -- porque el orquestador necesita las dos cosas: la Severidad decide si la
  -- fila se escribe, y `ya_estaba` si cuenta como alta o como cambio.
  -- ------------------------------------------------------------
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_nov_ubiagr_sev;
  CREATE TABLE bdm_tempo.stg_mock_nov_ubiagr_sev
  DISTSTYLE KEY DISTKEY (info_basica)
  AS
  SELECT s.tipo_identificacion,
         s.numero_identificacion,
         s.info_basica,
         s.codigo_dane,
         s.ciudad,
         s.departamento,
         s.ubicacion_dato,
         s.ubicacion_reportdesde,
         s.ubicacion_ultreporte,
         s.ubicacion_numentidades,
         s.ubicacion_numreportes,
         s.ubicacion_clase,
         s.ubicacion_tipocuenta,
         s.ubicacion_orden,
         s.ubicacion_indicativo,
         s.ubicacion_estrato,
         s.ubicacion_zona,
         s.ubicacion_ciudad,
         s.ubicacion_departamento,
         s.ubicacion_codigodane,
         s.ubicacion_barrio,
         s.ubicacion_localidad,
         s.ubicacion_codigopostal,
         s.ubicacion_longitud,
         s.ubicacion_latitud,
         s.tipo,
         s.fuente,
         s.id,
         s.cod_pais,
         CASE WHEN b.info_basica IS NULL THEN 0 ELSE 1 END AS ya_estaba,
         CASE
           -- Rama 1: no estaba. Las siete preguntas son las del legado.
           WHEN b.info_basica            IS NULL
            AND b.tipo_identificacion    IS NULL
            AND b.numero_identificacion  IS NULL
            AND b.ubicacion_dato         IS NULL
            AND b.ubicacion_codigodane   IS NULL
            AND b.ubicacion_ciudad       IS NULL
            AND b.ubicacion_departamento IS NULL
                THEN 1
           -- Rama 2: estaba y alguna de las diecinueve cambio.
           WHEN b.info_basica            IS NOT NULL
            AND b.tipo_identificacion    IS NOT NULL
            AND b.numero_identificacion  IS NOT NULL
            AND b.ubicacion_dato         IS NOT NULL
            AND b.ubicacion_codigodane   IS NOT NULL
            AND b.ubicacion_ciudad       IS NOT NULL
            AND b.ubicacion_departamento IS NOT NULL
            AND ( COALESCE(s.codigo_dane, 'SV')            <> COALESCE(b.codigo_dane, 'SV')
               OR COALESCE(s.ubicacion_reportdesde,  CAST('2099-12-31' AS DATE))
                  <> COALESCE(b.ubicacion_reportdesde,  CAST('2099-12-31' AS DATE))
               OR COALESCE(s.ubicacion_ultreporte,   CAST('2099-12-31' AS DATE))
                  <> COALESCE(b.ubicacion_ultreporte,   CAST('2099-12-31' AS DATE))
               OR COALESCE(s.ubicacion_numentidades, -1)    <> COALESCE(b.ubicacion_numentidades, -1)
               OR COALESCE(s.ubicacion_numreportes,  -1)    <> COALESCE(b.ubicacion_numreportes,  -1)
               OR COALESCE(s.ubicacion_clase,        'SV')  <> COALESCE(b.ubicacion_clase,        'SV')
               OR COALESCE(s.ubicacion_tipocuenta,   'SV')  <> COALESCE(b.ubicacion_tipocuenta,   'SV')
               OR COALESCE(s.ubicacion_orden,        -1)    <> COALESCE(b.ubicacion_orden,        -1)
               OR COALESCE(s.ubicacion_indicativo,   'SV')  <> COALESCE(b.ubicacion_indicativo,   'SV')
               OR COALESCE(s.ubicacion_estrato,      'SV')  <> COALESCE(b.ubicacion_estrato,      'SV')
               OR COALESCE(s.ubicacion_zona,         'SV')  <> COALESCE(b.ubicacion_zona,         'SV')
               OR COALESCE(s.ubicacion_barrio,       'SV')  <> COALESCE(b.ubicacion_barrio,       'SV')
               OR COALESCE(s.ubicacion_localidad,    'SV')  <> COALESCE(b.ubicacion_localidad,    'SV')
               OR COALESCE(s.ubicacion_codigopostal, 'SV')  <> COALESCE(b.ubicacion_codigopostal, 'SV')
               OR COALESCE(s.ubicacion_longitud,     -1)    <> COALESCE(b.ubicacion_longitud,     -1)
               OR COALESCE(s.ubicacion_latitud,      -1)    <> COALESCE(b.ubicacion_latitud,      -1)
               OR COALESCE(s.tipo,                   'SV')  <> COALESCE(b.tipo,                   'SV')
               OR COALESCE(s.fuente,                 'SV')  <> COALESCE(b.fuente,                 'SV')
               OR COALESCE(s.id,                     'SV')  <> COALESCE(b.id,                     'SV') )
                THEN 1
           ELSE -1
         END AS severidad
  FROM      bdm_tempo.stg_nov_ubiagr_etapa_final_mock s
  LEFT JOIN bdm_datos.mat_ubicacion_agregada_mock     b
         ON s.info_basica            = b.info_basica
        AND s.tipo_identificacion    = b.tipo_identificacion
        AND s.numero_identificacion  = b.numero_identificacion
        AND s.ubicacion_dato         = b.ubicacion_dato
        AND s.ubicacion_codigodane   = b.ubicacion_codigodane
        AND s.ubicacion_ciudad       = b.ubicacion_ciudad
        AND s.ubicacion_departamento = b.ubicacion_departamento;

  -- ------------------------------------------------------------
  -- La mitad UPDATE del upsert: se retira la version anterior de las llaves
  -- que vuelven a entrar. Solo Severidad = 1; el -1 lo descarta el
  -- 130.TPT:215. Las llaves se materializan antes para que el DELETE no
  -- lleve la subconsulta entera.
  -- ------------------------------------------------------------
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_nov_ubiagr_llaves;
  CREATE TABLE bdm_tempo.stg_mock_nov_ubiagr_llaves
  DISTSTYLE KEY DISTKEY (info_basica)
  AS
  SELECT info_basica, tipo_identificacion, numero_identificacion,
         ubicacion_dato, ubicacion_codigodane, ubicacion_ciudad,
         ubicacion_departamento
  FROM bdm_tempo.stg_mock_nov_ubiagr_sev
  WHERE severidad = 1;

  -- DELETE ... USING y no un IN de siete columnas: Redshift NO admite el
  -- constructor de fila `(a,b,c) IN (SELECT ...)`. Y el destino va SIN ALIAS,
  -- que es la misma regla que ya costo un rato en UPDATE ... FROM.
  DELETE FROM bdm_datos.mat_ubicacion_agregada_mock
  USING bdm_tempo.stg_mock_nov_ubiagr_llaves k
  WHERE bdm_datos.mat_ubicacion_agregada_mock.info_basica            = k.info_basica
    AND bdm_datos.mat_ubicacion_agregada_mock.tipo_identificacion    = k.tipo_identificacion
    AND bdm_datos.mat_ubicacion_agregada_mock.numero_identificacion  = k.numero_identificacion
    AND bdm_datos.mat_ubicacion_agregada_mock.ubicacion_dato         = k.ubicacion_dato
    AND bdm_datos.mat_ubicacion_agregada_mock.ubicacion_codigodane   = k.ubicacion_codigodane
    AND bdm_datos.mat_ubicacion_agregada_mock.ubicacion_ciudad       = k.ubicacion_ciudad
    AND bdm_datos.mat_ubicacion_agregada_mock.ubicacion_departamento = k.ubicacion_departamento;

  -- ------------------------------------------------------------
  -- La mitad INSERT. Las 29 del contrato mas las tres de trazabilidad.
  -- ------------------------------------------------------------
  INSERT INTO bdm_datos.mat_ubicacion_agregada_mock (
    tipo_identificacion, numero_identificacion, info_basica, codigo_dane,
    ciudad, departamento, ubicacion_dato, ubicacion_reportdesde,
    ubicacion_ultreporte, ubicacion_numentidades, ubicacion_numreportes,
    ubicacion_clase, ubicacion_tipocuenta, ubicacion_orden,
    ubicacion_indicativo, ubicacion_estrato, ubicacion_zona, ubicacion_ciudad,
    ubicacion_departamento, ubicacion_codigodane, ubicacion_barrio,
    ubicacion_localidad, ubicacion_codigopostal, ubicacion_longitud,
    ubicacion_latitud, tipo, fuente, id, cod_pais,
    lote, fecha_actualizacion, usuario_bd
  )
  SELECT s.tipo_identificacion, s.numero_identificacion, s.info_basica,
         s.codigo_dane, s.ciudad, s.departamento, s.ubicacion_dato,
         s.ubicacion_reportdesde, s.ubicacion_ultreporte,
         s.ubicacion_numentidades, s.ubicacion_numreportes,
         s.ubicacion_clase, s.ubicacion_tipocuenta, s.ubicacion_orden,
         s.ubicacion_indicativo, s.ubicacion_estrato, s.ubicacion_zona,
         s.ubicacion_ciudad, s.ubicacion_departamento, s.ubicacion_codigodane,
         s.ubicacion_barrio, s.ubicacion_localidad, s.ubicacion_codigopostal,
         s.ubicacion_longitud, s.ubicacion_latitud, s.tipo, s.fuente, s.id,
         s.cod_pais,
         p_lote, GETDATE(), CURRENT_USER
  FROM bdm_tempo.stg_mock_nov_ubiagr_sev s
  WHERE s.severidad = 1;

  DROP TABLE IF EXISTS bdm_tempo.stg_mock_nov_ubiagr_llaves;

  -- stg_nov_ubiagr_sev NO se borra aqui: la lee el orquestador. Ver cabecera.

END;
$$;
