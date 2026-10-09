-- SLCOPRBA-1355 (Fase 5): gate por ARQUETIPO de la Unificacion mock.
--
-- Los validadores que ya existian (validacion_unificacion_conteos,
-- validacion_unificacion_gates_full_delta) miran totales globales: dicen
-- "salieron 55 000 filas", no "E4 disparo por esc4 y E7 por X4". Este gate
-- compara arquetipo por arquetipo contra la matriz de
-- dt/docs/RESULTADOS_ESPERADOS_MOCK.md, que es lo que convierte "corrio" en
-- "certificado".
--
-- ARQ se deriva de la clave de la semilla:
--     id_buro_persona     = 9000000 + ARQ * 10000 + replica
--     cod_dw_persona_ubic = id_buro_persona * 10 + k
-- de donde  ARQ = (cod_dw_persona_ubic / 10 - 9000000) / 10000.
--
-- Se acota a BETWEEN 90100000 AND 95609999, el rango de la semilla: las
-- direcciones que genera el motor llevan clave FNV_HASH y calcularian un ARQ
-- sin sentido. Hoy no pueden aparecer como HIJA (nacen sin unificar y quedan
-- solas en su grupo), pero el filtro lo garantiza aunque eso cambie.
--
-- p_fase selecciona que criterios aplican:
--   FULL    la matriz completa
--   DELTA1  un DELTA sobre datos SIN MUTAR no produce filas nuevas
--   DELTA2  idem, mas la mutacion ya aplicada (ver mutacion_mock.sql)
-- Los criterios estructurales (un hijo un padre, sin padres huerfanos) corren
-- en todas las fases.
CREATE OR REPLACE PROCEDURE bdm_datos.sp_unificacion_mock_gate_arq(
    p_fase VARCHAR,   -- FULL | DELTA1 | DELTA2
    p_lote INTEGER    -- Lote_Corrida de la corrida que se acaba de evaluar
)
NONATOMIC
LANGUAGE plpgsql
AS $$
BEGIN

  DELETE FROM bdm_stage.mock_unif_ca_result
   WHERE criterio_ca LIKE p_fase || '/%';

  DROP TABLE IF EXISTS bdm_tempo.stg_gate_arq_esperado;
  DROP TABLE IF EXISTS bdm_tempo.stg_gate_arq_real;

  -- Matriz esperada del FULL, filas por PERSONA. Explicita a proposito: un gate
  -- de certificacion se audita leyendolo, no deduciendolo.
  CREATE TABLE bdm_tempo.stg_gate_arq_esperado
  DISTSTYLE ALL
  AS
  SELECT v.arq, v.filas_persona
  FROM (
    SELECT  1 AS arq, 1 AS filas_persona UNION ALL
    SELECT  2, 1 UNION ALL
    SELECT  3, 1 UNION ALL
    SELECT  4, 1 UNION ALL
    SELECT  5, 0 UNION ALL
    SELECT  6, 1 UNION ALL
    SELECT  7, 1 UNION ALL
    SELECT  8, 1 UNION ALL
    SELECT  9, 1 UNION ALL
    SELECT 10, 0 UNION ALL
    SELECT 11, 1 UNION ALL
    SELECT 12, 1 UNION ALL
    SELECT 13, 1 UNION ALL
    SELECT 14, 1 UNION ALL
    SELECT 15, 0 UNION ALL
    SELECT 16, 0 UNION ALL
    SELECT 17, 0 UNION ALL
    SELECT 18, 0 UNION ALL
    SELECT 19, 0 UNION ALL
    SELECT 20, 0 UNION ALL
    SELECT 21, 1 UNION ALL
    SELECT 22, 1 UNION ALL
    SELECT 23, 1 UNION ALL
    SELECT 24, 1 UNION ALL
    SELECT 25, 0 UNION ALL
    SELECT 26, 1 UNION ALL
    SELECT 27, 1 UNION ALL
    SELECT 28, 1 UNION ALL
    SELECT 29, 1 UNION ALL
    SELECT 30, 0 UNION ALL
    SELECT 31, 1 UNION ALL
    SELECT 32, 1 UNION ALL
    SELECT 33, 1 UNION ALL
    SELECT 34, 1 UNION ALL
    SELECT 35, 0 UNION ALL
    SELECT 36, 1 UNION ALL
    SELECT 37, 1 UNION ALL
    SELECT 38, 1 UNION ALL
    SELECT 39, 1 UNION ALL
    SELECT 40, 0 UNION ALL
    SELECT 41, 1 UNION ALL
    SELECT 42, 1 UNION ALL
    SELECT 43, 1 UNION ALL
    SELECT 44, 1 UNION ALL
    SELECT 45, 0 UNION ALL
    SELECT 46, 2 UNION ALL
    SELECT 47, 2 UNION ALL
    SELECT 48, 2 UNION ALL
    SELECT 49, 2 UNION ALL
    SELECT 50, 0 UNION ALL
    SELECT 51, 3 UNION ALL
    SELECT 52, 3 UNION ALL
    SELECT 53, 3 UNION ALL
    SELECT 54, 3 UNION ALL
    SELECT 55, 2 UNION ALL
    SELECT 56, 1
  ) v;

  CREATE TABLE bdm_tempo.stg_gate_arq_real
  DISTSTYLE ALL
  AS
  SELECT
    CAST((u.cod_dw_persona_ubic / 10 - 9000000) / 10000 AS INTEGER) AS arq,
    COUNT(*)                                                        AS filas,
    COUNT(DISTINCT u.cod_dw_persona_ubic / 10)                      AS personas,
    SUM(CASE WHEN u.lote = p_lote THEN 1 ELSE 0 END)                AS filas_del_lote
  FROM bdm_datos.unificacion_direccion_mock u
  WHERE u.cod_dw_persona_ubic BETWEEN 90100000 AND 95609999
  GROUP BY 1;

  -- ------------------------------------------------------------------
  -- FULL: la matriz, arquetipo por arquetipo
  -- ------------------------------------------------------------------
  IF p_fase = 'FULL' THEN

    INSERT INTO bdm_stage.mock_unif_ca_result (criterio_ca, estado, detalle)
    SELECT
      'FULL/CA-U01',
      CASE WHEN COUNT(*) = 0 THEN 'PASSED' ELSE 'FAILED' END,
      'arquetipos que no cuadran=' || CAST(COUNT(*) AS VARCHAR) || ' ' ||
      COALESCE(LISTAGG('ARQ ' || CAST(x.arq AS VARCHAR)
                       || ': esperado ' || CAST(x.esperado AS VARCHAR)
                       || ', real ' || CAST(x.real_filas AS VARCHAR), ' | ')
               WITHIN GROUP (ORDER BY x.arq), 'todos cuadran')
    FROM (
      SELECT e.arq,
             e.filas_persona * 1000       AS esperado,
             COALESCE(r.filas, 0)         AS real_filas
      FROM       bdm_tempo.stg_gate_arq_esperado e
      LEFT JOIN  bdm_tempo.stg_gate_arq_real     r ON r.arq = e.arq
      WHERE e.filas_persona * 1000 <> COALESCE(r.filas, 0)
    ) x;

    INSERT INTO bdm_stage.mock_unif_ca_result (criterio_ca, estado, detalle)
    SELECT 'FULL/CA-U02',
           CASE WHEN SUM(filas) = 55000 THEN 'PASSED' ELSE 'FAILED' END,
           'total unificacion_direccion_mock=' || CAST(COALESCE(SUM(filas), 0) AS VARCHAR)
             || ' (esperado 55000)'
    FROM bdm_tempo.stg_gate_arq_real;

    INSERT INTO bdm_stage.mock_unif_ca_result (criterio_ca, estado, detalle)
    SELECT 'FULL/CA-U03',
           CASE WHEN COUNT(*) = 5000
                 AND SUM(CASE WHEN COALESCE(d.generada_enriquecida, 0) = 1 THEN 0 ELSE 1 END) = 0
                THEN 'PASSED' ELSE 'FAILED' END,
           'direcciones generadas=' || CAST(COUNT(*) AS VARCHAR) || ' (esperado 5000), sin marca='
             || CAST(SUM(CASE WHEN COALESCE(d.generada_enriquecida, 0) = 1 THEN 0 ELSE 1 END) AS VARCHAR)
    FROM bdm_datos.direccion_fisica_generada_mock d;

    -- El complemento que el motor arma para E7. Es el criterio que distingue
    -- "el motor corrio" de "el motor fusiono bien": lleva el complemento del
    -- padre al frente, el aporte de los hijos ordenado por nivel (TO=4, CS=5) y
    -- TO deduplicado, que lo aportan los DOS hijos.
    INSERT INTO bdm_stage.mock_unif_ca_result (criterio_ca, estado, detalle)
    SELECT 'FULL/CA-U04',
           CASE WHEN COUNT(*) = 5000 THEN 'PASSED' ELSE 'FAILED' END,
           'generadas con complemento ''AP 9 TO 2 CS 4''=' || CAST(COUNT(*) AS VARCHAR)
             || ' (esperado 5000)'
    FROM bdm_datos.direccion_fisica_generada_mock d
    WHERE TRIM(d.complemento) = 'AP 9 TO 2 CS 4';

  END IF;

  -- ------------------------------------------------------------------
  -- DELTA: cuantas filas aporto ESTA corrida
  -- ------------------------------------------------------------------
  IF p_fase = 'DELTA1' THEN
    -- Sobre datos sin mutar no debe aportar NADA. Es la afirmacion que el
    -- filtro de estado hace posible: antes de M7 cada DELTA re-procesaba todo.
    INSERT INTO bdm_stage.mock_unif_ca_result (criterio_ca, estado, detalle)
    SELECT 'DELTA1/CA-U07',
           CASE WHEN COALESCE(SUM(filas_del_lote), 0) = 0 THEN 'PASSED' ELSE 'FAILED' END,
           'filas nuevas del lote ' || CAST(p_lote AS VARCHAR) || '='
             || CAST(COALESCE(SUM(filas_del_lote), 0) AS VARCHAR) || ' (esperado 0)'
    FROM bdm_tempo.stg_gate_arq_real;
  END IF;

  IF p_fase = 'DELTA2' THEN
    -- Tras la mutacion: 100 direcciones nuevas en ARQ 21 y 100 en ARQ 22, cada
    -- una se unifica contra el padre de su grupo -> 100 + 100 filas nuevas.
    INSERT INTO bdm_stage.mock_unif_ca_result (criterio_ca, estado, detalle)
    SELECT 'DELTA2/CA-U08',
           CASE WHEN COALESCE(SUM(CASE WHEN arq = 21 THEN filas_del_lote END), 0) = 100
                 AND COALESCE(SUM(CASE WHEN arq = 22 THEN filas_del_lote END), 0) = 100
                 AND COALESCE(SUM(filas_del_lote), 0) = 200
                THEN 'PASSED' ELSE 'FAILED' END,
           'ARQ21=' || CAST(COALESCE(SUM(CASE WHEN arq = 21 THEN filas_del_lote END), 0) AS VARCHAR)
             || ' ARQ22=' || CAST(COALESCE(SUM(CASE WHEN arq = 22 THEN filas_del_lote END), 0) AS VARCHAR)
             || ' total=' || CAST(COALESCE(SUM(filas_del_lote), 0) AS VARCHAR)
             || ' (esperado 100 / 100 / 200)'
    FROM bdm_tempo.stg_gate_arq_real;

    -- CONTRAFACTUAL DEL DISENO 2. ARQ 22 es la posicion FUERA: su fecha
    -- original (2024-01-15) queda fuera de la ventana. Solo entra porque le
    -- LLEGO una direccion nueva, y arrastra consigo al padre, que sigue con la
    -- fecha vieja. Con una ventana por FILA el padre no entraria, la nueva se
    -- quedaria sin pareja y ARQ 22 daria 0. Que de 100 es la prueba de que el
    -- driver es por PERSONA.
    INSERT INTO bdm_stage.mock_unif_ca_result (criterio_ca, estado, detalle)
    SELECT 'DELTA2/CA-U09',
           CASE WHEN COALESCE(SUM(CASE WHEN arq = 22 THEN filas_del_lote END), 0) = 100
                THEN 'PASSED' ELSE 'FAILED' END,
           'ventana por persona (ARQ 22, posicion FUERA): filas nuevas='
             || CAST(COALESCE(SUM(CASE WHEN arq = 22 THEN filas_del_lote END), 0) AS VARCHAR)
             || ' (esperado 100; con ventana por fila daria 0)'
    FROM bdm_tempo.stg_gate_arq_real;

    -- Lo que ya estaba no se re-escribe: el total del FULL sigue en pie.
    INSERT INTO bdm_stage.mock_unif_ca_result (criterio_ca, estado, detalle)
    SELECT 'DELTA2/CA-U10',
           CASE WHEN SUM(filas) = 55200 THEN 'PASSED' ELSE 'FAILED' END,
           'total tras la mutacion=' || CAST(COALESCE(SUM(filas), 0) AS VARCHAR)
             || ' (esperado 55200 = 55000 del FULL + 200 nuevas)'
    FROM bdm_tempo.stg_gate_arq_real;
  END IF;

  -- ------------------------------------------------------------------
  -- Estructurales: valen en toda fase
  -- ------------------------------------------------------------------
  -- La Clave_Unificacion es el PAR, de modo que el UPSERT por si solo NO impide
  -- que una direccion acabe con dos padres si una corrida posterior le asigna
  -- otro. Este criterio es el que lo vigila.
  INSERT INTO bdm_stage.mock_unif_ca_result (criterio_ca, estado, detalle)
  SELECT p_fase || '/CA-U05',
         CASE WHEN COUNT(*) = 0 THEN 'PASSED' ELSE 'FAILED' END,
         'direcciones con mas de un padre=' || CAST(COUNT(*) AS VARCHAR)
  FROM ( SELECT u.cod_dw_persona_ubic
           FROM bdm_datos.unificacion_direccion_mock u
          GROUP BY u.cod_dw_persona_ubic
         HAVING COUNT(DISTINCT u.cod_dw_direccion_unificada) > 1 ) dup;

  INSERT INTO bdm_stage.mock_unif_ca_result (criterio_ca, estado, detalle)
  SELECT p_fase || '/CA-U06',
         CASE WHEN COUNT(*) = 0 THEN 'PASSED' ELSE 'FAILED' END,
         'padres que no existen como relacion=' || CAST(COUNT(*) AS VARCHAR)
  FROM ( SELECT DISTINCT u.cod_dw_direccion_unificada
           FROM bdm_datos.unificacion_direccion_mock u
          WHERE u.cod_dw_direccion_unificada IS NOT NULL
            AND NOT EXISTS ( SELECT 1
                               FROM bdm_stage.relacion_persona_ubicacion r
                              WHERE r.cod_dw_persona_ubic = u.cod_dw_direccion_unificada )
            AND NOT EXISTS ( SELECT 1
                               FROM bdm_datos.rpu_generada_mock g
                              WHERE g.cod_dw_persona_ubic = u.cod_dw_direccion_unificada )
       ) huerf;

END;
$$;
