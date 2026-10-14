-- ============================================================
-- sp_cert_evaluar_criterios_ord_mock.sql
-- SLCOPRBA-1355: evaluador del tablero de certificacion de ORDENAMIENTO.
-- Gemelo de sp_cert_evaluar_criterios_mock.sql, que hace lo mismo para
-- Unificacion. UTF-8 sin BOM, sin acentos.
--
-- PRINCIPIO: un criterio que no se puede afirmar NO sale ausente ni sale
-- PASSED. Sale con el estado que le corresponde y con la razon exacta. El
-- tablero vale justamente por las filas que no son PASSED.
--
-- ALCANCE EVALUABLE (45 de los 90):
--   los 30 de la Fase 4 (scoring), los 6 CA-F, y de los transversales
--   RG-02, RG-03, RG-05, RG-07, RG-08 y CA-T02..CA-T05.
--   Los otros 45 salen con estado explicito:
--     FASE1/FASE2/FASE3 y lo que depende de ellas -> NO_IMPLEMENTADO (29+5)
--     GOBERNANZA y CA_MIGR de acta                -> FUERA_DE_ALCANCE
--     CA-M01 (paridad numerica con Teradata)      -> BLOQUEADO
--     los cuatro donde el RF y el legado NO dicen
--     lo mismo                                    -> REVISION_MANUAL
--
-- POR QUE CUATRO CRITERIOS EN REVISION_MANUAL Y NO EN PASSED:
--   F4-DIR-04, F4-CEL-06, F4-EMA-02 y F4-EMA-03 enuncian un comportamiento
--   que NUESTRO CODIGO CUMPLE pero que EL LEGADO NO HACE. Marcarlos PASSED
--   seria cierto contra el documento y falso contra Teradata, y RG-09/CA-M01
--   exigen reproducir Teradata. Marcarlos FAILED seria injusto con el codigo.
--   El estado correcto es el que obliga a decidir, con las dos conductas
--   escritas en el detalle. Van a la bitacora de G-03.
--
-- EL UNIVERSO MOCK: id_buro_persona entre 9000000 y 9999999. Los reales son
--   FNV_HASH(pin), valores de 64 bits, tipicamente negativos: no colisionan.
--   El Ordenamiento mock escribe en las tablas de salida REALES (decision ya
--   tomada y documentada en sp_ordenamiento_ejecucion_mock), de modo que el
--   filtro por banda es lo que separa una via de la otra.
--
-- NONATOMIC (leccion #13). Firma (VARCHAR, INTEGER): es un gate de la
-- bateria, no un orquestador, asi que NO lleva los 6 VARCHAR del
-- Framework_Batch. Rollback: DROP PROCEDURE con la firma exacta (#12/#14).
-- ============================================================

CREATE OR REPLACE PROCEDURE bdm_datos.sp_cert_evaluar_criterios_ord_mock(
    p_fase VARCHAR,   -- FULL | DELTA1 | DELTA2 | FULL2
    p_lote INTEGER    -- Lote_Corrida de la corrida que se acaba de evaluar
)
NONATOMIC
LANGUAGE plpgsql
AS $$
DECLARE
    -- CA-T03 consulta el catalogo del motor (pg_tables), que vive en el
    -- leader node. Redshift NO admite mezclar un catalogo de sistema con un
    -- INSERT a una tabla de usuario en la misma sentencia: falla con
    -- "Specified types or functions not supported on Redshift tables". El
    -- patron que si funciona es leerlo a una variable y usar la variable.
    v_stg_vivas INTEGER       := 0;
    v_stg_lista VARCHAR(1000) := '';
BEGIN

  -- Idempotencia del propio gate. WHERE explicito [REDSHIFT:232].
  DELETE FROM bdm_datos.cert_resultado_ord
   WHERE lote = p_lote AND modo = p_fase;

  DROP TABLE IF EXISTS bdm_tempo.stg_cert_ord_base;
  DROP TABLE IF EXISTS bdm_tempo.stg_cert_ord_beta;

  -- ------------------------------------------------------------
  -- Apoyo 1: los scores del universo mock, con la marca de hija.
  -- DISTSTYLE ALL: son pocas decenas de miles de filas y varios criterios
  -- la cruzan consigo misma por (persona, canal); ninguna clave de
  -- distribucion colocaliza las dos caras de ese join.
  -- ------------------------------------------------------------
  CREATE TABLE bdm_tempo.stg_cert_ord_base
  DISTSTYLE ALL
  AS
  SELECT s.cod_dw_persona_ubic,
         s.id_buro_persona,
         s.canal,
         s.score,
         s.lugar,
         CASE WHEN u.cod_dw_persona_ubic IS NOT NULL THEN 1 ELSE 0 END AS es_hija
  FROM bdm_datos.score_ordenamiento s
  LEFT JOIN bdm_datos.unificacion_direccion_mock u
    ON u.cod_dw_persona_ubic = s.cod_dw_persona_ubic
  WHERE s.id_buro_persona BETWEEN 9000000 AND 9999999;

  -- ------------------------------------------------------------
  -- Apoyo 2: el catalogo de betas, resumido por canal, con los limites
  -- teoricos del score. Cada termino es (cat / max_cat) * beta y cat <= max,
  -- de modo que el score vive entre la suma de los betas negativos y la de
  -- los positivos. Es la consecuencia verificable de la formula.
  -- ------------------------------------------------------------
  CREATE TABLE bdm_tempo.stg_cert_ord_beta
  DISTSTYLE ALL
  AS
  SELECT b.canal,
         COUNT(*)                                                      AS n_betas,
         COUNT(DISTINCT b.cod_caracteristica)                          AS n_codigos,
         SUM(CASE WHEN b.valor_beta > 0 THEN b.valor_beta ELSE 0 END)  AS lim_sup,
         SUM(CASE WHEN b.valor_beta < 0 THEN b.valor_beta ELSE 0 END)  AS lim_inf
  FROM bdm_datos.beta_ordenamiento b
  GROUP BY 1;

  -- ============================================================
  -- FASE 4 -- GENERALES
  -- ============================================================

  -- F4-01. Los cuatro canales producen score.
  -- Se cuenta sobre un DISTINCT previo: Redshift no admite LISTAGG junto a
  -- COUNT(DISTINCT) en el mismo SELECT.
  INSERT INTO bdm_datos.cert_resultado_ord
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'F4-01',
         CASE WHEN COUNT(*) = 0 THEN 'SIN_DATO'
              WHEN COUNT(*) = 4 THEN 'PASSED'
              ELSE 'FAILED' END,
         'canales con score en el universo mock=' || CAST(COUNT(*) AS VARCHAR)
           || ' (' || COALESCE(LISTAGG(z.canal, ', ') WITHIN GROUP (ORDER BY z.canal), 'ninguno')
           || '), esperado 4: DIR, TEL, CEL, EMA',
         GETDATE(), CURRENT_USER
  FROM ( SELECT DISTINCT canal FROM bdm_tempo.stg_cert_ord_base ) z;

  -- F4-02. La formula, por su consecuencia verificable: ningun score se sale
  -- de [suma de betas negativos, suma de betas positivos]. Un score fuera de
  -- rango significa que el divisor, la categoria o el beta no son los del
  -- modelo.
  INSERT INTO bdm_datos.cert_resultado_ord
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'F4-02',
         CASE WHEN COUNT(*) = 0 THEN 'SIN_DATO'
              WHEN COALESCE(SUM(CASE WHEN s.score > b.lim_sup
                                       OR s.score < b.lim_inf
                                     THEN 1 ELSE 0 END), 0) > 0 THEN 'FAILED'
              ELSE 'PASSED' END,
         'scores evaluados=' || CAST(COUNT(*) AS VARCHAR)
           || ', fuera del rango teorico de la formula='
           || CAST(COALESCE(SUM(CASE WHEN s.score > b.lim_sup
                                       OR s.score < b.lim_inf
                                     THEN 1 ELSE 0 END), 0) AS VARCHAR)
           || '. El rango sale de los betas del canal: cada termino es '
           || '(categoria/max_categoria)*beta y categoria<=max_categoria',
         GETDATE(), CURRENT_USER
  FROM      bdm_tempo.stg_cert_ord_base s
  JOIN      bdm_tempo.stg_cert_ord_beta b ON b.canal = s.canal
  WHERE     s.score IS NOT NULL;

  -- F4-03. Los betas viven en la tabla, completos y sin duplicados. El
  -- duplicado importa de verdad: los SP de scoring hacen LEFT JOIN sin
  -- agregar, de modo que una fila repetida en (canal, cod_caracteristica)
  -- MULTIPLICA las filas y duplica el score. La tabla no tiene PK ni UNIQUE
  -- (Redshift no las obliga), asi que esta es la unica defensa.
  INSERT INTO bdm_datos.cert_resultado_ord
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'F4-03',
         CASE WHEN COALESCE(SUM(b.n_betas), 0) <> 47                        THEN 'FAILED'
              WHEN COALESCE(SUM(b.n_betas - b.n_codigos), 0) > 0            THEN 'FAILED'
              ELSE 'PASSED' END,
         'filas en beta_ordenamiento=' || CAST(COALESCE(SUM(b.n_betas), 0) AS VARCHAR)
           || ' (esperado 47), codigos duplicados='
           || CAST(COALESCE(SUM(b.n_betas - b.n_codigos), 0) AS VARCHAR)
           || ' (esperado 0; un duplicado multiplica el score por LEFT JOIN)',
         GETDATE(), CURRENT_USER
  FROM bdm_tempo.stg_cert_ord_beta b;

  -- F4-04. El ranking es un ROW_NUMBER por persona dentro del canal: los
  -- lugares de cada grupo son 1..n sin huecos ni repetidos, y el lugar 1 es
  -- el de score maximo. Las dos mitades, porque una sola no basta.
  INSERT INTO bdm_datos.cert_resultado_ord
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'F4-04',
         CASE WHEN COUNT(*) = 0                                                   THEN 'SIN_DATO'
              WHEN COALESCE(SUM(CASE WHEN g.secuencia_ok = 0 THEN 1 ELSE 0 END), 0) > 0 THEN 'FAILED'
              WHEN COALESCE(SUM(CASE WHEN g.cabeza_ok    = 0 THEN 1 ELSE 0 END), 0) > 0 THEN 'FAILED'
              ELSE 'PASSED' END,
         'grupos (persona, canal)=' || CAST(COUNT(*) AS VARCHAR)
           || ', con lugares 1..n sin huecos ni repetidos='
           || CAST(COALESCE(SUM(g.secuencia_ok), 0) AS VARCHAR)
           || ', con el lugar 1 en el score maximo='
           || CAST(COALESCE(SUM(g.cabeza_ok), 0) AS VARCHAR),
         GETDATE(), CURRENT_USER
  FROM ( SELECT s.id_buro_persona, s.canal,
                CASE WHEN MIN(s.lugar) = 1
                      AND MAX(s.lugar) = COUNT(*)
                      AND COUNT(DISTINCT s.lugar) = COUNT(*)
                     THEN 1 ELSE 0 END                                  AS secuencia_ok,
                CASE WHEN MAX(CASE WHEN s.lugar = 1 THEN s.score END)
                         = MAX(s.score)
                     THEN 1 ELSE 0 END                                  AS cabeza_ok
           FROM bdm_tempo.stg_cert_ord_base s
          GROUP BY 1, 2 ) g;

  -- F4-05. Ningun dato vigente con score NULL.
  -- Importa mas de lo que parece: en el legado la sumatoria enlaza los
  -- terminos con LEFT JOIN y los suma con '+' desnudo, sin COALESCE, de modo
  -- que un beta ausente o una persona sin fila en una tabla _Peso anula el
  -- SCORE del canal ENTERO. Y en Redshift ORDER BY ... DESC pone NULLS
  -- FIRST, al reves que Teradata: un score NULL se llevaria el lugar 1.
  INSERT INTO bdm_datos.cert_resultado_ord
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'F4-05',
         CASE WHEN COUNT(*) = 0 THEN 'SIN_DATO'
              WHEN COALESCE(SUM(CASE WHEN s.score IS NULL THEN 1 ELSE 0 END), 0) > 0
                   THEN 'FAILED'
              ELSE 'PASSED' END,
         'datos vigentes con score=' || CAST(COUNT(*) AS VARCHAR)
           || ', con score NULL='
           || CAST(COALESCE(SUM(CASE WHEN s.score IS NULL THEN 1 ELSE 0 END), 0) AS VARCHAR)
           || ' (esperado 0)',
         GETDATE(), CURRENT_USER
  FROM  bdm_tempo.stg_cert_ord_base s
  WHERE s.es_hija = 0;

  -- F4-06. orden_prioridad escrito para toda persona que recibio score.
  INSERT INTO bdm_datos.cert_resultado_ord
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'F4-06',
         CASE WHEN COUNT(*) = 0 THEN 'SIN_DATO'
              WHEN COALESCE(SUM(CASE WHEN o.cod_dw_persona_ubic IS NULL
                                     THEN 1 ELSE 0 END), 0) > 0 THEN 'FAILED'
              ELSE 'PASSED' END,
         'RPU vigentes con score=' || CAST(COUNT(*) AS VARCHAR)
           || ', sin fila en rpu_orden_prioridad='
           || CAST(COALESCE(SUM(CASE WHEN o.cod_dw_persona_ubic IS NULL
                                     THEN 1 ELSE 0 END), 0) AS VARCHAR)
           || ' (esperado 0)',
         GETDATE(), CURRENT_USER
  FROM ( SELECT DISTINCT cod_dw_persona_ubic
           FROM bdm_tempo.stg_cert_ord_base
          WHERE es_hija = 0 ) s
  LEFT JOIN bdm_datos.rpu_orden_prioridad o
    ON o.cod_dw_persona_ubic = s.cod_dw_persona_ubic;

  -- F4-07. Las hijas de Unificacion no reciben score. Dos mitades: que haya
  -- hijas en el universo (si no, el criterio no prueba nada) y que ninguna
  -- tenga score.
  INSERT INTO bdm_datos.cert_resultado_ord
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'F4-07',
         CASE WHEN COALESCE(MAX(h.hijas), 0) = 0        THEN 'SIN_DATO'
              WHEN COALESCE(MAX(h.hijas_con_score), 0) > 0 THEN 'FAILED'
              ELSE 'PASSED' END,
         'hijas de unificacion en el universo mock='
           || CAST(COALESCE(MAX(h.hijas), 0) AS VARCHAR)
           || ', de ellas con score='
           || CAST(COALESCE(MAX(h.hijas_con_score), 0) AS VARCHAR)
           || ' (esperado 0)',
         GETDATE(), CURRENT_USER
  FROM ( SELECT COUNT(DISTINCT u.cod_dw_persona_ubic) AS hijas,
                COUNT(DISTINCT CASE WHEN s.cod_dw_persona_ubic IS NOT NULL
                                    THEN u.cod_dw_persona_ubic END) AS hijas_con_score
           FROM bdm_datos.unificacion_direccion_mock u
           LEFT JOIN bdm_tempo.stg_cert_ord_base s
             ON s.cod_dw_persona_ubic = u.cod_dw_persona_ubic ) h;

  -- F4-08. Idempotencia. Se verifica RECALCULANDO el ranking de forma
  -- independiente y comparandolo con el que escribio el SP:
  --
  --     lugar  ==  ROW_NUMBER() OVER (PARTITION BY persona, canal
  --                                   ORDER BY score DESC NULLS LAST,
  --                                            cod_dw_persona_ubic)
  --
  -- POR QUE ASI Y NO "no hay empates": porque los empates son legitimos y
  -- frecuentes -- la categoria es un entero pequeno sobre un divisor fijo, de
  -- modo que el espacio de scores es discreto. Lo que rompia la idempotencia
  -- no era el empate sino el ROW_NUMBER sin columna de desempate, que dejaba
  -- el lugar al azar del orden fisico. Con el desempate explicito ya aplicado
  -- en los cuatro SP de scoring, esta comparacion lo DEMUESTRA en una sola
  -- corrida: si alguien quitara el desempate, un grupo empatado dejaria de
  -- coincidir y el criterio caeria.
  --
  -- El numero de grupos con empate viaja en el detalle porque es la medida de
  -- cuanto trabajo esta haciendo el desempate: con cero empates el criterio
  -- pasaria aunque el desempate no existiera.
  INSERT INTO bdm_datos.cert_resultado_ord
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'F4-08',
         CASE WHEN COUNT(*) = 0                                             THEN 'SIN_DATO'
              WHEN COALESCE(SUM(v.lugar_discrepa), 0) > 0                   THEN 'FAILED'
              WHEN COALESCE(SUM(v.duplicado), 0)     > 0                    THEN 'FAILED'
              ELSE 'PASSED' END,
         'filas evaluadas=' || CAST(COUNT(*) AS VARCHAR)
           || ', con el lugar distinto del ranking determinista='
           || CAST(COALESCE(SUM(v.lugar_discrepa), 0) AS VARCHAR)
           || ', con el mismo dato puntuado dos veces en el canal='
           || CAST(COALESCE(SUM(v.duplicado), 0) AS VARCHAR)
           || ' (ambos esperados 0). Filas que viven en un grupo (persona, canal) CON empate='
           || CAST(COALESCE(MAX(v.filas_empatadas), 0) AS VARCHAR)
           || ': el empate es legitimo, lo que se exige es que el desempate por '
           || 'cod_dw_persona_ubic lo resuelva siempre igual',
         GETDATE(), CURRENT_USER
  FROM ( SELECT CASE WHEN s.lugar <> ROW_NUMBER() OVER (
                              PARTITION BY s.id_buro_persona, s.canal
                              ORDER BY s.score DESC NULLS LAST, s.cod_dw_persona_ubic)
                     THEN 1 ELSE 0 END                                  AS lugar_discrepa,
                CASE WHEN COUNT(*) OVER (
                              PARTITION BY s.id_buro_persona, s.canal,
                                           s.cod_dw_persona_ubic) > 1
                     THEN 1 ELSE 0 END                                  AS duplicado,
                -- Cuenta FILAS, no grupos: g viaja unido a cada fila. Sirve
                -- igual como medida de cuanto trabaja el desempate.
                SUM(CASE WHEN g.empatado = 1 THEN 1 ELSE 0 END) OVER () AS filas_empatadas
           FROM      bdm_tempo.stg_cert_ord_base s
           LEFT JOIN ( SELECT id_buro_persona, canal,
                              CASE WHEN COUNT(*) > COUNT(DISTINCT score)
                                   THEN 1 ELSE 0 END AS empatado
                         FROM bdm_tempo.stg_cert_ord_base
                        GROUP BY 1, 2 ) g
                  ON g.id_buro_persona = s.id_buro_persona
                 AND g.canal           = s.canal ) v;

  -- F4-09. Los betas parametrizados: los cuatro canales presentes con el
  -- reparto del modelo (DIR 12, TEL 11, CEL 11, EMA 13).
  INSERT INTO bdm_datos.cert_resultado_ord
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'F4-09',
         CASE WHEN COUNT(*) <> 4 THEN 'FAILED'
              WHEN COALESCE(SUM(CASE WHEN (b.canal = 'DIR' AND b.n_betas <> 12)
                                       OR (b.canal = 'TEL' AND b.n_betas <> 11)
                                       OR (b.canal = 'CEL' AND b.n_betas <> 11)
                                       OR (b.canal = 'EMA' AND b.n_betas <> 13)
                                     THEN 1 ELSE 0 END), 0) > 0 THEN 'FAILED'
              ELSE 'PASSED' END,
         'canales en beta_ordenamiento=' || CAST(COUNT(*) AS VARCHAR)
           || ', DIR=' || CAST(COALESCE(MAX(CASE WHEN b.canal='DIR' THEN b.n_betas END), 0) AS VARCHAR)
           || ', TEL=' || CAST(COALESCE(MAX(CASE WHEN b.canal='TEL' THEN b.n_betas END), 0) AS VARCHAR)
           || ', CEL=' || CAST(COALESCE(MAX(CASE WHEN b.canal='CEL' THEN b.n_betas END), 0) AS VARCHAR)
           || ', EMA=' || CAST(COALESCE(MAX(CASE WHEN b.canal='EMA' THEN b.n_betas END), 0) AS VARCHAR)
           || ' (esperado 12/11/11/13)',
         GETDATE(), CURRENT_USER
  FROM bdm_tempo.stg_cert_ord_beta b;

  -- ============================================================
  -- FASE 4 -- POR CANAL: el catalogo de betas de cada uno
  -- Un INSERT conducido por tabla de mapeo: el mismo criterio cuatro veces
  -- cambiando solo el canal, el conteo esperado y el prefijo.
  -- ============================================================
  INSERT INTO bdm_datos.cert_resultado_ord
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, m.criterio,
         CASE WHEN COALESCE(x.n_total, 0) <> m.esperado THEN 'FAILED'
              WHEN COALESCE(x.n_prefijo, 0) <> m.esperado THEN 'FAILED'
              ELSE 'PASSED' END,
         'betas del canal ' || m.canal || '=' || CAST(COALESCE(x.n_total, 0) AS VARCHAR)
           || ' (esperado ' || CAST(m.esperado AS VARCHAR) || '), de ellos con prefijo '
           || m.prefijo || '=' || CAST(COALESCE(x.n_prefijo, 0) AS VARCHAR),
         GETDATE(), CURRENT_USER
  FROM ( SELECT CAST('F4-DIR-01' AS VARCHAR(12)) AS criterio,
                'DIR' AS canal, 12 AS esperado,
                CAST('CO00DIR o CO01DIR' AS VARCHAR(40)) AS prefijo UNION ALL
         SELECT 'F4-TEL-01', 'TEL', 11, 'CO01TEL'           UNION ALL
         SELECT 'F4-CEL-01', 'CEL', 11, 'CO01CEL'           UNION ALL
         SELECT 'F4-EMA-01', 'EMA', 13, 'CO01EMA'           UNION ALL
         SELECT 'F4-DIR-06', 'DIR', 12, 'CO00DIR o CO01DIR' UNION ALL
         SELECT 'F4-TEL-05', 'TEL', 11, 'CO01TEL'           UNION ALL
         SELECT 'F4-CEL-05', 'CEL', 11, 'CO01CEL'           UNION ALL
         SELECT 'F4-EMA-04', 'EMA', 13, 'CO01EMA' ) m
  LEFT JOIN ( SELECT b.canal,
                     COUNT(*) AS n_total,
                     SUM(CASE WHEN b.canal = 'DIR'
                                   AND (b.cod_caracteristica LIKE 'CO00DIR%'
                                     OR b.cod_caracteristica LIKE 'CO01DIR%') THEN 1
                              WHEN b.canal <> 'DIR'
                                   AND b.cod_caracteristica LIKE 'CO01' || b.canal || '%' THEN 1
                              ELSE 0 END) AS n_prefijo
                FROM bdm_datos.beta_ordenamiento b
               GROUP BY 1 ) x
    ON x.canal = m.canal;

  -- ============================================================
  -- CRITERIOS DE ACEPTACION FUNCIONALES
  -- ============================================================

  -- CA-F01. Todo dato vigente con score tiene orden_prioridad. Es la cara
  -- complementaria de F4-06: alli se cuentan los que faltan, aqui ademas se
  -- exige que el valor sea un lugar valido (>= 1).
  INSERT INTO bdm_datos.cert_resultado_ord
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'CA-F01',
         CASE WHEN COUNT(*) = 0 THEN 'SIN_DATO'
              WHEN COALESCE(SUM(CASE WHEN o.orden_prioridad IS NULL
                                       OR o.orden_prioridad < 1
                                     THEN 1 ELSE 0 END), 0) > 0 THEN 'FAILED'
              ELSE 'PASSED' END,
         'RPU vigentes con score=' || CAST(COUNT(*) AS VARCHAR)
           || ', sin orden_prioridad valido='
           || CAST(COALESCE(SUM(CASE WHEN o.orden_prioridad IS NULL
                                       OR o.orden_prioridad < 1
                                     THEN 1 ELSE 0 END), 0) AS VARCHAR)
           || ' (esperado 0)',
         GETDATE(), CURRENT_USER
  FROM ( SELECT DISTINCT cod_dw_persona_ubic
           FROM bdm_tempo.stg_cert_ord_base
          WHERE es_hija = 0 ) s
  LEFT JOIN bdm_datos.rpu_orden_prioridad o
    ON o.cod_dw_persona_ubic = s.cod_dw_persona_ubic;

  -- CA-F02. Las hijas no reciben score NI ranking. F4-07 cubre el score;
  -- esta mitad anade el ranking: tampoco pueden tener orden_prioridad.
  INSERT INTO bdm_datos.cert_resultado_ord
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'CA-F02',
         CASE WHEN COUNT(*) = 0                                                   THEN 'SIN_DATO'
              WHEN COALESCE(SUM(CASE WHEN s.cod_dw_persona_ubic IS NOT NULL
                                     THEN 1 ELSE 0 END), 0) > 0                   THEN 'FAILED'
              WHEN COALESCE(SUM(CASE WHEN o.cod_dw_persona_ubic IS NOT NULL
                                     THEN 1 ELSE 0 END), 0) > 0                   THEN 'FAILED'
              ELSE 'PASSED' END,
         'hijas de unificacion=' || CAST(COUNT(*) AS VARCHAR)
           || ', con score='
           || CAST(COALESCE(SUM(CASE WHEN s.cod_dw_persona_ubic IS NOT NULL THEN 1 ELSE 0 END), 0) AS VARCHAR)
           || ', con orden_prioridad='
           || CAST(COALESCE(SUM(CASE WHEN o.cod_dw_persona_ubic IS NOT NULL THEN 1 ELSE 0 END), 0) AS VARCHAR)
           || ' (ambos esperados 0)',
         GETDATE(), CURRENT_USER
  FROM ( SELECT DISTINCT u.cod_dw_persona_ubic
           FROM bdm_datos.unificacion_direccion_mock u ) h
  LEFT JOIN ( SELECT DISTINCT cod_dw_persona_ubic FROM bdm_tempo.stg_cert_ord_base ) s
    ON s.cod_dw_persona_ubic = h.cod_dw_persona_ubic
  LEFT JOIN bdm_datos.rpu_orden_prioridad o
    ON o.cod_dw_persona_ubic = h.cod_dw_persona_ubic;

  -- CA-F04. Cero scores duplicados por (dato de contacto, canal).
  INSERT INTO bdm_datos.cert_resultado_ord
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'CA-F04',
         CASE WHEN COALESCE(MAX(d.filas), 0) = 0 THEN 'SIN_DATO'
              WHEN COALESCE(MAX(d.filas), 0) <> COALESCE(MAX(d.pares), 0) THEN 'FAILED'
              ELSE 'PASSED' END,
         'filas en score_ordenamiento (universo mock)='
           || CAST(COALESCE(MAX(d.filas), 0) AS VARCHAR)
           || ', pares (dato, canal) distintos='
           || CAST(COALESCE(MAX(d.pares), 0) AS VARCHAR)
           || ' (deben coincidir)',
         GETDATE(), CURRENT_USER
  FROM ( SELECT COUNT(*) AS filas,
                COUNT(DISTINCT CAST(cod_dw_persona_ubic AS VARCHAR) || '|' || canal) AS pares
           FROM bdm_tempo.stg_cert_ord_base ) d;

  -- CA-F05. Mismo invariante que RG-02; se evalua aqui por separado para que
  -- el tablero mapee 1:1 con el documento.
  INSERT INTO bdm_datos.cert_resultado_ord
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'CA-F05',
         CASE WHEN COALESCE(SUM(b.n_betas), 0) = 47
                   AND COALESCE(SUM(b.n_betas - b.n_codigos), 0) = 0 THEN 'PASSED'
              ELSE 'FAILED' END,
         'beta_ordenamiento: filas=' || CAST(COALESCE(SUM(b.n_betas), 0) AS VARCHAR)
           || ' (esperado 47 del RITM5226589), duplicados='
           || CAST(COALESCE(SUM(b.n_betas - b.n_codigos), 0) AS VARCHAR),
         GETDATE(), CURRENT_USER
  FROM bdm_tempo.stg_cert_ord_beta b;

  -- CA-F06. El lugar 1 es el de mayor score dentro de su canal.
  INSERT INTO bdm_datos.cert_resultado_ord
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'CA-F06',
         CASE WHEN COUNT(*) = 0 THEN 'SIN_DATO'
              WHEN COALESCE(SUM(CASE WHEN g.cabeza_ok = 0 THEN 1 ELSE 0 END), 0) > 0
                   THEN 'FAILED'
              ELSE 'PASSED' END,
         'grupos (persona, canal)=' || CAST(COUNT(*) AS VARCHAR)
           || ', donde el lugar 1 NO tiene el score maximo='
           || CAST(COALESCE(SUM(CASE WHEN g.cabeza_ok = 0 THEN 1 ELSE 0 END), 0) AS VARCHAR)
           || ' (esperado 0)',
         GETDATE(), CURRENT_USER
  FROM ( SELECT s.id_buro_persona, s.canal,
                CASE WHEN MAX(CASE WHEN s.lugar = 1 THEN s.score END) = MAX(s.score)
                     THEN 1 ELSE 0 END AS cabeza_ok
           FROM bdm_tempo.stg_cert_ord_base s
          GROUP BY 1, 2 ) g;

  -- ============================================================
  -- TRANSVERSALES EVALUABLES
  -- ============================================================

  -- RG-02. Igual que CA-F05 y F4-03: el catalogo de betas vigente.
  -- RG-03. Igual que F4-08: idempotencia, con el empate como senal.
  -- RG-05. Igual que F4-07: solo vigentes puntuan.
  -- Se escriben por separado porque el tablero mapea 1:1 con el documento, y
  -- un criterio que remite a otro sin estado propio sale SIN_EVALUAR.
  INSERT INTO bdm_datos.cert_resultado_ord
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, m.criterio, r.estado,
         SUBSTRING(m.nota || ' ' || r.detalle, 1, 1024),
         GETDATE(), CURRENT_USER
  FROM ( SELECT CAST('RG-02' AS VARCHAR(12)) AS criterio, 'F4-03' AS espejo,
                'mismo invariante que F4-03.' AS nota UNION ALL
         SELECT 'RG-03', 'F4-08', 'mismo invariante que F4-08.' UNION ALL
         SELECT 'RG-05', 'F4-07', 'mismo invariante que F4-07.' ) m
  JOIN bdm_datos.cert_resultado_ord r
    ON r.criterio = m.espejo AND r.lote = p_lote AND r.modo = p_fase;

  -- RG-08 y CA-T02. Cada etapa registra inicio y fin con timestamp.
  INSERT INTO bdm_datos.cert_resultado_ord
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, m.criterio,
         CASE WHEN COALESCE(MAX(e.etapas), 0) = 0                THEN 'SIN_DATO'
              WHEN COALESCE(MAX(e.sin_cierre), 0) > 0            THEN 'FAILED'
              ELSE 'PASSED' END,
         'etapas registradas para el lote=' || CAST(COALESCE(MAX(e.etapas), 0) AS VARCHAR)
           || ', sin fecha_hora_fin=' || CAST(COALESCE(MAX(e.sin_cierre), 0) AS VARCHAR)
           || ' (esperado 0)',
         GETDATE(), CURRENT_USER
  -- El CAST de la primera rama fija el tipo del nodo UNION ALL: sin el,
  -- 'RG-08' lo dejaria en VARCHAR(5) y 'CA-T02' se truncaria.
  FROM ( SELECT CAST('RG-08' AS VARCHAR(12)) AS criterio UNION ALL
         SELECT 'CA-T02' ) m
  CROSS JOIN ( SELECT COUNT(*) AS etapas,
                      SUM(CASE WHEN fecha_hora_fin IS NULL THEN 1 ELSE 0 END) AS sin_cierre
                 FROM bdm_stage.mock_ord_control_etapa
                WHERE lote = p_lote ) e
  GROUP BY m.criterio;

  -- CA-T03. Las tablas intermedias se eliminan al terminar. Se consulta el
  -- catalogo del motor: tras sp_ordenamiento_drop_staging_edf no debe quedar
  -- ninguna bdm_tempo.stg_insumo_* ni stg_contacto_*. Va por variable, no en
  -- el INSERT, por el motivo explicado en el DECLARE.
  SELECT COUNT(*),
         COALESCE(LISTAGG(CAST(t.tablename AS VARCHAR(128)), ', ')
                  WITHIN GROUP (ORDER BY CAST(t.tablename AS VARCHAR(128))), '')
    INTO v_stg_vivas, v_stg_lista
    FROM pg_tables t
   WHERE t.schemaname = 'bdm_tempo'
     AND (t.tablename LIKE 'stg_insumo_%' OR t.tablename LIKE 'stg_contacto_%');

  INSERT INTO bdm_datos.cert_resultado_ord
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'CA-T03',
         CASE WHEN v_stg_vivas = 0 THEN 'PASSED' ELSE 'FAILED' END,
         'tablas intermedias del Ordenamiento vivas tras el ciclo='
           || CAST(v_stg_vivas AS VARCHAR) || ' (esperado 0)'
           || CASE WHEN v_stg_vivas > 0 THEN ': ' || v_stg_lista ELSE '' END,
         GETDATE(), CURRENT_USER;

  -- CA-T05. Ejecucion incremental: el DELTA no reprocesa todo el universo.
  -- En FULL no hay con que comparar y sale SIN_DATO a proposito.
  INSERT INTO bdm_datos.cert_resultado_ord
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'CA-T05',
         CASE WHEN p_fase IN ('FULL', 'FULL2')                   THEN 'SIN_DATO'
              WHEN COALESCE(MAX(c.pers_delta), 0) = 0            THEN 'SIN_DATO'
              WHEN COALESCE(MAX(c.pers_full), 0) = 0             THEN 'SIN_DATO'
              WHEN COALESCE(MAX(c.pers_delta), 0)
                   > COALESCE(MAX(c.pers_full), 0)               THEN 'FAILED'
              ELSE 'PASSED' END,
         'personas de entrada en este DELTA='
           || CAST(COALESCE(MAX(c.pers_delta), 0) AS VARCHAR)
           || ', en el FULL de referencia='
           || CAST(COALESCE(MAX(c.pers_full), 0) AS VARCHAR)
           || '. El DELTA no debe superar al FULL'
           || CASE WHEN p_fase IN ('FULL', 'FULL2')
                   THEN '. En una fase FULL no hay con que comparar: SIN_DATO es correcto.'
                   ELSE '' END,
         GETDATE(), CURRENT_USER
  FROM ( SELECT MAX(CASE WHEN lote = p_lote THEN personas_entrada END) AS pers_delta,
                MAX(CASE WHEN modo = 'FULL'  THEN personas_entrada END) AS pers_full
           FROM bdm_stage.mock_ord_control ) c;

  -- ============================================================
  -- ESTADOS FIJOS: lo que no se afirma con una consulta
  -- Tabla de mapeo literal, patron del tablero de Unificacion. El FROM es
  -- la propia tabla de mapeo, asi que SIEMPRE devuelve fila y ningun
  -- criterio puede salir SIN_EVALUAR.
  -- ============================================================
  INSERT INTO bdm_datos.cert_resultado_ord
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, m.criterio, m.estado, m.detalle, GETDATE(), CURRENT_USER
  FROM (
    -- --- estructurales que SI se pueden afirmar leyendo el codigo ---
    -- Los tres CAST de la primera rama fijan el tipo del nodo UNION ALL.
    -- Sin ellos 'RG-07' lo dejaria en VARCHAR(5) y 'F4-DIR-04' se
    -- truncaria; 'PASSED' lo dejaria en VARCHAR(6) y 'FUERA_DE_ALCANCE'
    -- tambien.
    SELECT CAST('RG-07'  AS VARCHAR(12)) AS criterio,
           CAST('PASSED' AS VARCHAR(20)) AS estado,
           CAST('esquemas fijos bdm_datos / bdm_tempo / bdm_stage y CERO SQL dinamico en la cadena de Ordenamiento. Es una divergencia FAVORABLE frente al legado, que ejecuta el scoring con cursores sobre sentencias guardadas en texto (Ordenamiento.sql:244, PREPARE ... FROM V_CADENA) y resuelve las dependencias por el ORDER BY alfabetico de un campo de descripcion.' AS VARCHAR(1024)) AS detalle UNION ALL
    SELECT 'CA-T04', 'PASSED',
           'mismo invariante que RG-07: esquemas fijos, sin SQL dinamico.' UNION ALL

    -- --- donde el RF y el legado NO dicen lo mismo: decide negocio ---
    SELECT 'F4-DIR-04', 'REVISION_MANUAL',
           'El RF dice DIR017 = tipo ubicacion (RES=1, LAB=2, CRR=3) y nuestro codigo lo implementa asi (scoring_dir_edf.sql:46-48). EL LEGADO HACE OTRA COSA: Caracteristicas.txt:147 define DIR015 = conteo de RES, DIR016 = conteo de CRR y DIR017 = conteo de LAB; son tres contadores, no un codigo. Ademas Orden_Direcc (:159) etiqueta DIR016 como LAB y DIR017 como COR, o sea cruzadas. Decidir si se sigue el RF o el legado (RG-09 exige reproducir Teradata). Bitacora G-03.' UNION ALL
    SELECT 'F4-CEL-06', 'REVISION_MANUAL',
           'El RF pide un valor por defecto para el operador no mapeado. Nuestro codigo usa 0.22 (scoring_cel_edf.sql:36) y puntua igual. EL LEGADO usa 0 (Caracteristicas.txt:80) y ademas EXCLUYE el celular del ranking (WHERE CO01CEL018 <> 0, :79): un prefijo no catalogado hace DESAPARECER el celular del resultado, en silencio. El literal 0.22 no aparece ni una vez en el legado. Decidir. Bitacora G-03.' UNION ALL
    SELECT 'F4-EMA-02', 'REVISION_MANUAL',
           'NO es un desajuste de etiqueta, es de SIGNO y de INCLUSION. Nuestro codigo pone el dominio conocido en EMA014 (scoring_ema_edf.sql:32) con beta NEGATIVA -130.80018340 y DENTRO de la suma; ademas EMA017 sale de la MISMA lista de dominios (preparar_insumos_edf.sql:295-296) con beta -30.56079051, tambien dentro. Resultado: un gmail PIERDE unos 121 puntos frente a un dominio corporativo. EL LEGADO pone el dominio conocido en EMA018 (Caracteristicas.txt:94, lista de CINCO con live), con beta POSITIVA +91.68 y FUERA de la suma (:246): el dominio NO afecta al score. Su EMA014 es otra cosa, el porcentaje de reportes de mas de 24 meses (:142). O sea que donde el legado es indiferente, nosotros penalizamos. Decidir cual manda. Bitacora G-03.' UNION ALL
    SELECT 'F4-EMA-03', 'REVISION_MANUAL',
           'El RF dice EMA025 = ratio de recencia (min_meses/max_meses*100). EL LEGADO: EMA025 es la LONGITUD DEL BUZON, bucketizada en campana con pico en 9-12 caracteres (Caracteristicas.txt:170 y :91; CHAR() en Teradata devuelve longitud). Tampoco entra en la suma. Decidir. Bitacora G-03.' UNION ALL

    -- --- pendientes de la matriz mock de Ordenamiento (E3) ---
    SELECT 'F4-DIR-02', 'SIN_DATO',
           'DIR001IN = meses desde el primer reporte. Falta el arquetipo de la matriz mock de Ordenamiento que lo ejercite con un valor conocido.' UNION ALL
    SELECT 'F4-DIR-03', 'SIN_DATO',
           'DIR009 = entidades distintas reportando. Falta el arquetipo con un numero conocido de entidades.' UNION ALL
    SELECT 'F4-DIR-05', 'SIN_DATO',
           'Umbrales de categorizacion. Falta el arquetipo que caiga a proposito en cada tramo de un CASE WHEN.' UNION ALL
    SELECT 'F4-TEL-02', 'SIN_DATO',
           'TEL010 = porcentaje con coincidencia geografica. HOY NO ES EJERCITABLE: coincidencia_geo esta fijada a 0 en preparar_insumos_edf.sql:234, de modo que TEL010 es una constante para todas las filas. Es un cableado pendiente, sin TODO que lo marque.' UNION ALL
    SELECT 'F4-TEL-03', 'SIN_DATO',
           'TEL020 binario 1/4. Comparte origen con TEL010 y por tanto tampoco discrimina hoy. En el legado esta fuera de la suma (Caracteristicas.txt:238) y nuestro codigo lo respeta (scoring_tel_edf.sql:81): la paridad es deliberada.' UNION ALL
    SELECT 'F4-TEL-04', 'SIN_DATO',
           'Reportes NO VALIDA. El legado los EXCLUYE (Caracteristicas.txt:46); nuestro codigo no excluye, solo degrada el numerador (scoring_tel_edf.sql:30-38). Falta el arquetipo con un reporte no valido para medir la diferencia.' UNION ALL
    SELECT 'F4-CEL-02', 'SIN_DATO',
           'CEL013 por prefijos 310-314. Falta el arquetipo. Nota: los prefijos estan HARDCODEADOS en scoring_cel_edf.sql:32 y duplican catalogo_tipo_cuenta_tel, que marca esos mismos prefijos como PREPAGO.' UNION ALL
    SELECT 'F4-CEL-03', 'SIN_DATO',
           'CEL014 = indicador de cuenta POSPAGO. Falta el arquetipo.' UNION ALL
    SELECT 'F4-CEL-04', 'SIN_DATO',
           'CEL018 por catalogo de operador. Falta el arquetipo con prefijo catalogado y con prefijo ausente. Nota: catalogo_operador_ord_cel es interim DEV (02_catalogos_ordenamiento.sql:34).' UNION ALL
    SELECT 'CA-F03', 'SIN_DATO',
           'Recalculo independiente del score. Falta el arquetipo de valores controlados contra el que recomputar la formula termino a termino.' UNION ALL

    -- --- fases no portadas ---
    SELECT 'RG-01', 'NO_IMPLEMENTADO',
           'Secuencia F1 -> F2 -> F3 -> F4. Solo F4 esta portada. En el legado el scoring ni siquiera comparte malla con F1-F3: corre desde BTEQ_CURSOR_131.BTQ con los cuatro canales en PARALELO.' UNION ALL
    SELECT 'RG-04', 'NO_IMPLEMENTADO',
           'Exclusion de cuentas bloqueadas: pertenece a la Fase 2, no portada. Nota: tampoco existe filtro de bloqueo en el Ordenamiento de Redshift.' UNION ALL
    SELECT 'RG-06', 'NO_IMPLEMENTADO',
           'Hash MD5 determinista: pertenece a las Fases 2 y 3, no portadas. Cero coincidencias de MD5 en los tres repos.' UNION ALL
    SELECT 'CA-T01', 'NO_IMPLEMENTADO',
           'Hash MD5 de 32 caracteres: mismo motivo que RG-06.' UNION ALL
    SELECT 'CA-M04', 'NO_IMPLEMENTADO',
           'Dependencia F1 -> F2 -> F3 -> F4: no verificable mientras F1-F3 no existan.' UNION ALL

    -- --- paridad numerica con Teradata ---
    SELECT 'CA-M01', 'BLOQUEADO',
           'Exige el mismo corte de datos que Teradata. Faltan las vistas frontera V_DIRECCIONES_TEMP_TF / TM / DF / ML y V_Operador_Ord_Cel, que no vienen en el entregable, y las Fases 1-3 no estan portadas. Sin los mismos insumos no hay paridad numerica demostrable; lo que si se certifica es la logica de la Fase 4.' UNION ALL

    -- --- acta del area funcional ---
    SELECT 'RG-09', 'FUERA_DE_ALCANCE',
           'Reproducir Teradata o explicar la diferencia aprobada: requiere acta del area funcional sobre la bitacora de divergencias. No cuenta para la certificacion QA.' UNION ALL
    SELECT 'RG-10', 'FUERA_DE_ALCANCE',
           'No cambiar umbrales ni betas sin decision funcional: acta del area funcional. Las divergencias detectadas estan en F4-DIR-04, F4-CEL-06, F4-EMA-02 y F4-EMA-03.' UNION ALL
    SELECT 'G-01', 'FUERA_DE_ALCANCE', 'clasificacion de diferencias: acta del area funcional.' UNION ALL
    SELECT 'G-02', 'FUERA_DE_ALCANCE', 'aprobacion de cambios funcionales: acta del area funcional.' UNION ALL
    SELECT 'G-03', 'FUERA_DE_ALCANCE', 'bitacora de diferencias: la alimentan los criterios en REVISION_MANUAL de este tablero, pero la firma es del area funcional.' UNION ALL
    SELECT 'G-04', 'FUERA_DE_ALCANCE', 'migracion contra evolucion funcional: acta del area funcional.' UNION ALL
    SELECT 'G-05', 'FUERA_DE_ALCANCE', 'comparacion con el mismo corte: depende de CA-M01, bloqueado.' UNION ALL
    SELECT 'G-06', 'FUERA_DE_ALCANCE', 'versionado y auditoria de betas: hoy beta_ordenamiento no guarda version. Decision de alcance del area funcional.' UNION ALL
    SELECT 'CA-M02', 'FUERA_DE_ALCANCE', 'bitacora de diferencias con aprobacion: acta del area funcional.' UNION ALL
    SELECT 'CA-M03', 'FUERA_DE_ALCANCE', 'ausencia de cambios funcionales implicitos: acta del area funcional.'
  ) m;

  -- Las tres fases no portadas, en bloque. Se escriben desde el catalogo
  -- para que no haya forma de olvidar una fila si el documento crece.
  INSERT INTO bdm_datos.cert_resultado_ord
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, c.criterio, 'NO_IMPLEMENTADO',
         'Fase ' || SUBSTRING(c.criterio, 2, 1) || ' no portada a Redshift. '
           || 'Verificado: BTT, REC, cta_atributos, portafolio y MD5 dan cero '
           || 'coincidencias en los tres repos. El legado esta en '
           || CASE SUBSTRING(c.criterio, 2, 1)
                   WHEN '1' THEN 'PRO_ORD_MATERIALIZA_BTT / _REC / PRO_ORD_UNIF_BTT_REC.'
                   WHEN '2' THEN 'PRO_ORD_CTA_ATRIBUTOS / PRO_ORD_CTA_TOTALES_PERSONAS.'
                   ELSE 'PRO_ORD_CALC_UBICACIONES / PRO_ORD_UBIC_DIRECCIONES.'
              END,
         GETDATE(), CURRENT_USER
  FROM  bdm_datos.cert_criterio_ord c
  WHERE c.bloque IN ('FASE1', 'FASE2', 'FASE3');

  DROP TABLE IF EXISTS bdm_tempo.stg_cert_ord_base;
  DROP TABLE IF EXISTS bdm_tempo.stg_cert_ord_beta;


END;
$$;
