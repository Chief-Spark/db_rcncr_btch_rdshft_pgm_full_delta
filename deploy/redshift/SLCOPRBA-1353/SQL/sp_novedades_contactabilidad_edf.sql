-- ============================================================
-- sp_novedades_contactabilidad_edf.sql
-- SLCOPRBA-1399: dominio CONTACTABILIDAD de Novedades, via REAL.
-- (repo pgm / db_rcncr_btch_rdshft_pgm)
-- UTF-8 sin BOM. Sin acentos a proposito.
--
-- LEGADO: PRO_Novedad_Linea_Contact (Novedad.sql:186-1059).
--
-- ------------------------------------------------------------
-- ESTO NO ES UN PORT DE LAS SIETE ETAPAS: ES UNA TABLA CON DOS COLUMNAS
-- POBLADAS Y DIEZ EN NULL, Y ESO ES DELIBERADO (D-NOV-08).
--
-- Las siete etapas del legado existen para resumir EVENTOS DE GESTION --
-- alguien llamo a ese numero tal dia a tal hora y paso tal cosa -- que
-- entran enteros por REC_VISTA.V_CONTACTABILIDAD, una de las seis fuentes
-- del buro (V_Fuente, Cod_Dw_Fuente = 31937). Sin eventos no hay nada que
-- resumir, de modo que portar la cascada seria portar siete CREATE TABLE
-- vacios.
--   Verificado que la fuente no existe de este lado: no esta en
--   svv_all_columns de ds_dba_rncr_batch.edf_views (buscado contact,
--   gestion, effect, result, call, attempt); no esta en la documentacion de
--   EDF (la seccion contactInformations del contrato Alpha tiene nueve
--   campos y los nueve son el dato de contacto, no la gestion -- Confluence
--   CCBR 251264536, 2026-10-21); y el cargador de la fuente 31937 no esta en
--   el material entregado.
--
-- LAS DOS QUE SE POBLAN LO HACEN CON UN EQUIVALENTE DE OTRA SEMANTICA.
-- DECISION DEL USUARIO, 2026-10-21, tomada sabiendo esto:
--
--   fecha_ultimo_contacto <- rpu.fecha_relacion_persona_ubicaci, que es
--       ContactEventLastUpdated. El legado pone MAX(FECHA_GESTION)
--       (Novedad.sql:855): la ultima vez que alguien CONTACTO la ubicacion.
--       Esto es la ultima vez que se ACTUALIZO EL DATO. Un telefono puede
--       reportarse cien veces sin que nadie lo haya marcado nunca.
--
--   reportado_por <- r.id_buro_suscriptor del reporte mas reciente. El
--       legado pone CTB.ID_BURO_SUSCRIPTOR (Novedad.sql:598): quien
--       GESTIONO. Esto es quien REPORTO.
--
-- LAS OTRAS DIEZ SE QUEDAN EN NULL A PROPOSITO Y NO EN UN VALOR POR DEFECTO.
-- NULL dice "no hay con que medir"; un 'NO' en contactabilidad diria "se
-- intento contactar y no se pudo", que es falso y lo leeria asi el Batch. Es
-- la misma distincion de las cuatro columnas por_* del censo de Ordenamiento
-- (F1-08) y la leccion de NOV-UB-12: un dato ausente tiene que verse
-- ausente.
--
-- ------------------------------------------------------------
-- EL UNIVERSO SALE DE LA ETAPA 9 DE UBICACION, y eso es paridad real: las
-- cuatro consultas del legado que leen V_CONTACTABILIDAD la cruzan con
-- INNER JOIN TMP_UBICA_ETAPA_9 (Novedad.sql:272, :357, :432, :618).
-- Contactabilidad no describe ubicaciones que Ubicacion no haya validado.
-- Por eso este SP corre DESPUES de Ubicacion en el orquestador.
--
-- GRANO: una fila por ubicacion_id. La llave del legado son las tres
-- columnas (ID, SECTOR, UBICACION_ID) -- PRIMARY INDEX de Novedad.sql:885 y
-- predicado del UPSERT en 130.TPT:871-873 -- y de las tres solo ubicacion_id
-- tiene valor por esta via, de modo que el grano colapsa a ella. No es una
-- eleccion nuestra: es la consecuencia de que id y sector esten en NULL.
--
-- CONTRATO DE CARGA: FOTO COMPLETA, igual que el AS-IS. El 111.BTQ:820 hace
-- DELETE ... ALL antes de cargar y el UPSERT del 130.TPT opera siempre sobre
-- una tabla vacia. Aqui es TRUNCATE + INSERT, y por eso NO hay cargador
-- aparte ni tabla de Severidad: sin estado previo que comparar, la Severidad
-- no decide nada.
--
-- FIRMA: (INTEGER). No es orquestador, asi que no lleva los 6 VARCHAR del
-- Framework Batch; recibe solo el lote, igual que los tres cargadores.
-- NONATOMIC en toda la cadena de CALL.
-- ============================================================
CREATE OR REPLACE PROCEDURE bdm_datos.sp_novedades_contactabilidad_edf(
    p_lote INTEGER
)
NONATOMIC
LANGUAGE plpgsql
AS $$
BEGIN

  TRUNCATE TABLE bdm_datos.mat_info_contactabilidad;

  INSERT INTO bdm_datos.mat_info_contactabilidad (
    id, contactabilidad, fecha_ultimo_contacto, fecha_gestion,
    mejor_dia_gestion, mejor_hora_gestion, reportado_por, sector,
    ubicacion_id, peso, mejor_resultado_3meses, mejor_resultado_6meses,
    lote, fecha_actualizacion, usuario_bd
  )
  SELECT CAST(NULL AS BIGINT)         AS id,
         CAST(NULL AS VARCHAR(2))     AS contactabilidad,
         u.fecha_ultimo_contacto,
         CAST(NULL AS TIMESTAMP)      AS fecha_gestion,
         CAST(NULL AS VARCHAR(10))    AS mejor_dia_gestion,
         CAST(NULL AS VARCHAR(20))    AS mejor_hora_gestion,
         u.reportado_por,
         CAST(NULL AS VARCHAR(100))   AS sector,
         u.ubicacion_id,
         CAST(NULL AS BIGINT)         AS peso,
         CAST(NULL AS VARCHAR(100))   AS mejor_resultado_3meses,
         CAST(NULL AS VARCHAR(100))   AS mejor_resultado_6meses,
         p_lote, GETDATE(), CURRENT_USER
  FROM (
    -- El ranking va en una subconsulta del FROM y NO en la lista del SELECT:
    -- una subconsulta escalar en la proyeccion la rechaza Redshift en
    -- EJECUCION con XX000, y el banco sobre PostgreSQL no la caza (es el
    -- tercer punto ciego, el que tumbo el job #407 en NOV-UB-14).
    SELECT e9.id                                      AS ubicacion_id,
           MAX(rpu.fecha_relacion_persona_ubicaci)    AS fecha_ultimo_contacto,
           -- El suscriptor del reporte MAS RECIENTE. Quien lo elige es la
           -- ventana de la derivada `ult`, que ya deja una fila por
           -- ubicacion; este MAX() solo existe para satisfacer el GROUP BY.
           MAX(ult.id_buro_suscriptor)                AS reportado_por
    FROM   bdm_tempo.stg_nov_ubica_etapa_9 e9
    LEFT JOIN bdm_tempo.v_xpm_relacion_persona_ubicacion rpu
           ON rpu.cod_dw_persona_ubic = e9.id
    LEFT JOIN (
      SELECT cod_dw_persona_ubic,
             id_buro_suscriptor
      FROM (
        SELECT r.cod_dw_persona_ubic,
               r.id_buro_suscriptor,
               ROW_NUMBER() OVER (
                 PARTITION BY r.cod_dw_persona_ubic
                 ORDER BY r.fecha_reporte DESC NULLS LAST,
                          r.id_buro_suscriptor DESC NULLS LAST
               ) AS rn
        FROM bdm_tempo.v_xpm_reporte_relacion_persona_ubica r
      ) q
      WHERE q.rn = 1
    ) ult
           ON ult.cod_dw_persona_ubic = e9.id
    GROUP BY e9.id
  ) u;

END;
$$;
