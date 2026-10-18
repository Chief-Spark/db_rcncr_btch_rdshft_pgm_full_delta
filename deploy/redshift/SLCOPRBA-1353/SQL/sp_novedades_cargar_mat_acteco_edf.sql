-- Novedades - carga de la tabla final del dominio ACTIVIDAD ECONOMICA
-- Port de lo que en el legado hacen los dos TPT, no un SP:
--   P0035_Extractor_Novedades_120.TPT:176-199  vista Vstg_Reconocer_Actividad_Econo
--   P0035_Extractor_Novedades_130.TPT:215      filtro Severidad <> -1
--   P0035_Extractor_Novedades_130.TPT:710-757  UPSERT y DELETE por ID
-- Fuente: bdm_tempo.stg_nov_acteco_etapa_1
-- Salida: bdm_datos.mat_info_actividad_economica
--
-- ------------------------------------------------------------
-- AQUI SEVERIDAD SI HAY QUE CALCULARLA, al reves que en Ubicacion.
--   Alli flag_op (I|A|E) ya traia la decision y el filtro era
--   'flag_op IS NOT NULL'. Aqui no alcanza: la Severidad de este dominio
--   compara ADEMAS el contenido contra la tabla viva (120.TPT:186-197):
--
--     WHEN FLAG_OP = 'I' AND B.INFO_BASICA_ID IS NULL                 -> 1
--     WHEN (FLAG_OP = 'A' OR B.INFO_BASICA_ID IS NOT NULL)
--          AND (COALESCE(STG.ACTIVIDAD_ECONOMICA,'SV')
--               <> COALESCE(B.ACTIVIDAD_ECONOMICA,'SV')
--            OR COALESCE(STG.VERSION,-1) <> COALESCE(B.VERSION,-1))   -> 1
--     WHEN B.INFO_BASICA_ID IS NULL                                   -> 1
--     ELSE                                                            -> -1
--
--   Se porta literal, centinelas 'SV' y -1 incluidos. Son los mismos
--   centinelas inconsistentes que ya documentamos en Ubicacion.
--
--   Las tres ramas se reducen a: ES NUEVA, o YA ESTABA Y CAMBIO. Se escribe
--   asi, desplegada, y no simplificada, para que el diff contra el legado se
--   pueda leer linea a linea.
--
-- ------------------------------------------------------------
-- DOS RAMAS DEL LEGADO QUE NO SE EJECUTAN NUNCA. No son un olvido del port:
-- estan en el legado y tampoco se ejecutan alli. Portarlas "mejoradas" seria
-- divergir.
--
--   EL DELETE. El 130.TPT lleva 'WHEN IN_Severidad = 2 THEN DELETE' (:753),
--   pero el CASE de arriba no tiene ninguna rama que devuelva 2. Esta tabla
--   no pierde filas jamas. Es la segunda vez que aparece el patron: en
--   Ubicacion el DELETE moria por flag_op='E', que es codigo muerto.
--
--   EL UPDATE DEL UPSERT. ID se asigna como MAX(ID) + row_number() sobre la
--   tabla VIVA (120.TPT:177), de modo que cada fila preparada estrena un ID
--   por encima del maximo y el 'UPDATE ... WHERE ID = :IN_ID' (:722) no
--   encuentra nada. El 'INSERT FOR MISSING UPDATE ROWS' (:750) inserta
--   siempre. La tabla solo crece.
--
--   POR ESO AQUI NO HAY DELETE Y SOLO HAY INSERT, y no por simplificar.
--   [REDSHIFT:232] no aplica: no hay UPDATE ni DELETE de nivel superior.
--
--   LO QUE ESTO IMPLICA Y HAY QUE VIGILAR: una persona cuyo CIIU cambie de
--   descripcion acumula una fila nueva en cada corrida. Hoy no pasa porque
--   actividad_economica y version salen NULL por falta del catalogo, y
--   COALESCE(NULL,'SV') <> COALESCE(NULL,'SV') es falso. El dia que el
--   catalogo llegue, volvera: es comportamiento del legado y la decision de
--   corregirlo o no es funcional, no de migracion. NOV-AE-05 lo mide.
--
-- NONATOMIC (leccion #13).

CREATE OR REPLACE PROCEDURE bdm_datos.sp_novedades_cargar_mat_acteco_edf(
    p_lote INTEGER
)
NONATOMIC
LANGUAGE plpgsql
AS $$
BEGIN

  -- ------------------------------------------------------------
  -- Severidad, materializada. No va como subconsulta en la proyeccion: es la
  -- trampa que tumbo el job DEV/DATABASE #407 con
  --   XX000: This type of correlated subquery pattern is not supported
  -- y que el banco local no ve porque PostgreSQL la ejecuta sin una queja.
  --
  -- El LEFT JOIN contra un agregado por info_basica_id sustituye al LEFT JOIN
  -- directo del legado: la tabla final puede tener VARIAS filas por persona
  -- -- justo porque el upsert nunca actualiza -- y un join directo
  -- multiplicaria la etapa. El legado tiene ese mismo defecto y alli se nota;
  -- aqui se agrega primero y se compara contra la ultima version conocida.
  -- ------------------------------------------------------------
  DROP TABLE IF EXISTS bdm_tempo.stg_nov_acteco_viva;
  CREATE TABLE bdm_tempo.stg_nov_acteco_viva
  DISTSTYLE KEY DISTKEY(info_basica_id)
  AS
  SELECT info_basica_id,
         MAX(actividad_economica) AS actividad_economica,
         MAX(version)             AS version
  FROM bdm_datos.mat_info_actividad_economica
  GROUP BY info_basica_id;

  DROP TABLE IF EXISTS bdm_tempo.stg_nov_acteco_sev;
  CREATE TABLE bdm_tempo.stg_nov_acteco_sev
  DISTSTYLE KEY DISTKEY(info_basica_id)
  AS
  SELECT s.id, s.tipo_identificacion, s.numero_identificacion, s.ciiu,
         s.actividad_economica, s.version, s.fecha_reporte, s.info_basica_id,
         CASE
           WHEN s.flag_op = 'I' AND b.info_basica_id IS NULL THEN 1
           WHEN (s.flag_op = 'A' OR b.info_basica_id IS NOT NULL)
                AND ( COALESCE(s.actividad_economica, 'SV') <> COALESCE(b.actividad_economica, 'SV')
                   OR COALESCE(s.version, -1)               <> COALESCE(b.version, -1) ) THEN 1
           WHEN b.info_basica_id IS NULL THEN 1
           ELSE -1
         END AS severidad
  FROM      bdm_tempo.stg_nov_acteco_etapa_1 s
  LEFT JOIN bdm_tempo.stg_nov_acteco_viva    b ON b.info_basica_id = s.info_basica_id;

  -- ------------------------------------------------------------
  -- El id: MAX(id) de la tabla viva mas la posicion de la fila, que es lo que
  -- hace la vista de staging con
  --   Max_ID + CAST(SUM(1) OVER (ROWS UNBOUNDED PRECEDING) AS INTEGER)
  -- (120.TPT:177) sobre un CROSS JOIN con COALESCE(MAX(ID),0).
  --
  -- ROW_NUMBER y no SUM(1) OVER: son lo mismo sobre una ventana sin
  -- particion, y ROW_NUMBER no necesita la clausula de marco. El ORDER BY va
  -- explicito y por una columna estable, para que dos corridas sobre los
  -- mismos datos asignen los mismos ids -- el legado no lo garantiza y
  -- nosotros si, sin coste.
  --
  -- EL MAXIMO VA MATERIALIZADO Y CON CROSS JOIN, NO COMO SUBCONSULTA EN LA
  -- PROYECCION. Es literalmente lo que hace el legado -- un
  -- 'CROSS JOIN (SELECT COALESCE(MAX(ID),0) Max_ID FROM ...) A'
  -- (120.TPT:178-179) -- y ademas evita el patron que tumbo el job #407 con
  -- XX000. El chequeo 10 de validar.sh avisa de el por algo.
  --
  -- Solo entran las Severidad = 1: el -1 lo descarta el 130.TPT:215.
  -- ------------------------------------------------------------
  DROP TABLE IF EXISTS bdm_tempo.stg_nov_acteco_maxid;
  CREATE TABLE bdm_tempo.stg_nov_acteco_maxid
  DISTSTYLE ALL
  AS
  SELECT COALESCE(MAX(id), 0) AS max_id
  FROM bdm_datos.mat_info_actividad_economica;

  INSERT INTO bdm_datos.mat_info_actividad_economica (
    id, ciiu, actividad_economica, version, fecha_reporte,
    info_basica_id, tipo_identificacion, numero_identificacion,
    lote, fecha_actualizacion, usuario_bd
  )
  SELECT
    CAST(x.max_id + ROW_NUMBER() OVER (ORDER BY s.info_basica_id, s.ciiu) AS INTEGER),
    s.ciiu, s.actividad_economica, s.version, s.fecha_reporte,
    s.info_basica_id, s.tipo_identificacion, s.numero_identificacion,
    p_lote, GETDATE(), CURRENT_USER
  FROM       bdm_tempo.stg_nov_acteco_sev   s
  CROSS JOIN bdm_tempo.stg_nov_acteco_maxid x
  WHERE s.severidad = 1;

  DROP TABLE IF EXISTS bdm_tempo.stg_nov_acteco_maxid;

  DROP TABLE IF EXISTS bdm_tempo.stg_nov_acteco_viva;
  DROP TABLE IF EXISTS bdm_tempo.stg_nov_acteco_sev;

END;
$$;
