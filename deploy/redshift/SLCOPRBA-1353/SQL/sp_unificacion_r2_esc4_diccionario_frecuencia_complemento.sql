-- R2 Esc4 — diccionario de complementos
-- Escenario: Gana mayor frecuencia en diccionario; empate excluido
-- Fix QA 2026-09-11 (TC-R2-14 / R2_EMPATE): stg_regla2_e04_ganador + HAVING COUNT(*)=1
--   → si dos RPU empatan en frecuencia máxima, NO unifica
-- Fuente: edf_views → bdm_tempo.v_xpm_* | Salida: bdm_datos.unificacion_direccion
-- Prerequisito: sp_unificacion_r2_esc3_sin_nit_misma_nomenclatura
-- Generado: tools/gen_unificacion_sps_por_escenario.py

CREATE OR REPLACE PROCEDURE bdm_datos.sp_unificacion_r2_esc4_diccionario_frecuencia_complemento(
    p_modo VARCHAR,   -- FULL | DELTA (modo efectivo de la corrida)
    p_lote INTEGER    -- Lote_Corrida externo (reemplaza el 1 hardcodeado)
)
NONATOMIC
LANGUAGE plpgsql
AS $$
BEGIN
  CREATE TABLE bdm_tempo.stg_regla2_e04
  DISTSTYLE KEY DISTKEY(id_buro_persona)
  AS
  SELECT DISTINCT a.*
  FROM (SELECT * FROM bdm_tempo.stg_regla2_e2 WHERE ind_unificacion = 'N') a
  JOIN (SELECT * FROM bdm_tempo.stg_regla2_e2 WHERE ind_unificacion = 'N') b
    ON a.id_buro_persona = b.id_buro_persona
   AND a.texto_ubicacion = b.texto_ubicacion
   AND a.cod_dw_tipo_ubicacion_dir = b.cod_dw_tipo_ubicacion_dir
   AND a.cod_dw_municipio = b.cod_dw_municipio
   AND a.cod_dw_persona_ubic <> b.cod_dw_persona_ubic
   AND a.complemento <> b.complemento;

  CREATE TABLE bdm_tempo.stg_regla2_e04_a
  DISTSTYLE KEY DISTKEY(id_buro_persona)
  AS
  SELECT DISTINCT
    a.*,
    nmc1.nomenclatura AS nomenclatura_pri,
    nmc1.nivel_complemento AS nivel_pri
  FROM bdm_tempo.stg_regla2_e04 a
  LEFT JOIN bdm_datos.nomenclatura nmc1
    ON a.complemento LIKE TRIM(nmc1.nomenclatura) || ' %';

  CREATE TABLE bdm_tempo.stg_regla2_e04_c1
  DISTSTYLE KEY DISTKEY(cod_dw_persona_ubic)
  AS
  SELECT
    t1.cod_dw_persona_ubic,
    COALESCE(t2.conteo, 0) AS conteo
  FROM bdm_tempo.stg_regla2_e04_a t1
  LEFT JOIN (
    SELECT t1.cod_dw_persona_ubic, SUM(dc.frecuencia) AS conteo
    FROM bdm_tempo.stg_regla2_e04_a t1
    LEFT JOIN bdm_datos.diccionario_complementos dc
      ON t1.cod_dw_ubic = dc.cod_dw_ubic
     AND t1.complemento LIKE '%' || dc.nomenclatura || '%'
     AND t1.id_buro_persona = dc.id_buro_persona
    GROUP BY 1
  ) t2
    ON t1.cod_dw_persona_ubic = t2.cod_dw_persona_ubic;

  -- Esc4: solo unifica si un unico RPU tiene conteo maximo en diccionario (R2_EMPATE excluido)
  CREATE TABLE bdm_tempo.stg_regla2_e04_ganador
  DISTSTYLE KEY DISTKEY(id_buro_persona)
  AS
  SELECT
    a.id_buro_persona,
    a.texto_ubicacion,
    a.cod_dw_tipo_ubicacion_dir,
    a.cod_dw_municipio
  FROM bdm_tempo.stg_regla2_e04_a a
  LEFT JOIN bdm_tempo.stg_regla2_e04_c1 c
    ON c.cod_dw_persona_ubic = a.cod_dw_persona_ubic
  JOIN (
    SELECT
      a.id_buro_persona,
      a.texto_ubicacion,
      a.cod_dw_tipo_ubicacion_dir,
      a.cod_dw_municipio,
      MAX(COALESCE(c.conteo, 0)) AS max_conteo
    FROM bdm_tempo.stg_regla2_e04_a a
    LEFT JOIN bdm_tempo.stg_regla2_e04_c1 c
      ON c.cod_dw_persona_ubic = a.cod_dw_persona_ubic
    GROUP BY 1, 2, 3, 4
  ) mx
    ON mx.id_buro_persona = a.id_buro_persona
   AND mx.texto_ubicacion = a.texto_ubicacion
   AND mx.cod_dw_tipo_ubicacion_dir = a.cod_dw_tipo_ubicacion_dir
   AND mx.cod_dw_municipio = a.cod_dw_municipio
   AND COALESCE(c.conteo, 0) = mx.max_conteo
  GROUP BY 1, 2, 3, 4
  HAVING COUNT(*) = 1;

  CREATE TABLE bdm_tempo.stg_regla2_e04_e
  DISTSTYLE KEY DISTKEY(cod_dw_persona_ubic)
  AS
  SELECT DISTINCT
    b.cod_dw_persona_ubic,
    a.cod_dw_persona_ubic AS id_padre
  FROM (
    SELECT
      a.cod_dw_persona_ubic,
      (COALESCE(b.conteo,0) + 10000000)
        + COALESCE(CAST(REPLACE(CAST(a.fecha_relacion_persona_ubicaci AS VARCHAR),'-','') AS BIGINT),0) AS id,
      a.id_buro_persona,
      a.cod_dw_tipo_ubicacion_dir,
      a.cod_dw_municipio,
      a.texto_ubicacion,
      ROW_NUMBER() OVER (
        PARTITION BY a.id_buro_persona, a.texto_ubicacion, a.cod_dw_tipo_ubicacion_dir, a.cod_dw_municipio
        ORDER BY (COALESCE(b.conteo,0) + 10000000)
          + COALESCE(CAST(REPLACE(CAST(a.fecha_relacion_persona_ubicaci AS VARCHAR),'-','') AS BIGINT),0)
      ) AS orden
    FROM bdm_tempo.stg_regla2_e04_a a
    LEFT JOIN bdm_tempo.stg_regla2_e04_c1 b
      ON a.cod_dw_persona_ubic = b.cod_dw_persona_ubic
  ) a
  JOIN (
    SELECT
      a.cod_dw_persona_ubic,
      (COALESCE(b.conteo,0) + 10000000)
        + COALESCE(CAST(REPLACE(CAST(a.fecha_relacion_persona_ubicaci AS VARCHAR),'-','') AS BIGINT),0) AS id,
      a.id_buro_persona,
      a.cod_dw_tipo_ubicacion_dir,
      a.cod_dw_municipio,
      a.texto_ubicacion,
      ROW_NUMBER() OVER (
        PARTITION BY a.id_buro_persona, a.texto_ubicacion, a.cod_dw_tipo_ubicacion_dir, a.cod_dw_municipio
        ORDER BY (COALESCE(b.conteo,0) + 10000000)
          + COALESCE(CAST(REPLACE(CAST(a.fecha_relacion_persona_ubicaci AS VARCHAR),'-','') AS BIGINT),0)
      ) AS orden
    FROM bdm_tempo.stg_regla2_e04_a a
    LEFT JOIN bdm_tempo.stg_regla2_e04_c1 b
      ON a.cod_dw_persona_ubic = b.cod_dw_persona_ubic
  ) b
    ON a.id_buro_persona = b.id_buro_persona
   AND a.texto_ubicacion = b.texto_ubicacion
   AND a.cod_dw_tipo_ubicacion_dir = b.cod_dw_tipo_ubicacion_dir
   AND a.cod_dw_municipio = b.cod_dw_municipio
   AND a.cod_dw_persona_ubic <> b.cod_dw_persona_ubic
   AND a.id > b.id
  JOIN (
    SELECT id_buro_persona, texto_ubicacion, cod_dw_tipo_ubicacion_dir, cod_dw_municipio, MAX(orden) AS max_orden
    FROM (
      SELECT
        a.cod_dw_persona_ubic,
        (COALESCE(b.conteo,0) + 10000000)
          + COALESCE(CAST(REPLACE(CAST(a.fecha_relacion_persona_ubicaci AS VARCHAR),'-','') AS BIGINT),0) AS id,
        a.id_buro_persona,
        a.cod_dw_tipo_ubicacion_dir,
        a.cod_dw_municipio,
        a.texto_ubicacion,
        ROW_NUMBER() OVER (
          PARTITION BY a.id_buro_persona, a.texto_ubicacion, a.cod_dw_tipo_ubicacion_dir, a.cod_dw_municipio
          ORDER BY (COALESCE(b.conteo,0) + 10000000)
            + COALESCE(CAST(REPLACE(CAST(a.fecha_relacion_persona_ubicaci AS VARCHAR),'-','') AS BIGINT),0)
        ) AS orden
      FROM bdm_tempo.stg_regla2_e04_a a
      LEFT JOIN bdm_tempo.stg_regla2_e04_c1 b
        ON a.cod_dw_persona_ubic = b.cod_dw_persona_ubic
    ) tmp
    GROUP BY 1,2,3,4
  ) mx
    ON a.id_buro_persona = mx.id_buro_persona
   AND a.texto_ubicacion = mx.texto_ubicacion
   AND a.cod_dw_tipo_ubicacion_dir = mx.cod_dw_tipo_ubicacion_dir
   AND a.cod_dw_municipio = mx.cod_dw_municipio
   AND a.orden = mx.max_orden
  JOIN bdm_tempo.stg_regla2_e04_ganador g
    ON g.id_buro_persona = mx.id_buro_persona
   AND g.texto_ubicacion = mx.texto_ubicacion
   AND g.cod_dw_tipo_ubicacion_dir = mx.cod_dw_tipo_ubicacion_dir
   AND g.cod_dw_municipio = mx.cod_dw_municipio;

  -- Persistencia condicional al modo (Tarea 6.1, Req 5.1..5.6).
  -- 1) Materializar el resultado de la regla (SELECT DISTINCT, Req 5.5).
  DROP TABLE IF EXISTS bdm_tempo.sp_unificacion_r2_esc4_diccionario_frecuencia_complemento_persist;
  CREATE TABLE bdm_tempo.sp_unificacion_r2_esc4_diccionario_frecuencia_complemento_persist
  DISTSTYLE KEY DISTKEY(cod_dw_persona_ubic)
  AS
  SELECT DISTINCT
    cod_dw_persona_ubic AS cod_dw_persona_ubic,
    id_padre AS cod_dw_direccion_unificada,
    2 AS unifica_atributos,
    CURRENT_DATE AS fecha_unificacion,
    p_lote /* Lote_Corrida externo */ AS lote,
    1 AS severidad,
    LEFT(CURRENT_USER,30) AS usuario_bd
  FROM bdm_tempo.stg_regla2_e04_e;

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
    FROM bdm_tempo.sp_unificacion_r2_esc4_diccionario_frecuencia_complemento_persist s
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
      FROM bdm_tempo.sp_unificacion_r2_esc4_diccionario_frecuencia_complemento_persist s
     WHERE bdm_datos.unificacion_direccion.cod_dw_persona_ubic = s.cod_dw_persona_ubic
       AND bdm_datos.unificacion_direccion.cod_dw_direccion_unificada = s.cod_dw_direccion_unificada;

    INSERT INTO bdm_datos.unificacion_direccion
      (cod_dw_persona_ubic, cod_dw_direccion_unificada, unifica_atributos, fecha_unificacion, lote, severidad, usuario_bd)
    SELECT DISTINCT s.cod_dw_persona_ubic, s.cod_dw_direccion_unificada, s.unifica_atributos,
           s.fecha_unificacion, s.lote, s.severidad, s.usuario_bd
    FROM bdm_tempo.sp_unificacion_r2_esc4_diccionario_frecuencia_complemento_persist s
    WHERE NOT EXISTS (
      SELECT 1
      FROM bdm_datos.unificacion_direccion u
      WHERE u.cod_dw_persona_ubic = s.cod_dw_persona_ubic
        AND u.cod_dw_direccion_unificada = s.cod_dw_direccion_unificada);
  END IF;

  DROP TABLE IF EXISTS bdm_tempo.sp_unificacion_r2_esc4_diccionario_frecuencia_complemento_persist;

  UPDATE bdm_tempo.stg_regla2_e2
  SET id_padre = e.id_padre,
      ind_unificacion = 'S',
      n_id = 'B5'
  FROM bdm_tempo.stg_regla2_e04_e e
  WHERE bdm_tempo.stg_regla2_e2.cod_dw_persona_ubic = e.cod_dw_persona_ubic
    AND bdm_tempo.stg_regla2_e2.id_padre IS NULL;


END;
$$;
-- SLCOPRBA-1355: re-DPLY DEV post DROP SCHEMA strct #256
