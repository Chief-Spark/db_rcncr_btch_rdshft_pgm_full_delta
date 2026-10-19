-- ============================================================
-- sp_ordenamiento_cuentas_edf.sql
-- SLCOPRBA-1355: FASE 2 del Ordenamiento -- Atributos de Cuenta.
-- Legado: PRO_ORD_CTA_ATRIBUTOS, PRO_ORD_CTA_TOTALES_PERSONAS{,_1,_2},
-- PRO_ORD_CONCAT_ATRIBUTOS y PRO_ORD_FINAL_CTA_ATRIBUTOS, en
-- dt/docs/legado_ordenamiento_f1_f3/. Criterios F2-01..08 y F2-10.
-- UTF-8 sin BOM, ASCII sin acentos.
--
-- ------------------------------------------------------------
-- HAY DOS COLUMNAS DE PORTAFOLIO Y ESTA PORTA LA QUE NO ESTABA.
--
--   Portafolio_Nuevo -- 20 lineas sobre el prefijo del cod_suscriptor, decide
--     el Sector. YA estaba portada, en sp_ordenamiento_preparar_insumos_edf,
--     con catalogo en 23_ddl_catalogo_portafolio_ord.sql. Da ONCE valores.
--   Portafolio -- la de F2-05. Un CASE anidado de 179 lineas
--     (PRO_ORD_CTA_TOTALES_PERSONAS_2.sql:304-375) sobre NUEVE columnas.
--
-- Confundirlas cuesta el port entero: ya paso una vez al planificar.
--
-- EL CASE PRODUCE UN DECIMO VALOR QUE EL CRITERIO NO NOMBRA: ''--''.
-- F2-05 enumera nueve -- CO, RO, VE, HP, IN, OT, CC, AH, CT -- y dice que no
-- puede haber valores fuera del catalogo. El legado alcanza ''--'' cuando el
-- comportamiento es PASIVO y el tipo de cuenta no es 1 (:308-313): no es NULL,
-- es un centinela. Se porta LITERAL (regla 4) y el evaluador lo cuenta aparte,
-- que es la unica forma de que el tablero no mienta en ninguna de las dos
-- direcciones.
--
-- LA VENTANA DE 12 MESES ES POR CUENTA, NO POR CORRIDA. El ancla es la
-- fecha_nov de CADA cuenta: add_months(fecha_nov, -12)
-- (PRO_ORD_CTA_TOTALES_PERSONAS.sql:93). Tomarla de la fecha de proceso seria
-- el mismo defecto que el #409 dejo en Novedades.
--
-- LAS BANDERAS SON "EXISTE FILA", NO UN DATO. El legado las deriva con dos
-- LEFT JOIN contra STG_COMPORTAMIENTO_CTA_ACTIVO y _PASIVO:
-- CASE WHEN h.cod_dw_cta IS NOT NULL THEN ''Y'' ELSE ''N'' END (:290-297).
-- Nuestro contrato trae las dos en una tabla con una columna que las
-- distingue, y las banderas salen igual.
--
-- EL MD5 NO PUEDE LEER EL ALIAS concatena DE SU PROPIO SELECT -- el legado
-- escribe rec_vista.hash_md5(concatena) y Redshift no lo resuelve --, asi que
-- el concatena se arma en una subconsulta. Misma trampa que FLAG_OP en
-- Novedades y que el hash de la Fase 3.
--
-- DE LAS 21 COLUMNAS DEL CONCATENA DEL LEGADO AQUI VAN 4 CON DATO. Las otras
-- 17 son importes y contadores del modelo de credito (debitos, creditos,
-- cheques, score, disponible...) que no tenemos y que NO se inventan: una
-- semilla con saldos y moras inventados pareceria dato de credito y no lo
-- seria. Van con el centinela ''0'' del propio legado, en su sitio y en su
-- orden, para que el dia que existan el hash cambie en una linea.
--
-- INSERT-ONLY. El UPDATE de PRO_ORD_FINAL_CTA_ATRIBUTOS.sql:200 esta
-- comentado con "Por solicitud de Experian... no se va a necesitar", la misma
-- frase que desactiva el de la Fase 3. Dos archivos, una decision.
--
-- NONATOMIC (leccion #13). Rollback: DROP PROCEDURE con firma exacta
-- (#12/#14).
-- ============================================================

CREATE OR REPLACE PROCEDURE bdm_datos.sp_ordenamiento_cuentas_edf(
  p_lote INTEGER
)
NONATOMIC
LANGUAGE plpgsql
AS $$
BEGIN

  DROP TABLE IF EXISTS bdm_tempo.stg_ord_cta_hash;
  DROP TABLE IF EXISTS bdm_tempo.stg_ord_cta_base;

  -- Paso 1. Las cuentas del universo de la Fase 1 (F2-01), con sus banderas
  -- de comportamiento activo y pasivo dentro de la ventana de 12 meses
  -- (F2-02, F2-03, F2-04). El INNER JOIN contra el alcance ES F2-01.
  CREATE TABLE bdm_tempo.stg_ord_cta_base
  DISTSTYLE KEY
  DISTKEY (id_buro_persona)
  SORTKEY (id_buro_persona, cod_dw_cta)
  AS
  SELECT c.cod_dw_cta,
         c.id_buro_persona,
         c.cod_pin_persona,
         c.cod_suscriptor,
         c.cod_tipo_cta_fte,
         c.cod_tipo_obligacion_fte,
         c.cod_tipo_rel_con_cta_fte,
         c.cod_clase_garantia_buro_fte,
         c.num_cuotas_pactadas,
         c.fecha_nov,
         c.valor_saldo,
         c.valor_cuota_mensual,
         c.numero_dias_mora,
         c.num_cuotas_pagadas,
         -- F2-10: las tres fechas de insumo por Persona-Cuenta-Suscriptor.
         -- El legado las materializa como (cod_dw_cta, fecha_nov_ini,
         -- fecha_nov) para el calculo de meses de reporte (:93).
         DATEADD(month, -12, c.fecha_nov) AS fecha_nov_ini,
         CURRENT_DATE                     AS fecha_proceso,
         CASE WHEN act.cod_dw_cta IS NOT NULL THEN 'Y' ELSE 'N' END AS flag_comp_cta_activo,
         CASE WHEN pas.cod_dw_cta IS NOT NULL THEN 'Y' ELSE 'N' END AS flag_comp_cta_pasivo
    FROM bdm_tempo.v_xpm_cuenta c
    INNER JOIN bdm_tempo.stg_ord_personas_alcance alc
            ON alc.id_buro_persona = c.id_buro_persona
    LEFT JOIN ( SELECT DISTINCT b.cod_dw_cta
                  FROM bdm_tempo.v_xpm_comportamiento_cta b
                  INNER JOIN bdm_tempo.v_xpm_cuenta cc
                          ON cc.cod_dw_cta = b.cod_dw_cta
                 WHERE b.tipo = 'A'
                   AND b.fecha_corte >  DATEADD(month, -12, cc.fecha_nov)
                   AND b.fecha_corte <= cc.fecha_nov ) act
           ON act.cod_dw_cta = c.cod_dw_cta
    LEFT JOIN ( SELECT DISTINCT b.cod_dw_cta
                  FROM bdm_tempo.v_xpm_comportamiento_cta b
                  INNER JOIN bdm_tempo.v_xpm_cuenta cc
                          ON cc.cod_dw_cta = b.cod_dw_cta
                 WHERE b.tipo = 'P'
                   AND b.fecha_corte >  DATEADD(month, -12, cc.fecha_nov)
                   AND b.fecha_corte <= cc.fecha_nov ) pas
           ON pas.cod_dw_cta = c.cod_dw_cta;

  ANALYZE bdm_tempo.stg_ord_cta_base;

  -- Paso 2. El Portafolio (F2-05, F2-06) y el hash (F2-07, F2-08).
  -- El CASE va LITERAL desde PRO_ORD_CTA_TOTALES_PERSONAS_2.sql:304-375,
  -- con su anidamiento y su orden de ramas: cambiar el orden cambia la
  -- clasificacion, porque las condiciones no son excluyentes entre si.
  CREATE TABLE bdm_tempo.stg_ord_cta_hash
  DISTSTYLE KEY
  DISTKEY (cod_dw_cta)
  SORTKEY (id_buro_persona, cod_dw_cta)
  AS
  SELECT x.cod_pin_persona,
         x.id_buro_persona,
         x.cod_dw_cta,
         x.fecha_nov,
         x.portafolio,
         MD5(x.concatena) AS cod_hash
  FROM (
    SELECT a.cod_pin_persona,
           a.id_buro_persona,
           a.cod_dw_cta,
           a.fecha_nov,
           CASE WHEN a.flag_comp_cta_pasivo = 'Y' THEN
                  CASE WHEN CAST(a.cod_tipo_cta_fte AS INTEGER) = 1
                        AND SUBSTRING(a.cod_suscriptor, 1, 2) = '51' THEN 'AH'
                       ELSE
                         CASE WHEN CAST(a.cod_tipo_cta_fte AS INTEGER) = 1
                               AND SUBSTRING(a.cod_suscriptor, 1, 2) <> '51' THEN 'CT'
                              ELSE '--'
                         END
                  END
                ELSE
                  CASE WHEN a.flag_comp_cta_activo = 'Y' THEN
                    CASE WHEN a.cod_tipo_rel_con_cta_fte = 'C'
                          AND CAST(a.cod_tipo_cta_fte AS INTEGER) <> 2 THEN 'CO'
                         ELSE
                      CASE WHEN (CAST(a.cod_tipo_cta_fte AS INTEGER) IN (2, 3))
                             OR (CAST(a.cod_tipo_cta_fte AS INTEGER) IN (5, 6, 27, 49)
                                 AND CAST(a.cod_tipo_obligacion_fte AS INTEGER) = 2
                                 AND a.num_cuotas_pactadas = 0
                                 AND a.cod_clase_garantia_buro_fte <> '1')
                             OR (CAST(a.cod_tipo_cta_fte AS INTEGER) = 18
                                 AND CAST(a.cod_tipo_obligacion_fte AS INTEGER) = 2
                                 AND a.num_cuotas_pactadas = 0
                                 AND a.cod_clase_garantia_buro_fte <> '1') THEN 'RO'
                           ELSE
                        CASE WHEN ( (CAST(a.cod_tipo_cta_fte AS INTEGER) IN (5, 6, 7, 8, 18, 27, 49)
                                     AND CAST(a.cod_tipo_obligacion_fte AS INTEGER) = 2)
                                 OR (CAST(a.cod_tipo_cta_fte AS INTEGER) = 18
                                     AND CAST(a.cod_tipo_obligacion_fte AS INTEGER) = 1) )
                              AND a.num_cuotas_pactadas BETWEEN 1 AND 60
                              AND a.cod_clase_garantia_buro_fte = '1' THEN 'VE'
                             ELSE
                          CASE WHEN CAST(a.cod_tipo_cta_fte AS INTEGER) = 13
                                 OR (CAST(a.cod_tipo_cta_fte AS INTEGER) IN (5, 6, 7, 8, 27, 49)
                                     AND (CAST(a.cod_tipo_obligacion_fte AS INTEGER) = 3
                                          OR (a.num_cuotas_pactadas > 60
                                              AND a.cod_clase_garantia_buro_fte = '1'))) THEN 'HP'
                               ELSE
                            CASE WHEN CAST(a.cod_tipo_cta_fte AS INTEGER)
                                      IN (5, 6, 7, 8, 9, 14, 18, 27, 33, 46, 49) THEN 'IN'
                                 ELSE
                              CASE WHEN ( (CAST(a.cod_tipo_cta_fte AS INTEGER)
                                           IN (4, 9, 10, 11, 15, 16, 19, 20, 21, 22, 26, 28, 29, 34, 35, 36, 43, 44, 45)
                                           AND CAST(a.cod_tipo_obligacion_fte AS INTEGER) = 2)
                                        OR (CAST(a.cod_tipo_cta_fte AS INTEGER) IN (15, 16)
                                            AND CAST(a.cod_tipo_obligacion_fte AS INTEGER) = 3) )
                                     OR ( (CAST(a.cod_tipo_cta_fte AS INTEGER)
                                           IN (4, 9, 10, 11, 19, 20, 21, 22, 26, 28, 29, 34, 35, 36, 43, 44, 45)
                                           AND CAST(a.cod_tipo_obligacion_fte AS INTEGER) <> 2)
                                        OR ( (CAST(a.cod_tipo_cta_fte AS INTEGER) IN (15, 16)
                                              AND CAST(a.cod_tipo_obligacion_fte AS INTEGER) NOT IN (3, 2))
                                          OR CAST(a.cod_tipo_cta_fte AS INTEGER)
                                             IN (30, 31, 32, 37, 38, 39, 41, 42) ) ) THEN 'OT'
                                   ELSE
                                CASE WHEN CAST(a.cod_tipo_cta_fte AS INTEGER) IN (23, 24) THEN 'CC'
                                     ELSE 'OT'
                                END
                              END
                            END
                          END
                        END
                      END
                    END
                  ELSE 'OT'
                  END
           END AS portafolio,
           -- Concatena del legado (PRO_ORD_CONCAT_ATRIBUTOS:95-120), con su
           -- centinela ''0''. Las 17 que no tenemos van en su sitio.
                 COALESCE(CAST(TRIM(a.cod_clase_garantia_buro_fte) AS VARCHAR(20)), '0')
              || '0'                                                       -- valor_inicial
              || COALESCE(CAST(TRIM(CAST(a.valor_cuota_mensual AS VARCHAR)) AS VARCHAR(20)), '0')
              || COALESCE(CAST(TRIM(CAST(a.valor_saldo         AS VARCHAR)) AS VARCHAR(20)), '0')
              || COALESCE(CAST(TRIM(CAST(a.numero_dias_mora    AS VARCHAR)) AS VARCHAR(20)), '0')
              || '0'                                                       -- valor_saldo_mora
              || COALESCE(CAST(TRIM(CAST(a.num_cuotas_pagadas  AS VARCHAR)) AS VARCHAR(20)), '0')
              || '0'                                                       -- valor_disponible
              || '0'                                                       -- num_cuotas_mora
              || COALESCE(CAST(TRIM(CAST(a.num_cuotas_pactadas AS VARCHAR)) AS VARCHAR(20)), '0')
              || '0' || '0' || '0' || '0'                                  -- debitos y creditos
              || '0' || '0'                                                -- cheques
              || '0'                                                       -- valor_score
              || '0'                                                       -- ind_rel_suscriptor
              || '0'                                                       -- ind_tec_score
             AS concatena
      FROM bdm_tempo.stg_ord_cta_base a
  ) x;

  ANALYZE bdm_tempo.stg_ord_cta_hash;

  -- F2-07. Lo nuevo entra. Anti-join de CUATRO columnas, hash incluido
  -- (PRO_ORD_FINAL_CTA_ATRIBUTOS:110-133): una cuenta cuyo hash cambio no
  -- encuentra pareja y entra como fila nueva. Es como el AS-IS registra el
  -- cambio, porque su UPDATE esta desactivado.
  INSERT INTO bdm_datos.cuenta_atributo_hash
    (cod_pin_persona, id_buro_persona, cod_dw_cta,
     cod_dw_hash, fecha_nov, portafolio, lote, usuario_bd)
  SELECT a.cod_pin_persona, a.id_buro_persona, a.cod_dw_cta,
         a.cod_hash, a.fecha_nov, a.portafolio, p_lote, CURRENT_USER
    FROM bdm_tempo.stg_ord_cta_hash a
    LEFT JOIN bdm_datos.cuenta_atributo_hash b
           ON  b.cod_pin_persona = a.cod_pin_persona
           AND b.id_buro_persona = a.id_buro_persona
           AND b.cod_dw_cta      = a.cod_dw_cta
           AND b.cod_dw_hash     = a.cod_hash
   WHERE b.cod_dw_cta IS NULL;

END;
$$;
