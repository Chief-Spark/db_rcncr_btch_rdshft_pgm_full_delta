-- Novedades - carga de la tabla final del dominio UBICACION (ESPEJO MOCK)
-- Espejo de sp_novedades_cargar_mat_ubicacion_edf.sql. Generado por SUSTITUCION DE
-- FUENTES: no se edita a mano. Regenerar con
-- tools/gen_novedades_espejo_mock_resto.py.
-- Solo cambian los nombres de los objetos: _edf -> _mock en los
-- procedimientos, y sufijo _mock en las tablas que lee y escribe.
-- El diff contra el real debe salir vacio modulo esos nombres.

CREATE OR REPLACE PROCEDURE bdm_datos.sp_novedades_cargar_mat_ubicacion_mock(
    p_lote INTEGER
)
NONATOMIC
LANGUAGE plpgsql
AS $$
BEGIN

  -- 1) Baja: la fila bloqueada desaparece de la tabla final (130.TPT:703).
  DELETE FROM bdm_datos.mat_info_ubicacion_mock
  WHERE id IN ( SELECT id
                  FROM bdm_tempo.stg_nov_ubica_etapa_9_mock
                 WHERE flag_op = 'E' );

  -- 2) Alta y cambio: se retira la version anterior de las llaves que vuelven
  --    a entrar, para que el INSERT siguiente no duplique.
  DELETE FROM bdm_datos.mat_info_ubicacion_mock
  WHERE id IN ( SELECT id
                  FROM bdm_tempo.stg_nov_ubica_etapa_9_mock
                 WHERE flag_op IN ('I', 'A') );

  INSERT INTO bdm_datos.mat_info_ubicacion_mock (
    cod_tipo_ident_fte, tipo_identificacion, numero_identificacion, id, orden,
    indicativo, dato, estrato, tipo, zona, ciudad, departamento,
    longitud, latitud, reportado_desde, ultimo_reporte, fuente,
    numero_reportes, numero_entidades, barrio, localidad, codigo_postal,
    clase, info_basica, codigo_dane,
    es_tipo_crr, es_tipo_res, es_tipo_ppl, es_tipo_agn, es_tipo_suc,
    es_tipo_est, es_tipo_cdi, es_tipo_lab, tipo_cuenta,
    cod_dw_ubic, cod_dw_direccion_fisica, cod_dw_telefono,
    cod_dw_direccion_electronica, ind_unificacion, cod_dw_tipo_ubicacion_dir,
    cod_pin_persona, flag_op, lote, fecha_actualizacion, usuario_bd
  )
  SELECT
    cod_tipo_ident_fte, tipo_identificacion, numero_identificacion, id, orden,
    indicativo, dato, estrato, tipo, zona, ciudad, departamento,
    longitud, latitud, reportado_desde, ultimo_reporte, fuente,
    numero_reportes, numero_entidades, barrio, localidad, codigo_postal,
    clase, info_basica, codigo_dane,
    es_tipo_crr, es_tipo_res, es_tipo_ppl, es_tipo_agn, es_tipo_suc,
    es_tipo_est, es_tipo_cdi, es_tipo_lab, tipo_cuenta,
    cod_dw_ubic, cod_dw_direccion_fisica, cod_dw_telefono,
    cod_dw_direccion_electronica, ind_unificacion, cod_dw_tipo_ubicacion_dir,
    cod_pin_persona,
    -- El codigo numerico del legado (120.TPT:169-173): I -> 1, A -> 2, E -> 3.
    CASE WHEN flag_op = 'I' THEN 1
         WHEN flag_op = 'A' THEN 2
         WHEN flag_op = 'E' THEN 3 END,
    p_lote, GETDATE(), CURRENT_USER
  FROM bdm_tempo.stg_nov_ubica_etapa_9_mock
  WHERE flag_op IN ('I', 'A');

END;
$$;
