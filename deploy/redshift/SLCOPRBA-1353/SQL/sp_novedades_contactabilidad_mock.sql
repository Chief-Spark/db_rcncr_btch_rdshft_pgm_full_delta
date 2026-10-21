-- Novedades - dominio CONTACTABILIDAD (ESPEJO MOCK)
-- Espejo del real. Generado por
-- SUSTITUCION DE FUENTES: no se edita a mano. Regenerar con
-- tools/gen_novedades_espejo_contact.py.
-- Solo cambian los nombres de los objetos: _edf -> _mock en el
-- procedimiento y en la tabla final, sufijo _mock en la etapa 9 de
-- Ubicacion y v_xpm_* -> v_mock_* en las dos vistas de insumo. El diff
-- contra el real debe salir vacio modulo esos nombres.
-- La justificacion de D-NOV-08 vive en el archivo real.

CREATE OR REPLACE PROCEDURE bdm_datos.sp_novedades_contactabilidad_mock(
    p_lote INTEGER
)
NONATOMIC
LANGUAGE plpgsql
AS $$
BEGIN

  TRUNCATE TABLE bdm_datos.mat_info_contactabilidad_mock;

  INSERT INTO bdm_datos.mat_info_contactabilidad_mock (
    id, contactabilidad, fecha_ultimo_contacto, fecha_gestion,
    mejor_dia_gestion, mejor_hora_gestion, reportado_por, sector,
    ubicacion_id, peso, mejor_resultado_3meses, mejor_resultado_6meses,
    lote, fecha_actualizacion, usuario_bd
  )
  SELECT CAST(NULL AS BIGINT)         AS id,
         CAST(NULL AS VARCHAR(2))     AS contactabilidad,
         u.fecha_ultimo_contacto,
         CAST(NULL AS TIMESTAMP)      AS fecha_gestion,
         CAST(NULL AS VARCHAR(10))    AS mejor_dia_gestion,
         CAST(NULL AS VARCHAR(20))    AS mejor_hora_gestion,
         u.reportado_por,
         CAST(NULL AS VARCHAR(100))   AS sector,
         u.ubicacion_id,
         CAST(NULL AS BIGINT)         AS peso,
         CAST(NULL AS VARCHAR(100))   AS mejor_resultado_3meses,
         CAST(NULL AS VARCHAR(100))   AS mejor_resultado_6meses,
         p_lote, GETDATE(), CURRENT_USER
  FROM (
    -- El ranking va en una subconsulta del FROM y NO en la lista del SELECT:
    -- una subconsulta escalar en la proyeccion la rechaza Redshift en
    -- EJECUCION con XX000, y el banco sobre PostgreSQL no la caza (es el
    -- tercer punto ciego, el que tumbo el job #407 en NOV-UB-14).
    SELECT e9.id                                      AS ubicacion_id,
           MAX(rpu.fecha_relacion_persona_ubicaci)    AS fecha_ultimo_contacto,
           -- El suscriptor del reporte MAS RECIENTE. Quien lo elige es la
           -- ventana de la derivada `ult`, que ya deja una fila por
           -- ubicacion; este MAX() solo existe para satisfacer el GROUP BY.
           MAX(ult.id_buro_suscriptor)                AS reportado_por
    FROM   bdm_tempo.stg_nov_ubica_etapa_9_mock e9
    LEFT JOIN bdm_tempo.v_mock_relacion_persona_ubicacion rpu
           ON rpu.cod_dw_persona_ubic = e9.id
    LEFT JOIN (
      SELECT cod_dw_persona_ubic,
             id_buro_suscriptor
      FROM (
        SELECT r.cod_dw_persona_ubic,
               r.id_buro_suscriptor,
               ROW_NUMBER() OVER (
                 PARTITION BY r.cod_dw_persona_ubic
                 ORDER BY r.fecha_reporte DESC NULLS LAST,
                          r.id_buro_suscriptor DESC NULLS LAST
               ) AS rn
        FROM bdm_tempo.v_mock_reporte_relacion_persona_ubica r
      ) q
      WHERE q.rn = 1
    ) ult
           ON ult.cod_dw_persona_ubic = e9.id
    GROUP BY e9.id
  ) u;

END;
$$;
