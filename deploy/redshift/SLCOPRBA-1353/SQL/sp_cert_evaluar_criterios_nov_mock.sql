-- ============================================================
-- sp_cert_evaluar_criterios_nov_mock.sql
-- SLCOPRBA-1355: evaluador del tablero de certificacion de NOVEDADES.
-- Gemelo de sp_cert_evaluar_criterios_ord_mock.sql. UTF-8 sin BOM, sin acentos.
--
-- PRINCIPIO: un criterio que no se puede afirmar NO sale ausente ni sale
-- PASSED. Sale con el estado que le corresponde y con la razon exacta.
--
-- ALCANCE EVALUABLE: 14 de los 32.
--   NOV-UB-01..NOV-UB-15 menos NOV-UB-05  -> CONSULTA
--   NOV-UB-05                             -> SIN_DATO (la gestion de registro
--                                            no esta modelada en el mock)
--   NOV-UB-16..NOV-UB-22                  -> BLOQUEADO (catalogo o contrato
--                                            GEO que no se entrego)
--   los siete dominios no portados        -> NO_IMPLEMENTADO
--   NOV-G-01..G-03                        -> REVISION_MANUAL
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

  -- ------------------------------------------------------------
  -- Apoyo: la salida del dominio, acotada al universo mock.
  -- DISTSTYLE ALL: son decenas de miles de filas y varios criterios la
  -- cruzan contra si misma y contra la tabla final.
  -- ------------------------------------------------------------
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

  -- ---------- NOV-UB-12: en DELTA hay cambios ----------
  INSERT INTO bdm_datos.cert_resultado_nov
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'NOV-UB-12',
         CASE WHEN p_fase IN ('FULL', 'FULL2') THEN 'NO_APLICA'
              WHEN COUNT(*) = 0 THEN 'SIN_DATO'
              WHEN COALESCE(SUM(CASE WHEN z.flag_op IN ('I','A') THEN 1 ELSE 0 END), 0) = 0
                                 THEN 'FAILED'
              ELSE 'PASSED' END,
         'fase=' || p_fase
           || ', altas=' || CAST(COALESCE(SUM(CASE WHEN z.flag_op = 'I' THEN 1 ELSE 0 END), 0) AS VARCHAR)
           || ', cambios=' || CAST(COALESCE(SUM(CASE WHEN z.flag_op = 'A' THEN 1 ELSE 0 END), 0) AS VARCHAR)
           || ', fuera de la ventana=' || CAST(COALESCE(SUM(CASE WHEN z.flag_op IS NULL THEN 1 ELSE 0 END), 0) AS VARCHAR),
         GETDATE(), CURRENT_USER
  FROM bdm_tempo.stg_cert_nov_base z;

  -- ---------- NOV-UB-13: la baja por bloqueo ----------
  -- El mock no siembra ubicaciones bloqueadas: la rama existe en el SP pero
  -- ninguna fila la ejercita. SIN_DATO en vez de PASSED, por el mismo motivo
  -- que NOV-UB-05.
  INSERT INTO bdm_datos.cert_resultado_nov
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase,  'NOV-UB-13',
         CASE WHEN COALESCE(SUM(CASE WHEN z.flag_op = 'E' THEN 1 ELSE 0 END), 0) = 0
                   THEN 'SIN_DATO' ELSE 'PASSED' END,
         'bajas en la salida=' || CAST(COALESCE(SUM(CASE WHEN z.flag_op = 'E' THEN 1 ELSE 0 END), 0) AS VARCHAR)
           || '. El mock no siembra ubicaciones bloqueadas: la rama existe en el SP y ninguna fila la ejercita',
         GETDATE(), CURRENT_USER
  FROM bdm_tempo.stg_cert_nov_base z;

  -- ---------- NOV-UB-14: la tabla final recibe el alta y el cambio ----------
  INSERT INTO bdm_datos.cert_resultado_nov
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'NOV-UB-14',
         CASE WHEN v.aplicables = 0                       THEN 'SIN_DATO'
              WHEN v.en_mat <> v.ids_mat                  THEN 'FAILED'
              WHEN v.aplicables <> v.cubiertas            THEN 'FAILED'
              ELSE 'PASSED' END,
         'aplicables en la salida (I o A)=' || CAST(v.aplicables AS VARCHAR)
           || ', de esas presentes en la tabla final=' || CAST(v.cubiertas AS VARCHAR)
           || '; filas en la tabla final=' || CAST(v.en_mat AS VARCHAR)
           || ', ids distintos=' || CAST(v.ids_mat AS VARCHAR),
         GETDATE(), CURRENT_USER
  FROM (
    SELECT (SELECT COUNT(*) FROM bdm_tempo.stg_cert_nov_base WHERE flag_op IN ('I','A')) AS aplicables,
           (SELECT COUNT(*) FROM bdm_tempo.stg_cert_nov_base b
             WHERE b.flag_op IN ('I','A')
               AND EXISTS (SELECT 1 FROM bdm_datos.mat_info_ubicacion_mock m WHERE m.id = b.id)) AS cubiertas,
           (SELECT COUNT(*)          FROM bdm_datos.mat_info_ubicacion_mock) AS en_mat,
           (SELECT COUNT(DISTINCT id) FROM bdm_datos.mat_info_ubicacion_mock) AS ids_mat
  ) v;

  -- ---------- NOV-UB-15: la baja borra de la tabla final ----------
  INSERT INTO bdm_datos.cert_resultado_nov
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, 'NOV-UB-15',
         CASE WHEN v.bajas = 0           THEN 'SIN_DATO'
              WHEN v.supervivientes > 0  THEN 'FAILED'
              ELSE 'PASSED' END,
         'bajas=' || CAST(v.bajas AS VARCHAR)
           || ', de esas aun presentes en la tabla final=' || CAST(v.supervivientes AS VARCHAR)
           || '. Sin bajas sembradas el criterio queda SIN_DATO, no PASSED',
         GETDATE(), CURRENT_USER
  FROM (
    SELECT (SELECT COUNT(*) FROM bdm_tempo.stg_cert_nov_base WHERE flag_op = 'E') AS bajas,
           (SELECT COUNT(*) FROM bdm_tempo.stg_cert_nov_base b
             WHERE b.flag_op = 'E'
               AND EXISTS (SELECT 1 FROM bdm_datos.mat_info_ubicacion_mock m WHERE m.id = b.id)) AS supervivientes
  ) v;

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

  -- ---------- Los siete dominios no portados ----------
  INSERT INTO bdm_datos.cert_resultado_nov
    (lote, modo, criterio, estado, detalle, fecha_hora, usuario_bd)
  SELECT p_lote, p_fase, c.criterio, 'NO_IMPLEMENTADO', c.detalle, GETDATE(), CURRENT_USER
  FROM (
    SELECT CAST('NOV-CAT-01' AS VARCHAR(12)) AS criterio,
           CAST('PRO_Novedad_Linea_Catalogo (Novedad.sql:3) no esta portado' AS VARCHAR(1024)) AS detalle UNION ALL
    SELECT 'NOV-INB-01', 'PRO_Novedad_Linea_Info_Basica (Novedad.sql:2166) no esta portado; depende ademas de la decision funcional del filtro Mosaic' UNION ALL
    SELECT 'NOV-CON-01', 'PRO_Novedad_Linea_Contact (Novedad.sql:186) no esta portado; siete de sus once columnas son datos de gestion que no vienen del datashare' UNION ALL
    SELECT 'NOV-PIN-01', 'PRO_Novedad_Linea_Punto_Interes (Novedad.sql:4585) no esta portado; falta ademas el nombre del punto de interes en el contrato de distancias' UNION ALL
    SELECT 'NOV-HIS-01', 'PRO_Novedad_Linea_Historial (Novedad.sql:1060) no esta portado' UNION ALL
    SELECT 'NOV-MOV-01', 'PRO_Novedad_Linea_Indic_Movilidad (Novedad.sql:1508) no esta portado y depende del proceso P0029, cuya migracion esta pendiente' UNION ALL
    SELECT 'NOV-AGR-01', 'PRO_Novedad_Linea_Ubi_Agregada (Novedad.sql:5032) no esta portado; es el mayor consumidor de las dos etapas de Ubicacion'
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

  DROP TABLE IF EXISTS bdm_tempo.stg_cert_nov_base;

END;
$$;
