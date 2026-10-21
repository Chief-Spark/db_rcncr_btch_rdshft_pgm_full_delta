-- Novedades - dominio INFO BASICA (ESPEJO MOCK)
-- Espejo del real. Generado por
-- SUSTITUCION DE FUENTES: no se edita a mano. Regenerar con
-- tools/gen_novedades_espejo_inbas.py.
-- Solo cambian tres nombres: el procedimiento, la tabla final y la
-- vista de insumo. El diff contra el real debe salir vacio modulo
-- esos nombres. Las justificaciones viven en el archivo real.

CREATE OR REPLACE PROCEDURE bdm_datos.sp_novedades_info_basica_mock(
    p_lote INTEGER
)
NONATOMIC
LANGUAGE plpgsql
AS $$
BEGIN

  TRUNCATE TABLE bdm_datos.mat_info_basica_mock;

  INSERT INTO bdm_datos.mat_info_basica_mock (
    id, primer_nombre, segundo_nombre, primer_apellido, segundo_apellido,
    nombre_completo, cod_tipo_ident_fte, tipo_identificacion,
    numero_identificacion, estado_documento, rango_edad, lugar_expedicion,
    fecha_expedicion, genero, ciiu, actividad_economica, razon_social,
    pagina_web, mosaic_id, departamento_expedicion, cod_pin_persona, rut,
    lote, fecha_actualizacion, usuario_bd
  )
  SELECT pb.id_buro_persona,
         pb.primer_nombre,
         pb.segundo_nombre,
         pb.primer_apellido,
         pb.segundo_apellido,
         pb.nombre_completo,
         pb.cod_tipo_ident_fte,
         pb.tipo_identificacion,
         pb.numero_identificacion,
         pb.estado_documento,
         pb.rango_edad,
         pb.lugar_expedicion,
         pb.fecha_expedicion,
         pb.genero,
         pb.ciiu,
         pb.actividad_economica,
         pb.razon_social,
         pb.pagina_web,
         pb.mosaic_id,
         pb.departamento_expedicion,
         pb.cod_pin_persona,
         pb.rut,
         p_lote, GETDATE(), CURRENT_USER
  FROM bdm_tempo.v_mock_persona_basica pb
  -- Sin id no hay llave, y una fila sin llave no la puede leer nadie: el
  -- UPSERT del legado une por ID y una fila con ID nulo no casa ni con ella
  -- misma. Se descarta aqui en vez de dejarla entrar y ensuciar el conteo.
  WHERE pb.id_buro_persona IS NOT NULL;

END;
$$;
