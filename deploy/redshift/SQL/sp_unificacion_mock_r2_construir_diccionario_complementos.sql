-- R2 Constructor del Diccionario de Complementos (mock)
-- Escenario: tokeniza el complemento contra el catalogo de nomenclaturas y
--            deja la tabla de frecuencias que consumen esc4, esc6 y el motor.
-- Fuente: bdm_tempo.stg_mock_regla2_insumo | Salida: bdm_stage.diccionario_complementos
-- Prerequisito: sp_unificacion_mock_r2_preparar_insumo
--
-- EQUIVALENTE LEGADO: PRO_CreaDicNomenclaturaReg2 (Teradata, P0020,
-- invocado por P0020_CreaDicNomenclaturaReg2_131.BTQ con la firma
-- (lote, fecha_inicio, proceso, BDDATOS, BDVISTA, BDSTAGE, P_ERROR)).
-- El cliente NO entrego el fuente de ese SP: los dos zips de Teradata traen
-- unicamente el .BTQ que lo invoca, y nadie escribe DICCIONARIO_COMPLEMENTOS
-- en el codigo disponible. Esta implementacion se reconstruye a partir del
-- CONTRATO DE CONSUMO, que si esta completo en PRO_UnificacionR2.sql:
--
--   1) Descomposicion por componentes (PRO_UnificacionR2.sql:787, E03_B1)
--        INNER JOIN DICCIONARIO_COMPLEMENTOS DC
--          ON TU.complemento LIKE '%'||DC.nomenclatura||'%'
--         AND TU.cod_dw_ubic = DC.cod_dw_ubic
--         AND TU.ID_BURO_PERSONA = DC.ID_BURO_PERSONA
--        LEFT JOIN NOMENCLATURA NOM ON NOM.NOMENCLATURA = DC.Nomen
--        ... SUM(TO_NUMBER(VALOR)) AS valor
--      => el diccionario aporta: nomenclatura (texto a buscar dentro del
--         complemento), nomen (clave del catalogo de niveles) y valor (numerico).
--
--   2) Frecuencia de esc4 / esc6 (PRO_UnificacionR2.sql:2053, E04_C1)
--        SUM(CONTEO) ... ON T1.COD_DW_UBIC = T2.COD_DW_UBIC
--                     AND T1.COMPLEMENTO LIKE '%'||T2.Nomenclatura||'%'
--                     AND T1.ID_BURO_PERSONA = T2.ID_BURO_PERSONA
--      => el diccionario aporta: conteo (aqui 'frecuencia').
--
-- La granularidad que se deduce de los dos joins es
-- (id_buro_persona, cod_dw_ubic, nomenclatura), y es la que se implementa.
-- Nota: el legado marca la condicion por persona con /*#4*/ (una enmienda
-- posterior); se respeta el codigo TAL COMO ESTA ESCRITO, es decir por persona.
--
-- FIDELIDAD DELIBERADA: el join del legado es LIKE '%token%' SIN frontera de
-- palabra, de modo que un complemento 'EDIFICIO 2' casa con el token 'ED'.
-- Se reproduce esa laxitud en vez de "corregirla": el objetivo es paridad con
-- Teradata, y endurecer el match cambiaria los conteos de esc4 / esc6.
CREATE OR REPLACE PROCEDURE bdm_datos.sp_unificacion_mock_r2_construir_diccionario_complementos(
    p_modo VARCHAR,   -- FULL | DELTA (modo efectivo de la corrida)
    p_lote INTEGER    -- Lote_Corrida externo
)
NONATOMIC
LANGUAGE plpgsql
AS $$
BEGIN

  -- FULL borra el historico completo del diccionario; DELTA reconstruye solo
  -- las personas de la ventana y deja intactas las demas. En ambos casos el
  -- insumo ya viene recortado por sp_unificacion_mock_r2_preparar_insumo,
  -- asi que los consumidores (esc4, esc6, motor) ven exactamente su universo.
  IF p_modo = 'FULL' THEN
    DELETE FROM bdm_stage.diccionario_complementos;
  ELSE
    DELETE FROM bdm_stage.diccionario_complementos
     WHERE id_buro_persona IN ( SELECT DISTINCT i.id_buro_persona
                                  FROM bdm_tempo.stg_mock_regla2_insumo i );
  END IF;

  INSERT INTO bdm_stage.diccionario_complementos
    (id_buro_persona, cod_dw_ubic, nomenclatura, nomen, valor, frecuencia)
  SELECT
    t.id_buro_persona,
    t.cod_dw_ubic,
    t.token                              AS nomenclatura,
    t.token                              AS nomen,
    CAST(MIN(t.valor_num) AS VARCHAR(50)) AS valor,
    CAST(COUNT(*) AS INTEGER)            AS frecuencia
  FROM (
    SELECT
      i.id_buro_persona,
      i.cod_dw_ubic,
      n.nomenclatura AS token,
      -- El valor numerico que sigue al token dentro del complemento. Se extrae
      -- con REGEXP_SUBSTR + REGEXP_REPLACE (y no con el parametro 'e' de
      -- subexpresion) para no depender de variantes del motor de regex.
      -- El guardia de longitud evita desbordar BIGINT con cadenas largas.
      CASE
        WHEN LEN(REGEXP_REPLACE(
                   REGEXP_SUBSTR(UPPER(i.complemento), n.nomenclatura || ' *[0-9]+'),
                   '[^0-9]', '')) BETWEEN 1 AND 18
        THEN CAST(REGEXP_REPLACE(
                    REGEXP_SUBSTR(UPPER(i.complemento), n.nomenclatura || ' *[0-9]+'),
                    '[^0-9]', '') AS BIGINT)
      END AS valor_num
    FROM bdm_tempo.stg_mock_regla2_insumo i
    JOIN bdm_stage.nomenclatura n
      ON UPPER(COALESCE(i.complemento, '')) LIKE '%' || n.nomenclatura || '%'
  ) t
  GROUP BY 1, 2, 3, 4;

END;
$$;
