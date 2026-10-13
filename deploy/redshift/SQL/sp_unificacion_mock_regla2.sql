-- Orquestador Regla 2
-- MODO MOCK — lee v_mock_*/bdm_stage; NO usa edf_views ni v_xpm_*
-- Escenario: CALL escenarios R2 en orden
-- Fuente: bdm_stage → bdm_tempo.v_mock_* | Salida: bdm_datos.unificacion_direccion_mock | MODO MOCK
-- Generado: tools/gen_unificacion_mock_sps.py (espejo mock)

CREATE OR REPLACE PROCEDURE bdm_datos.sp_unificacion_mock_regla2(
    p_modo      VARCHAR,   -- FULL | DELTA (modo efectivo de la corrida)
    p_lote      INTEGER,   -- Lote_Corrida externo
    p_watermark DATE       -- frontera inferior inclusiva (solo aplica en DELTA)
)
NONATOMIC
LANGUAGE plpgsql
AS $$
BEGIN

  -- Limpiar leftover de corridas fallidas (CREATE TABLE AS no es IF NOT EXISTS)
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_regla2_insumo;
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_regla2_esc1_pares;
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_regla2_e1;
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_regla2_esc2_pares;
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_regla2_e2;
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_regla2_e03;
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_regla2_e03_a;
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_regla2_e03_e1;
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_regla2_e04;
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_regla2_e04_a;
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_regla2_e04_c1;
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_regla2_e04_ganador;
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_regla2_e04_e;
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_regla2_e05;
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_regla2_e05_a;
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_regla2_e05_pares;
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_regla2_e06_freq;
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_regla2_e06_pares;
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_motor_keys;
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_motor_ranked;
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_motor_insumo;

  CALL bdm_datos.sp_unificacion_mock_r2_preparar_insumo(p_modo, p_watermark);
  -- El diccionario se reconstruye DESPUES del insumo y ANTES de esc4: esc4 y
  -- esc6 consumen su frecuencia y el motor consume nomen/valor.
  CALL bdm_datos.sp_unificacion_mock_r2_construir_diccionario_complementos(p_modo, p_lote);
  CALL bdm_datos.sp_unificacion_mock_r2_esc1_complemento_vacio_esc2_substring_complemento(p_modo, p_lote);
  -- Orden del legado: cada etapa marca sus filas en stg_mock_regla2_e2 para que
  -- las POSTERIORES no las vuelvan a procesar.
  --   esc1/esc2 -> esc3 'L3' -> motor NIT 'X4' -> esc4 'B5'
  --             -> motor NIVEL 'A6' -> esc5 'C7' -> esc6
  -- Los dos sitios que crean direcciones (PRO_UnificacionR2.sql:1602 y :3423)
  -- van INTERCALADOS, no al final: por eso el motor son dos llamadas.
  CALL bdm_datos.sp_unificacion_mock_r2_esc3_sin_nit_misma_nomenclatura(p_modo, p_lote);
  CALL bdm_datos.sp_unificacion_mock_r2_motor_nit_empates_nuevas_direcciones(p_modo, p_lote);
  CALL bdm_datos.sp_unificacion_mock_r2_esc4_diccionario_frecuencia_complemento(p_modo, p_lote);
  -- SITIO 2 ('A6', etapa 5.1 del legado, PRO_UnificacionR2.sql:2250-3607).
  -- Va AQUI, entre esc4 y esc5, que es donde el legado lo intercala. Su
  -- poblacion (Tmp_Unificacion_E051_C) y la de esc5 (Tmp_Unificacion_E05_C)
  -- son los dos subcasos del escenario 5 y difieren en UN predicado: el sitio
  -- 2 toma los pares cuyos VALORES difieren y esc5 aquellos cuyos valores son
  -- iguales. No hay starvation entre ellos.
  CALL bdm_datos.sp_unificacion_mock_r2_motor_nivel_nueva_direccion(p_modo, p_lote);
  CALL bdm_datos.sp_unificacion_mock_r2_esc5_nomenclatura_menor_nivel_pierde(p_modo, p_lote);
  CALL bdm_datos.sp_unificacion_mock_r2_esc6_frecuencia_complemento_gana(p_modo, p_lote);

  -- ------------------------------------------------------------------
  -- CENSO DE ESCENARIOS (SLCOPRBA-1355)
  --
  -- Antes de dropear el staging, deja constancia de cuantas direcciones
  -- resolvio CADA escenario y cuantas no resolvio ninguno. El sello N_ID vive
  -- solo aqui; la tabla final guarda el par (direccion, padre) y no el motivo.
  --
  -- El catalogo de sellos va EXPLICITO y se cruza con LEFT JOIN a proposito:
  -- un sello que no produjo nada en la corrida aparece con 0 en vez de
  -- faltar. "Falta la fila" y "midio cero" no son lo mismo para quien lee el
  -- censo, y la diferencia importa: lo que no se ejecuta no da error, da cero
  -- en silencio.
  -- ------------------------------------------------------------------
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_regla2_censo;
  CREATE TABLE bdm_tempo.stg_mock_regla2_censo
  DISTSTYLE ALL
  AS
  SELECT b.bucket,
         COUNT(*)                          AS direcciones,
         COUNT(DISTINCT b.id_buro_persona) AS personas
  FROM (
    SELECT
      e.id_buro_persona,
      CASE
        WHEN e.n_id IS NOT NULL THEN e.n_id
        -- SLCOPRBA-1355: el PADRE de una unificacion no es una brecha.
        -- Cada escenario (salvo el motor) sella SOLO a la hija: el UPDATE
        -- matchea cod_dw_persona_ubic contra la tabla persist, que lleva las
        -- hijas. El padre se queda sin sello. Sin esta rama caia en
        -- SIN_RESOLVER, y en la primera corrida del censo (job #310) eso
        -- inflo la brecha de ~6000 a 31000: 25000 de esas filas eran los
        -- padres de las 25000 unificaciones que SI ocurrieron
        -- (H1 5000 + K2/L3/B5/C7/E6 4000 cada uno).
        -- El motor no sufre el problema porque marca el grupo COMPLETO, y por
        -- eso X4 da ~3 direcciones por persona.
        WHEN pad.id_padre IS NOT NULL THEN 'PADRE'
        -- "tenia pareja posible" = en su grupo hay al menos DOS complementos
        -- distintos, que es lo que todos los escenarios exigen para emparejar.
        -- Un grupo de un solo complemento no es una brecha: no hay con que
        -- unificar.
        --
        -- MIN/MAX de ventana y no COUNT(DISTINCT): Redshift no admite
        -- COUNT(DISTINCT) como funcion de ventana. Ademas PARTITION BY trata
        -- los NULL como iguales, que es lo que hace falta cuando
        -- texto_ubicacion llega nulo -- un JOIN los perderia.
        WHEN MIN(COALESCE(e.complemento, '')) OVER (
               PARTITION BY e.id_buro_persona, e.texto_ubicacion,
                            e.cod_dw_tipo_ubicacion_dir, e.cod_dw_municipio)
          <> MAX(COALESCE(e.complemento, '')) OVER (
               PARTITION BY e.id_buro_persona, e.texto_ubicacion,
                            e.cod_dw_tipo_ubicacion_dir, e.cod_dw_municipio)
        THEN 'SIN_RESOLVER'
        ELSE 'SIN_PAREJA'
      END AS bucket
    FROM bdm_tempo.stg_mock_regla2_e2 e
    LEFT JOIN ( SELECT DISTINCT id_padre
                  FROM bdm_tempo.stg_mock_regla2_e2
                 WHERE id_padre IS NOT NULL ) pad
      ON pad.id_padre = e.cod_dw_persona_ubic
  ) b
  GROUP BY 1;

  INSERT INTO bdm_datos.unif_escenario_censo_mock
    (lote, modo, n_id, escenario, ref_legado, direcciones, personas, fecha_hora, usuario_bd)
  SELECT
    p_lote, p_modo, c.n_id, c.escenario, c.ref_legado,
    COALESCE(r.direcciones, 0), COALESCE(r.personas, 0),
    CURRENT_TIMESTAMP, CURRENT_USER
  FROM (
    SELECT 'H1'           AS bucket, CAST('H1' AS VARCHAR(10)) AS n_id,
           CAST('esc1 - complemento vacio'                        AS VARCHAR(120)) AS escenario,
           CAST('PRO_UnificacionR2.sql linea 201'                 AS VARCHAR(80))  AS ref_legado UNION ALL
    SELECT 'K2', 'K2', 'esc2 - complemento substring de otro',
                       'PRO_UnificacionR2.sql linea 388'                    UNION ALL
    SELECT 'L3', 'L3', 'esc3 - sin NIT, misma nomenclatura',
                       'PRO_UnificacionR2.sql linea 1729'                   UNION ALL
    SELECT 'X4', 'X4', 'motor sitio 1 - direccion nueva fusionada',
                       'PRO_UnificacionR2.sql linea 1705'                   UNION ALL
    SELECT 'B5', 'B5', 'esc4 - mayor frecuencia en el diccionario',
                       'PRO_UnificacionR2.sql linea 2226'                   UNION ALL
    SELECT 'C7', 'C7', 'esc5 - gana la nomenclatura de menor nivel',
                       'PRO_UnificacionR2.sql linea 3991'                   UNION ALL
    SELECT 'E6', 'E6', 'esc6 - mayor frecuencia del complemento gana',
                       'sello AGREGADO: el legado no marca esc6'            UNION ALL
    SELECT 'A6', 'A6', 'sitio 2 (etapa 5.1) - direccion nueva por nivel distinto',
                       'PRO_UnificacionR2.sql linea 3423'                   UNION ALL
    SELECT 'PADRE', NULL, 'PADRE de una unificacion de esta corrida (no es brecha)',
                       'ninguno: el escenario sella solo a la hija'         UNION ALL
    SELECT 'SIN_RESOLVER', NULL, 'sin resolver, tenia pareja posible <- BRECHA',
                       'ninguno: es lo que el port no cubre'                UNION ALL
    SELECT 'SIN_PAREJA',   NULL, 'sin pareja posible (un solo complemento en el grupo)',
                       'ninguno: no es brecha, no hay con que unificar'
  ) c
  LEFT JOIN bdm_tempo.stg_mock_regla2_censo r
    ON r.bucket = c.bucket;

  DROP TABLE IF EXISTS bdm_tempo.stg_mock_regla2_censo;

  DROP TABLE IF EXISTS bdm_tempo.stg_mock_regla2_insumo;
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_regla2_esc1_pares;
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_regla2_e1;
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_regla2_esc2_pares;
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_regla2_e2;
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_regla2_e03;
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_regla2_e03_a;
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_regla2_e03_e1;
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_regla2_e04;
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_regla2_e04_a;
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_regla2_e04_c1;
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_regla2_e04_ganador;
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_regla2_e04_e;
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_regla2_e05;
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_regla2_e05_a;
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_regla2_e05_pares;
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_regla2_e06_freq;
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_regla2_e06_pares;
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_motor_keys;
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_motor_ranked;
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_motor_insumo;

END;
$$;
-- SLCOPRBA-1355: re-DPLY DEV post DROP SCHEMA strct #256
