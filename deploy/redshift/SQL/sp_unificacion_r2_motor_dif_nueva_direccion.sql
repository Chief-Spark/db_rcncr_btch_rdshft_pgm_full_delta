-- R2 Motor DIF (escenario 6 subcaso 2 del legado) -- creacion de direcciones nuevas
-- Escenario 6 subcaso 2: dos complementos cuyas nomenclaturas NO coinciden en
--   ninguna combinacion y cuyos NIVELES difieren. Se arma una direccion nueva
--   que fusiona los dos complementos y los dos originales quedan como hijos.
--   Marca 'D9'.
-- Fuente: edf_views -> bdm_tempo.v_xpm_* | Salida: bdm_datos.direccion_fisica_generada + bdm_datos.rpu_generada + bdm_datos.unificacion_direccion
-- Prerequisito: sp_unificacion_r2_motor_nivel_nueva_direccion (sello 'A6')
--               sp_unificacion_r2_construir_diccionario_complementos
--
-- PARIDAD CON TERADATA (PRO_UnificacionR2.sql lineas 4715-5448)
--
-- Es el CUARTO y ULTIMO sitio que crea direcciones, y el que cierra R2-07:
--
--   linea 1602  cadena Tmp_Unificacion_E03*   etapa (3)    marca 'X4'
--   linea 3423  cadena Tmp_Unificacion_E051*  etapa (5.1)  marca 'A6'
--   linea 4016  cadena Tmp_Unificacion_E061*  etapa (6.1)  marca 'A8'
--   linea 4715  cadena Tmp_Unificacion_E062*  etapa (6.2)  marca 'D9'   <- este
--
-- El sello 'D9' no es una invencion: lo fija el MERGE de cierre del legado
-- (linea 5415, "N_ID = ''D9''").
--
-- QUE DISTINGUE A ESTE SUBCASO. El espacio del par esta repartido entre cinco
-- casos disjuntos, y lo que los separa es COMO se relacionan las dos
-- nomenclaturas de cada complemento (NMC1 la que encabeza, NMC2 la de en
-- medio):
--
--   A6  esc5 sub1  una coincide EN LA MISMA POSICION, la otra difiere y esta
--                  a distinto nivel; los valores son DIFERENTES
--   C7  esc5 sub2  igual, pero los valores son IGUALES -> decide el diccionario
--   A8  esc6 sub1  una coincide EN POSICION CRUZADA y las colas se CONTIENEN
--   D9  esc6 sub2  NINGUNA coincide en ninguna combinacion y los niveles
--                  difieren                                             <- este
--   F1  esc6 sub3  los niveles son IGUALES -> decide el diccionario
--
-- POR QUE ESTE SP VA ANTES DE esc5 Y NO DESPUES (divergencia deliberada,
-- anotada para GOB-03).
-- En el legado esta etapa corre DESPUES de esc5, y puede permitirselo porque el
-- esc5 del legado es ESTRECHO: Tmp_Unificacion_E05_C (linea 3844) exige que una
-- nomenclatura coincida EN LA MISMA POSICION y que las colas SE CONTENGAN,
--     AND ( A.Complemento2 LIKE '%'||B.Complemento2||'%'
--        OR B.Complemento2 LIKE '%'||A.Complemento2||'%' )
--     AND ( A.NOMENCLATURA <> B.NOMENCLATURA
--           AND NVL(A.NOMENCLATURA1,'A') = NVL(B.NOMENCLATURA1,'A') )
-- de modo que deja pasar intactos justo los pares que esta etapa recoge.
-- Nuestro sp_unificacion_r2_esc5_nomenclatura_menor_nivel_pierde es MAS ANCHO:
-- le basta con que las dos nomenclaturas iniciales existan, difieran y esten a
-- distinto nivel. Todo par de 'D9' cumple eso, asi que colocado despues este SP
-- correria siempre contra cero filas.
-- Se porta el REPARTO del legado y no el orden de sus lineas: la etapa entra
-- entre el sitio 2 ('A6') y esc5. El orden respecto de 'A8' (6.1) no importa:
-- los dos subcasos son disjuntos por construccion -- el cruzado cumple
-- A.NOMENCLATURA = B.NOMENCLATURA1, que es exactamente lo que la tercera
-- condicion de abajo excluye.
--
-- EL PREDICADO, Tmp_Unificacion_E062_C (linea 4844):
--   ( A.Complemento2 NOT LIKE '%'||B.Complemento2||'%'
--     OR B.Complemento2 NOT LIKE '%'||A.Complemento2||'%' )
--   AND COALESCE(A.NOMENCLATURA ,'A') <> COALESCE(B.NOMENCLATURA ,'B')
--   AND COALESCE(A.NOMENCLATURA1,'A') <> COALESCE(B.NOMENCLATURA1,'B')
--   AND COALESCE(A.NOMENCLATURA ,'A') <> COALESCE(B.NOMENCLATURA1,'B')
--   AND A.NIVEL_COMPLEMENTO <> B.NIVEL_COMPLEMENTO
--   AND COALESCE(A.NIVEL_COMPLEMENTO,'A') <> COALESCE(B.NIVEL_COMPLEMENTO1,'B')
--
-- Los COALESCE con literales DISTINTOS ('A' contra 'B') son el idioma del
-- legado para que dos NULL NO casen: si las dos nomenclaturas faltan, la
-- comparacion queda 'A' = 'B', que es falsa, y el par SI entra. Se conserva.
-- La ultima linea compara un ENTERO contra 'A'/'B'; Teradata lo castea en
-- silencio y Redshift no admite mezclar INTEGER y VARCHAR en un COALESCE, asi
-- que van centinelas NUMERICOS distintos (-1 y -2) con la misma semantica.
-- La cuarta linea (A.NIVEL <> B.NIVEL, sin COALESCE) propaga NULL y por tanto
-- excluye la fila: los dos complementos necesitan nomenclatura INICIAL en el
-- catalogo. Se porta tal cual.
--
-- La condicion de las colas es un OR de dos NOT LIKE, de modo que solo excluye
-- el caso en que cada cola contiene a la otra -- es decir, cuando son IGUALES.
-- Es la contraparte exacta del AND de dos LIKE que usa esc5 sub2 del legado.
--
-- COMPLEMENTO2 (linea 4790) es el complemento sin sus dos tokens de
-- nomenclatura, con el OREPLACE anidado de Teradata. En Redshift es REPLACE,
-- pero los JOIN al catalogo son LEFT y REPLACE(x, NULL, '') devuelve NULL, asi
-- que cada paso va protegido con su CASE.
--
-- QUIEN ES EL PADRE: NADIE, igual que en 'A8'. El legado no elige entre las
-- filas existentes: concatena los complementos de TODOS los miembros del grupo
-- y con esa fusion construye una direccion completamente nueva. Por eso aqui
-- tampoco hay MDIR.
--
-- LO QUE ORDENA ES EL DICCIONARIO MAS LA FECHA. Tmp_Unificacion_E062_D (linea
-- 4969) define
--   ID = (COALESCE(Conteo,0) + 10000000) + COALESCE(CAST(fecha AS INTEGER), 0)
-- donde Conteo es la suma de frecuencias del diccionario para ese complemento
-- (Tmp_Unificacion_E062_C1, linea 4907, el mismo join que usa esc4). El
-- CAST(DATE AS INTEGER) de Teradata devuelve (anio-1900)*10000 + mes*100 + dia;
-- Redshift no soporta ese cast, asi que se reconstruye con DATE_PART.
--
-- LO QUE NO SE PORTA: Tmp_Unificacion_E062_D calcula ademas COUNT_EMPATE, IDMAX
-- y EMPATE, pero su unico consumidor -- 'QUALIFY EMPATE=1' en la linea 5000 --
-- esta COMENTADO en el legado. Columnas que nadie lee y un filtro desactivado:
-- se omiten las tres y queda la nota.
--
-- LOS DOS 'WITH RECURSIVE' SON 'LISTAGG', igual que en 'A8':
--
--   Tmp_Unificacion_E062_E  (linea 5034)  concatena los COMPLEMENTO del grupo
--     anchor: cada fila con LVL = 1
--     paso:   T1.ID > T2.ID, resultado T1 || ' ' || T2, LVL + 1
--     cierre: RANK() ... ORDER BY LVL DESC = 1
--   Como T1 se antepone y la condicion es T1.ID > T2.ID, el resultado queda
--   ordenado por ID DESCENDENTE. Equivale a
--     LISTAGG(complemento, ' ') WITHIN GROUP (ORDER BY id DESC, ...)
--
--   Tmp_Unificacion_E062_EB (linea 5190)  reordena los componentes de la fusion
--     misma mecanica sobre ID_ORD_COMP = (nivel * 100000 + valor) * -1
--   El '* -1' invierte el sentido, de modo que queda ordenado por nivel
--   ASCENDENTE. Es EXACTAMENTE el reordenamiento ya portado para 'A6' y 'A8'.
--
-- LOS DOS LISTAGG DE LA FUSION COMPARTEN 'WITHIN GROUP'. No solo porque
-- Redshift lo exija dentro de un mismo SELECT ("within group ORDER BY clauses
-- for aggregate functions must be the same"): es lo FIEL al legado, donde la
-- lista de personas y el complemento se construyen en la MISMA recursion y por
-- tanto comparten orden por construccion.
--
-- DIVERGENCIA DELIBERADA, la misma de 'A8' (anotada para GOB-03).
-- La recursion exige T1.ID > T2.ID ESTRICTO, de modo que dos miembros de IGUAL
-- ID no pueden encadenarse: el legado deja a uno FUERA y, como varias cadenas
-- quedan empatadas en LVL, el 'RANK() ... ORDER BY LVL DESC = 1' escoge una
-- cualquiera. El miembro que se pierde depende del plan de ejecucion, no de los
-- datos. Aqui se porta la SEMANTICA declarada -- fusionar el grupo completo --
-- con un desempate explicito por cod_dw_persona_ubic para que el resultado sea
-- reproducible corrida a corrida, que es lo que exige la idempotencia (G-06).
--
-- Si tras la fusion el complemento no aporta ningun componente, no se crea
-- direccion y el grupo sigue su camino hasta esc5 / esc6.
CREATE OR REPLACE PROCEDURE bdm_datos.sp_unificacion_r2_motor_dif_nueva_direccion(
    p_modo VARCHAR,   -- FULL | DELTA (modo efectivo de la corrida)
    p_lote INTEGER    -- Lote_Corrida externo
)
NONATOMIC
LANGUAGE plpgsql
AS $$
BEGIN
  DROP TABLE IF EXISTS bdm_tempo.stg_motor_dif_base;
  DROP TABLE IF EXISTS bdm_tempo.stg_motor_dif_cand;
  DROP TABLE IF EXISTS bdm_tempo.stg_motor_dif_conteo;
  DROP TABLE IF EXISTS bdm_tempo.stg_motor_dif_orden;
  DROP TABLE IF EXISTS bdm_tempo.stg_motor_dif_fusion;
  DROP TABLE IF EXISTS bdm_tempo.stg_motor_dif_componentes;
  DROP TABLE IF EXISTS bdm_tempo.stg_motor_dif_nueva_nomen;
  DROP TABLE IF EXISTS bdm_tempo.stg_motor_dif_cabeza;
  DROP TABLE IF EXISTS bdm_tempo.stg_motor_dif_insumo;
  DROP TABLE IF EXISTS bdm_tempo.stg_motor_dif_miembros;
  DROP TABLE IF EXISTS bdm_tempo.stg_motor_dif_persist;

  -- (1) Tmp_Unificacion_E062 + Tmp_Unificacion_E062_A (lineas 4741 y 4790).
  --     Poblacion: lo que ningun escenario anterior consumio Y tiene pareja
  --     posible en su grupo, descompuesto en su nomenclatura inicial, su
  --     nomenclatura intermedia y la COLA que queda al quitarle las dos.
  --     El EXISTS es el self-join + QUALIFY rn = 1 del legado: "esta fila tiene
  --     al menos un companero con complemento distinto en el mismo grupo".
  --     Los JOIN al catalogo son LEFT a proposito, como en el legado: el
  --     predicato de abajo decide, no el join.
  CREATE TABLE bdm_tempo.stg_motor_dif_base
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
    e.fecha_relacion_persona_ubicaci,
    nmc1.nomenclatura      AS nomen_pri,
    nmc1.nivel_complemento AS nivel_pri,
    nmc2.nomenclatura      AS nomen_sec,
    nmc2.nivel_complemento AS nivel_sec,
    -- COMPLEMENTO2: el OREPLACE anidado del legado. Cada paso va envuelto en su
    -- CASE porque REPLACE(x, NULL, '') devuelve NULL en Redshift y los dos JOIN
    -- al catalogo son LEFT.
    TRIM(
      CASE WHEN nmc2.nomenclatura IS NULL
           THEN CASE WHEN nmc1.nomenclatura IS NULL
                     THEN UPPER(COALESCE(e.complemento, ''))
                     ELSE REPLACE(UPPER(COALESCE(e.complemento, '')), TRIM(nmc1.nomenclatura), '')
                END
           ELSE REPLACE(
                  CASE WHEN nmc1.nomenclatura IS NULL
                       THEN UPPER(COALESCE(e.complemento, ''))
                       ELSE REPLACE(UPPER(COALESCE(e.complemento, '')), TRIM(nmc1.nomenclatura), '')
                  END,
                  TRIM(nmc2.nomenclatura), '')
      END
    ) AS complemento2
  FROM bdm_tempo.stg_regla2_e2 e
  LEFT JOIN bdm_datos.nomenclatura nmc1
    ON UPPER(COALESCE(e.complemento, '')) LIKE TRIM(nmc1.nomenclatura) || ' %'
  LEFT JOIN bdm_datos.nomenclatura nmc2
    ON UPPER(COALESCE(e.complemento, '')) LIKE '% ' || TRIM(nmc2.nomenclatura) || ' %'
  WHERE e.ind_unificacion = 'N'
    AND EXISTS (
      SELECT 1
        FROM bdm_tempo.stg_regla2_e2 b
       WHERE b.ind_unificacion           = 'N'
         AND b.id_buro_persona           = e.id_buro_persona
         AND b.texto_ubicacion           = e.texto_ubicacion
         AND b.cod_dw_tipo_ubicacion_dir = e.cod_dw_tipo_ubicacion_dir
         AND b.cod_dw_municipio          = e.cod_dw_municipio
         AND b.cod_dw_persona_ubic      <> e.cod_dw_persona_ubic
         AND b.complemento              <> e.complemento );

  -- (2) Tmp_Unificacion_E062_C (linea 4844): el predicado de 'D9'.
  --     Ninguna nomenclatura coincide en ninguna combinacion, los niveles
  --     difieren y las colas NO son identicas.
  --     El ROW_NUMBER ... = 1 es el QUALIFY del legado: una fila por direccion,
  --     aunque varios companeros del grupo satisfagan el predicado.
  CREATE TABLE bdm_tempo.stg_motor_dif_cand
  DISTSTYLE KEY DISTKEY(id_buro_persona)
  AS
  SELECT z.cod_dw_persona_ubic, z.id_buro_persona, z.cod_dw_ubic,
         z.texto_ubicacion, z.cod_dw_tipo_ubicacion_dir, z.cod_dw_municipio,
         z.complemento, z.cod_dw_direccion_fisica, z.fecha_relacion_persona_ubicaci
  FROM (
    SELECT
      a.cod_dw_persona_ubic, a.id_buro_persona, a.cod_dw_ubic,
      a.texto_ubicacion, a.cod_dw_tipo_ubicacion_dir, a.cod_dw_municipio,
      a.complemento, a.cod_dw_direccion_fisica, a.fecha_relacion_persona_ubicaci,
      ROW_NUMBER() OVER (PARTITION BY a.cod_dw_persona_ubic
                             ORDER BY a.complemento) AS rn
    FROM bdm_tempo.stg_motor_dif_base a
    JOIN bdm_tempo.stg_motor_dif_base b
      ON  b.id_buro_persona           = a.id_buro_persona
      AND b.texto_ubicacion           = a.texto_ubicacion
      AND b.cod_dw_tipo_ubicacion_dir = a.cod_dw_tipo_ubicacion_dir
      AND b.cod_dw_municipio          = a.cod_dw_municipio
      AND b.cod_dw_persona_ubic      <> a.cod_dw_persona_ubic
      AND b.complemento              <> a.complemento
      -- las colas NO se contienen mutuamente (es decir, no son iguales)
      AND (    a.complemento2 NOT LIKE '%' || b.complemento2 || '%'
            OR b.complemento2 NOT LIKE '%' || a.complemento2 || '%' )
      -- ninguna nomenclatura coincide, en ninguna de las tres combinaciones
      AND COALESCE(a.nomen_pri, 'A') <> COALESCE(b.nomen_pri, 'B')
      AND COALESCE(a.nomen_sec, 'A') <> COALESCE(b.nomen_sec, 'B')
      AND COALESCE(a.nomen_pri, 'A') <> COALESCE(b.nomen_sec, 'B')
      -- y los niveles difieren
      AND a.nivel_pri <> b.nivel_pri
      AND COALESCE(a.nivel_pri, -1) <> COALESCE(b.nivel_sec, -2)
  ) z
  WHERE z.rn = 1;

  -- (3) Tmp_Unificacion_E062_C1 (linea 4907): la suma de frecuencias del
  --     diccionario para cada direccion. Mismo join que usa esc4.
  CREATE TABLE bdm_tempo.stg_motor_dif_conteo
  DISTSTYLE KEY DISTKEY(cod_dw_persona_ubic)
  AS
  SELECT c.cod_dw_persona_ubic,
         SUM(dc.frecuencia) AS conteo
  FROM bdm_tempo.stg_motor_dif_cand c
  JOIN bdm_datos.diccionario_complementos dc
    ON dc.cod_dw_ubic     = c.cod_dw_ubic
   AND dc.id_buro_persona = c.id_buro_persona
   AND UPPER(COALESCE(c.complemento, '')) LIKE '%' || dc.nomenclatura || '%'
  GROUP BY 1;

  -- (4) Tmp_Unificacion_E062_D (linea 4969): la clave de orden de la fusion.
  --     ID = (conteo + 10000000) + fecha_como_entero.
  --     El CAST(DATE AS INTEGER) de Teradata da (anio-1900)*10000 + mes*100 +
  --     dia; Redshift no lo soporta y se reconstruye con DATE_PART.
  --     NO se portan COUNT_EMPATE, IDMAX ni EMPATE: su unico consumidor, el
  --     'QUALIFY EMPATE=1' de la linea 5000, esta comentado en el legado.
  CREATE TABLE bdm_tempo.stg_motor_dif_orden
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
    CAST(COALESCE(n.conteo, 0) + 10000000 AS BIGINT)
      + CAST(COALESCE(
          (DATE_PART(year,  c.fecha_relacion_persona_ubicaci) - 1900) * 10000
          + DATE_PART(month, c.fecha_relacion_persona_ubicaci) * 100
          + DATE_PART(day,   c.fecha_relacion_persona_ubicaci), 0) AS BIGINT) AS id
  FROM bdm_tempo.stg_motor_dif_cand c
  LEFT JOIN bdm_tempo.stg_motor_dif_conteo n
    ON n.cod_dw_persona_ubic = c.cod_dw_persona_ubic;

  -- (5) Tmp_Unificacion_E062_E (linea 5034), primer WITH RECURSIVE: la fusion
  --     de los complementos del grupo, por ID DESCENDENTE.
  --     Solo grupos de DOS O MAS miembros, que es el
  --     'WHERE CL.Cod_DW_Persona_Ubic LIKE ''%,%''' del legado (linea 5083).
  CREATE TABLE bdm_tempo.stg_motor_dif_fusion
  DISTSTYLE KEY DISTKEY(id_buro_persona)
  AS
  SELECT
    o.id_buro_persona,
    o.cod_dw_ubic,
    o.texto_ubicacion,
    o.cod_dw_tipo_ubicacion_dir,
    o.cod_dw_municipio,
    COUNT(*) AS miembros,
    LISTAGG(CAST(o.cod_dw_persona_ubic AS VARCHAR), ',')
      WITHIN GROUP (ORDER BY o.id DESC, o.cod_dw_persona_ubic) AS hijos,
    LISTAGG(o.complemento, ' ')
      WITHIN GROUP (ORDER BY o.id DESC, o.cod_dw_persona_ubic) AS complemento_fusion
  FROM bdm_tempo.stg_motor_dif_orden o
  GROUP BY 1, 2, 3, 4, 5
  HAVING COUNT(*) > 1;

  -- (6) Tmp_Unificacion_E062_EA (linea 5131): descomposicion de la fusion en
  --     componentes del diccionario, con su nivel.
  --     El join es por (cod_dw_ubic, id_buro_persona) + LIKE, igual que el
  --     legado. Un LIKE con patron derivado de columna SI es valido en
  --     Redshift; lo que no lo seria es un REGEXP_* con patron no literal.
  CREATE TABLE bdm_tempo.stg_motor_dif_componentes
  DISTSTYLE KEY DISTKEY(id_buro_persona)
  AS
  SELECT DISTINCT
    f.id_buro_persona,
    f.cod_dw_ubic,
    f.texto_ubicacion,
    f.cod_dw_tipo_ubicacion_dir,
    f.cod_dw_municipio,
    dc.nomenclatura,
    -- El VALOR va en su propia columna del diccionario: el constructor guarda
    -- 'nomenclatura' y 'nomen' con el TOKEN SOLO ('BR') y el numero aparte en
    -- 'valor' ('5'). Sin arrastrarlo, el complemento que se arma abajo saldria
    -- sin numeros ('BR AP' en vez de 'BR 5 AP 301').
    dc.valor,
    COALESCE(nom.nivel_complemento, 99) AS nivel_complemento,
    COALESCE(CAST(NULLIF(REGEXP_REPLACE(COALESCE(dc.valor, ''), '[^0-9]', ''), '') AS BIGINT),
             999999) AS valor_num
  FROM bdm_tempo.stg_motor_dif_fusion f
  JOIN bdm_datos.diccionario_complementos dc
    ON dc.cod_dw_ubic     = f.cod_dw_ubic
   AND dc.id_buro_persona = f.id_buro_persona
   AND UPPER(f.complemento_fusion) LIKE '%' || dc.nomenclatura || '%'
  LEFT JOIN bdm_datos.nomenclatura nom
    ON nom.nomenclatura = COALESCE(NULLIF(dc.nomen, ''), dc.nomenclatura);

  -- (7) Tmp_Unificacion_E062_EB (linea 5190), segundo WITH RECURSIVE: el
  --     complemento final, reordenado por (nivel, valor) ASCENDENTE y sin
  --     repetir nomenclatura. Mismo reordenamiento que 'A6' y 'A8'.
  CREATE TABLE bdm_tempo.stg_motor_dif_nueva_nomen
  DISTSTYLE KEY DISTKEY(id_buro_persona)
  AS
  SELECT
    c.id_buro_persona,
    c.cod_dw_ubic,
    c.texto_ubicacion,
    c.cod_dw_tipo_ubicacion_dir,
    c.cod_dw_municipio,
    LISTAGG(TRIM(c.nomenclatura || ' ' || COALESCE(c.valor, '')), ' ')
      WITHIN GROUP (ORDER BY c.nivel_complemento, c.valor_num, c.nomenclatura) AS nuevo_complemento
  FROM bdm_tempo.stg_motor_dif_componentes c
  GROUP BY 1, 2, 3, 4, 5;

  -- (8) La CABEZA del grupo: el miembro de ID mas alto, que es el que encabeza
  --     la cadena del legado (T1 de la recursion). De el se heredan los
  --     atributos de via, que no cambian: lo que cambia es el complemento.
  CREATE TABLE bdm_tempo.stg_motor_dif_cabeza
  DISTSTYLE KEY DISTKEY(id_buro_persona)
  AS
  SELECT z.*
  FROM (
    SELECT
      o.id_buro_persona,
      o.cod_dw_ubic,
      o.texto_ubicacion,
      o.cod_dw_tipo_ubicacion_dir,
      o.cod_dw_municipio,
      o.cod_dw_persona_ubic,
      o.cod_dw_direccion_fisica,
      ROW_NUMBER() OVER (PARTITION BY o.id_buro_persona, o.cod_dw_ubic,
                                      o.texto_ubicacion,
                                      o.cod_dw_tipo_ubicacion_dir,
                                      o.cod_dw_municipio
                             ORDER BY o.id DESC, o.cod_dw_persona_ubic) AS rn
    FROM bdm_tempo.stg_motor_dif_orden o
  ) z
  WHERE z.rn = 1;

  -- (9) Tmp_Unificacion_E062_F (linea 5329), rama ROW_U = -99: una fila por
  --     direccion NUEVA.
  CREATE TABLE bdm_tempo.stg_motor_dif_insumo
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
    -- Mismas claves deterministas que los otros tres sitios, con su propio
    -- discriminante '|MOTOR|D9|': cuatro sitios distintos no pueden colisionar.
    FNV_HASH(CAST(cab.cod_dw_persona_ubic AS VARCHAR) || '|MOTOR|D9|DF|'  || f.hijos) AS cod_dw_direccion_fisica,
    FNV_HASH(CAST(cab.cod_dw_persona_ubic AS VARCHAR) || '|MOTOR|D9|RPU|' || f.hijos) AS cod_dw_persona_ubic,
    nn.nuevo_complemento AS complemento_motor,
    CAST(1 AS INTEGER) AS generada_enriquecida
  FROM bdm_tempo.stg_motor_dif_fusion f
  JOIN bdm_tempo.stg_motor_dif_cabeza cab
    ON  cab.id_buro_persona           = f.id_buro_persona
    AND cab.cod_dw_ubic               = f.cod_dw_ubic
    AND cab.texto_ubicacion           = f.texto_ubicacion
    AND cab.cod_dw_tipo_ubicacion_dir = f.cod_dw_tipo_ubicacion_dir
    AND cab.cod_dw_municipio          = f.cod_dw_municipio
  JOIN bdm_tempo.stg_motor_dif_nueva_nomen nn
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
    FROM bdm_tempo.stg_motor_dif_insumo s
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
  FROM bdm_tempo.stg_motor_dif_insumo s
  WHERE NOT EXISTS ( SELECT 1 FROM bdm_datos.direccion_fisica_generada d
                      WHERE d.cod_dw_direccion_fisica = s.cod_dw_direccion_fisica );

  UPDATE bdm_datos.rpu_generada
     SET cod_dw_ubic               = s.cod_dw_ubic,
         cod_dw_direccion_fisica   = s.cod_dw_direccion_fisica,
         cod_dw_tipo_ubicacion_dir = s.cod_dw_tipo_ubicacion_dir,
         lote_actualizacion        = p_lote,
         usuario_bd                = CURRENT_USER,
         fecha_modificacion        = CURRENT_DATE
    FROM bdm_tempo.stg_motor_dif_insumo s
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
    -- NULL como en la rama ROW_U = -99 del legado (linea 5335).
    NULL,
    p_lote, p_lote,
    NULL,
    CURRENT_USER, NULL, CURRENT_DATE
  FROM bdm_tempo.stg_motor_dif_insumo s
  WHERE NOT EXISTS ( SELECT 1 FROM bdm_datos.rpu_generada r
                      WHERE r.cod_dw_persona_ubic = s.cod_dw_persona_ubic );

  -- ----------------------------------------------------------------------
  -- (11) EL GRUPO COMPLETO SE UNIFICA CONTRA LA DIRECCION GENERADA
  -- Rama ROW_U = 0 de Tmp_Unificacion_E062_F (linea 5356): TODOS los miembros
  -- de E062_D quedan como hijos de la direccion nueva.
  -- ----------------------------------------------------------------------
  CREATE TABLE bdm_tempo.stg_motor_dif_miembros
  DISTSTYLE KEY DISTKEY(id_buro_persona)
  AS
  SELECT
    o.id_buro_persona,
    o.cod_dw_ubic,
    o.texto_ubicacion,
    o.cod_dw_tipo_ubicacion_dir,
    o.cod_dw_municipio,
    o.cod_dw_persona_ubic AS miembro
  FROM bdm_tempo.stg_motor_dif_orden o;

  CREATE TABLE bdm_tempo.stg_motor_dif_persist
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
  FROM bdm_tempo.stg_motor_dif_miembros m
  JOIN bdm_tempo.stg_motor_dif_insumo s
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
    FROM bdm_tempo.stg_motor_dif_persist s
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
      FROM bdm_tempo.stg_motor_dif_persist s
     WHERE bdm_datos.unificacion_direccion.cod_dw_persona_ubic = s.cod_dw_persona_ubic
       AND bdm_datos.unificacion_direccion.cod_dw_direccion_unificada = s.cod_dw_direccion_unificada;

    INSERT INTO bdm_datos.unificacion_direccion
      (cod_dw_persona_ubic, cod_dw_direccion_unificada, unifica_atributos, fecha_unificacion, lote, severidad, usuario_bd)
    SELECT DISTINCT s.cod_dw_persona_ubic, s.cod_dw_direccion_unificada, s.unifica_atributos,
           s.fecha_unificacion, s.lote, s.severidad, s.usuario_bd
    FROM bdm_tempo.stg_motor_dif_persist s
    WHERE NOT EXISTS (
      SELECT 1 FROM bdm_datos.unificacion_direccion u
       WHERE u.cod_dw_persona_ubic = s.cod_dw_persona_ubic
         AND u.cod_dw_direccion_unificada = s.cod_dw_direccion_unificada);
  END IF;

  -- ----------------------------------------------------------------------
  -- (12) MARCADO. El MERGE de vuelta a Tmp_Unificacion_E2 (linea 5402), con el
  -- sello 'D9' que fija la linea 5415, para que las etapas POSTERIORES -- esc5,
  -- el sitio 3 y esc6 -- no vuelvan a ver este grupo.
  -- ----------------------------------------------------------------------
  UPDATE bdm_tempo.stg_regla2_e2
  SET id_padre        = stg.cod_dw_direccion_unificada,
      ind_unificacion = 'S',
      n_id            = 'D9'
  FROM bdm_tempo.stg_motor_dif_persist stg
  WHERE bdm_tempo.stg_regla2_e2.cod_dw_persona_ubic = stg.cod_dw_persona_ubic
    AND bdm_tempo.stg_regla2_e2.id_padre IS NULL;

END;
$$;
