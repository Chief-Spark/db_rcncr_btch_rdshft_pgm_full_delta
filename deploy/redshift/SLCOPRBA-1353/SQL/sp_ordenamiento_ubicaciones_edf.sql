-- ============================================================
-- sp_ordenamiento_ubicaciones_edf.sql
-- SLCOPRBA-1355: FASE 3 del Ordenamiento -- deteccion de cambios por hash.
-- Legado: PRO_ORD_CONCAT_DIRECCIONES (arma el concatena y el MD5) y
-- PRO_ORD_FINAL_UBIC_DIRECCIONES (persiste en UBICACION_ATRIBUTO_HASH).
-- Copia del legado en dt/docs/legado_ordenamiento_f1_f3/.
-- Criterios F3-03..F3-07. UTF-8 sin BOM, ASCII sin acentos.
--
-- ------------------------------------------------------------
-- EL LEGADO SE CONTRADICE A SI MISMO Y HAY QUE SABERLO ANTES DE LEER ESTO.
--
-- Existen DOS versiones del mismo paso:
--   PRO_ORD_FINAL_UBIC_DIRECCIONES   -- el UPDATE esta COMENTADO
--   PRO_ORD_FINAL_UBIC_DIRECCIONES1  -- el UPDATE esta vivo
--
-- El comentario que lo desactiva no es casual ni es basura de edicion:
-- "Por solicitud de Experian se deja en comentario esta parte del codigo
-- Puesto no se va a necesitar" (FINAL_UBIC_DIRECCIONES.sql:216), y la MISMA
-- frase aparece en FINAL_CTA_ATRIBUTOS.sql:200, que es la tabla de hash de la
-- Fase 2. Dos archivos distintos, la misma decision: es una peticion real del
-- negocio, no un descuido.
--
-- Ademas, de los dos solo FINAL_UBIC_DIRECCIONES lleva entrada de bitacora de
-- mantenimiento (2018-09-26, "Se agrega IN P_VARQUERY"), lo que apunta a que
-- es el vigente y el otro una copia.
--
-- SE PORTA LA VERSION SIN UPDATE: la tabla es INSERT-ONLY.
-- NO es prueba cerrada -- el CALL vive en la malla, que no esta en el
-- material entregado --, y por eso queda escrito aqui. Si aparece la malla,
-- se revisa contra ella.
--
-- CONSECUENCIA, Y ES LA QUE CAMBIA UN CRITERIO: una direccion que cambia NO
-- actualiza su fila, deja una SEGUNDA con el hash nuevo. F3-06 dice "los
-- registros modificados se deben actualizar", y esa rama es codigo muerto en
-- el AS-IS. Es el mismo caso de NOV-UB-13 y NOV-UB-15 en Novedades, que
-- verificaban una rama que el legado no puede tomar: el criterio se evalua
-- contra la paridad REAL -- el cambio queda registrado y la fila anterior no
-- se toca -- y no contra una conducta que Teradata no ejecuta.
--
-- LA LLAVE DEL ANTI-JOIN SON CUATRO COLUMNAS, LA DE LA ENTIDAD TRES.
-- F3-07 nombra tres: cod_pin_persona, id_buro_persona, cod_dw_persona_ubic.
-- El hash es la cuarta del anti-join, la que decide si la COMBINACION es
-- nueva. Confundirlas haria que una direccion cambiada no se registrara.
--
-- EL CONCATENA DEL LEGADO TIENE DOCE COLUMNAS Y AQUI HAY SIETE CON DATO.
-- Las otras cinco van con el centinela ''0'' del propio legado, que es lo que
-- este usa para un nulo. Se mantienen EN SU SITIO y en el ORDEN original para
-- que el dia que el dato exista el hash cambie en una sola linea y se vea en
-- el diff. Las cinco, y por que:
--   descripcion_gestion_registro -- la nuestra es una sintesis heuristica, no
--                                   el estado de gestion por reporte
--   desc_tipo_cta                -- necesita las cuentas de la Fase 2
--   urbanizacion_barrio          -- no existe en nuestro modelo
--   cod_dane_departamento        -- solo esta en el mock, no en el datashare
--   (las coordenadas SI entran: salen de la ubicacion estandarizada)
--
-- EL MD5 NO PUEDE LEER EL ALIAS 'concatena' DE SU PROPIO SELECT. El legado
-- escribe rec_vista.hash_md5(concatena) referenciando el alias de la columna
-- de al lado; Teradata lo resuelve y Redshift NO -- la misma trampa que
-- FLAG_OP en Novedades (Novedad.sql:8392-8396). Por eso el concatena se arma
-- en una subconsulta y el MD5 se aplica fuera.
--
-- NONATOMIC (leccion #13). Sin parametros: lo llama el ciclo, que ya resolvio
-- modo, lote y watermark. Rollback: DROP PROCEDURE con firma exacta (#12/#14).
-- ============================================================

CREATE OR REPLACE PROCEDURE bdm_datos.sp_ordenamiento_ubicaciones_edf(
  p_lote INTEGER
)
NONATOMIC
LANGUAGE plpgsql
AS $$
BEGIN

  DROP TABLE IF EXISTS bdm_tempo.stg_ord_ubic_hash;

  -- Una fila por direccion del alcance, con su tipo de persona y su MD5.
  --
  -- tipo_persona (F3-03) sale de cod_tipo_ident_fte, que es lo que tenemos:
  -- el legado lo toma de V_Tipo_persona por Cod_DW_Tipo_Persona, un catalogo
  -- que no esta en el datashare. NIT es juridica; el resto, natural. El
  -- COALESCE final evita el NULL que F3-03 prohibe.
  CREATE TABLE bdm_tempo.stg_ord_ubic_hash
  DISTSTYLE KEY
  DISTKEY (cod_dw_persona_ubic)
  SORTKEY (id_buro_persona, cod_dw_persona_ubic)
  AS
  SELECT x.cod_pin_persona,
         x.id_buro_persona,
         x.cod_dw_persona_ubic,
         x.tipo_persona,
         MD5(x.concatena) AS cod_hash
  FROM (
    SELECT d.cod_pin_persona,
           d.id_buro_persona,
           d.cod_dw_persona_ubic,
           COALESCE( CASE WHEN UPPER(TRIM(COALESCE(rpu.cod_tipo_ident_fte, ''))) IN ('2', 'NIT')
                          THEN 'JURIDICA' ELSE 'NATURAL' END, 'NATURAL') AS tipo_persona,
           -- Orden y centinela del legado (PRO_ORD_CONCAT_DIRECCIONES:108-120).
                 COALESCE(CAST(TRIM(d.direccion_fisica) AS VARCHAR(100)), '0')
              || COALESCE(CAST(TRIM(d.tipo_ubicacion)   AS VARCHAR(200)), '0')
              || '0'                                      -- gestion_registro
              || COALESCE(CAST(TRIM(CAST(d.cod_dane_ciudad AS VARCHAR)) AS VARCHAR(20)), '0')
              || '0'                                      -- dane_departamento
              || COALESCE(CAST(TRIM(CASE WHEN UPPER(TRIM(COALESCE(rpu.cod_tipo_ident_fte, ''))) IN ('2', 'NIT')
                                         THEN 'JURIDICA' ELSE 'NATURAL' END) AS VARCHAR(500)), '0')
              || '0'                                      -- desc_tipo_cta
              || COALESCE(CAST(TRIM(d.direccion_fisica) AS VARCHAR(201)), '0')
              || COALESCE(CAST(TRIM(d.complemento)      AS VARCHAR(100)), '0')
              || '0'                                      -- urbanizacion_barrio
              || COALESCE(CAST(TRIM(CAST(ue.latitud  AS VARCHAR)) AS VARCHAR(50)), '0')
              || COALESCE(CAST(TRIM(CAST(ue.longitud AS VARCHAR)) AS VARCHAR(50)), '0')
             AS concatena
      FROM bdm_tempo.stg_insumo_direccion d
      INNER JOIN bdm_tempo.stg_rpu_post_unificacion r
              ON r.cod_dw_persona_ubic = d.cod_dw_persona_ubic
      LEFT JOIN bdm_tempo.v_xpm_relacion_persona_ubicacion rpu
             ON rpu.cod_dw_persona_ubic = d.cod_dw_persona_ubic
      LEFT JOIN bdm_tempo.v_xpm_ubicacion_estandarizada ue
             ON ue.cod_dw_ubic = r.cod_dw_ubic
  ) x
  GROUP BY x.cod_pin_persona, x.id_buro_persona, x.cod_dw_persona_ubic,
           x.tipo_persona, x.concatena;

  ANALYZE bdm_tempo.stg_ord_ubic_hash;

  -- F3-05. Lo nuevo entra. El anti-join lleva las CUATRO columnas, hash
  -- incluido (PRO_ORD_FINAL_UBIC_DIRECCIONES:125-133): una direccion cuyo
  -- hash cambio no encuentra pareja y entra como fila nueva, que es como el
  -- AS-IS registra el cambio.
  INSERT INTO bdm_datos.ubicacion_atributo_hash
    (cod_pin_persona, id_buro_persona, cod_dw_persona_ubic,
     cod_dw_hash, fecha_nov, tipo_persona, lote, usuario_bd)
  SELECT a.cod_pin_persona, a.id_buro_persona, a.cod_dw_persona_ubic,
         a.cod_hash, CURRENT_DATE, a.tipo_persona, p_lote, CURRENT_USER
    FROM bdm_tempo.stg_ord_ubic_hash a
    LEFT JOIN bdm_datos.ubicacion_atributo_hash b
           ON  b.cod_pin_persona     = a.cod_pin_persona
           AND b.id_buro_persona     = a.id_buro_persona
           AND b.cod_dw_persona_ubic = a.cod_dw_persona_ubic
           AND b.cod_dw_hash         = a.cod_hash
   WHERE b.cod_dw_persona_ubic IS NULL;

END;
$$;
