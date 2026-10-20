-- ============================================================
-- sp_rcn_ctl_nov_migrar_info_basica
-- 2026-10-20 (D-NOV-04). Migra bdm_datos.mat_info_ubicacion.info_basica de
-- INTEGER a BIGINT en los ambientes donde la tabla ya existe, CONSERVANDO los
-- datos. UTF-8 sin BOM. Nunca GRANT ... TO PUBLIC.
--
-- POR QUE HACE FALTA: info_basica es id_buro_persona = FNV_HASH(pin), de 64
-- bits, y en INTEGER la etapa 9 de Novedades aborta con "integer out of
-- range" con cualquier dato real. 30_ddl_novedades.sql ya la declara BIGINT,
-- pero CREATE TABLE IF NOT EXISTS no altera una tabla existente, y Redshift
-- no cambia el tipo de una columna numerica (ALTER COLUMN TYPE solo existe
-- para VARCHAR).
--
-- POR QUE ASI Y NO DROP + CREATE: es la tabla final que lee En Linea. Un
-- DROP en cada despliegue la dejaria vacia hasta la siguiente corrida, que
-- es el defecto que ya arrastra unificacion_direccion (#13 del plan). Aqui la
-- columna se reemplaza con su valor, y solo si sigue en INTEGER: el segundo
-- despliegue y todos los siguientes no hacen nada.
--
-- La columna queda al FINAL de la tabla en los ambientes migrados. Todo el
-- que la usa lo hace por nombre (el INSERT de
-- sp_novedades_cargar_mat_ubicacion_edf.sql lleva lista de columnas).
--
-- La invoca dt (run_migracion_nov_info_basica.sql, primera linea de su
-- deploy.par), despues de que strct y pgm esten desplegados.
-- ============================================================

CREATE OR REPLACE PROCEDURE bdm_datos.sp_rcn_ctl_nov_migrar_info_basica()
NONATOMIC
LANGUAGE plpgsql
AS $$
DECLARE
  v_tipo  VARCHAR(64);
  v_filas BIGINT;
BEGIN
  -- El catalogo va a una variable antes de cualquier escritura: Redshift no
  -- mezcla una vista de sistema del leader con una tabla de usuario en la
  -- misma sentencia (misma trampa que el censo de 19_sp_ordenamiento_ciclo).
  SELECT data_type INTO v_tipo
    FROM information_schema.columns
   WHERE table_schema = 'bdm_datos'
     AND table_name   = 'mat_info_ubicacion'
     AND column_name  = 'info_basica';

  IF v_tipo IS NULL THEN
    RAISE INFO 'sp_rcn_ctl_nov_migrar_info_basica: bdm_datos.mat_info_ubicacion no existe o no tiene info_basica. Nada que migrar.';
    RETURN;
  END IF;

  IF v_tipo <> 'integer' THEN
    RAISE INFO 'sp_rcn_ctl_nov_migrar_info_basica: info_basica ya es %. Nada que migrar.', v_tipo;
    RETURN;
  END IF;

  ALTER TABLE bdm_datos.mat_info_ubicacion ADD COLUMN info_basica_bigint BIGINT;

  UPDATE bdm_datos.mat_info_ubicacion
     SET info_basica_bigint = info_basica
   WHERE info_basica IS NOT NULL;

  SELECT COUNT(*) INTO v_filas
    FROM bdm_datos.mat_info_ubicacion
   WHERE info_basica_bigint IS NOT NULL;

  ALTER TABLE bdm_datos.mat_info_ubicacion DROP COLUMN info_basica;
  ALTER TABLE bdm_datos.mat_info_ubicacion RENAME COLUMN info_basica_bigint TO info_basica;

  RAISE INFO 'sp_rcn_ctl_nov_migrar_info_basica: info_basica migrada a BIGINT; % filas con valor conservadas.', v_filas;
END;
$$;
