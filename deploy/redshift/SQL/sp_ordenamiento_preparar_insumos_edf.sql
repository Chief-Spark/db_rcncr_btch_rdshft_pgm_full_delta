-- ============================================================
-- 05_sp_preparar_insumos_edf.sql
-- Staging TEMPORAL por corrida: 1 lectura datashare → tablas stg_* locales.
-- No persiste entre ejecuciones (drop al final de sp_ordenamiento_ejecucion_edf).
-- Misma lógica que vistas bdm_datos.insumo_* en 04_vistas_sin_copia_productor.sql
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
            u.lote = p_lote
         OR (p_watermark IS NOT NULL AND u.fecha_unificacion >= p_watermark)
          )
  ) x;

  ANALYZE bdm_tempo.stg_ord_personas_alcance;

  -- 1) RPU post-unificación (sin join orden_prioridad — evita fan-out en staging)
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

  -- 2) Personas ganadoras (broadcast pequeño)
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

  -- 4) Referencia dirección por persona (TEL/CEL)
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

  -- 5) Contacto dirección solo RPUs ganadoras (1 pasada datashare)
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
    rep.fecha_reporte,
    rpu.id_buro_persona
  FROM bdm_tempo.v_xpm_reporte_relacion_persona_ubica rep
  INNER JOIN bdm_tempo.stg_rpu_post_unificacion rpu
    ON rpu.cod_dw_persona_ubic = rep.cod_dw_persona_ubic
   AND COALESCE(rpu.ind_unificacion, 0) <> 1;

  ANALYZE bdm_tempo.stg_reporte_rpu;

  -- 7) Contactos canal TEL/CEL/EMA — solo personas ganadoras
  CREATE TABLE bdm_tempo.stg_contacto_canal
  DISTSTYLE KEY
  DISTKEY (id_buro_persona)
  SORTKEY (id_buro_persona, contact_type)
  AS
  SELECT c.*
  FROM bdm_tempo.v_xpm_contacto_canal c
  INNER JOIN bdm_tempo.stg_persona_dir_ganadora pg
    ON pg.id_buro_persona = c.id_buro_persona;

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
    COALESCE(ref.dir_ref, c.texto_ubicacion_vinculo, c.valor_contacto) AS direccion_fisica,
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
  LEFT JOIN bdm_tempo.stg_persona_dir_ref ref
    ON ref.id_buro_persona = c.id_buro_persona
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
    LTRIM(c.valor_contacto, '0') AS celular,
    COALESCE(ref.dir_ref, c.texto_ubicacion_vinculo) AS texto_ubicacion,
    c.id_buro_suscriptor,
    COALESCE(c.fecha_contacto, CURRENT_DATE) AS fecha_reporte,
    GREATEST(DATEDIFF(month, COALESCE(c.fecha_contacto, CURRENT_DATE), CURRENT_DATE), 0) AS meses_reporte,
    LEFT(LTRIM(c.valor_contacto, '0'), 3) AS operador,
    COALESCE(sf.sector_financiero, 0) AS sector_financiero,
    COALESCE(tcat.tipo_cuenta, 'PREPAGO') AS tipo_cuenta
  FROM bdm_tempo.stg_contacto_canal c
  LEFT JOIN bdm_datos.catalogo_sector_financiero sf
    ON sf.id_buro_suscriptor = c.id_buro_suscriptor
  LEFT JOIN bdm_datos.catalogo_tipo_cuenta_tel tcat
    ON tcat.prefijo_operador = LEFT(LTRIM(c.valor_contacto, '0'), 3)
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
      ('gmail.com','hotmail.com','yahoo.com','outlook.com') THEN 'PERSONAL' ELSE 'CORPORATIVO' END AS tipo_cuenta
  FROM bdm_tempo.stg_contacto_canal c
  LEFT JOIN bdm_datos.catalogo_sector_financiero sf
    ON sf.id_buro_suscriptor = c.id_buro_suscriptor
  WHERE c.contact_type = '10'
    AND c.valor_contacto LIKE '%@%';

  ANALYZE bdm_tempo.stg_insumo_email;
END;
$$;
-- SLCOPRBA-1355: re-DPLY DEV post DROP SCHEMA strct #256
