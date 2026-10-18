-- Novedades - dominio UBICACION AGREGADA (ESPEJO MOCK)
-- Espejo del real. Generado por
-- SUSTITUCION DE FUENTES: no se edita a mano. Regenerar con
-- tools/gen_novedades_espejo_ubiagr.py.
-- Solo cambian los nombres de los objetos: _edf -> _mock en el
-- procedimiento, sufijo _mock en las dos etapas de entrada y en la de
-- salida, y stg_nov_ubiagr_* -> stg_mock_nov_ubiagr_* en las 16
-- intermedias. El diff contra el real debe salir vacio modulo esos
-- nombres.

CREATE OR REPLACE PROCEDURE bdm_datos.sp_novedades_ubi_agregada_mock()
NONATOMIC
LANGUAGE plpgsql
AS $$
BEGIN

  -- ============================================================
  -- CADENA AGRUP: los agregados de la etapa 2 y los atributos de la etapa 9.
  -- ============================================================

  -- ---------- a1..a4: cuatro agregados sobre la MISMA llave ----------
  -- El legado hace cuatro pasadas separadas sobre la etapa 2, una por
  -- agregado, y las vuelve a unir en a5..a7. Las cuatro caben en una sola
  -- consulta y NO se juntan a proposito: el diff contra el legado tiene que
  -- poder leerse etapa por etapa, que es la convencion de este repo, y la
  -- union de a5..a7 tiene su propia trampa (el info_basica que falta) que
  -- desapareceria al simplificar.
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_nov_ubiagr_a1;
  CREATE TABLE bdm_tempo.stg_mock_nov_ubiagr_a1
  DISTSTYLE KEY DISTKEY (info_basica)
  AS
  SELECT e2.tipo_identificacion,
         e2.numero_identificacion,
         e2.info_basica,
         e2.dato,
         e2.codigo_dane,
         e2.ciudad,
         e2.departamento,
         MIN(e2.reportado_desde) AS ubicacion_reportdesde
  FROM bdm_tempo.stg_nov_ubica_etapa_2_mock e2
  GROUP BY e2.tipo_identificacion, e2.numero_identificacion, e2.info_basica,
           e2.dato, e2.codigo_dane, e2.ciudad, e2.departamento;

  DROP TABLE IF EXISTS bdm_tempo.stg_mock_nov_ubiagr_a2;
  CREATE TABLE bdm_tempo.stg_mock_nov_ubiagr_a2
  DISTSTYLE KEY DISTKEY (info_basica)
  AS
  SELECT e2.tipo_identificacion,
         e2.numero_identificacion,
         e2.info_basica,
         e2.dato,
         e2.codigo_dane,
         e2.ciudad,
         e2.departamento,
         MAX(e2.ultimo_reporte) AS ubicacion_ultreporte
  FROM bdm_tempo.stg_nov_ubica_etapa_2_mock e2
  GROUP BY e2.tipo_identificacion, e2.numero_identificacion, e2.info_basica,
           e2.dato, e2.codigo_dane, e2.ciudad, e2.departamento;

  DROP TABLE IF EXISTS bdm_tempo.stg_mock_nov_ubiagr_a3;
  CREATE TABLE bdm_tempo.stg_mock_nov_ubiagr_a3
  DISTSTYLE KEY DISTKEY (info_basica)
  AS
  SELECT e2.tipo_identificacion,
         e2.numero_identificacion,
         e2.info_basica,
         e2.dato,
         e2.codigo_dane,
         e2.ciudad,
         e2.departamento,
         MAX(e2.numero_entidades) AS ubicacion_numentidades
  FROM bdm_tempo.stg_nov_ubica_etapa_2_mock e2
  GROUP BY e2.tipo_identificacion, e2.numero_identificacion, e2.info_basica,
           e2.dato, e2.codigo_dane, e2.ciudad, e2.departamento;

  -- OJO: este es SUM y no MAX, al reves que el de entidades. Es del legado
  -- (:5389 contra :5315) y no una erratilla nuestra.
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_nov_ubiagr_a4;
  CREATE TABLE bdm_tempo.stg_mock_nov_ubiagr_a4
  DISTSTYLE KEY DISTKEY (info_basica)
  AS
  SELECT e2.tipo_identificacion,
         e2.numero_identificacion,
         e2.info_basica,
         e2.dato,
         e2.codigo_dane,
         e2.ciudad,
         e2.departamento,
         SUM(e2.numero_reportes) AS ubicacion_numreportes
  FROM bdm_tempo.stg_nov_ubica_etapa_2_mock e2
  GROUP BY e2.tipo_identificacion, e2.numero_identificacion, e2.info_basica,
           e2.dato, e2.codigo_dane, e2.ciudad, e2.departamento;

  -- ---------- a5, a6, a7: la union de los cuatro ----------
  -- EL JOIN OMITE info_basica. Ver el punto 1 de la cabecera: es del legado,
  -- se porta tal cual, y el criterio de grano del tablero es quien lo vigila.
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_nov_ubiagr_a5;
  CREATE TABLE bdm_tempo.stg_mock_nov_ubiagr_a5
  DISTSTYLE KEY DISTKEY (info_basica)
  AS
  SELECT a1.tipo_identificacion,
         a1.numero_identificacion,
         a1.info_basica,
         a1.dato,
         a1.codigo_dane,
         a1.ciudad,
         a1.departamento,
         a1.ubicacion_reportdesde,
         a2.ubicacion_ultreporte
  FROM bdm_tempo.stg_mock_nov_ubiagr_a1 a1
  JOIN bdm_tempo.stg_mock_nov_ubiagr_a2 a2
    ON a1.tipo_identificacion   = a2.tipo_identificacion
   AND a1.numero_identificacion = a2.numero_identificacion
   AND a1.dato                  = a2.dato
   AND a1.codigo_dane           = a2.codigo_dane
   AND a1.ciudad                = a2.ciudad
   AND a1.departamento          = a2.departamento;

  DROP TABLE IF EXISTS bdm_tempo.stg_mock_nov_ubiagr_a6;
  CREATE TABLE bdm_tempo.stg_mock_nov_ubiagr_a6
  DISTSTYLE KEY DISTKEY (info_basica)
  AS
  SELECT a5.tipo_identificacion,
         a5.numero_identificacion,
         a5.info_basica,
         a5.dato,
         a5.codigo_dane,
         a5.ciudad,
         a5.departamento,
         a5.ubicacion_reportdesde,
         a5.ubicacion_ultreporte,
         a3.ubicacion_numentidades
  FROM bdm_tempo.stg_mock_nov_ubiagr_a5 a5
  JOIN bdm_tempo.stg_mock_nov_ubiagr_a3 a3
    ON a5.tipo_identificacion   = a3.tipo_identificacion
   AND a5.numero_identificacion = a3.numero_identificacion
   AND a5.dato                  = a3.dato
   AND a5.codigo_dane           = a3.codigo_dane
   AND a5.ciudad                = a3.ciudad
   AND a5.departamento          = a3.departamento;

  -- a7 es donde `dato` pasa a llamarse `ubicacion_dato`, y con ese nombre
  -- viaja hasta el contrato.
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_nov_ubiagr_a7;
  CREATE TABLE bdm_tempo.stg_mock_nov_ubiagr_a7
  DISTSTYLE KEY DISTKEY (info_basica)
  AS
  SELECT a6.tipo_identificacion,
         a6.numero_identificacion,
         a6.info_basica,
         a6.codigo_dane,
         a6.ciudad,
         a6.departamento,
         a6.dato AS ubicacion_dato,
         a6.ubicacion_reportdesde,
         a6.ubicacion_ultreporte,
         a6.ubicacion_numentidades,
         a4.ubicacion_numreportes
  FROM bdm_tempo.stg_mock_nov_ubiagr_a6 a6
  JOIN bdm_tempo.stg_mock_nov_ubiagr_a4 a4
    ON a6.tipo_identificacion   = a4.tipo_identificacion
   AND a6.numero_identificacion = a4.numero_identificacion
   AND a6.dato                  = a4.dato
   AND a6.codigo_dane           = a4.codigo_dane
   AND a6.ciudad                = a4.ciudad
   AND a6.departamento          = a4.departamento;

  -- ---------- a8..a11: los atributos de la etapa 9 ----------
  -- a8 agrupa por NUEVE columnas. Ver el punto 2 de la cabecera.
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_nov_ubiagr_a8;
  CREATE TABLE bdm_tempo.stg_mock_nov_ubiagr_a8
  DISTSTYLE KEY DISTKEY (info_basica)
  AS
  SELECT e9.tipo_identificacion,
         e9.numero_identificacion,
         e9.info_basica,
         e9.dato AS ubicacion_dato,
         e9.codigo_dane,
         e9.ciudad,
         e9.departamento,
         e9.clase       AS ubicacion_clase,
         e9.tipo_cuenta AS ubicacion_tipocuenta
  FROM bdm_tempo.stg_nov_ubica_etapa_9_mock e9
  GROUP BY e9.tipo_identificacion, e9.numero_identificacion, e9.info_basica,
           e9.dato, e9.codigo_dane, e9.ciudad, e9.departamento,
           e9.clase, e9.tipo_cuenta;

  -- El centinela del indicativo va como CADENA: en el legado es -1 y aqui
  -- indicativo es VARCHAR, que Redshift no mezcla con INTEGER.
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_nov_ubiagr_a9;
  CREATE TABLE bdm_tempo.stg_mock_nov_ubiagr_a9
  DISTSTYLE KEY DISTKEY (info_basica)
  AS
  SELECT e9.tipo_identificacion,
         e9.numero_identificacion,
         e9.info_basica,
         e9.dato AS ubicacion_dato,
         e9.codigo_dane,
         e9.ciudad,
         e9.departamento,
         MIN(e9.orden)                        AS ubicacion_orden,
         MAX(COALESCE(e9.indicativo, '-1'))   AS ubicacion_indicativo,
         e9.estrato AS ubicacion_estrato,
         e9.zona    AS ubicacion_zona
  FROM bdm_tempo.stg_nov_ubica_etapa_9_mock e9
  GROUP BY e9.tipo_identificacion, e9.numero_identificacion, e9.info_basica,
           e9.dato, e9.codigo_dane, e9.ciudad, e9.departamento,
           e9.estrato, e9.zona;

  DROP TABLE IF EXISTS bdm_tempo.stg_mock_nov_ubiagr_a10;
  CREATE TABLE bdm_tempo.stg_mock_nov_ubiagr_a10
  DISTSTYLE KEY DISTKEY (info_basica)
  AS
  SELECT e9.tipo_identificacion,
         e9.numero_identificacion,
         e9.info_basica,
         e9.dato AS ubicacion_dato,
         e9.ciudad,
         e9.departamento,
         e9.codigo_dane,
         e9.barrio AS ubicacion_barrio
  FROM bdm_tempo.stg_nov_ubica_etapa_9_mock e9
  GROUP BY e9.tipo_identificacion, e9.numero_identificacion, e9.info_basica,
           e9.dato, e9.ciudad, e9.departamento, e9.codigo_dane, e9.barrio;

  DROP TABLE IF EXISTS bdm_tempo.stg_mock_nov_ubiagr_a11;
  CREATE TABLE bdm_tempo.stg_mock_nov_ubiagr_a11
  DISTSTYLE KEY DISTKEY (info_basica)
  AS
  SELECT e9.tipo_identificacion,
         e9.numero_identificacion,
         e9.info_basica,
         e9.dato AS ubicacion_dato,
         e9.codigo_dane,
         e9.ciudad,
         e9.departamento,
         e9.localidad     AS ubicacion_localidad,
         e9.codigo_postal AS ubicacion_codigopostal,
         e9.longitud      AS ubicacion_longitud,
         e9.latitud       AS ubicacion_latitud
  FROM bdm_tempo.stg_nov_ubica_etapa_9_mock e9
  GROUP BY e9.tipo_identificacion, e9.numero_identificacion, e9.info_basica,
           e9.codigo_dane, e9.ciudad, e9.departamento, e9.dato,
           e9.localidad, e9.codigo_postal, e9.longitud, e9.latitud;

  -- ============================================================
  -- CADENA RECAGR: las tres cadenas concatenadas.
  -- Cada una sustituye el trio del legado (token + WITH RECURSIVE + QUALIFY)
  -- por un LISTAGG. La cabecera explica por que y con que equivalencia.
  -- Los nombres r3, r6 y r9 son los del legado, que son los que lee FINAL_1.
  -- ============================================================

  -- ---------- r3: la cadena de TIPO (legado r1 -> r2 -> r3) ----------
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_nov_ubiagr_r3;
  CREATE TABLE bdm_tempo.stg_mock_nov_ubiagr_r3
  DISTSTYLE KEY DISTKEY (info_basica)
  AS
  SELECT z.tipo_identificacion,
         z.numero_identificacion,
         z.info_basica,
         z.ubicacion_dato,
         z.codigo_dane,
         z.ciudad,
         z.departamento,
         CAST(LISTAGG(z.tipo, ' - ')
              WITHIN GROUP (ORDER BY z.token_tipo, z.tipo) AS VARCHAR(30)) AS tipo
  FROM (
    SELECT e9.tipo_identificacion,
           e9.numero_identificacion,
           e9.info_basica,
           e9.dato AS ubicacion_dato,
           e9.codigo_dane,
           e9.ciudad,
           e9.departamento,
           e9.tipo,
           CASE WHEN e9.tipo = 'R' THEN 1
                WHEN e9.tipo = 'L' THEN 2
                WHEN e9.tipo = 'C' THEN 3
                ELSE 4 END AS token_tipo
    FROM bdm_tempo.stg_nov_ubica_etapa_9_mock e9
    GROUP BY e9.tipo_identificacion, e9.numero_identificacion, e9.info_basica,
             e9.ciudad, e9.departamento, e9.dato, e9.codigo_dane, e9.tipo
  ) z
  GROUP BY z.tipo_identificacion, z.numero_identificacion, z.info_basica,
           z.ubicacion_dato, z.codigo_dane, z.ciudad, z.departamento;

  -- ---------- r6: la cadena de FUENTE (legado r4 -> r5 -> r6) ----------
  -- Esta sale de la etapa 2, no de la 9: es la quinta de las columnas que
  -- Ubicacion deja en blanco.
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_nov_ubiagr_r6;
  CREATE TABLE bdm_tempo.stg_mock_nov_ubiagr_r6
  DISTSTYLE KEY DISTKEY (info_basica)
  AS
  SELECT z.tipo_identificacion,
         z.numero_identificacion,
         z.info_basica,
         z.ubicacion_dato,
         z.codigo_dane,
         z.ciudad,
         z.departamento,
         CAST(LISTAGG(z.fuente, ' - ')
              WITHIN GROUP (ORDER BY z.token_tipo, z.fuente) AS VARCHAR(30)) AS fuente
  FROM (
    SELECT e2.tipo_identificacion,
           e2.numero_identificacion,
           e2.info_basica,
           e2.dato AS ubicacion_dato,
           e2.codigo_dane,
           e2.ciudad,
           e2.departamento,
           e2.fuente,
           CASE WHEN e2.fuente = 'SUS'  THEN 1
                WHEN e2.fuente = 'CAM'  THEN 2
                WHEN e2.fuente = 'CONT' THEN 3
                ELSE 4 END AS token_tipo
    FROM bdm_tempo.stg_nov_ubica_etapa_2_mock e2
    GROUP BY e2.tipo_identificacion, e2.numero_identificacion, e2.info_basica,
             e2.dato, e2.codigo_dane, e2.ciudad, e2.departamento, e2.fuente
  ) z
  GROUP BY z.tipo_identificacion, z.numero_identificacion, z.info_basica,
           z.ubicacion_dato, z.codigo_dane, z.ciudad, z.departamento;

  -- ---------- r9: la lista de ID (legado r7 -> r8 -> r9) ----------
  -- Separador coma, no ' - ': lo fija el legado en :6560.
  -- EL CAST A VARCHAR(1000) ES EL DEL LEGADO (:6549 y :6560) y trunca si una
  -- persona acumula mas ubicaciones de las que caben. Se porta igual: un
  -- literal mas largo que su columna es un [REDSHIFT:112], y truncar aqui es
  -- lo que hace el AS-IS.
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_nov_ubiagr_r9;
  CREATE TABLE bdm_tempo.stg_mock_nov_ubiagr_r9
  DISTSTYLE KEY DISTKEY (info_basica)
  AS
  SELECT z.tipo_identificacion,
         z.numero_identificacion,
         z.info_basica,
         z.ubicacion_dato,
         z.codigo_dane,
         z.ciudad,
         z.departamento,
         CAST(LISTAGG(CAST(z.id AS VARCHAR(100)), ',')
              WITHIN GROUP (ORDER BY z.id) AS VARCHAR(1000)) AS id
  FROM (
    SELECT e9.tipo_identificacion,
           e9.numero_identificacion,
           e9.info_basica,
           e9.dato AS ubicacion_dato,
           e9.codigo_dane,
           e9.ciudad,
           e9.departamento,
           e9.cod_dw_ubic AS id
    FROM bdm_tempo.stg_nov_ubica_etapa_9_mock e9
    GROUP BY e9.tipo_identificacion, e9.numero_identificacion, e9.info_basica,
             e9.dato, e9.codigo_dane, e9.ciudad, e9.departamento,
             e9.cod_dw_ubic
  ) z
  GROUP BY z.tipo_identificacion, z.numero_identificacion, z.info_basica,
           z.ubicacion_dato, z.codigo_dane, z.ciudad, z.departamento;

  -- ============================================================
  -- FINAL_1: el join de las siete piezas.
  -- Los cuatro primeros cuelgan de a7 y los tres ultimos de a10, igual que
  -- en el legado (:6695-6786). No se reordena: con INNER JOIN el resultado
  -- es el mismo, pero el diff contra el legado deja de leerse.
  -- ============================================================
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_nov_ubiagr_final1;
  CREATE TABLE bdm_tempo.stg_mock_nov_ubiagr_final1
  DISTSTYLE KEY DISTKEY (info_basica)
  AS
  SELECT c.tipo_identificacion,
         c.numero_identificacion,
         c.info_basica,
         c.codigo_dane,
         c.ciudad,
         c.departamento,
         c.ubicacion_dato,
         c.ubicacion_reportdesde,
         c.ubicacion_ultreporte,
         c.ubicacion_numentidades,
         c.ubicacion_numreportes,
         d.ubicacion_clase,
         d.ubicacion_tipocuenta,
         e.ubicacion_orden,
         e.ubicacion_indicativo,
         e.ubicacion_estrato,
         e.ubicacion_zona,
         f.ciudad       AS ubicacion_ciudad,
         f.departamento AS ubicacion_departamento,
         f.codigo_dane  AS ubicacion_codigodane,
         f.ubicacion_barrio,
         g.ubicacion_localidad,
         g.ubicacion_codigopostal,
         g.ubicacion_longitud,
         g.ubicacion_latitud,
         h.tipo,
         i.fuente,
         j.id
  FROM bdm_tempo.stg_mock_nov_ubiagr_a7 c
  JOIN bdm_tempo.stg_mock_nov_ubiagr_a8 d
    ON c.tipo_identificacion   = d.tipo_identificacion
   AND c.numero_identificacion = d.numero_identificacion
   AND c.info_basica           = d.info_basica
   AND c.ubicacion_dato        = d.ubicacion_dato
   AND c.codigo_dane           = d.codigo_dane
   AND c.ciudad                = d.ciudad
   AND c.departamento          = d.departamento
  JOIN bdm_tempo.stg_mock_nov_ubiagr_a9 e
    ON c.tipo_identificacion   = e.tipo_identificacion
   AND c.numero_identificacion = e.numero_identificacion
   AND c.info_basica           = e.info_basica
   AND c.ubicacion_dato        = e.ubicacion_dato
   AND c.codigo_dane           = e.codigo_dane
   AND c.ciudad                = e.ciudad
   AND c.departamento          = e.departamento
  JOIN bdm_tempo.stg_mock_nov_ubiagr_a10 f
    ON c.tipo_identificacion   = f.tipo_identificacion
   AND c.numero_identificacion = f.numero_identificacion
   AND c.info_basica           = f.info_basica
   AND c.ubicacion_dato        = f.ubicacion_dato
   AND c.codigo_dane           = f.codigo_dane
   AND c.ciudad                = f.ciudad
   AND c.departamento          = f.departamento
  JOIN bdm_tempo.stg_mock_nov_ubiagr_a11 g
    ON c.tipo_identificacion   = g.tipo_identificacion
   AND c.numero_identificacion = g.numero_identificacion
   AND c.info_basica           = g.info_basica
   AND c.ubicacion_dato        = g.ubicacion_dato
   AND c.codigo_dane           = g.codigo_dane
   AND c.ciudad                = g.ciudad
   AND c.departamento          = g.departamento
  JOIN bdm_tempo.stg_mock_nov_ubiagr_r3 h
    ON f.tipo_identificacion   = h.tipo_identificacion
   AND f.numero_identificacion = h.numero_identificacion
   AND f.info_basica           = h.info_basica
   AND f.ubicacion_dato        = h.ubicacion_dato
   AND f.codigo_dane           = h.codigo_dane
   AND f.ciudad                = h.ciudad
   AND f.departamento          = h.departamento
  JOIN bdm_tempo.stg_mock_nov_ubiagr_r6 i
    ON f.tipo_identificacion   = i.tipo_identificacion
   AND f.numero_identificacion = i.numero_identificacion
   AND f.info_basica           = i.info_basica
   AND f.ubicacion_dato        = i.ubicacion_dato
   AND f.codigo_dane           = i.codigo_dane
   AND f.ciudad                = i.ciudad
   AND f.departamento          = i.departamento
  JOIN bdm_tempo.stg_mock_nov_ubiagr_r9 j
    ON f.tipo_identificacion   = j.tipo_identificacion
   AND f.numero_identificacion = j.numero_identificacion
   AND f.info_basica           = j.info_basica
   AND f.ubicacion_dato        = j.ubicacion_dato
   AND f.codigo_dane           = j.codigo_dane
   AND f.ciudad                = j.ciudad
   AND f.departamento          = j.departamento;

  -- ============================================================
  -- ETAPA FINAL: el orden de la ubicacion agregada y el pais.
  --
  -- El ROW_NUMBER particiona por (info_basica, ubicacion_clase) y REUSA el
  -- nombre ubicacion_orden: el de dentro del NVL es el de a9, el de fuera es
  -- el resultado. Aqui el de dentro va cualificado con el alias de la tabla
  -- para que no haya duda de cual es cual -- en el legado (:7148) no lo esta.
  --
  -- CHAR(x) DESC del legado es LONGITUD DESC: Redshift lo escribe LENGTH(x).
  -- Y hash_md5() es la UDF de Teradata; en Redshift MD5() es nativa.
  -- ============================================================
  TRUNCATE TABLE bdm_tempo.stg_nov_ubiagr_etapa_final_mock;

  INSERT INTO bdm_tempo.stg_nov_ubiagr_etapa_final_mock (
    tipo_identificacion, numero_identificacion, info_basica, codigo_dane,
    ciudad, departamento, ubicacion_dato, ubicacion_reportdesde,
    ubicacion_ultreporte, ubicacion_numentidades, ubicacion_numreportes,
    ubicacion_clase, ubicacion_tipocuenta, ubicacion_orden,
    ubicacion_indicativo, ubicacion_estrato, ubicacion_zona, ubicacion_ciudad,
    ubicacion_departamento, ubicacion_codigodane, ubicacion_barrio,
    ubicacion_localidad, ubicacion_codigopostal, ubicacion_longitud,
    ubicacion_latitud, tipo, fuente, id, cod_pais, flag_op
  )
  SELECT a.tipo_identificacion,
         a.numero_identificacion,
         a.info_basica,
         a.codigo_dane,
         a.ciudad,
         a.departamento,
         a.ubicacion_dato,
         a.ubicacion_reportdesde,
         a.ubicacion_ultreporte,
         a.ubicacion_numentidades,
         a.ubicacion_numreportes,
         a.ubicacion_clase,
         a.ubicacion_tipocuenta,
         CAST(ROW_NUMBER() OVER (
                PARTITION BY a.info_basica, a.ubicacion_clase
                ORDER BY COALESCE(a.ubicacion_orden, 999) ASC,
                         a.ubicacion_reportdesde  DESC NULLS LAST,
                         a.ubicacion_ultreporte   DESC NULLS LAST,
                         a.ubicacion_numreportes  DESC NULLS LAST,
                         LENGTH(a.tipo)           DESC NULLS LAST,
                         a.tipo                   ASC,
                         LENGTH(a.ubicacion_dato) DESC NULLS LAST,
                         a.codigo_dane            DESC NULLS LAST,
                         a.ubicacion_ciudad       DESC NULLS LAST,
                         a.ubicacion_departamento DESC NULLS LAST,
                         a.id                     ASC,
                         MD5(a.ubicacion_dato)    ASC
              ) AS INTEGER)                         AS ubicacion_orden,
         a.ubicacion_indicativo,
         a.ubicacion_estrato,
         a.ubicacion_zona,
         a.ubicacion_ciudad,
         a.ubicacion_departamento,
         a.ubicacion_codigodane,
         a.ubicacion_barrio,
         a.ubicacion_localidad,
         a.ubicacion_codigopostal,
         a.ubicacion_longitud,
         a.ubicacion_latitud,
         a.tipo,
         a.fuente,
         a.id,
         -- BLOQUEADA: falta V_PAIS. El CROSS JOIN del legado (:7175-7178) no
         -- se porta; contra una vista inexistente dejaria la etapa vacia.
         CAST(NULL AS VARCHAR(3))                   AS cod_pais,
         CAST('I' AS VARCHAR(1))                    AS flag_op
  FROM bdm_tempo.stg_mock_nov_ubiagr_final1 a;

  -- ============================================================
  -- Las intermedias no sobreviven a la corrida: bdm_tempo es compartido y una
  -- tabla huerfana confunde al siguiente que mire. Mismo cierre que los otros
  -- dos dominios. La etapa final SI sobrevive: la lee el cargador.
  -- ============================================================
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_nov_ubiagr_final1;
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_nov_ubiagr_r9;
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_nov_ubiagr_r6;
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_nov_ubiagr_r3;
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_nov_ubiagr_a11;
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_nov_ubiagr_a10;
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_nov_ubiagr_a9;
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_nov_ubiagr_a8;
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_nov_ubiagr_a7;
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_nov_ubiagr_a6;
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_nov_ubiagr_a5;
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_nov_ubiagr_a4;
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_nov_ubiagr_a3;
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_nov_ubiagr_a2;
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_nov_ubiagr_a1;

END;
$$;
