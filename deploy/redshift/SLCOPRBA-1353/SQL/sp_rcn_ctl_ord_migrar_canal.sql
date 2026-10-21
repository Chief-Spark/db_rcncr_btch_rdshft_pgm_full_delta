-- ============================================================
-- sp_rcn_ctl_ord_migrar_canal
-- 2026-10-21 (D-ORD-10, decision T1 del usuario). Anade la columna canal a
-- bdm_datos.rpu_orden_prioridad en los ambientes donde la tabla ya existe sin
-- ella, y VACIA la tabla. UTF-8 sin BOM. Nunca GRANT ... TO PUBLIC.
--
-- POR QUE HACE FALTA: 04_vistas_insumo_ordenamiento_edf_views.sql ya declara
-- la columna, pero CREATE TABLE IF NOT EXISTS no altera una tabla que ya
-- existe, y en DEV y QA existe de despliegues anteriores. Sin esta migracion
-- el INSERT de sp_ordenamiento_consolidacion_edf falla con
-- "column canal of relation rpu_orden_prioridad does not exist".
--
-- POR QUE VACIA LA TABLA EN VEZ DE RELLENAR LA COLUMNA: las filas viejas se
-- escribieron con MIN(lugar) MEZCLANDO canales, de modo que no hay valor de
-- canal que sea cierto para ellas -- inventarlo seria marcar como "de DIR" un
-- numero que puede venir de TEL. La siguiente corrida es FULL y las repuebla
-- con el grano nuevo. La tabla es un insumo del Batch, no un historico: su
-- unica limpieza regular ya es un DELETE por alcance.
--
-- ES IDEMPOTENTE: si la columna ya existe, informa y sale sin tocar nada, de
-- modo que la segunda pasada de DPLY del pipeline no vacia una tabla que la
-- primera acaba de poblar (la regla del job #412).
--
-- La invoca dt (run_migracion_ord_canal.sql), despues de que strct y pgm
-- esten desplegados.
-- ============================================================

CREATE OR REPLACE PROCEDURE bdm_datos.sp_rcn_ctl_ord_migrar_canal()
NONATOMIC
LANGUAGE plpgsql
AS $$
DECLARE
  v_col   VARCHAR(64);
  v_tabla VARCHAR(64);
  v_filas BIGINT;
BEGIN
  -- El catalogo va a variables ANTES de cualquier escritura: Redshift no
  -- mezcla una vista de sistema del leader con una tabla de usuario en la
  -- misma sentencia (misma trampa que el censo de 19_sp_ordenamiento_ciclo).
  SELECT table_name INTO v_tabla
    FROM information_schema.tables
   WHERE table_schema = 'bdm_datos'
     AND table_name   = 'rpu_orden_prioridad';

  IF v_tabla IS NULL THEN
    RAISE INFO 'sp_rcn_ctl_ord_migrar_canal: bdm_datos.rpu_orden_prioridad no existe todavia. La crea el DDL con la columna. Nada que migrar.';
    RETURN;
  END IF;

  SELECT column_name INTO v_col
    FROM information_schema.columns
   WHERE table_schema = 'bdm_datos'
     AND table_name   = 'rpu_orden_prioridad'
     AND column_name  = 'canal';

  IF v_col IS NOT NULL THEN
    RAISE INFO 'sp_rcn_ctl_ord_migrar_canal: la columna canal ya existe. Nada que migrar.';
    RETURN;
  END IF;

  SELECT COUNT(*) INTO v_filas FROM bdm_datos.rpu_orden_prioridad;

  ALTER TABLE bdm_datos.rpu_orden_prioridad ADD COLUMN canal VARCHAR(3);

  -- Un DELETE con WHERE y no un TRUNCATE: la politica REDSHIFT:232 exige
  -- WHERE explicito en todo DELETE de nivel superior, y un TRUNCATE aqui
  -- confirmaria la transaccion en curso.
  DELETE FROM bdm_datos.rpu_orden_prioridad
   WHERE cod_dw_persona_ubic IS NOT NULL
      OR cod_dw_persona_ubic IS NULL;

  RAISE INFO 'sp_rcn_ctl_ord_migrar_canal: columna canal anadida; % filas del grano viejo descartadas. La proxima corrida FULL repuebla.', v_filas;
END;
$$;
