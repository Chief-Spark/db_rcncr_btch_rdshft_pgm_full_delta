-- R3 — Regla 3 completa: dos escenarios, Diccionario de Via y puntaje
-- Fuente: edf_views -> bdm_tempo.v_xpm_* | Salida: bdm_datos.unificacion_direccion
-- Prerequisito: Regla 2 ejecutada; geo_atributos poblado por el Ciclo GEO
--
-- ============================================================================
-- PUERTO DEL LEGADO P0021_UNIFICACION_111.BTQ (431 lineas)
-- ============================================================================
-- La version anterior de este SP NO habia visto el legado: lo suplia troceando
-- texto_ubicacion con SPLIT_PART, exigia latitud en AMBOS lados y elegia al
-- padre por numero de entidades. No tenia escenarios, ni puntaje, ni
-- diccionario. El legado si los tiene y esta completo.
--
-- LAS CUATRO ETAPAS DEL LEGADO, con su nombre alli:
--   Unificacion_3431  insumo              -> stg_regla3_insumo
--   Unificacion_3432  pares (dos esc.)    -> stg_regla3_pares
--   DICCIONARIO_VIA   frecuencia historica-> bdm_datos.diccionario_via
--   Unificacion_3433  puntaje             -> stg_regla3_scored
--   Unificacion_3434  padre               -> stg_regla3_ganador + stg_regla3_final
--
-- LA FORMULA DEL PUNTAJE es el corazon de la regla y explica cuatro criterios
-- de aceptacion de un golpe (legado, linea 268):
--
--   id_unificacion = CASE WHEN lat Y long  THEN 100000000 + conteo_diccionario
--                    + CASE WHEN falta una THEN fecha_como_entero
--                    + numero_entidades_reportan
--
--   El 100000000 hace que CUALQUIER direccion geolocalizada gane a CUALQUIERA
--   sin coordenadas          -> "si solo una tiene coordenadas, el padre es la
--                               geolocalizada"
--   Sin coordenadas manda la fecha (del orden de 1,2 millones) y las entidades
--   (decenas) desempatan      -> "si ninguna tiene coordenadas gana la de fecha
--                               mas reciente; ante empate, mas entidades"
--   Con las dos geolocalizadas decide el conteo del diccionario
--                             -> "se consulta el Diccionario de Via por
--                               frecuencia y gana la mas reportada"
--   Y el padre debe ser UNICO en su particion a ese puntaje
--                             -> "ante empate en el diccionario no se toma
--                               decision de unificacion"
--
-- NO se exige coordenadas en el insumo. Exigirlas era el defecto de fondo del
-- puerto anterior: eliminaba de la regla justamente los dos subcasos que los
-- criterios piden ("solo una geolocalizada" y "ninguna geolocalizada").
--
-- ----------------------------------------------------------------------------
-- CUATRO DIVERGENCIAS DELIBERADAS RESPECTO AL LEGADO
-- Cada una vive en UN predicado marcado, de modo que volver al comportamiento
-- de Teradata es un cambio de una linea. Quedan para la bitacora de diferencias
-- (GOB-01/GOB-04) como cambio funcional.
--
--   (D1) TIPO DE VIA. El legado filtra TA.Descripcion_Tipo_Atributo='Tipo_Via',
--        que es el TIPO del atributo y admite los cuatro valores del catalogo
--        (Via, MZ, Rural, Descriptiva): no excluye Manzana ni Rural. El
--        criterio de aceptacion dice que si. Se filtra por el VALOR 'Via'.
--
--   (D2) CUADRANTES. El legado los EXCLUYE de la regla, en el mismo predicado
--        con que excluye los modificadores de via ('| OE$| E$| NE$| SE$| O$|
--        S$| N$| SOE$'). El criterio dice lo contrario: "se omiten para la
--        comparacion numerica pero NO excluyen a la direccion de participar".
--        Se deja entrar la direccion y se normaliza la clave de comparacion.
--
--   (D3) UMBRAL DE PUERTA. El legado escribe ABS(diff) = 2, EXACTAMENTE dos, de
--        modo que una diferencia de 1 no empareja -- y el comentario que esta
--        tres lineas arriba del propio legado dice "± 2 unidades". El codigo y
--        su comentario se contradicen entre si; el criterio dice "umbral de
--        mas/menos 2". Se implementa BETWEEN 1 AND 2.--
--   (D4) ALCANCE DEL UMBRAL. En el legado el escenario 2 (puerta a +-2)
--        empareja sin mirar coordenadas: las coordenadas solo PUNTUAN, no
--        condicionan el emparejamiento. El criterio de aceptacion dice que "el
--        umbral de mas/menos 2 aplica SOLO en el subcaso donde ambas
--        direcciones tienen coordenadas", que describe un arbol de decision
--        distinto: primero se mira si hay coordenadas y el umbral se consulta
--        solo en la rama de las dos. Se acota el escenario 2 a las filas con
--        las dos coordenadas en AMBOS lados.
--        No afecta a los otros subcasos: "solo una geolocalizada" y "ninguna
--        geolocalizada" son casos del escenario 1 (misma puerta, distinta via
--        generadora), que sigue sin condicion de coordenadas.
--
-- DOS CORRECCIONES a defectos del legado, no divergencias de criterio:
--   (C1) El legado usa INNER JOIN contra el reporte pero envuelve el conteo en
--        COALESCE(...,0), que bajo INNER JOIN es codigo muerto: el tell de que
--        la agregacion se escribio para un LEFT JOIN. Con INNER, toda direccion
--        sin entidad reportante queda fuera de la regla para siempre -- entre
--        ellas las que crea el motor, que nacen sin fila de reporte. Es el
--        mismo defecto ya corregido en los insumos de R1 y R2 (SLCOPRBA-1355).
--   (C2) El legado compara coordenadas con OR en el escenario 1 y con AND en el
--        escenario 2. Con AND, una fila que trae UNA sola coordenada no suma ni
--        el termino geo ni el de fecha y queda con solo las entidades. Se usa
--        OR en los dos, que es el complemento exacto de "trae las dos".
-- ============================================================================

CREATE OR REPLACE PROCEDURE bdm_datos.sp_unificacion_r3_esc1_geo_misma_via_puerta_cercana(
    p_modo VARCHAR,   -- FULL | DELTA (modo efectivo de la corrida)
    p_lote INTEGER    -- Lote_Corrida externo
)
NONATOMIC
LANGUAGE plpgsql
AS $$
BEGIN

  DROP TABLE IF EXISTS bdm_tempo.stg_regla3_insumo;
  DROP TABLE IF EXISTS bdm_tempo.stg_regla3_pares;
  DROP TABLE IF EXISTS bdm_tempo.stg_regla3_scored;
  DROP TABLE IF EXISTS bdm_tempo.stg_regla3_ganador;
  DROP TABLE IF EXISTS bdm_tempo.stg_regla3_final;

  -- ==========================================================
  -- (1) INSUMO  <- Unificacion_3431 (legado, linea 46)
  -- ----------------------------------------------------------
  -- SIN frontera de fecha, igual que el legado: su insumo de R3 nunca se acota
  -- por ventana. El estado (ind_unificacion IS NULL) es lo que lo hace
  -- incremental, como en R1 y R2.
  --
  -- numero_puerta es VARCHAR en el origen (standardizednumeropuerta del
  -- datashare) y el escenario 2 necesita restarlo. El CAST va envuelto en
  -- REGEXP_SUBSTR '^[0-9]+$': un CAST directo sobre un valor no numerico
  -- ABORTA el lote con "Invalid digit, Value '#', Pos 0, Type: Integer".
  -- Devolviendo NULL en el que no es numerico, la fila no compara -- que es el
  -- comportamiento buscado -- en vez de tumbar la corrida. El patron es un
  -- literal: Redshift no acepta patrones derivados de columna.
  -- ==========================================================
  CREATE TABLE bdm_tempo.stg_regla3_insumo
  DISTSTYLE KEY DISTKEY(id_buro_persona)
  SORTKEY(id_buro_persona, cod_dw_municipio)
  AS
  SELECT
    rpu.cod_dw_persona_ubic,
    rpu.id_buro_persona,
    ubi.texto_ubicacion,
    df.tipo_via_principal,
    df.via_principal,
    df.via_generadora,
    df.numero_puerta,
    ubi.cod_dw_municipio,
    ubi.latitud,
    ubi.longitud,
    -- (D2) Clave de comparacion con el cuadrante OMITIDO. El criterio pide que
    -- el cuadrante no impida el emparejamiento; comparando el valor crudo, un
    -- 'CL 45 SUR' nunca casaria con un 'CL 45' y el efecto seria el contrario
    -- al pedido. Las alternativas largas van PRIMERO: la alternacion es
    -- leftmost-first y con 'S' delante, 'SUR' nunca se alcanzaria.
    REGEXP_REPLACE(UPPER(COALESCE(df.via_principal, '')),
      '[[:space:]]+(NORTE|OESTE|ESTE|SUR|SOE|NE|NO|SE|SO|OE|N|S|E|O)$', '') AS via_principal_cmp,
    REGEXP_REPLACE(UPPER(COALESCE(df.via_generadora, '')),
      '[[:space:]]+(NORTE|OESTE|ESTE|SUR|SOE|NE|NO|SE|SO|OE|N|S|E|O)$', '') AS via_generadora_cmp,
    CAST(NULLIF(REGEXP_SUBSTR(COALESCE(df.numero_puerta, ''), '^[0-9]+$'), '') AS INTEGER) AS numero_puerta_num,
    -- (C1) LEFT JOIN, no INNER: ver la cabecera.
    COALESCE(COUNT(DISTINCT rep.id_buro_suscriptor), 0) AS numero_entidades_reportan,
    MAX(rep.fecha_reporte)                              AS fecha_ultima_actualizacion
  FROM bdm_tempo.v_xpm_relacion_persona_ubicacion rpu
  JOIN bdm_tempo.v_xpm_ubicacion_estandarizada ubi
    ON rpu.cod_dw_ubic = ubi.cod_dw_ubic
  LEFT JOIN bdm_tempo.v_xpm_direccion_fisica df
    ON rpu.cod_dw_direccion_fisica = df.cod_dw_direccion_fisica
  LEFT JOIN bdm_tempo.v_xpm_reporte_relacion_persona_ubica rep
    ON rpu.cod_dw_persona_ubic = rep.cod_dw_persona_ubic
  WHERE rpu.ind_unificacion IS NULL
    AND COALESCE(rpu.bloqueado, 0) = 0
    -- (D1) Solo tipo Via: se excluyen Manzana, Rural y Descriptiva.
    -- Dominio del catalogo Tipo_Via del legado. En la via REAL el valor llega
    -- de standardizedtipo del datashare y su dominio exacto es un dato que QA
    -- debe confirmar con
    --     SELECT DISTINCT tipo_ubicacion FROM bdm_tempo.v_xpm_ubicacion_estandarizada;
    -- Si alli el literal no fuera 'Via', la regla daria 0 filas en real -- y lo
    -- diria el conteo del insumo, no un error.
    AND UPPER(TRIM(COALESCE(ubi.tipo_ubicacion, ''))) = 'VIA'
    -- Modificadores de via (B, C, F, BIS...): se excluyen. Literal del legado,
    -- 'un corrido de 1 a 3 digitos seguido de 1 a 5 letras' ('12B', '45BIS').
    -- Aqui NO van los cuadrantes del legado: esa es la divergencia (D2).
    AND REGEXP_COUNT(UPPER(COALESCE(ubi.texto_ubicacion, '')), '[0-9]{1,3}[A-Z]{1,5}') = 0
  GROUP BY 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13;

  -- ==========================================================
  -- (2) PARES  <- Unificacion_3432 (legado, linea 128)
  -- ----------------------------------------------------------
  -- No son parejas todavia: son las filas que TIENEN con quien emparejarse,
  -- etiquetadas con el escenario. Una misma direccion puede salir en los dos.
  --   id_u = 1  misma puerta,     distinta via generadora
  --   id_u = 2  misma generadora, puerta a +-2  (D3)
  -- ==========================================================
  CREATE TABLE bdm_tempo.stg_regla3_pares
  DISTSTYLE KEY DISTKEY(id_buro_persona)
  AS
  SELECT DISTINCT 1 AS id_u, t1.*
  FROM bdm_tempo.stg_regla3_insumo t1
  JOIN bdm_tempo.stg_regla3_insumo t2
    ON  t1.id_buro_persona    = t2.id_buro_persona
   AND  t1.cod_dw_municipio   = t2.cod_dw_municipio
   AND  t1.tipo_via_principal = t2.tipo_via_principal
   AND  t1.via_principal_cmp  = t2.via_principal_cmp
   AND  t1.numero_puerta_num  = t2.numero_puerta_num
   AND  t1.via_generadora_cmp <> t2.via_generadora_cmp
  UNION ALL
  SELECT DISTINCT 2 AS id_u, t1.*
  FROM bdm_tempo.stg_regla3_insumo t1
  JOIN bdm_tempo.stg_regla3_insumo t2
    ON  t1.id_buro_persona    = t2.id_buro_persona
   AND  t1.cod_dw_municipio   = t2.cod_dw_municipio
   AND  t1.tipo_via_principal = t2.tipo_via_principal
   AND  t1.via_principal_cmp  = t2.via_principal_cmp
   AND  t1.via_generadora_cmp = t2.via_generadora_cmp
   -- (D3) El legado dice ABS(...) = 2; el criterio y el propio comentario del
   -- legado dicen +-2.
   AND  ABS(t1.numero_puerta_num - t2.numero_puerta_num) BETWEEN 1 AND 2
   -- (D4) El umbral SOLO aplica cuando las dos direcciones estan
   -- geolocalizadas. El legado no lo acota; el criterio si. Quitar estas
   -- cuatro lineas devuelve el comportamiento de Teradata.
   AND  NULLIF(t1.latitud, 0)  IS NOT NULL AND NULLIF(t1.longitud, 0) IS NOT NULL
   AND  NULLIF(t2.latitud, 0)  IS NOT NULL AND NULLIF(t2.longitud, 0) IS NOT NULL;

  -- ==========================================================
  -- (3) DICCIONARIO DE VIA  <- DICCIONARIO_VIA (legado, linea 200)
  -- ----------------------------------------------------------
  -- Frecuencia HISTORICA, no por persona: cuenta reportes sobre toda la
  -- poblacion que comparte ese texto_ubicacion, igual que el legado (su join
  -- es por texto_ubicacion, no por id_buro_persona). Por eso se construye
  -- DESPUES de los pares y acotado a sus textos: es el alcance del legado.
  --
  -- LA LLAVE LLEVA '|' COMO SEPARADOR, no el espacio del legado. Con espacios
  -- la llave es ambigua: 'CL 45 6' no distingue CL/45/6 de 'CL 4'/5/6. El
  -- separador solo tiene que ser el MISMO aqui y en el LEFT JOIN del puntaje,
  -- y eso es lo unico que hay que mantener en paralelo entre las dos consultas.
  --
  -- Se usan los componentes CRUDOS, no los normalizados por cuadrante: el
  -- diccionario mide con que frecuencia se reporta esa cadena exacta, que es
  -- lo que hace el legado. La normalizacion (D2) afecta al emparejamiento y a
  -- la particion, no a la frecuencia.
  --
  -- WHERE explicito en el DELETE por la politica del pipeline (REDSHIFT:232);
  -- nombra los dos unicos tipos que existen, de modo que borra todo sin
  -- decirlo con un predicado vacio.
  -- ==========================================================
  DELETE FROM bdm_datos.diccionario_via
   WHERE tipo IN ('Via_Generadora', 'Numero_Puerta');

  INSERT INTO bdm_datos.diccionario_via (tipo, llave, valor, cod_dw_municipio, conteo)
  SELECT
    'Via_Generadora',
    COALESCE(df.tipo_via_principal, '') || '|' || COALESCE(df.via_principal, '') || '|' || COALESCE(df.numero_puerta, ''),
    df.via_generadora,
    p.cod_dw_municipio,
    COUNT(*)
  FROM bdm_tempo.v_xpm_direccion_fisica df
  JOIN bdm_tempo.v_xpm_ubicacion_estandarizada ue
    ON df.cod_dw_ubic = ue.cod_dw_ubic
  JOIN ( SELECT DISTINCT texto_ubicacion, cod_dw_municipio
           FROM bdm_tempo.stg_regla3_pares
          WHERE id_u = 1 ) p
    ON p.texto_ubicacion  = ue.texto_ubicacion
   AND p.cod_dw_municipio = ue.cod_dw_municipio
  JOIN bdm_tempo.v_xpm_relacion_persona_ubicacion rpu
    ON df.cod_dw_ubic             = rpu.cod_dw_ubic
   AND df.cod_dw_direccion_fisica = rpu.cod_dw_direccion_fisica
  JOIN bdm_tempo.v_xpm_reporte_relacion_persona_ubica rep
    ON rpu.cod_dw_persona_ubic = rep.cod_dw_persona_ubic
  GROUP BY 1, 2, 3, 4;

  INSERT INTO bdm_datos.diccionario_via (tipo, llave, valor, cod_dw_municipio, conteo)
  SELECT
    'Numero_Puerta',
    COALESCE(df.tipo_via_principal, '') || '|' || COALESCE(df.via_principal, '') || '|' || COALESCE(df.via_generadora, ''),
    df.numero_puerta,
    p.cod_dw_municipio,
    COUNT(*)
  FROM bdm_tempo.v_xpm_direccion_fisica df
  JOIN bdm_tempo.v_xpm_ubicacion_estandarizada ue
    ON df.cod_dw_ubic = ue.cod_dw_ubic
  JOIN ( SELECT DISTINCT texto_ubicacion, cod_dw_municipio
           FROM bdm_tempo.stg_regla3_pares
          WHERE id_u = 2 ) p
    ON p.texto_ubicacion  = ue.texto_ubicacion
   AND p.cod_dw_municipio = ue.cod_dw_municipio
  JOIN bdm_tempo.v_xpm_relacion_persona_ubicacion rpu
    ON df.cod_dw_ubic             = rpu.cod_dw_ubic
   AND df.cod_dw_direccion_fisica = rpu.cod_dw_direccion_fisica
  JOIN bdm_tempo.v_xpm_reporte_relacion_persona_ubica rep
    ON rpu.cod_dw_persona_ubic = rep.cod_dw_persona_ubic
  GROUP BY 1, 2, 3, 4;

  -- ==========================================================
  -- (4) PUNTAJE  <- Unificacion_3433 (legado, linea 268)
  -- ----------------------------------------------------------
  -- UN SOLO LEFT JOIN con un CASE sobre id_u, en vez de los dos del legado
  -- (DVV/DVP): solo uno de los dos puede casar por fila, asi que son
  -- equivalentes y asi no hay dos joins que mantener en paralelo. Al del
  -- escenario 2 se le AGREGA cod_dw_municipio, que el legado solo pone en el
  -- del escenario 1 -- una asimetria que sin municipio sumaria frecuencias de
  -- ciudades distintas.
  --
  -- LA FECHA COMO ENTERO reproduce el CAST(date AS INTEGER) de Teradata, que
  -- Redshift no acepta: (anio-1900)*10000 + mes*100 + dia. La forma importa,
  -- no solo la monotonia -- el orden de magnitud (del millon) es lo que deja
  -- que numero_entidades_reportan (decenas) desempate sin poder invertir la
  -- comparacion de fechas.
  --
  -- NULLIF(x, 0): el legado trata una coordenada en 0 como ausente.
  -- ==========================================================
  CREATE TABLE bdm_tempo.stg_regla3_scored
  DISTSTYLE KEY DISTKEY(id_buro_persona)
  AS
  SELECT
    p.*,
      CASE WHEN NULLIF(p.latitud, 0) IS NOT NULL AND NULLIF(p.longitud, 0) IS NOT NULL
           THEN 100000000 + COALESCE(d.conteo, 0) ELSE 0 END
      -- (C2) OR en los dos escenarios, el complemento exacto de "trae las dos".
    + CASE WHEN NULLIF(p.latitud, 0) IS NULL OR NULLIF(p.longitud, 0) IS NULL
           THEN COALESCE( (DATE_PART(year,  p.fecha_ultima_actualizacion) - 1900) * 10000
                        +  DATE_PART(month, p.fecha_ultima_actualizacion) * 100
                        +  DATE_PART(day,   p.fecha_ultima_actualizacion), 0) ELSE 0 END
    + COALESCE(p.numero_entidades_reportan, 0) AS id_unificacion
  FROM bdm_tempo.stg_regla3_pares p
  LEFT JOIN bdm_datos.diccionario_via d
    ON  d.tipo  = CASE WHEN p.id_u = 1 THEN 'Via_Generadora' ELSE 'Numero_Puerta' END
   AND  d.llave = CASE WHEN p.id_u = 1
                       THEN COALESCE(p.tipo_via_principal, '') || '|' || COALESCE(p.via_principal, '') || '|' || COALESCE(p.numero_puerta, '')
                       ELSE COALESCE(p.tipo_via_principal, '') || '|' || COALESCE(p.via_principal, '') || '|' || COALESCE(p.via_generadora, '') END
   AND  COALESCE(d.valor, '') = CASE WHEN p.id_u = 1
                                     THEN COALESCE(p.via_generadora, '')
                                     ELSE COALESCE(p.numero_puerta, '') END
   AND  d.cod_dw_municipio = p.cod_dw_municipio;

  -- ==========================================================
  -- (5) GANADOR  <- el CANT1/CANT2 del legado (linea 283)
  -- ----------------------------------------------------------
  -- El padre de cada grupo es el de puntaje maximo, Y TIENE QUE SER UNICO a ese
  -- puntaje: con dos empatados no se toma decision. Eso es literalmente el
  -- criterio "ante empate en el diccionario no se toma decision de
  -- unificacion", y vale para cualquier empate, no solo el del diccionario.
  --
  -- La particion es la del escenario: lo que esta FIJO en el emparejamiento.
  --   id_u = 1  ... numero_puerta fijo
  --   id_u = 2  ... via_generadora fija
  -- El CAST a VARCHAR del discriminante no es cosmetico: un CASE no puede
  -- devolver INTEGER en una rama y VARCHAR en la otra.
  -- ==========================================================
  CREATE TABLE bdm_tempo.stg_regla3_ganador
  DISTSTYLE KEY DISTKEY(id_buro_persona)
  AS
  SELECT id_u, cod_dw_persona_ubic, id_buro_persona, cod_dw_municipio,
         tipo_via_principal, via_principal_cmp, via_generadora_cmp,
         numero_puerta_num, id_unificacion
  FROM (
    SELECT s.*,
           ROW_NUMBER() OVER (
             PARTITION BY s.id_u, s.id_buro_persona, s.cod_dw_municipio,
                          s.tipo_via_principal, s.via_principal_cmp,
                          CASE WHEN s.id_u = 1 THEN CAST(s.numero_puerta_num AS VARCHAR)
                               ELSE s.via_generadora_cmp END
             ORDER BY s.id_unificacion DESC) AS rn,
           COUNT(*) OVER (
             PARTITION BY s.id_u, s.id_buro_persona, s.cod_dw_municipio,
                          s.tipo_via_principal, s.via_principal_cmp,
                          CASE WHEN s.id_u = 1 THEN CAST(s.numero_puerta_num AS VARCHAR)
                               ELSE s.via_generadora_cmp END,
                          s.id_unificacion) AS empatados
    FROM bdm_tempo.stg_regla3_scored s
  ) r
  WHERE rn = 1
    AND empatados = 1;

  -- ==========================================================
  -- (6) PAREJAS  <- Unificacion_3434 (legado, linea 330)
  -- ----------------------------------------------------------
  -- Las dos ramas UNION ALL del legado colapsadas en un OR sobre id_u. La hija
  -- es toda fila de puntaje <= al del ganador y distinta de el; el ROW_NUMBER
  -- final deja UN SOLO padre por hija, que es el ajuste #2 del legado
  -- ("Unificacion un hijo con varios padres", 14/09/2018).
  -- ==========================================================
  CREATE TABLE bdm_tempo.stg_regla3_final
  DISTSTYLE KEY DISTKEY(cod_dw_persona_ubic)
  AS
  SELECT cod_dw_persona_ubic, id_padre
  FROM (
    SELECT h.cod_dw_persona_ubic,
           g.cod_dw_persona_ubic AS id_padre,
           ROW_NUMBER() OVER (PARTITION BY h.cod_dw_persona_ubic
                              ORDER BY g.id_unificacion DESC, g.cod_dw_persona_ubic) AS rn
    FROM bdm_tempo.stg_regla3_scored h
    JOIN bdm_tempo.stg_regla3_ganador g
      ON  g.id_u               = h.id_u
     AND  g.id_buro_persona    = h.id_buro_persona
     AND  g.cod_dw_municipio   = h.cod_dw_municipio
     AND  g.tipo_via_principal = h.tipo_via_principal
     AND  g.via_principal_cmp  = h.via_principal_cmp
     AND  g.cod_dw_persona_ubic <> h.cod_dw_persona_ubic
     AND  h.id_unificacion     <= g.id_unificacion
     AND  ( ( h.id_u = 1
              AND g.numero_puerta_num  = h.numero_puerta_num
              AND g.via_generadora_cmp <> h.via_generadora_cmp )
         OR ( h.id_u = 2
              AND g.via_generadora_cmp = h.via_generadora_cmp
              AND g.numero_puerta_num <> h.numero_puerta_num ) )
  ) r
  WHERE rn = 1;

  -- Persistencia condicional al modo (Tarea 6.1, Req 5.1..5.6).
  -- 1) Materializar el resultado de la regla (SELECT DISTINCT, Req 5.5).
  --
  -- unifica_atributos = 3 y no el 1 del legado (Vstg_Unificacion_tres sella
  -- '1 AS UNIFICA_ATRIBUTOS', el mismo valor que la Regla 1). Es una mejora
  -- deliberada de trazabilidad, ya documentada: con el 1 del legado no se
  -- puede saber que regla produjo una pareja, y la guia de QA habla
  -- explicitamente de "unificaciones tipo 3".
  DROP TABLE IF EXISTS bdm_tempo.sp_unificacion_r3_esc1_geo_misma_via_puerta_cercana_persist;
  CREATE TABLE bdm_tempo.sp_unificacion_r3_esc1_geo_misma_via_puerta_cercana_persist
  DISTSTYLE KEY DISTKEY(cod_dw_persona_ubic)
  AS
  SELECT DISTINCT
    cod_dw_persona_ubic AS cod_dw_persona_ubic,
    id_padre AS cod_dw_direccion_unificada,
    3 AS unifica_atributos,
    CURRENT_DATE AS fecha_unificacion,
    p_lote /* Lote_Corrida externo */ AS lote,
    1 AS severidad,
    LEFT(CURRENT_USER,30) AS usuario_bd
  FROM bdm_tempo.stg_regla3_final;

  IF p_modo = 'FULL' THEN
    -- FULL: el TRUNCATE lo hizo el orquestador una vez al inicio de la corrida.
    -- Se usa INSERT FOR MISSING (el mismo NOT EXISTS del Modo_Delta) y NO un
    -- INSERT plano: dentro de una misma corrida FULL dos escenarios distintos
    -- pueden producir la MISMA Clave_Unificacion, y el INSERT plano dejaba la
    -- pareja DUPLICADA -- justo lo que vigila el gate unicidad_clave_unificacion.
    -- El legado Teradata aplica el upsert de forma uniforme, sin distinguir
    -- carga inicial: gana el primer escenario que produce la pareja.
    INSERT INTO bdm_datos.unificacion_direccion
      (cod_dw_persona_ubic, cod_dw_direccion_unificada, unifica_atributos, fecha_unificacion, lote, severidad, usuario_bd)
    SELECT DISTINCT s.cod_dw_persona_ubic, s.cod_dw_direccion_unificada, s.unifica_atributos,
           s.fecha_unificacion, s.lote, s.severidad, s.usuario_bd
    FROM bdm_tempo.sp_unificacion_r3_esc1_geo_misma_via_puerta_cercana_persist s
    WHERE NOT EXISTS (
      SELECT 1
      FROM bdm_datos.unificacion_direccion u
      WHERE u.cod_dw_persona_ubic = s.cod_dw_persona_ubic
        AND u.cod_dw_direccion_unificada = s.cod_dw_direccion_unificada);
  ELSE
    -- DELTA UPSERT fiel al legado Teradata (SLCOPRBA-1355).
    -- Patron 'INSERT FOR MISSING UPDATE ROWS' de
    -- P0020_UNIFICACION_DIRECCION_130.TPT (STEP Load_UNIFICACION_DIRECCION):
    -- UPDATE de las filas que ya existen con la misma Clave_Unificacion e
    -- INSERT de las que faltan. El UPDATE no reescribe 'lote' (identifica la
    -- corrida que CREO la unificacion) ni 'unifica_atributos'; solo sella
    -- lote_actualizacion / fecha_modificacion / usuario_bd.
    -- NOTA Redshift: en UPDATE ... FROM la tabla destino NO admite alias.
    UPDATE bdm_datos.unificacion_direccion
       SET lote_actualizacion = p_lote,
           fecha_modificacion = CURRENT_DATE,
           usuario_bd         = CURRENT_USER
      FROM bdm_tempo.sp_unificacion_r3_esc1_geo_misma_via_puerta_cercana_persist s
     WHERE bdm_datos.unificacion_direccion.cod_dw_persona_ubic = s.cod_dw_persona_ubic
       AND bdm_datos.unificacion_direccion.cod_dw_direccion_unificada = s.cod_dw_direccion_unificada;

    INSERT INTO bdm_datos.unificacion_direccion
      (cod_dw_persona_ubic, cod_dw_direccion_unificada, unifica_atributos, fecha_unificacion, lote, severidad, usuario_bd)
    SELECT DISTINCT s.cod_dw_persona_ubic, s.cod_dw_direccion_unificada, s.unifica_atributos,
           s.fecha_unificacion, s.lote, s.severidad, s.usuario_bd
    FROM bdm_tempo.sp_unificacion_r3_esc1_geo_misma_via_puerta_cercana_persist s
    WHERE NOT EXISTS (
      SELECT 1
      FROM bdm_datos.unificacion_direccion u
      WHERE u.cod_dw_persona_ubic = s.cod_dw_persona_ubic
        AND u.cod_dw_direccion_unificada = s.cod_dw_direccion_unificada);
  END IF;

  DROP TABLE IF EXISTS bdm_tempo.sp_unificacion_r3_esc1_geo_misma_via_puerta_cercana_persist;

  -- stg_regla3_insumo, stg_regla3_pares y stg_regla3_scored NO se borran: son
  -- la evidencia que QA consulta para los criterios de R3 (que entro al
  -- insumo, que se emparejo y con que puntaje). El siguiente CALL las recrea
  -- con el DROP de arriba, de modo que no hay estado que se arrastre.
  DROP TABLE IF EXISTS bdm_tempo.stg_regla3_ganador;
  DROP TABLE IF EXISTS bdm_tempo.stg_regla3_final;

END;
$$;
-- SLCOPRBA-1355: puerto del legado P0021_UNIFICACION_111.BTQ
