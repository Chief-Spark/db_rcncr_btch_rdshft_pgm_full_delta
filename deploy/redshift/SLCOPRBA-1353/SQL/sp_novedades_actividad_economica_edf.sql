-- Novedades - dominio ACTIVIDAD ECONOMICA
-- Port de PRO_Novedad_Linea_Historial (Novedad.sql:1060-1420), que a pesar
-- del nombre es el SP que produce MAT_INFO_ACTIVIDAD_ECONOMICA. La
-- nomenclatura del legado esta cruzada; manda el 120.TPT, no el nombre.
--
-- Salida: bdm_tempo.stg_nov_acteco_etapa_1 (legado TMP_PERS_ACTIVIDAD_ECONOMIC).
-- La carga a la tabla final la hace sp_novedades_cargar_mat_acteco_edf, que es
-- el port de los dos TPT -- misma particion en dos piezas que en Ubicacion.
--
-- NONATOMIC en toda la cadena de CALL (leccion #13).
--
-- ------------------------------------------------------------
-- LAS CUATRO DIVERGENCIAS, TODAS POR INSUMO QUE NO TENEMOS.
--
-- DIVERGENCIA 1. El legado arma su universo de V_PERSONA_ACT_ECONOMICA_CIIU,
--   que trae COD_DW_ACT_ECONO_CIIU, FECHA_REPORTE e INFO_BASICA_ID por fila.
--   Nosotros leemos v_xpm_actividad_economica_persona, que son DOS columnas:
--   id_buro_persona y cod_act_econo_ciiu_fte.
--   2026-10-21 (D-NOV-06): ANTES ERA v_xpm_ciiu_persona, que trae SOLO el
--   CIIU principal, y el legado toma TODAS las actividades de la persona
--   (Novedad.sql:1280-1294, PRIMARY INDEX(INFO_BASICA_ID,
--   COD_DW_ACT_ECONO_CIIU)). La vista nueva une las once fuentes del
--   datashare: el principal de bestpersonalinformation, el principal y las
--   cuatro secundarias de personalinformation, y las mismas cinco de
--   chamberofcommerce.
--   NO se amplio v_xpm_ciiu_persona: la Regla 1 de Unificacion la une por
--   persona con un LEFT JOIN y mas de una fila le multiplicaria el insumo.
--   (02_vistas_insumo_edf_views.sql:364-370). El CIIU viene directo del
--   datashare, en bestpersonalinformation.mainisiccodeforproduct.
--
-- DIVERGENCIA 2. ACTIVIDAD_ECONOMICA y VERSION salen del catalogo
--   V_ACTIVIDAD_ECONO_CIIU (Novedad.sql:1352-1354), que NO se entrego: no
--   esta en los diez CSV de novedades_mapeo_y_catalogos.zip. Salen NULL y los
--   criterios NOV-AE-06 y NOV-AE-07 lo dejan por escrito en vez de callarlo.
--
-- DIVERGENCIA 3, Y ES DE GRANO. El legado toma
--   COALESCE(VPAE.FECHA_REPORTE, VPJC.Fecha_Matricula) (:1355), con grano por
--   (persona, CIIU). Nuestro unico fechado es cutoffdate, que vive en
--   v_xpm_reporte_relacion_persona_ubica con grano por UBICACION, asi que
--   aqui se agrega con MAX por persona. Es "la fecha mas reciente en que se
--   vio a la persona", no la del reporte de su CIIU.
--   V_Persona_Juridica_Camara no esta en el datashare y por eso la rama de
--   Fecha_Matricula no se porta: no hay de donde.
--
-- DIVERGENCIA 4. TIPO_IDENTIFICACION necesita V_Hom_Tip_Ident_Linea, el mismo
--   catalogo que ya bloquea la columna homonima en Ubicacion (NOV-UB-18).
--   Sale NULL.
--
-- ------------------------------------------------------------
-- LA DEDUPLICACION SE PORTA AUNQUE EN LA VIA REAL SEA REDUNDANTE, y conviene
-- saber por que esta. El legado cierra con
--   QUALIFY ROW_NUMBER() OVER(PARTITION BY CIIU, INFO_BASICA_ID
--                             ORDER BY Version DESC, Fecha_Reporte DESC,
--                                      Fecha_Matricula DESC) = 1   (:1379)
-- En la via REAL v_xpm_ciiu_persona ya hace SELECT DISTINCT sobre justo esas
-- dos columnas, de modo que el grano esta garantizado y el ROW_NUMBER no
-- quitaria una sola fila. En la via MOCK no: v_mock_ciiu_persona lee
-- bdm_stage.ciiu_persona SIN DISTINCT (02b_vistas_insumo_mock.sql:245-250).
-- Quitarlo haria que las dos vias contaran distinto ante una semilla
-- repetida. Se porta.
--   Nota sobre el ORDER BY: version y fecha_matricula son NULL en nuestra via,
--   asi que el desempate efectivo es por fecha_reporte. NULLS LAST explicito,
--   porque Redshift pone NULLS FIRST en DESC y Teradata hace lo contrario.

CREATE OR REPLACE PROCEDURE bdm_datos.sp_novedades_actividad_economica_edf(
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
  DROP TABLE IF EXISTS bdm_tempo.stg_nov_acteco_pers;
  CREATE TABLE bdm_tempo.stg_nov_acteco_pers
  DISTSTYLE KEY DISTKEY(id_buro_persona)
  AS
  SELECT rpu.id_buro_persona,
         MAX(rpu.cod_pin_persona) AS cod_pin_persona,
         MAX(r.fecha_reporte)     AS fecha_reporte
  FROM      bdm_tempo.v_xpm_relacion_persona_ubicacion rpu
  LEFT JOIN bdm_tempo.v_xpm_reporte_relacion_persona_ubica r
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
  DROP TABLE IF EXISTS bdm_tempo.stg_nov_acteco_flag;
  CREATE TABLE bdm_tempo.stg_nov_acteco_flag
  DISTSTYLE KEY DISTKEY(info_basica_id)
  AS
  SELECT DISTINCT info_basica_id
  FROM bdm_datos.mat_info_actividad_economica;

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
  TRUNCATE TABLE bdm_tempo.stg_nov_acteco_etapa_1;

  INSERT INTO bdm_tempo.stg_nov_acteco_etapa_1 (
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
    FROM      bdm_tempo.v_xpm_actividad_economica_persona     c
    JOIN      bdm_tempo.stg_nov_acteco_pers    p ON p.id_buro_persona = c.id_buro_persona
    LEFT JOIN bdm_tempo.stg_nov_acteco_flag    f ON f.info_basica_id  = c.id_buro_persona
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
  DROP TABLE IF EXISTS bdm_tempo.stg_nov_acteco_pers;
  DROP TABLE IF EXISTS bdm_tempo.stg_nov_acteco_flag;

END;
$$;
