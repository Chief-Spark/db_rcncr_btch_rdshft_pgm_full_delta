-- R2 Esc6 — frecuencia de complemento
-- MODO MOCK — lee v_mock_*/bdm_stage; NO usa edf_views ni v_xpm_*
-- Escenario: Mayor frecuencia en diccionario gana
-- Fuente: bdm_stage → bdm_tempo.v_mock_* | Salida: bdm_datos.unificacion_direccion_mock | MODO MOCK
-- Prerequisito: sp_unificacion_mock_r2_esc5_nomenclatura_menor_nivel_pierde
-- Generado: tools/gen_unificacion_mock_sps.py (espejo mock)

CREATE OR REPLACE PROCEDURE bdm_datos.sp_unificacion_mock_r2_esc6_frecuencia_complemento_gana(
    p_modo VARCHAR,   -- FULL | DELTA (modo efectivo de la corrida)
    p_lote INTEGER    -- Lote_Corrida externo (reemplaza el 1 hardcodeado)
)
NONATOMIC
LANGUAGE plpgsql
AS $$
BEGIN
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_regla2_e06_freq;
  DROP TABLE IF EXISTS bdm_tempo.stg_mock_regla2_e06_pares;

  CREATE TABLE bdm_tempo.stg_mock_regla2_e06_freq
  DISTSTYLE KEY DISTKEY(cod_dw_persona_ubic)
  AS
  SELECT
    a.cod_dw_persona_ubic,
    COALESCE(SUM(dc.frecuencia), 0) AS freq
  FROM (SELECT * FROM bdm_tempo.stg_mock_regla2_e2 WHERE ind_unificacion = 'N') a
  LEFT JOIN bdm_stage.diccionario_complementos dc
    ON a.cod_dw_ubic = dc.cod_dw_ubic
   AND a.complemento LIKE '%' || dc.nomenclatura || '%'
   AND a.id_buro_persona = dc.id_buro_persona
  GROUP BY 1;

  -- SLCOPRBA-1355 (C): UN SOLO PADRE POR HIJA.
  -- Antes este CREATE terminaba en 'WHERE fa.freq > fb.freq' y nada mas, de
  -- modo que una direccion recibia un par por CADA candidato de frecuencia
  -- mayor. Con el arquetipo E6 -- 'CA 1 LT 2' (frecuencia 5), 'CA 3 LT 4' (5),
  -- 'CA 9' (3) -- las dos primeras EMPATAN en el maximo, ninguna puede ser hija
  -- de la otra, y 'CA 9' acababa con DOS padres. Es lo que el job #303 reporto
  -- como "direcciones con mas de un padre=4000" en CA-U05 y CA-C06, y lo
  -- confirmo la consulta sobre la persona 9460000:
  --     94600003 -> 94600001   (CA 9 -> CA 1 LT 2)
  --     94600003 -> 94600002   (CA 9 -> CA 3 LT 4)
  -- El conteo salia bien (2 filas por persona) pero la FORMA estaba mal: una
  -- hija con dos padres en vez de dos hijas con un padre. Por eso CA-U01 no lo
  -- veia y CA-U05 si.
  --
  -- Todos los demas escenarios ya reducen a un padre: esc1 y esc2 con
  -- ROW_NUMBER ... rn = 1, esc3 con el MAX(ORDEN) del legado. esc6 era el unico
  -- sin reduccion. El desempate secundario por cod_dw_persona_ubic es
  -- DETERMINISTA a proposito: sin el, el padre elegido entre dos frecuencias
  -- iguales podria variar entre corridas y romperia CA-C02..C04, que comparan
  -- por checksum.
  --
  -- PENDIENTE, y NO se toca aqui: el CRITERIO de esc6. La frecuencia no rompe
  -- el empate 5/5, asi que tras este cambio E6 produce 1 fila por persona en
  -- vez de 2 y CA-U01 lo reportara. El 'esc6' del legado no es un escenario de
  -- emparejamiento sino un SITIO DE CREACION de direcciones: Tmp_Unificacion_
  -- E061_D empareja con T1.ID > T2.ID y su ID_PADRE lleva el marcador /*#6*/
  -- del secuenciador MAX_ID, es decir el sitio 2 que sigue sin implementar.
  -- Hasta decodificarlo no hay con que fijar el criterio correcto, y es
  -- preferible un dato consistente e incompleto a un dato corrupto.
  CREATE TABLE bdm_tempo.stg_mock_regla2_e06_pares
  DISTSTYLE KEY DISTKEY(cod_dw_persona_ubic)
  AS
  SELECT cod_dw_persona_ubic, id_padre
  FROM (
    SELECT
      b.cod_dw_persona_ubic,
      a.cod_dw_persona_ubic AS id_padre,
      ROW_NUMBER() OVER (
        PARTITION BY b.cod_dw_persona_ubic
        ORDER BY fa.freq DESC, a.cod_dw_persona_ubic
      ) AS rn
    FROM (SELECT * FROM bdm_tempo.stg_mock_regla2_e2 WHERE ind_unificacion = 'N') a
    JOIN (SELECT * FROM bdm_tempo.stg_mock_regla2_e2 WHERE ind_unificacion = 'N') b
      ON a.id_buro_persona = b.id_buro_persona
     AND a.texto_ubicacion = b.texto_ubicacion
     AND a.cod_dw_tipo_ubicacion_dir = b.cod_dw_tipo_ubicacion_dir
     AND a.cod_dw_municipio = b.cod_dw_municipio
     AND a.cod_dw_persona_ubic <> b.cod_dw_persona_ubic
     AND a.complemento <> b.complemento
    JOIN bdm_tempo.stg_mock_regla2_e06_freq fa
      ON a.cod_dw_persona_ubic = fa.cod_dw_persona_ubic
    JOIN bdm_tempo.stg_mock_regla2_e06_freq fb
      ON b.cod_dw_persona_ubic = fb.cod_dw_persona_ubic
    WHERE fa.freq > fb.freq
  )
  WHERE rn = 1;

  -- Persistencia condicional al modo (Tarea 6.1, Req 5.1..5.6).
  -- 1) Materializar el resultado de la regla (SELECT DISTINCT, Req 5.5).
  DROP TABLE IF EXISTS bdm_tempo.sp_unificacion_mock_r2_esc6_frecuencia_complemento_gana_persist;
  CREATE TABLE bdm_tempo.sp_unificacion_mock_r2_esc6_frecuencia_complemento_gana_persist
  DISTSTYLE KEY DISTKEY(cod_dw_persona_ubic)
  AS
  SELECT DISTINCT
    cod_dw_persona_ubic AS cod_dw_persona_ubic,
    id_padre AS cod_dw_direccion_unificada,
    2 AS unifica_atributos,
    CURRENT_DATE AS fecha_unificacion,
    p_lote /* Lote_Corrida externo */ AS lote,
    1 AS severidad,
    LEFT(CURRENT_USER,30) AS usuario_bd
  FROM bdm_tempo.stg_mock_regla2_e06_pares;

  IF p_modo = 'FULL' THEN
    -- FULL: el TRUNCATE lo hizo el orquestador una vez al inicio de la corrida.
    -- Se usa INSERT FOR MISSING (el mismo NOT EXISTS del Modo_Delta) y NO un
    -- INSERT plano: dentro de una misma corrida FULL dos escenarios distintos
    -- pueden producir la MISMA Clave_Unificacion, y el INSERT plano dejaba la
    -- pareja DUPLICADA -- justo lo que vigila el gate unicidad_clave_unificacion.
    -- El legado Teradata aplica el upsert de forma uniforme, sin distinguir
    -- carga inicial: gana el primer escenario que produce la pareja.
    -- No se hace el UPDATE previo que si lleva el Modo_Delta: tras el TRUNCATE
    -- la unica fila preexistente posible proviene de un escenario anterior de
    -- ESTA misma corrida, por lo que sellar lote_actualizacion con el mismo
    -- lote no aportaria informacion.
    INSERT INTO bdm_datos.unificacion_direccion_mock
      (cod_dw_persona_ubic, cod_dw_direccion_unificada, unifica_atributos, fecha_unificacion, lote, severidad, usuario_bd)
    SELECT DISTINCT s.cod_dw_persona_ubic, s.cod_dw_direccion_unificada, s.unifica_atributos,
           s.fecha_unificacion, s.lote, s.severidad, s.usuario_bd
    FROM bdm_tempo.sp_unificacion_mock_r2_esc6_frecuencia_complemento_gana_persist s
    WHERE NOT EXISTS (
      SELECT 1
      FROM bdm_datos.unificacion_direccion_mock u
      WHERE u.cod_dw_persona_ubic = s.cod_dw_persona_ubic
        AND u.cod_dw_direccion_unificada = s.cod_dw_direccion_unificada);
  ELSE
    -- DELTA UPSERT fiel al legado Teradata (SLCOPRBA-1355).
    -- Patron 'INSERT FOR MISSING UPDATE ROWS' de
    -- P0020_UNIFICACION_DIRECCION_130.TPT (STEP Load_UNIFICACION_DIRECCION):
    --   1) UPDATE de las filas que YA existen con la misma Clave_Unificacion
    --      (cod_dw_persona_ubic, cod_dw_direccion_unificada).
    --   2) INSERT de las que faltan.
    -- El UPDATE NO reescribe 'lote' ni 'unifica_atributos': en el legado el
    -- Lote identifica la corrida que CREO la unificacion y es inmutable; solo
    -- se sellan Lote_Actualizacion / Fecha_Modificacion / Usuario_BD.
    -- NO se usa MERGE: el cluster Redshift no acepta alias en MERGE.
    -- NO se usa DELETE+INSERT (version anterior): reescribia 'lote' con el de
    -- la corrida en curso, perdiendo la trazabilidad de que corrida origino
    -- cada unificacion y haciendo ininterpretable total_unificaciones.
    -- NOTA Redshift: en UPDATE ... FROM la tabla destino NO admite alias; se
    -- referencia con su nombre calificado completo (igual que el DELETE USING).
    UPDATE bdm_datos.unificacion_direccion_mock
       SET lote_actualizacion = p_lote,
           fecha_modificacion = CURRENT_DATE,
           usuario_bd         = CURRENT_USER
      FROM bdm_tempo.sp_unificacion_mock_r2_esc6_frecuencia_complemento_gana_persist s
     WHERE bdm_datos.unificacion_direccion_mock.cod_dw_persona_ubic = s.cod_dw_persona_ubic
       AND bdm_datos.unificacion_direccion_mock.cod_dw_direccion_unificada = s.cod_dw_direccion_unificada;

    INSERT INTO bdm_datos.unificacion_direccion_mock
      (cod_dw_persona_ubic, cod_dw_direccion_unificada, unifica_atributos, fecha_unificacion, lote, severidad, usuario_bd)
    SELECT DISTINCT s.cod_dw_persona_ubic, s.cod_dw_direccion_unificada, s.unifica_atributos,
           s.fecha_unificacion, s.lote, s.severidad, s.usuario_bd
    FROM bdm_tempo.sp_unificacion_mock_r2_esc6_frecuencia_complemento_gana_persist s
    WHERE NOT EXISTS (
      SELECT 1
      FROM bdm_datos.unificacion_direccion_mock u
      WHERE u.cod_dw_persona_ubic = s.cod_dw_persona_ubic
        AND u.cod_dw_direccion_unificada = s.cod_dw_direccion_unificada);
  END IF;

  -- SLCOPRBA-1355: SELLO DE esc6, para que el censo lo pueda contar.
  --
  -- El legado NO marca esc6, y con razon: es el ULTIMO escenario y nadie lee
  -- la marca despues. Pero sin marca una direccion resuelta por esc6 queda en
  -- el staging con n_id NULL, exactamente igual que una que NO resolvio nadie
  -- -- y esa es justo la distincion que bdm_datos.unif_escenario_censo tiene
  -- que medir. Sin este sello el censo no puede separar "lo hizo esc6" de
  -- "falta implementar".
  --
  -- 'E6' NO ES UN SELLO DEL LEGADO. PRO_UnificacionR2.sql usa H1, K2, L3, X4,
  -- B5, A6 y C7, y ninguno para esc6. El censo lo declara como tal en su
  -- columna ref_legado, para que nadie lo confunda con uno portado.
  --
  -- No cambia ningun resultado: nada lee el VALOR de n_id (solo si es nulo, y
  -- aqui se marca despues del ultimo escenario), y stg_regla2_e2 se dropea al
  -- cerrar la Regla 2.
  UPDATE bdm_tempo.stg_mock_regla2_e2
  SET id_padre        = stg.cod_dw_direccion_unificada,
      ind_unificacion = 'S',
      n_id            = 'E6'
  FROM bdm_tempo.sp_unificacion_mock_r2_esc6_frecuencia_complemento_gana_persist stg
  WHERE bdm_tempo.stg_mock_regla2_e2.cod_dw_persona_ubic = stg.cod_dw_persona_ubic
    AND bdm_tempo.stg_mock_regla2_e2.id_padre IS NULL;

  DROP TABLE IF EXISTS bdm_tempo.sp_unificacion_mock_r2_esc6_frecuencia_complemento_gana_persist;


END;
$$;
-- SLCOPRBA-1355: re-DPLY DEV post DROP SCHEMA strct #256
