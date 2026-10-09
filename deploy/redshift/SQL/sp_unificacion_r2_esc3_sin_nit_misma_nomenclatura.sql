-- R2 Esc3 — misma nomenclatura sin NIT
-- Escenario: Excluye tipo identificación 3 (NIT)
-- Fuente: edf_views → bdm_tempo.v_xpm_* | Salida: bdm_datos.unificacion_direccion
-- Prerequisito: sp_unificacion_r2_esc1_complemento_vacio_esc2_substring_complemento
-- Generado: tools/gen_unificacion_sps_por_escenario.py

CREATE OR REPLACE PROCEDURE bdm_datos.sp_unificacion_r2_esc3_sin_nit_misma_nomenclatura(
    p_modo VARCHAR,   -- FULL | DELTA (modo efectivo de la corrida)
    p_lote INTEGER    -- Lote_Corrida externo (reemplaza el 1 hardcodeado)
)
NONATOMIC
LANGUAGE plpgsql
AS $$
BEGIN
  CREATE TABLE bdm_tempo.stg_regla2_e03
  DISTSTYLE KEY DISTKEY(id_buro_persona)
  AS
  SELECT a.*
  FROM bdm_tempo.stg_regla2_e2 a
  JOIN bdm_tempo.v_xpm_relacion_persona_ubicacion rpu
    ON a.cod_dw_persona_ubic = rpu.cod_dw_persona_ubic
  WHERE a.ind_unificacion = 'N'
    -- SLCOPRBA-1355: comparacion TEXTUAL. cod_tipo_ident_fte es VARCHAR(20)
    -- en el legado y en el mock; la via real lo exponia como INTEGER y el
    -- CAST abortaba con "Value out of range for 4 bytes" (job #293). TRIM
    -- porque el codigo llega del datashare sin normalizar.
    AND COALESCE(TRIM(rpu.cod_tipo_ident_fte), '') <> '3';

  CREATE TABLE bdm_tempo.stg_regla2_e03_a
  DISTSTYLE KEY DISTKEY(id_buro_persona)
  AS
  SELECT u1.*
  FROM (
    SELECT
      a.cod_dw_persona_ubic,
      COALESCE(CAST(REPLACE(CAST(a.fecha_relacion_persona_ubicaci AS VARCHAR), '-', '') AS BIGINT), 19000101)
        + (COALESCE(a.numero_entidades_reportan, 0) + 10000000) AS id,
      a.texto_ubicacion,
      a.fecha_relacion_persona_ubicaci,
      nmc1.nomenclatura,
      a.id_buro_persona,
      a.cod_dw_tipo_ubicacion_dir,
      a.cod_dw_municipio,
      ROW_NUMBER() OVER (
        PARTITION BY a.id_buro_persona, a.texto_ubicacion, a.cod_dw_tipo_ubicacion_dir,
          a.cod_dw_municipio, nmc1.nomenclatura
        ORDER BY COALESCE(CAST(REPLACE(CAST(a.fecha_relacion_persona_ubicaci AS VARCHAR), '-', '') AS BIGINT), 19000101)
          + (COALESCE(a.numero_entidades_reportan, 0) + 10000000)
      ) AS orden
    FROM bdm_tempo.stg_regla2_e03 a
    JOIN bdm_tempo.stg_regla2_e03 b
      ON a.id_buro_persona = b.id_buro_persona
     AND a.texto_ubicacion = b.texto_ubicacion
     AND a.cod_dw_tipo_ubicacion_dir = b.cod_dw_tipo_ubicacion_dir
     AND a.cod_dw_municipio = b.cod_dw_municipio
     AND a.cod_dw_persona_ubic <> b.cod_dw_persona_ubic
     AND a.complemento <> b.complemento
    JOIN bdm_datos.nomenclatura nmc1
      ON a.complemento LIKE nmc1.nomenclatura || '%'
    JOIN bdm_datos.nomenclatura nmc2
      ON b.complemento LIKE nmc2.nomenclatura || '%'
    WHERE nmc1.nomenclatura = nmc2.nomenclatura
  ) u1;

  CREATE TABLE bdm_tempo.stg_regla2_e03_e1
  DISTSTYLE KEY DISTKEY(cod_dw_persona_ubic)
  AS
  SELECT DISTINCT
    b.cod_dw_persona_ubic,
    a.cod_dw_persona_ubic AS id_padre
  FROM bdm_tempo.stg_regla2_e03_a a
  JOIN bdm_tempo.stg_regla2_e03_a b
    ON a.id_buro_persona = b.id_buro_persona
   AND a.texto_ubicacion = b.texto_ubicacion
   AND a.cod_dw_tipo_ubicacion_dir = b.cod_dw_tipo_ubicacion_dir
   AND a.cod_dw_municipio = b.cod_dw_municipio
   AND a.nomenclatura = b.nomenclatura
   AND a.cod_dw_persona_ubic <> b.cod_dw_persona_ubic
   AND a.id > b.id
  JOIN (
    SELECT id_buro_persona, texto_ubicacion, cod_dw_tipo_ubicacion_dir, cod_dw_municipio, nomenclatura,
      MAX(orden) AS max_orden
    FROM bdm_tempo.stg_regla2_e03_a
    GROUP BY 1,2,3,4,5
  ) mx
    ON a.id_buro_persona = mx.id_buro_persona
   AND a.texto_ubicacion = mx.texto_ubicacion
   AND a.cod_dw_tipo_ubicacion_dir = mx.cod_dw_tipo_ubicacion_dir
   AND a.cod_dw_municipio = mx.cod_dw_municipio
   AND a.nomenclatura = mx.nomenclatura
   AND a.orden = mx.max_orden;

  -- Persistencia condicional al modo (Tarea 6.1, Req 5.1..5.6).
  -- 1) Materializar el resultado de la regla (SELECT DISTINCT, Req 5.5).
  DROP TABLE IF EXISTS bdm_tempo.sp_unificacion_r2_esc3_sin_nit_misma_nomenclatura_persist;
  CREATE TABLE bdm_tempo.sp_unificacion_r2_esc3_sin_nit_misma_nomenclatura_persist
  DISTSTYLE KEY DISTKEY(cod_dw_persona_ubic)
  AS
  SELECT DISTINCT
    cod_dw_persona_ubic AS cod_dw_persona_ubic,
    id_padre AS cod_dw_direccion_unificada,
    2 AS unifica_atributos,
    CURRENT_DATE AS fecha_unificacion,
    p_lote /* Lote_Corrida externo */ AS lote,
    1 AS severidad,
    LEFT(CURRENT_USER, 30) AS usuario_bd
  FROM bdm_tempo.stg_regla2_e03_e1;

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
    FROM bdm_tempo.sp_unificacion_r2_esc3_sin_nit_misma_nomenclatura_persist s
    WHERE NOT EXISTS (
      SELECT 1
      FROM bdm_datos.unificacion_direccion u
      WHERE u.cod_dw_persona_ubic = s.cod_dw_persona_ubic
        AND u.cod_dw_direccion_unificada = s.cod_dw_direccion_unificada);
  ELSE
    -- DELTA UPSERT fiel al legado Teradata (SLCOPRBA-1355).
    -- Patron 'INSERT FOR MISSING UPDATE ROWS' de
    -- P0020_UNIFICACION_DIRECCION_130.TPT (STEP Load_UNIFICACION_DIRECCION):
    --   1) UPDATE de las filas que YA existen con la misma Clave_Unificacion
    --      (cod_dw_persona_ubic, cod_dw_direccion_unificada).
    --   2) INSERT de las que faltan.
    -- El UPDATE NO reescribe 'lote' ni 'unifica_atributos': en el legado el
    -- Lote identifica la corrida que CREO la unificacion y es inmutable; solo
    -- se sellan Lote_Actualizacion / Fecha_Modificacion / Usuario_BD.
    -- NO se usa MERGE: el cluster Redshift no acepta alias en MERGE.
    -- NO se usa DELETE+INSERT (version anterior): reescribia 'lote' con el de
    -- la corrida en curso, perdiendo la trazabilidad de que corrida origino
    -- cada unificacion y haciendo ininterpretable total_unificaciones.
    -- NOTA Redshift: en UPDATE ... FROM la tabla destino NO admite alias; se
    -- referencia con su nombre calificado completo (igual que el DELETE USING).
    UPDATE bdm_datos.unificacion_direccion
       SET lote_actualizacion = p_lote,
           fecha_modificacion = CURRENT_DATE,
           usuario_bd         = CURRENT_USER
      FROM bdm_tempo.sp_unificacion_r2_esc3_sin_nit_misma_nomenclatura_persist s
     WHERE bdm_datos.unificacion_direccion.cod_dw_persona_ubic = s.cod_dw_persona_ubic
       AND bdm_datos.unificacion_direccion.cod_dw_direccion_unificada = s.cod_dw_direccion_unificada;

    INSERT INTO bdm_datos.unificacion_direccion
      (cod_dw_persona_ubic, cod_dw_direccion_unificada, unifica_atributos, fecha_unificacion, lote, severidad, usuario_bd)
    SELECT DISTINCT s.cod_dw_persona_ubic, s.cod_dw_direccion_unificada, s.unifica_atributos,
           s.fecha_unificacion, s.lote, s.severidad, s.usuario_bd
    FROM bdm_tempo.sp_unificacion_r2_esc3_sin_nit_misma_nomenclatura_persist s
    WHERE NOT EXISTS (
      SELECT 1
      FROM bdm_datos.unificacion_direccion u
      WHERE u.cod_dw_persona_ubic = s.cod_dw_persona_ubic
        AND u.cod_dw_direccion_unificada = s.cod_dw_direccion_unificada);
  END IF;

  DROP TABLE IF EXISTS bdm_tempo.sp_unificacion_r2_esc3_sin_nit_misma_nomenclatura_persist;

  UPDATE bdm_tempo.stg_regla2_e2
  SET id_padre = stg.id_padre,
      ind_unificacion = 'S',
      n_id = 'L3'
  FROM bdm_tempo.stg_regla2_e03_e1 stg
  WHERE bdm_tempo.stg_regla2_e2.cod_dw_persona_ubic = stg.cod_dw_persona_ubic
    AND bdm_tempo.stg_regla2_e2.id_padre IS NULL;


END;
$$;
-- SLCOPRBA-1355: re-DPLY DEV post DROP SCHEMA strct #256
