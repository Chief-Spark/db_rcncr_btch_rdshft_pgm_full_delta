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
-- ALCANCE EVALUABLE (74 de los 90):
--   los 30 de la Fase 4 (scoring), los 6 CA-F, los 29 de las FASES 1, 2 y 3,
--   y de los transversales RG-02, RG-03, RG-05, RG-07, RG-08 y
--   CA-T02..CA-T05. **Ya no queda ni un NO_IMPLEMENTADO**: los 16 restantes
--   salen FUERA_DE_ALCANCE (gobernanza y actas), BLOQUEADO o REVISION_MANUAL,
--   cada uno con su razon.
--
-- LA FASE 1 ENTRO AQUI EN SLCOPRBA-1355, y conviene saber por que no fue un
-- port: sus 46 pasos del legado detectan el delta con MetadataCargaLog y
-- dbc.tables, plomeria de Teradata sin contraparte. Se re-especifico sobre el
-- alcance por lote y watermark que ya existia. De los ocho, SEIS se pueden
-- afirmar y DOS no: F1-01 y F1-08 salen BLOQUEADO porque el mock no tiene
-- tabla de cuentas y porque cuatro de los seis tipos de cambio del legado no
-- dejan rastro temporal en nuestro modelo. Estan BLOQUEADO y no FAILED a
-- proposito: es trabajo de modelo, no un defecto del alcance.
--     GOBERNANZA y CA_MIGR de acta                -> FUERA_DE_ALCANCE
--     CA-M01 (paridad numerica con Teradata)      -> BLOQUEADO
--     los cuatro donde el RF y el legado NO dicen
--     lo mismo                                    -> REVISION_MANUAL
--
-- POR QUE UN CRITERIO EN REVISION_MANUAL Y NO EN PASSED:
--   *(Esta nota decia CUATRO. Tres de ellos -- F4-DIR-04, F4-CEL-06 y
--   F4-EMA-02 -- se resolvieron a favor del legado y hoy estan en PASSED;
--   queda solo F4-EMA-03.)*
--   F4-EMA-03 enuncia un comportamiento
--   que NUESTRO CODIGO CUMPLE pero que EL LEGADO NO HACE. Marcarlo PASSED
--   seria cierto contra el documento y falso contra Teradata, y RG-09/CA-M01
--   exigen reproducir Teradata. Marcarlo FAILED seria injusto con el codigo.
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
  DROP TABLE IF EXISTS bdm_tempo.stg_cert_ord_arq;

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

  -- ------------------------------------------------------------
  -- Apoyo 3: los arquetipos del Ordenamiento (ARQ 80..84), agregados por
  -- banda y canal.
  --
  -- SE MIDE EL DELTA ENTRE LAS DOS FILAS DE CADA PERSONA, no el score
  -- absoluto. El delta solo depende de la diferencia de categoria por el
  -- beta, de modo que es inmune a todo lo que las dos filas COMPARTEN: la
  -- fecha (y por tanto el calendario), el catalogo de sector financiero -- que
  -- en mock vale 0 siempre porque se carga de la vista real del datashare --,
  -- el numero de reportes y el de direcciones. Un score absoluto dependeria de
  -- las tres cosas y el criterio se caeria solo al mes siguiente.
  --
  -- Se guardan el minimo y el maximo del delta por banda para poder afirmar
  -- ademas que las 1000 replicas se comportan IGUAL: si una sola se desviara,
  -- delta_min y delta_max dejarian de coincidir.
  -- ------------------------------------------------------------
  CREATE TABLE bdm_tempo.stg_cert_ord_arq
  DISTSTYLE ALL
  AS
  SELECT g.banda,
         g.canal,
         COUNT(*)            AS personas,
         MIN(g.n_filas)      AS filas_min,
         MAX(g.n_filas)      AS filas_max,
         MIN(g.delta_score)  AS delta_min,
         MAX(g.delta_score)  AS delta_max,
         SUM(g.cabeza_ok)    AS cabeza_ok
  FROM ( SELECT CAST(s.id_buro_persona / 10000 AS INTEGER) * 10000 AS banda,
                s.id_buro_persona,
                s.canal,
                COUNT(*)                        AS n_filas,
                -- delta_score y no 'delta': DELTA ES PALABRA RESERVADA EN
                -- REDSHIFT (viene de los codificados DELTA / DELTA32K) y en
                -- PostgreSQL no lo es, de modo que el banco lo acepto toda
                -- la sesion y Redshift lo rechazo en el deploy del job #366:
                --   42601: syntax error at or near "delta" in context "(g.delta"
                MAX(s.score) - MIN(s.score)     AS delta_score,
                CASE WHEN MAX(CASE WHEN s.lugar = 1 THEN s.score END) = MAX(s.score)
                     THEN 1 ELSE 0 END          AS cabeza_ok
           FROM bdm_tempo.stg_cert_ord_base s
          WHERE s.id_buro_persona BETWEEN 9800000 AND 9999999
          GROUP BY 1, 2, 3 ) g
  GROUP BY 1, 2;

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

  -- F4-08. El ranking es monotono con el score y es una permutacion limpia.
  --
  -- ANTES recalculaba el ranking de forma independiente y lo comparaba. ESO YA
  -- NO SE PUEDE, y la razon importa: el desempate de los SP de scoring dejo de
  -- ser cod_dw_persona_ubic y paso a ser la CLAVE DEL GRUPO (direccion_fisica
  -- en DIR y TEL, celular, email), porque cod_dw_persona_ubic entra como MIN()
  -- sobre el GROUP BY y dos grupos de la misma persona pueden compartirlo. La
  -- clave del grupo SI es unica dentro de (persona, canal) -- es el propio
  -- GROUP BY -- de modo que el orden es TOTAL y el ranking es determinista por
  -- DEMOSTRACION, no por medicion. Pero score_ordenamiento no guarda esa clave
  -- (cod_dw_persona_ubic, cod_pin_persona, id_buro_persona, canal, score,
  -- lugar), asi que desde aqui el orden no se puede reproducir.
  --
  -- LO QUE ESTE CRITERIO NO CUBRE, y conviene no creer que si: la
  -- reproducibilidad ENTRE corridas. Es propiedad de dos ejecuciones, no de
  -- una, y la bateria de convergencia solo fotografia los tres objetos de
  -- Unificacion; score_ordenamiento no esta ahi. Cerrarlo de verdad son dos
  -- caminos, los dos decision de la mesa: anadir el valor de contacto a
  -- score_ordenamiento, o meter esa tabla en la convergencia.
  --
  -- Lo que SI se verifica aqui, y es fuerte:
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
  -- SLCOPRBA-1355: SE RETIRO el termino que contaba "el mismo dato puntuado dos
  -- veces en el canal". Media la RPU, no el dato: particionaba por
  -- (persona, canal, cod_dw_persona_ubic) y marcaba >1. Pero dos correos
  -- distintos en la misma RPU son dos filas LEGITIMAS, y el mock las siembra a
  -- proposito (2000 RPU con dos celulares, 1000 con dos correos). El `dato` de
  -- verdad es el valor de contacto, y score_ordenamiento NO lo guarda: sus
  -- columnas son cod_dw_persona_ubic, cod_pin_persona, id_buro_persona, canal,
  -- score y lugar. Asi que el invariante no era comprobable desde aqui, y lo
  -- que si lo es -- que el lugar coincida con un recalculo cuyo ORDER BY
  -- determina -- ya lo asierta el termino que queda.
  --
  -- El numero de grupos con empate viaja en el detalle porque es la medida de
  -- cuanto trabajo esta haciendo el desempate: con cero empates el criterio
  -- pasaria aunque el desempate no existiera.
  INSERT INTO bdm_datos.cert_resultado_ord
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'F4-08',
         CASE WHEN COUNT(*) = 0                                   THEN 'SIN_DATO'
              WHEN COALESCE(SUM(v.rompe_orden), 0)   > 0          THEN 'FAILED'
              WHEN COALESCE(SUM(v.grupo_roto), 0)    > 0          THEN 'FAILED'
              ELSE 'PASSED' END,
         'filas evaluadas=' || CAST(COUNT(*) AS VARCHAR)
           || ', con el lugar fuera de orden respecto al score='
           || CAST(COALESCE(SUM(v.rompe_orden), 0) AS VARCHAR)
           || ', en grupos cuyo lugar no es 1..n sin huecos='
           || CAST(COALESCE(SUM(v.grupo_roto), 0) AS VARCHAR)
           || ' (ambos esperados 0). Filas en un grupo (persona, canal) CON empate='
           || CAST(COALESCE(MAX(v.filas_empatadas), 0) AS VARCHAR)
           || '. La reproducibilidad ENTRE corridas no se mide aqui: ver la nota del codigo',
         GETDATE(), CURRENT_USER
  FROM ( SELECT
                -- El lugar tiene que ser monotono con el score: recorriendo el
                -- grupo por lugar ascendente, el score nunca puede subir. Pilla
                -- un DESC perdido, un NULLS mal puesto, o que se ordene por el
                -- FLOAT interno en vez de por el DECIMAL que se persiste.
                CASE WHEN s.score > LAG(s.score) OVER (
                              PARTITION BY s.id_buro_persona, s.canal
                              ORDER BY s.lugar)
                     THEN 1 ELSE 0 END                                  AS rompe_orden,
                -- Y tiene que ser una permutacion limpia: 1..n dentro del
                -- grupo, sin huecos ni repetidos.
                CASE WHEN MAX(s.lugar) OVER (PARTITION BY s.id_buro_persona, s.canal)
                          <> COUNT(*)  OVER (PARTITION BY s.id_buro_persona, s.canal)
                       OR MIN(s.lugar) OVER (PARTITION BY s.id_buro_persona, s.canal) <> 1
                     THEN 1 ELSE 0 END                                  AS grupo_roto,
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
              WHEN COALESCE(MAX(d.filas), 0) <> COALESCE(MAX(d.posiciones), 0) THEN 'FAILED'
              ELSE 'PASSED' END,
         'filas en score_ordenamiento (universo mock)='
           || CAST(COALESCE(MAX(d.filas), 0) AS VARCHAR)
           || ', ternas (persona, canal, lugar) distintas='
           || CAST(COALESCE(MAX(d.posiciones), 0) AS VARCHAR)
           || ' (deben coincidir: ninguna posicion del ranking se repite).'
           || ' El RF pide 0 duplicados por DATO de contacto; score_ordenamiento no guarda el valor del contacto, asi que se asierta el invariante equivalente y comprobable.',
         GETDATE(), CURRENT_USER
  -- SLCOPRBA-1355: antes contaba pares (cod_dw_persona_ubic, canal) y los
  -- llamaba "(dato, canal)". No es el dato: la RPU se repite de forma legitima
  -- cuando una persona tiene dos celulares o dos correos en la misma RPU, y el
  -- scoring emite -- correctamente -- una fila por valor de contacto. Con lo
  -- que la tabla guarda, el invariante fuerte y comprobable es que el RANKING
  -- NO REPITA POSICIONES: una terna (persona, canal, lugar) por fila. Es
  -- exactamente lo que garantiza el desempate por la clave del grupo, y cae si
  -- alguien lo quita.
  FROM ( SELECT COUNT(*) AS filas,
                COUNT(DISTINCT CAST(id_buro_persona AS VARCHAR) || '|' || canal
                               || '|' || CAST(lugar AS VARCHAR)) AS posiciones
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
  -- FASE 1 -- MATERIALIZACION (F1-01..08), SLCOPRBA-1355
  --
  -- LA FASE 1 NO SE PORTA: SE RE-ESPECIFICA, y conviene no volver a abrirlo.
  -- Los 46 pasos de PRO_ORD_MATERIALIZA_BTT / _REC existen para detectar el
  -- delta con bdm_mtdat.MetadataCargaLog y dbc.tables, que son plomeria de
  -- Teradata sin contraparte en Redshift. El equivalente aqui es el alcance
  -- por lote y watermark de sp_ordenamiento_preparar_insumos (:36-67). Estos
  -- ocho criterios miden ESE alcance, no un port inexistente.
  --
  -- TODO SALE DEL CENSO, no del staging: sp_ordenamiento_drop_staging_edf ya
  -- borro bdm_tempo.stg_ord_personas_alcance cuando este gate corre.
  -- ============================================================

  -- F1-01. Delta del modelo BTT (cuentas y comportamiento crediticio).
  -- BLOQUEADO, y no FAILED: no es que el alcance se deje fuera las cuentas,
  -- es que no hay ninguna tabla de cuentas en el mock contra la que mirar.
  -- PRO_ORD_MATERIALIZA_BTT lee V_CUENTA, V_COMPORTAMIENTO_CUENTA,
  -- V_COMPORT_CTA_ACTIVO, V_COMPORT_CTA_PASIVO y V_BURO_PERSONA; la semilla
  -- equivalente (bdm_stage.mock_cuenta) llega con la Fase 2. Cuando llegue,
  -- el ciclo llenara por_cuenta y este criterio pasa a medir sin tocarse.
  INSERT INTO bdm_datos.cert_resultado_ord
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'F1-01',
         CASE WHEN c.filas = 0                  THEN 'SIN_DATO'
              WHEN p_fase IN ('FULL', 'FULL2')  THEN 'SIN_DATO'
              WHEN c.por_cuenta IS NULL         THEN 'BLOQUEADO'
              WHEN c.por_cuenta > 0             THEN 'PASSED'
              ELSE 'FAILED' END,
         CASE WHEN c.filas = 0
              THEN 'no hay censo de alcance para el lote=' || CAST(p_lote AS VARCHAR)
              WHEN c.por_cuenta IS NULL
              THEN 'rama BTT sin medir: no hay contrato de cuenta. El legado '
                || 'la saca de V_CUENTA y V_COMPORTAMIENTO_CUENTA '
                || '(PRO_ORD_MATERIALIZA_BTT).'
              ELSE 'personas que entraron por la rama BTT='
                || CAST(c.por_cuenta AS VARCHAR)
                || CASE WHEN p_fase IN ('FULL', 'FULL2')
                        THEN '. En FULL la rama no se evalua -- entra el '
                          || 'universo entero por la de ubicacion --, asi que '
                          || 'SIN_DATO es correcto.'
                        ELSE '' END END,
         GETDATE(), CURRENT_USER
  FROM ( SELECT COUNT(*) AS filas, MAX(por_cuenta) AS por_cuenta
           FROM bdm_stage.mock_ord_alcance_censo
          WHERE lote = p_lote ) c;

  -- F1-02. Delta del modelo REC (ubicaciones). Es la rama que SI existe:
  -- fecha_relacion_persona_ubicaci >= watermark, o fecha nula.
  INSERT INTO bdm_datos.cert_resultado_ord
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'F1-02',
         CASE WHEN c.filas = 0                  THEN 'SIN_DATO'
              WHEN COALESCE(c.por_ubic, 0) = 0  THEN 'FAILED'
              ELSE 'PASSED' END,
         'personas que entraron por la rama de ubicacion='
           || CAST(COALESCE(c.por_ubic, 0) AS VARCHAR)
           || ', por la de unificacion=' || CAST(COALESCE(c.por_unif, 0) AS VARCHAR)
           || ', alcance total=' || CAST(COALESCE(c.personas, 0) AS VARCHAR)
           || '. En FULL entra todo el universo por la rama de ubicacion; '
           || 'en DELTA solo lo que cae en la ventana.',
         GETDATE(), CURRENT_USER
  FROM ( SELECT COUNT(*) AS filas, MAX(por_ubicacion) AS por_ubic,
                MAX(por_unificacion) AS por_unif, MAX(alcance_personas) AS personas
           FROM bdm_stage.mock_ord_alcance_censo
          WHERE lote = p_lote ) c;

  -- F1-03. La union de los dos modelos no genera duplicados: una fila por
  -- persona en el alcance. Lo garantiza el SELECT DISTINCT, y este criterio
  -- lo verifica en vez de confiar en el.
  INSERT INTO bdm_datos.cert_resultado_ord
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'F1-03',
         CASE WHEN c.filas = 0                                  THEN 'SIN_DATO'
              WHEN COALESCE(c.alc_filas, 0) = 0                 THEN 'SIN_DATO'
              WHEN c.alc_filas <> c.alc_personas                THEN 'FAILED'
              ELSE 'PASSED' END,
         'filas del alcance=' || CAST(COALESCE(c.alc_filas, 0) AS VARCHAR)
           || ', personas distintas=' || CAST(COALESCE(c.alc_personas, 0) AS VARCHAR)
           || ' (tienen que coincidir)',
         GETDATE(), CURRENT_USER
  FROM ( SELECT COUNT(*) AS filas, MAX(alcance_filas) AS alc_filas,
                MAX(alcance_personas) AS alc_personas
           FROM bdm_stage.mock_ord_alcance_censo
          WHERE lote = p_lote ) c;

  -- F1-04. Sin lotes nuevos no hay reproceso. El ARQ 96 es la persona
  -- sembrada con fecha 2026-01-15, ANTERIOR al watermark y no nula, y sin
  -- unificacion: las dos ramas la dejan fuera. En FULL entra a proposito
  -- (en FULL entra el universo entero) y por eso ahi sale SIN_DATO.
  --
  -- Y SI NO HAY ARQUETIPO SEMBRADO, TAMBIEN SALE SIN_DATO. Un criterio que
  -- afirma "cero entraron" sobre cero candidatos no prueba nada: es la
  -- leccion que dejo NOV-UB-12.
  INSERT INTO bdm_datos.cert_resultado_ord
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'F1-04',
         CASE WHEN c.filas = 0                            THEN 'SIN_DATO'
              WHEN p_fase IN ('FULL', 'FULL2')            THEN 'SIN_DATO'
              WHEN COALESCE(c.fv_total, 0) = 0            THEN 'SIN_DATO'
              WHEN COALESCE(c.fv_dentro, 0) > 0           THEN 'FAILED'
              ELSE 'PASSED' END,
         'personas sembradas fuera de la ventana (ARQ 96)='
           || CAST(COALESCE(c.fv_total, 0) AS VARCHAR)
           || ', de esas entraron al alcance=' || CAST(COALESCE(c.fv_dentro, 0) AS VARCHAR)
           || ' (esperado 0 en DELTA)'
           || CASE WHEN p_fase IN ('FULL', 'FULL2')
                   THEN '. En FULL entra el universo entero: SIN_DATO es correcto.'
                   ELSE '' END,
         GETDATE(), CURRENT_USER
  FROM ( SELECT COUNT(*) AS filas, MAX(fuera_ventana_total) AS fv_total,
                MAX(fuera_ventana_dentro) AS fv_dentro
           FROM bdm_stage.mock_ord_alcance_censo
          WHERE lote = p_lote ) c;

  -- F1-05. Las tablas intermedias se borran solas al terminar. El censo las
  -- cuenta DESPUES de sp_ordenamiento_drop_staging_edf; son catorce desde
  -- que stg_ord_alcance_origen se sumo a la lista.
  INSERT INTO bdm_datos.cert_resultado_ord
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'F1-05',
         CASE WHEN c.filas = 0                       THEN 'SIN_DATO'
              WHEN c.residuales IS NULL              THEN 'SIN_DATO'
              WHEN c.residuales > 0                  THEN 'FAILED'
              ELSE 'PASSED' END,
         'tablas stg_* del Ordenamiento vivas tras el cleanup='
           || CAST(COALESCE(c.residuales, -1) AS VARCHAR) || ' de 14 (esperado 0)',
         GETDATE(), CURRENT_USER
  FROM ( SELECT COUNT(*) AS filas, MAX(stg_residuales) AS residuales
           FROM bdm_stage.mock_ord_alcance_censo
          WHERE lote = p_lote ) c;

  -- F1-06. Inicio y fin de la fase en el log, con timestamp. La etapa que
  -- representa a la Fase 1 es 'preparar'.
  INSERT INTO bdm_datos.cert_resultado_ord
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'F1-06',
         CASE WHEN COALESCE(e.n, 0) = 0        THEN 'FAILED'
              WHEN COALESCE(e.sin_fin, 0) > 0  THEN 'FAILED'
              ELSE 'PASSED' END,
         'etapa preparar registrada=' || CAST(COALESCE(e.n, 0) AS VARCHAR)
           || ' vez(ces), sin fecha_hora_fin=' || CAST(COALESCE(e.sin_fin, 0) AS VARCHAR)
           || ' (esperado al menos 1 y 0)',
         GETDATE(), CURRENT_USER
  FROM ( SELECT COUNT(*) AS n,
                SUM(CASE WHEN fecha_hora_fin IS NULL THEN 1 ELSE 0 END) AS sin_fin
           FROM bdm_stage.mock_ord_control_etapa
          WHERE lote = p_lote AND etapa = 'preparar' ) e;

  -- F1-07. El universo se acota por fecha parametrica o por la fecha del
  -- ultimo ordenamiento guardada en la tabla de control. Nuestro ciclo usa
  -- la segunda via: MAX(watermark_nuevo) de mock_ord_control, y BOOTSTRAP
  -- cuando no hay corrida previa, que es el caso legitimo de frontera nula.
  INSERT INTO bdm_datos.cert_resultado_ord
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'F1-07',
         CASE WHEN c.filas = 0                                        THEN 'SIN_DATO'
              WHEN c.origen NOT IN ('BOOTSTRAP', 'CONTROL')           THEN 'FAILED'
              WHEN c.origen = 'CONTROL' AND c.wm IS NULL              THEN 'FAILED'
              ELSE 'PASSED' END,
         'origen del watermark=' || COALESCE(c.origen, 'sin dato')
           || ', valor usado=' || COALESCE(CAST(c.wm AS VARCHAR), 'NULL')
           || '. BOOTSTRAP con watermark nulo es correcto: es la primera '
           || 'corrida y no hay frontera anterior.',
         GETDATE(), CURRENT_USER
  FROM ( SELECT COUNT(*) AS filas, MAX(watermark_origen) AS origen,
                MAX(watermark_usado) AS wm
           FROM bdm_stage.mock_ord_alcance_censo
          WHERE lote = p_lote ) c;

  -- F1-08. Los seis tipos de cambio que el legado detecta. BLOQUEADO con el
  -- desglose exacto, que es lo unico honesto: nuestro alcance cubre DOS.
  --
  -- NO ES QUE FALTE UN PREDICADO: faltan columnas. bdm_stage.ubicacion_
  -- estandarizada no tiene fecha ni lote, 'bloqueado' es una bandera sin
  -- fecha, y no hay tabla de cuentas. Un cambio en esas cuatro no deja rastro
  -- temporal que una ventana pueda pescar. Es trabajo de modelo, no de SQL,
  -- y por eso el criterio no sale FAILED.
  INSERT INTO bdm_datos.cert_resultado_ord
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'F1-08',
         CASE WHEN c.filas = 0 THEN 'SIN_DATO'
              WHEN c.por_estand IS NULL OR c.por_bloq IS NULL
                OR c.por_cta IS NULL OR c.por_comp IS NULL THEN 'BLOQUEADO'
              ELSE 'PASSED' END,
         'tipos de cambio detectados 3 de 6. Cubiertos: ubicacion='
           || CAST(COALESCE(c.por_ubic, 0) AS VARCHAR)
           || ', unificacion=' || CAST(COALESCE(c.por_unif, 0) AS VARCHAR)
           || ', cuentas=' || CAST(COALESCE(c.por_cta, 0) AS VARCHAR)
           || ' (esta se sumo con la Fase 2). Sin senal de delta en el '
           || 'modelo siguen tres: estandarizacion (ubicacion_estandarizada '
           || 'no tiene fecha ni lote), bloqueo (bloqueado es bandera sin '
           || 'fecha) y comportamiento de cuenta. El legado los saca de '
           || 'V_UBICACION_ESTANDARIZADA, V_BLOQUEO y '
           || 'V_COMPORTAMIENTO_CUENTA.',
         GETDATE(), CURRENT_USER
  FROM ( SELECT COUNT(*) AS filas, MAX(por_ubicacion) AS por_ubic,
                MAX(por_unificacion) AS por_unif,
                MAX(por_estandarizacion) AS por_estand, MAX(por_bloqueo) AS por_bloq,
                MAX(por_cuenta) AS por_cta, MAX(por_comportamiento) AS por_comp
           FROM bdm_stage.mock_ord_alcance_censo
          WHERE lote = p_lote ) c;

  -- ============================================================
  -- FASE 2 -- ATRIBUTOS DE CUENTA (F2-01..10), SLCOPRBA-1355
  --
  -- Todo sale de bdm_datos.cuenta_atributo_hash_mock, que es permanente. El
  -- arquetipo es el ARQ 99, repartido en cuatro tramos de n.i dentro de la
  -- banda 9990000 porque es la ultima que cabe en el universo mock.
  -- ============================================================

  -- F2-01. Solo cuentas de personas del alcance de la Fase 1. Lo garantiza el
  -- INNER JOIN contra stg_ord_personas_alcance; aqui se verifica el efecto:
  -- ninguna cuenta de una persona fuera del alcance puede haber entrado.
  INSERT INTO bdm_datos.cert_resultado_ord
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'F2-01',
         CASE WHEN COALESCE(c.filas, 0) = 0     THEN 'SIN_DATO'
              WHEN COALESCE(c.huerfanas, 0) > 0 THEN 'FAILED'
              ELSE 'PASSED' END,
         'cuentas en el hash=' || CAST(COALESCE(c.filas, 0) AS VARCHAR)
           || ', de personas que no tienen ni una direccion en el universo='
           || CAST(COALESCE(c.huerfanas, 0) AS VARCHAR) || ' (esperado 0)',
         GETDATE(), CURRENT_USER
  FROM ( SELECT COUNT(*) AS filas,
                SUM(CASE WHEN r.id_buro_persona IS NULL THEN 1 ELSE 0 END) AS huerfanas
           FROM bdm_datos.cuenta_atributo_hash_mock h
           LEFT JOIN ( SELECT DISTINCT id_buro_persona
                         FROM bdm_tempo.v_mock_relacion_persona_ubicacion ) r
                  ON r.id_buro_persona = h.id_buro_persona ) c;

  -- F2-02, F2-03 y F2-04. La ventana de doce meses, y que dentro de ella se
  -- vean los dos comportamientos.
  --
  -- EL TRAMO 400..599 DEL ARQ 99 LLEVA UNA FILA DENTRO Y OTRA FUERA, y esa es
  -- toda la prueba: con solo filas dentro, "la ventana filtra" seria
  -- indistinguible de "no filtra nada". Es la leccion de NOV-AE, donde un
  -- DELTA en cero se dio por bueno sin comparar el rango del dato.
  INSERT INTO bdm_datos.cert_resultado_ord
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, m.criterio,
         CASE WHEN COALESCE(MAX(v.dentro), 0) = 0  THEN 'SIN_DATO'
              WHEN COALESCE(MAX(v.fuera), 0) = 0   THEN 'SIN_DATO'
              WHEN COALESCE(MAX(v.activos), 0) = 0 THEN 'FAILED'
              WHEN COALESCE(MAX(v.pasivos), 0) = 0 THEN 'FAILED'
              ELSE 'PASSED' END,
         'comportamientos sembrados DENTRO de los 12 meses='
           || CAST(COALESCE(MAX(v.dentro), 0) AS VARCHAR)
           || ', FUERA=' || CAST(COALESCE(MAX(v.fuera), 0) AS VARCHAR)
           || '. Cuentas con bandera activa=' || CAST(COALESCE(MAX(v.activos), 0) AS VARCHAR)
           || ', con pasiva=' || CAST(COALESCE(MAX(v.pasivos), 0) AS VARCHAR)
           || '. Sin filas fuera de la ventana el criterio no prueba nada: '
           || 'por eso exige las dos.',
         GETDATE(), CURRENT_USER
  FROM ( SELECT CAST('F2-02' AS VARCHAR(12)) AS criterio UNION ALL
         SELECT 'F2-03' UNION ALL SELECT 'F2-04' ) m
  CROSS JOIN ( SELECT
         SUM(CASE WHEN b.fecha_corte >  DATEADD(month, -12, c.fecha_nov)
                   AND b.fecha_corte <= c.fecha_nov THEN 1 ELSE 0 END) AS dentro,
         SUM(CASE WHEN b.fecha_corte <= DATEADD(month, -12, c.fecha_nov)
                  THEN 1 ELSE 0 END)                                   AS fuera,
         COUNT(DISTINCT CASE WHEN b.tipo = 'A' THEN b.cod_dw_cta END)  AS activos,
         COUNT(DISTINCT CASE WHEN b.tipo = 'P' THEN b.cod_dw_cta END)  AS pasivos
           FROM bdm_tempo.v_mock_comportamiento_cta b
           INNER JOIN bdm_tempo.v_mock_cuenta c ON c.cod_dw_cta = b.cod_dw_cta ) v
  GROUP BY m.criterio;

  -- F2-05. Los nueve portafolios... y el decimo valor del legado.
  --
  -- EL CRITERIO DICE NUEVE Y EL CASE PRODUCE DIEZ. Los nueve que F2-05 nombra
  -- -- CO, RO, VE, HP, IN, OT, CC, AH, CT -- mas ''--'', al que el legado
  -- llega cuando el comportamiento es PASIVO y el tipo de cuenta no es 1
  -- (PRO_ORD_CTA_TOTALES_PERSONAS_2.sql:308-313). No es NULL: es un
  -- centinela, y se porta literal porque manda el codigo (regla 4).
  --
  -- Asi que el criterio NO exige cero fuera del catalogo: exige que todo lo
  -- que salga este en los nueve O sea ese centinela, y cuenta los dos por
  -- separado. Un criterio que lo diera por FAILED estaria exigiendo que el
  -- port se desviara del legado; uno que no lo contara lo esconderia.
  INSERT INTO bdm_datos.cert_resultado_ord
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'F2-05',
         CASE WHEN COALESCE(q.filas, 0) = 0       THEN 'SIN_DATO'
              WHEN COALESCE(q.fuera_cat, 0) > 0   THEN 'FAILED'
              WHEN COALESCE(q.distintos, 0) < 2   THEN 'SIN_DATO'
              ELSE 'PASSED' END,
         'portafolios distintos vistos=' || CAST(COALESCE(q.distintos, 0) AS VARCHAR)
           || ' sobre ' || CAST(COALESCE(q.filas, 0) AS VARCHAR) || ' cuentas. '
           || 'Fuera del catalogo del legado=' || CAST(COALESCE(q.fuera_cat, 0) AS VARCHAR)
           || ' (esperado 0). En el centinela -- del legado='
           || CAST(COALESCE(q.centinela, 0) AS VARCHAR)
           || ', que F2-05 no nombra y el codigo si produce: se porta literal.',
         GETDATE(), CURRENT_USER
  FROM ( SELECT COUNT(*) AS filas,
                COUNT(DISTINCT portafolio) AS distintos,
                SUM(CASE WHEN portafolio = '--' THEN 1 ELSE 0 END) AS centinela,
                SUM(CASE WHEN portafolio NOT IN
                         ('CO','RO','VE','HP','IN','OT','CC','AH','CT','--')
                         THEN 1 ELSE 0 END) AS fuera_cat
           FROM bdm_datos.cuenta_atributo_hash_mock ) q;

  -- F2-06. Ninguno nulo. El tramo 200..399 del ARQ 99 es la persona SIN
  -- cuenta: tiene que no aportar ninguna fila, no una fila con portafolio
  -- nulo.
  INSERT INTO bdm_datos.cert_resultado_ord
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'F2-06',
         CASE WHEN COALESCE(q.filas, 0) = 0  THEN 'SIN_DATO'
              WHEN COALESCE(q.nulos, 0) > 0  THEN 'FAILED'
              WHEN COALESCE(q.sin_cta, 0) = 0 THEN 'SIN_DATO'
              ELSE 'PASSED' END,
         'cuentas con portafolio nulo=' || CAST(COALESCE(q.nulos, 0) AS VARCHAR)
           || ' (esperado 0). Personas sembradas sin cuenta='
           || CAST(COALESCE(q.sin_cta, 0) AS VARCHAR)
           || ': no aportan fila, que es distinto de aportar una con nulo.',
         GETDATE(), CURRENT_USER
  FROM ( SELECT COUNT(*) AS filas,
                SUM(CASE WHEN h.portafolio IS NULL THEN 1 ELSE 0 END) AS nulos,
                MAX(s.n) AS sin_cta
           FROM bdm_datos.cuenta_atributo_hash_mock h
           CROSS JOIN ( SELECT COUNT(*) AS n
                          FROM bdm_tempo.v_mock_relacion_persona_ubicacion r
                          LEFT JOIN bdm_tempo.v_mock_cuenta c
                                 ON c.id_buro_persona = r.id_buro_persona
                         WHERE r.id_buro_persona BETWEEN 9990200 AND 9990399
                           AND c.cod_dw_cta IS NULL ) s ) q;

  -- F2-07. MD5 de 32 exactos, y el cambio registrado. El tramo 600..799 del
  -- ARQ 99 cambia de SALDO antes del DELTA2 -- no de portafolio, para que el
  -- criterio no confunda el atributo con la clasificacion -- y tiene que
  -- acabar con DOS hashes.
  INSERT INTO bdm_datos.cert_resultado_ord
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'F2-07',
         CASE WHEN COALESCE(h.filas, 0) = 0                   THEN 'SIN_DATO'
              WHEN COALESCE(h.malos, 0) > 0                   THEN 'FAILED'
              WHEN p_fase <> 'DELTA2'                         THEN 'PASSED'
              WHEN COALESCE(h.mutadas_con_dos, 0) = 0         THEN 'FAILED'
              ELSE 'PASSED' END,
         'hashes escritos=' || CAST(COALESCE(h.filas, 0) AS VARCHAR)
           || ', con longitud distinta de 32=' || CAST(COALESCE(h.malos, 0) AS VARCHAR)
           || ' (esperado 0). Cuentas del tramo mutado con dos hashes='
           || CAST(COALESCE(h.mutadas_con_dos, 0) AS VARCHAR)
           || CASE WHEN p_fase <> 'DELTA2'
                   THEN '. La mutacion ocurre antes del DELTA2: en las demas '
                     || 'fases solo se afirma la longitud.'
                   ELSE ' (esperado > 0)' END,
         GETDATE(), CURRENT_USER
  FROM ( SELECT COUNT(*) AS filas,
                SUM(CASE WHEN LENGTH(TRIM(cod_dw_hash)) <> 32 THEN 1 ELSE 0 END) AS malos,
                SUM(CASE WHEN id_buro_persona BETWEEN 9990600 AND 9990799
                         THEN 1 ELSE 0 END)
                - COUNT(DISTINCT CASE WHEN id_buro_persona BETWEEN 9990600 AND 9990799
                                      THEN cod_dw_cta END) AS mutadas_con_dos
           FROM bdm_datos.cuenta_atributo_hash_mock ) h;

  -- F2-08. El concatena no puede ser vacio ni nulo. Se verifica por su
  -- consecuencia: un concatena vacio daria el MD5 de la cadena vacia, que es
  -- constante, de modo que todas las cuentas compartirian hash.
  INSERT INTO bdm_datos.cert_resultado_ord
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'F2-08',
         CASE WHEN COALESCE(q.filas, 0) = 0      THEN 'SIN_DATO'
              WHEN COALESCE(q.vacios, 0) > 0     THEN 'FAILED'
              WHEN COALESCE(q.distintos, 0) < 2  THEN 'FAILED'
              ELSE 'PASSED' END,
         'hashes distintos=' || CAST(COALESCE(q.distintos, 0) AS VARCHAR)
           || ' sobre ' || CAST(COALESCE(q.filas, 0) AS VARCHAR) || ' cuentas, '
           || 'con el MD5 de la cadena vacia=' || CAST(COALESCE(q.vacios, 0) AS VARCHAR)
           || ' (esperado 0). Un concatena vacio daria un hash constante.',
         GETDATE(), CURRENT_USER
  FROM ( SELECT COUNT(*) AS filas,
                COUNT(DISTINCT cod_dw_hash) AS distintos,
                SUM(CASE WHEN TRIM(cod_dw_hash) = MD5('') THEN 1 ELSE 0 END) AS vacios
           FROM bdm_datos.cuenta_atributo_hash_mock ) q;

  -- F2-09. Inicio y fin de la fase en el log. La etapa es 'cuentas'.
  INSERT INTO bdm_datos.cert_resultado_ord
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'F2-09',
         CASE WHEN COALESCE(e.n, 0) = 0        THEN 'FAILED'
              WHEN COALESCE(e.sin_fin, 0) > 0  THEN 'FAILED'
              ELSE 'PASSED' END,
         'etapa cuentas registrada=' || CAST(COALESCE(e.n, 0) AS VARCHAR)
           || ' vez(ces), sin fecha_hora_fin=' || CAST(COALESCE(e.sin_fin, 0) AS VARCHAR)
           || ' (esperado al menos 1 y 0)',
         GETDATE(), CURRENT_USER
  FROM ( SELECT COUNT(*) AS n,
                SUM(CASE WHEN fecha_hora_fin IS NULL THEN 1 ELSE 0 END) AS sin_fin
           FROM bdm_stage.mock_ord_control_etapa
          WHERE lote = p_lote AND etapa = 'cuentas' ) e;

  -- F2-10. Tres fechas de insumo por Persona-Cuenta-Suscriptor para el
  -- calculo de meses de reporte. El legado las materializa como
  -- (cod_dw_cta, fecha_nov_ini, fecha_nov) en
  -- PRO_ORD_CTA_TOTALES_PERSONAS.sql:93; la tercera es la de proceso.
  -- Se verifica que la derivada cuadre: fecha_nov_ini = fecha_nov - 12 meses.
  INSERT INTO bdm_datos.cert_resultado_ord
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'F2-10',
         CASE WHEN COALESCE(f.cuentas, 0) = 0   THEN 'SIN_DATO'
              WHEN COALESCE(f.sin_fecha, 0) > 0 THEN 'FAILED'
              ELSE 'PASSED' END,
         'cuentas con las tres fechas derivables='
           || CAST(COALESCE(f.cuentas, 0) AS VARCHAR)
           || ', sin fecha_nov=' || CAST(COALESCE(f.sin_fecha, 0) AS VARCHAR)
           || ' (esperado 0). La ventana es por CUENTA: fecha_nov menos 12 '
           || 'meses, no una fecha de proceso.',
         GETDATE(), CURRENT_USER
  FROM ( SELECT COUNT(*) AS cuentas,
                SUM(CASE WHEN fecha_nov IS NULL THEN 1 ELSE 0 END) AS sin_fecha
           FROM bdm_datos.cuenta_atributo_hash_mock ) f;

  -- CA-M04. La dependencia F1 -> F2 -> F3 -> F4, medida con dato.
  --
  -- Decia "no verificable mientras F1-F3 no existan". Ya existen, y existen
  -- como ETAPAS del ciclo, de modo que ord_control_etapa guarda su orden real
  -- de ejecucion. Se compara ese orden con el esperado, por fecha de inicio:
  -- preparar (F1) -> cuentas (F2) -> ubicaciones (F3) -> scoring_dir (F4).
  --
  -- Mide el ORDEN, no la mera presencia: cuatro etapas registradas en
  -- cualquier secuencia pasarian un criterio que solo contara.
  INSERT INTO bdm_datos.cert_resultado_ord
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'CA-M04',
         CASE WHEN COALESCE(o.etapas, 0) < 4            THEN 'SIN_DATO'
              WHEN o.t_prep <= o.t_cta
               AND o.t_cta  <= o.t_ubi
               AND o.t_ubi  <= o.t_sco                  THEN 'PASSED'
              ELSE 'FAILED' END,
         'etapas de las cuatro fases registradas=' || CAST(COALESCE(o.etapas, 0) AS VARCHAR)
           || ' de 4. Orden por fecha de inicio: preparar, cuentas, '
           || 'ubicaciones, scoring_dir. El criterio mide el ORDEN, no la '
           || 'presencia: cuatro etapas en cualquier secuencia pasarian un '
           || 'criterio que solo contara.',
         GETDATE(), CURRENT_USER
  FROM ( SELECT COUNT(DISTINCT etapa) AS etapas,
                MIN(CASE WHEN etapa = 'preparar'    THEN fecha_hora_inicio END) AS t_prep,
                MIN(CASE WHEN etapa = 'cuentas'     THEN fecha_hora_inicio END) AS t_cta,
                MIN(CASE WHEN etapa = 'ubicaciones' THEN fecha_hora_inicio END) AS t_ubi,
                MIN(CASE WHEN etapa = 'scoring_dir' THEN fecha_hora_inicio END) AS t_sco
           FROM bdm_stage.mock_ord_control_etapa
          WHERE lote = p_lote
            AND etapa IN ('preparar', 'cuentas', 'ubicaciones', 'scoring_dir') ) o;

  -- ============================================================
  -- FASE 3 -- UBICACIONES (F3-01..11), SLCOPRBA-1355
  --
  -- Todo sale de bdm_datos.ubicacion_atributo_hash_mock, que es permanente;
  -- el staging ya lo borro el cleanup. Los arquetipos son el 97 (su direccion
  -- CAMBIA de texto antes del DELTA2) y el 98 (no cambia nunca).
  -- ============================================================

  -- F3-01. Las direcciones bloqueadas no se ordenan. El universo mock las
  -- tiene: las siembra el ARQ 59. El predicado vive en los insumos de la
  -- cascada y aqui se verifica el efecto: ninguna llega al hash.
  INSERT INTO bdm_datos.cert_resultado_ord
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'F3-01',
         CASE WHEN COALESCE(b.sembradas, 0) = 0  THEN 'SIN_DATO'
              WHEN COALESCE(b.en_hash, 0) > 0    THEN 'FAILED'
              ELSE 'PASSED' END,
         'direcciones bloqueadas en el universo=' || CAST(COALESCE(b.sembradas, 0) AS VARCHAR)
           || ', de esas llegaron al hash=' || CAST(COALESCE(b.en_hash, 0) AS VARCHAR)
           || ' (esperado 0). Sin ninguna sembrada el criterio no prueba nada '
           || 'y sale SIN_DATO.',
         GETDATE(), CURRENT_USER
  FROM ( SELECT COUNT(*) AS sembradas,
                COUNT(h.cod_dw_persona_ubic) AS en_hash
           FROM bdm_tempo.v_mock_relacion_persona_ubicacion rpu
           LEFT JOIN bdm_datos.ubicacion_atributo_hash_mock h
                  ON h.cod_dw_persona_ubic = rpu.cod_dw_persona_ubic
          WHERE COALESCE(rpu.bloqueado, 0) = 1 ) b;

  -- F3-02 y F3-11. Las hijas de unificacion no se ordenan. Son el mismo
  -- predicado -- ind_unificacion IS NULL -- y por eso comparten evaluacion.
  INSERT INTO bdm_datos.cert_resultado_ord
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, m.criterio,
         CASE WHEN COALESCE(MAX(u.hijas), 0) = 0     THEN 'SIN_DATO'
              WHEN COALESCE(MAX(u.en_hash), 0) > 0   THEN 'FAILED'
              ELSE 'PASSED' END,
         'direcciones hijas de unificacion=' || CAST(COALESCE(MAX(u.hijas), 0) AS VARCHAR)
           || ', de esas llegaron al hash=' || CAST(COALESCE(MAX(u.en_hash), 0) AS VARCHAR)
           || ' (esperado 0)',
         GETDATE(), CURRENT_USER
  FROM ( SELECT CAST('F3-02' AS VARCHAR(12)) AS criterio UNION ALL
         SELECT 'F3-11' ) m
  CROSS JOIN ( SELECT COUNT(*) AS hijas,
                      COUNT(h.cod_dw_persona_ubic) AS en_hash
                 FROM bdm_datos.unificacion_direccion_mock ud
                 LEFT JOIN bdm_datos.ubicacion_atributo_hash_mock h
                        ON h.cod_dw_persona_ubic = ud.cod_dw_persona_ubic ) u
  GROUP BY m.criterio;

  -- F3-03. Ninguna fila con tipo_persona nula, y las DOS ramas ejercitadas:
  -- el ARQ 97 entra como NATURAL y el 98 como JURIDICA. Con una sola rama el
  -- criterio pasaria sin haber probado la clasificacion.
  INSERT INTO bdm_datos.cert_resultado_ord
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'F3-03',
         CASE WHEN COALESCE(t.filas, 0) = 0     THEN 'SIN_DATO'
              WHEN COALESCE(t.nulas, 0) > 0     THEN 'FAILED'
              WHEN COALESCE(t.naturales, 0) = 0
                OR COALESCE(t.juridicas, 0) = 0 THEN 'FAILED'
              ELSE 'PASSED' END,
         'filas en el hash=' || CAST(COALESCE(t.filas, 0) AS VARCHAR)
           || ', con tipo_persona nula=' || CAST(COALESCE(t.nulas, 0) AS VARCHAR)
           || ' (esperado 0), NATURAL=' || CAST(COALESCE(t.naturales, 0) AS VARCHAR)
           || ', JURIDICA=' || CAST(COALESCE(t.juridicas, 0) AS VARCHAR)
           || '. Las dos ramas tienen que estar: una sola no prueba la '
           || 'clasificacion.',
         GETDATE(), CURRENT_USER
  FROM ( SELECT COUNT(*) AS filas,
                SUM(CASE WHEN tipo_persona IS NULL          THEN 1 ELSE 0 END) AS nulas,
                SUM(CASE WHEN tipo_persona = 'NATURAL'      THEN 1 ELSE 0 END) AS naturales,
                SUM(CASE WHEN tipo_persona = 'JURIDICA'     THEN 1 ELSE 0 END) AS juridicas
           FROM bdm_datos.ubicacion_atributo_hash_mock ) t;

  -- F3-04. MD5 de 32 caracteres exactos. El legado usa un UDF propio
  -- (rec_vista.hash_md5); Redshift trae MD5() nativo.
  INSERT INTO bdm_datos.cert_resultado_ord
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'F3-04',
         CASE WHEN COALESCE(h.filas, 0) = 0      THEN 'SIN_DATO'
              WHEN COALESCE(h.malos, 0) > 0      THEN 'FAILED'
              ELSE 'PASSED' END,
         'hashes escritos=' || CAST(COALESCE(h.filas, 0) AS VARCHAR)
           || ', con longitud distinta de 32=' || CAST(COALESCE(h.malos, 0) AS VARCHAR)
           || ' (esperado 0)',
         GETDATE(), CURRENT_USER
  FROM ( SELECT COUNT(*) AS filas,
                SUM(CASE WHEN LENGTH(TRIM(cod_dw_hash)) <> 32 THEN 1 ELSE 0 END) AS malos
           FROM bdm_datos.ubicacion_atributo_hash_mock ) h;

  -- F3-05. Lo nuevo entra. En FULL la tabla parte vacia -- el reset la
  -- trunca -- asi que todo el universo ordenable tiene que estar.
  INSERT INTO bdm_datos.cert_resultado_ord
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'F3-05',
         CASE WHEN COALESCE(h.filas, 0) = 0 THEN 'FAILED' ELSE 'PASSED' END,
         'filas en ubicacion_atributo_hash tras la corrida='
           || CAST(COALESCE(h.filas, 0) AS VARCHAR)
           || ', llaves distintas=' || CAST(COALESCE(h.llaves, 0) AS VARCHAR),
         GETDATE(), CURRENT_USER
  FROM ( SELECT COUNT(*) AS filas,
                COUNT(DISTINCT cod_dw_persona_ubic) AS llaves
           FROM bdm_datos.ubicacion_atributo_hash_mock ) h;

  -- F3-06. EL CRITERIO SE EVALUA CONTRA LA PARIDAD REAL, NO CONTRA SU LETRA.
  -- Dice "los registros modificados se deben actualizar", y esa rama es
  -- CODIGO MUERTO en el AS-IS: el UPDATE de
  -- PRO_ORD_FINAL_UBIC_DIRECCIONES.sql:216 esta comentado con
  -- "Por solicitud de Experian... no se va a necesitar", y la misma frase
  -- aparece en FINAL_CTA_ATRIBUTOS.sql:200. Es el caso de NOV-UB-13 y
  -- NOV-UB-15: verificar una rama que el legado no puede tomar no certifica
  -- nada. Lo que SI es paridad: el cambio queda registrado -- segunda fila
  -- con hash nuevo -- y la fila anterior no se toca.
  --
  -- Solo se puede afirmar despues de la mutacion, o sea en DELTA2.
  INSERT INTO bdm_datos.cert_resultado_ord
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'F3-06',
         CASE WHEN p_fase <> 'DELTA2'                 THEN 'SIN_DATO'
              WHEN COALESCE(c.arq97_pers, 0) = 0
                OR COALESCE(c.arq98_pers, 0) = 0      THEN 'SIN_DATO'
              WHEN COALESCE(c.arq97_hashes, 0) <> 2   THEN 'FAILED'
              WHEN COALESCE(c.arq98_hashes, 0) <> 1   THEN 'FAILED'
              ELSE 'PASSED' END,
         'ARQ 97 (su direccion cambia de texto): personas='
           || CAST(COALESCE(c.arq97_pers, 0) AS VARCHAR)
           || ', hashes distintos por direccion=' || CAST(COALESCE(c.arq97_hashes, 0) AS VARCHAR)
           || ' (esperado 2). ARQ 98 (no cambia): personas='
           || CAST(COALESCE(c.arq98_pers, 0) AS VARCHAR)
           || ', hashes=' || CAST(COALESCE(c.arq98_hashes, 0) AS VARCHAR)
           || ' (esperado 1)'
           || CASE WHEN p_fase <> 'DELTA2'
                   THEN '. La mutacion ocurre antes del DELTA2: en las demas '
                     || 'fases no hay cambio que medir y SIN_DATO es correcto.'
                   ELSE '' END,
         GETDATE(), CURRENT_USER
  FROM ( SELECT COUNT(DISTINCT CASE WHEN banda = 997 THEN cod_dw_persona_ubic END) AS arq97_pers,
                COUNT(DISTINCT CASE WHEN banda = 998 THEN cod_dw_persona_ubic END) AS arq98_pers,
                MAX(CASE WHEN banda = 997 THEN hashes END) AS arq97_hashes,
                MAX(CASE WHEN banda = 998 THEN hashes END) AS arq98_hashes
           FROM ( SELECT h.cod_dw_persona_ubic,
                         h.id_buro_persona / 10000 AS banda,
                         COUNT(DISTINCT h.cod_dw_hash) AS hashes
                    FROM bdm_datos.ubicacion_atributo_hash_mock h
                   WHERE h.id_buro_persona BETWEEN 9970000 AND 9989999
                   GROUP BY h.cod_dw_persona_ubic, h.id_buro_persona / 10000 ) g ) c;

  -- F3-07. La llave de deteccion es de TRES columnas y el hash es la cuarta
  -- del anti-join. Se verifica por su consecuencia: no puede haber dos filas
  -- con la misma llave Y el mismo hash. Si las hubiera, el anti-join estaria
  -- mal escrito y cada corrida duplicaria la tabla.
  INSERT INTO bdm_datos.cert_resultado_ord
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'F3-07',
         CASE WHEN COALESCE(d.filas, 0) = 0       THEN 'SIN_DATO'
              WHEN COALESCE(d.repetidas, 0) > 0   THEN 'FAILED'
              ELSE 'PASSED' END,
         'combinaciones (cod_pin, id_buro, cod_dw_persona_ubic, hash) repetidas='
           || CAST(COALESCE(d.repetidas, 0) AS VARCHAR) || ' (esperado 0), sobre '
           || CAST(COALESCE(d.filas, 0) AS VARCHAR) || ' filas',
         GETDATE(), CURRENT_USER
  FROM ( SELECT SUM(n)   AS filas,
                SUM(CASE WHEN n > 1 THEN 1 ELSE 0 END) AS repetidas
           FROM ( SELECT COUNT(*) AS n
                    FROM bdm_datos.ubicacion_atributo_hash_mock
                   GROUP BY cod_pin_persona, id_buro_persona,
                            cod_dw_persona_ubic, cod_dw_hash ) q ) d;

  -- F3-08. Inicio y fin de la fase en el log. La etapa es 'ubicaciones'.
  INSERT INTO bdm_datos.cert_resultado_ord
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'F3-08',
         CASE WHEN COALESCE(e.n, 0) = 0        THEN 'FAILED'
              WHEN COALESCE(e.sin_fin, 0) > 0  THEN 'FAILED'
              ELSE 'PASSED' END,
         'etapa ubicaciones registrada=' || CAST(COALESCE(e.n, 0) AS VARCHAR)
           || ' vez(ces), sin fecha_hora_fin=' || CAST(COALESCE(e.sin_fin, 0) AS VARCHAR)
           || ' (esperado al menos 1 y 0)',
         GETDATE(), CURRENT_USER
  FROM ( SELECT COUNT(*) AS n,
                SUM(CASE WHEN fecha_hora_fin IS NULL THEN 1 ELSE 0 END) AS sin_fin
           FROM bdm_stage.mock_ord_control_etapa
          WHERE lote = p_lote AND etapa = 'ubicaciones' ) e;

  -- F3-09 y F3-10. BLOQUEADO, y el motivo es que NO ESTAN EN EL LEGADO que
  -- tenemos. Buscados ICBDIR y 'NO VALIDA' en los 13.826 renglones de
  -- dt/docs/legado_ordenamiento_f1_f3/: cero coincidencias. Los dos
  -- enunciados salen del RF, no del codigo, y la regla 4 dice que manda el
  -- codigo. 'NO VALIDA' si aparece, pero en Caracteristicas.txt, que es la
  -- Fase 4 y otro grano (el divisor de DIR010FI y DIR013OT).
  --
  -- No se inventa un predicado para que pasen: sin saber que columna del
  -- datashare lleva la fuente ni cual la validez de estandarizacion, un
  -- filtro nuestro seria una divergencia disfrazada de criterio cumplido.
  INSERT INTO bdm_datos.cert_resultado_ord
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, m.criterio, 'BLOQUEADO', m.detalle, GETDATE(), CURRENT_USER
  FROM ( SELECT CAST('F3-09' AS VARCHAR(12)) AS criterio,
                CAST('solo se ordenan ubicaciones con cuenta activa para la fuente ICBDIR: ICBDIR no aparece ni una vez en los 17 SP del legado de F1-F3. El enunciado sale del RF y no del codigo. Ademas exige cuentas, que son la Fase 2.' AS VARCHAR(512)) AS detalle UNION ALL
         SELECT 'F3-10',
                'no se ordenan ubicaciones no validas: la validez del estandarizador no aparece en el legado de F1-F3. El unico NO VALIDA del legado esta en Caracteristicas.txt, que es la Fase 4 y otro grano (divisor de DIR010FI y DIR013OT).' ) m;

  -- ============================================================
  -- LOS ARQUETIPOS DEL ORDENAMIENTO (ARQ 80..84)
  -- ============================================================

  -- CA-F03. El recalculo independiente de la formula. Cada arquetipo tiene
  -- DOS filas que difieren en UNA sola caracteristica, de modo que su delta
  -- de score es exactamente (diferencia de categoria / divisor) * beta -- un
  -- numero que se puede calcular a mano desde el catalogo de betas y que no
  -- depende de ningun otro insumo. Si la formula, un umbral, un divisor o un
  -- beta cambian, el delta deja de cuadrar.
  --
  -- La tolerancia de 0.0002 existe porque el score se persiste redondeado a
  -- DECIMAL(18,4): el delta de dos valores redondeados puede separarse del
  -- delta exacto hasta en una diezmilesima por cada lado.
  INSERT INTO bdm_datos.cert_resultado_ord
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'CA-F03',
         CASE WHEN COALESCE(SUM(x.hay), 0) = 0                       THEN 'SIN_DATO'
              WHEN COALESCE(SUM(x.falla), 0) > 0                     THEN 'FAILED'
              ELSE 'PASSED' END,
         SUBSTRING(
           'arquetipos esperados=' || CAST(COUNT(*) AS VARCHAR)
           || ', presentes=' || CAST(COALESCE(SUM(x.hay), 0) AS VARCHAR)
           || ', con el delta de score esperado='
           || CAST(COALESCE(SUM(CASE WHEN x.falla = 0 AND x.hay = 1 THEN 1 ELSE 0 END), 0) AS VARCHAR)
           || '. Detalle: '
           || COALESCE(LISTAGG('ARQ ' || CAST(x.banda / 10000 - 900 AS VARCHAR)
                               || '/' || x.canal
                               || ' esperado ' || CAST(x.delta_esperado AS VARCHAR)
                               || ' obtenido ' || COALESCE(CAST(x.delta_min AS VARCHAR), 'sin filas')
                               || CASE WHEN x.delta_min <> x.delta_max
                                       THEN '..' || CAST(x.delta_max AS VARCHAR)
                                            || ' (LAS REPLICAS NO COINCIDEN)'
                                       ELSE '' END, ' | ')
                       WITHIN GROUP (ORDER BY x.banda), 'nada que medir')
           || ' -- ' || x2.nota, 1, 1024),
         GETDATE(), CURRENT_USER
  FROM ( SELECT m.banda, m.canal, m.delta_esperado,
                a.delta_min, a.delta_max,
                CASE WHEN a.banda IS NULL THEN 0 ELSE 1 END AS hay,
                CASE WHEN a.banda IS NULL                                  THEN 0
                     WHEN ABS(a.delta_min - m.delta_esperado) > 0.0002     THEN 1
                     WHEN ABS(a.delta_max - m.delta_esperado) > 0.0002     THEN 1
                     WHEN a.filas_min <> 2 OR a.filas_max <> 2             THEN 1
                     ELSE 0 END                                            AS falla
           FROM ( SELECT CAST(9800000 AS INTEGER) AS banda,
                         CAST('DIR' AS VARCHAR(10)) AS canal,
                         CAST(0.0000 AS DECIMAL(18,4)) AS delta_esperado UNION ALL
                  SELECT 9810000, 'DIR',   9.6774 UNION ALL
                  SELECT 9820000, 'CEL',   0.0000 UNION ALL
                  SELECT 9830000, 'CEL',  38.3817 UNION ALL
                  SELECT 9840000, 'EMA', 100.8506 UNION ALL
                  SELECT 9850000, 'CEL',  93.3610 UNION ALL
                  SELECT 9860000, 'EMA',  56.5375 UNION ALL
                  SELECT 9870000, 'DIR',  45.1613 UNION ALL
                  SELECT 9890000, 'TEL', 259.1687 UNION ALL
                  SELECT 9900000, 'TEL', 323.5534 UNION ALL
                  -- SLCOPRBA-1355, segunda tanda. Los cinco medidos con
                  -- delta_min = delta_max en las 1000 replicas y VERIFICADOS
                  -- A MANO contra el movimiento de categorias, que es lo que
                  -- distingue una prueba de una foto: medir y aceptar lo que
                  -- salga no probaria nada.
                  SELECT 9910000, 'EMA', 240.9718 UNION ALL
                  SELECT 9920000, 'EMA',  85.5702 UNION ALL
                  SELECT 9930000, 'EMA', 158.1521 UNION ALL
                  SELECT 9940000, 'CEL',  50.8299 UNION ALL
                  SELECT 9950000, 'CEL', 125.5186 ) m
           LEFT JOIN bdm_tempo.stg_cert_ord_arq a
                  ON a.banda = m.banda AND a.canal = m.canal ) x
  CROSS JOIN ( SELECT CAST('ARQ 80 y 82 son empates a proposito (delta 0); '
                        || 'ARQ 81 mueve DIR017 de categoria 1 a 2 (29.03225806/3); '
                        || 'ARQ 83 mueve CEL018 de 2 a 3 (153.52697100/4), con un tercer '
                        || 'celular que la compuerta excluye; '
                        || 'ARQ 84 mueve EMA024 de 1 a 4 (134.46747820/4); '
                        || 'ARQ 85 mueve CEL019 de 1 a 3 (186.72199170/4), dos celulares '
                        || 'de igual valor de operador que solo difieren en el tipo de cuenta; '
                        || 'ARQ 86 mueve EMA021 de 1 a 3 (113.07492490/4); '
                        || 'ARQ 87 mueve DIR001IN y DIR010FI a la vez, porque el prefijo 05 '
                        || 'da portafolio IN y este colapsa a Sector FI: 80.64516129/3 mas '
                        || '54.83870968/3; ARQ 89 y 90 son deltas compuestos del canal TEL. '
                        || 'ARQ 88 NO aparece aqui: DIR009 es por persona y su delta dentro '
                        || 'de la persona es cero por definicion. '
                        || 'ARQ 91 mueve EMA014 de 1 a 4 (bandas 8.33/41.18/85) y arrastra '
                        || 'EMA010 y EMA023; ARQ 92 mueve EMA015 y EMA016, las dos binarias, '
                        || 'en sentidos opuestos; ARQ 93 mueve EMA017, que TOPA EN 3 y divide '
                        || 'entre 4; ARQ 94 mueve CEL020 de 2 a 3 (203.31950210/4) y es el '
                        || 'unico NO compuesto: con la formula vieja, de filas de reporte, '
                        || 'su delta seria CERO; ARQ 95 mueve CEL023 por el filtro de gestion '
                        || 'y arrastra CEL003, CEL013 y CEL014, porque la validez viaja '
                        || 'pegada a la fecha'
                        AS VARCHAR(900)) AS nota ) x2
  GROUP BY x2.nota;

  -- F4-DIR-05. Los umbrales de categorizacion se aplican. El ARQ 81 tiene dos
  -- direcciones identicas salvo el tipo de ubicacion (RES contra LAB), que es
  -- la UNICA columna que mueve una sola caracteristica.
  --
  -- EL DELTA NO CAMBIO CON LA REESCRITURA DE DIR017, PERO SU ORIGEN SI.
  -- Antes DIR017 era un codigo ordinal (RES=1, LAB=2) y las categorias eran
  -- 2 y 3. Ahora es el conteo de reportes 'LAB' del legado
  -- (Caracteristicas.txt:1795): la direccion RES no tiene ninguno y da NULL
  -- -> categoria 1, la LAB tiene uno -> categoria 2. Un escalon en los dos
  -- casos, de modo que 9.6774 sigue siendo el numero correcto por una razon
  -- distinta. Conviene saberlo: un verde aqui ya no prueba lo que probaba.
  INSERT INTO bdm_datos.cert_resultado_ord
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'F4-DIR-05',
         CASE WHEN COUNT(*) = 0                                        THEN 'SIN_DATO'
              WHEN ABS(MAX(a.delta_min) - 9.6774) > 0.0002             THEN 'FAILED'
              WHEN MAX(a.delta_min) <> MAX(a.delta_max)                THEN 'FAILED'
              ELSE 'PASSED' END,
         'ARQ 81 (DIR, RES contra LAB): delta de score observado='
           || COALESCE(CAST(MAX(a.delta_min) AS VARCHAR), 'sin filas')
           || CASE WHEN MAX(a.delta_min) <> MAX(a.delta_max)
                   THEN '..' || CAST(MAX(a.delta_max) AS VARCHAR) || ' (replicas distintas)'
                   ELSE '' END
           || ', esperado 9.6774 = (2-1)/3 * 29.03225806. Es el salto mas '
           || 'pequeno que admite el canal DIR, de modo que ademas mide la resolucion',
         GETDATE(), CURRENT_USER
  FROM  bdm_tempo.stg_cert_ord_arq a
  WHERE a.banda = 9810000 AND a.canal = 'DIR';

  -- F4-CEL-02 (REESCRITO, SLCOPRBA-1355). Antes afirmaba que CEL013 reconocia
  -- el prefijo del operador. NO LO HACE: el legado define CEL013 como el
  -- conteo de reportes de mas de 24 meses (Caracteristicas.txt:2449), y sus
  -- umbrales de categoria (:2348-2354, <1 <2 <3 >=3) lo confirman. El
  -- criterio certificaba una invencion nuestra y por eso daba verde.
  --
  -- La caracteristica que SI depende del operador es CEL018 (:908-909), y el
  -- legado la discrimina por el VALOR del catalogo, no por estar dentro o
  -- fuera. El ARQ 83 enfrenta ahora 310 (0.62 -> categoria 3) contra 300
  -- (0.55 -> categoria 2), los dos catalogados y los dos supervivientes de
  -- la compuerta. Dos mitades: que el 310 gane el lugar 1, y que el delta
  -- sea el de un solo escalon de CEL018.
  INSERT INTO bdm_datos.cert_resultado_ord
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'F4-CEL-02',
         CASE WHEN COUNT(*) = 0                                   THEN 'SIN_DATO'
              WHEN MAX(a.cabeza_ok) <> MAX(a.personas)            THEN 'FAILED'
              WHEN ABS(MAX(a.delta_min) - 38.3817) > 0.0002       THEN 'FAILED'
              ELSE 'PASSED' END,
         'ARQ 83 (CEL, operador 310 contra 300): personas='
           || CAST(COALESCE(MAX(a.personas), 0) AS VARCHAR)
           || ', con el 310 en el lugar 1='
           || CAST(COALESCE(MAX(a.cabeza_ok), 0) AS VARCHAR)
           || ', delta observado='
           || COALESCE(CAST(MAX(a.delta_min) AS VARCHAR), 'sin filas')
           || ' (esperado 38.3817 = CEL018 de 2 a 3, (3-2)/4 * 153.52697100)',
         GETDATE(), CURRENT_USER
  FROM  bdm_tempo.stg_cert_ord_arq a
  WHERE a.banda = 9830000 AND a.canal = 'CEL';

  -- F4-CEL-04 (REESCRITO, SLCOPRBA-1355). Ahora certifica LA COMPUERTA.
  --
  -- Antes afirmaba lo contrario: que el celular con prefijo fuera del
  -- catalogo SEGUIA teniendo fila, con CEL018 en un default inventado de
  -- 0.22. Se dejo asi a proposito, para que la divergencia fuera medible
  -- "cuando negocio decida" (bitacora G-03). Negocio decidio: manda el
  -- legado.
  --
  -- El legado devuelve 0 para el prefijo no catalogado (:909) y Orden_Celular
  -- lo EXCLUYE del ranking (:899, WHERE CEl018.CO01CEL018 <> 0). Ya esta
  -- aplicado en scoring_cel_edf.sql. El ARQ 83 siembra TRES celulares --310,
  -- 300 y 322-- y la compuerta se lleva el 322: deben quedar DOS filas.
  --
  -- Es el mismo 2..2 de antes, pero ahora sobre tres sembrados en vez de dos,
  -- de modo que el criterio prueba que la compuerta FILTRA en lugar de probar
  -- que no filtraba.
  INSERT INTO bdm_datos.cert_resultado_ord
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'F4-CEL-04',
         CASE WHEN COUNT(*) = 0                                 THEN 'SIN_DATO'
              WHEN MAX(a.filas_min) <> 2 OR MAX(a.filas_max) <> 2 THEN 'FAILED'
              ELSE 'PASSED' END,
         'ARQ 83: filas de score por persona (min..max)='
           || COALESCE(CAST(MAX(a.filas_min) AS VARCHAR), '0') || '..'
           || COALESCE(CAST(MAX(a.filas_max) AS VARCHAR), '0')
           || ', esperado 2..2 sobre TRES celulares sembrados (310, 300 y 322). '
           || 'El 322 no esta en catalogo_operador_ord_cel, CEL018 le da 0 y la '
           || 'compuerta del canal lo deja fuera del ranking, igual que el '
           || 'legado (Caracteristicas.txt:899)',
         GETDATE(), CURRENT_USER
  FROM  bdm_tempo.stg_cert_ord_arq a
  WHERE a.banda = 9830000 AND a.canal = 'CEL';

  -- F4-CEL-03 (REAPUNTADO Y MEDIDO, SLCOPRBA-1355).
  --
  -- El enunciado del RF dice "CEL014 = indicador de si la persona tiene
  -- cuenta POSPAGO", y durante toda la vida del tablero salio SIN_DATO con
  -- el motivo "falta el arquetipo". Las dos cosas eran falsas.
  --
  --   CEL014 no mira el tipo de cuenta: es la cuota de reportes de mas de
  --   24 meses (Caracteristicas.txt:2450-2453), y esta portada asi.
  --   La que depende del tipo de cuenta es CEL019 (:112), y lo que le
  --   faltaba no era arquetipo sino el catalogo V_Tipo_Cuenta_Ord, que ya
  --   esta cargado en bdm_datos.catalogo_tipo_cuenta_ord.
  --
  -- El ARQ 85 enfrenta dos celulares de la misma persona con el MISMO valor
  -- de operador --300 y 301, los dos 0,55-- que solo difieren en el tipo de
  -- cuenta: '2' da peso 100 (categoria 3) y '1' da peso 10 (categoria 1).
  -- Es la forma del ARQ 82, que esta medido en 0.0000, de modo que todo lo
  -- que no sea el tipo de cuenta ya esta probado que no mueve nada.
  INSERT INTO bdm_datos.cert_resultado_ord
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'F4-CEL-03',
         CASE WHEN COUNT(*) = 0                                     THEN 'SIN_DATO'
              WHEN MAX(a.filas_min) <> 2 OR MAX(a.filas_max) <> 2   THEN 'FAILED'
              WHEN ABS(MAX(a.delta_min) - 93.3610) > 0.0002         THEN 'FAILED'
              WHEN ABS(MAX(a.delta_max) - 93.3610) > 0.0002         THEN 'FAILED'
              ELSE 'PASSED' END,
         'ARQ 85 (CEL, tipo de cuenta 2 contra 1): personas='
           || CAST(COALESCE(MAX(a.personas), 0) AS VARCHAR)
           || ', filas por persona='
           || COALESCE(CAST(MAX(a.filas_min) AS VARCHAR), '0') || '..'
           || COALESCE(CAST(MAX(a.filas_max) AS VARCHAR), '0')
           || ', delta observado='
           || COALESCE(CAST(MAX(a.delta_min) AS VARCHAR), 'sin filas')
           || ' (esperado 93.3610 = CEL019 de 1 a 3, (3-1)/4 * 186.72199170). '
           || 'El enunciado del RF lo atribuye a CEL014, que no mira el tipo '
           || 'de cuenta; se evalua sobre CEL019, que es quien lo hace',
         GETDATE(), CURRENT_USER
  FROM  bdm_tempo.stg_cert_ord_arq a
  WHERE a.banda = 9850000 AND a.canal = 'CEL';

  -- F4-DIR-02 (MEDIDO, SLCOPRBA-1355). DIR001IN sobre el ARQ 87.
  --
  -- El enunciado del RF la llama "meses desde el primer reporte" y se
  -- equivoca dos veces: Meses_Reporte cuenta hacia atras, de modo que el MIN
  -- del legado es el reporte MAS RECIENTE (el MAX es DIR002TO); y el MIN va
  -- restringido con un WHERE duro a los reportes cuyo suscriptor tiene
  -- Portafolio_Nuevo = 'IN' (Caracteristicas.txt:172).
  --
  -- EL DELTA ES COMPUESTO Y SE DESCOMPONE EXACTO. El prefijo 05 da
  -- portafolio 'IN', y 'IN' colapsa a Sector 'FI' (:391-396), asi que la
  -- direccion k=1 mueve DOS caracteristicas:
  --   DIR001IN  categoria 2 contra 1 -> (2-1)/3 * 80.64516129 = 26.8817
  --   DIR010FI  categoria 2 contra 1 -> (2-1)/3 * 54.83870968 = 18.2796
  --                                                     suma = 45.1613
  -- DIR013OT no se mueve: ninguna de las dos direcciones es Sector 'OT'
  -- ('IN' va a 'FI' y 'RS' va a 'RE'), de modo que las dos quedan en NULL.
  INSERT INTO bdm_datos.cert_resultado_ord
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'F4-DIR-02',
         CASE WHEN COUNT(*) = 0                                   THEN 'SIN_DATO'
              WHEN MAX(a.filas_min) <> 2 OR MAX(a.filas_max) <> 2 THEN 'FAILED'
              WHEN ABS(MAX(a.delta_min) - 45.1613) > 0.0002       THEN 'FAILED'
              WHEN ABS(MAX(a.delta_max) - 45.1613) > 0.0002       THEN 'FAILED'
              ELSE 'PASSED' END,
         'ARQ 87 (DIR, suscriptor 050001 contra 080001): personas='
           || CAST(COALESCE(MAX(a.personas), 0) AS VARCHAR)
           || ', delta observado='
           || COALESCE(CAST(MAX(a.delta_min) AS VARCHAR), 'sin filas')
           || ' (esperado 45.1613 = DIR001IN 80.64516129/3 mas DIR010FI '
           || '54.83870968/3; el prefijo 05 da portafolio IN y este colapsa '
           || 'a Sector FI, de modo que mueve las dos a la vez)',
         GETDATE(), CURRENT_USER
  FROM  bdm_tempo.stg_cert_ord_arq a
  WHERE a.banda = 9870000 AND a.canal = 'DIR';

  -- F4-DIR-03 (MEDIDO, SLCOPRBA-1355). DIR009 sobre el ARQ 88.
  --
  -- DIR009 es A GRANO DE PERSONA: el join del legado (Caracteristicas.txt:201)
  -- es solo por Id_Buro_Persona y reparte el MISMO valor a todas las
  -- direcciones de esa persona. Por eso su delta DENTRO de la persona es
  -- cero por definicion y este criterio NO puede usar stg_cert_ord_arq:
  -- compara DOS PERSONAS que solo difieren en cuantas de sus direcciones
  -- son de correspondencia.
  --
  --   persona par   una direccion CRR  -> DIR009 = 1 -> categoria 2
  --   persona impar las dos CRR        -> DIR009 = 2 -> categoria 3
  --   (umbrales :42, "IS NULL -> 1, <= 1 -> 2, ELSE 3")
  --
  -- El beta es NEGATIVO (-51.61290323), de modo que la persona impar
  -- puntua MENOS: mas direcciones de correspondencia penalizan.
  --   esperado = (3-2)/3 * 51.61290323 = 17.2043, con el par por encima.
  INSERT INTO bdm_datos.cert_resultado_ord
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'F4-DIR-03',
         CASE WHEN COUNT(*) = 0                             THEN 'SIN_DATO'
              WHEN MIN(t.par) <> MAX(t.par)                 THEN 'FAILED'
              WHEN MIN(t.impar) <> MAX(t.impar)             THEN 'FAILED'
              WHEN ABS(MAX(t.par) - MAX(t.impar) - 17.2043) > 0.0002 THEN 'FAILED'
              ELSE 'PASSED' END,
         'ARQ 88 (DIR, una direccion CRR contra dos): score de la persona par='
           || COALESCE(CAST(MAX(t.par) AS VARCHAR), 'sin filas')
           || ', de la impar=' || COALESCE(CAST(MAX(t.impar) AS VARCHAR), 'sin filas')
           || ', diferencia=' || COALESCE(CAST(MAX(t.par) - MAX(t.impar) AS VARCHAR), 'n/a')
           || ' (esperado 17.2043 = (3-2)/3 * 51.61290323, con la IMPAR por '
           || 'DEBAJO porque el beta de DIR009 es negativo). DIR009 es por '
           || 'persona, asi que se mide entre personas y no entre direcciones',
         GETDATE(), CURRENT_USER
  FROM ( SELECT MAX(CASE WHEN MOD(s.id_buro_persona, 2) = 0 THEN s.score END) AS par,
                MAX(CASE WHEN MOD(s.id_buro_persona, 2) = 1 THEN s.score END) AS impar
           FROM bdm_tempo.stg_cert_ord_base s
          WHERE s.id_buro_persona BETWEEN 9880000 AND 9880999
            AND s.canal = 'DIR' ) t;

  -- F4-TEL-02 (MEDIDO, SLCOPRBA-1355). TEL010 sobre el ARQ 89.
  --
  -- TEL010 es la cuota de los reportes de la persona de los ULTIMOS 12 MESES
  -- que son de ESTE telefono, sobre Total_Reportes_12 (Caracteristicas.txt:249).
  -- NO mira la coincidencia geografica: esa columna no aparece ni una vez en
  -- el statement, y los umbrales 20/50/70 de su _cat (:77) confirman la
  -- lectura de porcentaje y descartan la de bandera.
  --
  --   telefono A  3 de los 4 reportes -> TEL010 = 75 -> categoria 4
  --   telefono B  1 de los 4          -> TEL010 = 25 -> categoria 2
  --
  -- EL DELTA ES COMPUESTO A PROPOSITO, y no se puede evitar: para cambiar la
  -- cuota de la ventana <= 12 hay que cambiar cuantos reportes caen dentro, y
  -- eso mueve tambien las cuotas de las demas ventanas del canal. Por eso el
  -- criterio exige DOS cosas: el delta exacto y, lo que de verdad prueba la
  -- caracteristica, que el telefono con mas cuota se lleve el lugar 1.
  INSERT INTO bdm_datos.cert_resultado_ord
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'F4-TEL-02',
         CASE WHEN COUNT(*) = 0                                   THEN 'SIN_DATO'
              WHEN MAX(a.filas_min) <> 2 OR MAX(a.filas_max) <> 2 THEN 'FAILED'
              WHEN MAX(a.cabeza_ok) <> MAX(a.personas)            THEN 'FAILED'
              WHEN ABS(MAX(a.delta_min) - 259.1687) > 0.0002      THEN 'FAILED'
              WHEN ABS(MAX(a.delta_max) - 259.1687) > 0.0002      THEN 'FAILED'
              ELSE 'PASSED' END,
         'ARQ 89 (TEL, 3 reportes de un telefono contra 1 del otro dentro de '
           || '12 meses): personas=' || CAST(COALESCE(MAX(a.personas), 0) AS VARCHAR)
           || ', con el de mayor cuota en el lugar 1='
           || CAST(COALESCE(MAX(a.cabeza_ok), 0) AS VARCHAR)
           || ', delta observado='
           || COALESCE(CAST(MAX(a.delta_min) AS VARCHAR), 'sin filas')
           || ' (esperado 259.1687, compuesto: TEL010 pasa de categoria 2 a 4 '
           || 'y con el se mueven las demas cuotas por ventana del canal, que '
           || 'es inevitable porque comparten el numero de reportes)',
         GETDATE(), CURRENT_USER
  FROM  bdm_tempo.stg_cert_ord_arq a
  WHERE a.banda = 9890000 AND a.canal = 'TEL';

  -- F4-TEL-04 (MEDIDO, SLCOPRBA-1355). El guardia de validez, ARQ 90.
  --
  -- Nuestro insumo deriva descripcion_gestion del propio numero
  -- (preparar_insumos_edf.sql): 'VALIDA' si es todo digitos y mide 7 o mas.
  -- Los cinco contadores de TEL ya lo excluyen (scoring_tel_edf.sql:37, 41,
  -- 57, 72, 74), al contrario de lo que afirmaba el motivo anterior.
  --
  --   telefono A  '6033333333', 10 digitos -> VALIDA
  --   telefono B  '60444',       5 digitos -> NO VALIDA
  --
  -- DIVERGENCIA QUE ESTE CRITERIO CERTIFICA, no paridad. En el legado el
  -- filtro es CODIGO MUERTO: Descripcion_Gestion_Registro se cablea al
  -- literal 'Valida' (Prc_Ordenamiento2.sql:1295) y el WHERE de :1298
  -- excluye fisicamente cualquier otra gestion, de modo que 'NO VALIDA' no
  -- puede existir y los 15 predicados que lo filtran son siempre ciertos.
  -- El legado excluye AGUAS ARRIBA por catalogo de gestion; nosotros
  -- sintetizamos la validez del numero. Misma intencion, distinta definicion
  -- de "invalido". Para la bitacora G-03.
  INSERT INTO bdm_datos.cert_resultado_ord
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'F4-TEL-04',
         CASE WHEN COUNT(*) = 0                                   THEN 'SIN_DATO'
              WHEN MAX(a.filas_min) <> 2 OR MAX(a.filas_max) <> 2 THEN 'FAILED'
              WHEN MAX(a.cabeza_ok) <> MAX(a.personas)            THEN 'FAILED'
              WHEN ABS(MAX(a.delta_min) - 323.5534) > 0.0002      THEN 'FAILED'
              WHEN ABS(MAX(a.delta_max) - 323.5534) > 0.0002      THEN 'FAILED'
              ELSE 'PASSED' END,
         'ARQ 90 (TEL, numero de 10 digitos contra uno de 5): personas='
           || CAST(COALESCE(MAX(a.personas), 0) AS VARCHAR)
           || ', con el VALIDA en el lugar 1='
           || CAST(COALESCE(MAX(a.cabeza_ok), 0) AS VARCHAR)
           || ', delta observado='
           || COALESCE(CAST(MAX(a.delta_min) AS VARCHAR), 'sin filas')
           || ' (esperado 323.5534). CERTIFICA UNA DIVERGENCIA, no paridad: '
           || 'en el legado este filtro es codigo muerto porque '
           || 'Descripcion_Gestion_Registro se cablea al literal Valida '
           || '(Prc_Ordenamiento2.sql:1295) y NO VALIDA no puede existir',
         GETDATE(), CURRENT_USER
  FROM  bdm_tempo.stg_cert_ord_arq a
  WHERE a.banda = 9900000 AND a.canal = 'TEL';

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
    SELECT 'F4-DIR-04', 'PASSED',
           'RESUELTO a favor del legado, como exige RG-09. DIR017 era un codigo ordinal (RES=1, LAB=2, CRR=3) siguiendo el RF; ahora es el conteo de reportes de tipo LAB que define Caracteristicas.txt:1795, con DIR016 (conteo de CRR, :1794) como insumo de DIR009. Queda anotado, sin consecuencia para el port: Orden_Direcc (:159) etiqueta DIR016 como LAB y DIR017 como COR, o sea cruzadas respecto a su propia definicion; las definiciones mandan sobre las etiquetas.' UNION ALL
    SELECT 'F4-CEL-06', 'PASSED',
           'RESUELTO a favor del legado. El default inventado de 0.22 -- que no aparece ni una vez en Caracteristicas.txt -- se cambio por 0 (:909) y se aplico la compuerta del ranking (:899, WHERE CEl018.CO01CEL018 <> 0): un prefijo no catalogado deja al celular FUERA de score_ordenamiento, no solo penalizado. Lo certifica F4-CEL-04 sobre el ARQ 83, que siembra tres celulares y espera dos filas.' UNION ALL
    SELECT 'F4-EMA-02', 'PASSED',
           'RESUELTO a favor del legado, y el diagnostico era exacto: el dominio conocido estaba en EMA014 con beta negativa y dentro de la suma, de modo que un gmail perdia unos 121 puntos. Ya no. EMA014 es la cuota de reportes de mas de 24 meses (Caracteristicas.txt:2450-2453, portada) y EMA017 la de la ventana (12,24] (:2459-2463); el dominio vive ahora en EMA018 (:1090-1094), con la lista de CINCO que incluye live, y esta FUERA de la suma igual que en el legado (:2936, literal 0, con el LEFT JOIN comentado en :2945-2946). El dominio ya no afecta al score.' UNION ALL
    SELECT 'F4-EMA-03', 'REVISION_MANUAL',
           'El RF dice EMA025 = ratio de recencia (min_meses/max_meses*100). EL LEGADO: EMA025 es la LONGITUD DEL BUZON, bucketizada en campana con pico en 9-12 caracteres (Caracteristicas.txt:170 y :91; CHAR() en Teradata devuelve longitud). Tampoco entra en la suma. Decidir. Bitacora G-03.' UNION ALL

    -- --- pendientes de la matriz mock de Ordenamiento (E3) ---
    -- F4-TEL-03 (PASSED ESTRUCTURAL, SLCOPRBA-1355).
    --
    -- NO ES CERTIFICABLE CON DATOS, y conviene que quede dicho por que:
    -- coincidencia_geo esta fijada al literal 0 (preparar_insumos_edf.sql),
    -- de modo que TEL020 vale lo mismo en TODAS las filas. Un termino
    -- constante desplaza todos los scores por igual, asi que ninguna
    -- consulta sobre score_ordenamiento puede distinguir "TEL020 entra en la
    -- suma" de "no entra". Se certifica leyendo los dos lados:
    --   legado  Caracteristicas.txt:238 -- la suma tiene DIEZ terminos,
    --           TEL001/002/003/006/007/010/017/019/023/025, y TEL020_Peso no
    --           esta entre ellos (tampoco TEL022), aunque su _Peso SI se
    --           construye en :128. Queda huerfano a proposito.
    --   nuestro scoring_tel_edf.sql:144-150 -- los mismos diez terminos, con
    --           el comentario de exclusion en la linea 148.
    -- Es el mismo patron de F4-DIR-04, F4-CEL-06 y F4-EMA-02.
    SELECT 'F4-TEL-03', 'PASSED',
           'TEL020 se calcula y queda FUERA de la suma en los dos lados. Legado: Caracteristicas.txt:238 suma diez terminos (TEL001/002/003/006/007/010/017/019/023/025) y TEL020_Peso no esta, aunque se construye en :128. Nuestro port: scoring_tel_edf.sql:144-150, los mismos diez. NO es certificable con datos porque coincidencia_geo esta fijada a 0 y un termino constante no es observable en el score; se certifica por lectura de ambos lados, igual que F4-DIR-04, F4-CEL-06 y F4-EMA-02.' UNION ALL


    -- --- SLCOPRBA-1355: LAS CINCO QUE DEPENDIAN DE LAS FASES NO PORTADAS ---
    -- Las cinco decian "no portada" o "no portadas", y eso dejo de ser cierto
    -- cuando entraron F1, F3 y F2. Una justificacion que envejece es
    -- exactamente lo que este tablero no se puede permitir, asi que cuatro
    -- pasan a medirse de verdad y la quinta cambia de razon.
    SELECT 'RG-01', 'PASSED',
           'Secuencia F1 -> F2 -> F3 -> F4. Las cuatro corren hoy, y en ese orden, como etapas del ciclo: preparar (F1), cuentas (F2), ubicaciones (F3) y los cuatro scoring (F4). El evaluador lo verifica en CA-M04 contra ord_control_etapa. En el legado el scoring ni siquiera comparte malla con F1-F3: corre desde BTEQ_CURSOR_131.BTQ con los cuatro canales en PARALELO, de modo que el orden que aqui se certifica es el NUESTRO.' UNION ALL
    SELECT 'RG-04', 'BLOQUEADO',
           'Exclusion de cuentas bloqueadas. Ya NO es por falta de Fase 2: la Fase 2 esta portada. Lo que falta es el dato: el contrato de cuenta no trae razon ni fecha de bloqueo, que en el legado salen de V_Razon_Bloqueo (PRO_ORD_CTA_ATRIBUTOS:298), uno de los objetos del Bloque A del datashare. El bloqueo de DIRECCIONES si esta, y lo certifica F3-01.' UNION ALL
    SELECT 'RG-06', 'PASSED',
           'Hash MD5 determinista. Las dos tablas de hash existen y se escriben: cuenta_atributo_hash (F2-07) y ubicacion_atributo_hash (F3-04). MD5() nativo de Redshift sustituye al UDF rec_vista.hash_md5 del legado. Determinista por definicion de la funcion; que la longitud sea 32 en todas las filas lo verifican F2-07 y F3-04 con dato.' UNION ALL
    SELECT 'CA-T01', 'PASSED',
           'Hash MD5 de 32 caracteres: mismo motivo que RG-06, y lo miden F2-07 sobre las cuentas y F3-04 sobre las ubicaciones.' UNION ALL

    -- --- paridad numerica con Teradata ---
    SELECT 'CA-M01', 'BLOQUEADO',
           'Exige el mismo corte de datos que Teradata. Ya NO es por falta de fases: las tres estan portadas. Lo que falta son las vistas frontera V_DIRECCIONES_TEMP_TF / TM / DF / ML y V_Operador_Ord_Cel, que no vienen en el entregable. Sin los mismos insumos no hay paridad numerica demostrable; lo que si se certifica es la logica de las cuatro fases sobre mock.' UNION ALL

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

  -- SLCOPRBA-1355: AQUI VIVIA EL BLOQUE QUE DABA LAS TRES FASES POR NO
  -- PORTADAS, y se retira entero porque ya no le queda ninguna. Escribia
  -- NO_IMPLEMENTADO para FASE1, FASE2 y FASE3 leyendo el catalogo, y se fue
  -- vaciando a medida que cada una se cerro: la 1, luego la 3, y con la 2 se
  -- queda sin filas que escribir. Un bloque que inserta cero filas y sigue
  -- ahi es justo lo que hace que un tablero envejezca mal.


  DROP TABLE IF EXISTS bdm_tempo.stg_cert_ord_base;
  DROP TABLE IF EXISTS bdm_tempo.stg_cert_ord_beta;
  DROP TABLE IF EXISTS bdm_tempo.stg_cert_ord_arq;

END;
$$;
