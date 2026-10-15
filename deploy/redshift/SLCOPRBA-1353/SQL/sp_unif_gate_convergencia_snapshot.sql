-- SLCOPRBA-1355 (M5): huella del estado de las salidas de Unificacion mock.
-- Se invoca DESPUES de cada corrida de la prueba de convergencia con una
-- etiqueta ('FULL', 'DELTA1', 'DELTA2', 'FULL2') y su numero de secuencia.
--
-- El checksum omite a proposito 'lote', 'lote_actualizacion',
-- 'fecha_modificacion', 'fecha_unificacion' y 'usuario_bd': esas columnas
-- cambian de forma legitima entre corridas y compararlas haria fallar el gate
-- por una diferencia que no es de contenido. Se comparan las columnas que
-- definen QUE se unifico con QUE.
--
-- SUM(FNV_HASH(...)) es independiente del orden de las filas, que es lo que se
-- quiere: dos corridas pueden devolver las mismas filas en otro orden. El
-- acumulador es DECIMAL(38,0) porque FNV_HASH devuelve BIGINT y sumar decenas
-- de miles desbordaria.
CREATE OR REPLACE PROCEDURE bdm_datos.sp_unif_gate_convergencia_snapshot(
    p_etiqueta  VARCHAR,  -- FULL | DELTA1 | DELTA2 | FULL2
    p_secuencia INTEGER,  -- 1, 2, 3, 4
    p_lote      INTEGER
)
NONATOMIC
LANGUAGE plpgsql
AS $$
BEGIN

  -- Idempotente: re-tomar la huella de una secuencia reemplaza la anterior.
  DELETE FROM bdm_stage.mock_unif_convergencia WHERE secuencia = p_secuencia;

  INSERT INTO bdm_stage.mock_unif_convergencia
    (etiqueta, secuencia, objeto, filas, checksum, lote)
  SELECT p_etiqueta, p_secuencia, 'unificacion_direccion_mock',
         COUNT(*),
         SUM(CAST(FNV_HASH(
             COALESCE(CAST(u.cod_dw_persona_ubic        AS VARCHAR), '~') || '|' ||
             COALESCE(CAST(u.cod_dw_direccion_unificada AS VARCHAR), '~') || '|' ||
             COALESCE(CAST(u.unifica_atributos          AS VARCHAR), '~')
           ) AS DECIMAL(38,0))),
         p_lote
  FROM bdm_datos.unificacion_direccion_mock u;

  INSERT INTO bdm_stage.mock_unif_convergencia
    (etiqueta, secuencia, objeto, filas, checksum, lote)
  SELECT p_etiqueta, p_secuencia, 'direccion_fisica_generada_mock',
         COUNT(*),
         SUM(CAST(FNV_HASH(
             COALESCE(CAST(d.cod_dw_direccion_fisica AS VARCHAR), '~') || '|' ||
             COALESCE(d.complemento,                        '~')      || '|' ||
             COALESCE(CAST(d.cod_dw_ubic             AS VARCHAR), '~') || '|' ||
             COALESCE(CAST(d.generada_enriquecida    AS VARCHAR), '~')
           ) AS DECIMAL(38,0))),
         p_lote
  FROM bdm_datos.direccion_fisica_generada_mock d;

  INSERT INTO bdm_stage.mock_unif_convergencia
    (etiqueta, secuencia, objeto, filas, checksum, lote)
  SELECT p_etiqueta, p_secuencia, 'rpu_generada_mock',
         COUNT(*),
         SUM(CAST(FNV_HASH(
             COALESCE(CAST(r.cod_dw_persona_ubic       AS VARCHAR), '~') || '|' ||
             COALESCE(CAST(r.id_buro_persona           AS VARCHAR), '~') || '|' ||
             COALESCE(CAST(r.cod_dw_ubic               AS VARCHAR), '~') || '|' ||
             COALESCE(CAST(r.cod_dw_direccion_fisica   AS VARCHAR), '~') || '|' ||
             COALESCE(CAST(r.cod_dw_tipo_ubicacion_dir AS VARCHAR), '~')
           ) AS DECIMAL(38,0))),
         p_lote
  FROM bdm_datos.rpu_generada_mock r;

END;
$$;
