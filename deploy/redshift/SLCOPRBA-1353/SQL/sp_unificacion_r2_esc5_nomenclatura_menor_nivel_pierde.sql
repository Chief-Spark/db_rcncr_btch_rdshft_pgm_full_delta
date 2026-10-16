-- R2 Esc5 - nivel de nomenclatura
-- Escenario: Nomenclaturas distintas: menor nivel pierde
-- Fuente: edf_views -> bdm_tempo.v_xpm_* | Salida: bdm_datos.unificacion_direccion
-- Prerequisito: sp_unificacion_r2_esc4_diccionario_frecuencia_complemento
-- Generado: tools/gen_unificacion_sps_por_escenario.py

CREATE OR REPLACE PROCEDURE bdm_datos.sp_unificacion_r2_esc5_nomenclatura_menor_nivel_pierde(
    p_modo VARCHAR,   -- FULL | DELTA (modo efectivo de la corrida)
    p_lote INTEGER    -- Lote_Corrida externo (reemplaza el 1 hardcodeado)
)
NONATOMIC
LANGUAGE plpgsql
AS $$
BEGIN
  CREATE TABLE bdm_tempo.stg_regla2_e05
  DISTSTYLE KEY DISTKEY(id_buro_persona)
  AS
  SELECT DISTINCT a.*
  FROM (SELECT * FROM bdm_tempo.stg_regla2_e2 WHERE ind_unificacion = 'N') a
  JOIN (SELECT * FROM bdm_tempo.stg_regla2_e2 WHERE ind_unificacion = 'N') b
    ON a.id_buro_persona = b.id_buro_persona
   AND a.texto_ubicacion = b.texto_ubicacion
   AND a.cod_dw_tipo_ubicacion_dir = b.cod_dw_tipo_ubicacion_dir
   AND a.cod_dw_municipio = b.cod_dw_municipio
   AND a.cod_dw_persona_ubic <> b.cod_dw_persona_ubic
   AND a.complemento <> b.complemento;

  CREATE TABLE bdm_tempo.stg_regla2_e05_a
  DISTSTYLE KEY DISTKEY(id_buro_persona)
  AS
  SELECT DISTINCT
    a.*,
    nmc1.nomenclatura AS nomenclatura_pri,
    nmc1.nivel_complemento AS nivel_pri
  FROM bdm_tempo.stg_regla2_e05 a
  LEFT JOIN bdm_datos.nomenclatura nmc1
    ON a.complemento LIKE TRIM(nmc1.nomenclatura) || ' %';

  -- SLCOPRBA-1355: UN SOLO PADRE POR HIJA.
  --
  -- Este CREATE terminaba en el predicado de nivel y nada mas, de modo que una
  -- direccion recibia un par por CADA candidato de nivel menor. esc5 era el
  -- UNICO escenario de la Regla 2 sin reduccion: esc1 y esc2 reducen con
  -- ROW_NUMBER ... rn = 1, esc3 con el MAX(ORDEN) del legado, esc4 con su
  -- ganador y esc6 se corrigio en su momento por el mismo motivo.
  --
  -- COMO SE MANIFIESTA: con tres direcciones en niveles 1, 2 y 3 dentro del
  -- mismo grupo (persona, texto_ubicacion, tipo, municipio) la version anterior
  -- emitia
  --     nivel2 -> nivel1      nivel3 -> nivel1      nivel3 -> nivel2
  -- de modo que nivel3 quedaba con DOS padres (viola R2-11) y nivel2 quedaba
  -- padre e hija a la vez (viola R2-10). El UPSERT no lo impide: la
  -- Clave_Unificacion es el PAR, asi que las dos filas entran.
  --
  -- POR QUE NO LO VEIA LA BATERIA: el arquetipo de esc5 tiene DOS direcciones
  -- ('BR 5' contra 'AP 301'), y con dos miembros no hay cadena de niveles que
  -- lo destape. CA-U05 vigila exactamente esto y pasaba por falta de dato, no
  -- por correccion. Es el unico defecto de la lista que CORROMPE datos en vez
  -- de dejar de producirlos: con datos reales basta una persona con tres
  -- nomenclaturas de niveles distintos en la misma puerta.
  --
  -- NO SE TOCA EL CRITERIO, solo la reduccion. Entre varios padres posibles
  -- gana el de nivel MAS BAJO -- que es la direccion del criterio actual, el
  -- que el censo describe como "gana la nomenclatura de menor nivel" -- y el
  -- desempate por cod_dw_persona_ubic es DETERMINISTA a proposito: sin el, el
  -- padre elegido podria variar entre corridas y romperia los checksums de
  -- convergencia CA-C02..CA-C04.
  CREATE TABLE bdm_tempo.stg_regla2_e05_pares
  DISTSTYLE KEY DISTKEY(cod_dw_persona_ubic)
  AS
  SELECT cod_dw_persona_ubic, id_padre
  FROM (
    SELECT
      b.cod_dw_persona_ubic,
      a.cod_dw_persona_ubic AS id_padre,
      ROW_NUMBER() OVER (
        PARTITION BY b.cod_dw_persona_ubic
        ORDER BY COALESCE(a.nivel_pri, 99), a.cod_dw_persona_ubic
      ) AS rn
    FROM bdm_tempo.stg_regla2_e05_a a
    JOIN bdm_tempo.stg_regla2_e05_a b
      ON a.id_buro_persona = b.id_buro_persona
     AND a.texto_ubicacion = b.texto_ubicacion
     AND a.cod_dw_tipo_ubicacion_dir = b.cod_dw_tipo_ubicacion_dir
     AND a.cod_dw_municipio = b.cod_dw_municipio
     AND a.cod_dw_persona_ubic <> b.cod_dw_persona_ubic
     AND a.complemento <> b.complemento
     AND COALESCE(a.nivel_pri,99) < COALESCE(b.nivel_pri,99)
    WHERE a.nomenclatura_pri IS NOT NULL
      AND b.nomenclatura_pri IS NOT NULL
      AND a.nomenclatura_pri <> b.nomenclatura_pri
  ) r
  WHERE rn = 1;

  -- Persistencia condicional al modo (Tarea 6.1, Req 5.1..5.6).
  -- 1) Materializar el resultado de la regla (SELECT DISTINCT, Req 5.5).
  DROP TABLE IF EXISTS bdm_tempo.sp_unificacion_r2_esc5_nomenclatura_menor_nivel_pierde_persist;
  CREATE TABLE bdm_tempo.sp_unificacion_r2_esc5_nomenclatura_menor_nivel_pierde_persist
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
  FROM bdm_tempo.stg_regla2_e05_pares;

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
    INSERT INTO bdm_datos.unificacion_direccion
      (cod_dw_persona_ubic, cod_dw_direccion_unificada, unifica_atributos, fecha_unificacion, lote, severidad, usuario_bd)
    SELECT DISTINCT s.cod_dw_persona_ubic, s.cod_dw_direccion_unificada, s.unifica_atributos,
           s.fecha_unificacion, s.lote, s.severidad, s.usuario_bd
    FROM bdm_tempo.sp_unificacion_r2_esc5_nomenclatura_menor_nivel_pierde_persist s
    WHERE NOT EXISTS (
      SELECT 1
      FROM bdm_datos.unificacion_direccion u
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
    UPDATE bdm_datos.unificacion_direccion
       SET lote_actualizacion = p_lote,
           fecha_modificacion = CURRENT_DATE,
           usuario_bd         = CURRENT_USER
      FROM bdm_tempo.sp_unificacion_r2_esc5_nomenclatura_menor_nivel_pierde_persist s
     WHERE bdm_datos.unificacion_direccion.cod_dw_persona_ubic = s.cod_dw_persona_ubic
       AND bdm_datos.unificacion_direccion.cod_dw_direccion_unificada = s.cod_dw_direccion_unificada;

    INSERT INTO bdm_datos.unificacion_direccion
      (cod_dw_persona_ubic, cod_dw_direccion_unificada, unifica_atributos, fecha_unificacion, lote, severidad, usuario_bd)
    SELECT DISTINCT s.cod_dw_persona_ubic, s.cod_dw_direccion_unificada, s.unifica_atributos,
           s.fecha_unificacion, s.lote, s.severidad, s.usuario_bd
    FROM bdm_tempo.sp_unificacion_r2_esc5_nomenclatura_menor_nivel_pierde_persist s
    WHERE NOT EXISTS (
      SELECT 1
      FROM bdm_datos.unificacion_direccion u
      WHERE u.cod_dw_persona_ubic = s.cod_dw_persona_ubic
        AND u.cod_dw_direccion_unificada = s.cod_dw_direccion_unificada);
  END IF;

  DROP TABLE IF EXISTS bdm_tempo.sp_unificacion_r2_esc5_nomenclatura_menor_nivel_pierde_persist;

  UPDATE bdm_tempo.stg_regla2_e2
  SET id_padre = e.id_padre,
      ind_unificacion = 'S',
      -- SLCOPRBA-1355: el legado sella esc5 con 'C7'
      -- (PRO_UnificacionR2.sql linea 3991), no con 'E5'. Nada lee el VALOR
      -- de n_id, asi que no cambia ningun resultado; se alinea porque una
      -- diferencia gratuita estorbaria en la conciliacion contra el legado.
      n_id = 'C7'
  FROM bdm_tempo.stg_regla2_e05_pares e
  WHERE bdm_tempo.stg_regla2_e2.cod_dw_persona_ubic = e.cod_dw_persona_ubic
    AND bdm_tempo.stg_regla2_e2.id_padre IS NULL;


END;
$$;
-- SLCOPRBA-1355: re-DPLY DEV post DROP SCHEMA strct #256
