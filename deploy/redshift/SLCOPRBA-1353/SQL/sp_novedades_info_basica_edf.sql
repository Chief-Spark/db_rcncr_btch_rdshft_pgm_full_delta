-- ============================================================
-- sp_novedades_info_basica_edf.sql
-- SLCOPRBA-1399: dominio INFO BASICA de Novedades (d4), via REAL.
-- (repo pgm / db_rcncr_btch_rdshft_pgm)
-- UTF-8 sin BOM. Sin acentos a proposito.
--
-- LEGADO: PRO_Novedad_Linea_Info_Basica (Novedad.sql:2166-3920), doce etapas.
--
-- ------------------------------------------------------------
-- NO ES UN PORT DE LAS DOCE ETAPAS: ES UNA RE-ESPECIFICACION, igual que la
-- Fase 1 del Ordenamiento, y conviene no volver a abrirlo.
--
-- El trabajo entero de esas etapas es elegir, por persona, el valor MAS
-- CONFIABLE de cada atributo: arrastran pares de columnas (NOMBRE_1 y
-- NOMBRE_1_2, GENERO y GENERO_2, ...) a traves de siete joins contra
-- V_RELACION_PERSONA_UBICACION, V_UBICACION_ESTANDARIZADA, V_GEOGRAFIA y los
-- catalogos, y la etapa 9_1 resuelve con COALESCE(valor_2, valor)
-- (Novedad.sql:3447-3466). En EDF esa eleccion YA ESTA HECHA: las secciones
-- bestName, bestIdentifications y bestPersonalInformation SON el registro
-- mas confiable. Lo que faltaba no era codigo de negocio.
--
-- El detalle de la derivacion columna por columna vive en la vista
-- bdm_tempo.v_xpm_persona_basica (strct/02_vistas_insumo_edf_views.sql) y no
-- se duplica aqui. Lo que importa saber en este archivo:
--
--   DIECINUEVE de las 22 columnas se pueblan.
--   TRES salen en NULL, cada una por su motivo:
--     tipo_identificacion -> falta V_Hom_Tip_Ident_Linea (C37). El CODIGO si
--         se puebla; falta la descripcion homologada. Se desbloquea con el
--         catalogo, sin tocar codigo.
--     pagina_web -> NO EXISTE EN EDF. El campo WebSite del contrato Alpha
--         esta marcado "NO APLICA (NO EXISTE CAMPO EN ALPHA)" (Confluence
--         CCBR 251264543, 2026-10-21). No hay nada que pedir.
--     mosaic_id -> Mosaic fuera por decision legal (D-NOV-07).
--
-- ------------------------------------------------------------
-- EL UNIVERSO ES LA PERSONA, NO LA UBICACION, y eso lo separa de los otros
-- cuatro dominios. El legado parte de TMP_INBAS_ETAPA_1, que sale de
-- V_RELACION_PERSONA_UBICACION (Novedad.sql:2387-2399), pero termina en la
-- UNION de dos ramas (:3778-3784):
--     TMP_INBAS_ETAPA_9_1  personas CON datos de ubicacion
--     TMP_INBAS_ETAPA_9_2  personas SIN datos de ubicacion
-- O sea que el dominio NO se acota por ubicacion: la union vuelve a abrir el
-- universo a toda persona. Por eso esta etapa lee la vista de persona
-- directamente y no la etapa 9 de Ubicacion, al contrario de
-- CONTACTABILIDAD, que si se acota (INNER JOIN TMP_UBICA_ETAPA_9).
--   ESO IMPORTA PARA EL ORDEN EN EL ORQUESTADOR: este dominio no depende de
--   Ubicacion y podria ir primero. Se deja DESPUES por el orden en que el
--   111.BTQ invoca los SP del legado, y porque un orden estable es mas facil
--   de leer que uno optimo.
--
-- GRANO: una fila por persona. La llave de la tabla es ID SOLA -- el UPSERT
-- une por STG.ID = B.ID (120.TPT:261-262) --, y la vista ya garantiza una
-- fila por persona (el ranking de identificaciones va dentro de ella). Aqui
-- no hay ningun join que pueda multiplicar.
--
-- CONTRATO DE CARGA: FOTO COMPLETA, igual que el AS-IS (111.BTQ:820 hace
-- DELETE ... ALL antes de cargar). TRUNCATE + INSERT, y por eso no hay
-- cargador aparte ni tabla de Severidad.
--
-- FIRMA: (INTEGER). No es orquestador: recibe solo el lote, igual que los
-- cargadores y que sp_novedades_contactabilidad_edf.
-- NONATOMIC en toda la cadena de CALL.
-- ============================================================
CREATE OR REPLACE PROCEDURE bdm_datos.sp_novedades_info_basica_edf(
    p_lote INTEGER
)
NONATOMIC
LANGUAGE plpgsql
AS $$
BEGIN

  TRUNCATE TABLE bdm_datos.mat_info_basica;

  INSERT INTO bdm_datos.mat_info_basica (
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
  FROM bdm_tempo.v_xpm_persona_basica pb
  -- Sin id no hay llave, y una fila sin llave no la puede leer nadie: el
  -- UPSERT del legado une por ID y una fila con ID nulo no casa ni con ella
  -- misma. Se descarta aqui en vez de dejarla entrar y ensuciar el conteo.
  WHERE pb.id_buro_persona IS NOT NULL;

END;
$$;
