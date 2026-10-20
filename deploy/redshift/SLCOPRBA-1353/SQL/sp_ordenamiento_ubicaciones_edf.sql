-- ============================================================
-- sp_ordenamiento_ubicaciones_edf.sql
-- SLCOPRBA-1355: FASE 3 del Ordenamiento -- deteccion de cambios por hash.
-- Legado: PRO_ORD_CONCAT_DIRECCIONES (arma el concatena y el MD5) y
-- PRO_ORD_FINAL_UBIC_DIRECCIONES (persiste en UBICACION_ATRIBUTO_HASH).
-- Copia del legado en dt/docs/legado_ordenamiento_f1_f3/.
-- Criterios F3-03..F3-07. UTF-8 sin BOM, ASCII sin acentos.
--
-- ------------------------------------------------------------
-- EL LEGADO SE CONTRADICE A SI MISMO Y HAY QUE SABERLO ANTES DE LEER ESTO.
--
-- Existen DOS versiones del mismo paso:
--   PRO_ORD_FINAL_UBIC_DIRECCIONES   -- el UPDATE esta COMENTADO
--   PRO_ORD_FINAL_UBIC_DIRECCIONES1  -- el UPDATE esta vivo
--
-- El comentario que lo desactiva no es casual ni es basura de edicion:
-- "Por solicitud de Experian se deja en comentario esta parte del codigo
-- Puesto no se va a necesitar" (FINAL_UBIC_DIRECCIONES.sql:216), y la MISMA
-- frase aparece en FINAL_CTA_ATRIBUTOS.sql:200, que es la tabla de hash de la
-- Fase 2. Dos archivos distintos, la misma decision: es una peticion real del
-- negocio, no un descuido.
--
-- Ademas, de los dos solo FINAL_UBIC_DIRECCIONES lleva entrada de bitacora de
-- mantenimiento (2018-09-26, "Se agrega IN P_VARQUERY"), lo que apunta a que
-- es el vigente y el otro una copia.
--
-- SE PORTA LA VERSION SIN UPDATE: la tabla es INSERT-ONLY.
-- NO es prueba cerrada -- el CALL vive en la malla, que no esta en el
-- material entregado --, y por eso queda escrito aqui. Si aparece la malla,
-- se revisa contra ella.
--
-- CONSECUENCIA, Y ES LA QUE CAMBIA UN CRITERIO: una direccion que cambia NO
-- actualiza su fila, deja una SEGUNDA con el hash nuevo. F3-06 dice "los
-- registros modificados se deben actualizar", y esa rama es codigo muerto en
-- el AS-IS. Es el mismo caso de NOV-UB-13 y NOV-UB-15 en Novedades, que
-- verificaban una rama que el legado no puede tomar: el criterio se evalua
-- contra la paridad REAL -- el cambio queda registrado y la fila anterior no
-- se toca -- y no contra una conducta que Teradata no ejecuta.
--
-- LA LLAVE DEL ANTI-JOIN SON CUATRO COLUMNAS, LA DE LA ENTIDAD TRES.
-- F3-07 nombra tres: cod_pin_persona, id_buro_persona, cod_dw_persona_ubic.
-- El hash es la cuarta del anti-join, la que decide si la COMBINACION es
-- nueva. Confundirlas haria que una direccion cambiada no se registrara.
--
-- EL CONCATENA DEL LEGADO TIENE DOCE COLUMNAS Y AQUI HAY SIETE CON DATO.
-- Las otras cinco van con el centinela ''0'' del propio legado, que es lo que
-- este usa para un nulo. Se mantienen EN SU SITIO y en el ORDEN original para
-- que el dia que el dato exista el hash cambie en una sola linea y se vea en
-- el diff. Las cinco, y por que:
--   descripcion_gestion_registro -- la nuestra es una sintesis heuristica, no
--                                   el estado de gestion por reporte
--   desc_tipo_cta                -- necesita las cuentas de la Fase 2
--   urbanizacion_barrio          -- no existe en nuestro modelo
--   cod_dane_departamento        -- solo esta en el mock, no en el datashare
--   (las coordenadas SI entran: salen de la ubicacion estandarizada)
--
-- EL MD5 NO PUEDE LEER EL ALIAS 'concatena' DE SU PROPIO SELECT. El legado
-- escribe rec_vista.hash_md5(concatena) referenciando el alias de la columna
-- de al lado; Teradata lo resuelve y Redshift NO -- la misma trampa que
-- FLAG_OP en Novedades (Novedad.sql:8392-8396). Por eso el concatena se arma
-- en una subconsulta y el MD5 se aplica fuera.
--
-- NONATOMIC (leccion #13). Sin parametros: lo llama el ciclo, que ya resolvio
-- modo, lote y watermark. Rollback: DROP PROCEDURE con firma exacta (#12/#14).
-- ============================================================

CREATE OR REPLACE PROCEDURE bdm_datos.sp_ordenamiento_ubicaciones_edf(
  p_lote INTEGER
)
NONATOMIC
LANGUAGE plpgsql
AS $$
BEGIN

  -- Limpieza del insumo de canal, que ahora produce esta fase.
  DROP TABLE IF EXISTS bdm_tempo.stg_insumo_email;
  DROP TABLE IF EXISTS bdm_tempo.stg_insumo_celular;
  DROP TABLE IF EXISTS bdm_tempo.stg_insumo_telefono;
  DROP TABLE IF EXISTS bdm_tempo.stg_insumo_direccion;

  -- ------------------------------------------------------------
  -- FASE A DEL RECABLEADO (SLCOPRBA-1355): LOS CUATRO INSUMOS DE CANAL SE
  -- PRODUCEN AQUI, NO EN preparar_insumos, Y ES PARIDAD CON EL LEGADO.
  --
  -- En Teradata el scoring NO lee el datashare: lee lo que deja la Fase 3.
  -- Caracteristicas.txt arranca cada canal de una vista de DIRECCIONES_TEMP,
  -- que es la tabla que crea PRO_ORD_CALC_UBICACIONES_2.sql:1234 (PASO20):
  --   _DF direccion fisica   _TF telefono fijo
  --   _TM telefono movil     _ML correo
  -- De ahi que Direccion_Fisica lleve el telefono en el canal TEL.
  --
  -- Antes de esto los cuatro los creaba preparar_insumos y la Fase 3 solo
  -- escribia su tabla de hash, de modo que el scoring no dependia de la Fase
  -- 3 para nada: la dependencia del legado no existia en el port. Ahora si.
  --
  -- LO QUE NO CAMBIA, Y ES LA PRUEBA DE ESTA FASE: las cuatro sentencias
  -- estan MOVIDAS, no reescritas -- misma proyeccion, mismo grano, mismos
  -- joins y mismos nombres de tabla. Por eso el score no se mueve ni una
  -- milesima, y eso se mide con la foto de score_ordenamiento.
  --
  -- POR QUE SIGUEN SIENDO CUATRO TABLAS Y NO UNA BASE CON CUATRO VISTAS.
  -- En el legado los cuatro canales viven en DIRECCIONES_TEMP porque alli una
  -- fila es un reporte de ubicacion de cualquier clase. En nuestro modelo no:
  -- las direcciones salen de contacto_direccion y los telefonos, celulares y
  -- correos de contacto_canal, que es otra tabla y otro grano -- esta escrito
  -- en CLAUDE.md y ya costo un fan-out de 219.000 filas para 73.000 ids.
  -- Unificarlas pide un UNION ALL, que es un cambio de contenido y no de
  -- cableado. Queda fuera de esta fase a proposito.
  -- ------------------------------------------------------------

  -- 8) Insumo DIR
  CREATE TABLE bdm_tempo.stg_insumo_direccion
  DISTSTYLE KEY
  DISTKEY (id_buro_persona)
  SORTKEY (id_buro_persona, cod_pin_persona)
  AS
  SELECT
    rpu.cod_dw_persona_ubic,
    rpu.cod_pin_persona,
    rpu.id_buro_persona,
    cd.texto_ubicacion AS direccion_fisica,
    cd.complemento,
    tud.descripcion_tipo_ubicacion_dir AS tipo_ubicacion,
    cd.cod_dw_ciudad AS cod_dane_ciudad,
    rep.id_buro_suscriptor,
    rep.fecha_reporte,
    GREATEST(DATEDIFF(month, rep.fecha_reporte, CURRENT_DATE), 0) AS meses_reporte,
    COALESCE(sf.sector_financiero, 0) AS sector_financiero,
    -- SLCOPRBA-1355: Portafolio_Nuevo y Sector del legado
    -- (PRO_ORD_CTA_TOTALES_PERSONAS_2.sql:378-396).
    --   El ORDEN de las ramas es parte de la definicion: RO e IN por prefijo
    --   van ANTES de la lista VE, y el resto de prefijos despues. Por eso el
    --   codigo 050058, que esta en la lista VE del legado, clasifica 'IN':
    --   es un condicional muerto del legado y se porta tal cual.
    --   La comparacion es NUMERICA, no de texto: en el legado los literales
    --   van sin comillas y Teradata coacciona, de modo que los ceros a la
    --   izquierda son irrelevantes. Un codigo no numerico cae a 'OT'.
    --   La rama 'CO' no se construye: exige las banderas de comportamiento
    --   de cuenta de la Fase 2. Una cuenta que seria 'CO' cae a su prefijo.
    CASE
      WHEN pp_ro.portafolio IS NOT NULL THEN pp_ro.portafolio
      WHEN pve.cod_suscriptor IS NOT NULL THEN 'VE'
      WHEN pp.portafolio IS NOT NULL THEN pp.portafolio
      ELSE 'OT'
    END AS portafolio_nuevo,
    CASE
      WHEN pp_ro.portafolio IS NOT NULL AND pp_ro.portafolio IN ('RO','IN') THEN 'FI'
      WHEN pve.cod_suscriptor IS NOT NULL THEN 'FI'
      WHEN pp.portafolio IN ('CC')                THEN 'CC'
      WHEN pp.portafolio IN ('RC','RS')           THEN 'RE'
      WHEN pp.portafolio IN ('HP','CP','FR')      THEN 'FI'
      ELSE 'OT'
    END AS sector,
    dir_cnt.conteo_direcciones
  FROM bdm_tempo.stg_rpu_post_unificacion rpu
  INNER JOIN bdm_tempo.stg_contacto_direccion_rpu cd
    ON cd.cod_dw_persona_ubic = rpu.cod_dw_persona_ubic
  INNER JOIN bdm_datos.tipo_ubicacion_dir tud
    ON cd.cod_dw_tipo_ubicacion_dir = tud.cod_dw_tipo_ubicacion_dir
  INNER JOIN bdm_tempo.stg_reporte_rpu rep
    ON rpu.cod_dw_persona_ubic = rep.cod_dw_persona_ubic
  LEFT JOIN bdm_datos.catalogo_sector_financiero sf
    ON sf.id_buro_suscriptor = rep.id_buro_suscriptor
  INNER JOIN bdm_tempo.stg_dir_conteo_persona dir_cnt
    ON dir_cnt.id_buro_persona = rpu.id_buro_persona
  LEFT JOIN bdm_datos.catalogo_portafolio_prefijo pp_ro
    ON pp_ro.prefijo = LEFT(LPAD(TRIM(rep.cod_suscriptor), 6, '0'), 2)
   AND pp_ro.portafolio IN ('RO','IN')
  -- La comparacion es numerica porque en el legado los literales del CASE
  -- van sin comillas y Teradata coacciona: '040003' y 40003 son el mismo
  -- codigo. Se normaliza con LPAD a seis en vez de castear, que es lo que
  -- evita el desbordamiento del job #293 -- un codigo de mas de 18 digitos
  -- reventaria un CAST a BIGINT y aqui simplemente no casa.
  LEFT JOIN bdm_datos.catalogo_portafolio_ve pve
    ON LPAD(TRIM(rep.cod_suscriptor), 6, '0') = LPAD(TRIM(pve.cod_suscriptor), 6, '0')
   AND TRIM(rep.cod_suscriptor) ~ '^[0-9]+$'
   AND LENGTH(TRIM(rep.cod_suscriptor)) <= 6
  LEFT JOIN bdm_datos.catalogo_portafolio_prefijo pp
    ON pp.prefijo = LEFT(LPAD(TRIM(rep.cod_suscriptor), 6, '0'), 2)
   AND pp.portafolio NOT IN ('RO','IN')

  WHERE COALESCE(rpu.ind_unificacion, 0) <> 1;

  ANALYZE bdm_tempo.stg_insumo_direccion;

  -- 9) Insumo TEL
  CREATE TABLE bdm_tempo.stg_insumo_telefono
  DISTSTYLE KEY
  DISTKEY (id_buro_persona)
  SORTKEY (id_buro_persona, cod_pin_persona)
  AS
  SELECT
    c.cod_dw_persona_ubic,
    c.cod_pin_persona,
    c.id_buro_persona,
    COALESCE(rref.dir_ref, c.texto_ubicacion_vinculo, c.valor_contacto) AS direccion_fisica,
    -- SLCOPRBA-1355: EL TELEFONO ES LA LLAVE DEL CANAL, NO LA DIRECCION.
    --
    --   En el legado la columna se llama Direccion_Fisica pero contiene el
    --   numero: REC_STAGE.Calculo_Meses2 (Caracteristicas.txt:2252-2262)
    --   agrupa por (Cod_Pin_Persona, Id_Buro_Persona, Direccion_Fisica) y al
    --   resultado lo llama Total_Reportes_Telefono. EMA lo hace explicito con
    --   un alias, "TML.Direccion_Fisica as Email" (:2764): es el nombre de
    --   columna de la vista de origen reutilizado para el dato de contacto de
    --   cada canal.
    --
    --   direccion_fisica se CONSERVA: la sigue usando el desempate del
    --   ranking, y sacarla cambiaria el orden sin motivo.
    c.valor_contacto AS telefono,
    -- Tipo de ubicacion del reporte, para CO01TEL017 ('RES') y CO01TEL019
    -- ('LAB'), que el legado toma de TMP_DIRECCIONES_TEMP_TF (:2085-2091).
    --
    --   DIVERGENCIA ANOTADA: el legado une por
    --   (Cod_DW_Reporte_Persona_Ubic, Cod_DW_TIpo_Ubicacion_Dir), es decir el
    --   tipo DE CADA FILA DE REPORTE. Nuestras filas de contacto no llevan
    --   tipo propio -- v_xpm_contacto_canal sale de
    --   location.val.contactinformations y no lo expone -- asi que se toma el
    --   de la RPU de la que cuelga el contacto. El GROUP BY del subselect
    --   garantiza que no haya fan-out si una RPU trae varias filas.
    COALESCE(tud.descripcion_tipo_ubicacion_dir, '') AS tipo_ubicacion,
    c.cod_dane_ciudad,
    CASE
      WHEN c.valor_contacto ~ '^[0-9]+$' AND LENGTH(TRIM(c.valor_contacto)) >= 7 THEN 'VALIDA'
      ELSE 'NO VALIDA'
    END AS descripcion_gestion,
    c.id_buro_suscriptor,
    COALESCE(c.fecha_contacto, CURRENT_DATE) AS fecha_reporte,
    GREATEST(DATEDIFF(month, COALESCE(c.fecha_contacto, CURRENT_DATE), CURRENT_DATE), 0) AS meses_reporte,
    0 AS coincidencia_geo,
    COALESCE(sf.sector_financiero, 0) AS sector_financiero,
    COALESCE(tcat.tipo_cuenta, 'FIJA') AS tipo_cuenta
  FROM bdm_tempo.stg_contacto_canal c
  LEFT JOIN bdm_datos.catalogo_sector_financiero sf
    ON sf.id_buro_suscriptor = c.id_buro_suscriptor
  LEFT JOIN bdm_datos.catalogo_tipo_cuenta_tel tcat
    ON tcat.prefijo_operador = LEFT(LTRIM(c.valor_contacto, '0'), 3)
  LEFT JOIN bdm_tempo.stg_rpu_dir_ref rref
    ON rref.cod_dw_persona_ubic = c.cod_dw_persona_ubic
  LEFT JOIN (
    SELECT cd.cod_dw_persona_ubic,
           MAX(cd.cod_dw_tipo_ubicacion_dir) AS cod_dw_tipo_ubicacion_dir
    FROM bdm_tempo.stg_contacto_direccion_rpu cd
    GROUP BY 1
  ) ctu
    ON ctu.cod_dw_persona_ubic = c.cod_dw_persona_ubic
  LEFT JOIN bdm_datos.tipo_ubicacion_dir tud
    ON tud.cod_dw_tipo_ubicacion_dir = ctu.cod_dw_tipo_ubicacion_dir
  -- 2026-10-20 (D-EDF-08): sin el 8, que en el datashare es direccion
  -- (standardizedtipo VIA, RURAL, MANZANA..., C6b). El espejo mock conserva
  -- la lista anterior sin efecto: sus semillas solo siembran el 4 como
  -- telefono (seed_mock_matriz.sql:347).
  WHERE c.contact_type IN ('4', '5')
    AND c.valor_contacto IS NOT NULL;

  ANALYZE bdm_tempo.stg_insumo_telefono;

  -- 10) Insumo CEL
  CREATE TABLE bdm_tempo.stg_insumo_celular
  DISTSTYLE KEY
  DISTKEY (id_buro_persona)
  SORTKEY (id_buro_persona, cod_pin_persona)
  AS
  SELECT
    c.cod_dw_persona_ubic,
    c.cod_pin_persona,
    c.id_buro_persona,
    -- SLCOPRBA-1355: el LTRIM de ceros era invencion nuestra. El legado
    -- agrupa por Texto_Ubicacion EN CRUDO y saca el prefijo de operador con
    -- SUBSTR(Texto_Ubicacion, 1, 3) (Caracteristicas.txt:912), sin
    -- normalizar: un grep de 'ltrim' sobre el volcado entero da cero.
    -- Importaba doble: el prefijo normalizado podia caer fuera del catalogo
    -- de operadores y la compuerta CEL018 <> 0 sacaba ese celular del
    -- ranking entero. En el mock no hay celulares con cero inicial, asi que
    -- el cambio es inerte ahi y fiel en datos reales.
    c.valor_contacto AS celular,
    COALESCE(ref.dir_ref, c.texto_ubicacion_vinculo) AS texto_ubicacion,
    c.id_buro_suscriptor,
    -- SLCOPRBA-1355: CEL023 filtra por gestion en el numerador Y en el
    -- divisor (Caracteristicas.txt:1566-1568 y :3133-3135) y hasta ahora no
    -- viajaba al canal. Misma expresion que en el insumo de telefono: para
    -- un celular de diez digitos el heuristico de ">=7 digitos numericos" si
    -- significa algo. NO vale para el canal DIR, donde una direccion nunca
    -- es una cadena de digitos y marcaria 'NO VALIDA' a todas.
    CASE
      WHEN c.valor_contacto ~ '^[0-9]+$' AND LENGTH(TRIM(c.valor_contacto)) >= 7 THEN 'VALIDA'
      ELSE 'NO VALIDA'
    END AS descripcion_gestion,
    COALESCE(c.fecha_contacto, CURRENT_DATE) AS fecha_reporte,
    GREATEST(DATEDIFF(month, COALESCE(c.fecha_contacto, CURRENT_DATE), CURRENT_DATE), 0) AS meses_reporte,
    LEFT(c.valor_contacto, 3) AS operador,
    COALESCE(sf.sector_financiero, 0) AS sector_financiero,
    COALESCE(tcat.tipo_cuenta, 'PREPAGO') AS tipo_cuenta,
    -- SLCOPRBA-1355: tipo de cuenta que reporto el celular. Lo consume
    -- CEL019 contra bdm_datos.catalogo_tipo_cuenta_ord. Viaja en crudo:
    -- el CAST a INTEGER se hace en el scoring, que es donde lo hace el
    -- legado (Caracteristicas.txt:112).
    c.cod_tipo_cta_fte
  FROM bdm_tempo.stg_contacto_canal c
  LEFT JOIN bdm_datos.catalogo_sector_financiero sf
    ON sf.id_buro_suscriptor = c.id_buro_suscriptor
  LEFT JOIN bdm_datos.catalogo_tipo_cuenta_tel tcat
    ON tcat.prefijo_operador = LEFT(c.valor_contacto, 3)
  LEFT JOIN bdm_tempo.stg_persona_dir_ref ref
    ON ref.id_buro_persona = c.id_buro_persona
  WHERE c.contact_type = '9'
    AND c.valor_contacto IS NOT NULL;

  ANALYZE bdm_tempo.stg_insumo_celular;

  -- 11) Insumo EMA
  CREATE TABLE bdm_tempo.stg_insumo_email
  DISTSTYLE KEY
  DISTKEY (id_buro_persona)
  SORTKEY (id_buro_persona, cod_pin_persona)
  AS
  SELECT
    c.cod_dw_persona_ubic,
    c.cod_pin_persona,
    c.id_buro_persona,
    LOWER(TRIM(c.valor_contacto)) AS email,
    LOWER(SPLIT_PART(TRIM(c.valor_contacto), '@', 2)) AS dominio,
    c.id_buro_suscriptor,
    COALESCE(c.fecha_contacto, CURRENT_DATE) AS fecha_reporte,
    GREATEST(DATEDIFF(month, COALESCE(c.fecha_contacto, CURRENT_DATE), CURRENT_DATE), 0) AS meses_reporte,
    COALESCE(sf.sector_financiero, 0) AS sector_financiero,
    CASE WHEN LOWER(SPLIT_PART(TRIM(c.valor_contacto), '@', 2)) IN
      ('gmail.com','hotmail.com','yahoo.com','outlook.com') THEN 'PERSONAL' ELSE 'CORPORATIVO' END AS tipo_cuenta,
    -- SLCOPRBA-1355: tipo de cuenta que reporto el correo. Lo consume
    -- EMA021 (Caracteristicas.txt:235). En crudo, porque una de sus cinco
    -- ramas compara en TEXTO y las otras cuatro castean: ver el scoring.
    c.cod_tipo_cta_fte
  FROM bdm_tempo.stg_contacto_canal c
  LEFT JOIN bdm_datos.catalogo_sector_financiero sf
    ON sf.id_buro_suscriptor = c.id_buro_suscriptor
  WHERE c.contact_type = '10'
    AND c.valor_contacto LIKE '%@%';

  ANALYZE bdm_tempo.stg_insumo_email;

  DROP TABLE IF EXISTS bdm_tempo.stg_ord_ubic_hash;

  -- Una fila por direccion del alcance, con su tipo de persona y su MD5.
  --
  -- tipo_persona (F3-03) sale de cod_tipo_ident_fte, que es lo que tenemos:
  -- el legado lo toma de V_Tipo_persona por Cod_DW_Tipo_Persona, un catalogo
  -- que no esta en el datashare. NIT es juridica; el resto, natural. El
  -- COALESCE final evita el NULL que F3-03 prohibe.
  CREATE TABLE bdm_tempo.stg_ord_ubic_hash
  DISTSTYLE KEY
  DISTKEY (cod_dw_persona_ubic)
  SORTKEY (id_buro_persona, cod_dw_persona_ubic)
  AS
  SELECT x.cod_pin_persona,
         x.id_buro_persona,
         x.cod_dw_persona_ubic,
         x.tipo_persona,
         MD5(x.concatena) AS cod_hash
  FROM (
    SELECT d.cod_pin_persona,
           d.id_buro_persona,
           d.cod_dw_persona_ubic,
           COALESCE( CASE WHEN UPPER(TRIM(COALESCE(rpu.cod_tipo_ident_fte, ''))) IN ('2', 'NIT')
                          THEN 'JURIDICA' ELSE 'NATURAL' END, 'NATURAL') AS tipo_persona,
           -- Orden y centinela del legado (PRO_ORD_CONCAT_DIRECCIONES:108-120).
                 COALESCE(CAST(TRIM(d.direccion_fisica) AS VARCHAR(100)), '0')
              || COALESCE(CAST(TRIM(d.tipo_ubicacion)   AS VARCHAR(200)), '0')
              || '0'                                      -- gestion_registro
              || COALESCE(CAST(TRIM(CAST(d.cod_dane_ciudad AS VARCHAR)) AS VARCHAR(20)), '0')
              || '0'                                      -- dane_departamento
              || COALESCE(CAST(TRIM(CASE WHEN UPPER(TRIM(COALESCE(rpu.cod_tipo_ident_fte, ''))) IN ('2', 'NIT')
                                         THEN 'JURIDICA' ELSE 'NATURAL' END) AS VARCHAR(500)), '0')
              || '0'                                      -- desc_tipo_cta
              || COALESCE(CAST(TRIM(d.direccion_fisica) AS VARCHAR(201)), '0')
              || COALESCE(CAST(TRIM(d.complemento)      AS VARCHAR(100)), '0')
              || '0'                                      -- urbanizacion_barrio
              || COALESCE(CAST(TRIM(CAST(ue.latitud  AS VARCHAR)) AS VARCHAR(50)), '0')
              || COALESCE(CAST(TRIM(CAST(ue.longitud AS VARCHAR)) AS VARCHAR(50)), '0')
             AS concatena
      FROM bdm_tempo.stg_insumo_direccion d
      INNER JOIN bdm_tempo.stg_rpu_post_unificacion r
              ON r.cod_dw_persona_ubic = d.cod_dw_persona_ubic
      LEFT JOIN bdm_tempo.v_xpm_relacion_persona_ubicacion rpu
             ON rpu.cod_dw_persona_ubic = d.cod_dw_persona_ubic
      LEFT JOIN bdm_tempo.v_xpm_ubicacion_estandarizada ue
             ON ue.cod_dw_ubic = r.cod_dw_ubic
  ) x
  GROUP BY x.cod_pin_persona, x.id_buro_persona, x.cod_dw_persona_ubic,
           x.tipo_persona, x.concatena;

  ANALYZE bdm_tempo.stg_ord_ubic_hash;

  -- F3-05. Lo nuevo entra. El anti-join lleva las CUATRO columnas, hash
  -- incluido (PRO_ORD_FINAL_UBIC_DIRECCIONES:125-133): una direccion cuyo
  -- hash cambio no encuentra pareja y entra como fila nueva, que es como el
  -- AS-IS registra el cambio.
  INSERT INTO bdm_datos.ubicacion_atributo_hash
    (cod_pin_persona, id_buro_persona, cod_dw_persona_ubic,
     cod_dw_hash, fecha_nov, tipo_persona, lote, usuario_bd)
  SELECT a.cod_pin_persona, a.id_buro_persona, a.cod_dw_persona_ubic,
         a.cod_hash, CURRENT_DATE, a.tipo_persona, p_lote, CURRENT_USER
    FROM bdm_tempo.stg_ord_ubic_hash a
    LEFT JOIN bdm_datos.ubicacion_atributo_hash b
           ON  b.cod_pin_persona     = a.cod_pin_persona
           AND b.id_buro_persona     = a.id_buro_persona
           AND b.cod_dw_persona_ubic = a.cod_dw_persona_ubic
           AND b.cod_dw_hash         = a.cod_hash
   WHERE b.cod_dw_persona_ubic IS NULL;

END;
$$;
