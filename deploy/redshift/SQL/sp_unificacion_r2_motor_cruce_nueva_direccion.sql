-- R2 Motor CRUCE (escenario 6 subcaso 1 del legado) -- creacion de direcciones nuevas
-- Escenario 6 subcaso 1: dos complementos comparten una nomenclatura pero en
--   POSICIONES CRUZADAS (la que encabeza en uno va en medio en el otro), y la
--   cola de uno esta CONTENIDA en la del otro. Se arma una direccion nueva que
--   fusiona los dos complementos y los dos originales quedan como hijos.
--   Marca 'A8'.
-- Fuente: edf_views -> bdm_tempo.v_xpm_* | Salida: bdm_datos.direccion_fisica_generada + bdm_datos.rpu_generada + bdm_datos.unificacion_direccion
-- Prerequisito: sp_unificacion_r2_motor_nivel_nueva_direccion (sello 'A6')
--               sp_unificacion_r2_construir_diccionario_complementos
--
-- PARIDAD CON TERADATA (PRO_UnificacionR2.sql lineas 4016-4708)
--
-- Es el TERCER sitio que crea direcciones. Los dos primeros ya estaban
-- portados; este cierra el primero de los dos que faltaban para R2-07:
--
--   linea 1602  cadena Tmp_Unificacion_E03*   etapa (3)    marca 'X4'
--   linea 3423  cadena Tmp_Unificacion_E051*  etapa (5.1)  marca 'A6'
--   linea 4016  cadena Tmp_Unificacion_E061*  etapa (6.1)  marca 'A8'   <- este
--   linea 4715  cadena Tmp_Unificacion_E062*  etapa (6.2)  marca 'D9'   (pendiente)
--
-- El sello 'A8' no es una invencion: lo fija el MERGE de cierre del legado
-- (linea 4672, "N_ID = ''A8''").
--
-- QUE DISTINGUE A ESTE SUBCASO. El espacio del par ya esta repartido entre
-- cinco casos disjuntos, y lo que los separa es COMO se relacionan las dos
-- nomenclaturas de cada complemento (NMC1 la que encabeza, NMC2 la de en
-- medio):
--
--   A6  esc5 sub1  una coincide EN LA MISMA POSICION, la otra difiere y esta
--                  a distinto nivel; los valores son DIFERENTES
--   C7  esc5 sub2  igual, pero los valores son IGUALES -> decide el diccionario
--   A8  esc6 sub1  una coincide EN POSICION CRUZADA (NMC1 de A con NMC2 de B,
--                  o NMC2 de A con NMC1 de B) y las colas se CONTIENEN  <- este
--   D9  esc6 sub2  NINGUNA coincide en ninguna combinacion y los niveles difieren
--   F1  esc6 sub3  los niveles son IGUALES -> decide el diccionario
--
-- El predicado del cruce es Tmp_Unificacion_E061_C (linea 4143), dos ramas en
-- UNION ALL:
--   rama 1   COALESCE(A.NOMENCLATURA , 'A') = COALESCE(B.NOMENCLATURA1, 'B')
--   rama 2   COALESCE(A.NOMENCLATURA1, 'A') = COALESCE(B.NOMENCLATURA , 'B')
-- Los COALESCE con literales distintos ('A' contra 'B') son el idioma del
-- legado para que dos NULL NO casen: si ambas nomenclaturas faltan, la
-- comparacion es 'A' = 'B', que es falsa. Aqui el JOIN al catalogo ya es INNER
-- por las dos nomenclaturas, de modo que ninguna puede ser nula y los COALESCE
-- sobran; se omiten y el resultado es el mismo.
--
-- NOM_A y NOM_B (linea 4146): el complemento partido en el punto donde aparece
-- la nomenclatura que hizo match.
--   NOM_A = SUBSTR(COMPLEMENTO, POSITION(nomen IN COMPLEMENTO), 100)  -- la COLA
--   NOM_B = SUBSTR(COMPLEMENTO, 1, POSITION(nomen IN COMPLEMENTO) - 1) -- el PREFIJO
-- En Redshift POSITION devuelve 0 cuando no encuentra, igual que Teradata, y
-- SUBSTR con inicio 0 se comporta distinto; por eso se usa STRPOS con guarda
-- explicita (GREATEST(..., 1)). El match esta garantizado por el JOIN del
-- catalogo, asi que la guarda nunca se dispara, pero deja el codigo cerrado.
--
-- SEGUNDO FILTRO, Tmp_Unificacion_E0611_C (linea 4216): de los pares cruzados
-- se quedan solo aquellos donde una cola CONTIENE a la otra y no son iguales
--   A.NOM_A LIKE '%' || B.NOM_A || '%'  AND  A.NOM_A <> B.NOM_A
-- (mas la rama simetrica). Es el "valores que estan incluidos" del comentario
-- de cabecera del legado.
--
-- QUIEN ES EL PADRE: NADIE. Y esta es la diferencia estructural con 'A6'.
-- En 'A6' el padre se ELIGE entre las filas existentes (MDIR = 1, la direccion
-- mas rica) y los hijos le aportan lo que le falta. Aqui el legado NO elige:
-- concatena los complementos de TODOS los miembros del grupo y con esa fusion
-- construye una direccion completamente nueva. Por eso en este SP no hay MDIR.
--
-- LO QUE ORDENA ES LA LONGITUD DEL COMPLEMENTO. Tmp_Unificacion_E061_D (linea
-- 4282) define
--   ID          = CHAR_LENGTH(COMPLEMENTO)
--   COMPLEMENTO1 = CASE WHEN NULLIF(NOM_B,'') IS NULL THEN NOM_A ELSE NOM_B END
-- o sea: si la nomenclatura que hizo match encabezaba el complemento el
-- prefijo es vacio y se toma la cola entera; si iba en medio se toma el
-- prefijo. Es la pieza que cada miembro aporta a la fusion.
--
-- LOS DOS 'WITH RECURSIVE' SON 'LISTAGG'. El legado usa dos veces el mismo
-- idioma de Teradata para agregar cadenas, que en Redshift es una sola funcion:
--
--   Tmp_Unificacion_E061_E  (linea 4359)  concatena los COMPLEMENTO1 del grupo
--     anchor: cada fila con LVL = 1
--     paso:   T1.ID > T2.ID, resultado T1 || ' ' || T2, LVL + 1
--     cierre: RANK() ... ORDER BY LVL DESC = 1  -- la cadena mas larga
--   Como T1 se antepone y la condicion es T1.ID > T2.ID, el resultado queda
--   ordenado por longitud DESCENDENTE. Equivale a
--     LISTAGG(complemento1, ' ') WITHIN GROUP (ORDER BY id_len DESC, ...)
--
--   Tmp_Unificacion_E061_EB (linea 4525)  reordena los componentes de la fusion
--     misma mecanica sobre ID_ORD_COMP = (nivel * 100000 + valor) * -1
--   El '* -1' invierte el sentido: T1.ID_ORD_COMP > T2.ID_ORD_COMP selecciona
--   el de MENOR (nivel, valor), y al anteponerse queda ordenado por nivel
--   ASCENDENTE. Equivale a
--     LISTAGG(nomenclatura, ' ') WITHIN GROUP (ORDER BY nivel, valor)
--   que es EXACTAMENTE el mismo reordenamiento ya portado para 'A6' en
--   stg_motor_niv_insumo. No es maquinaria nueva.
--
-- DIVERGENCIA DELIBERADA, Y POR QUE (anotada para GOB-03).
-- La recursion exige T1.ID > T2.ID ESTRICTO, de modo que dos complementos de
-- IGUAL longitud no pueden encadenarse: el legado deja a uno de ellos FUERA de
-- la cadena, y como varias cadenas quedan empatadas en LVL, el
-- 'RANK() ... ORDER BY LVL DESC = 1' escoge una cualquiera. El miembro que se
-- pierde depende del plan de ejecucion, no de los datos.
-- Aqui se porta la SEMANTICA declarada -- fusionar el grupo completo -- y no
-- ese no-determinismo: 'LISTAGG' incluye a todos los miembros, con un desempate
-- explicito por cod_dw_persona_ubic para que el resultado sea reproducible
-- corrida a corrida. Es la condicion que la idempotencia del pipeline (G-06)
-- exige y que la version literal del legado no puede cumplir.
--
-- Si tras la fusion el complemento no aporta ningun componente, no se crea
-- direccion y el grupo sigue su camino hasta esc5 / esc6.
CREATE OR REPLACE PROCEDURE bdm_datos.sp_unificacion_r2_motor_cruce_nueva_direccion(
    p_modo VARCHAR,   -- FULL | DELTA (modo efectivo de la corrida)
    p_lote INTEGER    -- Lote_Corrida externo
)
NONATOMIC
LANGUAGE plpgsql
AS $$
BEGIN
  DROP TABLE IF EXISTS bdm_tempo.stg_motor_crz_base;
  DROP TABLE IF EXISTS bdm_tempo.stg_motor_crz_cruce;
  DROP TABLE IF EXISTS bdm_tempo.stg_motor_crz_cand;
  DROP TABLE IF EXISTS bdm_tempo.stg_motor_crz_grupo;
  DROP TABLE IF EXISTS bdm_tempo.stg_motor_crz_fusion;
  DROP TABLE IF EXISTS bdm_tempo.stg_motor_crz_componentes;
  DROP TABLE IF EXISTS bdm_tempo.stg_motor_crz_nueva_nomen;
  DROP TABLE IF EXISTS bdm_tempo.stg_motor_crz_cabeza;
  DROP TABLE IF EXISTS bdm_tempo.stg_motor_crz_insumo;
  DROP TABLE IF EXISTS bdm_tempo.stg_motor_crz_miembros;
  DROP TABLE IF EXISTS bdm_tempo.stg_motor_crz_persist;

  -- (1) Tmp_Unificacion_E061 + Tmp_Unificacion_E061_A (lineas 4040 y 4094).
  --     Poblacion: lo que ningun escenario anterior consumio, descompuesto en
  --     su nomenclatura inicial y su nomenclatura intermedia.
  CREATE TABLE bdm_tempo.stg_motor_crz_base
  DISTSTYLE KEY DISTKEY(id_buro_persona)
  SORTKEY(id_buro_persona, texto_ubicacion)
  AS
  SELECT
    e.cod_dw_persona_ubic,
    e.id_buro_persona,
    e.cod_dw_ubic,
    e.texto_ubicacion,
    e.cod_dw_tipo_ubicacion_dir,
    e.cod_dw_municipio,
    e.complemento,
    e.cod_dw_direccion_fisica,
    nmc1.nomenclatura      AS nomen_pri,
    nmc1.nivel_complemento AS nivel_pri,
    nmc2.nomenclatura      AS nomen_sec,
    nmc2.nivel_complemento AS nivel_sec,
    LENGTH(TRIM(COALESCE(e.complemento, ''))) AS id_len
  FROM bdm_tempo.stg_regla2_e2 e
  JOIN bdm_datos.nomenclatura nmc1
    ON UPPER(COALESCE(e.complemento, '')) LIKE TRIM(nmc1.nomenclatura) || ' %'
  JOIN bdm_datos.nomenclatura nmc2
    ON UPPER(COALESCE(e.complemento, '')) LIKE '% ' || TRIM(nmc2.nomenclatura) || ' %'
  WHERE e.ind_unificacion = 'N';

  -- (2) Tmp_Unificacion_E061_C (linea 4143): el CRUCE de posiciones, con el
  --     complemento partido en el punto del match.
  --     Las dos ramas del UNION ALL se expresan con un CASE sobre que
  --     nomenclatura caso, porque el punto de corte depende de cual fue.
  CREATE TABLE bdm_tempo.stg_motor_crz_cruce
  DISTSTYLE KEY DISTKEY(id_buro_persona)
  AS
  SELECT z.cod_dw_persona_ubic, z.id_buro_persona, z.cod_dw_ubic,
         z.texto_ubicacion, z.cod_dw_tipo_ubicacion_dir, z.cod_dw_municipio,
         z.complemento, z.cod_dw_direccion_fisica, z.id_len,
         z.nom_a, z.nom_b
  FROM (
    SELECT
      a.cod_dw_persona_ubic, a.id_buro_persona, a.cod_dw_ubic,
      a.texto_ubicacion, a.cod_dw_tipo_ubicacion_dir, a.cod_dw_municipio,
      a.complemento, a.cod_dw_direccion_fisica, a.id_len,
      -- NOM_A: la COLA desde la nomenclatura que caso.
      SUBSTRING(UPPER(COALESCE(a.complemento, '')),
                GREATEST(STRPOS(UPPER(COALESCE(a.complemento, '')), TRIM(x.nomen_match)), 1),
                100) AS nom_a,
      -- NOM_B: el PREFIJO anterior a esa nomenclatura. Vacio si encabezaba.
      SUBSTRING(UPPER(COALESCE(a.complemento, '')),
                1,
                GREATEST(STRPOS(UPPER(COALESCE(a.complemento, '')), TRIM(x.nomen_match)) - 1, 0)) AS nom_b,
      ROW_NUMBER() OVER (PARTITION BY a.cod_dw_persona_ubic
                             ORDER BY x.nomen_match) AS rn
    FROM bdm_tempo.stg_motor_crz_base a
    JOIN (
      -- rama 1: la que encabeza en A va en medio en B
      SELECT DISTINCT a1.cod_dw_persona_ubic, a1.nomen_pri AS nomen_match
      FROM bdm_tempo.stg_motor_crz_base a1
      JOIN bdm_tempo.stg_motor_crz_base b1
        ON  b1.id_buro_persona           = a1.id_buro_persona
        AND b1.texto_ubicacion           = a1.texto_ubicacion
        AND b1.cod_dw_tipo_ubicacion_dir = a1.cod_dw_tipo_ubicacion_dir
        AND b1.cod_dw_municipio          = a1.cod_dw_municipio
        AND b1.cod_dw_persona_ubic      <> a1.cod_dw_persona_ubic
        AND b1.complemento              <> a1.complemento
        AND a1.nomen_pri                 = b1.nomen_sec
      UNION
      -- rama 2: la que va en medio en A encabeza en B
      SELECT DISTINCT a2.cod_dw_persona_ubic, a2.nomen_sec AS nomen_match
      FROM bdm_tempo.stg_motor_crz_base a2
      JOIN bdm_tempo.stg_motor_crz_base b2
        ON  b2.id_buro_persona           = a2.id_buro_persona
        AND b2.texto_ubicacion           = a2.texto_ubicacion
        AND b2.cod_dw_tipo_ubicacion_dir = a2.cod_dw_tipo_ubicacion_dir
        AND b2.cod_dw_municipio          = a2.cod_dw_municipio
        AND b2.cod_dw_persona_ubic      <> a2.cod_dw_persona_ubic
        AND b2.complemento              <> a2.complemento
        AND a2.nomen_sec                 = b2.nomen_pri
    ) x
      ON x.cod_dw_persona_ubic = a.cod_dw_persona_ubic
  ) z
  WHERE z.rn = 1;

  -- (3) Tmp_Unificacion_E0611_C (linea 4216): de los cruzados, solo los pares
  --     cuyas COLAS se contienen y no son iguales.
  CREATE TABLE bdm_tempo.stg_motor_crz_cand
  DISTSTYLE KEY DISTKEY(id_buro_persona)
  AS
  SELECT a.*
  FROM bdm_tempo.stg_motor_crz_cruce a
  WHERE EXISTS (
    SELECT 1
      FROM bdm_tempo.stg_motor_crz_cruce b
     WHERE b.id_buro_persona           = a.id_buro_persona
       AND b.texto_ubicacion           = a.texto_ubicacion
       AND b.cod_dw_tipo_ubicacion_dir = a.cod_dw_tipo_ubicacion_dir
       AND b.cod_dw_municipio          = a.cod_dw_municipio
       AND b.cod_dw_ubic               = a.cod_dw_ubic
       AND b.cod_dw_persona_ubic      <> a.cod_dw_persona_ubic
       AND b.complemento              <> a.complemento
       AND (    ( a.nom_a LIKE '%' || b.nom_a || '%' AND a.nom_a <> b.nom_a )
             OR ( b.nom_a LIKE '%' || a.nom_a || '%' AND b.nom_a <> a.nom_a ) ) );

  -- (4) Tmp_Unificacion_E061_D (linea 4282): lo que cada miembro APORTA a la
  --     fusion. El legado lo llama COMPLEMENTO1.
  CREATE TABLE bdm_tempo.stg_motor_crz_grupo
  DISTSTYLE KEY DISTKEY(id_buro_persona)
  AS
  SELECT
    c.cod_dw_persona_ubic,
    c.id_buro_persona,
    c.cod_dw_ubic,
    c.texto_ubicacion,
    c.cod_dw_tipo_ubicacion_dir,
    c.cod_dw_municipio,
    c.complemento,
    c.cod_dw_direccion_fisica,
    c.id_len,
    TRIM(CASE WHEN NULLIF(TRIM(c.nom_b), '') IS NULL THEN c.nom_a ELSE c.nom_b END) AS aporte
  FROM bdm_tempo.stg_motor_crz_cand c;

  -- (5) Tmp_Unificacion_E061_E (linea 4359), primer WITH RECURSIVE: la fusion
  --     de los aportes del grupo, por longitud DESCENDENTE.
  --     Solo grupos de DOS O MAS miembros, que es el
  --     'WHERE CL.Cod_DW_Persona_Ubic LIKE ''%,%''' del legado (linea 4404).
  CREATE TABLE bdm_tempo.stg_motor_crz_fusion
  DISTSTYLE KEY DISTKEY(id_buro_persona)
  AS
  SELECT
    g.id_buro_persona,
    g.cod_dw_ubic,
    g.texto_ubicacion,
    g.cod_dw_tipo_ubicacion_dir,
    g.cod_dw_municipio,
    COUNT(*)                                      AS miembros,
    -- Los DOS LISTAGG comparten el mismo WITHIN GROUP, y no solo porque Redshift
    -- lo exija ("within group ORDER BY clauses for aggregate functions must be
    -- the same"): es lo FIEL al legado. En Tmp_Unificacion_E061_E la lista de
    -- personas y el complemento se construyen en la MISMA recursion
    -- (T1 || ',' || T2 y T1 || ' ' || T2 avanzan juntos), de modo que ambas
    -- comparten orden por construccion. El desempate por cod_dw_persona_ubic
    -- sustituye al no-determinismo del legado ante longitudes iguales.
    LISTAGG(CAST(g.cod_dw_persona_ubic AS VARCHAR), ',')
      WITHIN GROUP (ORDER BY g.id_len DESC, g.cod_dw_persona_ubic) AS hijos,
    LISTAGG(g.aporte, ' ')
      WITHIN GROUP (ORDER BY g.id_len DESC, g.cod_dw_persona_ubic) AS complemento_fusion
  FROM bdm_tempo.stg_motor_crz_grupo g
  GROUP BY 1, 2, 3, 4, 5
  HAVING COUNT(*) > 1;

  -- (6) Tmp_Unificacion_E061_EA (linea 4455): descomposicion de la fusion en
  --     componentes del diccionario, con su nivel.
  --     El join es por (cod_dw_ubic, id_buro_persona) + LIKE, igual que el
  --     legado. Un LIKE con patron derivado de columna SI es valido en
  --     Redshift; lo que no lo seria es un REGEXP_* con patron no literal.
  CREATE TABLE bdm_tempo.stg_motor_crz_componentes
  DISTSTYLE KEY DISTKEY(id_buro_persona)
  AS
  SELECT DISTINCT
    f.id_buro_persona,
    f.cod_dw_ubic,
    f.texto_ubicacion,
    f.cod_dw_tipo_ubicacion_dir,
    f.cod_dw_municipio,
    dc.nomenclatura,
    COALESCE(nom.nivel_complemento, 99) AS nivel_complemento,
    COALESCE(CAST(NULLIF(REGEXP_REPLACE(COALESCE(dc.valor, ''), '[^0-9]', ''), '') AS BIGINT),
             999999) AS valor_num
  FROM bdm_tempo.stg_motor_crz_fusion f
  JOIN bdm_datos.diccionario_complementos dc
    ON dc.cod_dw_ubic     = f.cod_dw_ubic
   AND dc.id_buro_persona = f.id_buro_persona
   AND UPPER(f.complemento_fusion) LIKE '%' || dc.nomenclatura || '%'
  LEFT JOIN bdm_datos.nomenclatura nom
    ON nom.nomenclatura = COALESCE(NULLIF(dc.nomen, ''), dc.nomenclatura);

  -- (7) Tmp_Unificacion_E061_EB (linea 4525), segundo WITH RECURSIVE: el
  --     complemento final, reordenado por (nivel, valor) ASCENDENTE y sin
  --     repetir nomenclatura. Mismo reordenamiento que el sello 'A6'.
  CREATE TABLE bdm_tempo.stg_motor_crz_nueva_nomen
  DISTSTYLE KEY DISTKEY(id_buro_persona)
  AS
  SELECT
    c.id_buro_persona,
    c.cod_dw_ubic,
    c.texto_ubicacion,
    c.cod_dw_tipo_ubicacion_dir,
    c.cod_dw_municipio,
    LISTAGG(TRIM(c.nomenclatura), ' ')
      WITHIN GROUP (ORDER BY c.nivel_complemento, c.valor_num, c.nomenclatura) AS nuevo_complemento
  FROM bdm_tempo.stg_motor_crz_componentes c
  GROUP BY 1, 2, 3, 4, 5;

  -- (8) La CABEZA del grupo: el miembro de complemento mas largo, que es el que
  --     encabeza la cadena del legado (T1 de la recursion). De el se heredan
  --     los atributos de via, que no cambian: lo que cambia es el complemento.
  CREATE TABLE bdm_tempo.stg_motor_crz_cabeza
  DISTSTYLE KEY DISTKEY(id_buro_persona)
  AS
  SELECT z.*
  FROM (
    SELECT
      g.id_buro_persona,
      g.cod_dw_ubic,
      g.texto_ubicacion,
      g.cod_dw_tipo_ubicacion_dir,
      g.cod_dw_municipio,
      g.cod_dw_persona_ubic,
      g.cod_dw_direccion_fisica,
      ROW_NUMBER() OVER (PARTITION BY g.id_buro_persona, g.cod_dw_ubic,
                                      g.texto_ubicacion,
                                      g.cod_dw_tipo_ubicacion_dir,
                                      g.cod_dw_municipio
                             ORDER BY g.id_len DESC, g.cod_dw_persona_ubic) AS rn
    FROM bdm_tempo.stg_motor_crz_grupo g
  ) z
  WHERE z.rn = 1;

  -- (9) Tmp_Unificacion_E061_F (linea 4598), rama ROW_U = -99: una fila por
  --     direccion NUEVA.
  CREATE TABLE bdm_tempo.stg_motor_crz_insumo
  DISTSTYLE KEY DISTKEY(id_buro_persona)
  AS
  SELECT
    f.id_buro_persona,
    i.cod_pin_persona,
    f.cod_dw_ubic,
    f.cod_dw_tipo_ubicacion_dir,
    f.texto_ubicacion,
    f.cod_dw_municipio,
    i.lote,
    dfc.tipo_via_principal,
    dfc.via_principal,
    dfc.via_generadora,
    dfc.numero_puerta,
    f.hijos,
    -- Mismas claves deterministas que los otros dos sitios, con su propio
    -- discriminante '|MOTOR|A8|': tres sitios distintos no pueden colisionar.
    FNV_HASH(CAST(cab.cod_dw_persona_ubic AS VARCHAR) || '|MOTOR|A8|DF|'  || f.hijos) AS cod_dw_direccion_fisica,
    FNV_HASH(CAST(cab.cod_dw_persona_ubic AS VARCHAR) || '|MOTOR|A8|RPU|' || f.hijos) AS cod_dw_persona_ubic,
    nn.nuevo_complemento AS complemento_motor,
    CAST(1 AS INTEGER) AS generada_enriquecida
  FROM bdm_tempo.stg_motor_crz_fusion f
  JOIN bdm_tempo.stg_motor_crz_cabeza cab
    ON  cab.id_buro_persona           = f.id_buro_persona
    AND cab.cod_dw_ubic               = f.cod_dw_ubic
    AND cab.texto_ubicacion           = f.texto_ubicacion
    AND cab.cod_dw_tipo_ubicacion_dir = f.cod_dw_tipo_ubicacion_dir
    AND cab.cod_dw_municipio          = f.cod_dw_municipio
  JOIN bdm_tempo.stg_motor_crz_nueva_nomen nn
    ON  nn.id_buro_persona           = f.id_buro_persona
    AND nn.cod_dw_ubic               = f.cod_dw_ubic
    AND nn.texto_ubicacion           = f.texto_ubicacion
    AND nn.cod_dw_tipo_ubicacion_dir = f.cod_dw_tipo_ubicacion_dir
    AND nn.cod_dw_municipio          = f.cod_dw_municipio
  JOIN bdm_tempo.stg_regla2_insumo i
    ON i.cod_dw_persona_ubic = cab.cod_dw_persona_ubic
  JOIN bdm_tempo.v_xpm_direccion_fisica dfc
    ON dfc.cod_dw_direccion_fisica = cab.cod_dw_direccion_fisica;

  -- ----------------------------------------------------------------------
  -- (10) PERSISTENCIA DE LA DIRECCION GENERADA
  -- UPDATE + INSERT WHERE NOT EXISTS, el 'INSERT FOR MISSING UPDATE ROWS' de
  -- P0020_UNIFICACION_DIRECCION_130.TPT. El borrado del historico en FULL lo
  -- hace el orquestador ANTES de preparar el insumo.
  -- ----------------------------------------------------------------------
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
    FROM bdm_tempo.stg_motor_crz_insumo s
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
  FROM bdm_tempo.stg_motor_crz_insumo s
  WHERE NOT EXISTS ( SELECT 1 FROM bdm_datos.direccion_fisica_generada d
                      WHERE d.cod_dw_direccion_fisica = s.cod_dw_direccion_fisica );

  UPDATE bdm_datos.rpu_generada
     SET cod_dw_ubic               = s.cod_dw_ubic,
         cod_dw_direccion_fisica   = s.cod_dw_direccion_fisica,
         cod_dw_tipo_ubicacion_dir = s.cod_dw_tipo_ubicacion_dir,
         lote_actualizacion        = p_lote,
         usuario_bd                = CURRENT_USER,
         fecha_modificacion        = CURRENT_DATE
    FROM bdm_tempo.stg_motor_crz_insumo s
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
    -- 'N' en el staging del legado: la direccion generada nace SIN unificar.
    NULL,
    -- NULL como en la rama ROW_U = -99 del legado (linea 4604).
    NULL,
    p_lote, p_lote,
    NULL,
    CURRENT_USER, NULL, CURRENT_DATE
  FROM bdm_tempo.stg_motor_crz_insumo s
  WHERE NOT EXISTS ( SELECT 1 FROM bdm_datos.rpu_generada r
                      WHERE r.cod_dw_persona_ubic = s.cod_dw_persona_ubic );

  -- ----------------------------------------------------------------------
  -- (11) EL GRUPO COMPLETO SE UNIFICA CONTRA LA DIRECCION GENERADA
  -- Rama ROW_U = 0 de Tmp_Unificacion_E061_F (linea 4625): TODOS los miembros
  -- de E061_D quedan como hijos de la direccion nueva.
  -- ----------------------------------------------------------------------
  CREATE TABLE bdm_tempo.stg_motor_crz_miembros
  DISTSTYLE KEY DISTKEY(id_buro_persona)
  AS
  SELECT
    g.id_buro_persona,
    g.cod_dw_ubic,
    g.texto_ubicacion,
    g.cod_dw_tipo_ubicacion_dir,
    g.cod_dw_municipio,
    g.cod_dw_persona_ubic AS miembro
  FROM bdm_tempo.stg_motor_crz_grupo g;

  CREATE TABLE bdm_tempo.stg_motor_crz_persist
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
  FROM bdm_tempo.stg_motor_crz_miembros m
  JOIN bdm_tempo.stg_motor_crz_insumo s
    ON  s.id_buro_persona           = m.id_buro_persona
    AND s.cod_dw_ubic               = m.cod_dw_ubic
    AND s.texto_ubicacion           = m.texto_ubicacion
    AND s.cod_dw_tipo_ubicacion_dir = m.cod_dw_tipo_ubicacion_dir
    AND s.cod_dw_municipio          = m.cod_dw_municipio;

  IF p_modo = 'FULL' THEN
    -- El TRUNCATE lo hizo el orquestador al inicio de la corrida. Se usa
    -- INSERT FOR MISSING y no un INSERT plano porque dentro de una misma
    -- corrida FULL dos etapas distintas pueden producir la MISMA
    -- Clave_Unificacion, y el INSERT plano dejaria la pareja duplicada.
    INSERT INTO bdm_datos.unificacion_direccion
      (cod_dw_persona_ubic, cod_dw_direccion_unificada, unifica_atributos, fecha_unificacion, lote, severidad, usuario_bd)
    SELECT DISTINCT s.cod_dw_persona_ubic, s.cod_dw_direccion_unificada, s.unifica_atributos,
           s.fecha_unificacion, s.lote, s.severidad, s.usuario_bd
    FROM bdm_tempo.stg_motor_crz_persist s
    WHERE NOT EXISTS (
      SELECT 1 FROM bdm_datos.unificacion_direccion u
       WHERE u.cod_dw_persona_ubic = s.cod_dw_persona_ubic
         AND u.cod_dw_direccion_unificada = s.cod_dw_direccion_unificada);
  ELSE
    -- DELTA UPSERT. El UPDATE no reescribe 'lote' ni 'unifica_atributos': el
    -- Lote identifica la corrida que CREO la unificacion y es inmutable.
    -- En UPDATE ... FROM la tabla destino no admite alias en Redshift.
    UPDATE bdm_datos.unificacion_direccion
       SET lote_actualizacion = p_lote,
           fecha_modificacion = CURRENT_DATE,
           usuario_bd         = CURRENT_USER
      FROM bdm_tempo.stg_motor_crz_persist s
     WHERE bdm_datos.unificacion_direccion.cod_dw_persona_ubic = s.cod_dw_persona_ubic
       AND bdm_datos.unificacion_direccion.cod_dw_direccion_unificada = s.cod_dw_direccion_unificada;

    INSERT INTO bdm_datos.unificacion_direccion
      (cod_dw_persona_ubic, cod_dw_direccion_unificada, unifica_atributos, fecha_unificacion, lote, severidad, usuario_bd)
    SELECT DISTINCT s.cod_dw_persona_ubic, s.cod_dw_direccion_unificada, s.unifica_atributos,
           s.fecha_unificacion, s.lote, s.severidad, s.usuario_bd
    FROM bdm_tempo.stg_motor_crz_persist s
    WHERE NOT EXISTS (
      SELECT 1 FROM bdm_datos.unificacion_direccion u
       WHERE u.cod_dw_persona_ubic = s.cod_dw_persona_ubic
         AND u.cod_dw_direccion_unificada = s.cod_dw_direccion_unificada);
  END IF;

  -- ----------------------------------------------------------------------
  -- (12) MARCADO. El MERGE de vuelta a Tmp_Unificacion_E2 (linea 4659), con el
  -- sello 'A8' que fija la linea 4672, para que las etapas POSTERIORES -- esc5
  -- y esc6 -- no vuelvan a ver este grupo.
  -- ----------------------------------------------------------------------
  UPDATE bdm_tempo.stg_regla2_e2
  SET id_padre        = stg.cod_dw_direccion_unificada,
      ind_unificacion = 'S',
      n_id            = 'A8'
  FROM bdm_tempo.stg_motor_crz_persist stg
  WHERE bdm_tempo.stg_regla2_e2.cod_dw_persona_ubic = stg.cod_dw_persona_ubic
    AND bdm_tempo.stg_regla2_e2.id_padre IS NULL;

END;
$$;
