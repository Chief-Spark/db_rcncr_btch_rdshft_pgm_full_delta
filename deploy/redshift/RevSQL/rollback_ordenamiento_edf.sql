-- Rollback SPs ordenamiento EDF/mock (firmas nuevas; SIN IF EXISTS)
DROP PROCEDURE bdm_datos.sp_ordenamiento_ejecucion_mock(VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR);
DROP PROCEDURE bdm_datos.sp_ordenamiento_validar_mock();
DROP PROCEDURE bdm_datos.sp_ordenamiento_cargar_seed_mock();
DROP PROCEDURE bdm_datos.sp_ordenamiento_ejecucion_edf(BOOLEAN, VARCHAR, INTEGER, DATE);
DROP PROCEDURE bdm_datos.sp_ordenamiento_drop_staging_edf();
DROP PROCEDURE bdm_datos.sp_ordenamiento_consolidacion_edf();
DROP PROCEDURE bdm_datos.sp_ordenamiento_scoring_ema_edf();
DROP PROCEDURE bdm_datos.sp_ordenamiento_scoring_cel_edf();
DROP PROCEDURE bdm_datos.sp_ordenamiento_scoring_tel_edf();
DROP PROCEDURE bdm_datos.sp_ordenamiento_scoring_dir_edf();
DROP PROCEDURE bdm_datos.sp_ordenamiento_preparar_insumos_edf(VARCHAR, INTEGER, DATE);
