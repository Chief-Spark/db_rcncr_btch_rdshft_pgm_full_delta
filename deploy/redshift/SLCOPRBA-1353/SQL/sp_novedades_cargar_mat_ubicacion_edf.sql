-- Novedades - carga de la tabla final del dominio UBICACION
-- Port de lo que en el legado hacen los dos TPT, no un SP:
--   P0035_Extractor_Novedades_120.TPT:86-176  vista Vstg_Reconocer_Info_Ubica
--   P0035_Extractor_Novedades_130.TPT:215     filtro Severidad <> -1
--   P0035_Extractor_Novedades_130.TPT:573-703 UPSERT y DELETE por ID
-- Fuente: bdm_tempo.stg_nov_ubica_etapa_9 | Salida: bdm_datos.mat_info_ubicacion
--
-- QUE ES SEVERIDAD Y POR QUE AQUI NO HACE FALTA CALCULARLA.
--   En el legado la vista de staging compara cada fila contra la tabla viva
--   por LEFT JOIN (120.TPT:174-175) y emite 1 para alta o cambio, 2 para
--   baja y -1 para "sin cambio"; el TPT descarta los -1. Nuestra etapa 9 ya
--   trae flag_op con esa misma informacion (I, A, E), calculada contra la
--   misma tabla viva, de modo que el filtro es flag_op IS NOT NULL.
--
-- UPSERT SIN MERGE: se borra la llave y se vuelve a insertar, dentro del
--   mismo procedimiento. Es el idioma que ya usa el resto de la cadena y no
--   depende de la version de Redshift. Los dos DELETE llevan WHERE explicito
--   [REDSHIFT:232].

CREATE OR REPLACE PROCEDURE bdm_datos.sp_novedades_cargar_mat_ubicacion_edf(
    p_lote INTEGER
)
NONATOMIC
LANGUAGE plpgsql
AS $$
BEGIN

  -- 1) Baja: la fila bloqueada desaparece de la tabla final (130.TPT:703).
  DELETE FROM bdm_datos.mat_info_ubicacion
  WHERE id IN ( SELECT id
                  FROM bdm_tempo.stg_nov_ubica_etapa_9
                 WHERE flag_op = 'E' );

  -- 2) Alta y cambio: se retira la version anterior de las llaves que vuelven
  --    a entrar, para que el INSERT siguiente no duplique.
  DELETE FROM bdm_datos.mat_info_ubicacion
  WHERE id IN ( SELECT id
                  FROM bdm_tempo.stg_nov_ubica_etapa_9
                 WHERE flag_op IN ('I', 'A') );

  INSERT INTO bdm_datos.mat_info_ubicacion (
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
  FROM bdm_tempo.stg_nov_ubica_etapa_9
  WHERE flag_op IN ('I', 'A');

END;
$$;
