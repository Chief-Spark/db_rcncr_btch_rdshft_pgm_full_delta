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
  -- SITIO 2 ('A6', etapa 5.1 del legado) NO IMPLEMENTADO. Su poblacion base
  -- si esta leida (Tmp_Unificacion_E051, PRO_UnificacionR2.sql:2280: grupo sin
  -- unificar con complemento distinto, SIN filtro de NIT ni de nomenclatura),
  -- pero NO la regla con que elige al padre: eso vive en el pivote dinamico de
  -- E051_A / E051_D (lineas 2331-2900), que genera SQL dinamico sobre hasta 15
  -- posiciones de componente. Implementarlo por analogia con esc5 seria una
  -- suposicion, y ademas starveria a esc5 (misma poblacion, el sitio 2 corre
  -- antes), cambiando el resultado de los arquetipos ya certificados. Queda
  -- pendiente hasta decodificar ese pivote.
  CALL bdm_datos.sp_unificacion_mock_r2_esc5_nomenclatura_menor_nivel_pierde(p_modo, p_lote);
  CALL bdm_datos.sp_unificacion_mock_r2_esc6_frecuencia_complemento_gana(p_modo, p_lote);

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
