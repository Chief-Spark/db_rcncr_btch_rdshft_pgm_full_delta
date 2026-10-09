-- R2 Motor — creacion de direcciones nuevas (Direccion_nueva)
-- Escenario: por cada PADRE que esc3 o esc5 produjo, crea UNA direccion nueva
--            con el complemento del padre mas los componentes que aportan sus
--            hijos, y su RPU sintetica.
-- Fuente: bdm_stage → bdm_tempo.v_* | Salida: bdm_datos.direccion_fisica_generada_mock + bdm_datos.rpu_generada_mock
-- Prerequisito: sp_unificacion_mock_r2_esc5_nomenclatura_menor_nivel_pierde
--               sp_unificacion_mock_r2_construir_diccionario_complementos
-- MODO MOCK — lee v_mock_*/bdm_stage; NO usa edf_views ni v_xpm_*
--
-- PARIDAD CON TERADATA (PRO_UnificacionR2.sql)
--
-- El legado crea direcciones nuevas en EXACTAMENTE DOS sitios, los unicos que
-- consultan el secuenciador REC_MTDAT.MAX_ID:
--
--   linea 1602  cadena Tmp_Unificacion_E03*   -> escenario 3
--   linea 3423  cadena Tmp_Unificacion_E051*  -> escenario 5
--
-- Las cadenas E04_*, E061_* y E062_* existen y NINGUNA contiene MAX_ID: los
-- escenarios 4 y 6 no crean direcciones. Por eso este SP se alimenta de los
-- pares que marcaron esc3 ('L3') y esc5 ('E5') en stg_mock_regla2_e2, y NO de
-- condiciones propias sobre lo que quedo sin unificar.
--
-- Los dos sitios son identicos y hacen:
--
--   SELECT COD_DW_PERSONA_UBIC_PADRE||COD_DW_PERSONA_UBIC_HIJO AS Cod_DW_Persona_Ubic
--        , COMPLEMENTO_PADRE || CAST(NUEVA_NOMENCLATURA AS VARCHAR(300)) AS Complemento1
--        , CAST(NULL AS VARCHAR(20)) Cod_Tipo_Ident_Fte          -- linea 1677
--        , CAST(NULL AS DATE) Fecha_Relacion_Persona_Ubicaci     -- linea 1680
--   FROM ( SELECT COD_DW_PERSONA_UBIC_PADRE, COMPLEMENTO_PADRE, ...
--               , XMLAGG('' ''||TRIM(NUEVA_NOMENCLATURA) ORDER BY MDIR DESC)
--               , XMLAGG('' ,''||TRIM(COD_DW_PERSONA_UBIC_HIJO) ORDER BY MDIR DESC)
--          FROM Tmp_Unificacion_E031_codigo GROUP BY 1,2,3,4,5 ) CL
--        LEFT JOIN Tmp_Unificacion_E03_B T1 ON T1.Cod_DW_Persona_Ubic = CL....PADRE
--
-- De ahi las cuatro decisiones de este SP:
--
--   1. UNA direccion por PADRE, no por par ni por grupo. El GROUP BY de CL es
--      por padre y agrega TODOS sus hijos en una sola cadena.
--   2. El complemento es el del padre LITERAL mas lo que aportan los hijos
--      (COMPLEMENTO_PADRE || NUEVA_NOMENCLATURA). El padre conserva su cadena;
--      no se re-ordena todo por nivel.
--   3. La clave del legado es padre_id || lista_de_hijos. En Redshift esa
--      concatenacion literal desborda BIGINT (dos ids de 10 digitos dan 20, y
--      el maximo son 19), asi que se usa FNV_HASH sobre la MISMA cadena. Es
--      determinista entre corridas, de modo que una segunda pasada actualiza
--      en vez de duplicar.
--   4. La RPU generada nace con cod_tipo_ident_fte y
--      fecha_relacion_persona_ubicaci en NULL, como en las lineas 1677-1680.
--
-- RECONSTRUCCION DE 'NUEVA_NOMENCLATURA'
--   El legado la construye con SQL dinamico que genera SQL dinamico (lineas
--   1140-1290: un pivote XMLAGG(CASE WHEN ORDEN=n THEN NOMENCLATURA END) sobre
--   hasta 15 posiciones, mas un cursor que lo aplica por hijo). No se porto ese
--   mecanismo: se implementa su SEMANTICA, que el propio nombre declara y que
--   el pivote sirve -- los componentes del hijo que el padre NO tiene todavia.
--   Cuando varios hijos aportan el mismo 'nomen' se conserva UNO (el del hijo
--   de menor cod_dw_persona_ubic): duplicarlo reintroduciria el defecto que
--   motivo esta correccion.
--
--   Si los hijos no aportan NINGUN componente nuevo no se crea direccion. En el
--   legado NUEVA_NOMENCLATURA queda vacia y COMPLEMENTO_PADRE || NULL da NULL
--   en Teradata; aqui el JOIN es INNER. Crear una copia del complemento del
--   padre no tendria sentido funcional.
--
-- CONSECUENCIA DELIBERADA: un par cuyos complementos no contienen ninguna
-- nomenclatura del catalogo no produce componentes y por lo tanto no genera
-- direccion. Es el comportamiento del legado: el join a
-- DICCIONARIO_COMPLEMENTOS en E03_B1 (linea 787) y en la linea 1021 es INNER.
CREATE OR REPLACE PROCEDURE bdm_datos.sp_unificacion_mock_r2_motor_nit_empates_nuevas_direcciones(
    p_modo VARCHAR,   -- FULL | DELTA (modo efectivo de la corrida)
    p_lote INTEGER    -- Lote_Corrida externo
)
NONATOMIC
LANGUAGE plpgsql
AS $$
BEGIN
  DROP TABLE IF EXISTS bdm_tempo.stg_motor_pares;
  DROP TABLE IF EXISTS bdm_tempo.stg_motor_componentes;
  DROP TABLE IF EXISTS bdm_tempo.stg_motor_nueva_nomen;
  DROP TABLE IF EXISTS bdm_tempo.stg_motor_fusion;
  DROP TABLE IF EXISTS bdm_tempo.stg_motor_insumo;

  -- (Tmp_Unificacion_E031_codigo) Pares (padre, hijo) de esc3 y esc5.
  -- n_id es el marcador que cada escenario deja al unificar:
  --   H1 esc1 | K2 esc2 | L3 esc3 | B5 esc4 | E5 esc5 | esc6 no marca.
  -- Solo L3 y E5 corresponden a los dos sitios del legado.
  CREATE TABLE bdm_tempo.stg_motor_pares
  DISTSTYLE KEY DISTKEY(id_buro_persona)
  AS
  SELECT
    h.cod_dw_persona_ubic AS ubic_hijo,
    h.id_padre            AS ubic_padre,
    h.id_buro_persona,
    h.cod_dw_ubic,
    h.n_id
  FROM bdm_tempo.stg_mock_regla2_e2 h
  WHERE h.id_padre IS NOT NULL
    AND h.n_id IN ('L3', 'E5');

  -- (Tmp_Unificacion_E03_B1) Descomposicion en componentes de las direcciones
  -- implicadas, padres e hijos.
  CREATE TABLE bdm_tempo.stg_motor_componentes
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
                   FROM bdm_tempo.stg_motor_pares p
                  WHERE p.ubic_hijo = e.cod_dw_persona_ubic
                     OR p.ubic_padre = e.cod_dw_persona_ubic );

  -- (NUEVA_NOMENCLATURA) Lo que aporta cada hijo y el padre no tiene.
  CREATE TABLE bdm_tempo.stg_motor_nueva_nomen
  DISTSTYLE KEY DISTKEY(id_buro_persona)
  AS
  SELECT
    p.ubic_padre,
    p.ubic_hijo,
    p.id_buro_persona,
    ch.nomen,
    ch.nivel_complemento,
    ch.valor
  FROM bdm_tempo.stg_motor_pares p
  JOIN bdm_tempo.stg_motor_componentes ch
    ON ch.cod_dw_persona_ubic = p.ubic_hijo
  WHERE NOT EXISTS ( SELECT 1
                       FROM bdm_tempo.stg_motor_componentes cp
                      WHERE cp.cod_dw_persona_ubic = p.ubic_padre
                        AND cp.nomen = ch.nomen );

  -- Un componente por 'nomen' y por padre: si varios hijos aportan el mismo,
  -- gana el del hijo de menor cod_dw_persona_ubic.
  CREATE TABLE bdm_tempo.stg_motor_fusion
  DISTSTYLE KEY DISTKEY(id_buro_persona)
  AS
  SELECT
    z.ubic_padre,
    z.id_buro_persona,
    z.nomen,
    z.nivel_complemento,
    z.valor
  FROM (
    SELECT
      nn.*,
      ROW_NUMBER() OVER (
        PARTITION BY nn.ubic_padre, nn.nomen
        ORDER BY nn.ubic_hijo
      ) AS pick
    FROM bdm_tempo.stg_motor_nueva_nomen nn
  ) z
  WHERE z.pick = 1;

  -- (CL + Tmp_Unificacion_E03_C) Una fila por PADRE.
  CREATE TABLE bdm_tempo.stg_motor_insumo
  DISTSTYLE KEY DISTKEY(id_buro_persona)
  AS
  SELECT
    pad.id_buro_persona,
    i.cod_pin_persona,
    pad.cod_dw_ubic,
    pad.cod_dw_tipo_ubicacion_dir,
    i.lote,
    dfp.tipo_via_principal,
    dfp.via_principal,
    dfp.via_generadora,
    dfp.numero_puerta,
    FNV_HASH(CAST(pad.cod_dw_persona_ubic AS VARCHAR) || '|MOTOR|DF|' || hij.hijos)  AS cod_dw_direccion_fisica,
    FNV_HASH(CAST(pad.cod_dw_persona_ubic AS VARCHAR) || '|MOTOR|RPU|' || hij.hijos) AS cod_dw_persona_ubic,
    -- COMPLEMENTO_PADRE || NUEVA_NOMENCLATURA
    TRIM(COALESCE(pad.complemento, '') || ' ' || nue.nueva_nomenclatura) AS complemento_motor,
    hij.hijos,
    CAST(1 AS INTEGER) AS generada_enriquecida
  FROM bdm_tempo.stg_mock_regla2_e2 pad
  JOIN (
    SELECT
      ubic_padre,
      -- (ORDEN) nivel ASC, con el valor numerico como desempate igual que el
      -- TO_NUMBER(DC.VALOR) del legado: hay niveles compartidos (BL/ED=2,
      -- MZ/LC=3, TO/CA=4, CS/LT=5) y en orden lexical '10' iria antes que '9'.
      LISTAGG(TRIM(nomen || ' ' || COALESCE(valor, '')), ' ')
        WITHIN GROUP (ORDER BY nivel_complemento,
                               CAST(NULLIF(REGEXP_REPLACE(COALESCE(valor, ''),
                                                          '[^0-9]', ''), '') AS BIGINT),
                               nomen) AS nueva_nomenclatura
    FROM bdm_tempo.stg_motor_fusion
    GROUP BY 1
  ) nue
    ON nue.ubic_padre = pad.cod_dw_persona_ubic
  JOIN (
    -- La lista de hijos sale de TODOS los pares del padre, no solo de los que
    -- aportaron componentes: es el XMLAGG(COD_DW_PERSONA_UBIC_HIJO) sobre
    -- E031_codigo, que tiene una fila por par.
    SELECT
      ubic_padre,
      LISTAGG(CAST(ubic_hijo AS VARCHAR), ',')
        WITHIN GROUP (ORDER BY ubic_hijo) AS hijos
    FROM bdm_tempo.stg_motor_pares
    GROUP BY 1
  ) hij
    ON hij.ubic_padre = pad.cod_dw_persona_ubic
  JOIN bdm_tempo.stg_mock_regla2_insumo i
    ON i.cod_dw_persona_ubic = pad.cod_dw_persona_ubic
  JOIN bdm_tempo.v_mock_direccion_fisica dfp
    ON dfp.cod_dw_direccion_fisica = pad.cod_dw_direccion_fisica;

  -- ----------------------------------------------------------------------
  -- PERSISTENCIA
  -- El legado la hace con el TPT P0020_UNIFICACION_DIRECCION_130.TPT:
  --   UPDATE ... SET Lote_Actualizacion ... INSERT FOR MISSING UPDATE ROWS
  -- y su tercer destino inserta en DIRECCION_FISICA con Generada_Enriquecida=1.
  -- El borrado del historico en FULL NO vive aqui: lo hace el orquestador
  -- (paso 6) ANTES de preparar el insumo. Si se borrara aqui, al final de
  -- la corrida, el insumo del propio FULL habria visto ya las direcciones
  -- generadas por la corrida anterior.
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
    FROM bdm_tempo.stg_motor_insumo s
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
  FROM bdm_tempo.stg_motor_insumo s
  WHERE NOT EXISTS ( SELECT 1
                       FROM bdm_datos.direccion_fisica_generada_mock d
                      WHERE d.cod_dw_direccion_fisica = s.cod_dw_direccion_fisica );

  UPDATE bdm_datos.rpu_generada_mock
     SET cod_dw_ubic               = s.cod_dw_ubic,
         cod_dw_direccion_fisica   = s.cod_dw_direccion_fisica,
         cod_dw_tipo_ubicacion_dir = s.cod_dw_tipo_ubicacion_dir,
         lote_actualizacion        = p_lote,
         usuario_bd                = CURRENT_USER,
         fecha_modificacion        = CURRENT_DATE
    FROM bdm_tempo.stg_motor_insumo s
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
    -- NULL: la direccion generada nace SIN unificar, igual que en el legado,
    -- para que pueda entrar al insumo de una corrida posterior.
    NULL,
    -- NULL como en las lineas 1677-1680 del legado.
    NULL,
    p_lote, p_lote,
    NULL,
    CURRENT_USER, NULL, CURRENT_DATE
  FROM bdm_tempo.stg_motor_insumo s
  WHERE NOT EXISTS ( SELECT 1
                       FROM bdm_datos.rpu_generada_mock r
                      WHERE r.cod_dw_persona_ubic = s.cod_dw_persona_ubic );

END;
$$;
