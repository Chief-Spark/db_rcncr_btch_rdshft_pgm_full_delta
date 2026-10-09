-- R2 Motor NIT (sitio 1, etapa 3) -- creacion de direcciones nuevas
-- Escenario: por cada PADRE del grupo crea UNA direccion nueva con el
--            complemento del padre mas lo que aportan sus hijos, unifica el
--            grupo COMPLETO contra ella y lo marca 'X4'.
-- Fuente: bdm_stage → bdm_tempo.v_mock_* | Salida: bdm_datos.direccion_fisica_generada_mock + bdm_datos.rpu_generada_mock + bdm_datos.unificacion_direccion_mock
-- Prerequisito: sp_unificacion_mock_r2_esc3_sin_nit_misma_nomenclatura
--               sp_unificacion_mock_r2_construir_diccionario_complementos
-- MODO MOCK — lee v_mock_*/bdm_stage; NO usa edf_views ni v_xpm_*
--
-- PARIDAD CON TERADATA (PRO_UnificacionR2.sql)
--
-- El legado crea direcciones nuevas en EXACTAMENTE DOS sitios, los unicos que
-- consultan el secuenciador REC_MTDAT.MAX_ID:
--
--   linea 1602  cadena Tmp_Unificacion_E03*   etapa (3)    marca 'X4'
--   linea 3423  cadena Tmp_Unificacion_E051*  etapa (5.1)  marca 'A6'
--
-- Las cadenas E04_*, E061_* y E062_* no contienen MAX_ID: los escenarios 4 y 6
-- no crean direcciones. Este SP es el sitio 1.
--
-- Los dos sitios tienen la MISMA forma. Tmp_Unificacion_E03_D (linea 1666) y
-- Tmp_Unificacion_E051_F (linea 3494) son una UNION de dos ramas:
--
--   ROW_U = -99  la direccion nueva        Ind_Unificacion='N', N_ID=NULL
--   ROW_U =   0  el grupo unificado        Ind_Unificacion='S', N_ID='X4'
--                CONTRA la direccion nueva (padre = T2.ID_PADRE)
--
-- y el legado lo dice en prosa en la linea 757:
--
--   "SE DEBE CREAR UN NUEVO COMPLEMENTO EN LA TABLA DIRECCION_FISICA ...
--    creando su correspondiente relacion con la persona en
--    RELACION_PERSONA_UBICACION, este nuevo registro correspondera a la
--    direccion unificada y las dos direcciones evaluadas deben ser unidas a
--    esta ultima."
--
-- LA MITAD QUE FALTABA
--   La version anterior creaba la direccion y NO escribia nada en
--   bdm_datos.unificacion_direccion_mock: el parentesco contra la direccion generada no se
--   registraba. El efecto era que la corrida siguiente lo DESCUBRIA con un
--   retraso, por otros caminos (esc2 captura al padre porque su complemento es
--   substring del generado; esc4 captura al resto porque el generado tiene el
--   conteo maximo), y como la Clave_Unificacion es el PAR, el padre viejo y el
--   nuevo coexistian: la misma direccion acababa con DOS padres. Escribiendo
--   las filas aqui, en la misma corrida, la corrida siguiente produce el MISMO
--   par y el UPSERT actualiza en vez de insertar.
--
-- ORDEN EN LA CASCADA
--   El legado intercala las etapas y cada una marca sus filas en
--   Tmp_Unificacion_E2, de modo que las posteriores no las vuelven a ver:
--     esc1/esc2 -> esc3 ('L3') -> SITIO 1 ('X4') -> esc4 ('B5')
--               -> SITIO 2 ('A6') -> esc5 ('C7') -> esc6
--   Por eso este SP NO va al final del ciclo.
--
-- RECONSTRUCCION DE 'NUEVA_NOMENCLATURA'
--   El legado la construye con SQL dinamico que genera SQL dinamico (lineas
--   1140-1290: un pivote XMLAGG(CASE WHEN ORDEN=n THEN NOMENCLATURA END) sobre
--   hasta 15 posiciones, mas un cursor que lo aplica por hijo). No se porto ese
--   mecanismo: se implementa su SEMANTICA, que el nombre declara y el pivote
--   sirve -- los componentes del hijo que el padre NO tiene todavia. Cuando
--   varios hijos aportan el mismo 'nomen' se conserva UNO, el del hijo de menor
--   cod_dw_persona_ubic.
--
--   Si los hijos no aportan NINGUN componente nuevo no se crea direccion. En el
--   legado NUEVA_NOMENCLATURA queda vacia y COMPLEMENTO_PADRE || NULL da NULL
--   en Teradata; aqui el JOIN es INNER.
CREATE OR REPLACE PROCEDURE bdm_datos.sp_unificacion_mock_r2_motor_nit_empates_nuevas_direcciones(
    p_modo VARCHAR,   -- FULL | DELTA (modo efectivo de la corrida)
    p_lote INTEGER    -- Lote_Corrida externo
)
NONATOMIC
LANGUAGE plpgsql
AS $$
BEGIN
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_motor_nit_base;
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_motor_nit_grupo;
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_motor_nit_pares;
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_motor_nit_componentes;
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_motor_nit_nueva_nomen;
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_motor_nit_fusion;
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_motor_nit_insumo;
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_motor_nit_miembros;
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_motor_nit_persist;

  -- (1) POBLACION: Tmp_Unificacion_E031 (PRO_UnificacionR2.sql:650)
  --       Tmp_Unificacion_E2 WHERE Nombre_Tipo_Ident LIKE '%Nit%' AND Ind_Unificacion='N'
  --     mas el auto-join de Tmp_Unificacion_E03_B (linea 703):
  --       mismo (persona, texto_ubicacion, tipo, municipio), ubic distinto,
  --       COMPLEMENTO distinto y MISMA nomenclatura inicial
  --       (INNER JOIN NOMENCLATURA NMC1/NMC2 WHERE NMC1.Nomenclatura=NMC2.Nomenclatura).
  --
  --     Es el COMPLEMENTO exacto de esc3: esc3 resuelve "sin NIT, misma
  --     nomenclatura" uniendo contra un padre real; esta etapa resuelve "CON
  --     NIT, misma nomenclatura" creando una direccion nueva.
  CREATE TABLE bdm_tempo.stg_mock_motor_nit_base
  DISTSTYLE KEY DISTKEY(id_buro_persona)
  AS
  SELECT
    e.cod_dw_persona_ubic,
    e.id_buro_persona,
    e.cod_dw_ubic,
    e.texto_ubicacion,
    e.cod_dw_tipo_ubicacion_dir,
    e.cod_dw_municipio,
    e.complemento,
    nmc.nomenclatura AS nomen_pri,
    -- ID del legado (linea 712):
    --   CAST(Fecha_Relacion_Persona_Ubicaci AS INTEGER)
    --   + (COALESCE(Numero_entidades_que_Reportan,0) + 10000000)
    -- CAST(date AS INTEGER) en Teradata da (anio-1900)*10000 + mes*100 + dia.
    -- Se reproduce la formula literal para conservar la aritmetica: el termino
    -- de la fecha (~1.2e6) domina y el de entidades solo desempata fechas
    -- iguales. El +10000000 es un desplazamiento constante y no altera el orden.
    ( (DATE_PART(year,  COALESCE(e.fecha_relacion_persona_ubicaci, DATE '1900-01-01')) - 1900) * 10000
    +  DATE_PART(month, COALESCE(e.fecha_relacion_persona_ubicaci, DATE '1900-01-01')) * 100
    +  DATE_PART(day,   COALESCE(e.fecha_relacion_persona_ubicaci, DATE '1900-01-01'))
    +  COALESCE(e.numero_entidades_reportan, 0) + 10000000 ) AS id_orden
  FROM bdm_tempo.stg_mock_regla2_e2 e
  JOIN bdm_tempo.stg_mock_regla2_insumo i
    ON i.cod_dw_persona_ubic = e.cod_dw_persona_ubic
  JOIN bdm_stage.nomenclatura nmc
    ON UPPER(COALESCE(e.complemento, '')) LIKE TRIM(nmc.nomenclatura) || '%'
  WHERE e.ind_unificacion = 'N'
    AND COALESCE(i.cod_tipo_ident_fte, '') = '3';

  -- Solo los que tienen con quien emparejarse, y el orden que define al padre.
  CREATE TABLE bdm_tempo.stg_mock_motor_nit_grupo
  DISTSTYLE KEY DISTKEY(id_buro_persona)
  AS
  SELECT
    a.*,
    ROW_NUMBER() OVER (
      PARTITION BY a.id_buro_persona, a.texto_ubicacion,
                   a.cod_dw_tipo_ubicacion_dir, a.cod_dw_municipio, a.nomen_pri
      ORDER BY a.id_orden, a.cod_dw_persona_ubic
    ) AS orden
  FROM bdm_tempo.stg_mock_motor_nit_base a
  WHERE EXISTS ( SELECT 1
                   FROM bdm_tempo.stg_mock_motor_nit_base b
                  WHERE b.id_buro_persona           = a.id_buro_persona
                    AND b.texto_ubicacion           = a.texto_ubicacion
                    AND b.cod_dw_tipo_ubicacion_dir = a.cod_dw_tipo_ubicacion_dir
                    AND b.cod_dw_municipio          = a.cod_dw_municipio
                    AND b.nomen_pri                 = a.nomen_pri
                    AND b.cod_dw_persona_ubic      <> a.cod_dw_persona_ubic
                    AND b.complemento              <> a.complemento );

  CREATE TABLE bdm_tempo.stg_mock_motor_nit_pares
  DISTSTYLE KEY DISTKEY(id_buro_persona)
  AS
  SELECT
    h.cod_dw_persona_ubic AS ubic_hijo,
    p.cod_dw_persona_ubic AS ubic_padre,
    h.id_buro_persona,
    h.cod_dw_ubic
  FROM bdm_tempo.stg_mock_motor_nit_grupo h
  JOIN bdm_tempo.stg_mock_motor_nit_grupo p
    ON p.id_buro_persona           = h.id_buro_persona
   AND p.texto_ubicacion           = h.texto_ubicacion
   AND p.cod_dw_tipo_ubicacion_dir = h.cod_dw_tipo_ubicacion_dir
   AND p.cod_dw_municipio          = h.cod_dw_municipio
   AND p.nomen_pri                 = h.nomen_pri
   AND p.orden = 1
  WHERE h.orden > 1;

  -- (2) Tmp_Unificacion_E03_B1 (linea 787): descomposicion en componentes de
  --     las direcciones implicadas, padres e hijos.
  CREATE TABLE bdm_tempo.stg_mock_motor_nit_componentes
  DISTSTYLE KEY DISTKEY(id_buro_persona)
  AS
  SELECT DISTINCT
    e.cod_dw_persona_ubic,
    e.id_buro_persona,
    dc.nomen,
    -- El legado une al catalogo con LEFT JOIN: un nomen sin nivel no
    -- desaparece, se va al final del orden.
    COALESCE(cat.nivel_complemento, 99) AS nivel_complemento,
    dc.valor
  FROM bdm_tempo.stg_mock_regla2_e2 e
  JOIN bdm_stage.diccionario_complementos dc
    ON dc.id_buro_persona = e.id_buro_persona
   AND dc.cod_dw_ubic = e.cod_dw_ubic
   AND UPPER(COALESCE(e.complemento, '')) LIKE '%' || dc.nomenclatura || '%'
  LEFT JOIN bdm_stage.nomenclatura cat
    ON cat.nomenclatura = dc.nomen
  WHERE EXISTS ( SELECT 1
                   FROM bdm_tempo.stg_mock_motor_nit_pares p
                  WHERE p.ubic_hijo  = e.cod_dw_persona_ubic
                     OR p.ubic_padre = e.cod_dw_persona_ubic );

  -- (3) NUEVA_NOMENCLATURA: lo que aporta cada hijo y el padre no tiene.
  CREATE TABLE bdm_tempo.stg_mock_motor_nit_nueva_nomen
  DISTSTYLE KEY DISTKEY(id_buro_persona)
  AS
  SELECT
    p.ubic_padre,
    p.ubic_hijo,
    p.id_buro_persona,
    ch.nomen,
    ch.nivel_complemento,
    ch.valor
  FROM bdm_tempo.stg_mock_motor_nit_pares p
  JOIN bdm_tempo.stg_mock_motor_nit_componentes ch
    ON ch.cod_dw_persona_ubic = p.ubic_hijo
  WHERE NOT EXISTS ( SELECT 1
                       FROM bdm_tempo.stg_mock_motor_nit_componentes cp
                      WHERE cp.cod_dw_persona_ubic = p.ubic_padre
                        AND cp.nomen = ch.nomen );

  -- (4) Un componente por 'nomen' y por padre.
  CREATE TABLE bdm_tempo.stg_mock_motor_nit_fusion
  DISTSTYLE KEY DISTKEY(id_buro_persona)
  AS
  SELECT z.ubic_padre, z.id_buro_persona, z.nomen, z.nivel_complemento, z.valor
  FROM (
    SELECT
      nn.*,
      ROW_NUMBER() OVER (PARTITION BY nn.ubic_padre, nn.nomen
                             ORDER BY nn.ubic_hijo) AS pick
    FROM bdm_tempo.stg_mock_motor_nit_nueva_nomen nn
  ) z
  WHERE z.pick = 1;

  -- (5) CL + Tmp_Unificacion_E03_C (lineas 1602-1621): una fila por PADRE.
  CREATE TABLE bdm_tempo.stg_mock_motor_nit_insumo
  DISTSTYLE KEY DISTKEY(id_buro_persona)
  AS
  SELECT
    pad.cod_dw_persona_ubic AS ubic_padre,
    pad.id_buro_persona,
    i.cod_pin_persona,
    pad.cod_dw_ubic,
    pad.cod_dw_tipo_ubicacion_dir,
    i.lote,
    dfp.tipo_via_principal,
    dfp.via_principal,
    dfp.via_generadora,
    dfp.numero_puerta,
    -- La clave del legado es padre_id || lista_de_hijos. En Redshift esa
    -- concatenacion literal desborda BIGINT (dos ids de 10 digitos dan 20 y el
    -- maximo son 19), asi que se usa FNV_HASH sobre la MISMA cadena. Es
    -- determinista entre corridas: una segunda pasada actualiza, no duplica.
    FNV_HASH(CAST(pad.cod_dw_persona_ubic AS VARCHAR) || '|MOTOR|X4|DF|'  || hij.hijos) AS cod_dw_direccion_fisica,
    FNV_HASH(CAST(pad.cod_dw_persona_ubic AS VARCHAR) || '|MOTOR|X4|RPU|' || hij.hijos) AS cod_dw_persona_ubic,
    -- COMPLEMENTO_PADRE || NUEVA_NOMENCLATURA
    TRIM(COALESCE(pad.complemento, '') || ' ' || nue.nueva_nomenclatura) AS complemento_motor,
    hij.hijos,
    CAST(1 AS INTEGER) AS generada_enriquecida
  FROM bdm_tempo.stg_mock_regla2_e2 pad
  JOIN (
    SELECT
      ubic_padre,
      -- (ORDEN, linea 1017) nivel ASC, con el valor numerico como desempate
      -- igual que el TO_NUMBER(DC.VALOR) del legado: hay niveles compartidos
      -- (BL/ED=2, MZ/LC=3, TO/CA=4, CS/LT=5) y en orden lexical '10' iria
      -- antes que '9'. El REGEXP_REPLACE evita fallar con un valor no numerico.
      LISTAGG(TRIM(nomen || ' ' || COALESCE(valor, '')), ' ')
        WITHIN GROUP (ORDER BY nivel_complemento,
                               CAST(NULLIF(REGEXP_REPLACE(COALESCE(valor, ''),
                                                          '[^0-9]', ''), '') AS BIGINT),
                               nomen) AS nueva_nomenclatura
    FROM bdm_tempo.stg_mock_motor_nit_fusion
    GROUP BY 1
  ) nue
    ON nue.ubic_padre = pad.cod_dw_persona_ubic
  JOIN (
    -- XMLAGG(COD_DW_PERSONA_UBIC_HIJO) sobre E031_codigo, que tiene una fila
    -- por par: la lista sale de TODOS los hijos del padre, no solo de los que
    -- aportaron componentes.
    SELECT ubic_padre,
           LISTAGG(CAST(ubic_hijo AS VARCHAR), ',')
             WITHIN GROUP (ORDER BY ubic_hijo) AS hijos
    FROM bdm_tempo.stg_mock_motor_nit_pares
    GROUP BY 1
  ) hij
    ON hij.ubic_padre = pad.cod_dw_persona_ubic
  JOIN bdm_tempo.stg_mock_regla2_insumo i
    ON i.cod_dw_persona_ubic = pad.cod_dw_persona_ubic
  JOIN bdm_tempo.v_mock_direccion_fisica dfp
    ON dfp.cod_dw_direccion_fisica = pad.cod_dw_direccion_fisica;

  -- ----------------------------------------------------------------------
  -- (6) PERSISTENCIA DE LA DIRECCION GENERADA
  -- UPDATE + INSERT WHERE NOT EXISTS, el 'INSERT FOR MISSING UPDATE ROWS' de
  -- P0020_UNIFICACION_DIRECCION_130.TPT. El borrado del historico en FULL lo
  -- hace el orquestador (paso 6) ANTES de preparar el insumo.
  -- ----------------------------------------------------------------------
  UPDATE bdm_datos.direccion_fisica_generada_mock
     SET complemento        = s.complemento_motor,
         tipo_via_principal = s.tipo_via_principal,
         via_principal      = s.via_principal,
         via_generadora     = s.via_generadora,
         numero_puerta      = s.numero_puerta,
         cod_dw_ubic        = s.cod_dw_ubic,
         lote_actualizacion = p_lote,
         usuario_bd         = CURRENT_USER,
         fecha_modificacion = CURRENT_DATE
    FROM bdm_tempo.stg_mock_motor_nit_insumo s
   WHERE bdm_datos.direccion_fisica_generada_mock.cod_dw_direccion_fisica = s.cod_dw_direccion_fisica;

  INSERT INTO bdm_datos.direccion_fisica_generada_mock (
    cod_dw_direccion_fisica, complemento, tipo_via_principal, via_principal,
    via_generadora, numero_puerta, cod_dw_ubic, lote, lote_actualizacion,
    severidad, usuario_bd, generada_enriquecida, fecha_inactivacion,
    fecha_modificacion
  )
  SELECT
    s.cod_dw_direccion_fisica, s.complemento_motor, s.tipo_via_principal,
    s.via_principal, s.via_generadora, s.numero_puerta, s.cod_dw_ubic,
    p_lote, p_lote, 1, CURRENT_USER, 1, NULL, CURRENT_DATE
  FROM bdm_tempo.stg_mock_motor_nit_insumo s
  WHERE NOT EXISTS ( SELECT 1 FROM bdm_datos.direccion_fisica_generada_mock d
                      WHERE d.cod_dw_direccion_fisica = s.cod_dw_direccion_fisica );

  UPDATE bdm_datos.rpu_generada_mock
     SET cod_dw_ubic               = s.cod_dw_ubic,
         cod_dw_direccion_fisica   = s.cod_dw_direccion_fisica,
         cod_dw_tipo_ubicacion_dir = s.cod_dw_tipo_ubicacion_dir,
         lote_actualizacion        = p_lote,
         usuario_bd                = CURRENT_USER,
         fecha_modificacion        = CURRENT_DATE
    FROM bdm_tempo.stg_mock_motor_nit_insumo s
   WHERE bdm_datos.rpu_generada_mock.cod_dw_persona_ubic = s.cod_dw_persona_ubic;

  INSERT INTO bdm_datos.rpu_generada_mock (
    cod_dw_persona_ubic, id_buro_persona, cod_pin_persona, cod_dw_ubic,
    cod_dw_direccion_fisica, cod_dw_tipo_ubicacion_dir, ind_unificacion,
    fecha_relacion_persona_ubicaci, lote, lote_actualizacion,
    cod_tipo_ident_fte, usuario_bd, fecha_inactivacion, fecha_modificacion
  )
  SELECT
    s.cod_dw_persona_ubic, s.id_buro_persona, s.cod_pin_persona, s.cod_dw_ubic,
    s.cod_dw_direccion_fisica, s.cod_dw_tipo_ubicacion_dir,
    -- 'N' en el staging del legado: la direccion generada nace SIN unificar.
    NULL,
    -- NULL como en las lineas 1677-1680 del legado.
    NULL,
    p_lote, p_lote,
    NULL,
    CURRENT_USER, NULL, CURRENT_DATE
  FROM bdm_tempo.stg_mock_motor_nit_insumo s
  WHERE NOT EXISTS ( SELECT 1 FROM bdm_datos.rpu_generada_mock r
                      WHERE r.cod_dw_persona_ubic = s.cod_dw_persona_ubic );

  -- ----------------------------------------------------------------------
  -- (7) EL GRUPO COMPLETO SE UNIFICA CONTRA LA DIRECCION GENERADA
  -- Rama ROW_U = 0 / N_ID = 'X4'. Incluye al PADRE: "las dos direcciones
  -- evaluadas deben ser unidas a esta ultima" (linea 757).
  -- ----------------------------------------------------------------------
  CREATE TABLE bdm_tempo.stg_mock_motor_nit_miembros
  DISTSTYLE KEY DISTKEY(ubic_padre)
  AS
  SELECT ubic_padre, ubic_padre AS miembro FROM bdm_tempo.stg_mock_motor_nit_pares
  UNION
  SELECT ubic_padre, ubic_hijo  AS miembro FROM bdm_tempo.stg_mock_motor_nit_pares;

  CREATE TABLE bdm_tempo.stg_mock_motor_nit_persist
  DISTSTYLE KEY DISTKEY(cod_dw_persona_ubic)
  AS
  SELECT DISTINCT
    m.miembro                  AS cod_dw_persona_ubic,
    s.cod_dw_persona_ubic      AS cod_dw_direccion_unificada,
    2                          AS unifica_atributos,
    CURRENT_DATE               AS fecha_unificacion,
    p_lote /* Lote_Corrida externo */ AS lote,
    1                          AS severidad,
    LEFT(CURRENT_USER, 30)     AS usuario_bd
  FROM bdm_tempo.stg_mock_motor_nit_miembros m
  JOIN bdm_tempo.stg_mock_motor_nit_insumo s
    ON s.ubic_padre = m.ubic_padre;

  IF p_modo = 'FULL' THEN
    -- El TRUNCATE lo hizo el orquestador al inicio de la corrida. Se usa
    -- INSERT FOR MISSING y no un INSERT plano porque dentro de una misma
    -- corrida FULL dos etapas distintas pueden producir la MISMA
    -- Clave_Unificacion, y el INSERT plano dejaria la pareja duplicada.
    INSERT INTO bdm_datos.unificacion_direccion_mock
      (cod_dw_persona_ubic, cod_dw_direccion_unificada, unifica_atributos, fecha_unificacion, lote, severidad, usuario_bd)
    SELECT DISTINCT s.cod_dw_persona_ubic, s.cod_dw_direccion_unificada, s.unifica_atributos,
           s.fecha_unificacion, s.lote, s.severidad, s.usuario_bd
    FROM bdm_tempo.stg_mock_motor_nit_persist s
    WHERE NOT EXISTS (
      SELECT 1 FROM bdm_datos.unificacion_direccion_mock u
       WHERE u.cod_dw_persona_ubic = s.cod_dw_persona_ubic
         AND u.cod_dw_direccion_unificada = s.cod_dw_direccion_unificada);
  ELSE
    -- DELTA UPSERT. El UPDATE no reescribe 'lote' ni 'unifica_atributos': el
    -- Lote identifica la corrida que CREO la unificacion y es inmutable.
    -- En UPDATE ... FROM la tabla destino no admite alias en Redshift.
    UPDATE bdm_datos.unificacion_direccion_mock
       SET lote_actualizacion = p_lote,
           fecha_modificacion = CURRENT_DATE,
           usuario_bd         = CURRENT_USER
      FROM bdm_tempo.stg_mock_motor_nit_persist s
     WHERE bdm_datos.unificacion_direccion_mock.cod_dw_persona_ubic = s.cod_dw_persona_ubic
       AND bdm_datos.unificacion_direccion_mock.cod_dw_direccion_unificada = s.cod_dw_direccion_unificada;

    INSERT INTO bdm_datos.unificacion_direccion_mock
      (cod_dw_persona_ubic, cod_dw_direccion_unificada, unifica_atributos, fecha_unificacion, lote, severidad, usuario_bd)
    SELECT DISTINCT s.cod_dw_persona_ubic, s.cod_dw_direccion_unificada, s.unifica_atributos,
           s.fecha_unificacion, s.lote, s.severidad, s.usuario_bd
    FROM bdm_tempo.stg_mock_motor_nit_persist s
    WHERE NOT EXISTS (
      SELECT 1 FROM bdm_datos.unificacion_direccion_mock u
       WHERE u.cod_dw_persona_ubic = s.cod_dw_persona_ubic
         AND u.cod_dw_direccion_unificada = s.cod_dw_direccion_unificada);
  END IF;

  -- ----------------------------------------------------------------------
  -- (8) MARCADO. Igual que cada escenario, para que las etapas POSTERIORES no
  -- vuelvan a procesar este grupo. Es lo que en el legado hace el merge de
  -- vuelta a Tmp_Unificacion_E2 tras cada etapa.
  -- ----------------------------------------------------------------------
  UPDATE bdm_tempo.stg_mock_regla2_e2
  SET id_padre        = stg.cod_dw_direccion_unificada,
      ind_unificacion = 'S',
      n_id            = 'X4'
  FROM bdm_tempo.stg_mock_motor_nit_persist stg
  WHERE bdm_tempo.stg_mock_regla2_e2.cod_dw_persona_ubic = stg.cod_dw_persona_ubic
    AND bdm_tempo.stg_mock_regla2_e2.id_padre IS NULL;

END;
$$;
