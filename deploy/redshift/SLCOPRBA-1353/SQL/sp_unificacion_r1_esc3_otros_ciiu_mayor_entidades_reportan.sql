-- R1 Esc3 — otros CIIU, mismo texto distinto tipo
-- Escenario: Gana quien reportan más entidades
-- Fuente: edf_views → bdm_tempo.v_xpm_* | Salida: bdm_datos.unificacion_direccion
-- Prerequisito: sp_unificacion_r1_preparar_insumo
-- Generado: tools/gen_unificacion_sps_por_escenario.py

CREATE OR REPLACE PROCEDURE bdm_datos.sp_unificacion_r1_esc3_otros_ciiu_mayor_entidades_reportan(
    p_modo VARCHAR,   -- FULL | DELTA (modo efectivo de la corrida)
    p_lote INTEGER    -- Lote_Corrida externo (reemplaza el 1 hardcodeado)
)
NONATOMIC
LANGUAGE plpgsql
AS $$
BEGIN

  DROP TABLE IF EXISTS bdm_tempo.stg_regla1_scored;
  DROP TABLE IF EXISTS bdm_tempo.stg_regla1_max;
  DROP TABLE IF EXISTS bdm_tempo.stg_regla1_ganador;
  DROP TABLE IF EXISTS bdm_tempo.stg_regla1_pares;

  CREATE TABLE bdm_tempo.stg_regla1_scored
  DISTSTYLE KEY DISTKEY(id_buro_persona)
  SORTKEY(id_buro_persona, texto_ubicacion)
  AS
  SELECT *,
    'ESC3' AS escenario,
    numero_entidades_reportan AS score,
    ROW_NUMBER() OVER (
      PARTITION BY id_buro_persona, texto_ubicacion, cod_dw_ciudad
      ORDER BY numero_entidades_reportan DESC, cod_dw_persona_ubic DESC
    ) AS orden
  FROM bdm_tempo.stg_regla1_insumo
  WHERE cod_act_econo_ciiu_fte NOT IN ('10','81','82','90');

  CREATE TABLE bdm_tempo.stg_regla1_max
  DISTSTYLE KEY DISTKEY(id_buro_persona)
  AS
  SELECT id_buro_persona, texto_ubicacion, cod_dw_ciudad, escenario, MAX(score) AS max_score
  FROM bdm_tempo.stg_regla1_scored
  GROUP BY 1, 2, 3, 4;

  CREATE TABLE bdm_tempo.stg_regla1_ganador
  DISTSTYLE KEY DISTKEY(id_buro_persona)
  AS
  SELECT m.id_buro_persona, m.texto_ubicacion, m.cod_dw_ciudad, m.escenario
  FROM bdm_tempo.stg_regla1_max m
  JOIN bdm_tempo.stg_regla1_scored s
    ON s.id_buro_persona = m.id_buro_persona
   AND s.texto_ubicacion = m.texto_ubicacion
   AND s.cod_dw_ciudad = m.cod_dw_ciudad
   AND s.escenario = m.escenario
   AND s.score = m.max_score
  GROUP BY 1, 2, 3, 4
  HAVING COUNT(*) = 1;

  CREATE TABLE bdm_tempo.stg_regla1_pares
  DISTSTYLE KEY DISTKEY(cod_dw_persona_ubic)
  AS
  SELECT hijo.cod_dw_persona_ubic, padre.cod_dw_persona_ubic AS cod_dw_direccion_unificada
  FROM bdm_tempo.stg_regla1_scored padre
  JOIN bdm_tempo.stg_regla1_ganador g
    ON g.id_buro_persona = padre.id_buro_persona
   AND g.texto_ubicacion = padre.texto_ubicacion
   AND g.cod_dw_ciudad = padre.cod_dw_ciudad
   AND g.escenario = padre.escenario
  JOIN bdm_tempo.stg_regla1_scored hijo
    ON padre.id_buro_persona = hijo.id_buro_persona
   AND padre.texto_ubicacion = hijo.texto_ubicacion
   AND padre.cod_dw_ciudad = hijo.cod_dw_ciudad
   AND padre.escenario = hijo.escenario
   AND hijo.orden > 1
   AND padre.cod_dw_tipo_ubicacion_dir <> hijo.cod_dw_tipo_ubicacion_dir
  WHERE padre.orden = 1;

  -- Persistencia condicional al modo (Tarea 6.1, Req 5.1..5.6).
  -- 1) Materializar el resultado de la regla (SELECT DISTINCT, Req 5.5).
  DROP TABLE IF EXISTS bdm_tempo.sp_unificacion_r1_esc3_otros_ciiu_mayor_entidades_reportan_persist;
  CREATE TABLE bdm_tempo.sp_unificacion_r1_esc3_otros_ciiu_mayor_entidades_reportan_persist
  DISTSTYLE KEY DISTKEY(cod_dw_persona_ubic)
  AS
  SELECT DISTINCT
    cod_dw_persona_ubic AS cod_dw_persona_ubic,
    cod_dw_direccion_unificada AS cod_dw_direccion_unificada,
    1 AS unifica_atributos,
    CURRENT_DATE AS fecha_unificacion,
    p_lote /* Lote_Corrida externo */ AS lote,
    1 AS severidad,
    CURRENT_USER AS usuario_bd
  FROM bdm_tempo.stg_regla1_pares;

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
    FROM bdm_tempo.sp_unificacion_r1_esc3_otros_ciiu_mayor_entidades_reportan_persist s
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
      FROM bdm_tempo.sp_unificacion_r1_esc3_otros_ciiu_mayor_entidades_reportan_persist s
     WHERE bdm_datos.unificacion_direccion.cod_dw_persona_ubic = s.cod_dw_persona_ubic
       AND bdm_datos.unificacion_direccion.cod_dw_direccion_unificada = s.cod_dw_direccion_unificada;

    INSERT INTO bdm_datos.unificacion_direccion
      (cod_dw_persona_ubic, cod_dw_direccion_unificada, unifica_atributos, fecha_unificacion, lote, severidad, usuario_bd)
    SELECT DISTINCT s.cod_dw_persona_ubic, s.cod_dw_direccion_unificada, s.unifica_atributos,
           s.fecha_unificacion, s.lote, s.severidad, s.usuario_bd
    FROM bdm_tempo.sp_unificacion_r1_esc3_otros_ciiu_mayor_entidades_reportan_persist s
    WHERE NOT EXISTS (
      SELECT 1
      FROM bdm_datos.unificacion_direccion u
      WHERE u.cod_dw_persona_ubic = s.cod_dw_persona_ubic
        AND u.cod_dw_direccion_unificada = s.cod_dw_direccion_unificada);
  END IF;

  DROP TABLE IF EXISTS bdm_tempo.sp_unificacion_r1_esc3_otros_ciiu_mayor_entidades_reportan_persist;

  DROP TABLE IF EXISTS bdm_tempo.stg_regla1_scored;
  DROP TABLE IF EXISTS bdm_tempo.stg_regla1_max;
  DROP TABLE IF EXISTS bdm_tempo.stg_regla1_ganador;
  DROP TABLE IF EXISTS bdm_tempo.stg_regla1_pares;

END;
$$;
-- SLCOPRBA-1355: re-DPLY DEV post DROP SCHEMA strct #256
