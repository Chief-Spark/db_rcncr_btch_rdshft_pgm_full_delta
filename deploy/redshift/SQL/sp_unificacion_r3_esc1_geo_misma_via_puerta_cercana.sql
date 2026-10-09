-- R3 Esc1 — misma vía, puerta más cercana (±2)
-- Escenario: Unificación geo por proximidad de número de puerta
-- Fuente: edf_views → bdm_tempo.v_xpm_* | Salida: bdm_datos.unificacion_direccion
-- Prerequisito: Regla 2 ejecutada; lat/long en insumo
-- Generado: tools/gen_unificacion_sps_por_escenario.py

CREATE OR REPLACE PROCEDURE bdm_datos.sp_unificacion_r3_esc1_geo_misma_via_puerta_cercana(
    p_modo VARCHAR,   -- FULL | DELTA (modo efectivo de la corrida)
    p_lote INTEGER    -- Lote_Corrida externo (reemplaza el 1 hardcodeado)
)
NONATOMIC
LANGUAGE plpgsql
AS $$
BEGIN
-- Limpieza de staging de esta regla
DROP TABLE IF EXISTS bdm_tempo.stg_regla3_pares;

  -- ==========================================================
  -- REGLA 3
  -- Version validada en la corrida 20K.
  -- ==========================================================

  CREATE TABLE bdm_tempo.stg_regla3_insumo
  DISTSTYLE KEY DISTKEY(id_buro_persona)
  AS
  SELECT
    rpu.cod_dw_persona_ubic,
    rpu.id_buro_persona,
    ubi.texto_ubicacion,
    df.complemento,
    ubi.cod_dw_ciudad AS cod_dw_municipio,
    ubi.latitud,
    ubi.longitud,
    COALESCE(cnt.numero_entidades_reportan, 0) AS numero_entidades_reportan
  FROM bdm_tempo.v_xpm_relacion_persona_ubicacion rpu
  JOIN bdm_tempo.v_xpm_ubicacion_estandarizada ubi
    ON rpu.cod_dw_ubic = ubi.cod_dw_ubic
  LEFT JOIN bdm_tempo.v_xpm_direccion_fisica df
    ON rpu.cod_dw_direccion_fisica = df.cod_dw_direccion_fisica
  LEFT JOIN (
    SELECT cod_dw_persona_ubic, COUNT(DISTINCT id_buro_suscriptor) AS numero_entidades_reportan
    FROM bdm_tempo.v_xpm_reporte_relacion_persona_ubica
    GROUP BY 1
  ) cnt
    ON rpu.cod_dw_persona_ubic = cnt.cod_dw_persona_ubic
  WHERE rpu.ind_unificacion IS NULL;

  CREATE TABLE bdm_tempo.stg_regla3_pares
  DISTSTYLE KEY DISTKEY(cod_dw_persona_ubic)
  AS
  SELECT DISTINCT
    b.cod_dw_persona_ubic,
    a.cod_dw_persona_ubic AS id_padre
  FROM bdm_tempo.stg_regla3_insumo a
  JOIN bdm_tempo.stg_regla3_insumo b
    ON a.id_buro_persona = b.id_buro_persona
   AND a.cod_dw_municipio = b.cod_dw_municipio
   AND a.cod_dw_persona_ubic <> b.cod_dw_persona_ubic
   AND SPLIT_PART(a.texto_ubicacion,' ',1) = SPLIT_PART(b.texto_ubicacion,' ',1)
   AND SPLIT_PART(a.texto_ubicacion,' ',2) = SPLIT_PART(b.texto_ubicacion,' ',2)
   AND (
     ABS(CAST(SPLIT_PART(a.texto_ubicacion,' ',3) AS INTEGER) - CAST(SPLIT_PART(b.texto_ubicacion,' ',3) AS INTEGER)) BETWEEN 1 AND 2
     OR ABS(CAST(SPLIT_PART(a.texto_ubicacion,' ',4) AS INTEGER) - CAST(SPLIT_PART(b.texto_ubicacion,' ',4) AS INTEGER)) BETWEEN 1 AND 2
   )
   AND a.numero_entidades_reportan > b.numero_entidades_reportan
  WHERE a.latitud IS NOT NULL
    AND b.latitud IS NOT NULL;

  -- Persistencia condicional al modo (Tarea 6.1, Req 5.1..5.6).
  -- 1) Materializar el resultado de la regla (SELECT DISTINCT, Req 5.5).
  DROP TABLE IF EXISTS bdm_tempo.sp_unificacion_r3_esc1_geo_misma_via_puerta_cercana_persist;
  CREATE TABLE bdm_tempo.sp_unificacion_r3_esc1_geo_misma_via_puerta_cercana_persist
  DISTSTYLE KEY DISTKEY(cod_dw_persona_ubic)
  AS
  SELECT DISTINCT
    cod_dw_persona_ubic AS cod_dw_persona_ubic,
    id_padre AS cod_dw_direccion_unificada,
    3 AS unifica_atributos,
    CURRENT_DATE AS fecha_unificacion,
    p_lote /* Lote_Corrida externo */ AS lote,
    1 AS severidad,
    LEFT(CURRENT_USER,30) AS usuario_bd
  FROM bdm_tempo.stg_regla3_pares;

  IF p_modo = 'FULL' THEN
    -- FULL: el TRUNCATE lo hizo el orquestador una vez al inicio de la corrida.
    -- Se usa INSERT FOR MISSING (el mismo NOT EXISTS del Modo_Delta) y NO un
    -- INSERT plano: dentro de una misma corrida FULL dos escenarios distintos
    -- pueden producir la MISMA Clave_Unificacion, y el INSERT plano dejaba la
    -- pareja DUPLICADA -- justo lo que vigila el gate unicidad_clave_unificacion.
    -- El legado Teradata aplica el upsert de forma uniforme, sin distinguir
    -- carga inicial: gana el primer escenario que produce la pareja.
    -- No se hace el UPDATE previo que si lleva el Modo_Delta: tras el TRUNCATE
    -- la unica fila preexistente posible proviene de un escenario anterior de
    -- ESTA misma corrida, por lo que sellar lote_actualizacion con el mismo
    -- lote no aportaria informacion.
    INSERT INTO bdm_datos.unificacion_direccion
      (cod_dw_persona_ubic, cod_dw_direccion_unificada, unifica_atributos, fecha_unificacion, lote, severidad, usuario_bd)
    SELECT DISTINCT s.cod_dw_persona_ubic, s.cod_dw_direccion_unificada, s.unifica_atributos,
           s.fecha_unificacion, s.lote, s.severidad, s.usuario_bd
    FROM bdm_tempo.sp_unificacion_r3_esc1_geo_misma_via_puerta_cercana_persist s
    WHERE NOT EXISTS (
      SELECT 1
      FROM bdm_datos.unificacion_direccion u
      WHERE u.cod_dw_persona_ubic = s.cod_dw_persona_ubic
        AND u.cod_dw_direccion_unificada = s.cod_dw_direccion_unificada);
  ELSE
    -- DELTA UPSERT fiel al legado Teradata (SLCOPRBA-1355).
    -- Patron 'INSERT FOR MISSING UPDATE ROWS' de
    -- P0020_UNIFICACION_DIRECCION_130.TPT (STEP Load_UNIFICACION_DIRECCION):
    -- UPDATE de las filas que ya existen con la misma Clave_Unificacion e
    -- INSERT de las que faltan. El UPDATE no reescribe 'lote' (identifica la
    -- corrida que CREO la unificacion) ni 'unifica_atributos'; solo sella
    -- lote_actualizacion / fecha_modificacion / usuario_bd.
    -- NOTA Redshift: en UPDATE ... FROM la tabla destino NO admite alias.
    UPDATE bdm_datos.unificacion_direccion
       SET lote_actualizacion = p_lote,
           fecha_modificacion = CURRENT_DATE,
           usuario_bd         = CURRENT_USER
      FROM bdm_tempo.sp_unificacion_r3_esc1_geo_misma_via_puerta_cercana_persist s
     WHERE bdm_datos.unificacion_direccion.cod_dw_persona_ubic = s.cod_dw_persona_ubic
       AND bdm_datos.unificacion_direccion.cod_dw_direccion_unificada = s.cod_dw_direccion_unificada;

    INSERT INTO bdm_datos.unificacion_direccion
      (cod_dw_persona_ubic, cod_dw_direccion_unificada, unifica_atributos, fecha_unificacion, lote, severidad, usuario_bd)
    SELECT DISTINCT s.cod_dw_persona_ubic, s.cod_dw_direccion_unificada, s.unifica_atributos,
           s.fecha_unificacion, s.lote, s.severidad, s.usuario_bd
    FROM bdm_tempo.sp_unificacion_r3_esc1_geo_misma_via_puerta_cercana_persist s
    WHERE NOT EXISTS (
      SELECT 1
      FROM bdm_datos.unificacion_direccion u
      WHERE u.cod_dw_persona_ubic = s.cod_dw_persona_ubic
        AND u.cod_dw_direccion_unificada = s.cod_dw_direccion_unificada);
  END IF;

  DROP TABLE IF EXISTS bdm_tempo.sp_unificacion_r3_esc1_geo_misma_via_puerta_cercana_persist;
  DROP TABLE IF EXISTS bdm_tempo.stg_regla3_insumo;
  DROP TABLE IF EXISTS bdm_tempo.stg_regla3_pares;

END;
$$;
-- SLCOPRBA-1355: re-DPLY DEV post DROP SCHEMA strct #256
