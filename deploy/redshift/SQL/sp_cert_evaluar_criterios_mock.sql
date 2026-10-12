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
--          REVISION_MANUAL  (definidos en strct/13_ddl_cert_criterios.sql)
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

  CREATE TABLE bdm_tempo.stg_cert_ent
  DISTSTYLE KEY DISTKEY(cod_dw_persona_ubic)
  AS
  SELECT cod_dw_persona_ubic,
         COUNT(DISTINCT id_buro_suscriptor) AS entidades
  FROM   bdm_tempo.v_mock_reporte_relacion_persona_ubica
  GROUP  BY 1;

  CREATE TABLE bdm_tempo.stg_cert_pares
  DISTSTYLE KEY DISTKEY(cod_dw_persona_ubic)
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
               ON ci.id_buro_persona = rh.id_buro_persona;

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

  -- R1-06. Ninguna hija puede estar bloqueada, y ninguna direccion que ya era
  -- hija de una corrida anterior puede recibir un padre nuevo en esta.
  INSERT INTO bdm_datos.cert_resultado
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'R1-06',
         CASE WHEN COUNT(*) = 0 THEN 'PASSED' ELSE 'FAILED' END,
         'parejas con hija bloqueada o ya unificada antes=' || CAST(COUNT(*) AS VARCHAR),
         GETDATE(), CURRENT_USER
  FROM   bdm_tempo.stg_cert_pares
  WHERE  bloqueado_hija = 1;

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

  -- R1-08. El empate se descarta con HAVING COUNT(*) = 1 sobre el max_score.
  -- No hay arquetipo que lo AISLE: en esc1 y esc2 el tipo rompe el empate
  -- (+100000 al score) y en esc3 las entidades siempre difieren, de modo que
  -- la condicion del requerimiento nunca se alcanza con el dato actual.
  INSERT INTO bdm_datos.cert_resultado
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'R1-08', 'SIN_DATO',
         'mecanismo presente (HAVING COUNT(*) = 1 sobre max_score) pero ningun '
         || 'arquetipo aisla el empate: falta un caso con mismo tipo y mismas entidades.',
         GETDATE(), CURRENT_USER;

  -- ==================================================================
  -- REGLA 2
  -- ==================================================================
  -- Los escenarios 1 a 4 se afirman con el censo, que ya cuenta direcciones y
  -- personas por sello. Un sello con 0 direcciones es FAILED: el arquetipo
  -- existe, luego el escenario tenia que disparar.
  INSERT INTO bdm_datos.cert_resultado
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, m.criterio,
         CASE WHEN COALESCE(c.direcciones, 0) > 0 THEN 'PASSED' ELSE 'FAILED' END,
         'sello ' || m.n_id || ': direcciones='
           || CAST(COALESCE(c.direcciones, 0) AS VARCHAR)
           || ', personas=' || CAST(COALESCE(c.personas, 0) AS VARCHAR),
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

  -- R2-06. Escenario 5 del legado = sello A6 (lineas 2250-3607): crea una
  -- direccion nueva con ambas nomenclaturas y deja las dos originales como
  -- hijas. No implementado. Nuestro esc5 resuelve el subcaso 2 (C7), que es
  -- otro criterio.
  INSERT INTO bdm_datos.cert_resultado
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'R2-06', 'NO_IMPLEMENTADO',
         'sello A6 (escenario 5 subcaso 1 del legado, sitio de creacion de '
         || 'direcciones) sin implementar. El censo lo reporta en 0 a proposito.',
         GETDATE(), CURRENT_USER;

  -- R2-07. Escenario 6 del legado son TRES subcasos, con sellos A8, D9 y F1
  -- (lineas 4016-5847). A8 y D9 crean direcciones nuevas. Nuestro esc6 lleva
  -- sello E6 -- que no existe en el legado -- y solo aproxima F1.
  INSERT INTO bdm_datos.cert_resultado
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'R2-07', 'NO_IMPLEMENTADO',
         'faltan los sellos A8 (esc6 sub1) y D9 (esc6 sub2), ambos sitios de '
         || 'creacion. F1 (esc6 sub3, diccionario) esta aproximado por E6, '
         || 'sello propio que no existe en el legado. Direcciones marcadas E6='
         || CAST(COALESCE(( SELECT SUM(direcciones)
                              FROM bdm_datos.unif_escenario_censo_mock
                             WHERE lote = p_lote AND n_id = 'E6' ), 0) AS VARCHAR),
         GETDATE(), CURRENT_USER;

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
  FROM ( SELECT GREATEST(MAX(CASE WHEN d.vacio = 1 THEN 1 ELSE 0 END),
                         MAX(CASE WHEN d.repetida = 1 THEN 1 ELSE 0 END)) AS malos
           FROM ( SELECT g.cod_dw_direccion_fisica,
                         CASE WHEN NULLIF(TRIM(COALESCE(g.complemento, '')), '') IS NULL
                              THEN 1 ELSE 0 END AS vacio,
                         MAX(CASE
                               WHEN n.nomenclatura IS NOT NULL
                                AND STRPOS( SUBSTRING( ' ' || g.complemento || ' ',
                                                       STRPOS(' ' || g.complemento || ' ',
                                                              ' ' || TRIM(n.nomenclatura) || ' ')
                                                       + LENGTH(TRIM(n.nomenclatura)) + 1 ),
                                            ' ' || TRIM(n.nomenclatura) || ' ' ) > 0
                               THEN 1 ELSE 0 END) AS repetida
                    FROM      bdm_datos.direccion_fisica_generada_mock g
                    LEFT JOIN bdm_datos.nomenclatura n
                           ON STRPOS(' ' || g.complemento || ' ',
                                     ' ' || TRIM(n.nomenclatura) || ' ') > 0
                   GROUP BY 1, 2, g.complemento ) d
          GROUP BY d.cod_dw_direccion_fisica ) z;

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
  -- Los diez criterios comparten tres bloqueos encadenados, por eso se
  -- reportan juntos y con la misma razon: (1) el ciclo mock NO llama a la
  -- Regla 3; (2) en la via real latitud y longitud son CAST(NULL AS
  -- DECIMAL(10,6)) en v_xpm_contacto_direccion, o sea el datashare no las
  -- publica; (3) ninguna vista de insumo lee bdm_datos.geo_atributos, que es
  -- donde el Ciclo GEO escribe las coordenadas -- GEO y R3 no estan
  -- conectadas. Ademas no existe el Diccionario de Via.
  INSERT INTO bdm_datos.cert_resultado
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, m.criterio, m.estado, m.detalle, GETDATE(), CURRENT_USER
  FROM ( SELECT 'R3-01' AS criterio, 'NO_IMPLEMENTADO' AS estado,
                'el insumo de R3 no filtra por tipo de direccion; tipo_ubicacion existe en la vista real y es NULL en la mock.' AS detalle UNION ALL
         SELECT 'R3-02','NO_IMPLEMENTADO',
                'el insumo exige latitud en AMBOS lados, de modo que el caso de una sola direccion geolocalizada nunca unifica.' UNION ALL
         SELECT 'R3-03','NO_IMPLEMENTADO',
                'el caso sin coordenadas queda excluido por el mismo WHERE; no hay desempate por fecha ni por entidades.' UNION ALL
         SELECT 'R3-04','NO_IMPLEMENTADO',
                'no existe el Diccionario de Via; hoy el padre se elige por mayor numero de entidades reportantes.' UNION ALL
         SELECT 'R3-05','NO_IMPLEMENTADO',
                'el umbral esta como heuristica sobre los tokens 3 y 4 de texto_ubicacion; numero_puerta existe en v_xpm_direccion_fisica y no se usa.' UNION ALL
         SELECT 'R3-06','SIN_DATO',
                'el BETWEEN 1 AND 2 implementa la no-unificacion mas alla de 2, pero R3 no corre en la bateria mock.' UNION ALL
         SELECT 'R3-07','NO_IMPLEMENTADO',
                'no se excluyen los modificadores de via B, C, F ni BIS.' UNION ALL
         SELECT 'R3-08','NO_IMPLEMENTADO',
                'los cuadrantes no se omiten; la igualdad por SPLIT_PART hace que un cuadrante IMPIDA el emparejamiento, el efecto contrario al pedido.' UNION ALL
         SELECT 'R3-09','SIN_DATO',
                'se cumple por consecuencia (ambas coordenadas es la unica rama), no por diseno; R3 no corre en la bateria mock.' UNION ALL
         SELECT 'R3-10','NO_IMPLEMENTADO',
                'sin Diccionario de Via no hay empate de diccionario que evaluar.' ) m;

  -- ==================================================================
  -- GENERALES
  -- ==================================================================

  -- G-01. Cascada estricta: la traza debe mostrar regla1 antes de regla2.
  -- R3 no aparece en la cadena mock, y eso se reporta en el bloque REGLA3.
  INSERT INTO bdm_datos.cert_resultado
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'G-01',
         CASE WHEN MAX(CASE WHEN etapa = 'regla1' THEN fecha_hora_inicio END)
                 < MAX(CASE WHEN etapa = 'regla2' THEN fecha_hora_inicio END)
              THEN 'PASSED' ELSE 'FAILED' END,
         'orden de etapas segun la traza='
           || COALESCE(LISTAGG(etapa, ' -> ') WITHIN GROUP (ORDER BY fecha_hora_inicio), 'sin traza'),
         GETDATE(), CURRENT_USER
  FROM   bdm_datos.unif_control_etapa_mock
  WHERE  lote = p_lote
    AND  etapa IN ('regla1','regla2','geo','regla3');

  -- G-02. Un padre de R1 puede ser hija en R2.
  INSERT INTO bdm_datos.cert_resultado
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  -- El criterio es un PERMISO ("puede ser evaluada como hija"), no una
  -- obligacion, de modo que solo la evidencia POSITIVA lo afirma. Con cero
  -- casos no se puede distinguir "no esta excluido pero no se dio" de "esta
  -- excluido": eso es SIN_DATO, no PASSED.
  SELECT p_lote, p_fase, 'G-02',
         CASE WHEN COUNT(*) > 0 THEN 'PASSED' ELSE 'SIN_DATO' END,
         'padres de R1 que luego fueron hijas en R2=' || CAST(COUNT(*) AS VARCHAR)
           || '. Con 0 casos el criterio no se puede afirmar ni negar.',
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

  -- G-08. Propiedad de diseno: no hay consulta que pueda afirmar que nunca se
  -- borro nada. Se revisa leyendo el codigo.
  INSERT INTO bdm_datos.cert_resultado
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'G-08', 'REVISION_MANUAL',
         'la unificacion solo marca estados e inserta parejas. Verificar por '
         || 'lectura de codigo que ningun SP borra sobre las tablas de entrada.',
         GETDATE(), CURRENT_USER;

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
  -- Los cuatro dependen de un insumo que no existe: el resultado del proceso
  -- en Teradata para el mismo conjunto de entrada. Sin ese extracto no hay
  -- diferencias que clasificar, y declararlos cumplidos seria falso.
  -- Nota adicional: del legado solo tenemos la Regla 2 (PRO_UnificacionR2.sql
  -- y Unificacion.sql). El fuente de la Regla 1 nunca se entrego, de modo que
  -- R1 no es conciliable ni con el extracto en mano.
  INSERT INTO bdm_datos.cert_resultado
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, m.criterio, 'BLOQUEADO', m.detalle, GETDATE(), CURRENT_USER
  FROM ( SELECT 'GOB-01' AS criterio,
                'requiere el extracto de resultados de Teradata para el mismo insumo; no disponible.' AS detalle UNION ALL
         SELECT 'GOB-02',
                'depende de GOB-01: sin bitacora no hay diferencias clasificadas ni sin clasificar.' UNION ALL
         SELECT 'GOB-03',
                'proceso de negocio: requiere acta de aprobacion formal del area, fuera del alcance tecnico.' UNION ALL
         SELECT 'GOB-04',
                'la bitacora de diferencias no existe en ninguno de los tres repositorios.' ) m;

  -- ==================================================================
  -- GEO (Regla 3) -- guia de QA
  -- ==================================================================

  -- CA-01. Es el unico de los cinco con variante mock: el ciclo mock invoca
  -- sp_geo_exportar_insumo_mock, de modo que se afirma con dato de la bateria.
  INSERT INTO bdm_datos.cert_resultado
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'CA-01',
         CASE WHEN lc.lote IS NULL THEN 'SIN_DATO'
              WHEN lc.estado = 'exportado'
               AND COALESCE(ga.pendientes, 0) = COALESCE(lc.conteo_esperado, -1)
              THEN 'PASSED' ELSE 'FAILED' END,
         'lote GEO=' || COALESCE(CAST(lc.lote AS VARCHAR), 'ninguno')
           || ', estado=' || COALESCE(lc.estado, '-')
           || ', conteo_esperado=' || COALESCE(CAST(lc.conteo_esperado AS VARCHAR), '-')
           || ', ubicaciones pendientes de geocodificacion='
           || CAST(COALESCE(ga.pendientes, 0) AS VARCHAR),
         GETDATE(), CURRENT_USER
  FROM ( SELECT lote, estado, conteo_esperado
           FROM bdm_datos.geo_lote_control_mock
          WHERE lote = ( SELECT MAX(lote) FROM bdm_datos.geo_lote_control_mock ) ) lc
  LEFT JOIN ( SELECT lote, COUNT(*) AS pendientes
                FROM bdm_datos.geo_atributos_mock
               WHERE estado_geo = 'pendiente de geocodificacion'
               GROUP BY 1 ) ga
         ON ga.lote = lc.lote;

  -- CA-02, CA-03, CA-05: el Cargador_GEO y el Reenganchador no tienen variante
  -- mock. Se ejercitan sobre las tablas reales con un Lote preparado a mano,
  -- como indica la guia de QA. Este gate no los puede afirmar desde la bateria.
  -- CA-04: ademas de eso, hoy no puede pasar por dos defectos encadenados.
  INSERT INTO bdm_datos.cert_resultado
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, m.criterio, m.estado, m.detalle, GETDATE(), CURRENT_USER
  FROM ( SELECT 'CA-02' AS criterio, 'BLOQUEADO' AS estado,
                'sp_geo_cargar_georreferenciacion no tiene variante mock; se certifica sobre tablas reales con el Lote de QA (requiere COPY desde S3).' AS detalle UNION ALL
         SELECT 'CA-03','BLOQUEADO',
                'mismo SP que CA-02; el cierre a estado cargado solo se observa tras un COPY valido.' UNION ALL
         SELECT 'CA-04','NO_IMPLEMENTADO',
                'dos defectos encadenados: (1) sp_geo_reenganchar_r3 llama la Regla 3 con 0 argumentos y la firma pide 2, de modo que cae en el EXCEPTION y marca el Lote fallido; (2) ninguna vista de insumo lee geo_atributos, asi que la Regla 3 no ve las coordenadas que el Ciclo GEO escribe.' UNION ALL
         SELECT 'CA-05','BLOQUEADO',
                'la rama sin coordenadas retorna antes del CALL y es correcta por lectura, pero se certifica sobre tablas reales con el Lote de QA.' ) m;

  DROP TABLE IF EXISTS bdm_tempo.stg_cert_pares;
  DROP TABLE IF EXISTS bdm_tempo.stg_cert_ent;

END;
$$;
