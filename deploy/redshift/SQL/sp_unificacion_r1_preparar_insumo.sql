-- R1 — materializar insumo
-- Escenario: común R1
-- Fuente: edf_views → bdm_tempo.v_xpm_* | Salida: bdm_datos.unificacion_direccion
-- Prerequisito: vistas v_xpm_* desplegadas
-- Generado: tools/gen_unificacion_sps_por_escenario.py

CREATE OR REPLACE PROCEDURE bdm_datos.sp_unificacion_r1_preparar_insumo(
    p_modo      VARCHAR,   -- FULL | DELTA (modo efectivo de la corrida)
    p_watermark DATE       -- frontera inferior inclusiva (solo aplica en DELTA)
)
NONATOMIC
LANGUAGE plpgsql
AS $$
BEGIN

  -- ------------------------------------------------------------
  -- Driver del universo DELTA: personas tocadas en la ventana -- SLCOPRBA-1355.
  -- Patron DROP-CREATE (igual que el resto del staging). Se materializa dentro
  -- de este SP, y no en el orquestador, para que siga siendo invocable de forma
  -- autonoma. En FULL el predicado colapsa a TRUE y la tabla contiene el
  -- universo completo (mismo idioma que stg_unif_delta_ubic en el orquestador),
  -- por lo que el EXISTS del insumo es correcto en ambos modos.
  -- Nota: el driver NO filtra por ind_unificacion. Ese filtro decide que FILAS
  -- entran al insumo; aqui se decide que PERSONAS fueron tocadas.
  -- ------------------------------------------------------------
  DROP TABLE IF EXISTS bdm_tempo.stg_unif_delta_personas;
  CREATE TABLE bdm_tempo.stg_unif_delta_personas
  DISTSTYLE KEY DISTKEY(id_buro_persona)
  AS
  SELECT DISTINCT rpu.id_buro_persona
  FROM   bdm_tempo.v_xpm_relacion_persona_ubicacion rpu
  WHERE  p_modo = 'FULL'
     OR  rpu.fecha_relacion_persona_ubicaci >= p_watermark
     OR  rpu.fecha_relacion_persona_ubicaci IS NULL;

  DROP TABLE IF EXISTS bdm_tempo.stg_regla1_insumo;
  CREATE TABLE bdm_tempo.stg_regla1_insumo
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
  FROM bdm_tempo.v_xpm_relacion_persona_ubicacion rpu
  JOIN bdm_tempo.v_xpm_ubicacion_estandarizada ubi ON rpu.cod_dw_ubic = ubi.cod_dw_ubic
  LEFT JOIN bdm_tempo.v_xpm_direccion_fisica df ON rpu.cod_dw_direccion_fisica = df.cod_dw_direccion_fisica
  JOIN bdm_tempo.v_xpm_reporte_relacion_persona_ubica rep ON rpu.cod_dw_persona_ubic = rep.cod_dw_persona_ubic
  LEFT JOIN bdm_tempo.v_xpm_ciiu_persona ciiu ON rpu.id_buro_persona = ciiu.id_buro_persona
  LEFT JOIN bdm_datos.tipo_ubicacion_dir tud ON rpu.cod_dw_tipo_ubicacion_dir = tud.cod_dw_tipo_ubicacion_dir
  WHERE 1 = 1
    -- Filtro de ESTADO del legado Teradata (V_Insumo_Unificacion_Regla1):
    --     WHERE RELPU.Ind_Unificacion IS NULL AND BL.Cod_DW_Persona_Ubic IS NULL
    -- "Solo se toman para unificar direcciones hijas sin padres y sin bloqueos"
    -- (Documento Funcional Unificacion V1.0). El legado es incremental POR
    -- ESTADO, no por fecha: una relacion ya unificada se marca y no se vuelve a
    -- revisar.
    -- HOY ESTE FILTRO ES INERTE EN LA VIA REAL, A PROPOSITO: la vista EDF
    -- bdm_tempo.v_xpm_relacion_persona_ubicacion expone ind_unificacion como
    -- CAST(NULL AS INTEGER) y bloqueado como CAST(0 AS SMALLINT) porque el
    -- datashare no publica esos campos. Ambos predicados son siempre TRUE y los
    -- volumenes no cambian. Se deja puesto para que se active solo el dia que
    -- el datashare los publique, sin volver a tocar estos SP ni repetir la
    -- certificacion. En la via MOCK el campo ind_unificacion SI es real, por lo
    -- que la bateria de pruebas si ejercita el mecanismo del legado.
    AND rpu.ind_unificacion IS NULL
    AND COALESCE(rpu.bloqueado, 0) = 0
    -- Ventana del Modo_Delta POR PERSONA (no por fila) -- SLCOPRBA-1355.
    -- FULL: sin frontera de fecha (Req 3.3).
    -- DELTA: entran TODAS las relaciones de las personas tocadas en la ventana,
    --   no solo las filas cuya fecha cae dentro de ella.
    -- POR QUE: en el legado el insumo NUNCA se acota por fecha, de modo que el
    --   self-join por Id_Buro_Persona siempre ve todas las direcciones de la
    --   persona. Con un filtro por FILA, una persona cuya direccion nueva entra
    --   en la ventana pero cuyo historico queda fuera llega al insumo con una
    --   sola fila: no hay padre + hija, y esa unificacion no ocurre nunca (ni en
    --   el DELTA, que solo ve una fila, ni despues, porque el DELTA no trunca).
    --   En el dataset real de DEV ese caso es el 99,99% de las personas de la
    --   ventana, lo que explica que el DELTA produjera 0 unificaciones.
    AND ( p_modo = 'FULL'
          OR EXISTS ( SELECT 1
                        FROM bdm_tempo.stg_unif_delta_personas d
                       WHERE d.id_buro_persona = rpu.id_buro_persona ) )
  GROUP BY 1,2,3,4,5,6,7,9;

END;
$$;
-- SLCOPRBA-1355: re-DPLY DEV post DROP SCHEMA strct #256
