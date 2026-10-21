-- Novedades - dominio UBICACION (ESPEJO MOCK)
-- Espejo de sp_novedades_ubicacion_edf.sql. Generado por SUSTITUCION DE
-- FUENTES: no se edita a mano. Regenerar con
-- tools/gen_novedades_espejo_mock.py.
--
-- LO UNICO QUE CAMBIA SON LOS NOMBRES DE LOS OBJETOS QUE LEE Y ESCRIBE:
--   v_xpm_*            -> v_mock_*
--   v_rpu_post_unif.   -> v_mock_rpu_post_unificacion
--   geo_atributos      -> geo_atributos_mock
--   mat_info_ubicacion -> mat_info_ubicacion_mock
--   stg_nov_ubica_etapa_N -> ..._mock   (los dos contratos)
--   stg_nov_*             -> stg_mock_nov_*  (el staging intermedio)
-- El staging intermedio tambien cambia de nombre A PROPOSITO: real y mock
-- comparten el esquema bdm_tempo y una corrida pisaria a la otra.
--
-- La logica, los comentarios y las cinco divergencias documentadas son los
-- del archivo real. El diff entre los dos debe salir vacio modulo esta
-- cabecera y la lista de sustituciones de arriba.

CREATE OR REPLACE PROCEDURE bdm_datos.sp_novedades_ubicacion_mock(
    p_modo      VARCHAR,   -- FULL | DELTA (modo efectivo de la corrida)
    p_watermark DATE       -- frontera inferior inclusiva (solo aplica en DELTA)
)
NONATOMIC
LANGUAGE plpgsql
AS $$
BEGIN

  -- ------------------------------------------------------------
  -- Pasos 5 y 6 del legado: el delta de altas y de cambios.
  --
  -- DIVERGENCIA 2, y es la de fondo. El legado deriva las dos tablas de
  -- RELACION_PERSONA_UBICACION por LOTE, LOTE_ACTUALIZACION y
  -- FECHA_MODIFICACION (Novedad.sql:7394-7401 y :7455-7462), contra un
  -- watermark que lee de REC_MTDAT.LOG_TD. Ninguna de esas tres columnas
  -- existe en edf_views, y el watermark de LOG_TD esta inoperativo: la
  -- corrida borra su propio log al arrancar
  -- (P0035_Extractor_Novedades_111.BTQ:64-65), de modo que la lectura
  -- devuelve NULL y TODAS las corridas del legado son FULL.
  --
  -- Aqui la ventana es fecha_relacion_persona_ubicaci contra el watermark de
  -- nov_control, que es la misma que ya usa la Unificacion. Una relacion sin
  -- fecha entra siempre: es lo que hace sp_unificacion_r1_preparar_insumo y
  -- no inventamos una semantica distinta para el mismo dato.
  --
  -- ALTA contra CAMBIO: sin lote_actualizacion no hay forma de distinguirlos
  -- por columna, asi que se distinguen por presencia en la salida anterior.
  -- Lo que ya esta en mat_info_ubicacion y vuelve a entrar es un cambio; lo
  -- que no estaba es un alta. Es la misma pregunta que responde el
  -- LEFT JOIN de Severidad del legado (120.TPT:174-175), hecha aqui en vez
  -- de en la vista de staging.
  -- ------------------------------------------------------------
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_nov_flag_op_ubica;
  CREATE TABLE bdm_tempo.stg_mock_nov_flag_op_ubica
  DISTSTYLE KEY DISTKEY(cod_dw_persona_ubic)
  AS
  SELECT rpu.cod_dw_persona_ubic,
         CASE WHEN m.id IS NULL THEN 'I' ELSE 'A' END AS flag_op_delta
  FROM   bdm_tempo.v_mock_relacion_persona_ubicacion rpu
  LEFT JOIN bdm_datos.mat_info_ubicacion_mock m
         ON m.id = rpu.cod_dw_persona_ubic
  WHERE  rpu.fecha_relacion_persona_ubicaci >= p_watermark
     OR  rpu.fecha_relacion_persona_ubicaci IS NULL;

  -- ------------------------------------------------------------
  -- Paso 7 del legado: universo base (TMP_UBICA_ETAPA_1).
  -- Novedad.sql:7578-7597. Los tres filtros son del legado y van literales:
  --   sin unificar o padre, no bloqueada, y con orden de prioridad.
  --
  -- EL ORDEN SE LEE DE bdm_datos.rpu_orden_prioridad EN LAS DOS VIAS, Y ESA
  -- ES LA UNICA LINEA QUE EL ESPEJO MOCK NO SUSTITUYE. Motivo: el
  -- Ordenamiento no tiene espejo de consolidacion -- el mock reutiliza
  -- sp_ordenamiento_consolidacion_edf -- de modo que las dos vias escriben en
  -- esa misma tabla real. Verificado en el banco: tras correr
  -- sp_ordenamiento_ejecucion_mock, rpu_orden_prioridad trae 73000 filas.
  --
  -- NO se usa v_rpu_post_unificacion aunque exista y tenga espejo: su version
  -- mock lee bdm_stage.mock_ord_prioridad, que NADIE llena. Esta declarada en
  -- 05_ddl_ordenamiento_mock.sql y la trunca reset_mock.sql, pero no hay un
  -- solo INSERT contra ella en los tres repos, de modo que
  -- v_mock_rpu_post_unificacion.orden_prioridad es NULL siempre. Es un defecto
  -- preexistente de esa vista, no de este port, y esta anotado como tal.
  -- El MIN por cod_dw_persona_ubic replica lo que hace
  -- 04_vistas_insumo_ordenamiento_edf_views.sql:31-36.
  -- ------------------------------------------------------------
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_nov_ubica_e1;
  CREATE TABLE bdm_tempo.stg_mock_nov_ubica_e1
  DISTSTYLE KEY DISTKEY(cod_dw_persona_ubic)
  AS
  SELECT rpu.cod_dw_persona_ubic,
         pu.orden_prioridad,
         rpu.cod_dw_ubic,
         rpu.cod_dw_direccion_fisica,
         rpu.cod_dw_tipo_ubicacion_dir,
         rpu.id_buro_persona,
         rpu.cod_pin_persona,
         rpu.cod_tipo_ident_fte,
         rpu.ind_unificacion,
         rpu.bloqueado
  FROM   bdm_tempo.v_mock_relacion_persona_ubicacion rpu
  INNER JOIN ( SELECT cod_dw_persona_ubic, MIN(orden_prioridad) AS orden_prioridad
                 FROM bdm_datos.rpu_orden_prioridad
                GROUP BY 1 ) pu
         ON pu.cod_dw_persona_ubic = rpu.cod_dw_persona_ubic
  -- EL BLOQUEO EXCLUYE EL ID, NO LA FILA, y es literal del legado:
  --   LEFT JOIN V_BLOQUEO BLQ ON RPU.COD_DW_PERSONA_UBIC = BLQ.COD_DW_PERSONA_UBIC
  --   WHERE ... AND BLQ.COD_DW_PERSONA_UBIC IS NULL        (Novedad.sql:7590-7594)
  -- V_BLOQUEO es una tabla aparte con grano por cod_dw_persona_ubic, de modo
  -- que basta estar en ella para que el id entero desaparezca. Aqui el bloqueo
  -- viene como indicador en la propia fila de RPU, y un
  -- COALESCE(rpu.bloqueado,0) = 0 excluiria la FILA dejando pasar a sus
  -- hermanas con el mismo id. No es equivalente: cod_dw_persona_ubic NO es
  -- unico en el datashare -- 568.657 filas para 142.067 ids, ~4:1 -- asi que
  -- esa version era MAS ANCHA que el legado. El anti-join lo corrige.
  -- En el mock no cambia nada: alli el id es unico por construccion.
  LEFT JOIN ( SELECT DISTINCT cod_dw_persona_ubic
                FROM bdm_tempo.v_mock_relacion_persona_ubicacion
               WHERE COALESCE(bloqueado, 0) = 1 ) blq
         ON blq.cod_dw_persona_ubic = rpu.cod_dw_persona_ubic
  WHERE  (rpu.ind_unificacion IS NULL OR rpu.ind_unificacion = 0)
    AND  blq.cod_dw_persona_ubic IS NULL
    AND  pu.orden_prioridad IS NOT NULL;

  -- ------------------------------------------------------------
  -- Paso 9 del legado: enriquecimiento de ubicacion (TMP_UBICA_ETAPA_3).
  -- Novedad.sql:7652-7686.
  --
  -- El INNER JOIN con V_GESTION_REGISTRO filtrando 'VALIDA' es del legado y
  -- descarta filas (Novedad.sql:7679-7680). Esta frase decia que se portaba
  -- como predicado y no habia ninguno. 2026-10-20 (D-EDF-12): ahora si, sobre
  -- la gestion del LUGAR, que sale del score de estandarizacion (>= 0.80).
  -- DIVERGENCIA DECIDIDA: el legado tambien descarta la ubicacion sin
  -- gestion, porque es un INNER JOIN; aqui pasa. En EDF las direcciones de
  -- suscriptor no traen score (C24) y exigirlo las sacaria todas.
  --
  -- DIVERGENCIA 3, primera aparicion. En el legado la ciudad, el departamento
  -- y el codigo DANE salen de V_GEOGRAFIA. Aqui salen del propio datashare:
  -- cod_dw_ciudad ES standardizeddanecode (02_vistas_insumo_edf_views.sql:52)
  -- y municipio y departamento vienen estandarizados en la misma vista. Es
  -- mejor dato, no peor: V_GEOGRAFIA llego truncado a 1000 filas.
  --
  -- EL CANAL (descripcion_tipo_ubicacion) SALE DEL TIPO DE LA PROPIA
  -- UBICACION, Y NUNCA DE UN JOIN. El legado lo trae de V_TIPO_UBICACION
  -- unido por UEZ.COD_DW_TIPO_UBICACION (Novedad.sql:7678), que es un
  -- atributo 1:1 de la ubicacion.
  --
  -- SE PROBO DERIVARLO DE v_xpm_contacto_canal Y ESTA MAL POR DOS MOTIVOS.
  -- Medido en el banco: esa vista tiene TRES filas por cod_dw_persona_ubic,
  -- una por canal (contact_type 4, 9 y 10), de modo que el join multiplicaba
  -- la etapa 9 por tres -- 219000 filas para 73000 ids -- que es exactamente
  -- el riesgo de cardinalidad que el legado tampoco acota. Y ademas es otra
  -- pregunta: contacto_canal dice que canales tiene una persona-ubicacion,
  -- no que clase de ubicacion es.
  --
  -- EN NUESTRO MODELO TODA FILA DE RPU ES UNA DIRECCION. Los telefonos, los
  -- celulares y los correos no son filas de relacion_persona_ubicacion: viven
  -- en contacto_canal, que es otra tabla y otro grano. Portar las clases TEL,
  -- CEL y EMAIL exige traerla como FILAS ADICIONALES con UNION ALL, no como
  -- join, y eso cambia el grano del contrato. Queda para la tanda siguiente;
  -- por ahora la clase es DIR y el criterio NOV-UB-07 lo dice.
  --
  -- descripcion_tipo_ubicacion_dir si sale de catalogo, pero OJO: nuestro
  -- bdm_datos.tipo_ubicacion_dir tiene llaves 1..7 y las reales son de cinco
  -- digitos (21478, 21426, 21461...). Esta documentado en
  -- dt/docs/HALLAZGOS_CATALOGOS_REALES.md y la decision tomada fue documentar
  -- y no corregir, porque cambia resultados de procesos ya certificados.
  -- Contra datos reales las banderas es_tipo_* saldran en 0 hasta que se
  -- reconcilie ese catalogo.
  --
  -- zona y tipo de via no tienen catalogo entregado: ver la etapa 9.
  -- ------------------------------------------------------------
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_nov_ubica_e3;
  CREATE TABLE bdm_tempo.stg_mock_nov_ubica_e3
  DISTSTYLE KEY DISTKEY(cod_dw_persona_ubic)
  AS
  SELECT e1.cod_dw_persona_ubic,
         e1.orden_prioridad,
         e1.cod_dw_ubic,
         e1.cod_dw_direccion_fisica,
         e1.cod_dw_tipo_ubicacion_dir,
         e1.id_buro_persona,
         e1.cod_pin_persona,
         e1.cod_tipo_ident_fte,
         e1.ind_unificacion,
         TRIM(COALESCE(ue.texto_ubicacion, ' '))        AS texto_ubicacion,
         ue.cod_dw_ciudad,
         CAST(ue.cod_dw_ciudad AS VARCHAR(20))          AS codigo_dane,
         CAST(CASE WHEN ue.cod_dw_tipo_ubicacion = 9  THEN 'Celular'
                   WHEN ue.cod_dw_tipo_ubicacion = 10 THEN 'Mail'
                   WHEN ue.cod_dw_tipo_ubicacion IN (4, 5) THEN 'Telefono'
                   ELSE 'Geografica'
              END AS VARCHAR(20))                      AS descripcion_tipo_ubicacion,
         tud.descripcion_tipo_ubicacion_dir,
         CAST(ue.municipio    AS VARCHAR(30))           AS ciudad,
         CAST(ue.departamento AS VARCHAR(30))           AS departamento
  FROM   bdm_tempo.stg_mock_nov_ubica_e1 e1
  INNER JOIN bdm_tempo.v_mock_ubicacion_estandarizada ue
         ON ue.cod_dw_ubic = e1.cod_dw_ubic
  LEFT JOIN bdm_datos.tipo_ubicacion_dir tud
         ON tud.cod_dw_tipo_ubicacion_dir = e1.cod_dw_tipo_ubicacion_dir
  WHERE  COALESCE(ue.descripcion_gestion_registro, 'VALIDA') = 'VALIDA';

  -- ------------------------------------------------------------
  -- Pasos 11 y 12 del legado: la direccion fisica (TMP_UBICA_ETAPA_41 y _4).
  -- Novedad.sql:7747-7780 y :7834.
  --
  -- El legado parte en dos: una tabla solo con las direcciones fisicas
  -- (cod_dw_direccion_fisica > -1) y otra que la reintegra por LEFT JOIN.
  -- El resultado neto es un LEFT JOIN con ese predicado dentro, y asi se
  -- escribe: dos materializaciones para un LEFT JOIN son coste sin efecto.
  --
  -- dato = texto de ubicacion mas complemento, con TRIM, igual que :7772.
  -- ------------------------------------------------------------
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_nov_ubica_e4;
  CREATE TABLE bdm_tempo.stg_mock_nov_ubica_e4
  DISTSTYLE KEY DISTKEY(cod_dw_persona_ubic)
  AS
  SELECT e3.cod_dw_persona_ubic,
         e3.orden_prioridad,
         e3.cod_dw_ubic,
         e3.cod_dw_direccion_fisica,
         e3.cod_dw_tipo_ubicacion_dir,
         e3.id_buro_persona,
         e3.cod_pin_persona,
         e3.cod_tipo_ident_fte,
         e3.ind_unificacion,
         e3.texto_ubicacion,
         e3.cod_dw_ciudad,
         e3.codigo_dane,
         e3.descripcion_tipo_ubicacion,
         e3.descripcion_tipo_ubicacion_dir,
         e3.ciudad,
         e3.departamento,
         TRIM(df.complemento)                                           AS complemento,
         TRIM(e3.texto_ubicacion || ' ' || COALESCE(df.complemento,' ')) AS dato
  FROM   bdm_tempo.stg_mock_nov_ubica_e3 e3
  LEFT JOIN bdm_tempo.v_mock_direccion_fisica df
         ON df.cod_dw_direccion_fisica = e3.cod_dw_direccion_fisica
        AND df.cod_dw_ubic             = e3.cod_dw_ubic
        AND e3.cod_dw_direccion_fisica > -1;

  -- ------------------------------------------------------------
  -- Paso 15 del legado: atributos geograficos (TMP_UBICA_ETAPA_6).
  -- Novedad.sql:8031-8070.
  --
  -- DIVERGENCIA 3, segunda aparicion, y es la que mas duele.
  -- El legado toma latitud, longitud, barrio, localidad y codigo postal de
  -- RELACION_UBICAC_ESTANDAR_GEO, y el estrato de V_ESTRATO_DIRECCION. En
  -- Redshift el equivalente es bdm_datos.geo_atributos_mock, que declara barrio y
  -- estrato y NUNCA LOS ESCRIBE: su posicion en el contrato de 32 columnas no
  -- esta pinada (sp_geo_cargar_georreferenciacion.sql:443-446). Localidad y
  -- codigo postal ni siquiera tienen columna.
  --
  -- Las cuatro salen NULL, visibles y justificadas. Latitud y longitud si
  -- salen. El desbloqueo es una peticion del contrato Salida_Geo, no codigo.
  -- Los criterios NOV-UB-21 y NOV-UB-22 estan BLOQUEADO por esto.
  --
  -- El LEFT JOIN toma la fila de lote mas alto con coordenadas, igual que
  -- hace v_xpm_ubicacion_estandarizada (02_vistas_insumo_edf_views.sql:258).
  -- ------------------------------------------------------------
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_nov_ubica_e6;
  CREATE TABLE bdm_tempo.stg_mock_nov_ubica_e6
  DISTSTYLE KEY DISTKEY(cod_dw_persona_ubic)
  AS
  SELECT e4.*,
         -- Sin CAST: geo_atributos ya las trae en DECIMAL(10,6), que es el
         -- tipo del contrato desde la politica de tipos de SLCOPRBA-1355.
         g.latitud,
         g.longitud,
         CAST(NULL AS VARCHAR(100))      AS barrio,         -- BLOQUEADA: contrato GEO sin pinar
         CAST(NULL AS VARCHAR(100))      AS localidad,      -- BLOQUEADA: sin columna de origen
         CAST(NULL AS VARCHAR(20))       AS codigo_postal,  -- BLOQUEADA: sin columna de origen
         CAST(NULL AS VARCHAR(10))       AS estrato         -- BLOQUEADA: contrato GEO sin pinar
  FROM   bdm_tempo.stg_mock_nov_ubica_e4 e4
  LEFT JOIN (
    SELECT cod_dw_ubic, latitud, longitud
    FROM ( SELECT cod_dw_ubic, latitud, longitud,
                  ROW_NUMBER() OVER (PARTITION BY cod_dw_ubic
                                     ORDER BY lote DESC NULLS LAST) AS rn
             FROM bdm_datos.geo_atributos_mock
            WHERE latitud IS NOT NULL AND longitud IS NOT NULL ) z
    WHERE rn = 1
  ) g ON g.cod_dw_ubic = e4.cod_dw_ubic;

  -- ------------------------------------------------------------
  -- Paso 21 del legado: la salida principal (TMP_UBICA_ETAPA_9).
  -- Novedad.sql:8342-8420.
  --
  -- Los pasos 13, 17 y 19 del legado (indicativo, tipo de cuenta, y las dos
  -- homologaciones de tipo y zona) se colapsan aqui porque los cuatro
  -- catalogos que necesitan no se entregaron. Materializar tres tablas para
  -- escribir NULL seria coste sin informacion. Lo que falta, nombrado:
  --   V_TELEFONO_FIJO          -> indicativo      (NOV-UB-19)
  --   V_TIPO_CORREO            -> tipo_cuenta     (NOV-UB-20)
  --   V_Hom_TipoUbic_Dir_Linea -> tipo            (NOV-UB-16)
  --   V_Hom_Zona_Linea         -> zona            (NOV-UB-17)
  --   V_Hom_Tip_Ident_Linea    -> tipo_identif.   (NOV-UB-18)
  --
  -- DIVERGENCIA 1, la de sintaxis. El legado escribe
  --   CASE WHEN V_CARGA_FULL IS NULL THEN 'I' ELSE FLAG_OP1 END AS FLAG_OP
  -- y define FLAG_OP1 dos lineas mas abajo, en el mismo SELECT
  -- (Novedad.sql:8392-8396). Teradata resuelve el alias; Redshift no. El CASE
  -- se repite entero, que es la traduccion fiel y no cambia el resultado.
  --
  -- DIVERGENCIA 4. cod_dw_telefono y cod_dw_direccion_electronica no existen
  -- en edf_views: alli la ubicacion es un contacto tipado, no tres llaves
  -- separadas. Salen NULL.
  --
  -- SEXTA TRAMPA DEL LEGADO, Y ES LA QUE MAS ENGANA: flag_op = 'E' ES CODIGO
  -- MUERTO, y con el la unica via de BAJA de MAT_INFO_UBICACION.
  --
  -- La rama existe y se lee bien (Novedad.sql:8393):
  --     CASE WHEN BLQ.FECHA_BLOQUEO = DATE - INTERVAL '1' DAY THEN 'E' ...
  -- con LEFT JOIN V_BLOQUEO BLQ ON UTP8.COD_DW_PERSONA_UBIC = BLQ.COD_... (:8416).
  -- Pero la etapa 1 ya hizo el ANTI-JOIN contra ESA MISMA TABLA y ESA MISMA
  -- LLAVE (:7590-7594): todo id presente en V_BLOQUEO quedo fuera. De modo que
  -- en la etapa 9 BLQ.FECHA_BLOQUEO es NULL SIEMPRE, la comparacion nunca da
  -- TRUE y 'E' no se emite jamas.
  --
  -- Y arrastra al TPT: Severidad = 2 -- el borrado -- sale UNICAMENTE de
  -- WHEN STG.FLAG_OP = 'E' THEN 2 (120.TPT:163). Sin 'E' no hay Severidad 2,
  -- y el UPSERT de 130.TPT nunca borra una fila. El AS-IS solo inserta y
  -- actualiza.
  --
  -- SE PORTA LITERAL, igual que las otras cinco trampas y por el mismo
  -- criterio (decision SLCOPRBA-1355): la rama se escribe, y como el
  -- anti-join de arriba reproduce el del legado, aqui tampoco se emite nunca.
  -- NO es un defecto del port, y NOV-UB-13 / NOV-UB-15 no se "arreglan"
  -- sembrando un arquetipo de bajas: no les falta dato, verifican una rama
  -- que el legado no puede tomar.
  --
  -- Lo que si es nuestro y se anota: el legado exige ademas que el bloqueo
  -- sea de AYER, y nuestra vista expone el indicador sin fecha. Si algun dia
  -- la etapa 1 dejara de excluir el id, nuestra condicion seria mas ancha.
  -- ------------------------------------------------------------
  TRUNCATE TABLE bdm_tempo.stg_nov_ubica_etapa_9_mock;

  INSERT INTO bdm_tempo.stg_nov_ubica_etapa_9_mock (
    cod_tipo_ident_fte, tipo_identificacion, numero_identificacion, id, orden,
    indicativo, dato, estrato, tipo, zona, ciudad, departamento,
    longitud, latitud, reportado_desde, ultimo_reporte, fuente,
    numero_reportes, numero_entidades, barrio, localidad, codigo_postal,
    clase, info_basica, codigo_dane,
    es_tipo_crr, es_tipo_res, es_tipo_ppl, es_tipo_agn, es_tipo_suc,
    es_tipo_est, es_tipo_cdi, es_tipo_lab, tipo_cuenta,
    cod_dw_ubic, cod_dw_direccion_fisica, cod_dw_telefono,
    cod_dw_direccion_electronica, ind_unificacion, cod_dw_tipo_ubicacion_dir,
    cod_pin_persona, flag_op
  )
  SELECT
    CAST(e6.cod_tipo_ident_fte AS VARCHAR(20)),
    CAST(NULL AS VARCHAR(30)),                          -- BLOQUEADA: falta V_Hom_Tip_Ident_Linea
    e6.cod_pin_persona                                  AS numero_identificacion,
    e6.cod_dw_persona_ubic                              AS id,
    e6.orden_prioridad                                  AS orden,
    CAST(NULL AS VARCHAR(20))                           AS indicativo,   -- BLOQUEADA: falta V_TELEFONO_FIJO
    CAST(CASE WHEN e6.descripcion_tipo_ubicacion = 'Geografica'
              THEN e6.dato ELSE e6.texto_ubicacion END AS VARCHAR(201))  AS dato,
    e6.estrato,
    CAST(NULL AS VARCHAR(30))                           AS tipo,         -- BLOQUEADA: falta V_Hom_TipoUbic_Dir_Linea
    CAST(NULL AS VARCHAR(30))                           AS zona,         -- BLOQUEADA: falta V_Hom_Zona_Linea
    -- 2026-10-21 (D-NOV-05): el centinela '' del legado, COALESCE(CIUDAD,'')
    -- y COALESCE(DEPARTAMENTO,'') (Novedad.sql:8354-8355). Con NULL la etapa 2
    -- no casaba con la agregacion por igualdad y dejaba los dos contadores en
    -- NULL; con '' casa, igual que en el legado.
    COALESCE(e6.ciudad, '')                             AS ciudad,
    COALESCE(e6.departamento, '')                       AS departamento,
    e6.longitud,
    e6.latitud,
    -- Las cinco que el legado emite como literales por esta ruta
    -- (Novedad.sql:8358-8363). Sus valores reales viven en la etapa 2.
    CAST(NULL AS DATE)                                  AS reportado_desde,
    CAST(NULL AS DATE)                                  AS ultimo_reporte,
    CAST(NULL AS INTEGER)                               AS fuente,
    0                                                   AS numero_reportes,
    0                                                   AS numero_entidades,
    e6.barrio,
    e6.localidad,
    e6.codigo_postal,
    CAST(CASE WHEN e6.descripcion_tipo_ubicacion = 'Celular'    THEN 'CEL'
              WHEN e6.descripcion_tipo_ubicacion = 'Mail'       THEN 'EMAIL'
              WHEN e6.descripcion_tipo_ubicacion = 'Geografica' THEN 'DIR'
              WHEN e6.descripcion_tipo_ubicacion = 'Telefono'   THEN 'TEL'
         END AS VARCHAR(5))                             AS clase,
    -- 2026-10-20 (D-NOV-04): BIGINT. id_buro_persona es FNV_HASH(pin), de 64
    -- bits; el CAST a INTEGER abortaba con cualquier dato real.
    CAST(e6.id_buro_persona AS BIGINT)                  AS info_basica,
    COALESCE(e6.codigo_dane, '-1')                      AS codigo_dane,
    CASE WHEN e6.descripcion_tipo_ubicacion_dir = 'CRR' THEN '1' ELSE '0' END AS es_tipo_crr,
    CASE WHEN e6.descripcion_tipo_ubicacion_dir = 'RES' THEN '1' ELSE '0' END AS es_tipo_res,
    CAST(NULL AS VARCHAR(1))                            AS es_tipo_ppl,  -- NULL literal en el legado
    CAST(NULL AS VARCHAR(1))                            AS es_tipo_agn,  -- NULL literal en el legado
    CAST(NULL AS VARCHAR(1))                            AS es_tipo_suc,  -- NULL literal en el legado
    CAST(NULL AS VARCHAR(1))                            AS es_tipo_est,  -- NULL literal en el legado
    CAST(NULL AS VARCHAR(1))                            AS es_tipo_cdi,  -- NULL literal en el legado
    CASE WHEN e6.descripcion_tipo_ubicacion_dir = 'LAB' THEN '1' ELSE '0' END AS es_tipo_lab,
    CAST(NULL AS VARCHAR(1))                            AS tipo_cuenta,  -- BLOQUEADA: falta V_TIPO_CORREO
    e6.cod_dw_ubic,
    e6.cod_dw_direccion_fisica,
    CAST(NULL AS BIGINT)                                AS cod_dw_telefono,              -- sin origen en edf_views
    CAST(NULL AS BIGINT)                                AS cod_dw_direccion_electronica, -- sin origen en edf_views
    e6.ind_unificacion,
    e6.cod_dw_tipo_ubicacion_dir,
    e6.cod_pin_persona,
    CAST(CASE
      WHEN p_modo = 'FULL'            THEN 'I'
      WHEN b.bloqueado = 1            THEN 'E'
      WHEN f.flag_op_delta IS NOT NULL THEN f.flag_op_delta
    END AS VARCHAR(1))                                  AS flag_op
  FROM bdm_tempo.stg_mock_nov_ubica_e6 e6
  LEFT JOIN bdm_tempo.stg_mock_nov_flag_op_ubica f
         ON f.cod_dw_persona_ubic = e6.cod_dw_persona_ubic
  LEFT JOIN ( SELECT cod_dw_persona_ubic, MAX(bloqueado) AS bloqueado
                FROM bdm_tempo.v_mock_relacion_persona_ubicacion
               GROUP BY 1 ) b
         ON b.cod_dw_persona_ubic = e6.cod_dw_persona_ubic;

  -- ------------------------------------------------------------
  -- Pasos 23 y 24 del legado: las dos agregaciones y la etapa 2.
  -- Novedad.sql:8497-8530, :8571 y :8624-8671.
  --
  -- TRAMPA DEL LEGADO QUE SE PORTA LITERAL. La etapa 9 escribe '' para ciudad
  -- y departamento y '-1' para el DANE; las dos agregaciones escriben 'SV'
  -- para los tres (Novedad.sql:8502-8504). La etapa 2 une por igualdad en
  -- esas tres columnas (:8649-8651). En el legado no rompe porque la etapa 9
  -- ya aplico el COALESCE y nunca llega un NULL; aqui tampoco desde el
  -- 2026-10-21 (D-NOV-05), que la etapa 9 escribe el mismo ''.
  --
  -- DIVERGENCIA 5. El legado separa el primer reporte del ultimo con
  -- ID_FLAG_DESDE (Novedad.sql:8636-8637). Nuestra vista de reportes no trae
  -- esa bandera, de modo que se usan MIN y MAX de fecha_reporte, que es lo
  -- que la bandera marca.
  --
  -- Y LA FUENTE (T5, D-NOV-03, 2026-10-21). El legado escribe
  --   COALESCE(COALESCE(VFT.DESCRIPCION_FUENTE,'CAM'), h2.Descripcion_Hom...)
  -- (Novedad.sql:8635). El COALESCE interno nunca devuelve NULL, de modo que
  -- la homologacion a Linea JAMAS se aplica -- eso sigue siendo codigo muerto
  -- y no se porta --, PERO la fuente no sale siempre 'CAM': sale de V_FUENTE
  -- y 'CAM' solo cuando no hay coincidencia.
  --
  -- NO TENEMOS V_FUENTE NI cod_dw_fuente, asi que la fuente se deriva del
  -- typeOfData en v_xpm_reporte_relacion_persona_ubica: los tipos de
  -- suscriptor (1, 2, 3 y 17) dan 'SUS' y el resto 'CAM'. Decision del
  -- usuario del 2026-10-21. Es divergencia de ORIGEN, no de valor.
  --
  -- Y ESO DEVUELVE EL GRANO DEL LEGADO, que es lo que de verdad estaba mal.
  -- El GROUP BY de abajo incluye la fuente en la posicion 11, igual que
  -- Novedad.sql:8670: con un literal constante el grano colapsaba a una fila
  -- por RPU, y ahora es UNA FILA POR RPU Y FUENTE.
  --
  -- cod_dw_fuente sigue en NULL: es el codigo de la fuente en el catalogo del
  -- legado y no tiene equivalente en el datashare. No se inventa.
  -- ------------------------------------------------------------
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_nov_ubica_agr;
  CREATE TABLE bdm_tempo.stg_mock_nov_ubica_agr
  DISTSTYLE KEY DISTKEY(id_buro_persona)
  AS
  SELECT e9.info_basica                        AS id_buro_persona,
         e9.cod_pin_persona,
         e9.dato,
         COALESCE(e9.ciudad,       'SV')       AS ciudad,
         COALESCE(e9.departamento, 'SV')       AS departamento,
         COALESCE(e9.codigo_dane,  'SV')       AS codigo_dane,
         COUNT(DISTINCT r.id_buro_suscriptor)  AS numero_entidades,
         COUNT(*)                              AS numero_reportes
  FROM   bdm_tempo.stg_nov_ubica_etapa_9_mock e9
  INNER JOIN bdm_tempo.v_mock_reporte_relacion_persona_ubica r
         ON r.cod_dw_persona_ubic = e9.id
  GROUP BY 1, 2, 3, 4, 5, 6;

  TRUNCATE TABLE bdm_tempo.stg_nov_ubica_etapa_2_mock;

  INSERT INTO bdm_tempo.stg_nov_ubica_etapa_2_mock (
    tipo_identificacion, numero_identificacion, info_basica, cod_pin_persona,
    dato, cod_dw_fuente, id, ciudad, departamento, codigo_dane, fuente,
    reportado_desde, ultimo_reporte, numero_entidades, numero_reportes
  )
  SELECT e9.tipo_identificacion,
         e9.numero_identificacion,
         e9.info_basica,
         e9.cod_pin_persona,
         e9.dato,
         CAST(NULL AS INTEGER)            AS cod_dw_fuente,  -- sin origen en la vista de reportes
         e9.id,
         e9.ciudad,
         e9.departamento,
         e9.codigo_dane,
         r.fuente                         AS fuente,         -- ver la nota de la fuente, arriba
         MIN(r.fecha_reporte)             AS reportado_desde,
         MAX(r.fecha_reporte)             AS ultimo_reporte,
         MAX(a.numero_entidades)          AS numero_entidades,
         MAX(a.numero_reportes)           AS numero_reportes
  FROM   bdm_tempo.stg_nov_ubica_etapa_9_mock e9
  INNER JOIN bdm_tempo.v_mock_reporte_relacion_persona_ubica r
         ON r.cod_dw_persona_ubic = e9.id
  LEFT JOIN bdm_tempo.stg_mock_nov_ubica_agr a
         ON  a.id_buro_persona = e9.info_basica
         AND a.cod_pin_persona = e9.cod_pin_persona
         AND a.dato            = e9.dato
         AND a.ciudad          = e9.ciudad
         AND a.departamento    = e9.departamento
         AND a.codigo_dane     = e9.codigo_dane
  GROUP BY 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11;

  -- ------------------------------------------------------------
  -- Limpieza del staging intermedio. Las dos tablas de contrato NO se tocan:
  -- son la salida y las leen los otros procedimientos del dominio.
  -- ------------------------------------------------------------
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_nov_flag_op_ubica;
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_nov_ubica_e1;
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_nov_ubica_e3;
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_nov_ubica_e4;
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_nov_ubica_e6;
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_nov_ubica_agr;

END;
$$;
