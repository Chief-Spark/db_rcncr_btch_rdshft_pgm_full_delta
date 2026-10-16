-- ============================================================
-- 05_sp_preparar_insumos_edf.sql
-- Staging TEMPORAL por corrida: 1 lectura datashare -> tablas stg_* locales.
-- No persiste entre ejecuciones (drop al final de sp_ordenamiento_ejecucion_edf).
-- Misma logica que vistas bdm_datos.insumo_* en 04_vistas_sin_copia_productor.sql
-- ============================================================

CREATE OR REPLACE PROCEDURE bdm_datos.sp_ordenamiento_preparar_insumos_edf(
  p_modo      VARCHAR,   -- FULL | DELTA (modo efectivo)
  p_lote      INTEGER,   -- Lote_Corrida externo (no asumir 1)
  p_watermark DATE       -- frontera inferior inclusiva DELTA (NULL en Bootstrap FULL)
)
NONATOMIC
LANGUAGE plpgsql
AS $$
BEGIN
  -- Limpieza staging previo
  DROP TABLE IF EXISTS bdm_tempo.stg_insumo_email;
  DROP TABLE IF EXISTS bdm_tempo.stg_insumo_celular;
  DROP TABLE IF EXISTS bdm_tempo.stg_insumo_telefono;
  DROP TABLE IF EXISTS bdm_tempo.stg_insumo_direccion;
  DROP TABLE IF EXISTS bdm_tempo.stg_contacto_canal;
  DROP TABLE IF EXISTS bdm_tempo.stg_reporte_rpu;
  DROP TABLE IF EXISTS bdm_tempo.stg_contacto_direccion_rpu;
  DROP TABLE IF EXISTS bdm_tempo.stg_persona_dir_ref;
  DROP TABLE IF EXISTS bdm_tempo.stg_rpu_dir_ref;
  DROP TABLE IF EXISTS bdm_tempo.stg_dir_conteo_persona;
  DROP TABLE IF EXISTS bdm_tempo.stg_persona_dir_ganadora;
  DROP TABLE IF EXISTS bdm_tempo.stg_rpu_post_unificacion;
  DROP TABLE IF EXISTS bdm_tempo.stg_ord_personas_alcance;

  -- Universo de personas a (re)ordenar.
  -- FULL: todas las personas con RPU en el datashare.
  -- DELTA: personas tocadas por ventana RPU o por unificacion del lote/fecha
  --        (tabla acumulada; NO asumir TRUNCATE ni lote=1).
  CREATE TABLE bdm_tempo.stg_ord_personas_alcance
  DISTSTYLE KEY
  DISTKEY (id_buro_persona)
  SORTKEY (id_buro_persona)
  AS
  SELECT DISTINCT x.id_buro_persona
  FROM (
    SELECT rpu.id_buro_persona
    FROM bdm_tempo.v_xpm_relacion_persona_ubicacion rpu
    WHERE COALESCE(p_modo, 'FULL') = 'FULL'
       OR rpu.fecha_relacion_persona_ubicaci >= p_watermark
       OR rpu.fecha_relacion_persona_ubicaci IS NULL
    UNION
    SELECT rpu.id_buro_persona
    FROM bdm_tempo.v_xpm_relacion_persona_ubicacion rpu
    INNER JOIN bdm_datos.unificacion_direccion u
      ON u.cod_dw_persona_ubic = rpu.cod_dw_persona_ubic
    WHERE COALESCE(p_modo, 'FULL') = 'DELTA'
      AND (
            -- SLCOPRBA-1355: desde el UPSERT fiel al legado, 'lote' es INMUTABLE
            -- (identifica la corrida que CREO la unificacion) y 'fecha_unificacion'
            -- tampoco se reescribe al re-unificar. El re-toque de una pareja
            -- existente se registra en lote_actualizacion / fecha_modificacion.
            -- Sin estos dos predicados, una persona re-tocada por el Modo_Delta
            -- quedaria FUERA del alcance del Ordenamiento y no se re-puntuaria.
            u.lote = p_lote
         OR u.lote_actualizacion = p_lote
         OR (p_watermark IS NOT NULL AND u.fecha_unificacion >= p_watermark)
         OR (p_watermark IS NOT NULL AND u.fecha_modificacion >= p_watermark)
          )
  ) x;

  ANALYZE bdm_tempo.stg_ord_personas_alcance;

  -- 1) RPU post-unificacion (sin join orden_prioridad - evita fan-out en staging)
  CREATE TABLE bdm_tempo.stg_rpu_post_unificacion
  DISTSTYLE KEY
  DISTKEY (id_buro_persona)
  SORTKEY (cod_dw_persona_ubic)
  AS
  SELECT
    rpu.cod_dw_persona_ubic,
    rpu.cod_pin_persona,
    rpu.id_buro_persona,
    rpu.cod_dw_ubic,
    CAST(NULL AS INTEGER) AS orden_prioridad,
    rpu.fecha_relacion_persona_ubicaci,
    CASE WHEN u.cod_dw_persona_ubic IS NOT NULL THEN 1 ELSE 0 END AS ind_unificacion
  FROM bdm_tempo.v_xpm_relacion_persona_ubicacion rpu
  INNER JOIN bdm_tempo.stg_ord_personas_alcance alc
    ON alc.id_buro_persona = rpu.id_buro_persona
  LEFT JOIN bdm_datos.unificacion_direccion u
    ON u.cod_dw_persona_ubic = rpu.cod_dw_persona_ubic;

  ANALYZE bdm_tempo.stg_rpu_post_unificacion;

  -- 2) Personas ganadoras (broadcast pequeno)
  CREATE TABLE bdm_tempo.stg_persona_dir_ganadora
  DISTSTYLE ALL
  SORTKEY (id_buro_persona)
  AS
  SELECT DISTINCT id_buro_persona
  FROM bdm_tempo.stg_rpu_post_unificacion
  WHERE COALESCE(ind_unificacion, 0) <> 1;

  ANALYZE bdm_tempo.stg_persona_dir_ganadora;

  -- 3) Conteo direcciones por persona (pre-agregado para DIR)
  CREATE TABLE bdm_tempo.stg_dir_conteo_persona
  DISTSTYLE KEY
  DISTKEY (id_buro_persona)
  SORTKEY (id_buro_persona)
  AS
  SELECT
    r2.id_buro_persona,
    COUNT(DISTINCT cd2.texto_ubicacion) AS conteo_direcciones
  FROM bdm_tempo.stg_rpu_post_unificacion r2
  INNER JOIN bdm_tempo.v_xpm_contacto_direccion cd2
    ON cd2.cod_dw_persona_ubic = r2.cod_dw_persona_ubic
  WHERE COALESCE(r2.ind_unificacion, 0) <> 1
  GROUP BY 1;

  ANALYZE bdm_tempo.stg_dir_conteo_persona;

  -- 4) Referencia direccion por persona (TEL/CEL)
  CREATE TABLE bdm_tempo.stg_persona_dir_ref
  DISTSTYLE KEY
  DISTKEY (id_buro_persona)
  SORTKEY (id_buro_persona)
  AS
  SELECT
    r.id_buro_persona,
    MIN(u.texto_ubicacion) AS dir_ref
  FROM bdm_tempo.stg_rpu_post_unificacion r
  INNER JOIN bdm_tempo.v_xpm_ubicacion_estandarizada u
    ON r.cod_dw_ubic = u.cod_dw_ubic
  WHERE COALESCE(r.ind_unificacion, 0) <> 1
  GROUP BY 1;

  ANALYZE bdm_tempo.stg_persona_dir_ref;

  -- 4b) Referencia de direccion POR RPU, no por persona.
  --
  -- POR QUE EXISTE ESTA TABLA Y NO BASTA stg_persona_dir_ref:
  --   el canal TEL agrupa por direccion_fisica
  --   (sp_ordenamiento_scoring_tel_edf.sql:58), y si esa columna sale de un
  --   agregado POR PERSONA entonces todos los telefonos de una persona caen
  --   en el MISMO grupo: una sola fila de score, lugar = 1 siempre, y nada
  --   que ordenar. El canal pierde su funcion, que es elegir entre los
  --   telefonos de una persona cual es mas contactable.
  --
  --   El legado agrupa por la direccion fisica DE CADA FILA DE REPORTE
  --   (Caracteristicas.txt, GROUP BY Cod_Pin_Persona, Id_Buro_Persona,
  --   Direccion_Fisica), de modo que una persona con N direcciones produce N
  --   grupos. Esta tabla restaura ese grano.
  --
  --   Arrastraba ademas cinco caracteristicas: TEL001, TEL006, TEL010,
  --   TEL023 y TEL025 son en el legado cuotas del grupo contra el total de
  --   la persona, y con grupo = persona valen trivialmente 100 o 0.
  --
  -- stg_persona_dir_ref se CONSERVA: la sigue usando el insumo de CEL, donde
  -- alimenta una bandera de nivel persona (CEL023). Esa caracteristica tiene
  -- su propia divergencia con el legado y se trata aparte.
  CREATE TABLE bdm_tempo.stg_rpu_dir_ref
  DISTSTYLE KEY
  DISTKEY (cod_dw_persona_ubic)
  SORTKEY (cod_dw_persona_ubic)
  AS
  SELECT
    r.cod_dw_persona_ubic,
    MIN(u.texto_ubicacion) AS dir_ref
  FROM bdm_tempo.stg_rpu_post_unificacion r
  INNER JOIN bdm_tempo.v_xpm_ubicacion_estandarizada u
    ON r.cod_dw_ubic = u.cod_dw_ubic
  WHERE COALESCE(r.ind_unificacion, 0) <> 1
  GROUP BY 1;

  ANALYZE bdm_tempo.stg_rpu_dir_ref;

  -- 5) Contacto direccion solo RPUs ganadoras (1 pasada datashare)
  CREATE TABLE bdm_tempo.stg_contacto_direccion_rpu
  DISTSTYLE KEY
  DISTKEY (id_buro_persona)
  SORTKEY (cod_dw_persona_ubic)
  AS
  SELECT cd.*
  FROM bdm_tempo.v_xpm_contacto_direccion cd
  INNER JOIN bdm_tempo.stg_rpu_post_unificacion rpu
    ON rpu.cod_dw_persona_ubic = cd.cod_dw_persona_ubic
   AND COALESCE(rpu.ind_unificacion, 0) <> 1;

  ANALYZE bdm_tempo.stg_contacto_direccion_rpu;

  -- 6) Reportes solo RPUs ganadoras
  CREATE TABLE bdm_tempo.stg_reporte_rpu
  DISTSTYLE KEY
  DISTKEY (id_buro_persona)
  SORTKEY (cod_dw_persona_ubic)
  AS
  SELECT
    rep.cod_dw_persona_ubic,
    rep.id_buro_suscriptor,
    rep.cod_suscriptor,
    rep.fecha_reporte,
    rpu.id_buro_persona
  FROM bdm_tempo.v_xpm_reporte_relacion_persona_ubica rep
  INNER JOIN bdm_tempo.stg_rpu_post_unificacion rpu
    ON rpu.cod_dw_persona_ubic = rep.cod_dw_persona_ubic
   AND COALESCE(rpu.ind_unificacion, 0) <> 1;

  ANALYZE bdm_tempo.stg_reporte_rpu;

  -- 7) Contactos canal TEL/CEL/EMA - solo personas ganadoras
  -- SLCOPRBA-1355: filtro de hijas a grano de RPU, no de PERSONA.
  --
  -- EL DEFECTO. El unico filtro de unificacion de esta rama era el INNER JOIN
  -- a stg_persona_dir_ganadora, que es DISTINCT id_buro_persona de las RPU no
  -- hijas. A una persona con AL MENOS UNA RPU no hija le pasaban TODAS sus
  -- filas de contacto, hijas incluidas -- y los insumos de TEL, CEL y EMA
  -- toman c.cod_dw_persona_ubic de aqui sin volver a mirar ind_unificacion.
  -- Resultado medido en el banco local: 9000 hijas con score en cada uno de
  -- los tres canales, y DIR en cero. Esperado 0 (criterios F4-07, RG-05,
  -- CA-F02 del RF).
  --
  -- DIR no lo sufria porque arranca de stg_rpu_post_unificacion y vuelve a
  -- asertar el predicado sobre ESE MISMO alias. Esto le da a los canales la
  -- misma proteccion, en un solo sitio, y los tres insumos la heredan.
  --
  -- LEFT JOIN y no INNER a proposito: INNER exigiria que la RPU del contacto
  -- este en la tabla, que ademas esta acotada al alcance de la corrida, y eso
  -- descartaria contactos por una razon distinta de la que se quiere. Con
  -- COALESCE se cae SOLO lo que se sabe hija.
  --
  -- stg_persona_dir_ganadora se queda: cumple su propio proposito -- que la
  -- persona tenga una direccion ganadora -- y este filtro es adicional.
  --
  -- PENDIENTE DE NEGOCIO, anotado y no decidido aqui: un telefono reportado en
  -- una RPU que la Unificacion absorbio sigue siendo un telefono valido. Esto
  -- lo descarta, que es lo que pide el RF y lo coherente con DIR. Si negocio
  -- prefiere re-apuntarlo a la direccion padre, es otro cambio.
  CREATE TABLE bdm_tempo.stg_contacto_canal
  DISTSTYLE KEY
  DISTKEY (id_buro_persona)
  SORTKEY (id_buro_persona, contact_type)
  AS
  SELECT c.*
  FROM bdm_tempo.v_xpm_contacto_canal c
  INNER JOIN bdm_tempo.stg_persona_dir_ganadora pg
    ON pg.id_buro_persona = c.id_buro_persona
  LEFT JOIN bdm_tempo.stg_rpu_post_unificacion rpu
    ON rpu.cod_dw_persona_ubic = c.cod_dw_persona_ubic
  WHERE COALESCE(rpu.ind_unificacion, 0) <> 1;

  ANALYZE bdm_tempo.stg_contacto_canal;

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
  WHERE c.contact_type IN ('4', '5', '8')
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
END;
$$;
-- SLCOPRBA-1355: re-DPLY DEV post DROP SCHEMA strct #256
