-- Orquestador Regla 2
-- Escenario: CALL escenarios R2 en orden
-- Fuente: edf_views → bdm_tempo.v_xpm_* | Salida: bdm_datos.unificacion_direccion
-- Generado: tools/gen_unificacion_sps_por_escenario.py

-- Firma Framework Batch (6 params VARCHAR): in_solicitud, in_nit_suscriptor,
-- in_path_archivo, in_nemotecnico, in_id_facturacion, in_fecha_ejecucion.
-- Los parametros no se usan en la logica de unificacion (procesa edf_views completo).
CREATE OR REPLACE PROCEDURE bdm_datos.sp_unificacion_regla2(
    in_solicitud       VARCHAR,
    in_nit_suscriptor  VARCHAR,
    in_path_archivo    VARCHAR,
    in_nemotecnico     VARCHAR,
    in_id_facturacion  VARCHAR,
    in_fecha_ejecucion VARCHAR
)
NONATOMIC
LANGUAGE plpgsql
AS $$
DECLARE
  -- (Tarea 6.1) El orquestador maestro re-emite en los slots 4/5/6 del
  -- Framework_Batch: in_nemotecnico=Modo_Corrida, in_id_facturacion=Lote_Corrida,
  -- in_fecha_ejecucion=Watermark (frontera inferior inclusiva de la ventana
  -- DELTA; NO es la Fecha_Proceso). Se derivan aqui y se propagan a
  -- preparar_insumo(p_modo, p_watermark) y a cada escenario(p_modo, p_lote);
  -- ningun escenario re-parsea el Framework_Batch.
  p_modo      VARCHAR := NULLIF(UPPER(TRIM(COALESCE(in_nemotecnico, ''))), '');
  p_lote      INTEGER := CAST(NULLIF(TRIM(COALESCE(in_id_facturacion, '')), '') AS INTEGER);
  p_watermark DATE    := CAST(NULLIF(TRIM(COALESCE(in_fecha_ejecucion, '')), '') AS DATE);
BEGIN

  IF p_modo IS NULL THEN
    p_modo := 'FULL';   -- FULL por defecto (no romper lo desplegado, Req 10.1).
  END IF;

  CALL bdm_datos.sp_unificacion_r2_preparar_insumo(p_modo, p_watermark);
  -- El diccionario se reconstruye DESPUES del insumo y ANTES de esc4: esc4 y
  -- esc6 consumen su frecuencia y el motor consume nomen/valor.
  CALL bdm_datos.sp_unificacion_r2_construir_diccionario_complementos(p_modo, p_lote);
  CALL bdm_datos.sp_unificacion_r2_esc1_complemento_vacio_esc2_substring_complemento(p_modo, p_lote);
  -- Orden del legado: cada etapa marca sus filas en stg_regla2_e2 para que
  -- las POSTERIORES no las vuelvan a procesar.
  --   esc1/esc2 -> esc3 'L3' -> motor NIT 'X4' -> esc4 'B5'
  --             -> motor NIVEL 'A6' -> esc5 'C7' -> esc6
  -- Los dos sitios que crean direcciones (PRO_UnificacionR2.sql:1602 y :3423)
  -- van INTERCALADOS, no al final: por eso el motor son dos llamadas.
  CALL bdm_datos.sp_unificacion_r2_esc3_sin_nit_misma_nomenclatura(p_modo, p_lote);
  CALL bdm_datos.sp_unificacion_r2_motor_nit_empates_nuevas_direcciones(p_modo, p_lote);
  CALL bdm_datos.sp_unificacion_r2_esc4_diccionario_frecuencia_complemento(p_modo, p_lote);
  -- SITIO 2 ('A6', etapa 5.1 del legado) NO IMPLEMENTADO. Su poblacion base
  -- si esta leida (Tmp_Unificacion_E051, PRO_UnificacionR2.sql:2280: grupo sin
  -- unificar con complemento distinto, SIN filtro de NIT ni de nomenclatura),
  -- pero NO la regla con que elige al padre: eso vive en el pivote dinamico de
  -- E051_A / E051_D (lineas 2331-2900), que genera SQL dinamico sobre hasta 15
  -- posiciones de componente. Implementarlo por analogia con esc5 seria una
  -- suposicion, y ademas starveria a esc5 (misma poblacion, el sitio 2 corre
  -- antes), cambiando el resultado de los arquetipos ya certificados. Queda
  -- pendiente hasta decodificar ese pivote.
  CALL bdm_datos.sp_unificacion_r2_esc5_nomenclatura_menor_nivel_pierde(p_modo, p_lote);
  CALL bdm_datos.sp_unificacion_r2_esc6_frecuencia_complemento_gana(p_modo, p_lote);

  -- ------------------------------------------------------------------
  -- CENSO DE ESCENARIOS (SLCOPRBA-1355)
  --
  -- Antes de dropear el staging, deja constancia de cuantas direcciones
  -- resolvio CADA escenario y cuantas no resolvio ninguno. El sello N_ID vive
  -- solo aqui; la tabla final guarda el par (direccion, padre) y no el motivo.
  --
  -- El catalogo de sellos va EXPLICITO y se cruza con LEFT JOIN a proposito:
  -- asi 'A6' -- el sitio 2, que no esta implementado -- aparece con 0 en vez
  -- de faltar. "Falta la fila" y "midio cero" no son lo mismo para quien lee
  -- el censo, y la diferencia importa: lo que no esta implementado no da
  -- error, da cero en silencio.
  -- ------------------------------------------------------------------
  DROP TABLE IF EXISTS bdm_tempo.stg_regla2_censo;
  CREATE TABLE bdm_tempo.stg_regla2_censo
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
    FROM bdm_tempo.stg_regla2_e2 e
  ) b
  GROUP BY 1;

  INSERT INTO bdm_datos.unif_escenario_censo
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
    SELECT 'A6', 'A6', 'sitio 2 (etapa 5.1) - NO IMPLEMENTADO',
                       'PRO_UnificacionR2.sql lineas 3533 y 3573'           UNION ALL
    SELECT 'SIN_RESOLVER', NULL, 'sin resolver, tenia pareja posible <- BRECHA',
                       'ninguno: es lo que el port no cubre'                UNION ALL
    SELECT 'SIN_PAREJA',   NULL, 'sin pareja posible (un solo complemento en el grupo)',
                       'ninguno: no es brecha, no hay con que unificar'
  ) c
  LEFT JOIN bdm_tempo.stg_regla2_censo r
    ON r.bucket = c.bucket;

  DROP TABLE IF EXISTS bdm_tempo.stg_regla2_censo;

  DROP TABLE IF EXISTS bdm_tempo.stg_regla2_insumo;
  DROP TABLE IF EXISTS bdm_tempo.stg_regla2_esc1_pares;
  DROP TABLE IF EXISTS bdm_tempo.stg_regla2_e1;
  DROP TABLE IF EXISTS bdm_tempo.stg_regla2_esc2_pares;
  DROP TABLE IF EXISTS bdm_tempo.stg_regla2_e2;
  DROP TABLE IF EXISTS bdm_tempo.stg_regla2_e03;
  DROP TABLE IF EXISTS bdm_tempo.stg_regla2_e03_a;
  DROP TABLE IF EXISTS bdm_tempo.stg_regla2_e03_e1;
  DROP TABLE IF EXISTS bdm_tempo.stg_regla2_e04;
  DROP TABLE IF EXISTS bdm_tempo.stg_regla2_e04_a;
  DROP TABLE IF EXISTS bdm_tempo.stg_regla2_e04_c1;
  DROP TABLE IF EXISTS bdm_tempo.stg_regla2_e04_ganador;
  DROP TABLE IF EXISTS bdm_tempo.stg_regla2_e04_e;
  DROP TABLE IF EXISTS bdm_tempo.stg_regla2_e05;
  DROP TABLE IF EXISTS bdm_tempo.stg_regla2_e05_a;
  DROP TABLE IF EXISTS bdm_tempo.stg_regla2_e05_pares;
  DROP TABLE IF EXISTS bdm_tempo.stg_regla2_e06_freq;
  DROP TABLE IF EXISTS bdm_tempo.stg_regla2_e06_pares;
  DROP TABLE IF EXISTS bdm_tempo.stg_motor_nit_cand;
  DROP TABLE IF EXISTS bdm_tempo.stg_motor_nit_mdir;
  DROP TABLE IF EXISTS bdm_tempo.stg_motor_nit_base;
  DROP TABLE IF EXISTS bdm_tempo.stg_motor_nit_grupo;
  DROP TABLE IF EXISTS bdm_tempo.stg_motor_nit_pares;
  DROP TABLE IF EXISTS bdm_tempo.stg_motor_nit_componentes;
  DROP TABLE IF EXISTS bdm_tempo.stg_motor_nit_nueva_nomen;
  DROP TABLE IF EXISTS bdm_tempo.stg_motor_nit_fusion;
  DROP TABLE IF EXISTS bdm_tempo.stg_motor_nit_insumo;
  DROP TABLE IF EXISTS bdm_tempo.stg_motor_nit_miembros;
  DROP TABLE IF EXISTS bdm_tempo.stg_motor_nit_persist;

EXCEPTION WHEN OTHERS THEN
  RAISE EXCEPTION 'sp_unificacion_regla2 failed: %', SQLERRM;
END;
$$;
-- SLCOPRBA-1355: re-DPLY DEV post DROP SCHEMA strct #256
