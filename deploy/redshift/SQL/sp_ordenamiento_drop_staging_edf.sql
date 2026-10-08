-- Libera staging temporal al final de cada corrida
CREATE OR REPLACE PROCEDURE bdm_datos.sp_ordenamiento_drop_staging_edf()
NONATOMIC
LANGUAGE plpgsql
AS $$
BEGIN
  DROP TABLE IF EXISTS bdm_tempo.stg_ord_personas_alcance;
  DROP TABLE IF EXISTS bdm_tempo.stg_insumo_email;
  DROP TABLE IF EXISTS bdm_tempo.stg_insumo_celular;
  DROP TABLE IF EXISTS bdm_tempo.stg_insumo_telefono;
  DROP TABLE IF EXISTS bdm_tempo.stg_insumo_direccion;
  DROP TABLE IF EXISTS bdm_tempo.stg_contacto_canal;
  DROP TABLE IF EXISTS bdm_tempo.stg_reporte_rpu;
  DROP TABLE IF EXISTS bdm_tempo.stg_contacto_direccion_rpu;
  DROP TABLE IF EXISTS bdm_tempo.stg_persona_dir_ref;
  DROP TABLE IF EXISTS bdm_tempo.stg_dir_conteo_persona;
  DROP TABLE IF EXISTS bdm_tempo.stg_persona_dir_ganadora;
  DROP TABLE IF EXISTS bdm_tempo.stg_rpu_post_unificacion;
END;
$$;
-- SLCOPRBA-1355: re-DPLY DEV post DROP SCHEMA strct #256
