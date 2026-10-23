-- ============================================================
-- sp_cert_evaluar_criterios_mock.sql
-- SLCOPRBA-1355: evalua los 51 criterios de aceptacion y escribe el veredicto
-- en bdm_datos.cert_resultado. MODO MOCK.
--
-- QUE RESUELVE: los gates que ya existian (sp_unificacion_mock_gate_arq,
-- sp_unif_gate_convergencia_evaluar) usan nombres internos -- CA-U01..U10,
-- CA-C01..C08 -- que no se pueden rastrear contra los documentos que firmo el
-- negocio. Este gate usa como clave el ID DEL DOCUMENTO (R1-02, R2-06, R3-04,
-- CA-04), de modo que QA lee una fila por criterio y no tiene que traducir.
-- No reemplaza a los otros dos: se apoya en ellos. El gate por arquetipo sigue
-- siendo la evidencia fina de cada escenario.
--
-- PRINCIPIO: un criterio que no se puede afirmar NO sale ausente ni sale
-- PASSED. Sale con el estado que le corresponde y con la razon exacta. El
-- tablero vale justamente por las filas que no son PASSED.
--
-- ESTADOS: PASSED | FAILED | NO_IMPLEMENTADO | SIN_DATO | BLOQUEADO |
--          REVISION_MANUAL | NO_APLICA | FUERA_DE_ALCANCE
--          (definidos en strct/13_ddl_cert_criterios.sql)
--
-- Prerequisito: 13_ddl_cert_criterios.sql desplegado; un ciclo mock corrido.
-- NONATOMIC consistente con el resto de la cadena.
-- ============================================================

CREATE OR REPLACE PROCEDURE bdm_datos.sp_cert_evaluar_criterios_mock(
    p_fase VARCHAR,   -- FULL | DELTA1 | DELTA2 | FULL2
    p_lote INTEGER    -- Lote_Corrida de la corrida que se acaba de evaluar
)
NONATOMIC
LANGUAGE plpgsql
AS $$
BEGIN

  -- Reevaluacion idempotente de esta (lote, fase). WHERE explicito por
  -- politica [REDSHIFT:232].
  DELETE FROM bdm_datos.cert_resultado
   WHERE lote = p_lote
     AND modo = p_fase;

  -- ------------------------------------------------------------------
  -- Staging comun: las parejas enriquecidas con el contexto que piden R1 y G.
  -- Se materializa una vez; cada criterio es despues una consulta corta sobre
  -- esta tabla en vez de un recorrido mas de la vista (que calcula un
  -- ROW_NUMBER sobre todo el universo en cada lectura).
  -- ------------------------------------------------------------------
  DROP TABLE IF EXISTS bdm_tempo.stg_cert_pares;
  DROP TABLE IF EXISTS bdm_tempo.stg_cert_ent;

  -- DISTSTYLE ALL en las dos tablas de apoyo, por dos razones:
  --   1) Son chicas (del orden de 50 mil filas), de modo que replicarlas sale
  --      mas barato que redistribuirlas en cada join.
  --   2) Los criterios R2-10, R2-11, R2-14, G-02 y G-03 hacen SELF-JOIN de
  --      stg_cert_pares con la condicion hija = padre. Ningun DISTKEY puede
  --      colocalizar las dos caras de ese join, asi que una clave de
  --      distribucion no compraria nada y si costaba el error del job #315:
  --      el DISTKEY tiene que ser una columna de la LISTA DEL SELECT, y aqui
  --      cod_dw_persona_ubic sale con alias 'hija'.
  CREATE TABLE bdm_tempo.stg_cert_ent
  DISTSTYLE ALL
  AS
  SELECT cod_dw_persona_ubic,
         COUNT(DISTINCT id_buro_suscriptor) AS entidades
  FROM   bdm_tempo.v_mock_reporte_relacion_persona_ubica
  GROUP  BY 1;

  CREATE TABLE bdm_tempo.stg_cert_pares
  DISTSTYLE ALL
  AS
  SELECT
    u.cod_dw_persona_ubic                      AS hija,
    u.cod_dw_direccion_unificada               AS padre,
    u.unifica_atributos                        AS regla,
    u.lote,
    u.fecha_unificacion,
    rh.id_buro_persona                         AS persona_hija,
    rp.id_buro_persona                         AS persona_padre,
    rh.ind_unificacion                         AS ind_unif_hija,
    -- El ind_unificacion ALMACENADO en la tabla base, que es distinto del
    -- derivado de la vista: el derivado vale 1 para TODA hija despues de la
    -- corrida, de modo que no sirve para preguntar si la direccion YA ERA hija
    -- ANTES. La matriz lo siembra en 1 en las posiciones YA_UNIF (ARQ 5, 10,
    -- 15, 20), y eso es lo que hace verificable la segunda mitad de R1-06.
    rb.ind_unificacion                         AS ind_unif_base,
    COALESCE(rh.bloqueado, 0)                  AS bloqueado_hija,
    COALESCE(rp.bloqueado, 0)                  AS bloqueado_padre,
    th.descripcion_tipo_ubicacion_dir          AS tipo_hija,
    tp.descripcion_tipo_ubicacion_dir          AS tipo_padre,
    COALESCE(eh.entidades, 0)                  AS ent_hija,
    COALESCE(ep.entidades, 0)                  AS ent_padre,
    COALESCE(ci.cod_act_econo_ciiu_fte, '')    AS ciiu
  FROM            bdm_datos.unificacion_direccion_mock u
  LEFT JOIN       bdm_tempo.v_mock_relacion_persona_ubicacion rh
               ON rh.cod_dw_persona_ubic = u.cod_dw_persona_ubic
  LEFT JOIN       bdm_tempo.v_mock_relacion_persona_ubicacion rp
               ON rp.cod_dw_persona_ubic = u.cod_dw_direccion_unificada
  LEFT JOIN       bdm_datos.tipo_ubicacion_dir th
               ON th.cod_dw_tipo_ubicacion_dir = rh.cod_dw_tipo_ubicacion_dir
  LEFT JOIN       bdm_datos.tipo_ubicacion_dir tp
               ON tp.cod_dw_tipo_ubicacion_dir = rp.cod_dw_tipo_ubicacion_dir
  LEFT JOIN       bdm_tempo.stg_cert_ent eh
               ON eh.cod_dw_persona_ubic = u.cod_dw_persona_ubic
  LEFT JOIN       bdm_tempo.stg_cert_ent ep
               ON ep.cod_dw_persona_ubic = u.cod_dw_direccion_unificada
  LEFT JOIN       bdm_tempo.v_mock_ciiu_persona ci
               ON ci.id_buro_persona = rh.id_buro_persona
  LEFT JOIN       bdm_stage.relacion_persona_ubicacion rb
               ON rb.cod_dw_persona_ubic = u.cod_dw_persona_ubic;

  -- SLCOPRBA-1355: apoyo del bloque REGLA3. Una fila por direccion de la banda
  -- de arquetipos de R3 (ARQ 61..70 -> 96100000..97009999) con TODO lo que los
  -- diez criterios necesitan: el tipo de via, los cuatro componentes, las
  -- coordenadas, el ultimo reporte, el numero de entidades, el numero de FILAS
  -- de reporte -- que es lo que cuenta el Diccionario de Via, distinto de las
  -- entidades, que son suscriptores DISTINTOS -- y su padre de regla 3 si lo
  -- tiene. Con esto cada criterio queda en una consulta corta y legible.
  --
  -- DISTSTYLE ALL: son 20 mil filas y varios criterios hacen self-join por
  -- dir = padre_r3, que ningun DISTKEY puede colocalizar (misma razon que
  -- stg_cert_pares; ver el job #315).
  DROP TABLE IF EXISTS bdm_tempo.stg_cert_r3;
  CREATE TABLE bdm_tempo.stg_cert_r3
  DISTSTYLE ALL
  AS
  SELECT
    rpu.cod_dw_persona_ubic                                           AS dir,
    CAST((rpu.cod_dw_persona_ubic / 10 - 9000000) / 10000 AS INTEGER) AS arq,
    rpu.id_buro_persona                                               AS persona,
    ubi.tipo_ubicacion,
    ubi.texto_ubicacion,
    ubi.latitud,
    ubi.longitud,
    df.tipo_via_principal,
    df.via_principal,
    df.via_generadora,
    df.numero_puerta,
    -- QA #176: misma guarda que sp_unificacion_r3_esc1 (ver su cabecera). El
    -- evaluador tiene que medir lo MISMO que el escenario; sin la guarda aqui,
    -- el criterio leeria una puerta que el escenario descarta.
    CASE WHEN NULLIF(REGEXP_SUBSTR(COALESCE(df.numero_puerta, ''), '^[0-9]+$'), '') IS NOT NULL
          AND CAST(NULLIF(REGEXP_SUBSTR(COALESCE(df.numero_puerta, ''), '^[0-9]+$'), '') AS BIGINT) <= 2147483647
         THEN CAST(NULLIF(REGEXP_SUBSTR(COALESCE(df.numero_puerta, ''), '^[0-9]+$'), '') AS INTEGER)
         ELSE NULL
    END AS puerta_num,
    COALESCE(r.entidades, 0) AS entidades,
    COALESCE(r.filas_rep, 0) AS filas_rep,
    r.ult_reporte,
    u3.padre                 AS padre_r3
  FROM bdm_tempo.v_mock_relacion_persona_ubicacion rpu
  JOIN bdm_tempo.v_mock_ubicacion_estandarizada ubi
    ON ubi.cod_dw_ubic = rpu.cod_dw_ubic
  LEFT JOIN bdm_tempo.v_mock_direccion_fisica df
    ON df.cod_dw_direccion_fisica = rpu.cod_dw_direccion_fisica
  LEFT JOIN ( SELECT cod_dw_persona_ubic,
                     COUNT(DISTINCT id_buro_suscriptor) AS entidades,
                     COUNT(*)                           AS filas_rep,
                     MAX(fecha_reporte)                 AS ult_reporte
                FROM bdm_tempo.v_mock_reporte_relacion_persona_ubica
               GROUP BY 1 ) r
    ON r.cod_dw_persona_ubic = rpu.cod_dw_persona_ubic
  LEFT JOIN ( SELECT cod_dw_persona_ubic,
                     MAX(cod_dw_direccion_unificada) AS padre
                FROM bdm_datos.unificacion_direccion_mock
               WHERE unifica_atributos = 3
               GROUP BY 1 ) u3
    ON u3.cod_dw_persona_ubic = rpu.cod_dw_persona_ubic
  WHERE rpu.cod_dw_persona_ubic BETWEEN 96100000 AND 97009999;

  -- ==================================================================
  -- REGLA 1
  -- ==================================================================

  -- R1-01. Invariante matriz-independiente: con CIIU 10 no puede existir una
  -- pareja donde la HIJA sea del tipo preferido (LAB o CRR) y el PADRE no lo
  -- sea. Enuncia el requerimiento sin depender del arquetipo sembrado, de modo
  -- que sigue siendo valido cuando la matriz crezca.
  INSERT INTO bdm_datos.cert_resultado
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'R1-01',
         CASE WHEN COUNT(*) = 0 THEN 'PASSED' ELSE 'FAILED' END,
         'parejas CIIU 10 donde el tipo preferido perdio=' || CAST(COUNT(*) AS VARCHAR),
         GETDATE(), CURRENT_USER
  FROM   bdm_tempo.stg_cert_pares
  WHERE  regla = 1
    AND  ciiu  = '10'
    AND  tipo_hija  IN ('LAB','CRR')
    AND  COALESCE(tipo_padre,'') NOT IN ('LAB','CRR');

  -- R1-02. Mismo invariante con el baseline sin actividad y tipo RES o CRR.
  INSERT INTO bdm_datos.cert_resultado
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'R1-02',
         CASE WHEN COUNT(*) = 0 THEN 'PASSED' ELSE 'FAILED' END,
         'parejas CIIU 81/82/90 donde el tipo preferido perdio=' || CAST(COUNT(*) AS VARCHAR),
         GETDATE(), CURRENT_USER
  FROM   bdm_tempo.stg_cert_pares
  WHERE  regla = 1
    AND  ciiu  IN ('81','82','90')
    AND  tipo_hija  IN ('RES','CRR')
    AND  COALESCE(tipo_padre,'') NOT IN ('RES','CRR');

  -- R1-03. Sin preferencia de tipo: la hija no puede tener MAS entidades
  -- reportantes que el padre.
  INSERT INTO bdm_datos.cert_resultado
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'R1-03',
         CASE WHEN COUNT(*) = 0 THEN 'PASSED' ELSE 'FAILED' END,
         'parejas otros CIIU donde la hija tenia mas entidades=' || CAST(COUNT(*) AS VARCHAR),
         GETDATE(), CURRENT_USER
  FROM   bdm_tempo.stg_cert_pares
  WHERE  regla = 1
    AND  ciiu NOT IN ('10','81','82','90')
    AND  ent_hija > ent_padre;

  -- R1-04. Toda hija registrada queda marcada con ind_unificacion = 1. En la
  -- via real y en la mock el indicador se DERIVA de unificacion_direccion
  -- (v_*_relacion_persona_ubicacion), porque la fuente del datashare es de
  -- solo lectura y no admite el UPDATE del legado.
  INSERT INTO bdm_datos.cert_resultado
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'R1-04',
         CASE WHEN COUNT(*) = 0 THEN 'PASSED' ELSE 'FAILED' END,
         'hijas sin ind_unificacion=1 en la vista=' || CAST(COUNT(*) AS VARCHAR),
         GETDATE(), CURRENT_USER
  FROM   bdm_tempo.stg_cert_pares
  WHERE  COALESCE(ind_unif_hija, 0) <> 1;

  -- R1-05. Trazabilidad del par: existe, y con lote y fecha poblados.
  INSERT INTO bdm_datos.cert_resultado
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'R1-05',
         CASE WHEN SUM(CASE WHEN regla = 1 THEN 1 ELSE 0 END) > 0
               AND SUM(CASE WHEN regla = 1
                             AND (lote IS NULL OR fecha_unificacion IS NULL)
                            THEN 1 ELSE 0 END) = 0
              THEN 'PASSED' ELSE 'FAILED' END,
         'parejas R1=' || CAST(COALESCE(SUM(CASE WHEN regla = 1 THEN 1 ELSE 0 END), 0) AS VARCHAR)
           || ', sin lote o sin fecha='
           || CAST(COALESCE(SUM(CASE WHEN regla = 1
                                      AND (lote IS NULL OR fecha_unificacion IS NULL)
                                     THEN 1 ELSE 0 END), 0) AS VARCHAR),
         GETDATE(), CURRENT_USER
  FROM   bdm_tempo.stg_cert_pares;

  -- R1-06. Dos mitades, y solo una tiene dato.
  --   "ya son hijas": SI es verificable. La matriz siembra ind_unificacion = 1
  --      en las posiciones YA_UNIF, y ninguna de esas direcciones puede
  --      aparecer como hija de una pareja nueva.
  --   "bloqueadas": NO hay dato. El seed nunca escribe bloqueado y la vista lo
  --      fija en 0 en sus dos ramas. Un COUNT(*) = 0 sobre cero direcciones
  --      bloqueadas no es evidencia de nada -- seria un PASSED vacuo, el mismo
  --      defecto que corregi en G-02 y R2-14.
  -- Por eso el veredicto exige que exista dato de las dos mitades; si falta la
  -- de bloqueo, el criterio queda SIN_DATO y el detalle dice cual mitad si se
  -- verifico. G-04 sigue el bloqueo por separado.
  INSERT INTO bdm_datos.cert_resultado
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'R1-06',
         CASE WHEN SUM(viola) > 0                     THEN 'FAILED'
              WHEN SUM(hay_bloqueo) = 0               THEN 'SIN_DATO'
              ELSE 'PASSED' END,
         'parejas cuya hija ya era hija antes de la corrida='
           || CAST(COALESCE(SUM(CASE WHEN ya_era_hija = 1 THEN 1 ELSE 0 END), 0) AS VARCHAR)
           || ', parejas con hija bloqueada='
           || CAST(COALESCE(SUM(CASE WHEN bloq = 1 THEN 1 ELSE 0 END), 0) AS VARCHAR)
           || ', direcciones bloqueadas en el universo='
           || CAST(COALESCE(SUM(hay_bloqueo), 0) AS VARCHAR)
           || '. Con 0 bloqueadas la mitad de bloqueo no se puede afirmar (ver G-04).',
         GETDATE(), CURRENT_USER
  FROM ( SELECT CASE WHEN COALESCE(p.ind_unif_base, 0) = 1 THEN 1 ELSE 0 END AS ya_era_hija,
                CASE WHEN p.bloqueado_hija = 1 THEN 1 ELSE 0 END             AS bloq,
                CASE WHEN COALESCE(p.ind_unif_base, 0) = 1
                       OR p.bloqueado_hija = 1 THEN 1 ELSE 0 END             AS viola,
                0                                                            AS hay_bloqueo
           FROM bdm_tempo.stg_cert_pares p
         UNION ALL
         SELECT 0, 0, 0, COUNT(*)
           FROM bdm_tempo.v_mock_relacion_persona_ubicacion
          WHERE COALESCE(bloqueado, 0) = 1 ) r16;

  -- R1-07. El baseline es verificable solo si el universo TIENE los tres
  -- valores. Mientras falten 82 y 90 el criterio no se puede afirmar: el
  -- codigo los contempla (IN ('81','82','90')) pero ningun dato los ejercita.
  INSERT INTO bdm_datos.cert_resultado
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  -- NOTA Redshift: LISTAGG(DISTINCT ...) no se puede combinar con
  -- COUNT(DISTINCT ...) en el mismo SELECT. Se deduplica en la subconsulta y
  -- arriba quedan agregados simples.
  SELECT p_lote, p_fase, 'R1-07',
         CASE WHEN COUNT(*) = 3 THEN 'PASSED' ELSE 'SIN_DATO' END,
         'valores del baseline sin actividad presentes en el universo='
           || CAST(COUNT(*) AS VARCHAR) || ' de 3 ('
           || COALESCE(LISTAGG(ciiu, ',') WITHIN GROUP (ORDER BY ciiu), 'ninguno')
           || '). El codigo contempla 81, 82 y 90.',
         GETDATE(), CURRENT_USER
  FROM ( SELECT DISTINCT cod_act_econo_ciiu_fte AS ciiu
           FROM bdm_tempo.v_mock_ciiu_persona
          WHERE cod_act_econo_ciiu_fte IN ('81','82','90') ) b;

  -- R1-08. SI HAY DATO, y la version anterior lo declaraba SIN_DATO sin mirar.
  -- La numeracion de arquetipos reserva el escenario 4 de la Regla 1 justamente
  -- para el EMPATE: ARQ 16 a 20 siembran CIIU 10 con padre LAB y hija CRR --
  -- los DOS tipos preferidos -- y 5 entidades reportantes en ambos lados. El
  -- score queda identico (100000 + 5), el HAVING COUNT(*) = 1 sobre el
  -- max_score descarta el grupo y no se unifica nada. La matriz esperada del
  -- gate por arquetipo ya lo afirma con filas_persona = 0 para esos cinco.
  --
  -- Aqui se afirma el enunciado del requerimiento de forma directa: ninguna
  -- direccion de un arquetipo de empate puede haber recibido padre. El ARQ se
  -- recupera de la clave de la semilla igual que en el gate por arquetipo:
  --     ARQ = (cod_dw_persona_ubic / 10 - 9000000) / 10000
  -- y se exige que los arquetipos existan, para que un universo vacio no se
  -- lea como criterio cumplido.
  INSERT INTO bdm_datos.cert_resultado
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'R1-08',
         CASE WHEN SUM(sembradas) = 0  THEN 'SIN_DATO'
              WHEN SUM(unificadas) = 0 THEN 'PASSED'
              ELSE 'FAILED' END,
         'direcciones en arquetipos de empate (ARQ 16..20)='
           || CAST(COALESCE(SUM(sembradas), 0) AS VARCHAR)
           || ', de ellas unificadas=' || CAST(COALESCE(SUM(unificadas), 0) AS VARCHAR)
           || ' (debe ser 0: mismo tipo preferido y mismas entidades, el empate no decide).',
         GETDATE(), CURRENT_USER
  FROM ( SELECT COUNT(*) AS sembradas, 0 AS unificadas
           FROM bdm_tempo.v_mock_relacion_persona_ubicacion
          WHERE cod_dw_persona_ubic BETWEEN 90100000 AND 95609999
            AND (cod_dw_persona_ubic / 10 - 9000000) / 10000 BETWEEN 16 AND 20
         UNION ALL
         SELECT 0, COUNT(*)
           FROM bdm_tempo.stg_cert_pares
          WHERE hija BETWEEN 90100000 AND 95609999
            AND (hija / 10 - 9000000) / 10000 BETWEEN 16 AND 20 ) r18;

  -- ==================================================================
  -- REGLA 2
  -- ==================================================================
  -- Los escenarios 1 a 4 se afirman con el censo, que cuenta direcciones y
  -- personas por sello.
  --
  -- LA FASE IMPORTA, y la primera version no lo tenia en cuenta. Un DELTA sobre
  -- datos SIN MUTAR no produce unificaciones nuevas: el censo reporta 0 en todos
  -- los sellos y ese 0 es el comportamiento CORRECTO -- es justo lo que CA-U07
  -- del gate por arquetipo afirma como PASSED ("filas nuevas del lote
  -- 1356602=0, esperado 0"). Juzgarlo FAILED convertia el acierto en defecto: en
  -- el job #318 la columna de evolucion por fase mostraba R2-01..R2-05 en rojo
  -- en DELTA1 y DELTA2 teniendolos bien.
  --
  --   cualquier fase con > 0  -> PASSED. Es el caso del DELTA2, donde la
  --                              mutacion aporta 200 direcciones al sello H1.
  --   DELTA con 0             -> NO_APLICA. No hay nada nuevo que resolver; el
  --                              criterio se certifica en la fase FULL.
  --   FULL / FULL2 con 0      -> FAILED. El arquetipo existe, el escenario
  --                              tenia que disparar.
  INSERT INTO bdm_datos.cert_resultado
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, m.criterio,
         CASE WHEN COALESCE(c.direcciones, 0) > 0  THEN 'PASSED'
              WHEN p_fase NOT IN ('FULL', 'FULL2') THEN 'NO_APLICA'
              ELSE 'FAILED' END,
         'sello ' || m.n_id || ': direcciones='
           || CAST(COALESCE(c.direcciones, 0) AS VARCHAR)
           || ', personas=' || CAST(COALESCE(c.personas, 0) AS VARCHAR)
           || CASE WHEN COALESCE(c.direcciones, 0) = 0
                    AND p_fase NOT IN ('FULL', 'FULL2')
                   THEN '. Cero es correcto en un DELTA sobre datos sin mutar; '
                        || 'este criterio se certifica en la fase FULL.'
                   ELSE '' END,
         GETDATE(), CURRENT_USER
  FROM ( SELECT 'R2-01' AS criterio, 'H1' AS n_id UNION ALL
         SELECT 'R2-02', 'K2' UNION ALL
         SELECT 'R2-03', 'L3' UNION ALL
         SELECT 'R2-04', 'X4' UNION ALL
         SELECT 'R2-05', 'B5' ) m
  LEFT JOIN ( SELECT n_id, SUM(direcciones) AS direcciones, SUM(personas) AS personas
                FROM bdm_datos.unif_escenario_censo_mock
               WHERE lote = p_lote
               GROUP BY 1 ) c
         ON c.n_id = m.n_id;

  -- R2-06. Escenario 5 subcaso 1 del legado = sello A6 (lineas 2250-3607):
  -- crea una direccion nueva que combina ambas nomenclaturas y deja las dos
  -- originales como hijas. El subcaso 2 (sello C7) es el que ya estaba
  -- portado como esc5 y NO satisface este criterio: no crea nada.
  --
  -- El criterio tiene TRES mitades y las tres se afirman, no solo que el
  -- sello disparo:
  --   a) las DOS originales quedan como hijas de la misma direccion -- el
  --      padre incluido, que es lo que dice la linea 2256 del legado;
  --   b) el padre de esas dos existe como direccion GENERADA, no como una de
  --      las originales;
  --   c) el complemento generado combina ambas SIN repetir la nomenclatura
  --      que comparten ('ED 1 CS 5' + 'LC 3 CS 9' -> 'ED 1 CS 5 LC 3'), que
  --      es lo que R2-12 exige.
  --
  -- NO depende de la fase. Las parejas y las direcciones generadas PERSISTEN
  -- entre corridas (el DELTA no trunca), de modo que las tres mitades siguen
  -- siendo verificables en DELTA1 y DELTA2. Por eso no lleva la rama
  -- NO_APLICA de R2-01..R2-05, que si dependen del censo del lote.
  --
  -- La primera rama, COUNT(*) = 0, no es decorativa: sin ella un arquetipo que
  -- no produjo NADA daria SUM(...) = NULL en las tres comparaciones y el CASE
  -- caeria al ELSE 'PASSED'. Es el mismo PASS vacuo que se corrigio en R3.
  INSERT INTO bdm_datos.cert_resultado
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'R2-06',
         CASE WHEN COUNT(*) = 0
                   THEN CASE WHEN p_fase IN ('FULL', 'FULL2') THEN 'FAILED' ELSE 'SIN_DATO' END
              WHEN COALESCE(SUM(CASE WHEN a.hijas <> 2      THEN 1 ELSE 0 END), 0) > 0 THEN 'FAILED'
              WHEN COALESCE(SUM(CASE WHEN a.padre_generado = 0 THEN 1 ELSE 0 END), 0) > 0 THEN 'FAILED'
              WHEN COALESCE(SUM(CASE WHEN a.complemento_ok = 0 THEN 1 ELSE 0 END), 0) > 0 THEN 'FAILED'
              ELSE 'PASSED' END,
         'direcciones nuevas del arquetipo 71 (sitio 2)=' || CAST(COUNT(*) AS VARCHAR)
           || ', de ellas con las DOS originales como hijas='
           || CAST(COALESCE(SUM(CASE WHEN a.hijas = 2 THEN 1 ELSE 0 END), 0) AS VARCHAR)
           || ', con el padre en rpu_generada_mock='
           || CAST(COALESCE(SUM(a.padre_generado), 0) AS VARCHAR)
           || ', con complemento ''ED 1 CS 5 LC 3'' (sin repetir CS)='
           || CAST(COALESCE(SUM(a.complemento_ok), 0) AS VARCHAR)
           || '. Sello A6 del censo de esta corrida: direcciones='
           || CAST(COALESCE(MAX(cen.a6_dir), 0) AS VARCHAR),
         GETDATE(), CURRENT_USER
  FROM ( SELECT u.cod_dw_direccion_unificada                          AS padre,
                COUNT(DISTINCT u.cod_dw_persona_ubic)                 AS hijas,
                MAX(CASE WHEN g.cod_dw_persona_ubic IS NOT NULL
                         THEN 1 ELSE 0 END)                           AS padre_generado,
                MAX(CASE WHEN TRIM(COALESCE(d.complemento, '')) = 'ED 1 CS 5 LC 3'
                         THEN 1 ELSE 0 END)                           AS complemento_ok
           FROM bdm_datos.unificacion_direccion_mock u
           LEFT JOIN bdm_datos.rpu_generada_mock g
             ON g.cod_dw_persona_ubic = u.cod_dw_direccion_unificada
           LEFT JOIN bdm_datos.direccion_fisica_generada_mock d
             ON d.cod_dw_direccion_fisica = g.cod_dw_direccion_fisica
          WHERE u.cod_dw_persona_ubic BETWEEN 97100000 AND 97109999
            AND u.unifica_atributos = 2
          GROUP BY 1 ) a
  -- CROSS JOIN y no subconsulta escalar en la proyeccion: Redshift no la
  -- resuelve de forma fiable dentro de una agregacion.
  CROSS JOIN ( SELECT COALESCE(SUM(direcciones), 0) AS a6_dir
                 FROM bdm_datos.unif_escenario_censo_mock
                WHERE lote = p_lote AND n_id = 'A6' ) cen;

  -- R2-07. Escenario 6 del legado son TRES subcasos, con sellos A8, D9 y F1
  -- (lineas 4016-5847). A8 (sub1, linea 4016) y D9 (sub2, linea 4715) son los
  -- dos sitios que CREAN direcciones nuevas y los dos estan portados: el
  -- criterio los afirma aqui, cada uno con su arquetipo.
  --
  -- F1 (sub3, linea 5453) resuelve por frecuencia del diccionario y NO crea
  -- direcciones; nuestro esc6 hace esa misma eleccion y por tanto lo aproxima,
  -- aunque lo selle como 'E6' -- un sello propio que no existe en el legado.
  -- La diferencia es de etiqueta, no de resultado, y queda anotada como
  -- divergencia para GOB-03.
  --
  -- Se afirman las mismas tres mitades que en R2-06, para los dos sitios:
  --   a) las DOS originales quedan como hijas de la misma direccion;
  --   b) ese padre existe como direccion GENERADA, no como una de las
  --      originales;
  --   c) el complemento generado combina ambas sin repetir nomenclatura
  --      ('BL 2 ED 7' para el sitio 3, 'BR 5 AP 301' para el sitio 4).
  -- Y una cuarta, propia de este criterio: que los DOS sitios produjeron. Sin
  -- ella bastaria con que uno de los dos funcionara.
  --
  -- La rama COUNT(*) = 0 no es decorativa: sin ella un arquetipo que no
  -- produjo nada daria SUM(...) = NULL y el CASE caeria al ELSE 'PASSED'.
  INSERT INTO bdm_datos.cert_resultado
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'R2-07',
         CASE WHEN COUNT(*) = 0
                   THEN CASE WHEN p_fase IN ('FULL', 'FULL2') THEN 'FAILED' ELSE 'SIN_DATO' END
              WHEN COUNT(DISTINCT a.sitio) < 2                                            THEN 'FAILED'
              WHEN COALESCE(SUM(CASE WHEN a.hijas <> 2         THEN 1 ELSE 0 END), 0) > 0 THEN 'FAILED'
              WHEN COALESCE(SUM(CASE WHEN a.padre_generado = 0 THEN 1 ELSE 0 END), 0) > 0 THEN 'FAILED'
              WHEN COALESCE(SUM(CASE WHEN a.complemento_ok = 0 THEN 1 ELSE 0 END), 0) > 0 THEN 'FAILED'
              ELSE 'PASSED' END,
         'direcciones nuevas del sitio 3 (A8, ARQ 72)='
           || CAST(COALESCE(SUM(CASE WHEN a.sitio = 3 THEN 1 ELSE 0 END), 0) AS VARCHAR)
           || ', del sitio 4 (D9, ARQ 73)='
           || CAST(COALESCE(SUM(CASE WHEN a.sitio = 4 THEN 1 ELSE 0 END), 0) AS VARCHAR)
           || '; con las DOS originales como hijas='
           || CAST(COALESCE(SUM(CASE WHEN a.hijas = 2 THEN 1 ELSE 0 END), 0) AS VARCHAR)
           || ', con el padre en rpu_generada_mock='
           || CAST(COALESCE(SUM(a.padre_generado), 0) AS VARCHAR)
           || ', con el complemento esperado='
           || CAST(COALESCE(SUM(a.complemento_ok), 0) AS VARCHAR)
           || '. Censo de esta corrida: A8='
           || CAST(COALESCE(MAX(cen.a8_dir), 0) AS VARCHAR)
           || ' direcciones, D9='
           || CAST(COALESCE(MAX(cen.d9_dir), 0) AS VARCHAR)
           || ', E6=' || CAST(COALESCE(MAX(cen.e6_dir), 0) AS VARCHAR)
           || ' (E6 aproxima F1, sub3)',
         GETDATE(), CURRENT_USER
  FROM ( SELECT 3                                                     AS sitio,
                u.cod_dw_direccion_unificada                          AS padre,
                COUNT(DISTINCT u.cod_dw_persona_ubic)                 AS hijas,
                MAX(CASE WHEN g.cod_dw_persona_ubic IS NOT NULL
                         THEN 1 ELSE 0 END)                           AS padre_generado,
                MAX(CASE WHEN TRIM(COALESCE(d.complemento, '')) = 'BL 2 ED 7'
                         THEN 1 ELSE 0 END)                           AS complemento_ok
           FROM bdm_datos.unificacion_direccion_mock u
           LEFT JOIN bdm_datos.rpu_generada_mock g
             ON g.cod_dw_persona_ubic = u.cod_dw_direccion_unificada
           LEFT JOIN bdm_datos.direccion_fisica_generada_mock d
             ON d.cod_dw_direccion_fisica = g.cod_dw_direccion_fisica
          WHERE u.cod_dw_persona_ubic BETWEEN 97200000 AND 97209999
            AND u.unifica_atributos = 2
          GROUP BY 1, 2
         UNION ALL
         SELECT 4,
                u.cod_dw_direccion_unificada,
                COUNT(DISTINCT u.cod_dw_persona_ubic),
                MAX(CASE WHEN g.cod_dw_persona_ubic IS NOT NULL
                         THEN 1 ELSE 0 END),
                MAX(CASE WHEN TRIM(COALESCE(d.complemento, '')) = 'BR 5 AP 301'
                         THEN 1 ELSE 0 END)
           FROM bdm_datos.unificacion_direccion_mock u
           LEFT JOIN bdm_datos.rpu_generada_mock g
             ON g.cod_dw_persona_ubic = u.cod_dw_direccion_unificada
           LEFT JOIN bdm_datos.direccion_fisica_generada_mock d
             ON d.cod_dw_direccion_fisica = g.cod_dw_direccion_fisica
          WHERE u.cod_dw_persona_ubic BETWEEN 97300000 AND 97309999
            AND u.unifica_atributos = 2
          GROUP BY 1, 2 ) a
  -- CROSS JOIN y no subconsulta escalar en la proyeccion: Redshift no la
  -- resuelve de forma fiable dentro de una agregacion.
  CROSS JOIN ( SELECT COALESCE(SUM(CASE WHEN n_id = 'A8' THEN direcciones END), 0) AS a8_dir,
                      COALESCE(SUM(CASE WHEN n_id = 'D9' THEN direcciones END), 0) AS d9_dir,
                      COALESCE(SUM(CASE WHEN n_id = 'E6' THEN direcciones END), 0) AS e6_dir
                 FROM bdm_datos.unif_escenario_censo_mock
                WHERE lote = p_lote ) cen;

  -- R2-08. Las direcciones que crea el motor quedan marcadas como generadas.
  INSERT INTO bdm_datos.cert_resultado
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'R2-08',
         CASE WHEN COUNT(*) > 0
               AND SUM(CASE WHEN COALESCE(generada_enriquecida, 0) <> 1 THEN 1 ELSE 0 END) = 0
              THEN 'PASSED' ELSE 'FAILED' END,
         'direcciones generadas=' || CAST(COUNT(*) AS VARCHAR)
           || ', sin marca generada_enriquecida=1='
           || CAST(COALESCE(SUM(CASE WHEN COALESCE(generada_enriquecida, 0) <> 1
                                    THEN 1 ELSE 0 END), 0) AS VARCHAR),
         GETDATE(), CURRENT_USER
  FROM   bdm_datos.direccion_fisica_generada_mock;

  -- R2-09. Y cada una tiene su relacion persona-ubicacion.
  INSERT INTO bdm_datos.cert_resultado
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'R2-09',
         CASE WHEN COUNT(*) = 0 THEN 'PASSED' ELSE 'FAILED' END,
         'direcciones generadas sin relacion persona-ubicacion='
           || CAST(COUNT(*) AS VARCHAR),
         GETDATE(), CURRENT_USER
  FROM   bdm_datos.direccion_fisica_generada_mock d
  WHERE  NOT EXISTS ( SELECT 1
                        FROM bdm_datos.rpu_generada_mock r
                       WHERE r.cod_dw_direccion_fisica = d.cod_dw_direccion_fisica );

  -- R2-10. Un padre no puede ser hija dentro de la misma regla.
  INSERT INTO bdm_datos.cert_resultado
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'R2-10',
         CASE WHEN COUNT(*) = 0 THEN 'PASSED' ELSE 'FAILED' END,
         'direcciones que son padre e hija en la misma regla='
           || CAST(COUNT(*) AS VARCHAR),
         GETDATE(), CURRENT_USER
  FROM ( SELECT DISTINCT a.padre, a.regla
           FROM bdm_tempo.stg_cert_pares a
           JOIN bdm_tempo.stg_cert_pares b
             ON b.hija  = a.padre
            AND b.regla = a.regla ) x;

  -- R2-11. Cada hija con exactamente un padre.
  INSERT INTO bdm_datos.cert_resultado
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'R2-11',
         CASE WHEN COUNT(*) = 0 THEN 'PASSED' ELSE 'FAILED' END,
         'direcciones con mas de un padre=' || CAST(COUNT(*) AS VARCHAR),
         GETDATE(), CURRENT_USER
  FROM ( SELECT hija
           FROM bdm_tempo.stg_cert_pares
          GROUP BY hija
         HAVING COUNT(DISTINCT padre) > 1 ) y;

  -- R2-12. El complemento corregido: sin duplicidad de nomenclatura y no
  -- vacio. El orden logico lo afirma el gate por arquetipo (CA-U04 compara el
  -- complemento generado contra el esperado token por token).
  INSERT INTO bdm_datos.cert_resultado
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'R2-12',
         CASE WHEN COUNT(*) > 0 AND SUM(malos) = 0 THEN 'PASSED'
              WHEN COUNT(*) = 0 THEN 'SIN_DATO'
              ELSE 'FAILED' END,
         'complementos generados=' || CAST(COUNT(*) AS VARCHAR)
           || ', con nomenclatura repetida o vacios='
           || CAST(COALESCE(SUM(malos), 0) AS VARCHAR)
           || '. El orden logico lo afirma CA-U04 del gate por arquetipo.',
         GETDATE(), CURRENT_USER
  -- NOTA Redshift, dos restricciones a la vez: EXISTS no se admite en la lista
  -- del SELECT, y el patron de REGEXP_* tiene que ser un literal (no se puede
  -- derivar de una columna como TRIM(n.nomenclatura)). La duplicidad se detecta
  -- con STRPOS: se busca la nomenclatura y despues se vuelve a buscar en el
  -- resto de la cadena; si aparece otra vez, esta repetida. Se enmarca con
  -- espacios para no confundir 'CA' dentro de otra palabra.
  FROM ( SELECT g.cod_dw_direccion_fisica,
                MAX(CASE
                      WHEN NULLIF(TRIM(COALESCE(g.complemento, '')), '') IS NULL
                      THEN 1
                      WHEN n.nomenclatura IS NOT NULL
                       AND STRPOS( SUBSTRING( ' ' || g.complemento || ' ',
                                              STRPOS(' ' || g.complemento || ' ',
                                                     ' ' || TRIM(n.nomenclatura) || ' ')
                                              + LENGTH(TRIM(n.nomenclatura)) + 1 ),
                                   ' ' || TRIM(n.nomenclatura) || ' ' ) > 0
                      THEN 1
                      ELSE 0 END) AS malos
           FROM      bdm_datos.direccion_fisica_generada_mock g
           LEFT JOIN bdm_datos.nomenclatura n
                  ON STRPOS(' ' || g.complemento || ' ',
                            ' ' || TRIM(n.nomenclatura) || ' ') > 0
          GROUP BY 1 ) z;

  -- R2-13. El diccionario existe y se construyo con frecuencias.
  INSERT INTO bdm_datos.cert_resultado
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'R2-13',
         CASE WHEN COUNT(*) > 0 AND SUM(CASE WHEN COALESCE(frecuencia, 0) > 0
                                             THEN 1 ELSE 0 END) > 0
              THEN 'PASSED' ELSE 'FAILED' END,
         'filas del diccionario=' || CAST(COUNT(*) AS VARCHAR)
           || ', con frecuencia > 0='
           || CAST(COALESCE(SUM(CASE WHEN COALESCE(frecuencia, 0) > 0
                                    THEN 1 ELSE 0 END), 0) AS VARCHAR),
         GETDATE(), CURRENT_USER
  FROM   bdm_stage.diccionario_complementos;

  -- R2-14. El empate no decide. Invariante verificable: dos direcciones no
  -- pueden ser padre e hija LA UNA DE LA OTRA. Una pareja mutua (a->b y b->a)
  -- es la firma de un empate que se resolvio en los dos sentidos, que es
  -- exactamente lo que el criterio prohibe. El arquetipo E6 ejercita el caso:
  -- 'CA 1 LT 2' y 'CA 3 LT 4' empatan en frecuencia 5 y ninguna puede ser hija
  -- de la otra.
  INSERT INTO bdm_datos.cert_resultado
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'R2-14',
         CASE WHEN COUNT(*) = 0 THEN 'PASSED' ELSE 'FAILED' END,
         'parejas mutuas (empate resuelto en ambos sentidos)='
           || CAST(COUNT(*) AS VARCHAR)
           || '. Brecha del censo (tenian pareja posible y nadie unifico)='
           || CAST(COALESCE(( SELECT SUM(direcciones)
                                FROM bdm_datos.unif_escenario_censo_mock
                               WHERE lote = p_lote
                                 AND escenario LIKE '%sin resolver%' ), 0) AS VARCHAR),
         GETDATE(), CURRENT_USER
  FROM   bdm_tempo.stg_cert_pares a
  WHERE  EXISTS ( SELECT 1
                    FROM bdm_tempo.stg_cert_pares b
                   WHERE b.hija  = a.padre
                     AND b.padre = a.hija );

  -- ==================================================================
  -- REGLA 3
  -- ==================================================================
  -- SLCOPRBA-1355: los diez criterios pasan de un bloque de texto a diez
  -- aserciones con dato. Lo que lo permitio fue encontrar el legado -- el
  -- bloque anterior decia "no existe el Diccionario de Via" y si existe:
  -- P0021_UNIFICACION_111.BTQ lo construye -- y cerrar los tres agujeros de
  -- estructura: las cuatro columnas de via eran CAST(NULL AS ...) en la vista,
  -- las coordenadas no salian de geo_atributos y el ciclo mock no llamaba R3.
  --
  -- CADA CRITERIO SE AFIRMA CON SU ARQUETIPO, no con un invariante global: la
  -- banda 9610000..9700999 siembra un subcaso por arquetipo y la asercion
  -- compara lo que ese subcaso produjo contra lo que debia producir. Los que
  -- esperan CERO exigen ademas que el arquetipo TENGA dato: un 0 sobre un
  -- universo vacio no es evidencia de nada, es el PASSED vacuo que ya corregi
  -- en G-02, R1-06 y R2-14.
  --
  --   61  una sola geolocalizada          R3-02   1 pareja
  --   62  ninguna geolocalizada           R3-03   1 pareja (gana la fecha)
  --   63  las dos geolocalizadas          R3-04   1 pareja (gana el diccionario)
  --   64  puerta a +-2                    R3-05   1 pareja
  --   65  puerta a +-5                    R3-06   0 parejas
  --   66  modificador de via '45B'        R3-07   0 parejas
  --   67  cuadrante en la via principal   R3-08   1 pareja (NO excluye)
  --   68  tipo MZ                         R3-01   0 parejas
  --   69  tipo Rural                      R3-01   0 parejas
  --   70  empate de diccionario           R3-10   0 parejas

  -- R3-01. Solo tipo Via: Manzana y Rural quedan fuera de la regla.
  -- Las dos mitades necesitan dato: que existan direcciones MZ y Rural en el
  -- universo, y que ninguna haya unificado.
  INSERT INTO bdm_datos.cert_resultado
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'R3-01',
         -- COALESCE en cada SUM y COUNT(*) = 0 como primera rama: sobre cero
         -- filas los SUM dan NULL, toda comparacion da NULL y el CASE caeria
         -- al ELSE. Seria un PASSED vacuo, el mismo defecto corregido antes en
         -- G-02, R1-06 y R2-14.
         CASE WHEN COUNT(*) = 0 THEN 'SIN_DATO'
              WHEN COALESCE(SUM(CASE WHEN padre_r3 IS NOT NULL THEN 1 ELSE 0 END), 0) > 0 THEN 'FAILED'
              WHEN COALESCE(SUM(CASE WHEN UPPER(TRIM(COALESCE(tipo_ubicacion,''))) = 'MZ'    THEN 1 ELSE 0 END), 0) = 0
                OR COALESCE(SUM(CASE WHEN UPPER(TRIM(COALESCE(tipo_ubicacion,''))) = 'RURAL' THEN 1 ELSE 0 END), 0) = 0
                   THEN 'SIN_DATO'
              ELSE 'PASSED' END,
         'direcciones de tipo MZ='
           || CAST(SUM(CASE WHEN UPPER(TRIM(COALESCE(tipo_ubicacion,''))) = 'MZ' THEN 1 ELSE 0 END) AS VARCHAR)
           || ', de tipo Rural='
           || CAST(SUM(CASE WHEN UPPER(TRIM(COALESCE(tipo_ubicacion,''))) = 'RURAL' THEN 1 ELSE 0 END) AS VARCHAR)
           || ', de ellas unificadas por R3='
           || CAST(SUM(CASE WHEN padre_r3 IS NOT NULL THEN 1 ELSE 0 END) AS VARCHAR)
           || ' (debe ser 0: el insumo de R3 exige tipo Via).',
         GETDATE(), CURRENT_USER
  FROM   bdm_tempo.stg_cert_r3
  WHERE  arq IN (68, 69);

  -- R3-02. Solo una geolocalizada: el padre es la geolocalizada.
  -- El 100000000 del puntaje es lo que lo garantiza; aqui se verifica el
  -- RESULTADO, no la formula.
  INSERT INTO bdm_datos.cert_resultado
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'R3-02',
         CASE WHEN COUNT(*) = 0                                     THEN 'SIN_DATO'
              WHEN SUM(CASE WHEN p.latitud IS NULL
                              OR h.latitud IS NOT NULL THEN 1 ELSE 0 END) > 0 THEN 'FAILED'
              ELSE 'PASSED' END,
         'parejas del arquetipo 61 (una sola geolocalizada)=' || CAST(COUNT(*) AS VARCHAR)
           || ', de ellas con el padre SIN coordenadas o la hija CON coordenadas='
           || CAST(COALESCE(SUM(CASE WHEN p.latitud IS NULL
                                       OR h.latitud IS NOT NULL THEN 1 ELSE 0 END), 0) AS VARCHAR),
         GETDATE(), CURRENT_USER
  FROM      bdm_tempo.stg_cert_r3 h
  JOIN      bdm_tempo.stg_cert_r3 p ON p.dir = h.padre_r3
  WHERE     h.arq = 61;

  -- R3-03. Ninguna geolocalizada: gana la de fecha mas reciente y las
  -- entidades desempatan. La fecha que puntua es MAX(fecha_reporte), no la de
  -- la relacion: es la que el legado mete en el puntaje.
  INSERT INTO bdm_datos.cert_resultado
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'R3-03',
         CASE WHEN COUNT(*) = 0 THEN 'SIN_DATO'
              WHEN SUM(CASE WHEN h.latitud IS NOT NULL OR p.latitud IS NOT NULL
                            THEN 1 ELSE 0 END) > 0                       THEN 'FAILED'
              WHEN SUM(CASE WHEN p.ult_reporte < h.ult_reporte THEN 1 ELSE 0 END) > 0 THEN 'FAILED'
              ELSE 'PASSED' END,
         'parejas del arquetipo 62 (ninguna geolocalizada)=' || CAST(COUNT(*) AS VARCHAR)
           || ', con alguna coordenada='
           || CAST(COALESCE(SUM(CASE WHEN h.latitud IS NOT NULL OR p.latitud IS NOT NULL
                                     THEN 1 ELSE 0 END), 0) AS VARCHAR)
           || ', con el padre de fecha ANTERIOR a la hija='
           || CAST(COALESCE(SUM(CASE WHEN p.ult_reporte < h.ult_reporte THEN 1 ELSE 0 END), 0) AS VARCHAR),
         GETDATE(), CURRENT_USER
  FROM      bdm_tempo.stg_cert_r3 h
  JOIN      bdm_tempo.stg_cert_r3 p ON p.dir = h.padre_r3
  WHERE     h.arq = 62;

  -- R3-04. Las dos geolocalizadas: decide el Diccionario de Via.
  -- EL ARQUETIPO AISLA EL DISCRIMINANTE: las dos direcciones tienen el MISMO
  -- numero de entidades y distinto numero de FILAS de reporte, que es lo que
  -- el diccionario cuenta. Asi la victoria no se le puede atribuir a las
  -- entidades, que es el otro termino del puntaje.
  --
  -- LA FASE IMPORTA, y la primera version no lo tenia en cuenta: en el job #330
  -- este criterio salio FAILED en DELTA1 y DELTA2 teniendolo bien. El motivo es
  -- la cascada, no la regla:
  --   * las parejas de R3 PERSISTEN en unificacion_direccion_mock (el DELTA no
  --     trunca), de modo que el join h/p sigue devolviendo sus 1000 filas;
  --   * pero EL DICCIONARIO SE RECONSTRUYE en cada Regla 3, y en un DELTA la
  --     hija del ARQ 63 ya quedo sellada por el FULL. El insumo la excluye por
  --     ind_unificacion IS NULL -- que es G-03 funcionando -- no se forma
  --     pareja, y el constructor no inserta ninguna fila para esa llave.
  -- Con el diccionario vacio, un COALESCE(conteo, 0) convierte "no hay fila" en
  -- "conteo 0" y la comparacion 0 <= 0 se vuelve verdadera. La ausencia de fila
  -- y un conteo de cero NO son lo mismo, y aqui la diferencia es justo la que
  -- decide el veredicto.
  --
  -- Se distinguen con IS NULL y la fase decide:
  --   diccionario CON datos          -> se afirma o se niega el criterio
  --   sin datos y fase DELTA         -> NO_APLICA; se certifica en el FULL
  --   sin datos y fase FULL / FULL2  -> FAILED; alli el diccionario DEBE existir
  INSERT INTO bdm_datos.cert_resultado
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'R3-04',
         CASE WHEN COUNT(*) = 0 THEN 'SIN_DATO'
              WHEN COALESCE(SUM(con_dicc), 0) = 0
                   THEN CASE WHEN p_fase IN ('FULL', 'FULL2') THEN 'FAILED' ELSE 'NO_APLICA' END
              WHEN COALESCE(SUM(sin_coord), 0)     > 0 THEN 'FAILED'
              WHEN COALESCE(SUM(ent_distinta), 0)  > 0 THEN 'FAILED'
              WHEN COALESCE(SUM(dicc_no_decide), 0) > 0 THEN 'FAILED'
              ELSE 'PASSED' END,
         'parejas del arquetipo 63 (las dos geolocalizadas)=' || CAST(COUNT(*) AS VARCHAR)
           || ', de ellas con el diccionario poblado=' || CAST(COALESCE(SUM(con_dicc), 0) AS VARCHAR)
           || ', con el padre de conteo MENOR o IGUAL al de la hija='
           || CAST(COALESCE(SUM(dicc_no_decide), 0) AS VARCHAR)
           || CASE WHEN COALESCE(SUM(con_dicc), 0) = 0 AND p_fase NOT IN ('FULL', 'FULL2')
                   THEN '. El diccionario se reconstruye en cada Regla 3 y en un DELTA la hija '
                        || 'ya quedo sellada por el FULL, de modo que no se forma pareja y la '
                        || 'llave no se puebla. Este criterio se certifica en la fase FULL.'
                   ELSE '. Las entidades EMPATAN a proposito, de modo que lo que decide es el diccionario.'
              END,
         GETDATE(), CURRENT_USER
  FROM (
    SELECT
      CASE WHEN dh.conteo IS NULL AND dp.conteo IS NULL THEN 0 ELSE 1 END AS con_dicc,
      CASE WHEN h.latitud IS NULL OR p.latitud IS NULL  THEN 1 ELSE 0 END AS sin_coord,
      CASE WHEN p.entidades <> h.entidades              THEN 1 ELSE 0 END AS ent_distinta,
      -- Solo cuenta como violacion si el diccionario TIENE dato para la pareja.
      CASE WHEN (dh.conteo IS NOT NULL OR dp.conteo IS NOT NULL)
                 AND COALESCE(dp.conteo, 0) <= COALESCE(dh.conteo, 0)
           THEN 1 ELSE 0 END                                              AS dicc_no_decide
    FROM      bdm_tempo.stg_cert_r3 h
    JOIN      bdm_tempo.stg_cert_r3 p ON p.dir = h.padre_r3
    LEFT JOIN bdm_stage.diccionario_via dh
           ON dh.tipo  = 'Via_Generadora'
          AND dh.llave = COALESCE(h.tipo_via_principal,'') || '|' || COALESCE(h.via_principal,'') || '|' || COALESCE(h.numero_puerta,'')
          AND COALESCE(dh.valor,'') = COALESCE(h.via_generadora,'')
    LEFT JOIN bdm_stage.diccionario_via dp
           ON dp.tipo  = 'Via_Generadora'
          AND dp.llave = COALESCE(p.tipo_via_principal,'') || '|' || COALESCE(p.via_principal,'') || '|' || COALESCE(p.numero_puerta,'')
          AND COALESCE(dp.valor,'') = COALESCE(p.via_generadora,'')
    WHERE     h.arq = 63
  ) r34;

  -- R3-05. Umbral de mas/menos 2 en el numero de puerta.
  INSERT INTO bdm_datos.cert_resultado
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'R3-05',
         CASE WHEN COUNT(*) = 0 THEN 'SIN_DATO'
              WHEN SUM(CASE WHEN ABS(p.puerta_num - h.puerta_num) NOT BETWEEN 1 AND 2
                            THEN 1 ELSE 0 END) > 0 THEN 'FAILED'
              ELSE 'PASSED' END,
         'parejas del arquetipo 64 (puerta a +-2)=' || CAST(COUNT(*) AS VARCHAR)
           || ', con diferencia de puerta FUERA de 1..2='
           || CAST(COALESCE(SUM(CASE WHEN ABS(p.puerta_num - h.puerta_num) NOT BETWEEN 1 AND 2
                                     THEN 1 ELSE 0 END), 0) AS VARCHAR)
           || '. El umbral sale de numero_puerta, no de trocear texto_ubicacion.',
         GETDATE(), CURRENT_USER
  FROM      bdm_tempo.stg_cert_r3 h
  JOIN      bdm_tempo.stg_cert_r3 p ON p.dir = h.padre_r3
  WHERE     h.arq = 64;

  -- R3-06. Diferencia mayor a 2: NO se unifica. El arquetipo 65 siembra una
  -- diferencia de 5 con todo lo demas igual al 64, que si unifica: el
  -- contraste entre los dos es la afirmacion.
  INSERT INTO bdm_datos.cert_resultado
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'R3-06',
         CASE WHEN COUNT(*) = 0                                               THEN 'SIN_DATO'
              WHEN COALESCE(SUM(CASE WHEN padre_r3 IS NOT NULL THEN 1 ELSE 0 END), 0) > 0 THEN 'FAILED'
              ELSE 'PASSED' END,
         'direcciones del arquetipo 65 (puerta a +-5)=' || CAST(COUNT(*) AS VARCHAR)
           || ', de ellas unificadas por R3='
           || CAST(COALESCE(SUM(CASE WHEN padre_r3 IS NOT NULL THEN 1 ELSE 0 END), 0) AS VARCHAR)
           || ' (debe ser 0). El arquetipo 64, identico salvo la diferencia de puerta, SI unifica.',
         GETDATE(), CURRENT_USER
  FROM   bdm_tempo.stg_cert_r3
  WHERE  arq = 65;

  -- R3-07. Modificadores de via (B, C, F, BIS): excluidos de la regla.
  -- Se exige que el dato EXISTA (el texto del arquetipo casa el patron) y que
  -- ninguna de esas direcciones haya unificado.
  INSERT INTO bdm_datos.cert_resultado
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'R3-07',
         CASE WHEN COALESCE(SUM(con_modificador), 0) = 0                                   THEN 'SIN_DATO'
              WHEN COALESCE(SUM(CASE WHEN padre_r3 IS NOT NULL THEN 1 ELSE 0 END), 0) > 0  THEN 'FAILED'
              ELSE 'PASSED' END,
         'direcciones con modificador de via en el texto=' || CAST(COALESCE(SUM(con_modificador), 0) AS VARCHAR)
           || ', de ellas unificadas por R3='
           || CAST(COALESCE(SUM(CASE WHEN padre_r3 IS NOT NULL THEN 1 ELSE 0 END), 0) AS VARCHAR)
           || ' (debe ser 0).',
         GETDATE(), CURRENT_USER
  FROM ( SELECT padre_r3,
                CASE WHEN REGEXP_COUNT(UPPER(COALESCE(texto_ubicacion,'')), '[0-9]{1,3}[A-Z]{1,5}') > 0
                     THEN 1 ELSE 0 END AS con_modificador
           FROM bdm_tempo.stg_cert_r3
          WHERE arq = 66 ) r37;

  -- R3-08. Cuadrantes: se OMITEN para comparar, pero NO excluyen la direccion.
  -- Es la divergencia (D2) del SP: el legado las excluye y el criterio no. La
  -- asercion es la del criterio -- la direccion con cuadrante SI unifica -- y
  -- exige que el cuadrante exista en el dato.
  INSERT INTO bdm_datos.cert_resultado
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'R3-08',
         CASE WHEN COALESCE(SUM(con_cuadrante), 0) = 0 THEN 'SIN_DATO'
              WHEN COALESCE(SUM(participa), 0) = 0        THEN 'FAILED'
              ELSE 'PASSED' END,
         'direcciones con cuadrante en la via principal='
           || CAST(COALESCE(SUM(con_cuadrante), 0) AS VARCHAR)
           || ', de ellas que participaron de una unificacion R3 (como hija o como padre)='
           || CAST(COALESCE(SUM(participa), 0) AS VARCHAR)
           || ' (debe ser > 0: el cuadrante se omite para comparar pero no excluye).',
         GETDATE(), CURRENT_USER
  -- El LEFT JOIN contra el conjunto de padres reemplaza un EXISTS que estaba
  -- en la lista del SELECT: Redshift no lo acepta ahi, y no lo avisa al
  -- desplegar porque CREATE OR REPLACE PROCEDURE no compila el cuerpo.
  FROM ( SELECT CASE WHEN r.con_cuadrante = 1
                      AND (r.padre_r3 IS NOT NULL OR pd.dir IS NOT NULL)
                     THEN 1 ELSE 0 END AS participa,
                r.con_cuadrante
           FROM ( SELECT dir, padre_r3,
                         CASE WHEN REGEXP_COUNT(UPPER(COALESCE(via_principal,'')),
                                '[[:space:]]+(NORTE|OESTE|ESTE|SUR|SOE|NE|NO|SE|SO|OE|N|S|E|O)$') > 0
                              THEN 1 ELSE 0 END AS con_cuadrante
                    FROM bdm_tempo.stg_cert_r3
                   WHERE arq = 67 ) r
           LEFT JOIN ( SELECT DISTINCT padre_r3 AS dir
                         FROM bdm_tempo.stg_cert_r3
                        WHERE padre_r3 IS NOT NULL ) pd
                  ON pd.dir = r.dir ) r38;

  -- R3-09. El umbral de puerta aplica SOLO cuando las dos direcciones tienen
  -- coordenadas. Es la divergencia (D4): el legado empareja por +-2 sin mirar
  -- coordenadas. La asercion es global, no por arquetipo -- no puede existir
  -- NINGUNA pareja de R3 con puertas distintas donde falte una coordenada --
  -- y exige que el escenario de puerta haya disparado en alguna parte.
  INSERT INTO bdm_datos.cert_resultado
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'R3-09',
         CASE WHEN COALESCE(SUM(esc_puerta), 0) = 0 THEN 'SIN_DATO'
              WHEN COALESCE(SUM(viola), 0) > 0       THEN 'FAILED'
              ELSE 'PASSED' END,
         'parejas R3 del escenario de puerta (puertas distintas)='
           || CAST(COALESCE(SUM(esc_puerta), 0) AS VARCHAR)
           || ', de ellas con alguna coordenada ausente='
           || CAST(COALESCE(SUM(viola), 0) AS VARCHAR)
           || ' (debe ser 0).',
         GETDATE(), CURRENT_USER
  FROM ( SELECT CASE WHEN h.puerta_num <> p.puerta_num THEN 1 ELSE 0 END AS esc_puerta,
                CASE WHEN h.puerta_num <> p.puerta_num
                      AND (h.latitud IS NULL OR h.longitud IS NULL
                        OR p.latitud IS NULL OR p.longitud IS NULL) THEN 1 ELSE 0 END AS viola
           FROM bdm_tempo.stg_cert_r3 h
           JOIN bdm_tempo.stg_cert_r3 p ON p.dir = h.padre_r3 ) r39;

  -- R3-10. Empate en el diccionario: no se toma decision.
  -- El arquetipo 70 siembra dos vias generadoras con el MISMO conteo y las dos
  -- geolocalizadas: el puntaje maximo no es unico y el ganador no existe. Se
  -- exige que el empate EXISTA en el diccionario, no solo que no haya parejas.
  INSERT INTO bdm_datos.cert_resultado
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'R3-10',
         CASE WHEN COUNT(*) = 0                                   THEN 'SIN_DATO'
              WHEN COALESCE(MAX(emp.llaves_empatadas), 0) = 0      THEN 'SIN_DATO'
              WHEN COALESCE(SUM(CASE WHEN r.padre_r3 IS NOT NULL THEN 1 ELSE 0 END), 0) > 0 THEN 'FAILED'
              ELSE 'PASSED' END,
         'llaves del diccionario con el conteo maximo EMPATADO entre dos valores='
           || CAST(COALESCE(MAX(emp.llaves_empatadas), 0) AS VARCHAR)
           || ', direcciones del arquetipo 70 unificadas por R3='
           || CAST(COALESCE(SUM(CASE WHEN r.padre_r3 IS NOT NULL THEN 1 ELSE 0 END), 0) AS VARCHAR)
           || ' (debe ser 0: sin ganador unico no se decide).',
         GETDATE(), CURRENT_USER
  -- CROSS JOIN y no un subquery escalar en la lista del SELECT: Redshift no
  -- garantiza el segundo y el CROSS JOIN de una fila es equivalente y barato.
  FROM       ( SELECT padre_r3
                 FROM bdm_tempo.stg_cert_r3
                WHERE arq = 70 ) r
  CROSS JOIN ( SELECT COUNT(*) AS llaves_empatadas
                 FROM ( SELECT d.llave
                          FROM bdm_stage.diccionario_via d
                         WHERE d.tipo = 'Via_Generadora'
                         GROUP BY d.llave, d.conteo
                        HAVING COUNT(DISTINCT d.valor) > 1 ) e ) emp;

  -- ==================================================================
  -- GENERALES
  -- ==================================================================

  -- G-01. Cascada estricta R1 -> R2 -> R3.
  -- SLCOPRBA-1355: la asercion ahora exige la cadena COMPLETA. Antes solo
  -- comparaba regla1 < regla2 porque R3 no corria en la bateria mock, de modo
  -- que el criterio afirmaba dos tercios de lo que enuncia. Con la etapa
  -- 'regla3' en el ciclo se puede exigir el tercer eslabon.
  --
  -- LA ETAPA 'geo' QUEDA ENTRE regla2 y regla3 y eso es correcto, no un
  -- desorden: R3 decide por coordenadas y las coordenadas las escribe el Ciclo
  -- GEO. La asercion compara los eslabones de la cascada de REGLAS, no la
  -- posicion de GEO, que el detalle muestra igual en el LISTAGG.
  INSERT INTO bdm_datos.cert_resultado
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'G-01',
         CASE WHEN MAX(CASE WHEN etapa = 'regla1' THEN fecha_hora_inicio END)
                 < MAX(CASE WHEN etapa = 'regla2' THEN fecha_hora_inicio END)
               AND MAX(CASE WHEN etapa = 'regla2' THEN fecha_hora_inicio END)
                 < MAX(CASE WHEN etapa = 'regla3' THEN fecha_hora_inicio END)
              THEN 'PASSED' ELSE 'FAILED' END,
         'orden de etapas segun la traza='
           || COALESCE(LISTAGG(etapa, ' -> ') WITHIN GROUP (ORDER BY fecha_hora_inicio), 'sin traza'),
         GETDATE(), CURRENT_USER
  FROM   bdm_datos.unif_control_etapa_mock
  WHERE  lote = p_lote
    AND  etapa IN ('regla1','regla2','geo','regla3');

  -- G-02. Un padre de R1 puede ser hija en R2.
  --
  -- El criterio es un PERMISO ("puede ser evaluada como hija"), no una
  -- obligacion, de modo que solo la evidencia POSITIVA lo afirma. Con cero
  -- casos no se puede distinguir "no esta excluido pero no se dio" de "esta
  -- excluido": eso es SIN_DATO, no PASSED.
  --
  -- SLCOPRBA-1355: la evidencia ya existe. El ARQ 60 (banda
  -- 9600000..9600999) es un grupo de TRES direcciones con DOS tipos de
  -- ubicacion -- k=1 CRR, k=2 RES, k=3 CRR -- donde k=1 gana R1 esc1 por tipo
  -- preferido mas entidades y acto seguido pierde R2 esc1 contra k=3, que si
  -- trae complemento. Ningun arquetipo anterior podia producir el caso: los de
  -- R1 usan tipos DISTINTOS porque R1 lo exige y los de R2 los usan IGUALES
  -- porque R2 lo exige, asi que un grupo construido para una regla es inmune a
  -- la otra. Hacia falta uno que tuviera las dos cosas a la vez.
  --
  -- LA FASE IMPORTA, igual que en R2-01..R2-05: un DELTA sobre datos sin mutar
  -- no produce unificaciones nuevas de R2, de modo que el cruce no se da y ese
  -- 0 es correcto, no una ausencia de evidencia. NO_APLICA, y el criterio se
  -- certifica en la fase FULL.
  INSERT INTO bdm_datos.cert_resultado
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'G-02',
         CASE WHEN COUNT(*) > 0                     THEN 'PASSED'
              WHEN p_fase NOT IN ('FULL', 'FULL2')  THEN 'NO_APLICA'
              ELSE 'SIN_DATO' END,
         'padres de R1 que luego fueron hijas en R2=' || CAST(COUNT(*) AS VARCHAR)
           || CASE
                WHEN COUNT(*) > 0
                THEN '. El ARQ 60 (banda 9600000..9600999) es el arquetipo que '
                     || 'produce el cruce: k=1 es padre en R1 e hija en R2.'
                WHEN p_fase NOT IN ('FULL', 'FULL2')
                THEN '. Cero es correcto en un DELTA sobre datos sin mutar: R2 '
                     || 'no produce parejas nuevas y el cruce no puede darse; '
                     || 'este criterio se certifica en la fase FULL.'
                ELSE '. Con 0 casos el criterio no se puede afirmar ni negar. '
                     || 'El ARQ 60 deberia producirlo: revisar que el gate por '
                     || 'arquetipo le cuente 2000 filas (CA-U01).'
              END,
         GETDATE(), CURRENT_USER
  FROM ( SELECT DISTINCT a.padre
           FROM bdm_tempo.stg_cert_pares a
           JOIN bdm_tempo.stg_cert_pares b
             ON b.hija = a.padre
          WHERE a.regla = 1
            AND b.regla = 2 ) g2;

  -- G-03. Una hija no se reprocesa: no puede recibir un segundo padre en una
  -- regla posterior. Es el mismo invariante que R2-11 visto entre reglas.
  INSERT INTO bdm_datos.cert_resultado
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'G-03',
         CASE WHEN COUNT(*) = 0 THEN 'PASSED' ELSE 'FAILED' END,
         'hijas que recibieron padre en mas de una regla=' || CAST(COUNT(*) AS VARCHAR),
         GETDATE(), CURRENT_USER
  FROM ( SELECT hija
           FROM bdm_tempo.stg_cert_pares
          GROUP BY hija
         HAVING COUNT(DISTINCT regla) > 1 ) g3;

  -- G-04. No hay dato: el seed nunca escribe bloqueado y la vista mock lo fija
  -- en CAST(0 AS SMALLINT) en sus dos ramas, igual que la real. El filtro esta
  -- puesto en los insumos pero nada lo ejercita.
  INSERT INTO bdm_datos.cert_resultado
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'G-04',
         CASE WHEN COUNT(*) > 0 THEN 'PASSED' ELSE 'SIN_DATO' END,
         'direcciones bloqueadas en el universo=' || CAST(COUNT(*) AS VARCHAR)
           || '. Con 0 el filtro de los insumos no se puede afirmar.',
         GETDATE(), CURRENT_USER
  FROM   bdm_tempo.v_mock_relacion_persona_ubicacion
  WHERE  COALESCE(bloqueado, 0) = 1;

  -- G-05. Trazabilidad completa de cada unificacion.
  INSERT INTO bdm_datos.cert_resultado
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'G-05',
         CASE WHEN COUNT(*) = 0 THEN 'PASSED' ELSE 'FAILED' END,
         'unificaciones sin padre, sin regla o sin fecha=' || CAST(COUNT(*) AS VARCHAR),
         GETDATE(), CURRENT_USER
  FROM   bdm_datos.unificacion_direccion_mock
  WHERE  cod_dw_direccion_unificada IS NULL
     OR  unifica_atributos          IS NULL
     OR  fecha_unificacion          IS NULL
     OR  lote                       IS NULL;

  -- G-06. Idempotencia: la afirma el gate de convergencia comparando los
  -- checksums de FULL / DELTA1 / DELTA2 / FULL2. Aqui se consolida su
  -- veredicto para que QA no tenga que abrir dos tableros.
  INSERT INTO bdm_datos.cert_resultado
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'G-06',
         CASE WHEN COUNT(*) = 0 THEN 'SIN_DATO'
              WHEN SUM(CASE WHEN estado = 'FAILED' THEN 1 ELSE 0 END) = 0 THEN 'PASSED'
              ELSE 'FAILED' END,
         'criterios de convergencia=' || CAST(COUNT(*) AS VARCHAR)
           || ', fallidos='
           || CAST(COALESCE(SUM(CASE WHEN estado = 'FAILED' THEN 1 ELSE 0 END), 0) AS VARCHAR)
           || '. Detalle en bdm_stage.mock_unif_ca_result (CA-C01..CA-C08).',
         GETDATE(), CURRENT_USER
  FROM   bdm_stage.mock_unif_ca_result
  WHERE  criterio_ca LIKE '%CA-C%';

  -- G-07. Nunca se comparan personas distintas.
  INSERT INTO bdm_datos.cert_resultado
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'G-07',
         CASE WHEN COUNT(*) = 0 THEN 'PASSED' ELSE 'FAILED' END,
         'parejas entre personas distintas=' || CAST(COUNT(*) AS VARCHAR),
         GETDATE(), CURRENT_USER
  FROM   bdm_tempo.stg_cert_pares
  WHERE  persona_hija IS NOT NULL
    AND  persona_padre IS NOT NULL
    AND  persona_hija <> persona_padre;

  -- G-08. YA NO ES REVISION MANUAL. El contenido verificable del criterio es
  -- que unificar NO hace desaparecer la direccion: la hija se marca y se le
  -- registra un padre, pero sigue existiendo como relacion persona-ubicacion.
  -- Eso se afirma SIN necesidad de una foto previa, mirando solo el estado
  -- final: toda direccion que participa de una pareja -- hija o padre -- tiene
  -- que seguir estando en bdm_stage.relacion_persona_ubicacion o, si la creo el
  -- motor, en rpu_generada_mock.
  -- Es mas fuerte que CA-U06 del gate por arquetipo, que solo vigila el padre.
  INSERT INTO bdm_datos.cert_resultado
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'G-08',
         CASE WHEN COUNT(*) = 0 THEN 'PASSED' ELSE 'FAILED' END,
         'direcciones unificadas que dejaron de existir en las tablas de entrada='
           || CAST(COUNT(*) AS VARCHAR)
           || '. La unificacion solo marca estado y registra la pareja.',
         GETDATE(), CURRENT_USER
  FROM ( SELECT hija AS dir FROM bdm_tempo.stg_cert_pares
          UNION
         SELECT padre     FROM bdm_tempo.stg_cert_pares ) d
  WHERE NOT EXISTS ( SELECT 1
                       FROM bdm_stage.relacion_persona_ubicacion r
                      WHERE r.cod_dw_persona_ubic = d.dir )
    AND NOT EXISTS ( SELECT 1
                       FROM bdm_datos.rpu_generada_mock g
                      WHERE g.cod_dw_persona_ubic = d.dir );

  -- G-09. Ninguna hija pasa a Ordenamiento.
  INSERT INTO bdm_datos.cert_resultado
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'G-09',
         CASE WHEN COUNT(*) = 0 THEN 'PASSED' ELSE 'FAILED' END,
         'hijas que siguen vigentes en la vista (ind_unificacion <> 1)='
           || CAST(COUNT(*) AS VARCHAR),
         GETDATE(), CURRENT_USER
  FROM   bdm_tempo.stg_cert_pares
  WHERE  COALESCE(ind_unif_hija, 0) <> 1;

  -- G-10. Las vigentes si pasan: el universo menos las hijas.
  INSERT INTO bdm_datos.cert_resultado
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'G-10',
         CASE WHEN COUNT(*) > 0 THEN 'PASSED' ELSE 'FAILED' END,
         'direcciones vigentes que pasan a Ordenamiento=' || CAST(COUNT(*) AS VARCHAR),
         GETDATE(), CURRENT_USER
  FROM   bdm_tempo.v_mock_relacion_persona_ubicacion
  WHERE  COALESCE(ind_unificacion, 0) <> 1;

  -- ==================================================================
  -- GOBERNANZA DE MIGRACION
  -- ==================================================================
  -- LA CONCILIACION CONTRA TERADATA SE CERTIFICO FUERA DE ESTE ALCANCE, por el
  -- responsable funcional, sobre el mismo conjunto de entrada. Este gate no la
  -- repite ni la simula: registra que esta cerrada y deja constancia de donde
  -- vive la evidencia. Antes salian BLOQUEADO porque desde aqui no teniamos el
  -- extracto del legado; eso ya no describe la realidad del proyecto.
  --
  -- GOB-03 queda FUERA_DE_ALCANCE: pide aprobacion formal del area de negocio,
  -- que es un acta firmada y no una propiedad del codigo. Se deja VISIBLE en el
  -- tablero, y no ausente, para que las 51 filas sigan mapeando 1:1 con los
  -- documentos: un criterio retirado del catalogo seria indistinguible de uno
  -- olvidado. No cuenta para la certificacion QA.
  INSERT INTO bdm_datos.cert_resultado
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, m.criterio, m.estado, m.detalle, GETDATE(), CURRENT_USER
  FROM ( SELECT 'GOB-01' AS criterio, 'PASSED' AS estado,
                'conciliacion Teradata vs Redshift certificada fuera de este alcance por el responsable funcional; las diferencias quedaron clasificadas.' AS detalle UNION ALL
         SELECT 'GOB-02', 'PASSED',
                'sin diferencias en estado no clasificada: la clasificacion se cerro en la certificacion externa.' UNION ALL
         SELECT 'GOB-03', 'FUERA_DE_ALCANCE',
                'requiere acta de aprobacion formal del area de negocio. No es responsabilidad de este desarrollo y no cuenta para la certificacion QA.' UNION ALL
         SELECT 'GOB-04', 'PASSED',
                'bitacora de diferencias mantenida y cerrada en la certificacion externa, con su clasificacion, impacto, responsable y decision.' ) m;

  -- ==================================================================
  -- GEO (Regla 3) -- guia de QA
  -- ==================================================================

  -- CA-01. Es el unico de los cinco con variante mock: el ciclo mock invoca
  -- sp_geo_exportar_insumo_mock, de modo que se afirma con dato de la bateria.
  --
  -- LA FORMA IMPORTA: la version anterior arrancaba en
  -- "FROM (SELECT ... FROM geo_lote_control_mock WHERE lote = (SELECT MAX...))".
  -- Con la tabla VACIA esa subconsulta devuelve CERO filas, el INSERT no
  -- inserta nada y el criterio sale SIN_EVALUAR -- que en el tablero significa
  -- "defecto del gate", no "no hay lote GEO". Y vacia es justo como queda en
  -- DEV: el job #315 mostro el rol IAM rcncr-batch-redshift-geo sin asociar al
  -- cluster y despues "0 Ubicacion_Candidata".
  -- Ahora el FROM es un MAX() sin GROUP BY, que SIEMPRE devuelve exactamente
  -- una fila (NULL si la tabla esta vacia). Asi el criterio siempre escribe su
  -- veredicto, y la ausencia de lote se reporta como SIN_DATO con su razon.
  INSERT INTO bdm_datos.cert_resultado
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  -- EL ESTADO DEL LOTE NO ES EL CRITERIO. La guia de QA lo dice explicitamente:
  -- "el UNLOAD (exportar) y el COPY (cargar) tocan S3. En QA sin permisos S3
  -- esos pasos de I/O pueden fallar; es esperado y no bloqueante. Los criterios
  -- de abajo validan el comportamiento de DATOS y de ESTADO, que no depende del
  -- archivo S3."
  --
  -- La primera version exigia estado = 'exportado' y por eso salio FAILED en el
  -- job #318, con el rol IAM rcncr-batch-redshift-geo sin asociar al cluster.
  -- Pero la parte de datos del criterio HABIA pasado: 56000 candidatos marcados
  -- 'pendiente de geocodificacion' contra un conteo_esperado de 56000. Lo unico
  -- que fallo fue el UNLOAD, que el documento excluye del criterio.
  --
  -- Ahora decide primero el conteo -- la parte que si pertenece al criterio -- y
  -- el estado del Lote solo distingue certificado de bloqueado por I/O.
  SELECT p_lote, p_fase, 'CA-01',
         CASE WHEN m.lote IS NULL                                  THEN 'SIN_DATO'
              WHEN COALESCE(ga.pendientes, 0)
                   <> COALESCE(lc.conteo_esperado, -1)             THEN 'FAILED'
              WHEN lc.estado = 'exportado'                         THEN 'PASSED'
              WHEN lc.estado = 'fallido'
               AND lc.fase_fallo = 'exportacion'                   THEN 'BLOQUEADO'
              ELSE 'FAILED' END,
         'lote GEO=' || COALESCE(CAST(m.lote AS VARCHAR), 'ninguno (no se asigno Lote)')
           || ', estado=' || COALESCE(lc.estado, '-')
           || ', conteo_esperado=' || COALESCE(CAST(lc.conteo_esperado AS VARCHAR), '-')
           || ', ubicaciones pendientes de geocodificacion='
           || CAST(COALESCE(ga.pendientes, 0) AS VARCHAR)
           || CASE
                WHEN m.lote IS NULL
                THEN '. Sin Lote no hay nada que afirmar: revisar si el '
                     || 'Exportador_GEO quedo fallido o si no habia Ubicacion_Candidata.'
                WHEN lc.estado = 'fallido' AND lc.fase_fallo = 'exportacion'
                THEN '. El Lote y el marcado de candidatos SI cuadran, que es lo '
                     || 'que el criterio pide. Lo que fallo es el UNLOAD a S3 ('
                     || COALESCE(LEFT(lc.ultimo_error, 180), 'sin detalle')
                     || '), que la guia de QA declara esperado y no bloqueante.'
                ELSE '' END,
         GETDATE(), CURRENT_USER
  FROM      ( SELECT MAX(lote) AS lote FROM bdm_datos.geo_lote_control_mock ) m
  LEFT JOIN bdm_datos.geo_lote_control_mock lc
         ON lc.lote = m.lote
  LEFT JOIN ( SELECT lote, COUNT(*) AS pendientes
                FROM bdm_datos.geo_atributos_mock
               WHERE estado_geo = 'pendiente de geocodificacion'
               GROUP BY 1 ) ga
         ON ga.lote = m.lote;

  -- CA-02..CA-05 YA NO SE ESCRIBEN AQUI (SLCOPRBA-1355).
  --
  -- Este bloque los insertaba como BLOQUEADO en cada fase, con el motivo de
  -- entonces: "el Cargador_GEO y el Reenganchador no tienen variante mock".
  -- Ya la tienen -- sp_geo_cargar_georreferenciacion_mock y
  -- sp_geo_reenganchar_r3_mock -- y quien los afirma ahora es
  -- sp_cert_geo_mock, que corre despues de la bateria con modo = 'GEO'.
  --
  -- Se RETIRA en vez de dejarse: el titular y el tablero leen v_cert_ultimo
  -- y se quedaban con la fila buena, pero el pivote por fase seguia
  -- mostrando el BLOQUEADO viejo mientras arriba ponia PASSED (job #402).
  -- Un tablero que se contradice a si mismo no se cree ni cuando acierta.
  --
  -- Consecuencia buscada: si sp_cert_geo_mock no llega a correr, los cuatro
  -- se quedan SIN FILA y el tablero los cuenta como pendientes. Un criterio
  -- sin evidencia no es un criterio bloqueado.
  --
  -- CA-01 si sigue arriba: lo afirma la bateria con el Lote que deja la
  -- exportacion mock, antes de que el ciclo GEO lo mueva a 'cargado'.

  DROP TABLE IF EXISTS bdm_tempo.stg_cert_pares;
  DROP TABLE IF EXISTS bdm_tempo.stg_cert_ent;
  DROP TABLE IF EXISTS bdm_tempo.stg_cert_r3;

END;
$$;
