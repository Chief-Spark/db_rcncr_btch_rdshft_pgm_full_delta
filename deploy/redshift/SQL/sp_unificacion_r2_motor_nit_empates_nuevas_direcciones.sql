-- R2 Motor — NIT y empates (Esc3/Esc5/Esc6)
-- Escenario: fusiona las N direcciones del grupo por COMPONENTES y persiste la
--            direccion generada + su RPU sintetica.
-- Fuente: edf_views → bdm_tempo.v_xpm_* | Salida: bdm_datos.direccion_fisica_generada + bdm_datos.rpu_generada
-- Prerequisito: sp_unificacion_r2_esc6_frecuencia_complemento_gana
--               sp_unificacion_r2_construir_diccionario_complementos
--
-- PARIDAD CON TERADATA (PRO_UnificacionR2.sql). El legado NO concatena cadenas:
-- descompone cada complemento en COMPONENTES contra el diccionario y vuelve a
-- armar la cadena en orden de nivel.
--
--   E03_B1 (linea 787)   descomposicion por nomenclatura:
--     INNER JOIN DICCIONARIO_COMPLEMENTOS DC
--       ON TU.complemento LIKE '%'||DC.nomenclatura||'%'
--     LEFT JOIN NOMENCLATURA NOM ON NOM.NOMENCLATURA = DC.Nomen
--     ID_COM  = rank por Nivel_Complemento DESC
--     ID_COM1 = rank por Nivel_Complemento ASC
--
--   E03_B2 (linea 866)   firma del grupo de componentes:
--     NOM_AGRUP = XMLAGG(NOMEN ORDER BY ID_COM)      -> nivel DESC
--
--   ORDEN  (linea 1017)  posicion del componente dentro de la direccion:
--     SUM(1) OVER(... ORDER BY MDIR, ID_COM DESC, TO_NUMBER(DC.VALOR) ...)
--     ID_COM DESC equivale a nivel ASC, con el valor numerico como desempate.
--
-- De ahi los dos LISTAGG de abajo: complemento_motor se arma en nivel ASC (el
-- orden de ORDEN, que es como se lee una direccion: BL 5 TO 2 AP 301) y
-- nom_agrup en nivel DESC (el orden de NOM_AGRUP, que es la firma del grupo).
--
-- TRES CORRECCIONES RESPECTO A LA VERSION ANTERIOR
--   1. Fusion N-aria. Antes el self-join exigia motor_rn = 1 y motor_rn = 2, de
--      modo que un grupo de tres o mas direcciones perdia todo lo que no
--      estuviera en las dos primeras. Ahora la fusion recorre el grupo COMPLETO.
--   2. Fusion por componentes y no por cadena. Antes
--      TRIM(ra.complemento) || ' ' || TRIM(rb.complemento) duplicaba los
--      componentes repetidos: 'AP 301 TO 2' + 'AP 301 BL 5' daba
--      'AP 301 TO 2 AP 301 BL 5'. Ahora se deduplica por 'nomen' y queda
--      'BL 5 TO 2 AP 301' (niveles BL=2, TO=4, AP=7).
--   3. Persistencia. Antes la salida se quedaba en staging y nadie la escribia,
--      asi que la direccion generada no existia para las vistas ni para el
--      Ordenamiento. Ahora se persiste con el UPSERT del legado.
--
-- CONSECUENCIA DELIBERADA DEL INNER JOIN AL DICCIONARIO
--   Un grupo cuyos complementos no contienen NINGUNA nomenclatura del catalogo
--   no produce componentes y por lo tanto NO genera direccion. Es el
--   comportamiento del legado (el join a DICCIONARIO_COMPLEMENTOS en E03_B1 y
--   en la linea 1021 es INNER, no LEFT). La version anterior si generaba una
--   direccion en ese caso, con la concatenacion cruda de dos complementos que
--   el motor no sabia interpretar.
--
-- PRECEDENCIA AL FUSIONAR
--   Si dos direcciones del grupo traen el MISMO nomen con valores distintos
--   ('AP 301' y 'AP 302'), gana la de menor motor_rn, es decir la de menor
--   cod_dw_persona_ubic. Generaliza a N la precedencia que la version anterior
--   ya tenia implicita al tomar rn=1 como lado izquierdo del self-join.
CREATE OR REPLACE PROCEDURE bdm_datos.sp_unificacion_r2_motor_nit_empates_nuevas_direcciones(
    p_modo VARCHAR,   -- FULL | DELTA (modo efectivo de la corrida)
    p_lote INTEGER    -- Lote_Corrida externo (reemplaza el 1 hardcodeado)
)
NONATOMIC
LANGUAGE plpgsql
AS $$
BEGIN
  DROP TABLE IF EXISTS bdm_tempo.stg_motor_keys;
  DROP TABLE IF EXISTS bdm_tempo.stg_motor_ranked;
  DROP TABLE IF EXISTS bdm_tempo.stg_motor_componentes;
  DROP TABLE IF EXISTS bdm_tempo.stg_motor_fusion;
  DROP TABLE IF EXISTS bdm_tempo.stg_motor_insumo;

  -- Grupos que el motor debe fusionar: Esc3 NIT / Esc5 / Esc6.
  CREATE TABLE bdm_tempo.stg_motor_keys
  DISTSTYLE KEY DISTKEY(id_buro_persona)
  AS
  SELECT DISTINCT id_buro_persona, texto_ubicacion, cod_dw_tipo_ubicacion_dir, cod_dw_municipio
  FROM (
    SELECT e.id_buro_persona, e.texto_ubicacion, e.cod_dw_tipo_ubicacion_dir, e.cod_dw_municipio
    FROM bdm_tempo.stg_regla2_e2 e
    JOIN bdm_tempo.stg_regla2_insumo i ON i.cod_dw_persona_ubic = e.cod_dw_persona_ubic
    WHERE e.ind_unificacion = 'N' AND COALESCE(i.cod_tipo_ident_fte, 0) = 3
    GROUP BY 1, 2, 3, 4
    HAVING COUNT(DISTINCT e.cod_dw_persona_ubic) >= 2

    UNION

    SELECT DISTINCT a.id_buro_persona, a.texto_ubicacion, a.cod_dw_tipo_ubicacion_dir, a.cod_dw_municipio
    FROM bdm_tempo.stg_regla2_e05_a a
    JOIN bdm_tempo.stg_regla2_e05_a b
      ON a.id_buro_persona = b.id_buro_persona
     AND a.texto_ubicacion = b.texto_ubicacion
     AND a.cod_dw_tipo_ubicacion_dir = b.cod_dw_tipo_ubicacion_dir
     AND a.cod_dw_municipio = b.cod_dw_municipio
     AND a.cod_dw_persona_ubic <> b.cod_dw_persona_ubic
     AND COALESCE(a.nivel_pri, 99) <> COALESCE(b.nivel_pri, 99)
    WHERE a.nomenclatura_pri IS NOT NULL AND b.nomenclatura_pri IS NOT NULL

    UNION

    SELECT DISTINCT a.id_buro_persona, a.texto_ubicacion, a.cod_dw_tipo_ubicacion_dir, a.cod_dw_municipio
    FROM (SELECT * FROM bdm_tempo.stg_regla2_e2 WHERE ind_unificacion = 'N') a
    JOIN (SELECT * FROM bdm_tempo.stg_regla2_e2 WHERE ind_unificacion = 'N') b
      ON a.id_buro_persona = b.id_buro_persona
     AND a.texto_ubicacion = b.texto_ubicacion
     AND a.cod_dw_tipo_ubicacion_dir = b.cod_dw_tipo_ubicacion_dir
     AND a.cod_dw_municipio = b.cod_dw_municipio
     AND a.cod_dw_persona_ubic <> b.cod_dw_persona_ubic
     AND a.complemento <> b.complemento
    JOIN bdm_tempo.stg_regla2_e06_freq fa ON a.cod_dw_persona_ubic = fa.cod_dw_persona_ubic
    JOIN bdm_tempo.stg_regla2_e06_freq fb ON b.cod_dw_persona_ubic = fb.cod_dw_persona_ubic
    WHERE fa.freq = fb.freq
  ) motor_src;

  -- Direcciones de cada grupo, ordenadas. motor_rn fija la precedencia.
  CREATE TABLE bdm_tempo.stg_motor_ranked
  DISTSTYLE KEY DISTKEY(id_buro_persona)
  AS
  SELECT
    e.*,
    ROW_NUMBER() OVER (
      PARTITION BY e.id_buro_persona, e.texto_ubicacion, e.cod_dw_tipo_ubicacion_dir, e.cod_dw_municipio
      ORDER BY e.cod_dw_persona_ubic
    ) AS motor_rn
  FROM bdm_tempo.stg_regla2_e2 e
  JOIN bdm_tempo.stg_motor_keys k
    ON k.id_buro_persona = e.id_buro_persona
   AND k.texto_ubicacion = e.texto_ubicacion
   AND k.cod_dw_tipo_ubicacion_dir = e.cod_dw_tipo_ubicacion_dir
   AND k.cod_dw_municipio = e.cod_dw_municipio
  WHERE e.ind_unificacion = 'N';

  -- (E03_B1) Descomposicion del complemento en componentes.
  CREATE TABLE bdm_tempo.stg_motor_componentes
  DISTSTYLE KEY DISTKEY(id_buro_persona)
  AS
  SELECT
    r.id_buro_persona,
    r.texto_ubicacion,
    r.cod_dw_tipo_ubicacion_dir,
    r.cod_dw_municipio,
    r.cod_dw_persona_ubic,
    r.motor_rn,
    dc.nomen,
    -- El legado hace LEFT JOIN al catalogo: un nomen sin nivel no desaparece,
    -- se va al final del orden. 99 reproduce eso sin arriesgar NULLs en el
    -- ORDER BY del LISTAGG.
    COALESCE(cat.nivel_complemento, 99) AS nivel_complemento,
    dc.valor
  FROM bdm_tempo.stg_motor_ranked r
  JOIN bdm_datos.diccionario_complementos dc
    ON dc.id_buro_persona = r.id_buro_persona
   AND dc.cod_dw_ubic = r.cod_dw_ubic
   AND UPPER(COALESCE(r.complemento, '')) LIKE '%' || dc.nomenclatura || '%'
  LEFT JOIN bdm_datos.nomenclatura cat
    ON cat.nomenclatura = dc.nomen;

  -- Fusion N-aria: UN componente por 'nomen' para todo el grupo.
  CREATE TABLE bdm_tempo.stg_motor_fusion
  DISTSTYLE KEY DISTKEY(id_buro_persona)
  AS
  SELECT
    z.id_buro_persona,
    z.texto_ubicacion,
    z.cod_dw_tipo_ubicacion_dir,
    z.cod_dw_municipio,
    z.nomen,
    z.nivel_complemento,
    z.valor
  FROM (
    SELECT
      c.*,
      ROW_NUMBER() OVER (
        PARTITION BY c.id_buro_persona, c.texto_ubicacion,
                     c.cod_dw_tipo_ubicacion_dir, c.cod_dw_municipio, c.nomen
        ORDER BY c.motor_rn, c.cod_dw_persona_ubic
      ) AS pick
    FROM bdm_tempo.stg_motor_componentes c
  ) z
  WHERE z.pick = 1;

  -- Una fila por GRUPO: atributos heredados de la direccion rn=1 y el
  -- complemento rearmado a partir de los componentes fusionados.
  CREATE TABLE bdm_tempo.stg_motor_insumo
  DISTSTYLE KEY DISTKEY(id_buro_persona)
  AS
  SELECT
    ra.id_buro_persona,
    i.cod_pin_persona,
    ra.cod_dw_ubic,
    ra.cod_dw_tipo_ubicacion_dir,
    ra.fecha_relacion_persona_ubicaci,
    i.lote,
    i.cod_tipo_ident_fte,
    dfa.tipo_via_principal,
    dfa.via_principal,
    dfa.via_generadora,
    dfa.numero_puerta,
    FNV_HASH(CAST(ra.id_buro_persona AS VARCHAR) || '|MOTOR|DF|' || ra.texto_ubicacion) AS cod_dw_direccion_fisica,
    FNV_HASH(CAST(ra.id_buro_persona AS VARCHAR) || '|MOTOR|RPU|' || ra.texto_ubicacion) AS cod_dw_persona_ubic,
    f.complemento_motor,
    f.nom_agrup,
    CAST(1 AS INTEGER) AS generada_enriquecida
  FROM bdm_tempo.stg_motor_ranked ra
  JOIN bdm_tempo.stg_regla2_insumo i
    ON i.cod_dw_persona_ubic = ra.cod_dw_persona_ubic
  JOIN bdm_tempo.v_xpm_direccion_fisica dfa
    ON dfa.cod_dw_direccion_fisica = ra.cod_dw_direccion_fisica
  JOIN (
    SELECT
      id_buro_persona,
      texto_ubicacion,
      cod_dw_tipo_ubicacion_dir,
      cod_dw_municipio,
      -- (ORDEN) nivel ASC, valor numerico como desempate: 'BL 5 TO 2 AP 301'
      LISTAGG(TRIM(nomen || ' ' || COALESCE(valor, '')), ' ')
        WITHIN GROUP (ORDER BY nivel_complemento,
                               -- El legado desempata por TO_NUMBER(DC.VALOR), no
                               -- por texto: hay niveles compartidos (BL/ED=2,
                               -- MZ/LC=3, TO/CA=4, CS/LT=5) y en orden lexical
                               -- '10' iria antes que '9'. El REGEXP_REPLACE evita
                               -- fallar si alguien dejara un valor no numerico.
                               CAST(NULLIF(REGEXP_REPLACE(COALESCE(valor, ''),
                                                          '[^0-9]', ''), '') AS BIGINT),
                               nomen) AS complemento_motor,
      -- (NOM_AGRUP) firma del grupo de componentes, nivel DESC
      LISTAGG(nomen, '')
        WITHIN GROUP (ORDER BY nivel_complemento DESC, nomen) AS nom_agrup
    FROM bdm_tempo.stg_motor_fusion
    GROUP BY 1, 2, 3, 4
  ) f
    ON f.id_buro_persona = ra.id_buro_persona
   AND f.texto_ubicacion = ra.texto_ubicacion
   AND f.cod_dw_tipo_ubicacion_dir = ra.cod_dw_tipo_ubicacion_dir
   AND f.cod_dw_municipio = ra.cod_dw_municipio
  WHERE ra.motor_rn = 1;

  -- ----------------------------------------------------------------------
  -- PERSISTENCIA
  -- El legado la hace con el TPT P0020_UNIFICACION_DIRECCION_130.TPT:
  --   UPDATE ... SET Lote_Actualizacion ... INSERT FOR MISSING UPDATE ROWS
  -- y su tercer destino inserta en DIRECCION_FISICA con Generada_Enriquecida=1.
  -- Aqui se reproduce como UPDATE + INSERT WHERE NOT EXISTS, que es el mismo
  -- patron que ya usan los SP de escenario. La clave es estable entre corridas
  -- porque sale de FNV_HASH sobre (persona, texto_ubicacion), asi que una
  -- segunda corrida actualiza en vez de duplicar.
  -- FULL borra el historico de direcciones generadas; DELTA acumula.
  -- ----------------------------------------------------------------------
  IF p_modo = 'FULL' THEN
    DELETE FROM bdm_datos.rpu_generada;
    DELETE FROM bdm_datos.direccion_fisica_generada;
  END IF;

  UPDATE bdm_datos.direccion_fisica_generada
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
   WHERE bdm_datos.direccion_fisica_generada.cod_dw_direccion_fisica = s.cod_dw_direccion_fisica;

  INSERT INTO bdm_datos.direccion_fisica_generada (
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
                       FROM bdm_datos.direccion_fisica_generada d
                      WHERE d.cod_dw_direccion_fisica = s.cod_dw_direccion_fisica );

  UPDATE bdm_datos.rpu_generada
     SET cod_dw_ubic                    = s.cod_dw_ubic,
         cod_dw_direccion_fisica        = s.cod_dw_direccion_fisica,
         cod_dw_tipo_ubicacion_dir      = s.cod_dw_tipo_ubicacion_dir,
         fecha_relacion_persona_ubicaci = s.fecha_relacion_persona_ubicaci,
         lote_actualizacion             = p_lote,
         usuario_bd                     = CURRENT_USER,
         fecha_modificacion             = CURRENT_DATE
    FROM bdm_tempo.stg_motor_insumo s
   WHERE bdm_datos.rpu_generada.cod_dw_persona_ubic = s.cod_dw_persona_ubic;

  INSERT INTO bdm_datos.rpu_generada (
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
    s.fecha_relacion_persona_ubicaci, p_lote, p_lote,
    CAST(s.cod_tipo_ident_fte AS VARCHAR(20)), CURRENT_USER, NULL, CURRENT_DATE
  FROM bdm_tempo.stg_motor_insumo s
  WHERE NOT EXISTS ( SELECT 1
                       FROM bdm_datos.rpu_generada r
                      WHERE r.cod_dw_persona_ubic = s.cod_dw_persona_ubic );

END;
$$;
