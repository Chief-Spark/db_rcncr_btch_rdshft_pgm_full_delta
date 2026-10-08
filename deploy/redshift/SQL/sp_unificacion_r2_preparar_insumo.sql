-- R2 — materializar insumo
-- Escenario: común R2
-- Fuente: edf_views → bdm_tempo.v_xpm_* | Salida: bdm_datos.unificacion_direccion
-- Prerequisito: Regla 1 ejecutada
-- Generado: tools/gen_unificacion_sps_por_escenario.py

CREATE OR REPLACE PROCEDURE bdm_datos.sp_unificacion_r2_preparar_insumo(
    p_modo      VARCHAR,   -- FULL | DELTA (modo efectivo de la corrida)
    p_watermark DATE       -- frontera inferior inclusiva (solo aplica en DELTA)
)
NONATOMIC
LANGUAGE plpgsql
AS $$
BEGIN

  DROP TABLE IF EXISTS bdm_tempo.stg_regla2_insumo;
  DROP TABLE IF EXISTS bdm_tempo.stg_regla2_e2;
  CREATE TABLE bdm_tempo.stg_regla2_insumo
  DISTSTYLE KEY DISTKEY(id_buro_persona)
  AS
  SELECT
    rpu.cod_dw_persona_ubic,
    rpu.cod_pin_persona,
    rpu.id_buro_persona,
    rpu.cod_dw_tipo_ubicacion_dir,
    rpu.cod_dw_ubic,
    ubi.texto_ubicacion,
    rpu.cod_dw_direccion_fisica,
    df.complemento,
    ubi.cod_dw_ciudad AS cod_dw_municipio,
    COALESCE(COUNT(DISTINCT rep.id_buro_suscriptor), 0) AS numero_entidades_reportan,
    rpu.fecha_relacion_persona_ubicaci,
    rpu.cod_tipo_ident_fte,
    rpu.lote
  FROM bdm_tempo.v_xpm_relacion_persona_ubicacion rpu
  JOIN bdm_tempo.v_xpm_ubicacion_estandarizada ubi
    ON rpu.cod_dw_ubic = ubi.cod_dw_ubic
  LEFT JOIN bdm_tempo.v_xpm_direccion_fisica df
    ON rpu.cod_dw_direccion_fisica = df.cod_dw_direccion_fisica
  JOIN bdm_tempo.v_xpm_reporte_relacion_persona_ubica rep
    ON rpu.cod_dw_persona_ubic = rep.cod_dw_persona_ubic
  WHERE 1 = 1
    -- FULL: sin frontera de fecha (Req 3.3)
    -- DELTA: ventana inclusiva por dia + nulos (Req 3.1, 3.2)
    AND ( p_modo = 'FULL'
          OR rpu.fecha_relacion_persona_ubicaci >= p_watermark
          OR rpu.fecha_relacion_persona_ubicaci IS NULL )
  GROUP BY 1,2,3,4,5,6,7,8,9,11,12,13;


END;
$$;
-- SLCOPRBA-1355: re-DPLY DEV post DROP SCHEMA strct #256
