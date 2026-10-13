-- R2 Motor NIVEL (sitio 2, etapa 5.1 del legado) -- creacion de direcciones nuevas
-- Escenario 5 subcaso 1: dos complementos comparten una nomenclatura y difieren
--   en la otra, las dos que difieren estan a DISTINTO NIVEL y los valores que
--   las acompanan son DIFERENTES. Se crea una direccion nueva que combina ambas
--   y las dos originales quedan como hijas. Marca 'A6'.
-- Fuente: edf_views -> bdm_tempo.v_xpm_* | Salida: bdm_datos.direccion_fisica_generada + bdm_datos.rpu_generada + bdm_datos.unificacion_direccion
-- Prerequisito: sp_unificacion_r2_esc4_diccionario_frecuencia_complemento
--               sp_unificacion_r2_construir_diccionario_complementos
--
-- PARIDAD CON TERADATA (PRO_UnificacionR2.sql lineas 2250-3607)
--
-- Es el SEGUNDO de los dos unicos sitios que crean direcciones -- los unicos
-- que consultan el secuenciador REC_MTDAT.MAX_ID:
--
--   linea 1602  cadena Tmp_Unificacion_E03*   etapa (3)    marca 'X4'
--   linea 3423  cadena Tmp_Unificacion_E051*  etapa (5.1)  marca 'A6'   <- este
--
-- El sitio 1 ya estaba portado (sp_unificacion_r2_motor_nit_empates_nuevas_
-- direcciones). Este archivo cierra el sitio 2, que era la unica brecha
-- declarada del criterio R2-06.
--
-- QUE DISTINGUE AL SUBCASO 1 DEL SUBCASO 2. Es UN SOLO predicado, y el legado
-- lo dice en prosa en las dos cabeceras:
--
--   sub 1 (linea 2253, este SP): "Si los valores que acompanan las
--     nomenclaturas que difieren en el complemento son DIFERENTES, se realiza
--     la unificacion buscando armar un solo registro mas completo que contenga
--     ambas nomenclaturas y sus valores, creando para esto un nuevo
--     complemento en la tabla DIRECCION_FISICA ... y las dos direcciones
--     evaluadas deben ser unidas a esta ultima."
--   sub 2 (linea 3616, ya portado como esc5 'C7'): "Si los valores ... son
--     IGUALES, se debe consultar el Directorio ... y verificar cual de los
--     valores tiene mayor frecuencia."
--
-- En SQL (Tmp_Unificacion_E051_C linea 2385 contra Tmp_Unificacion_E05_C
-- linea 3742) la unica diferencia es el signo del LIKE sobre COMPLEMENTO2:
--
--   sub 1   A.Complemento2 NOT LIKE '%'||B.Complemento2||'%'
--        OR B.Complemento2 NOT LIKE '%'||A.Complemento2||'%'
--   sub 2   A.Complemento2     LIKE '%'||B.Complemento2||'%'
--        OR B.Complemento2     LIKE '%'||A.Complemento2||'%'
--
-- COMPLEMENTO2 (linea 2335) es el complemento SIN sus dos nomenclaturas, o sea
-- exactamente "los valores que acompanan":
--   TRIM( OREPLACE( OREPLACE(COMPLEMENTO, NMC1.NOMENCLATURA,''), NMC2.NOMENCLATURA,'') )
--
-- LA FORMA DEL PAR (Tmp_Unificacion_E051_A, linea 2330). Cada complemento se
-- descompone en DOS nomenclaturas del catalogo:
--   NMC1  la que ENCABEZA     COMPLEMENTO LIKE  'NOM %'
--   NMC2  la que va EN MEDIO  COMPLEMENTO LIKE '% NOM %'
-- y el par exige una igual, la otra distinta, y la que difiere a distinto
-- nivel. Son las dos ramas del UNION ALL de E051_C:
--   rama 1  NMC1 igual, NMC2 distinta, NIVEL de NMC2 distinto
--   rama 2  NMC1 distinta, NMC2 igual, NIVEL de NMC1 distinto
--
-- Un complemento de UNA sola nomenclatura no tiene NMC2 y por tanto no tiene
-- COMPLEMENTO2: en Teradata el OREPLACE con el patron nulo propaga NULL, el
-- predicado de valores se evalua a NULL y la fila no entra. Aqui el JOIN al
-- catalogo es INNER por las dos nomenclaturas, con el mismo efecto y sin
-- depender de la semantica de NULL de OREPLACE. Es tambien lo que deja intacto
-- al arquetipo de esc5 ('BR 5' / 'AP 301', una nomenclatura cada uno): este SP
-- corre ANTES que esc5 y, si lo capturara, moveria un resultado ya certificado.
--
-- QUIEN ES EL PADRE: MDIR, igual que en el sitio 1. Tmp_Unificacion_E051_P
-- (linea 3157) es
--   ROW_NUMBER() OVER (PARTITION BY COD_DW_UBIC, ID_BURO_PERSONA,
--                                   Cod_DW_Tipo_Ubicacion_Dir
--                      ORDER BY MDIR, ORDEN) = 1
-- y las hijas son el resto (Tmp_Unificacion_E051_H, linea 3193: NOT EXISTS en
-- P). MDIR sale del pivote dinamico de Tmp_Unificacion_E051_Dx (lineas
-- 2692-2740), que genera esta sentencia:
--   ROW_NUMBER() OVER (PARTITION BY cod_dw_ubic
--                      ORDER BY ID_COM11, ID_COM12, ..., val1, val2, ...)
--     ID_COM1<n> = COALESCE(MAX(CASE WHEN ID_COM1 = n THEN nivel_complemento END),    99)
--     val<n>     = COALESCE(MAX(CASE WHEN ID_COM1 = n THEN valor             END), 99999)
-- con ID_COM1 = SUM(1) OVER (PARTITION BY Cod_DW_Persona_Ubic
--                            ORDER BY NOM.Nivel_Complemento ROWS UNBOUNDED PRECEDING),
-- o sea ASCENDENTE por nivel. Es el MISMO MDIR del sitio 1 (alli el generador
-- vive en Tmp_Unificacion_E03_Bx, lineas 905-940) y se materializa igual: una
-- clave de ancho fijo, 2 digitos por nivel y 6 por valor, rellenando los slots
-- ausentes con '9'. Asi la comparacion lexicografica reproduce la tupla del
-- legado. Los dos terminos NO se entrelazan: el legado ordena por TODOS los
-- niveles y solo despues por TODOS los valores.
--
-- MDIR = 1 es la direccion con MAS componentes y de nivel MAS BAJO: la mas
-- RICA. El relleno con 99 manda al final a las que tienen pocos componentes.
--
-- EL COMPLEMENTO NUEVO. El legado lo arma en Tmp_Unificacion_E051_E (linea
-- 3426) como COMPLEMENTO_PADRE || NUEVA_NOMENCLATURA, y NUEVA_NOMENCLATURA la
-- fija un cursor (linea 3395) que ejecuta
--     SET NUEVA_NOMENCLATURA = TRIM(N<k>)
-- donde k = POSITION('0' IN CODIGO) - 1, con minimo 1, y CODIGO es la cadena de
-- '1'/'0' que compara, posicion a posicion, los componentes del padre con los
-- del hijo (linea 3290). O sea: k = largo del prefijo comun, y N<k> es la COLA
-- del hijo desde ahi (Tmp_Unificacion_E051_D01, linea 3063).
--
-- DIVERGENCIA DELIBERADA, Y POR QUE. El primer digito de CODIGO compara
-- NOM_AGRUP -- la lista de nomenclaturas de cada direccion -- y en este
-- escenario las dos difieren SIEMPRE (es su definicion), de modo que CODIGO
-- empieza por '0', k sale 0, se satura a 1, y N1 no es una cola: es el
-- COMPLEMENTO ENTERO del hijo (linea 3074, 'MAX(CASE WHEN ORDEN=1 THEN
-- COMPLEMENTO END) AS N1'). El resultado literal del legado seria pegar el
-- complemento completo del hijo detras del del padre, repitiendo la
-- nomenclatura que los dos comparten -- que es justo lo que el criterio R2-12
-- prohibe ("sin duplicidad, con completitud y con orden logico"). Se porta la
-- SEMANTICA que el nombre declara y que R2-12 exige, la misma del sitio 1: el
-- hijo aporta los componentes que el padre NO tiene todavia. Queda anotada
-- como divergencia para GOB-03.
--
-- Si los hijos no aportan NINGUN componente nuevo no se crea direccion y el
-- grupo sigue su camino hasta esc5.
CREATE OR REPLACE PROCEDURE bdm_datos.sp_unificacion_r2_motor_nivel_nueva_direccion(
    p_modo VARCHAR,   -- FULL | DELTA (modo efectivo de la corrida)
    p_lote INTEGER    -- Lote_Corrida externo
)
NONATOMIC
LANGUAGE plpgsql
AS $$
BEGIN
  DROP TABLE IF EXISTS bdm_tempo.stg_motor_niv_base;
  DROP TABLE IF EXISTS bdm_tempo.stg_motor_niv_cand;
  DROP TABLE IF EXISTS bdm_tempo.stg_motor_niv_mdir;
  DROP TABLE IF EXISTS bdm_tempo.stg_motor_niv_grupo;
  DROP TABLE IF EXISTS bdm_tempo.stg_motor_niv_pares;
  DROP TABLE IF EXISTS bdm_tempo.stg_motor_niv_componentes;
  DROP TABLE IF EXISTS bdm_tempo.stg_motor_niv_nueva_nomen;
  DROP TABLE IF EXISTS bdm_tempo.stg_motor_niv_fusion;
  DROP TABLE IF EXISTS bdm_tempo.stg_motor_niv_insumo;
  DROP TABLE IF EXISTS bdm_tempo.stg_motor_niv_miembros;
  DROP TABLE IF EXISTS bdm_tempo.stg_motor_niv_persist;

  -- (1) Tmp_Unificacion_E051 + Tmp_Unificacion_E051_A (lineas 2280 y 2330).
  --     Poblacion: lo que ningun escenario anterior consumio, descompuesto en
  --     su nomenclatura inicial y su nomenclatura intermedia. SIN filtro de
  --     NIT: el legado no lo pone en esta etapa.
  --
  --     Un complemento con TRES o mas nomenclaturas casa con varias NMC2 y
  --     produce varias filas. El legado tampoco deduplica aqui -- lo hace mas
  --     tarde, con QUALIFY ROW_NUMBER() ... = 1 por Cod_DW_Persona_Ubic (linea
  --     2420) -- asi que la multiplicidad se conserva y se reduce igual, en
  --     (2). El orden del desempate se fija a proposito para que la eleccion
  --     sea estable entre corridas: CA-C02..CA-C04 comparan por checksum.
  CREATE TABLE bdm_tempo.stg_motor_niv_base
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
    nmc1.nomenclatura      AS nomen_pri,
    nmc1.nivel_complemento AS nivel_pri,
    nmc2.nomenclatura      AS nomen_sec,
    nmc2.nivel_complemento AS nivel_sec,
    -- COMPLEMENTO2 (linea 2335): el complemento sin sus dos nomenclaturas.
    TRIM(REPLACE(REPLACE(UPPER(COALESCE(e.complemento, '')),
                         TRIM(nmc1.nomenclatura), ''),
                 TRIM(nmc2.nomenclatura), '')) AS valores,
    -- ORDEN del legado (linea 2550), que aqui solo DESEMPATA a MDIR:
    --   (COALESCE(Conteo,0) + 10000000) + CAST(fecha AS INTEGER)
    -- CAST(date AS INTEGER) en Teradata da (anio-1900)*10000 + mes*100 + dia.
    ( (DATE_PART(year,  COALESCE(e.fecha_relacion_persona_ubicaci, DATE '1900-01-01')) - 1900) * 10000
    +  DATE_PART(month, COALESCE(e.fecha_relacion_persona_ubicaci, DATE '1900-01-01')) * 100
    +  DATE_PART(day,   COALESCE(e.fecha_relacion_persona_ubicaci, DATE '1900-01-01'))
    +  COALESCE(e.numero_entidades_reportan, 0) + 10000000 ) AS id_orden
  FROM bdm_tempo.stg_regla2_e2 e
  JOIN bdm_datos.nomenclatura nmc1
    ON UPPER(COALESCE(e.complemento, '')) LIKE TRIM(nmc1.nomenclatura) || ' %'
  JOIN bdm_datos.nomenclatura nmc2
    ON UPPER(COALESCE(e.complemento, '')) LIKE '% ' || TRIM(nmc2.nomenclatura) || ' %'
  WHERE e.ind_unificacion = 'N';

  -- (2) Tmp_Unificacion_E051_C (linea 2385): las que tienen con quien
  --     emparejarse bajo el predicado del subcaso 1. El padre todavia NO esta
  --     elegido -- en el legado tampoco: la eleccion llega en E051_P.
  CREATE TABLE bdm_tempo.stg_motor_niv_cand
  DISTSTYLE KEY DISTKEY(id_buro_persona)
  AS
  SELECT z.cod_dw_persona_ubic, z.id_buro_persona, z.cod_dw_ubic,
         z.texto_ubicacion, z.cod_dw_tipo_ubicacion_dir, z.cod_dw_municipio,
         z.complemento, z.nomen_pri, z.nivel_pri, z.nomen_sec, z.nivel_sec,
         z.valores, z.id_orden
  FROM (
    SELECT a.*,
           ROW_NUMBER() OVER (PARTITION BY a.cod_dw_persona_ubic
                                  ORDER BY a.nomen_pri, a.nomen_sec) AS rn
    FROM bdm_tempo.stg_motor_niv_base a
    WHERE EXISTS (
      SELECT 1
        FROM bdm_tempo.stg_motor_niv_base b
       WHERE b.id_buro_persona           = a.id_buro_persona
         AND b.texto_ubicacion           = a.texto_ubicacion
         AND b.cod_dw_tipo_ubicacion_dir = a.cod_dw_tipo_ubicacion_dir
         AND b.cod_dw_municipio          = a.cod_dw_municipio
         AND b.cod_dw_persona_ubic      <> a.cod_dw_persona_ubic
         AND b.complemento              <> a.complemento
         -- subcaso 1: los valores que acompanan son DIFERENTES
         AND (     a.valores NOT LIKE '%' || b.valores || '%'
               OR  b.valores NOT LIKE '%' || a.valores || '%' )
         -- las dos ramas del UNION ALL de E051_C
         AND ( (    a.nomen_pri  = b.nomen_pri
                AND a.nomen_sec <> b.nomen_sec
                AND a.nivel_sec <> b.nivel_sec )
            OR (    a.nomen_pri <> b.nomen_pri
                AND a.nomen_sec  = b.nomen_sec
                AND a.nivel_pri <> b.nivel_pri ) ) )
  ) z
  WHERE z.rn = 1;

  -- (3) Tmp_Unificacion_E051_D1 (linea 2596): descomposicion en componentes.
  --     Es el insumo de MDIR, asi que va ANTES de elegir al padre.
  CREATE TABLE bdm_tempo.stg_motor_niv_componentes
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
  FROM bdm_tempo.stg_motor_niv_cand e
  JOIN bdm_datos.diccionario_complementos dc
    ON dc.id_buro_persona = e.id_buro_persona
   AND dc.cod_dw_ubic = e.cod_dw_ubic
   AND UPPER(COALESCE(e.complemento, '')) LIKE '%' || dc.nomenclatura || '%'
  LEFT JOIN bdm_datos.nomenclatura cat
    ON cat.nomenclatura = dc.nomen;

  -- (4) Tmp_Unificacion_E051_Dx (linea 2692): MDIR, como clave comparable.
  -- Un LISTAGG por subconsulta a proposito: Redshift no admite LISTAGG junto a
  -- otra funcion de agregacion con DISTINCT en la misma proyeccion.
  CREATE TABLE bdm_tempo.stg_motor_niv_mdir
  DISTSTYLE KEY DISTKEY(cod_dw_persona_ubic)
  AS
  SELECT n.cod_dw_persona_ubic, n.niv_key, v.val_key
  FROM (
    SELECT c.cod_dw_persona_ubic,
           RPAD( LISTAGG(LPAD(CAST(LEAST(c.nivel_complemento, 99) AS VARCHAR), 2, '0'), '')
                   WITHIN GROUP (ORDER BY c.nivel_complemento, c.nomen),
                 30, '9') AS niv_key
    FROM bdm_tempo.stg_motor_niv_componentes c
    GROUP BY 1
  ) n
  JOIN (
    SELECT c.cod_dw_persona_ubic,
           RPAD( LISTAGG(LPAD(CAST(LEAST(COALESCE(CAST(NULLIF(REGEXP_REPLACE(COALESCE(c.valor, ''),
                                                                            '[^0-9]', ''), '') AS BIGINT),
                                                  999999), 999999) AS VARCHAR), 6, '0'), '')
                   WITHIN GROUP (ORDER BY c.nivel_complemento, c.nomen),
                 90, '9') AS val_key
    FROM bdm_tempo.stg_motor_niv_componentes c
    GROUP BY 1
  ) v
    ON v.cod_dw_persona_ubic = n.cod_dw_persona_ubic;

  -- (5) Tmp_Unificacion_E051_P / E051_H (lineas 3157 y 3193). La particion es
  --     la del legado: (cod_dw_ubic, id_buro_persona, tipo de ubicacion). Una
  --     direccion sin entrada en el diccionario no tiene MDIR -- la clave
  --     todo-9 la manda al final, con el mismo efecto que en el legado, donde
  --     no llega a E051_D1 y no puede ser padre.
  CREATE TABLE bdm_tempo.stg_motor_niv_grupo
  DISTSTYLE KEY DISTKEY(id_buro_persona)
  AS
  SELECT
    a.*,
    ROW_NUMBER() OVER (
      PARTITION BY a.cod_dw_ubic, a.id_buro_persona, a.cod_dw_tipo_ubicacion_dir
      ORDER BY COALESCE(m.niv_key, REPEAT('9', 30)),
               COALESCE(m.val_key, REPEAT('9', 90)),
               a.id_orden, a.cod_dw_persona_ubic
    ) AS orden
  FROM bdm_tempo.stg_motor_niv_cand a
  LEFT JOIN bdm_tempo.stg_motor_niv_mdir m
    ON m.cod_dw_persona_ubic = a.cod_dw_persona_ubic;

  -- Tmp_Unificacion_E051_codigo (linea 3262): P LEFT JOIN H por
  -- (cod_dw_ubic, id_buro_persona, tipo de ubicacion).
  CREATE TABLE bdm_tempo.stg_motor_niv_pares
  DISTSTYLE KEY DISTKEY(id_buro_persona)
  AS
  SELECT
    h.cod_dw_persona_ubic AS ubic_hijo,
    p.cod_dw_persona_ubic AS ubic_padre,
    h.id_buro_persona,
    h.cod_dw_ubic
  FROM bdm_tempo.stg_motor_niv_grupo h
  JOIN bdm_tempo.stg_motor_niv_grupo p
    ON p.cod_dw_ubic               = h.cod_dw_ubic
   AND p.id_buro_persona           = h.id_buro_persona
   AND p.cod_dw_tipo_ubicacion_dir = h.cod_dw_tipo_ubicacion_dir
   AND p.orden = 1
  WHERE h.orden > 1;

  -- (6) NUEVA_NOMENCLATURA: lo que aporta cada hijo y el padre no tiene.
  CREATE TABLE bdm_tempo.stg_motor_niv_nueva_nomen
  DISTSTYLE KEY DISTKEY(id_buro_persona)
  AS
  SELECT
    p.ubic_padre,
    p.ubic_hijo,
    p.id_buro_persona,
    ch.nomen,
    ch.nivel_complemento,
    ch.valor
  FROM bdm_tempo.stg_motor_niv_pares p
  JOIN bdm_tempo.stg_motor_niv_componentes ch
    ON ch.cod_dw_persona_ubic = p.ubic_hijo
  WHERE NOT EXISTS ( SELECT 1
                       FROM bdm_tempo.stg_motor_niv_componentes cp
                      WHERE cp.cod_dw_persona_ubic = p.ubic_padre
                        AND cp.nomen = ch.nomen );

  -- (7) Un componente por 'nomen' y por padre. Cuando varios hijos aportan el
  --     mismo token se conserva el del hijo de menor cod_dw_persona_ubic.
  CREATE TABLE bdm_tempo.stg_motor_niv_fusion
  DISTSTYLE KEY DISTKEY(id_buro_persona)
  AS
  SELECT z.ubic_padre, z.id_buro_persona, z.nomen, z.nivel_complemento, z.valor
  FROM (
    SELECT
      nn.*,
      ROW_NUMBER() OVER (PARTITION BY nn.ubic_padre, nn.nomen
                             ORDER BY nn.ubic_hijo) AS pick
    FROM bdm_tempo.stg_motor_niv_nueva_nomen nn
  ) z
  WHERE z.pick = 1;

  -- (8) Tmp_Unificacion_E051_E (linea 3426): una fila por PADRE.
  CREATE TABLE bdm_tempo.stg_motor_niv_insumo
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
    -- concatenacion literal desborda BIGINT, asi que se usa FNV_HASH sobre la
    -- MISMA cadena. El discriminante '|MOTOR|A6|' la separa del sitio 1: dos
    -- sitios distintos nunca pueden colisionar en el mismo identificador.
    FNV_HASH(CAST(pad.cod_dw_persona_ubic AS VARCHAR) || '|MOTOR|A6|DF|'  || hij.hijos) AS cod_dw_direccion_fisica,
    FNV_HASH(CAST(pad.cod_dw_persona_ubic AS VARCHAR) || '|MOTOR|A6|RPU|' || hij.hijos) AS cod_dw_persona_ubic,
    -- COMPLEMENTO_PADRE || NUEVA_NOMENCLATURA
    TRIM(COALESCE(pad.complemento, '') || ' ' || nue.nueva_nomenclatura) AS complemento_motor,
    hij.hijos,
    CAST(1 AS INTEGER) AS generada_enriquecida
  FROM bdm_tempo.stg_regla2_e2 pad
  JOIN (
    -- ORDEN (linea 2884): nivel ASC, con el valor numerico como desempate
    -- igual que el TO_NUMBER(DC.VALOR) del legado -- hay niveles compartidos
    -- (BL/ED=2, MZ/LC=3, TO/CA=4, CS/LT=5) y en orden lexical '10' iria antes
    -- que '9'.
    SELECT
      ubic_padre,
      LISTAGG(TRIM(nomen || ' ' || COALESCE(valor, '')), ' ')
        WITHIN GROUP (ORDER BY nivel_complemento,
                               CAST(NULLIF(REGEXP_REPLACE(COALESCE(valor, ''),
                                                          '[^0-9]', ''), '') AS BIGINT),
                               nomen) AS nueva_nomenclatura
    FROM bdm_tempo.stg_motor_niv_fusion
    GROUP BY 1
  ) nue
    ON nue.ubic_padre = pad.cod_dw_persona_ubic
  JOIN (
    -- XMLAGG(COD_DW_PERSONA_UBIC_HIJO) sobre E051_codigo, que tiene una fila
    -- por par: la lista sale de TODOS los hijos del padre, no solo de los que
    -- aportaron componentes.
    SELECT ubic_padre,
           LISTAGG(CAST(ubic_hijo AS VARCHAR), ',')
             WITHIN GROUP (ORDER BY ubic_hijo) AS hijos
    FROM bdm_tempo.stg_motor_niv_pares
    GROUP BY 1
  ) hij
    ON hij.ubic_padre = pad.cod_dw_persona_ubic
  JOIN bdm_tempo.stg_regla2_insumo i
    ON i.cod_dw_persona_ubic = pad.cod_dw_persona_ubic
  JOIN bdm_tempo.v_xpm_direccion_fisica dfp
    ON dfp.cod_dw_direccion_fisica = pad.cod_dw_direccion_fisica;

  -- ----------------------------------------------------------------------
  -- (9) PERSISTENCIA DE LA DIRECCION GENERADA
  -- UPDATE + INSERT WHERE NOT EXISTS, el 'INSERT FOR MISSING UPDATE ROWS' de
  -- P0020_UNIFICACION_DIRECCION_130.TPT. El borrado del historico en FULL lo
  -- hace el orquestador (paso 6) ANTES de preparar el insumo.
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
    FROM bdm_tempo.stg_motor_niv_insumo s
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
  FROM bdm_tempo.stg_motor_niv_insumo s
  WHERE NOT EXISTS ( SELECT 1 FROM bdm_datos.direccion_fisica_generada d
                      WHERE d.cod_dw_direccion_fisica = s.cod_dw_direccion_fisica );

  UPDATE bdm_datos.rpu_generada
     SET cod_dw_ubic               = s.cod_dw_ubic,
         cod_dw_direccion_fisica   = s.cod_dw_direccion_fisica,
         cod_dw_tipo_ubicacion_dir = s.cod_dw_tipo_ubicacion_dir,
         lote_actualizacion        = p_lote,
         usuario_bd                = CURRENT_USER,
         fecha_modificacion        = CURRENT_DATE
    FROM bdm_tempo.stg_motor_niv_insumo s
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
    -- NULL como en las lineas 3494-3500 del legado.
    NULL,
    p_lote, p_lote,
    NULL,
    CURRENT_USER, NULL, CURRENT_DATE
  FROM bdm_tempo.stg_motor_niv_insumo s
  WHERE NOT EXISTS ( SELECT 1 FROM bdm_datos.rpu_generada r
                      WHERE r.cod_dw_persona_ubic = s.cod_dw_persona_ubic );

  -- ----------------------------------------------------------------------
  -- (10) EL GRUPO COMPLETO SE UNIFICA CONTRA LA DIRECCION GENERADA
  -- Rama ROW_U = 0 / N_ID = 'A6' de Tmp_Unificacion_E051_F (linea 3494).
  -- Incluye al PADRE: "las dos direcciones evaluadas deben ser unidas a esta
  -- ultima" (linea 2256).
  -- ----------------------------------------------------------------------
  CREATE TABLE bdm_tempo.stg_motor_niv_miembros
  DISTSTYLE KEY DISTKEY(ubic_padre)
  AS
  SELECT ubic_padre, ubic_padre AS miembro FROM bdm_tempo.stg_motor_niv_pares
  UNION
  SELECT ubic_padre, ubic_hijo  AS miembro FROM bdm_tempo.stg_motor_niv_pares;

  CREATE TABLE bdm_tempo.stg_motor_niv_persist
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
  FROM bdm_tempo.stg_motor_niv_miembros m
  JOIN bdm_tempo.stg_motor_niv_insumo s
    ON s.ubic_padre = m.ubic_padre;

  IF p_modo = 'FULL' THEN
    -- El TRUNCATE lo hizo el orquestador al inicio de la corrida. Se usa
    -- INSERT FOR MISSING y no un INSERT plano porque dentro de una misma
    -- corrida FULL dos etapas distintas pueden producir la MISMA
    -- Clave_Unificacion, y el INSERT plano dejaria la pareja duplicada.
    INSERT INTO bdm_datos.unificacion_direccion
      (cod_dw_persona_ubic, cod_dw_direccion_unificada, unifica_atributos, fecha_unificacion, lote, severidad, usuario_bd)
    SELECT DISTINCT s.cod_dw_persona_ubic, s.cod_dw_direccion_unificada, s.unifica_atributos,
           s.fecha_unificacion, s.lote, s.severidad, s.usuario_bd
    FROM bdm_tempo.stg_motor_niv_persist s
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
      FROM bdm_tempo.stg_motor_niv_persist s
     WHERE bdm_datos.unificacion_direccion.cod_dw_persona_ubic = s.cod_dw_persona_ubic
       AND bdm_datos.unificacion_direccion.cod_dw_direccion_unificada = s.cod_dw_direccion_unificada;

    INSERT INTO bdm_datos.unificacion_direccion
      (cod_dw_persona_ubic, cod_dw_direccion_unificada, unifica_atributos, fecha_unificacion, lote, severidad, usuario_bd)
    SELECT DISTINCT s.cod_dw_persona_ubic, s.cod_dw_direccion_unificada, s.unifica_atributos,
           s.fecha_unificacion, s.lote, s.severidad, s.usuario_bd
    FROM bdm_tempo.stg_motor_niv_persist s
    WHERE NOT EXISTS (
      SELECT 1 FROM bdm_datos.unificacion_direccion u
       WHERE u.cod_dw_persona_ubic = s.cod_dw_persona_ubic
         AND u.cod_dw_direccion_unificada = s.cod_dw_direccion_unificada);
  END IF;

  -- ----------------------------------------------------------------------
  -- (11) MARCADO. El merge de vuelta a Tmp_Unificacion_E2 (linea 3551), para
  -- que las etapas POSTERIORES -- esc5 y esc6 -- no vuelvan a ver este grupo.
  -- ----------------------------------------------------------------------
  UPDATE bdm_tempo.stg_regla2_e2
  SET id_padre        = stg.cod_dw_direccion_unificada,
      ind_unificacion = 'S',
      n_id            = 'A6'
  FROM bdm_tempo.stg_motor_niv_persist stg
  WHERE bdm_tempo.stg_regla2_e2.cod_dw_persona_ubic = stg.cod_dw_persona_ubic
    AND bdm_tempo.stg_regla2_e2.id_padre IS NULL;

END;
$$;
