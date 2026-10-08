-- R1 — materializar insumo
-- MODO MOCK — lee v_mock_*/bdm_stage; NO usa edf_views ni v_xpm_*
-- Escenario: común R1
-- Fuente: bdm_stage → bdm_tempo.v_mock_* | Salida: bdm_datos.unificacion_direccion_mock | MODO MOCK
-- Prerequisito: vistas v_mock_* + seed bdm_stage
-- Generado: tools/gen_unificacion_mock_sps.py (espejo mock)

CREATE OR REPLACE PROCEDURE bdm_datos.sp_unificacion_mock_r1_preparar_insumo(
    p_modo      VARCHAR,   -- FULL | DELTA (modo efectivo de la corrida)
    p_watermark DATE       -- frontera inferior inclusiva (solo aplica en DELTA)
)
NONATOMIC
LANGUAGE plpgsql
AS $$
BEGIN

  DROP TABLE IF EXISTS bdm_tempo.stg_mock_regla1_insumo;
  CREATE TABLE bdm_tempo.stg_mock_regla1_insumo
  DISTSTYLE KEY DISTKEY(id_buro_persona)
  SORTKEY(id_buro_persona, texto_ubicacion)
  AS
  SELECT
    rpu.cod_dw_persona_ubic,
    rpu.id_buro_persona,
    ubi.texto_ubicacion,
    df.complemento,
    ubi.cod_dw_ciudad,
    rpu.cod_dw_tipo_ubicacion_dir,
    COALESCE(ciiu.cod_act_econo_ciiu_fte, '') AS cod_act_econo_ciiu_fte,
    COALESCE(COUNT(DISTINCT rep.id_buro_suscriptor), 0) AS numero_entidades_reportan,
    tud.descripcion_tipo_ubicacion_dir AS tipo_direccion
  FROM bdm_tempo.v_mock_relacion_persona_ubicacion rpu
  JOIN bdm_tempo.v_mock_ubicacion_estandarizada ubi ON rpu.cod_dw_ubic = ubi.cod_dw_ubic
  LEFT JOIN bdm_tempo.v_mock_direccion_fisica df ON rpu.cod_dw_direccion_fisica = df.cod_dw_direccion_fisica
  JOIN bdm_tempo.v_mock_reporte_relacion_persona_ubica rep ON rpu.cod_dw_persona_ubic = rep.cod_dw_persona_ubic
  LEFT JOIN bdm_tempo.v_mock_ciiu_persona ciiu ON rpu.id_buro_persona = ciiu.id_buro_persona
  LEFT JOIN bdm_stage.tipo_ubicacion_dir tud ON rpu.cod_dw_tipo_ubicacion_dir = tud.cod_dw_tipo_ubicacion_dir
  WHERE 1 = 1
    -- FULL: sin frontera de fecha (Req 3.3)
    -- DELTA: ventana inclusiva por dia + nulos (Req 3.1, 3.2)
    AND ( p_modo = 'FULL'
          OR rpu.fecha_relacion_persona_ubicaci >= p_watermark
          OR rpu.fecha_relacion_persona_ubicaci IS NULL )
  GROUP BY 1,2,3,4,5,6,7,9;

END;
$$;
-- SLCOPRBA-1355: re-DPLY DEV post DROP SCHEMA strct #256
