-- ============================================================
-- sp_rcn_ctl_obs_migrar
-- 2026-10-21 (observabilidad F3, decision T3 del usuario). Pone al dia las
-- tablas de control en los ambientes donde ya existen. UTF-8 sin BOM.
-- Nunca GRANT ... TO PUBLIC.
--
-- POR QUE HACE FALTA: CREATE TABLE IF NOT EXISTS no altera una tabla que ya
-- existe, y en DEV y QA todas estas existen de despliegues anteriores. El DDL
-- ya las declara bien para un ambiente limpio; esto cubre los que no lo son.
--
-- QUE TOCA, y las tres cosas son ADITIVAS -- ninguna borra ni reescribe dato:
--   1. version_betas en beta_ordenamiento y en ord_control / mock_ord_control
--      (G-06, D-ORD-12).
--   2. corrida_id en geo_lote_control: ata el Lote GEO a la corrida de
--      Unificacion que lo creo.
--   3. etapa a VARCHAR(64) en las seis tablas de etapa. Redshift SOLO admite
--      ALTER COLUMN TYPE sobre VARCHAR y SOLO para ENSANCHAR, que es
--      exactamente este caso: 20 y 30 pasan a 64. Un valor que hoy cabe
--      sigue cabiendo, de modo que no hay dato que se pueda perder.
--
-- ES IDEMPOTENTE: cada paso mira el catalogo antes y sale si ya esta hecho,
-- de modo que la segunda pasada de DPLY del pipeline no hace nada (regla del
-- job #412).
--
-- Y RELLENA version_betas DE LAS BETAS YA CARGADAS: sin eso, en un ambiente
-- migrado la columna quedaria NULL hasta el proximo despliegue del catalogo,
-- y la corrida siguiente registraria "sin version" teniendo betas.
--
-- La invoca dt (run_migracion_observabilidad.sql).
-- ============================================================

CREATE OR REPLACE PROCEDURE bdm_datos.sp_rcn_ctl_obs_migrar()
NONATOMIC
LANGUAGE plpgsql
AS $$
DECLARE
  v_col   VARCHAR(64);
  v_largo INTEGER;
  v_filas BIGINT;
BEGIN
  -- --- 1. version_betas en el catalogo de betas -------------------
  SELECT column_name INTO v_col
    FROM information_schema.columns
   WHERE table_schema = 'bdm_datos' AND table_name = 'beta_ordenamiento'
     AND column_name = 'version_betas';
  IF v_col IS NULL THEN
    ALTER TABLE bdm_datos.beta_ordenamiento ADD COLUMN version_betas VARCHAR(40);
    UPDATE bdm_datos.beta_ordenamiento
       SET version_betas = 'RITM5226589'
     WHERE version_betas IS NULL;
    SELECT COUNT(*) INTO v_filas FROM bdm_datos.beta_ordenamiento;
    RAISE INFO 'sp_rcn_ctl_obs_migrar: version_betas anadida al catalogo; % betas marcadas RITM5226589.', v_filas;
  END IF;

  -- --- 2. version_betas en la traza de corrida --------------------
  SELECT column_name INTO v_col
    FROM information_schema.columns
   WHERE table_schema = 'bdm_datos' AND table_name = 'ord_control'
     AND column_name = 'version_betas';
  IF v_col IS NULL THEN
    ALTER TABLE bdm_datos.ord_control ADD COLUMN version_betas VARCHAR(40);
    RAISE INFO 'sp_rcn_ctl_obs_migrar: version_betas anadida a ord_control.';
  END IF;

  SELECT column_name INTO v_col
    FROM information_schema.columns
   WHERE table_schema = 'bdm_stage' AND table_name = 'mock_ord_control'
     AND column_name = 'version_betas';
  IF v_col IS NULL THEN
    SELECT table_name INTO v_col
      FROM information_schema.tables
     WHERE table_schema = 'bdm_stage' AND table_name = 'mock_ord_control';
    IF v_col IS NOT NULL THEN
      ALTER TABLE bdm_stage.mock_ord_control ADD COLUMN version_betas VARCHAR(40);
      RAISE INFO 'sp_rcn_ctl_obs_migrar: version_betas anadida a mock_ord_control.';
    END IF;
  END IF;

  -- --- 3. corrida_id en el control de Lotes GEO -------------------
  SELECT column_name INTO v_col
    FROM information_schema.columns
   WHERE table_schema = 'bdm_datos' AND table_name = 'geo_lote_control'
     AND column_name = 'corrida_id';
  IF v_col IS NULL THEN
    SELECT table_name INTO v_col
      FROM information_schema.tables
     WHERE table_schema = 'bdm_datos' AND table_name = 'geo_lote_control';
    IF v_col IS NOT NULL THEN
      ALTER TABLE bdm_datos.geo_lote_control ADD COLUMN corrida_id BIGINT;
      RAISE INFO 'sp_rcn_ctl_obs_migrar: corrida_id anadida a geo_lote_control.';
    END IF;
  END IF;

  -- --- 4. etapa a VARCHAR(64) en las seis tablas de etapa ---------
  SELECT character_maximum_length INTO v_largo
    FROM information_schema.columns
   WHERE table_schema = 'bdm_datos' AND table_name = 'ord_control_etapa'
     AND column_name = 'etapa';
  IF v_largo IS NOT NULL AND v_largo < 64 THEN
    ALTER TABLE bdm_datos.ord_control_etapa ALTER COLUMN etapa TYPE VARCHAR(64);
  END IF;

  SELECT character_maximum_length INTO v_largo
    FROM information_schema.columns
   WHERE table_schema = 'bdm_stage' AND table_name = 'mock_ord_control_etapa'
     AND column_name = 'etapa';
  IF v_largo IS NOT NULL AND v_largo < 64 THEN
    ALTER TABLE bdm_stage.mock_ord_control_etapa ALTER COLUMN etapa TYPE VARCHAR(64);
  END IF;

  SELECT character_maximum_length INTO v_largo
    FROM information_schema.columns
   WHERE table_schema = 'bdm_datos' AND table_name = 'unif_control_etapa'
     AND column_name = 'etapa';
  IF v_largo IS NOT NULL AND v_largo < 64 THEN
    ALTER TABLE bdm_datos.unif_control_etapa ALTER COLUMN etapa TYPE VARCHAR(64);
  END IF;

  SELECT character_maximum_length INTO v_largo
    FROM information_schema.columns
   WHERE table_schema = 'bdm_stage' AND table_name = 'mock_unif_control_etapa'
     AND column_name = 'etapa';
  IF v_largo IS NOT NULL AND v_largo < 64 THEN
    ALTER TABLE bdm_stage.mock_unif_control_etapa ALTER COLUMN etapa TYPE VARCHAR(64);
  END IF;

  SELECT character_maximum_length INTO v_largo
    FROM information_schema.columns
   WHERE table_schema = 'bdm_datos' AND table_name = 'nov_control_etapa'
     AND column_name = 'etapa';
  IF v_largo IS NOT NULL AND v_largo < 64 THEN
    ALTER TABLE bdm_datos.nov_control_etapa ALTER COLUMN etapa TYPE VARCHAR(64);
  END IF;

  SELECT character_maximum_length INTO v_largo
    FROM information_schema.columns
   WHERE table_schema = 'bdm_stage' AND table_name = 'mock_nov_control_etapa'
     AND column_name = 'etapa';
  IF v_largo IS NOT NULL AND v_largo < 64 THEN
    ALTER TABLE bdm_stage.mock_nov_control_etapa ALTER COLUMN etapa TYPE VARCHAR(64);
  END IF;

  -- --- 5. nombre_punto_interes en las distancias GEO --------------
  -- 2026-10-21 (d7). ADITIVA, como las cuatro de arriba. El nombre del punto
  -- de interes llega en col08 del contrato Salida_Distancias y hasta hoy se
  -- tiraba al cargar; es la columna NOMBRE de MAT_INFO_PUNTO_INTERES.
  SELECT column_name INTO v_col
    FROM information_schema.columns
   WHERE table_schema = 'bdm_datos' AND table_name = 'geo_distancias'
     AND column_name = 'nombre_punto_interes';
  IF v_col IS NULL THEN
    ALTER TABLE bdm_datos.geo_distancias ADD COLUMN nombre_punto_interes VARCHAR(200);
    RAISE INFO 'sp_rcn_ctl_obs_migrar: nombre_punto_interes anadida a geo_distancias.';
  END IF;

  -- El espejo mock se guarda ADEMAS por existencia de la tabla: es nueva en
  -- este commit y un ALTER sobre una tabla que no esta aborta el paso.
  SELECT table_name INTO v_col
    FROM information_schema.tables
   WHERE table_schema = 'bdm_datos' AND table_name = 'geo_distancias_mock';
  IF v_col IS NOT NULL THEN
    SELECT column_name INTO v_col
      FROM information_schema.columns
     WHERE table_schema = 'bdm_datos' AND table_name = 'geo_distancias_mock'
       AND column_name = 'nombre_punto_interes';
    IF v_col IS NULL THEN
      ALTER TABLE bdm_datos.geo_distancias_mock ADD COLUMN nombre_punto_interes VARCHAR(200);
    END IF;
  END IF;

  RAISE INFO 'sp_rcn_ctl_obs_migrar: terminado.';
END;
$$;
