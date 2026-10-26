-- R1 - materializar insumo
-- MODO MOCK - lee v_mock_*/bdm_stage; NO usa edf_views ni v_xpm_*
-- Escenario: comun R1
-- Fuente: bdm_stage -> bdm_tempo.v_mock_* | Salida: bdm_datos.unificacion_direccion_mock | MODO MOCK
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
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_unif_delta_personas;
  CREATE TABLE bdm_tempo.stg_mock_unif_delta_personas
  DISTSTYLE KEY DISTKEY(id_buro_persona)
  AS
  SELECT DISTINCT rpu.id_buro_persona
  FROM   bdm_tempo.v_mock_relacion_persona_ubicacion rpu
  WHERE  p_modo = 'FULL'
     OR  rpu.fecha_relacion_persona_ubicaci >= p_watermark
     OR  rpu.fecha_relacion_persona_ubicaci IS NULL;

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
  -- SLCOPRBA-1355: LEFT JOIN, no INNER.
  --
  -- Era un INNER JOIN, de modo que una direccion SIN NINGUNA entidad que la
  -- reporte quedaba FUERA del insumo y no podia unificarse nunca -- ni en FULL
  -- ni en DELTA, ni en esta corrida ni en las siguientes. No daba error: daba
  -- cero, en silencio.
  --
  -- El propio COALESCE(COUNT(DISTINCT ...), 0) de arriba lo delataba: con un
  -- INNER JOIN el conteo nunca puede ser 0, asi que ese COALESCE era codigo
  -- muerto. La agregacion estaba escrita para un LEFT JOIN y el join no.
  --
  -- EL LEGADO TRATA EL CONTEO COMO NULLABLE, y por tanto admite la direccion
  -- sin reporte. En PRO_UnificacionR2.sql TODO uso aritmetico de
  -- Numero_entidades_que_Reportan va envuelto en COALESCE(...,0) -- lineas 531
  -- y 712, que son justo la formula del ID que ordena ORDEN y desempata al
  -- padre del motor -- y las direcciones que el propio proceso crea se
  -- insertan con CAST(NULL AS INTEGER) en esa columna (lineas 1679, 1701,
  -- 1725, 3507, 3529). Si V_Insumo_Unificacion_Regla2 hiciera INNER JOIN
  -- contra el reporte, la columna no podria ser nula y esos COALESCE no
  -- existirian.
  --
  -- COMO SE ENCONTRO: el paso de mutacion de la bateria mock agrega una
  -- direccion nueva sin sembrarle reporte -- a proposito, porque el escenario 1
  -- no mira entidades. El INNER JOIN la descartaba y el DELTA2 daba 0 filas en
  -- vez de 200 (CA-U08/U09/U10 en los jobs #302 a #307). La persona SI entraba
  -- al driver, que lee la vista sin este join: por eso personas_distintas subia
  -- 100 y relaciones_entrada 300, y total_unificaciones seguia en 0.
  --
  -- CONSECUENCIA EN DATOS REALES, que es lo que importa de verdad: toda
  -- direccion sin entidad reportante estaba excluida de las Reglas 1 y 2. Entre
  -- ellas, las que el MOTOR crea: rpu_generada nace sin fila de reporte, de modo
  -- que la direccion fusionada no volvia a entrar al insumo nunca.
  LEFT JOIN bdm_tempo.v_mock_reporte_relacion_persona_ubica rep ON rpu.cod_dw_persona_ubic = rep.cod_dw_persona_ubic
  LEFT JOIN bdm_tempo.v_mock_ciiu_persona ciiu ON rpu.id_buro_persona = ciiu.id_buro_persona
  LEFT JOIN bdm_stage.tipo_ubicacion_dir tud ON rpu.cod_dw_tipo_ubicacion_dir = tud.cod_dw_tipo_ubicacion_dir
  WHERE 1 = 1
    -- Filtro de ESTADO del legado Teradata (V_Insumo_Unificacion_Regla1):
    --     WHERE RELPU.Ind_Unificacion IS NULL AND BL.Cod_DW_Persona_Ubic IS NULL
    -- "Solo se toman para unificar direcciones hijas sin padres y sin bloqueos"
    -- (Documento Funcional Unificacion V1.0). El legado es incremental POR
    -- ESTADO, no por fecha: una relacion ya unificada se marca y no se vuelve a
    -- revisar.
    -- LOS DOS PREDICADOS ESTAN VIVOS EN LA VIA REAL, Y DECIDEN EL UNIVERSO.
    --
    -- Este comentario decia, hasta 2026-10-26, que el filtro era "INERTE EN LA
    -- VIA REAL, A PROPOSITO", porque la vista exponia ind_unificacion como
    -- CAST(NULL AS INTEGER) y bloqueado como CAST(0 AS SMALLINT). Las dos mitades
    -- son FALSAS desde que esos campos se derivaron, y la nota sobrevivio al
    -- arreglo: quien la leyera hoy daria por inerte justo la linea que se lleva
    -- tres cuartas partes del universo.
    --
    --   bloqueado (D-EDF-01): se deriva del blockreason del suscriptor y del
    --     blockSeverity de la cuenta (02_vistas_insumo_edf_views.sql:203-220).
    --     MEDIDO EN DEV: de 299.575 relaciones caen 221.383, el 73,9%. Son
    --     personas juridicas -- 106 NIT aportan 134.357 relaciones, el 44,9% de
    --     la RPU entera -- y el legado las anti-une igual.
    --
    --   ind_unificacion (SLCOPRBA-1354, M7): se deriva de
    --     bdm_datos.unificacion_direccion; una relacion esta unificada si y solo
    --     si aparece como HIJA ahi (02_vistas_insumo_edf_views.sql:286-311,
    --     :326-327). En FULL el orquestador trunca esa tabla en su paso 6, ANTES
    --     de preparar el insumo (16_sp_unificacion_ciclo.sql:204-214), de modo
    --     que un FULL arranca con cero excluidas y re-procesa todo. En DELTA el
    --     filtro si recorta.
    --
    -- CUIDADO AL MEDIR EL EMBUDO DESPUES DE UN BUILD: la consulta ve como "ya
    -- unificadas" las filas que la propia corrida acaba de producir. En el job
    -- #491 eran 19, y son la salida de esa corrida, no una herencia.
    --
    -- En la via MOCK el campo ind_unificacion es ademas un dato sembrado por la
    -- matriz (posicion YA_UNIF), por lo que la bateria ejercita el mecanismo del
    -- legado por las dos vias.
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
                        FROM bdm_tempo.stg_mock_unif_delta_personas d
                       WHERE d.id_buro_persona = rpu.id_buro_persona ) )
  GROUP BY 1,2,3,4,5,6,7,9;

END;
$$;
-- SLCOPRBA-1355: re-DPLY DEV post DROP SCHEMA strct #256
