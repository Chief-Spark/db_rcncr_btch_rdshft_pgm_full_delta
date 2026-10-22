-- ============================================================
-- sp_ordenamiento_preparar_insumos_mock.sql
-- Staging TEMPORAL por corrida: 1 lectura mock bdm_stage -> tablas stg_* locales.
-- No persiste entre ejecuciones (drop al final del ciclo).
--
-- FASE A DEL RECABLEADO (SLCOPRBA-1355): YA NO PRODUCE LOS CUATRO INSUMOS DE
-- CANAL. stg_insumo_direccion, _telefono, _celular y _email los crea ahora
-- sp_ordenamiento_ubicaciones_mock, que es la Fase 3, porque es lo que hace el
-- legado: el scoring de Teradata no lee el datashare, lee las vistas de
-- DIRECCIONES_TEMP que deja PRO_ORD_CALC_UBICACIONES_2.sql:1234.
--
-- Lo que queda aqui es lo que de verdad es de la Fase 1 y su staging crudo:
-- el alcance por lote/watermark, stg_ord_alcance_origen, y las tablas de las
-- que los insumos se derivan (stg_rpu_post_unificacion, stg_contacto_canal,
-- stg_contacto_direccion_rpu, stg_reporte_rpu y las de referencia).
-- ============================================================

CREATE OR REPLACE PROCEDURE bdm_datos.sp_ordenamiento_preparar_insumos_mock(
  p_modo      VARCHAR,   -- FULL | DELTA (modo efectivo)
  p_lote      INTEGER,   -- Lote_Corrida externo (no asumir 1)
  p_watermark DATE       -- frontera inferior inclusiva DELTA (NULL en Bootstrap FULL)
)
NONATOMIC
LANGUAGE plpgsql
AS $$
BEGIN
  -- Limpieza staging previo
  DROP TABLE IF EXISTS bdm_tempo.stg_contacto_canal;
  DROP TABLE IF EXISTS bdm_tempo.stg_reporte_rpu;
  DROP TABLE IF EXISTS bdm_tempo.stg_contacto_direccion_rpu;
  DROP TABLE IF EXISTS bdm_tempo.stg_persona_dir_ref;
  DROP TABLE IF EXISTS bdm_tempo.stg_rpu_dir_ref;
  DROP TABLE IF EXISTS bdm_tempo.stg_dir_conteo_persona;
  DROP TABLE IF EXISTS bdm_tempo.stg_persona_dir_ganadora;
  DROP TABLE IF EXISTS bdm_tempo.stg_rpu_post_unificacion;
  DROP TABLE IF EXISTS bdm_tempo.stg_ord_personas_alcance;
  DROP TABLE IF EXISTS bdm_tempo.stg_ord_alcance_origen;

  -- Universo de personas a (re)ordenar.
  -- FULL: todas las personas con RPU en el datashare.
  -- DELTA: personas tocadas por ventana RPU o por unificacion del lote/fecha
  --        (tabla acumulada; NO asumir TRUNCATE ni lote=1).
  CREATE TABLE bdm_tempo.stg_ord_personas_alcance
  DISTSTYLE KEY
  DISTKEY (id_buro_persona)
  SORTKEY (id_buro_persona)
  AS
  SELECT DISTINCT x.id_buro_persona
  FROM (
    SELECT rpu.id_buro_persona
    FROM bdm_tempo.v_mock_relacion_persona_ubicacion rpu
    WHERE COALESCE(p_modo, 'FULL') = 'FULL'
       OR rpu.fecha_relacion_persona_ubicaci >= p_watermark
       OR rpu.fecha_relacion_persona_ubicaci IS NULL
    UNION
    SELECT rpu.id_buro_persona
    FROM bdm_tempo.v_mock_relacion_persona_ubicacion rpu
    INNER JOIN bdm_datos.unificacion_direccion_mock u
      ON u.cod_dw_persona_ubic = rpu.cod_dw_persona_ubic
    WHERE COALESCE(p_modo, 'FULL') = 'DELTA'
      AND (
            -- SLCOPRBA-1355: desde el UPSERT fiel al legado, 'lote' es INMUTABLE
            -- (identifica la corrida que CREO la unificacion) y 'fecha_unificacion'
            -- tampoco se reescribe al re-unificar. El re-toque de una pareja
            -- existente se registra en lote_actualizacion / fecha_modificacion.
            -- Sin estos dos predicados, una persona re-tocada por el Modo_Delta
            -- quedaria FUERA del alcance del Ordenamiento y no se re-puntuaria.
            u.lote = p_lote
         OR u.lote_actualizacion = p_lote
         OR (p_watermark IS NOT NULL AND u.fecha_unificacion >= p_watermark)
         OR (p_watermark IS NOT NULL AND u.fecha_modificacion >= p_watermark)
          )
    UNION
    -- SLCOPRBA-1355: la tercera rama, el modelo BTT. Ver la nota extensa en
    -- stg_ord_alcance_origen, mas abajo.
    SELECT c.id_buro_persona
    FROM bdm_tempo.v_mock_cuenta c
    WHERE COALESCE(p_modo, 'FULL') = 'DELTA'
      AND p_watermark IS NOT NULL
      AND c.fecha_nov >= p_watermark
  ) x;

  ANALYZE bdm_tempo.stg_ord_personas_alcance;

  -- ------------------------------------------------------------
  -- SLCOPRBA-1355 -- Fase 1: por que rama entro cada persona.
  --
  -- TABLA APARTE, Y NO UNA COLUMNA EN stg_ord_personas_alcance. Una persona
  -- puede entrar por las DOS ramas; si el origen viviera en el alcance, el
  -- SELECT DISTINCT dejaria de dar una fila por persona y cada INNER JOIN de
  -- los insumos se multiplicaria. Es el mismo fan-out que ya se pago al
  -- derivar la clase de ubicacion de v_xpm_contacto_canal.
  --
  -- NADIE LA UNE: la lee solo el censo de alcance, que la agrega antes de que
  -- sp_ordenamiento_drop_staging_edf borre el staging. Sin ella los criterios
  -- F1-01, F1-02 y F1-08 no tienen con que desglosar las ramas, y un criterio
  -- que no las separa deja pasar una rama vacia -- la leccion de NOV-UB-12.
  --
  -- En FULL todo entra por UBICACION: la rama de unificacion exige
  -- p_modo = 'DELTA' y no se evalua.
  -- ------------------------------------------------------------
  CREATE TABLE bdm_tempo.stg_ord_alcance_origen
  DISTSTYLE KEY
  DISTKEY (id_buro_persona)
  SORTKEY (id_buro_persona)
  AS
  SELECT rpu.id_buro_persona,
         CAST('UBICACION' AS VARCHAR(20)) AS origen
  FROM bdm_tempo.v_mock_relacion_persona_ubicacion rpu
  WHERE COALESCE(p_modo, 'FULL') = 'FULL'
     OR rpu.fecha_relacion_persona_ubicaci >= p_watermark
     OR rpu.fecha_relacion_persona_ubicaci IS NULL
  UNION ALL
  SELECT rpu.id_buro_persona,
         CAST('UNIFICACION' AS VARCHAR(20))
  FROM bdm_tempo.v_mock_relacion_persona_ubicacion rpu
  INNER JOIN bdm_datos.unificacion_direccion_mock u
    ON u.cod_dw_persona_ubic = rpu.cod_dw_persona_ubic
  WHERE COALESCE(p_modo, 'FULL') = 'DELTA'
    AND (
          u.lote = p_lote
       OR u.lote_actualizacion = p_lote
       OR (p_watermark IS NOT NULL AND u.fecha_unificacion >= p_watermark)
       OR (p_watermark IS NOT NULL AND u.fecha_modificacion >= p_watermark)
        )
  UNION ALL
  -- SLCOPRBA-1355 -- LA TERCERA RAMA: el modelo BTT.
  --
  -- PRO_ORD_MATERIALIZA_BTT existe justamente para esto: meter al universo a
  -- la persona a la que le cambio una CUENTA, no una direccion. Nuestro
  -- alcance no la tenia, y por eso F1-01 salia BLOQUEADO citando que no habia
  -- tabla de cuentas contra la que mirar. Con el contrato de la Fase 2 ya
  -- existe, y el censo llena por_cuenta en vez de dejarlo en NULL.
  --
  -- EN FULL NO SE EVALUA, igual que la de unificacion: entra el universo
  -- entero por la rama de ubicacion.
  SELECT c.id_buro_persona,
         CAST('CUENTA' AS VARCHAR(20))
  FROM bdm_tempo.v_mock_cuenta c
  WHERE COALESCE(p_modo, 'FULL') = 'DELTA'
    AND p_watermark IS NOT NULL
    AND c.fecha_nov >= p_watermark
  ;

  ANALYZE bdm_tempo.stg_ord_alcance_origen;

  -- 1) RPU post-unificacion (sin join orden_prioridad -- evita fan-out en staging)
  CREATE TABLE bdm_tempo.stg_rpu_post_unificacion
  DISTSTYLE KEY
  DISTKEY (id_buro_persona)
  SORTKEY (cod_dw_persona_ubic)
  AS
  SELECT
    rpu.cod_dw_persona_ubic,
    rpu.cod_pin_persona,
    rpu.id_buro_persona,
    rpu.cod_dw_ubic,
    CAST(NULL AS INTEGER) AS orden_prioridad,
    rpu.fecha_relacion_persona_ubicaci,
    CASE WHEN u.cod_dw_persona_ubic IS NOT NULL THEN 1 ELSE 0 END AS ind_unificacion
  FROM bdm_tempo.v_mock_relacion_persona_ubicacion rpu
  INNER JOIN bdm_tempo.stg_ord_personas_alcance alc
    ON alc.id_buro_persona = rpu.id_buro_persona
  LEFT JOIN bdm_datos.unificacion_direccion_mock u
    ON u.cod_dw_persona_ubic = rpu.cod_dw_persona_ubic
  -- SLCOPRBA-1355 -- F3-01: las direcciones bloqueadas NO se ordenan.
  --
  -- Faltaba, y el catalogo de criterios ya lo decia en redondo: "NO existe
  -- filtro de bloqueo en el Ordenamiento de Redshift". Medido en el banco
  -- antes de ponerlo: las 100 bloqueadas del ARQ 59 llegaban al hash de la
  -- Fase 3 y al scoring.
  --
  -- El legado lo hace con un ANTI-JOIN contra la tabla bloqueo
  -- (Prc_Ordenamiento2.sql:1122-1126), no con un filtro de fila, de modo que
  -- excluye el cod_dw_persona_ubic ENTERO. En el mock da igual porque el id
  -- es unico por construccion, pero en el datashare NO lo es -- 568.657 filas
  -- para 142.067 ids -- y ahi la diferencia importa: es la misma que ya costo
  -- una divergencia en la etapa 1 de Novedades. Por eso excluye el id entero
  -- y no es un COALESCE(rpu.bloqueado, 0) = 0.
  --
  -- Y VA COMO LEFT JOIN CONTRA UN SELECT DISTINCT, NO COMO NOT EXISTS
  -- (job DEV/DATABASE #458). El NOT EXISTS correlacionado contra una vista
  -- del datashare -- que a su vez lleva subconsultas -- Redshift no lo
  -- descorrelaciona y lo RECHAZA en ejecucion:
  --   XX000: This type of correlated subquery pattern is not supported
  -- Tumbo la via real entera: sin stg_rpu_post_unificacion no hay
  -- Ordenamiento, y sin orden_prioridad Novedades entra con cero relaciones.
  -- El mock no lo sufria porque v_mock_relacion_persona_ubicacion es una
  -- vista plana sobre una tabla, de modo que el tablero daba verde mientras
  -- la via real no arrancaba. Es la trampa que CLAUDE.md ya documentaba, en
  -- sitio nuevo. El anti-join no correlacionado es equivalente y Redshift lo
  -- planifica sin problema; se aplica a las DOS vias para no romper paridad.
  LEFT JOIN ( SELECT DISTINCT bl.cod_dw_persona_ubic
                FROM bdm_tempo.v_mock_relacion_persona_ubicacion bl
               WHERE COALESCE(bl.bloqueado, 0) = 1 ) blq
    ON blq.cod_dw_persona_ubic = rpu.cod_dw_persona_ubic
  WHERE blq.cod_dw_persona_ubic IS NULL
  ;

  ANALYZE bdm_tempo.stg_rpu_post_unificacion;

  -- 2) Personas ganadoras (broadcast pequeno)
  CREATE TABLE bdm_tempo.stg_persona_dir_ganadora
  DISTSTYLE ALL
  SORTKEY (id_buro_persona)
  AS
  SELECT DISTINCT id_buro_persona
  FROM bdm_tempo.stg_rpu_post_unificacion
  WHERE COALESCE(ind_unificacion, 0) <> 1;

  ANALYZE bdm_tempo.stg_persona_dir_ganadora;

  -- 3) Conteo direcciones por persona (pre-agregado para DIR)
  CREATE TABLE bdm_tempo.stg_dir_conteo_persona
  DISTSTYLE KEY
  DISTKEY (id_buro_persona)
  SORTKEY (id_buro_persona)
  AS
  SELECT
    r2.id_buro_persona,
    COUNT(DISTINCT cd2.texto_ubicacion) AS conteo_direcciones
  FROM bdm_tempo.stg_rpu_post_unificacion r2
  INNER JOIN bdm_tempo.v_mock_contacto_direccion cd2
    ON cd2.cod_dw_persona_ubic = r2.cod_dw_persona_ubic
  WHERE COALESCE(r2.ind_unificacion, 0) <> 1
  GROUP BY 1;

  ANALYZE bdm_tempo.stg_dir_conteo_persona;

  -- 4) Referencia direccion por persona (TEL/CEL)
  CREATE TABLE bdm_tempo.stg_persona_dir_ref
  DISTSTYLE KEY
  DISTKEY (id_buro_persona)
  SORTKEY (id_buro_persona)
  AS
  SELECT
    r.id_buro_persona,
    MIN(u.texto_ubicacion) AS dir_ref
  FROM bdm_tempo.stg_rpu_post_unificacion r
  INNER JOIN bdm_tempo.v_mock_ubicacion_estandarizada u
    ON r.cod_dw_ubic = u.cod_dw_ubic
  WHERE COALESCE(r.ind_unificacion, 0) <> 1
  GROUP BY 1;

  ANALYZE bdm_tempo.stg_persona_dir_ref;

  -- 4b) Referencia de direccion POR RPU, no por persona.
  --
  -- POR QUE EXISTE ESTA TABLA Y NO BASTA stg_persona_dir_ref:
  --   el canal TEL agrupa por direccion_fisica
  --   (sp_ordenamiento_scoring_tel_edf.sql:58), y si esa columna sale de un
  --   agregado POR PERSONA entonces todos los telefonos de una persona caen
  --   en el MISMO grupo: una sola fila de score, lugar = 1 siempre, y nada
  --   que ordenar. El canal pierde su funcion, que es elegir entre los
  --   telefonos de una persona cual es mas contactable.
  --
  --   El legado agrupa por la direccion fisica DE CADA FILA DE REPORTE
  --   (Caracteristicas.txt, GROUP BY Cod_Pin_Persona, Id_Buro_Persona,
  --   Direccion_Fisica), de modo que una persona con N direcciones produce N
  --   grupos. Esta tabla restaura ese grano.
  --
  --   Arrastraba ademas cinco caracteristicas: TEL001, TEL006, TEL010,
  --   TEL023 y TEL025 son en el legado cuotas del grupo contra el total de
  --   la persona, y con grupo = persona valen trivialmente 100 o 0.
  --
  -- stg_persona_dir_ref se CONSERVA: la sigue usando el insumo de CEL, donde
  -- alimenta una bandera de nivel persona (CEL023). Esa caracteristica tiene
  -- su propia divergencia con el legado y se trata aparte.
  CREATE TABLE bdm_tempo.stg_rpu_dir_ref
  DISTSTYLE KEY
  DISTKEY (cod_dw_persona_ubic)
  SORTKEY (cod_dw_persona_ubic)
  AS
  SELECT
    r.cod_dw_persona_ubic,
    MIN(u.texto_ubicacion) AS dir_ref
  FROM bdm_tempo.stg_rpu_post_unificacion r
  INNER JOIN bdm_tempo.v_mock_ubicacion_estandarizada u
    ON r.cod_dw_ubic = u.cod_dw_ubic
  WHERE COALESCE(r.ind_unificacion, 0) <> 1
  GROUP BY 1;

  ANALYZE bdm_tempo.stg_rpu_dir_ref;

  -- 5) Contacto direccion solo RPUs ganadoras (1 pasada datashare)
  CREATE TABLE bdm_tempo.stg_contacto_direccion_rpu
  DISTSTYLE KEY
  DISTKEY (id_buro_persona)
  SORTKEY (cod_dw_persona_ubic)
  AS
  SELECT cd.*
  FROM bdm_tempo.v_mock_contacto_direccion cd
  INNER JOIN bdm_tempo.stg_rpu_post_unificacion rpu
    ON rpu.cod_dw_persona_ubic = cd.cod_dw_persona_ubic
   AND COALESCE(rpu.ind_unificacion, 0) <> 1;

  ANALYZE bdm_tempo.stg_contacto_direccion_rpu;

  -- 6) Reportes solo RPUs ganadoras
  CREATE TABLE bdm_tempo.stg_reporte_rpu
  DISTSTYLE KEY
  DISTKEY (id_buro_persona)
  SORTKEY (cod_dw_persona_ubic)
  AS
  SELECT
    rep.cod_dw_persona_ubic,
    rep.id_buro_suscriptor,
    rep.cod_suscriptor,
    rep.fecha_reporte,
    rpu.id_buro_persona
  FROM bdm_tempo.v_mock_reporte_relacion_persona_ubica rep
  INNER JOIN bdm_tempo.stg_rpu_post_unificacion rpu
    ON rpu.cod_dw_persona_ubic = rep.cod_dw_persona_ubic
   AND COALESCE(rpu.ind_unificacion, 0) <> 1;

  ANALYZE bdm_tempo.stg_reporte_rpu;

  -- 7) Contactos canal TEL/CEL/EMA -- solo personas ganadoras
  -- SLCOPRBA-1355: filtro de hijas a grano de RPU, no de PERSONA.
  --
  -- EL DEFECTO. El unico filtro de unificacion de esta rama era el INNER JOIN
  -- a stg_persona_dir_ganadora, que es DISTINCT id_buro_persona de las RPU no
  -- hijas. A una persona con AL MENOS UNA RPU no hija le pasaban TODAS sus
  -- filas de contacto, hijas incluidas -- y los insumos de TEL, CEL y EMA
  -- toman c.cod_dw_persona_ubic de aqui sin volver a mirar ind_unificacion.
  -- Resultado medido en el banco local: 9000 hijas con score en cada uno de
  -- los tres canales, y DIR en cero. Esperado 0 (criterios F4-07, RG-05,
  -- CA-F02 del RF).
  --
  -- DIR no lo sufria porque arranca de stg_rpu_post_unificacion y vuelve a
  -- asertar el predicado sobre ESE MISMO alias. Esto le da a los canales la
  -- misma proteccion, en un solo sitio, y los tres insumos la heredan.
  --
  -- LEFT JOIN y no INNER a proposito: INNER exigiria que la RPU del contacto
  -- este en la tabla, que ademas esta acotada al alcance de la corrida, y eso
  -- descartaria contactos por una razon distinta de la que se quiere. Con
  -- COALESCE se cae SOLO lo que se sabe hija.
  --
  -- stg_persona_dir_ganadora se queda: cumple su propio proposito -- que la
  -- persona tenga una direccion ganadora -- y este filtro es adicional.
  --
  -- PENDIENTE DE NEGOCIO, anotado y no decidido aqui: un telefono reportado en
  -- una RPU que la Unificacion absorbio sigue siendo un telefono valido. Esto
  -- lo descarta, que es lo que pide el RF y lo coherente con DIR. Si negocio
  -- prefiere re-apuntarlo a la direccion padre, es otro cambio.
  CREATE TABLE bdm_tempo.stg_contacto_canal
  DISTSTYLE KEY
  DISTKEY (id_buro_persona)
  SORTKEY (id_buro_persona, contact_type)
  AS
  SELECT c.*
  FROM bdm_tempo.v_mock_contacto_canal c
  INNER JOIN bdm_tempo.stg_persona_dir_ganadora pg
    ON pg.id_buro_persona = c.id_buro_persona
  LEFT JOIN bdm_tempo.stg_rpu_post_unificacion rpu
    ON rpu.cod_dw_persona_ubic = c.cod_dw_persona_ubic
  WHERE COALESCE(rpu.ind_unificacion, 0) <> 1;

  ANALYZE bdm_tempo.stg_contacto_canal;

END;
$$;
-- SLCOPRBA-1355: espejo mock generado desde sp_ordenamiento_preparar_insumos_edf.sql
