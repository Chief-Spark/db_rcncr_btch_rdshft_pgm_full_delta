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
    -- FULL: append (el TRUNCATE lo hizo el orquestador una vez).
    INSERT INTO bdm_datos.unificacion_direccion
      (cod_dw_persona_ubic, cod_dw_direccion_unificada, unifica_atributos, fecha_unificacion, lote, severidad, usuario_bd)
    SELECT DISTINCT cod_dw_persona_ubic, cod_dw_direccion_unificada, unifica_atributos, fecha_unificacion, lote, severidad, usuario_bd
    FROM bdm_tempo.sp_unificacion_r1_esc3_otros_ciiu_mayor_entidades_reportan_persist;
  ELSE
    -- DELTA UPSERT (DELETE+INSERT): cluster Redshift no acepta alias en MERGE.
    -- Misma Clave_Unificacion; sin truncar tabla completa (Req 5.1, 5.2, 5.6).
    DELETE FROM bdm_datos.unificacion_direccion
    USING bdm_tempo.sp_unificacion_r1_esc3_otros_ciiu_mayor_entidades_reportan_persist s
    WHERE bdm_datos.unificacion_direccion.cod_dw_persona_ubic = s.cod_dw_persona_ubic
      AND bdm_datos.unificacion_direccion.cod_dw_direccion_unificada = s.cod_dw_direccion_unificada;

    INSERT INTO bdm_datos.unificacion_direccion
      (cod_dw_persona_ubic, cod_dw_direccion_unificada, unifica_atributos, fecha_unificacion, lote, severidad, usuario_bd)
    SELECT DISTINCT cod_dw_persona_ubic, cod_dw_direccion_unificada, unifica_atributos, fecha_unificacion, lote, severidad, usuario_bd
    FROM bdm_tempo.sp_unificacion_r1_esc3_otros_ciiu_mayor_entidades_reportan_persist;
  END IF;

  DROP TABLE IF EXISTS bdm_tempo.sp_unificacion_r1_esc3_otros_ciiu_mayor_entidades_reportan_persist;

  DROP TABLE IF EXISTS bdm_tempo.stg_regla1_scored;
  DROP TABLE IF EXISTS bdm_tempo.stg_regla1_max;
  DROP TABLE IF EXISTS bdm_tempo.stg_regla1_ganador;
  DROP TABLE IF EXISTS bdm_tempo.stg_regla1_pares;

END;
$$;
-- SLCOPRBA-1355: re-DPLY DEV post DROP SCHEMA strct #256
