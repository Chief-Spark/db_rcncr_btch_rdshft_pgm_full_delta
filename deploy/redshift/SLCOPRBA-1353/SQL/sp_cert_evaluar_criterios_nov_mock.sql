-- ============================================================
-- sp_cert_evaluar_criterios_nov_mock.sql
-- SLCOPRBA-1355: evaluador del tablero de certificacion de NOVEDADES.
-- Gemelo de sp_cert_evaluar_criterios_ord_mock.sql. UTF-8 sin BOM, sin acentos.
--
-- PRINCIPIO: un criterio que no se puede afirmar NO sale ausente ni sale
-- PASSED. Sale con el estado que le corresponde y con la razon exacta.
--
-- ALCANCE EVALUABLE: 22 de los 41.
--   NOV-UB-01..NOV-UB-15 menos NOV-UB-05  -> CONSULTA
--   NOV-UB-05                             -> SIN_DATO (la gestion de registro
--                                            no esta modelada en el mock)
--   NOV-UB-16..NOV-UB-22                  -> BLOQUEADO (catalogo o contrato
--                                            GEO que no se entrego)
--   los siete dominios no portados        -> NO_IMPLEMENTADO
--   NOV-AE-01..10 menos 06 y 07           -> CONSULTA
--   NOV-AE-06 y NOV-AE-07                 -> BLOQUEADO (catalogo que no se
--                                            entrego)
--   NOV-AG-01                             -> CONSULTA (mira el contrato, no
--                                            las filas)
--   NOV-AG-02..NOV-AG-08                  -> BLOQUEADO (el mismo catalogo,
--                                            que aqui vacia el dominio entero)
--   NOV-G-01..G-03                        -> REVISION_MANUAL
--
-- Y ESTE PROCEDIMIENTO ES AHORA UN GATE DE VERDAD: sp_cert_asercion_final
-- tiene rama 'NOVEDADES' desde el job DEV/DATABASE #409, de modo que un
-- FAILED que se escriba aqui tumba el build. Un criterio mal calibrado ya no
-- es ruido en un informe.
--
-- NOV-UB-13 Y NOV-UB-15 CAMBIARON DE SIGNO (SLCOPRBA-1355). Decian SIN_DATO
-- "porque el mock no siembra bajas", como si faltara un arquetipo. Era falso:
-- flag_op = 'E' es CODIGO MUERTO en el legado -- la etapa 1 anti-une
-- V_BLOQUEO (Novedad.sql:7590-7594) y la etapa 9 vuelve a unir la misma tabla
-- por la misma llave (:8393) --, y con el muere Severidad = 2, la unica via
-- de borrado del TPT (120.TPT:163). Ningun arquetipo los desbloquea. Ahora
-- exigen CERO bajas, que es la paridad real con el AS-IS.
--
-- EL UNIVERSO MOCK: info_basica (id_buro_persona) entre 9000000 y 9999999.
-- Los reales son FNV_HASH(pin), de 64 bits y tipicamente negativos: no
-- colisionan. El filtro por banda es lo que separa una via de la otra, igual
-- que en el evaluador del Ordenamiento.
--
-- SUM() SOBRE CERO FILAS DEVUELVE NULL, NO 0. Cada criterio guarda primero
-- con COUNT(*) = 0 -> SIN_DATO y envuelve despues en COALESCE. Sin eso, un
-- criterio vacio saldria PASSED, que es la peor forma de mentir.
--
-- NONATOMIC (leccion #13). Firma (VARCHAR, INTEGER): es un gate de la
-- bateria, no un orquestador, asi que NO lleva los 6 VARCHAR del
-- Framework Batch. Rollback: DROP PROCEDURE con firma exacta (#12/#14).
-- ============================================================

CREATE OR REPLACE PROCEDURE bdm_datos.sp_cert_evaluar_criterios_nov_mock(
    p_fase VARCHAR,   -- FULL | DELTA1 | DELTA2 | FULL2
    p_lote INTEGER
)
NONATOMIC
LANGUAGE plpgsql
AS $$
DECLARE
    -- Los dos conteos de columnas se leen del catalogo del motor, que vive en
    -- el leader node. Redshift NO admite mezclar un catalogo de sistema con un
    -- INSERT a una tabla de usuario en la misma sentencia ("Specified types or
    -- functions not supported on Redshift tables"). El patron que si funciona
    -- es leerlo a una variable y usar la variable -- igual que CA-T03 en el
    -- evaluador del Ordenamiento.
    v_cols_e9 INTEGER := 0;
    v_cols_e2 INTEGER := 0;
    -- Dominio ACTIVIDAD ECONOMICA: mismo patron, mismo motivo.
    v_cols_a1 INTEGER := 0;
    v_cols_am INTEGER := 0;
    -- Dominio UBICACION AGREGADA: igual. Es el unico criterio del dominio que
    -- se puede evaluar hoy, porque mira el contrato y no las filas.
    v_cols_ag INTEGER := 0;
    v_cols_agm INTEGER := 0;
BEGIN

  -- Idempotencia del propio gate. WHERE explicito [REDSHIFT:232].
  DELETE FROM bdm_datos.cert_resultado_nov
   WHERE lote = p_lote AND modo = p_fase;

  SELECT COUNT(*) INTO v_cols_e9
    FROM information_schema.columns
   WHERE table_schema = 'bdm_tempo' AND table_name = 'stg_nov_ubica_etapa_9_mock';

  SELECT COUNT(*) INTO v_cols_e2
    FROM information_schema.columns
   WHERE table_schema = 'bdm_tempo' AND table_name = 'stg_nov_ubica_etapa_2_mock';

  SELECT COUNT(*) INTO v_cols_a1
    FROM information_schema.columns
   WHERE table_schema = 'bdm_tempo' AND table_name = 'stg_nov_acteco_etapa_1_mock';

  SELECT COUNT(*) INTO v_cols_am
    FROM information_schema.columns
   WHERE table_schema = 'bdm_datos' AND table_name = 'mat_info_actividad_economica_mock';

  SELECT COUNT(*) INTO v_cols_ag
    FROM information_schema.columns
   WHERE table_schema = 'bdm_tempo' AND table_name = 'stg_nov_ubiagr_etapa_final_mock';

  SELECT COUNT(*) INTO v_cols_agm
    FROM information_schema.columns
   WHERE table_schema = 'bdm_datos' AND table_name = 'mat_ubicacion_agregada_mock';

  -- ------------------------------------------------------------
  -- Apoyo: la salida del dominio, acotada al universo mock.
  -- DISTSTYLE ALL: son decenas de miles de filas y varios criterios la
  -- cruzan contra si misma y contra la tabla final.
  -- ------------------------------------------------------------
  DROP TABLE IF EXISTS bdm_tempo.stg_cert_nov_cruce;
  DROP TABLE IF EXISTS bdm_tempo.stg_cert_nov_mat;
  DROP TABLE IF EXISTS bdm_tempo.stg_cert_nov_cruce;
  DROP TABLE IF EXISTS bdm_tempo.stg_cert_nov_mat;
  DROP TABLE IF EXISTS bdm_tempo.stg_cert_nov_base;
  CREATE TABLE bdm_tempo.stg_cert_nov_base
  DISTSTYLE ALL
  AS
  SELECT *
  FROM bdm_tempo.stg_nov_ubica_etapa_9_mock
  WHERE info_basica BETWEEN 9000000 AND 9999999;

  -- ---------- NOV-UB-01: las 42 columnas del contrato ----------
  INSERT INTO bdm_datos.cert_resultado_nov
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'NOV-UB-01',
         CASE WHEN v_cols_e9 = 42 THEN 'PASSED' ELSE 'FAILED' END,
         'columnas de stg_nov_ubica_etapa_9_mock=' || CAST(v_cols_e9 AS VARCHAR)
           || ', esperado 42 (contrato de 130.TPT:28-71 menos IN_Severidad). '
           || 'Cinco procedimientos de Novedades leen esta tabla: recortarla los deja sin enganche',
         GETDATE(), CURRENT_USER;

  -- ---------- NOV-UB-02: las 15 columnas de la etapa 2 ----------
  INSERT INTO bdm_datos.cert_resultado_nov
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'NOV-UB-02',
         CASE WHEN v_cols_e2 = 15 THEN 'PASSED' ELSE 'FAILED' END,
         'columnas de stg_nov_ubica_etapa_2_mock=' || CAST(v_cols_e2 AS VARCHAR)
           || ', esperado 15 (contrato de Novedad.sql:8625-8639). '
           || 'Es la unica entrada de Ubi_Agregada',
         GETDATE(), CURRENT_USER;

  -- ---------- NOV-UB-03: sin fan-out por id ----------
  -- El legado no lleva QUALIFY ni DISTINCT y tres de sus joins pueden abrir.
  -- Aqui se mide, no se supone.
  INSERT INTO bdm_datos.cert_resultado_nov
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'NOV-UB-03',
         CASE WHEN COUNT(*) = 0                        THEN 'SIN_DATO'
              WHEN COUNT(*) = COUNT(DISTINCT z.id)     THEN 'PASSED'
              ELSE 'FAILED' END,
         'filas=' || CAST(COUNT(*) AS VARCHAR)
           || ', ids distintos=' || CAST(COUNT(DISTINCT z.id) AS VARCHAR)
           || ', duplicadas=' || CAST(COUNT(*) - COUNT(DISTINCT z.id) AS VARCHAR),
         GETDATE(), CURRENT_USER
  FROM bdm_tempo.stg_cert_nov_base z;

  -- ---------- NOV-UB-04: universo base ----------
  INSERT INTO bdm_datos.cert_resultado_nov
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'NOV-UB-04',
         CASE WHEN COUNT(*) = 0 THEN 'SIN_DATO'
              WHEN COALESCE(SUM(CASE WHEN z.ind_unificacion = 1 THEN 1 ELSE 0 END), 0) > 0
                                 THEN 'FAILED'
              WHEN COALESCE(SUM(CASE WHEN z.orden IS NULL THEN 1 ELSE 0 END), 0) > 0
                                 THEN 'FAILED'
              ELSE 'PASSED' END,
         'filas=' || CAST(COUNT(*) AS VARCHAR)
           || ', ya unificadas (no deberia haber)='
           || CAST(COALESCE(SUM(CASE WHEN z.ind_unificacion = 1 THEN 1 ELSE 0 END), 0) AS VARCHAR)
           || ', sin orden de prioridad (no deberia haber)='
           || CAST(COALESCE(SUM(CASE WHEN z.orden IS NULL THEN 1 ELSE 0 END), 0) AS VARCHAR),
         GETDATE(), CURRENT_USER
  FROM bdm_tempo.stg_cert_nov_base z;

  -- ---------- NOV-UB-05: gestion VALIDA ----------
  -- El filtro existe en el port, pero el mock no modela el estado de gestion
  -- del registro: no hay dato con el que afirmarlo ni negarlo. SIN_DATO es el
  -- estado honesto; marcarlo PASSED seria afirmar algo que nada sostiene.
  INSERT INTO bdm_datos.cert_resultado_nov
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  VALUES (p_lote, p_fase, 'NOV-UB-05', 'SIN_DATO',
          'el INNER JOIN con la gestion de registro (Novedad.sql:7679) esta en el port, pero el mock no siembra estado de gestion: ninguna fila lo ejercita',
          GETDATE(), CURRENT_USER);

  -- ---------- NOV-UB-06: la columna DATO ----------
  INSERT INTO bdm_datos.cert_resultado_nov
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'NOV-UB-06',
         CASE WHEN COUNT(*) = 0 THEN 'SIN_DATO'
              WHEN COALESCE(SUM(CASE WHEN NULLIF(BTRIM(z.dato), '') IS NULL THEN 1 ELSE 0 END), 0) > 0
                                 THEN 'FAILED'
              ELSE 'PASSED' END,
         'filas=' || CAST(COUNT(*) AS VARCHAR)
           || ', con DATO vacio='
           || CAST(COALESCE(SUM(CASE WHEN NULLIF(BTRIM(z.dato), '') IS NULL THEN 1 ELSE 0 END), 0) AS VARCHAR)
           || '. En las geograficas DATO es texto mas complemento (Novedad.sql:7772)',
         GETDATE(), CURRENT_USER
  FROM bdm_tempo.stg_cert_nov_base z;

  -- ---------- NOV-UB-07: la columna CLASE ----------
  -- El universo mock de relacion_persona_ubicacion son SOLO direcciones: los
  -- telefonos, celulares y correos viven en contacto_canal, que es otra tabla
  -- y otro grano. Por eso se espera DIR en todas las filas, y las otras tres
  -- clases quedan sin ejercitar hasta que se traiga contacto_canal como filas
  -- adicionales. Esta escrito en el SP y aqui se mide.
  INSERT INTO bdm_datos.cert_resultado_nov
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'NOV-UB-07',
         CASE WHEN COUNT(*) = 0 THEN 'SIN_DATO'
              WHEN COALESCE(SUM(CASE WHEN z.clase NOT IN ('CEL','EMAIL','DIR','TEL') THEN 1 ELSE 0 END), 0) > 0
                                 THEN 'FAILED'
              ELSE 'PASSED' END,
         'filas=' || CAST(COUNT(*) AS VARCHAR)
           || ', DIR=' || CAST(COALESCE(SUM(CASE WHEN z.clase = 'DIR' THEN 1 ELSE 0 END), 0) AS VARCHAR)
           || ', TEL=' || CAST(COALESCE(SUM(CASE WHEN z.clase = 'TEL' THEN 1 ELSE 0 END), 0) AS VARCHAR)
           || ', CEL=' || CAST(COALESCE(SUM(CASE WHEN z.clase = 'CEL' THEN 1 ELSE 0 END), 0) AS VARCHAR)
           || ', EMAIL=' || CAST(COALESCE(SUM(CASE WHEN z.clase = 'EMAIL' THEN 1 ELSE 0 END), 0) AS VARCHAR)
           || ', fuera de dominio=' || CAST(COALESCE(SUM(CASE WHEN z.clase NOT IN ('CEL','EMAIL','DIR','TEL') THEN 1 ELSE 0 END), 0) AS VARCHAR)
           || '. En el mock solo hay direcciones: las otras tres clases esperan a contacto_canal',
         GETDATE(), CURRENT_USER
  FROM bdm_tempo.stg_cert_nov_base z;

  -- ---------- NOV-UB-08: las banderas de tipo ----------
  INSERT INTO bdm_datos.cert_resultado_nov
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'NOV-UB-08',
         CASE WHEN COUNT(*) = 0 THEN 'SIN_DATO'
              WHEN COALESCE(SUM(CASE WHEN z.es_tipo_crr NOT IN ('0','1')
                                       OR z.es_tipo_res NOT IN ('0','1')
                                       OR z.es_tipo_lab NOT IN ('0','1')
                                     THEN 1 ELSE 0 END), 0) > 0 THEN 'FAILED'
              WHEN COALESCE(SUM(CASE WHEN z.es_tipo_ppl IS NOT NULL
                                       OR z.es_tipo_agn IS NOT NULL
                                       OR z.es_tipo_suc IS NOT NULL
                                       OR z.es_tipo_est IS NOT NULL
                                       OR z.es_tipo_cdi IS NOT NULL
                                     THEN 1 ELSE 0 END), 0) > 0 THEN 'FAILED'
              ELSE 'PASSED' END,
         'RES=' || CAST(COALESCE(SUM(CASE WHEN z.es_tipo_res = '1' THEN 1 ELSE 0 END), 0) AS VARCHAR)
           || ', CRR=' || CAST(COALESCE(SUM(CASE WHEN z.es_tipo_crr = '1' THEN 1 ELSE 0 END), 0) AS VARCHAR)
           || ', LAB=' || CAST(COALESCE(SUM(CASE WHEN z.es_tipo_lab = '1' THEN 1 ELSE 0 END), 0) AS VARCHAR)
           || '. Las otras cinco banderas son NULL literal en el legado (Novedad.sql:8377-8381)',
         GETDATE(), CURRENT_USER
  FROM bdm_tempo.stg_cert_nov_base z;

  -- ---------- NOV-UB-09: las cinco columnas en blanco por esta ruta ----------
  INSERT INTO bdm_datos.cert_resultado_nov
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'NOV-UB-09',
         CASE WHEN COUNT(*) = 0 THEN 'SIN_DATO'
              WHEN COALESCE(SUM(CASE WHEN z.reportado_desde IS NOT NULL
                                       OR z.ultimo_reporte  IS NOT NULL
                                       OR z.fuente          IS NOT NULL
                                       OR z.numero_reportes  <> 0
                                       OR z.numero_entidades <> 0
                                     THEN 1 ELSE 0 END), 0) > 0 THEN 'FAILED'
              ELSE 'PASSED' END,
         'filas=' || CAST(COUNT(*) AS VARCHAR)
           || ', con alguno de los cinco campos poblado (el legado los emite como literales)='
           || CAST(COALESCE(SUM(CASE WHEN z.reportado_desde IS NOT NULL
                                       OR z.ultimo_reporte  IS NOT NULL
                                       OR z.fuente          IS NOT NULL
                                       OR z.numero_reportes  <> 0
                                       OR z.numero_entidades <> 0
                                     THEN 1 ELSE 0 END), 0) AS VARCHAR)
           || '. DECISION TOMADA (SLCOPRBA-1355): se reproduce el legado tal cual, no se pueblan. Los valores reales viven en la etapa 2 (Novedad.sql:8635-8639), que esta ruta no consume',
         GETDATE(), CURRENT_USER
  FROM bdm_tempo.stg_cert_nov_base z;

  -- ---------- NOV-UB-10: el orden viene del Ordenamiento ----------
  INSERT INTO bdm_datos.cert_resultado_nov
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'NOV-UB-10',
         CASE WHEN COUNT(*) = 0 THEN 'SIN_DATO'
              WHEN COALESCE(SUM(CASE WHEN z.orden <> o.orden_prioridad THEN 1 ELSE 0 END), 0) > 0
                                 THEN 'FAILED'
              ELSE 'PASSED' END,
         'filas cotejadas=' || CAST(COUNT(*) AS VARCHAR)
           || ', con orden distinto al de rpu_orden_prioridad='
           || CAST(COALESCE(SUM(CASE WHEN z.orden <> o.orden_prioridad THEN 1 ELSE 0 END), 0) AS VARCHAR),
         GETDATE(), CURRENT_USER
  FROM bdm_tempo.stg_cert_nov_base z
  JOIN ( SELECT cod_dw_persona_ubic, MIN(orden_prioridad) AS orden_prioridad
           FROM bdm_datos.rpu_orden_prioridad
          GROUP BY 1 ) o
    ON o.cod_dw_persona_ubic = z.id;

  -- ---------- NOV-UB-11: en FULL todo es alta ----------
  INSERT INTO bdm_datos.cert_resultado_nov
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'NOV-UB-11',
         CASE WHEN p_fase NOT IN ('FULL', 'FULL2') THEN 'NO_APLICA'
              WHEN COUNT(*) = 0 THEN 'SIN_DATO'
              WHEN COALESCE(SUM(CASE WHEN z.flag_op <> 'I' OR z.flag_op IS NULL THEN 1 ELSE 0 END), 0) > 0
                                 THEN 'FAILED'
              ELSE 'PASSED' END,
         'fase=' || p_fase || ', filas=' || CAST(COUNT(*) AS VARCHAR)
           || ', altas=' || CAST(COALESCE(SUM(CASE WHEN z.flag_op = 'I' THEN 1 ELSE 0 END), 0) AS VARCHAR)
           || ', no altas=' || CAST(COALESCE(SUM(CASE WHEN z.flag_op <> 'I' OR z.flag_op IS NULL THEN 1 ELSE 0 END), 0) AS VARCHAR),
         GETDATE(), CURRENT_USER
  FROM bdm_tempo.stg_cert_nov_base z;

  -- ------------------------------------------------------------
  -- Apoyo de NOV-UB-12: las DOS RAMAS de la ventana del DELTA, separadas.
  --
  -- POR QUE HACE FALTA SEPARARLAS. La ventana del SP es
  --   fecha_relacion_persona_ubicaci >= watermark OR fecha IS NULL
  -- (sp_novedades_ubicacion_edf.sql:78-79). Un NOV-UB-12 que solo cuenta
  -- cambios da PASSED aunque la rama de FECHA no haya aportado una sola
  -- fila, y eso fue exactamente lo que paso en el job DEV/DATABASE #409: el
  -- orquestador cerraba la corrida con CURRENT_DATE como watermark nuevo en
  -- vez del MAX del dato, la frontera quedaba en hoy y el DELTA recogia solo
  -- la rama de fecha nula. El tablero no lo vio porque no miraba.
  --
  -- Toda fila de la salida ya paso la ventana, asi que la que trae fecha no
  -- nula entro POR FECHA y la que la trae nula entro por la otra rama: la
  -- particion no necesita releer el watermark.
  --
  -- Materializado y con CROSS JOIN, no en subconsulta escalar: es la trampa
  -- que tumbo el #407 y esta documentada mas abajo.
  -- ------------------------------------------------------------
  DROP TABLE IF EXISTS bdm_tempo.stg_cert_nov_ventana;
  CREATE TABLE bdm_tempo.stg_cert_nov_ventana
  DISTSTYLE ALL
  AS
  SELECT COALESCE(SUM(CASE WHEN r.fecha_relacion_persona_ubicaci IS NOT NULL
                           THEN 1 ELSE 0 END), 0) AS por_fecha,
         COALESCE(SUM(CASE WHEN r.fecha_relacion_persona_ubicaci IS NULL
                           THEN 1 ELSE 0 END), 0) AS por_nula
  FROM bdm_tempo.stg_cert_nov_base z
  JOIN bdm_tempo.v_mock_relacion_persona_ubicacion r
    ON r.cod_dw_persona_ubic = z.id
  WHERE z.flag_op IN ('I','A');

  -- ---------- NOV-UB-12: en DELTA hay cambios, y por la ventana de FECHA ----------
  INSERT INTO bdm_datos.cert_resultado_nov
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'NOV-UB-12',
         CASE WHEN p_fase IN ('FULL', 'FULL2') THEN 'NO_APLICA'
              WHEN COUNT(*) = 0 THEN 'SIN_DATO'
              WHEN COALESCE(SUM(CASE WHEN z.flag_op IN ('I','A') THEN 1 ELSE 0 END), 0) = 0
                                 THEN 'FAILED'
              -- Sin una sola fila por fecha, el DELTA no ha ejercitado la
              -- ventana: es verde de la rama que no prueba nada.
              WHEN MAX(w.por_fecha) = 0 THEN 'FAILED'
              ELSE 'PASSED' END,
         'fase=' || p_fase
           || ', altas=' || CAST(COALESCE(SUM(CASE WHEN z.flag_op = 'I' THEN 1 ELSE 0 END), 0) AS VARCHAR)
           || ', cambios=' || CAST(COALESCE(SUM(CASE WHEN z.flag_op = 'A' THEN 1 ELSE 0 END), 0) AS VARCHAR)
           || ', fuera de la ventana=' || CAST(COALESCE(SUM(CASE WHEN z.flag_op IS NULL THEN 1 ELSE 0 END), 0) AS VARCHAR)
           || '; de las que entraron, por fecha=' || CAST(MAX(w.por_fecha) AS VARCHAR)
           || ' y por fecha nula=' || CAST(MAX(w.por_nula) AS VARCHAR),
         GETDATE(), CURRENT_USER
  FROM       bdm_tempo.stg_cert_nov_base    z
  CROSS JOIN bdm_tempo.stg_cert_nov_ventana w;

  -- ---------- NOV-UB-13: la baja por bloqueo ----------
  -- CORREGIDO (SLCOPRBA-1355). Esto decia "el mock no siembra ubicaciones
  -- bloqueadas", como si faltara un arquetipo. ERA FALSO: la rama 'E' es
  -- CODIGO MUERTO EN EL LEGADO. La etapa 1 hace el anti-join contra V_BLOQUEO
  -- (Novedad.sql:7590-7594) y la etapa 9 vuelve a unir la MISMA tabla por la
  -- MISMA llave para preguntar por FECHA_BLOQUEO (:8393, :8416): lo que
  -- sobrevivio no esta en V_BLOQUEO, asi que la condicion nunca da TRUE.
  -- Ningun arquetipo lo desbloquea. Lo correcto es decirlo, no sembrarlo.
  -- El criterio verifica entonces lo que SI se puede verificar: que nuestro
  -- port tampoco emita bajas, que es la paridad con el AS-IS.
  INSERT INTO bdm_datos.cert_resultado_nov
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase,  'NOV-UB-13',
         CASE WHEN COALESCE(SUM(CASE WHEN z.flag_op = 'E' THEN 1 ELSE 0 END), 0) = 0
                   THEN 'PASSED' ELSE 'FAILED' END,
         'bajas en la salida=' || CAST(COALESCE(SUM(CASE WHEN z.flag_op = 'E' THEN 1 ELSE 0 END), 0) AS VARCHAR)
           || ', esperadas=0. flag_op=E es codigo muerto en el legado: la etapa 1'
           || ' anti-une V_BLOQUEO (Novedad.sql:7590-7594) y la etapa 9 vuelve a'
           || ' unirla por la misma llave (:8393), de modo que FECHA_BLOQUEO es'
           || ' siempre NULL. Emitir una baja seria divergir, no acertar',
         GETDATE(), CURRENT_USER
  FROM bdm_tempo.stg_cert_nov_base z;

  -- ------------------------------------------------------------
  -- Apoyo 2 y 3: los conteos que necesitan NOV-UB-14 y NOV-UB-15.
  --
  -- POR QUE MATERIALIZADOS Y NO EN SUBCONSULTA, que es lo que tumbo el job
  -- DEV/DATABASE #407: la version anterior ponia cuatro subconsultas
  -- escalares en la proyeccion de una tabla derivada, con un EXISTS
  -- correlacionado dentro de cada una. Redshift lo rechaza en EJECUCION con
  --   XX000: This type of correlated subquery pattern is not supported
  -- y PostgreSQL lo acepta sin una queja, de modo que el banco lo dio verde.
  -- Tercer punto ciego del banco, hermano de DELTA y del RAISE.
  --
  -- El LEFT JOIN contra un SELECT DISTINCT sustituye al EXISTS; el
  -- SELECT DISTINCT evita que la tabla final multiplique filas del cruce si
  -- algun dia tuviera el id repetido -- que es justo lo que NOV-UB-14 mide.
  -- ------------------------------------------------------------
  DROP TABLE IF EXISTS bdm_tempo.stg_cert_nov_mat;
  CREATE TABLE bdm_tempo.stg_cert_nov_mat
  DISTSTYLE ALL
  AS
  SELECT COUNT(*)           AS en_mat,
         COUNT(DISTINCT id) AS ids_mat
  FROM bdm_datos.mat_info_ubicacion_mock;

  DROP TABLE IF EXISTS bdm_tempo.stg_cert_nov_cruce;
  CREATE TABLE bdm_tempo.stg_cert_nov_cruce
  DISTSTYLE ALL
  AS
  SELECT COALESCE(SUM(CASE WHEN b.flag_op IN ('I','A') THEN 1 ELSE 0 END), 0) AS aplicables,
         COALESCE(SUM(CASE WHEN b.flag_op IN ('I','A') AND m.id IS NOT NULL
                           THEN 1 ELSE 0 END), 0)                             AS cubiertas,
         COALESCE(SUM(CASE WHEN b.flag_op = 'E' THEN 1 ELSE 0 END), 0)        AS bajas,
         COALESCE(SUM(CASE WHEN b.flag_op = 'E' AND m.id IS NOT NULL
                           THEN 1 ELSE 0 END), 0)                             AS supervivientes
  FROM      bdm_tempo.stg_cert_nov_base b
  LEFT JOIN ( SELECT DISTINCT id FROM bdm_datos.mat_info_ubicacion_mock ) m
         ON m.id = b.id;

  -- ---------- NOV-UB-14: la tabla final recibe el alta y el cambio ----------
  INSERT INTO bdm_datos.cert_resultado_nov
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'NOV-UB-14',
         CASE WHEN c.aplicables = 0            THEN 'SIN_DATO'
              WHEN v.en_mat <> v.ids_mat       THEN 'FAILED'
              WHEN c.aplicables <> c.cubiertas THEN 'FAILED'
              ELSE 'PASSED' END,
         'aplicables en la salida (I o A)=' || CAST(c.aplicables AS VARCHAR)
           || ', de esas presentes en la tabla final=' || CAST(c.cubiertas AS VARCHAR)
           || '; filas en la tabla final=' || CAST(v.en_mat AS VARCHAR)
           || ', ids distintos=' || CAST(v.ids_mat AS VARCHAR),
         GETDATE(), CURRENT_USER
  FROM       bdm_tempo.stg_cert_nov_cruce c
  CROSS JOIN bdm_tempo.stg_cert_nov_mat   v;

  -- ---------- NOV-UB-15: la baja borra de la tabla final ----------
  -- Hermano de NOV-UB-13 y corregido por lo mismo. El borrado del legado sale
  -- de Severidad = 2, y Severidad = 2 sale UNICAMENTE de
  -- WHEN STG.FLAG_OP = 'E' THEN 2 (120.TPT:163). Sin 'E' no hay Severidad 2:
  -- el UPSERT de 130.TPT nunca borra. El AS-IS solo inserta y actualiza, y
  -- eso es lo que el criterio verifica.
  INSERT INTO bdm_datos.cert_resultado_nov
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'NOV-UB-15',
         CASE WHEN c.bajas > 0          THEN 'FAILED'
              WHEN c.supervivientes > 0 THEN 'FAILED'
              ELSE 'PASSED' END,
         'bajas=' || CAST(c.bajas AS VARCHAR) || ', esperadas=0'
           || '; de esas aun presentes en la tabla final=' || CAST(c.supervivientes AS VARCHAR)
           || '. El borrado del legado sale solo de Severidad=2, y Severidad=2'
           || ' solo de FLAG_OP=E (120.TPT:163), que es codigo muerto: el UPSERT'
           || ' de 130.TPT nunca borra una fila',
         GETDATE(), CURRENT_USER
  FROM bdm_tempo.stg_cert_nov_cruce c;

  -- ============================================================
  -- DOMINIO ACTIVIDAD ECONOMICA (NOV-AE-01..10)
  --
  -- Segundo dominio portado. Legado: PRO_Novedad_Linea_Historial
  -- (Novedad.sql:1060-1420) mas los dos TPT.
  --
  -- TODO SE MATERIALIZA Y SE UNE CON CROSS JOIN. No hay una sola subconsulta
  -- escalar en la lista de un SELECT: es la trampa que tumbo el job #407 con
  -- XX000 y que el banco local no ve porque PostgreSQL la ejecuta sin quejarse.
  -- ============================================================
  DROP TABLE IF EXISTS bdm_tempo.stg_cert_ae_falta;
  DROP TABLE IF EXISTS bdm_tempo.stg_cert_ae_mat;
  DROP TABLE IF EXISTS bdm_tempo.stg_cert_ae_base;
  CREATE TABLE bdm_tempo.stg_cert_ae_base
  DISTSTYLE ALL
  AS
  SELECT *
  FROM bdm_tempo.stg_nov_acteco_etapa_1_mock
  WHERE info_basica_id BETWEEN 9000000 AND 9999999;

  CREATE TABLE bdm_tempo.stg_cert_ae_mat
  DISTSTYLE ALL
  AS
  SELECT COUNT(*)                       AS filas,
         COUNT(DISTINCT id)             AS ids,
         COUNT(DISTINCT info_basica_id) AS personas
  FROM bdm_datos.mat_info_actividad_economica_mock
  WHERE info_basica_id BETWEEN 9000000 AND 9999999;

  -- Personas de la etapa que NO llegaron a la tabla final. LEFT JOIN contra un
  -- SELECT DISTINCT en vez de NOT EXISTS correlacionado, por lo mismo.
  CREATE TABLE bdm_tempo.stg_cert_ae_falta
  DISTSTYLE ALL
  AS
  SELECT COALESCE(SUM(CASE WHEN m.info_basica_id IS NULL THEN 1 ELSE 0 END), 0) AS ausentes
  FROM      ( SELECT DISTINCT info_basica_id
                FROM bdm_tempo.stg_cert_ae_base ) z
  LEFT JOIN ( SELECT DISTINCT info_basica_id
                FROM bdm_datos.mat_info_actividad_economica_mock ) m
         ON m.info_basica_id = z.info_basica_id;

  -- ---------- NOV-AE-01: las columnas de los dos contratos ----------
  INSERT INTO bdm_datos.cert_resultado_nov
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'NOV-AE-01',
         CASE WHEN v_cols_a1 = 9 AND v_cols_am = 11 THEN 'PASSED' ELSE 'FAILED' END,
         'columnas de stg_nov_acteco_etapa_1_mock=' || CAST(v_cols_a1 AS VARCHAR)
           || ' (esperado 9) y de mat_info_actividad_economica_mock='
           || CAST(v_cols_am AS VARCHAR)
           || ' (esperado 11 = 8 del contrato de 130.TPT:76-88 mas lote, fecha_actualizacion y usuario_bd)',
         GETDATE(), CURRENT_USER;

  -- ---------- NOV-AE-02: un par (ciiu, persona) por fila ----------
  -- El QUALIFY del legado (Novedad.sql:1379) es REDUNDANTE en la via real,
  -- porque v_xpm_ciiu_persona ya hace SELECT DISTINCT sobre esas dos columnas.
  -- En la via MOCK no lo es: v_mock_ciiu_persona lee bdm_stage.ciiu_persona sin
  -- DISTINCT (02b_vistas_insumo_mock.sql:245-250). Este criterio es el que
  -- avisaria si alguien lo quita por parecer sobrante.
  INSERT INTO bdm_datos.cert_resultado_nov
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'NOV-AE-02',
         CASE WHEN COUNT(*) = 0 THEN 'SIN_DATO'
              WHEN COUNT(*) = COUNT(DISTINCT z.ciiu || '|' || CAST(z.info_basica_id AS VARCHAR))
                   THEN 'PASSED' ELSE 'FAILED' END,
         'filas=' || CAST(COUNT(*) AS VARCHAR)
           || ', pares (ciiu, persona) distintos='
           || CAST(COUNT(DISTINCT z.ciiu || '|' || CAST(z.info_basica_id AS VARCHAR)) AS VARCHAR)
           || ' (deben coincidir: el QUALIFY de Novedad.sql:1379 particiona por ese par)',
         GETDATE(), CURRENT_USER
  FROM bdm_tempo.stg_cert_ae_base z;

  -- ---------- NOV-AE-03: solo personas con CIIU informado ----------
  INSERT INTO bdm_datos.cert_resultado_nov
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'NOV-AE-03',
         CASE WHEN COUNT(*) = 0 THEN 'SIN_DATO'
              WHEN COALESCE(SUM(CASE WHEN z.ciiu IS NULL THEN 1 ELSE 0 END), 0) = 0
                   THEN 'PASSED' ELSE 'FAILED' END,
         'filas=' || CAST(COUNT(*) AS VARCHAR)
           || ', con CIIU nulo=' || CAST(COALESCE(SUM(CASE WHEN z.ciiu IS NULL THEN 1 ELSE 0 END), 0) AS VARCHAR)
           || ' (esperado 0; filtro del legado en Novedad.sql:1377)',
         GETDATE(), CURRENT_USER
  FROM bdm_tempo.stg_cert_ae_base z;

  -- ---------- NOV-AE-04: en FULL todo es alta ----------
  INSERT INTO bdm_datos.cert_resultado_nov
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'NOV-AE-04',
         CASE WHEN p_fase NOT IN ('FULL', 'FULL2') THEN 'NO_APLICA'
              WHEN COUNT(*) = 0 THEN 'SIN_DATO'
              WHEN COALESCE(SUM(CASE WHEN z.flag_op <> 'I' THEN 1 ELSE 0 END), 0) = 0
                   THEN 'PASSED' ELSE 'FAILED' END,
         'fase=' || p_fase
           || ', filas=' || CAST(COUNT(*) AS VARCHAR)
           || ', altas=' || CAST(COALESCE(SUM(CASE WHEN z.flag_op = 'I' THEN 1 ELSE 0 END), 0) AS VARCHAR)
           || ', no altas=' || CAST(COALESCE(SUM(CASE WHEN z.flag_op <> 'I' THEN 1 ELSE 0 END), 0) AS VARCHAR),
         GETDATE(), CURRENT_USER
  FROM bdm_tempo.stg_cert_ae_base z;

  -- ---------- NOV-AE-05: en DELTA la ventana de FECHA aporta ----------
  -- GEMELO DE NOV-UB-12, Y POR LA MISMA RAZON. La ventana del SP es
  --   fecha_reporte >= watermark OR fecha_reporte IS NULL
  -- (sp_novedades_actividad_economica_edf.sql:149-151). Contar filas a secas
  -- da PASSED aunque la rama de FECHA no haya aportado ninguna, que es
  -- exactamente el defecto que el #409 dejo pasar en Ubicacion.
  --
  -- Toda fila de la etapa ya paso la ventana, de modo que la que trae fecha no
  -- nula entro POR FECHA: la particion no necesita releer el watermark.
  --
  -- CERO FILAS ES SIN_DATO Y NO FAILED, a proposito: es la verdad cuando la
  -- semilla no pone ninguna fecha por encima del watermark, y un FAILED ahi
  -- tumbaria el build por una carencia del mock y no por un defecto del port.
  INSERT INTO bdm_datos.cert_resultado_nov
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'NOV-AE-05',
         CASE WHEN p_fase IN ('FULL', 'FULL2') THEN 'NO_APLICA'
              WHEN COUNT(*) = 0 THEN 'SIN_DATO'
              WHEN COALESCE(SUM(CASE WHEN z.fecha_reporte IS NOT NULL THEN 1 ELSE 0 END), 0) = 0
                   THEN 'FAILED'
              ELSE 'PASSED' END,
         'fase=' || p_fase
           || ', filas=' || CAST(COUNT(*) AS VARCHAR)
           || '; de las que entraron, por fecha='
           || CAST(COALESCE(SUM(CASE WHEN z.fecha_reporte IS NOT NULL THEN 1 ELSE 0 END), 0) AS VARCHAR)
           || ' y por fecha nula='
           || CAST(COALESCE(SUM(CASE WHEN z.fecha_reporte IS NULL THEN 1 ELSE 0 END), 0) AS VARCHAR),
         GETDATE(), CURRENT_USER
  FROM bdm_tempo.stg_cert_ae_base z;

  -- ---------- NOV-AE-08: el AS-IS solo inserta ----------
  INSERT INTO bdm_datos.cert_resultado_nov
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'NOV-AE-08',
         CASE WHEN COUNT(*) = 0 THEN 'SIN_DATO'
              WHEN COALESCE(SUM(CASE WHEN z.flag_op = 'E' THEN 1 ELSE 0 END), 0) = 0
                   THEN 'PASSED' ELSE 'FAILED' END,
         'bajas en la etapa=' || CAST(COALESCE(SUM(CASE WHEN z.flag_op = 'E' THEN 1 ELSE 0 END), 0) AS VARCHAR)
           || ', esperadas=0. El DELETE del 130.TPT:753 exige Severidad=2 y el CASE de 120.TPT:186-197 no tiene rama que la devuelva: tres dan 1 y el ELSE da -1. Emitir una baja seria divergir',
         GETDATE(), CURRENT_USER
  FROM bdm_tempo.stg_cert_ae_base z;

  -- ---------- NOV-AE-09: el id de la tabla final no se repite ----------
  INSERT INTO bdm_datos.cert_resultado_nov
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'NOV-AE-09',
         CASE WHEN v.filas = 0 THEN 'SIN_DATO'
              WHEN v.filas = v.ids THEN 'PASSED' ELSE 'FAILED' END,
         'filas en la tabla final=' || CAST(v.filas AS VARCHAR)
           || ', ids distintos=' || CAST(v.ids AS VARCHAR)
           || ', personas distintas=' || CAST(v.personas AS VARCHAR)
           || ' (filas e ids deben coincidir: el id es MAX(id) + la posicion de la fila, 120.TPT:177-179)',
         GETDATE(), CURRENT_USER
  FROM bdm_tempo.stg_cert_ae_mat v;

  -- ---------- NOV-AE-10: la etapa llega a la tabla final ----------
  INSERT INTO bdm_datos.cert_resultado_nov
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'NOV-AE-10',
         CASE WHEN COUNT(*) = 0 THEN 'SIN_DATO'
              WHEN MAX(f.ausentes) = 0 THEN 'PASSED' ELSE 'FAILED' END,
         'personas en la etapa=' || CAST(COUNT(DISTINCT z.info_basica_id) AS VARCHAR)
           || ', de ellas ausentes de la tabla final=' || CAST(COALESCE(MAX(f.ausentes), 0) AS VARCHAR)
           || ' (esperado 0; el 130.TPT:215 descarta Severidad=-1 y el resto entra)',
         GETDATE(), CURRENT_USER
  FROM       bdm_tempo.stg_cert_ae_base  z
  CROSS JOIN bdm_tempo.stg_cert_ae_falta f;

  -- ---------- NOV-AE-06 y 07: bloqueadas por catalogo que no se entrego ----------
  INSERT INTO bdm_datos.cert_resultado_nov
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, c.criterio, 'BLOQUEADO', c.detalle, GETDATE(), CURRENT_USER
  FROM (
    SELECT CAST('NOV-AE-06' AS VARCHAR(12)) AS criterio,
           CAST('falta V_ACTIVIDAD_ECONO_CIIU (Novedad.sql:1352-1354): actividad_economica y version salen NULL. Pedido en docs/PETICION_CATALOGOS_NOVEDADES.md seccion 6' AS VARCHAR(1024)) AS detalle UNION ALL
    SELECT 'NOV-AE-07', 'falta el catalogo V_Hom_Tip_Ident_Linea, el mismo que bloquea NOV-UB-18: el tipo de identificacion sale NULL'
  ) c;

  -- ------------------------------------------------------------
  -- DOMINIO UBICACION AGREGADA (NOV-AG-01..08)
  --
  -- SIETE DE LOS OCHO SALEN BLOQUEADO, Y NO ES PRUDENCIA: ES QUE EL DOMINIO
  -- EMITE CERO FILAS. tipo_identificacion sale NULL en toda fila
  -- (sp_novedades_ubicacion_edf.sql:362) y la etapa 5 une por igualdad en esa
  -- columna (Novedad.sql:5431): NULL = NULL es falso y el join vacia la
  -- cadena. Medido en el banco: etapas 1 a 4 con 8.500 filas, la 5 con cero.
  --
  -- UN SIN_DATO SERIA MENTIR POR OMISION. SIN_DATO dice "el mock no siembra
  -- este caso" y se arregla sembrando un arquetipo; aqui ningun arquetipo lo
  -- arregla, porque falta un catalogo del datashare. BLOQUEADO es el estado
  -- que ya usan NOV-AE-06/07 y NOV-UB-16..22 para exactamente esto.
  --
  -- Y NO SE EVALUAN EN FALSO: un COUNT(*) sobre cero filas daria PASSED en
  -- varios de ellos -- es la trampa del SUM() sobre cero filas que ya costo
  -- un criterio --, de modo que escribirlos como CONSULTA los dejaria en
  -- verde sin haber mirado nada.
  -- ------------------------------------------------------------

  -- ---------- NOV-AG-01: las columnas de los dos contratos ----------
  -- EL UNICO EVALUABLE HOY: mira information_schema, que no depende de que
  -- haya filas. Es lo que cazaria una deriva del contrato mientras el resto
  -- espera al catalogo.
  INSERT INTO bdm_datos.cert_resultado_nov
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'NOV-AG-01',
         CASE WHEN v_cols_ag = 30 AND v_cols_agm = 32 THEN 'PASSED' ELSE 'FAILED' END,
         'columnas de stg_nov_ubiagr_etapa_final_mock=' || CAST(v_cols_ag AS VARCHAR)
           || ' (esperado 30 = 29 del contrato de 130.TPT:1033-1147 mas flag_op)'
           || ' y de mat_ubicacion_agregada_mock=' || CAST(v_cols_agm AS VARCHAR)
           || ' (esperado 32 = 29 mas lote, fecha_actualizacion y usuario_bd)',
         GETDATE(), CURRENT_USER;

  -- ---------- NOV-AG-02..08: bloqueadas por el mismo catalogo ----------
  INSERT INTO bdm_datos.cert_resultado_nov
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, c.criterio, 'BLOQUEADO', c.detalle, GETDATE(), CURRENT_USER
  FROM (
    SELECT CAST('NOV-AG-02' AS VARCHAR(12)) AS criterio,
           CAST('falta V_Hom_Tip_Ident_Linea: con tipo_identificacion en NULL la etapa 5 (Novedad.sql:5431) sale vacia y no hay filas sobre las que medir el grano de la llave de siete columnas' AS VARCHAR(1024)) AS detalle UNION ALL
    SELECT 'NOV-AG-03', 'mismo catalogo: sin filas en la etapa final no hay listas concatenadas que comprobar' UNION ALL
    SELECT 'NOV-AG-04', 'mismo catalogo: sin filas no hay ranking que numerar' UNION ALL
    SELECT 'NOV-AG-05', 'mismo catalogo: sin filas no se puede comprobar que las cinco columnas de reporte vengan pobladas' UNION ALL
    SELECT 'NOV-AG-06', 'mismo catalogo: sin filas el conteo de bajas sale cero por vacio y no por paridad, que es justo lo que este criterio debe distinguir' UNION ALL
    SELECT 'NOV-AG-07', 'mismo catalogo: la tabla final no crece entre pasadas porque no entra nada, de modo que el verde no probaria la idempotencia del UPSERT' UNION ALL
    SELECT 'NOV-AG-08', 'mismo catalogo: sin filas no se puede comprobar que cod_pais siga en blanco'
  ) c;

  -- ---------- NOV-UB-16..22: bloqueadas por insumo que no se entrego ----------
  INSERT INTO bdm_datos.cert_resultado_nov
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, c.criterio, 'BLOQUEADO', c.detalle, GETDATE(), CURRENT_USER
  FROM (
    SELECT CAST('NOV-UB-16' AS VARCHAR(12)) AS criterio,
           CAST('falta el catalogo V_Hom_TipoUbic_Dir_Linea: la columna TIPO sale NULL' AS VARCHAR(1024)) AS detalle UNION ALL
    SELECT 'NOV-UB-17', 'faltan V_ZONA_UBICACION y V_Hom_Zona_Linea: la columna ZONA sale NULL' UNION ALL
    SELECT 'NOV-UB-18', 'falta el catalogo V_Hom_Tip_Ident_Linea: el tipo de identificacion sale NULL' UNION ALL
    SELECT 'NOV-UB-19', 'falta V_TELEFONO_FIJO: la columna INDICATIVO sale NULL' UNION ALL
    SELECT 'NOV-UB-20', 'falta V_TIPO_CORREO: la columna de tipo de cuenta sale NULL' UNION ALL
    SELECT 'NOV-UB-21', 'geo_atributos declara barrio y estrato y nunca los escribe: su posicion en el contrato de 32 columnas no esta pinada (sp_geo_cargar_georreferenciacion.sql:443-446)' UNION ALL
    SELECT 'NOV-UB-22', 'localidad y codigo postal no tienen columna en geo_atributos; las dos vienen del contrato GEO sin pinar'
  ) c;

  -- ---------- Los SEIS dominios no portados ----------
  -- Eran siete. NOV-HIS-01 salio del catalogo: el historial de actividad
  -- economica es PRO_Novedad_Linea_Historial, que es justo lo que el bloque
  -- ACTIVIDAD_ECONOMICA certifica desde el job DEV/DATABASE #413.
  INSERT INTO bdm_datos.cert_resultado_nov
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, c.criterio, 'NO_IMPLEMENTADO', c.detalle, GETDATE(), CURRENT_USER
  FROM (
    SELECT CAST('NOV-CAT-01' AS VARCHAR(12)) AS criterio,
           CAST('PRO_Novedad_Linea_Catalogo (Novedad.sql:3) no esta portado' AS VARCHAR(1024)) AS detalle UNION ALL
    SELECT 'NOV-INB-01', 'PRO_Novedad_Linea_Info_Basica (Novedad.sql:2166) no esta portado; depende ademas de la decision funcional del filtro Mosaic' UNION ALL
    SELECT 'NOV-CON-01', 'PRO_Novedad_Linea_Contact (Novedad.sql:186) no esta portado; siete de sus once columnas son datos de gestion que no vienen del datashare' UNION ALL
    SELECT 'NOV-PIN-01', 'PRO_Novedad_Linea_Punto_Interes (Novedad.sql:4585) no esta portado; falta ademas el nombre del punto de interes en el contrato de distancias' UNION ALL
    SELECT 'NOV-MOV-01', 'PRO_Novedad_Linea_Indic_Movilidad (Novedad.sql:1508) no esta portado y depende del proceso P0029, cuya migracion esta pendiente'
  ) c;

  -- ---------- Gobernanza: no hay consulta que la decida ----------
  INSERT INTO bdm_datos.cert_resultado_nov
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, c.criterio, 'REVISION_MANUAL', c.detalle, GETDATE(), CURRENT_USER
  FROM (
    SELECT CAST('NOV-G-01' AS VARCHAR(12)) AS criterio,
           CAST('la paridad real/mock se verifica con un diff de archivos, no con una consulta: lo comprueba validar.sh y el generador tools/gen_novedades_espejo_mock.py' AS VARCHAR(1024)) AS detalle UNION ALL
    SELECT 'NOV-G-02', 'el control de lote es diseno propio porque el del legado esta inoperativo: 111.BTQ:64-65 borra el log al arrancar y 140.BTQ:853-858 no llama al cierre. Decision a confirmar con el equipo' UNION ALL
    SELECT 'NOV-G-03', 'falta decidir el equivalente en Redshift del patron de recarga del legado (clonar a BK_*, apuntar las vistas al clon, vaciar y reponer). Decision de arquitectura'
  ) c;

  DROP TABLE IF EXISTS bdm_tempo.stg_cert_nov_cruce;
  DROP TABLE IF EXISTS bdm_tempo.stg_cert_nov_mat;
  DROP TABLE IF EXISTS bdm_tempo.stg_cert_nov_base;
  DROP TABLE IF EXISTS bdm_tempo.stg_cert_ae_falta;
  DROP TABLE IF EXISTS bdm_tempo.stg_cert_ae_mat;
  DROP TABLE IF EXISTS bdm_tempo.stg_cert_ae_base;

END;
$$;
