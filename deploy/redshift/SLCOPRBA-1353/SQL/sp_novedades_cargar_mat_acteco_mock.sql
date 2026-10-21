-- Novedades - carga de la tabla final del dominio ACTIVIDAD ECONOMICA (ESPEJO MOCK)
-- Espejo de sp_novedades_cargar_mat_acteco_edf.sql. Generado por SUSTITUCION DE
-- FUENTES: no se edita a mano. Regenerar con
-- tools/gen_novedades_espejo_acteco.py.
-- Solo cambian los nombres de los objetos: _edf -> _mock en los
-- procedimientos, v_xpm_* -> v_mock_*, sufijo _mock en el contrato y
-- en la tabla final, y stg_nov_* -> stg_mock_nov_* en el staging.
-- El diff contra el real debe salir vacio modulo esos nombres.

CREATE OR REPLACE PROCEDURE bdm_datos.sp_novedades_cargar_mat_acteco_mock(
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
  -- LA LLAVE DEL LEFT JOIN SON TRES COLUMNAS, NO UNA. CORREGIDO 2026-10-21.
  --
  -- El legado une STG con la MAT por
  --   STG.INFO_BASICA_ID = B.INFO_BASICA_ID
  --   AND STG.CIIU       = B.CIIU
  --   AND STG.FECHA_REPORTE = B.FECHA_REPORTE
  -- (P0035_Extractor_Novedades_120.TPT:200-202).
  --
  -- Aqui se unia SOLO por info_basica_id contra un agregado por persona, y
  -- eso PERDIA FILAS. El camino es concreto: una persona que YA esta en la
  -- MAT recibe un CIIU NUEVO. En el legado ese CIIU no casa con ninguna fila,
  -- B.* sale NULL y la primera rama del CASE le da Severidad = 1, de modo que
  -- entra. Aqui b.info_basica_id NO era NULL -- la persona existe --, caia en
  -- la segunda rama y se comparaba contra el MAX(actividad_economica) y el
  -- MAX(version) de TODAS sus actividades: si no los superaba, salia -1 y la
  -- actividad nueva se perdia en silencio.
  --
  -- IMPORTA MAS DESDE HOY: con D-NOV-06 el universo pasa a ser todas las
  -- actividades de la persona, no solo el CIIU principal, asi que una persona
  -- con varias actividades es el caso normal y no el raro.
  --
  -- SE SIGUE AGREGANDO, PERO POR LA LLAVE COMPLETA, y ese es el motivo de que
  -- la tabla de apoyo no desaparezca: la MAT es insert-only, de modo que la
  -- misma (persona, ciiu, fecha) puede estar repetida de corridas anteriores y
  -- un join directo multiplicaria la etapa. El legado tiene ese defecto y
  -- aqui no se copia. El MAX ya no mezcla actividades distintas: desempata
  -- dentro de la MISMA llave, que es lo que un dedup necesita.
  --
  -- (La version anterior de este comentario citaba 120.TPT:198-199 para
  -- justificar la llave de una columna. Esas dos lineas son el CROSS JOIN y
  -- la cabecera del LEFT JOIN; la condicion esta en :200-202 y dice lo
  -- contrario.)
  -- ------------------------------------------------------------
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_nov_acteco_viva;
  CREATE TABLE bdm_tempo.stg_mock_nov_acteco_viva
  DISTSTYLE KEY DISTKEY(info_basica_id)
  AS
  SELECT info_basica_id,
         ciiu,
         fecha_reporte,
         MAX(actividad_economica) AS actividad_economica,
         MAX(version)             AS version
  FROM bdm_datos.mat_info_actividad_economica_mock
  GROUP BY info_basica_id, ciiu, fecha_reporte;

  DROP TABLE IF EXISTS bdm_tempo.stg_mock_nov_acteco_sev;
  CREATE TABLE bdm_tempo.stg_mock_nov_acteco_sev
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
  FROM      bdm_tempo.stg_nov_acteco_etapa_1_mock s
  LEFT JOIN bdm_tempo.stg_mock_nov_acteco_viva    b
         ON  b.info_basica_id = s.info_basica_id
         AND b.ciiu           = s.ciiu
         AND b.fecha_reporte  = s.fecha_reporte;

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
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_nov_acteco_maxid;
  CREATE TABLE bdm_tempo.stg_mock_nov_acteco_maxid
  DISTSTYLE ALL
  AS
  SELECT COALESCE(MAX(id), 0) AS max_id
  FROM bdm_datos.mat_info_actividad_economica_mock;

  INSERT INTO bdm_datos.mat_info_actividad_economica_mock (
    id, ciiu, actividad_economica, version, fecha_reporte,
    info_basica_id, tipo_identificacion, numero_identificacion,
    lote, fecha_actualizacion, usuario_bd
  )
  SELECT
    CAST(x.max_id + ROW_NUMBER() OVER (ORDER BY s.info_basica_id, s.ciiu) AS INTEGER),
    s.ciiu, s.actividad_economica, s.version, s.fecha_reporte,
    s.info_basica_id, s.tipo_identificacion, s.numero_identificacion,
    p_lote, GETDATE(), CURRENT_USER
  FROM       bdm_tempo.stg_mock_nov_acteco_sev   s
  CROSS JOIN bdm_tempo.stg_mock_nov_acteco_maxid x
  WHERE s.severidad = 1;

  DROP TABLE IF EXISTS bdm_tempo.stg_mock_nov_acteco_maxid;

  DROP TABLE IF EXISTS bdm_tempo.stg_mock_nov_acteco_viva;
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_nov_acteco_sev;

END;
$$;
