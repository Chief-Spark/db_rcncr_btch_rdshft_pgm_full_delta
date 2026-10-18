-- Novedades - dominio ACTIVIDAD ECONOMICA (ESPEJO MOCK)
-- Espejo de sp_novedades_actividad_economica_edf.sql. Generado por SUSTITUCION DE
-- FUENTES: no se edita a mano. Regenerar con
-- tools/gen_novedades_espejo_acteco.py.
-- Solo cambian los nombres de los objetos: _edf -> _mock en los
-- procedimientos, v_xpm_* -> v_mock_*, sufijo _mock en el contrato y
-- en la tabla final, y stg_nov_* -> stg_mock_nov_* en el staging.
-- El diff contra el real debe salir vacio modulo esos nombres.

CREATE OR REPLACE PROCEDURE bdm_datos.sp_novedades_actividad_economica_mock(
    p_modo      VARCHAR,   -- FULL | DELTA (modo efectivo de la corrida)
    p_watermark DATE       -- frontera inferior inclusiva (solo aplica en DELTA)
)
NONATOMIC
LANGUAGE plpgsql
AS $$
BEGIN

  -- ------------------------------------------------------------
  -- Paso 1: la persona, con su pin y su fecha mas reciente.
  --
  -- El pin entra como MAX() de arrastre y no por join aparte: id_buro_persona
  -- es FNV_HASH(pin) y cod_pin_persona es CAST(pin AS BIGINT)
  -- (02_vistas_insumo_edf_views.sql:22-23), de modo que hay un unico pin por
  -- hash salvo colision. Es el mismo idioma que usa el canal TEL del
  -- Ordenamiento para arrastrar la direccion.
  --
  -- EL LEFT JOIN NO ES COSMETICO: una persona sin reporte conserva su CIIU y
  -- entra con fecha NULL. Con INNER la perderiamos, y el legado no la pierde:
  -- su FECHA_REPORTE tambien admite NULL.
  -- ------------------------------------------------------------
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_nov_acteco_pers;
  CREATE TABLE bdm_tempo.stg_mock_nov_acteco_pers
  DISTSTYLE KEY DISTKEY(id_buro_persona)
  AS
  SELECT rpu.id_buro_persona,
         MAX(rpu.cod_pin_persona) AS cod_pin_persona,
         MAX(r.fecha_reporte)     AS fecha_reporte
  FROM      bdm_tempo.v_mock_relacion_persona_ubicacion rpu
  LEFT JOIN bdm_tempo.v_mock_reporte_relacion_persona_ubica r
         ON r.cod_dw_persona_ubic = rpu.cod_dw_persona_ubic
  GROUP BY rpu.id_buro_persona;

  -- ------------------------------------------------------------
  -- Paso 2: alta contra cambio, por presencia en la tabla final.
  --
  -- El legado lo decide por LOTE y LOTE_ACTUALIZACION de
  -- V_PERSONA_ACT_ECONOMICA_CIIU (Novedad.sql:1159 y :1213), dos columnas que
  -- no existen en edf_views. Misma salida que en Ubicacion y por el mismo
  -- motivo: lo que ya esta en la tabla final y vuelve a entrar es un cambio;
  -- lo que no estaba es un alta.
  --
  -- La llave es info_basica_id y no el par (info_basica_id, ciiu), porque es
  -- la que usa el LEFT JOIN de Severidad del legado (120.TPT:198-199).
  -- ------------------------------------------------------------
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_nov_acteco_flag;
  CREATE TABLE bdm_tempo.stg_mock_nov_acteco_flag
  DISTSTYLE KEY DISTKEY(info_basica_id)
  AS
  SELECT DISTINCT info_basica_id
  FROM bdm_datos.mat_info_actividad_economica_mock;

  -- ------------------------------------------------------------
  -- Paso 3: la etapa 1 (legado TMP_PERS_ACTIVIDAD_ECONOMIC, :1347-1382).
  --
  -- id va NULL: lo asigna el cargador como MAX(id) + row_number(), que es lo
  -- que hace la vista de staging del legado (120.TPT:177). Calcularlo aqui
  -- daria otra secuencia.
  --
  -- La ventana del DELTA es la misma que la de Ubicacion -- fecha contra el
  -- watermark, mas los nulos -- y por la misma razon: es el unico fechado que
  -- tenemos y no inventamos una semantica distinta para el mismo dato.
  -- ------------------------------------------------------------
  TRUNCATE TABLE bdm_tempo.stg_nov_acteco_etapa_1_mock;

  INSERT INTO bdm_tempo.stg_nov_acteco_etapa_1_mock (
    id, tipo_identificacion, numero_identificacion, ciiu,
    actividad_economica, version, fecha_reporte, info_basica_id, flag_op
  )
  SELECT id, tipo_identificacion, numero_identificacion, ciiu,
         actividad_economica, version, fecha_reporte, info_basica_id, flag_op
  FROM (
    SELECT
      CAST(NULL AS INTEGER)                        AS id,
      CAST(NULL AS VARCHAR(30))                    AS tipo_identificacion,  -- BLOQUEADA: falta V_Hom_Tip_Ident_Linea
      p.cod_pin_persona                            AS numero_identificacion,
      CAST(c.cod_act_econo_ciiu_fte AS VARCHAR(20)) AS ciiu,
      CAST(NULL AS VARCHAR(500))                   AS actividad_economica,  -- BLOQUEADA: falta V_ACTIVIDAD_ECONO_CIIU
      CAST(NULL AS INTEGER)                        AS version,              -- BLOQUEADA: falta V_ACTIVIDAD_ECONO_CIIU
      p.fecha_reporte,
      c.id_buro_persona                            AS info_basica_id,
      CAST(CASE WHEN p_modo = 'FULL'          THEN 'I'
                WHEN f.info_basica_id IS NULL THEN 'I'
                ELSE 'A' END AS VARCHAR(1))        AS flag_op,
      ROW_NUMBER() OVER (PARTITION BY c.cod_act_econo_ciiu_fte, c.id_buro_persona
                         ORDER BY p.fecha_reporte DESC NULLS LAST)          AS rn
    FROM      bdm_tempo.v_mock_ciiu_persona     c
    JOIN      bdm_tempo.stg_mock_nov_acteco_pers    p ON p.id_buro_persona = c.id_buro_persona
    LEFT JOIN bdm_tempo.stg_mock_nov_acteco_flag    f ON f.info_basica_id  = c.id_buro_persona
    -- El filtro del legado, literal (:1377). Nuestra vista ya lo garantiza con
    -- su propio WHERE, y se repite porque el mock no lo lleva.
    WHERE c.cod_act_econo_ciiu_fte IS NOT NULL
      AND ( p_modo = 'FULL'
            OR p.fecha_reporte >= p_watermark
            OR p.fecha_reporte IS NULL )
  ) z
  WHERE z.rn = 1;

  -- Las intermedias no sobreviven a la corrida: bdm_tempo es compartido y una
  -- tabla huerfana confunde al siguiente que mire. Mismo cierre que Ubicacion.
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_nov_acteco_pers;
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_nov_acteco_flag;

END;
$$;
