-- ============================================================
-- sp_rcn_geo_02_buscar_resultados_mock  (Reconocer / GEO MOCK)
-- 2026-10-20. UTF-8 sin BOM. Nunca GRANT ... TO PUBLIC.
--
-- ESPEJO MOCK de sp_rcn_geo_02_buscar_resultados. Mismo recorrido: Lotes en
-- 'exportado' con filas en el archivo de vuelta pasan a 'procesado por
-- ArcGIS_Externo' y se cargan; un error deja RAISE INFO y nunca sube.
--
-- DIFIERE EN EL ORIGEN, como el resto de la via mock de GEO:
--   * el "archivo de vuelta" es bdm_stage.mock_geo_respuesta, la tabla que
--     escribe sp_geo_simular_arcgis_mock; no hay COPY ni configuracion de S3
--     que leer;
--   * no hay distancias en la via mock (no existe geo_distancias_mock), de
--     modo que solo se llama al cargador de georreferenciacion.
--
-- EN LA BATERIA NO HACE NADA, y eso es lo esperado: durante el e2e y la
-- convergencia mock_geo_respuesta esta vacia (la trunca reset_mock.sql y el
-- simulador solo corre despues, en run_geo_ciclo_mock.sql). Asi CA-01 sigue
-- viendo el Lote en 'exportado'. Sirve para probar el recorrido a mano.
-- ============================================================

CREATE OR REPLACE PROCEDURE bdm_datos.sp_rcn_geo_02_buscar_resultados_mock()
NONATOMIC
LANGUAGE plpgsql
AS $$
DECLARE
  v_en_espera    INTEGER;
  v_filas_geo    INTEGER;
  v_n            INTEGER;
  v_i            INTEGER;
  v_lote         INTEGER;
  v_estado       VARCHAR(40);
  v_cargados     INTEGER;
  v_err          VARCHAR(2000);
BEGIN

  SELECT COUNT(*) INTO v_en_espera
  FROM bdm_datos.geo_lote_control_mock
  WHERE estado = 'exportado';

  IF v_en_espera = 0 THEN
    RAISE INFO 'sp_rcn_geo_02_buscar_resultados_mock: no hay Lotes esperando respuesta de ArcGIS.';
    RETURN;
  END IF;

  SELECT COUNT(*) INTO v_filas_geo FROM bdm_stage.mock_geo_respuesta;

  DROP TABLE IF EXISTS bdm_tempo.stg_mock_geo_lotes_con_resultado;
  CREATE TABLE bdm_tempo.stg_mock_geo_lotes_con_resultado AS
  SELECT lc.lote,
         ROW_NUMBER() OVER (ORDER BY lc.lote) AS rn
  FROM bdm_datos.geo_lote_control_mock lc
  WHERE lc.estado = 'exportado'
    AND lc.lote::VARCHAR IN (SELECT DISTINCT BTRIM(col02)
                             FROM bdm_stage.mock_geo_respuesta);

  SELECT COUNT(*) INTO v_n FROM bdm_tempo.stg_mock_geo_lotes_con_resultado;
  v_i := 1;
  v_cargados := 0;

  WHILE v_i <= v_n LOOP
    SELECT lote INTO v_lote
    FROM bdm_tempo.stg_mock_geo_lotes_con_resultado
    WHERE rn = v_i;

    UPDATE bdm_datos.geo_lote_control_mock
    SET estado              = 'procesado por ArcGIS_Externo',
        fecha_actualizacion = GETDATE()
    WHERE lote = v_lote
      AND estado = 'exportado';

    BEGIN
      CALL bdm_datos.sp_geo_cargar_georreferenciacion_mock(v_lote, 'bdm_stage.mock_geo_respuesta');
    EXCEPTION WHEN OTHERS THEN
      v_err := LEFT(SQLERRM, 2000);
      RAISE INFO 'sp_rcn_geo_02_buscar_resultados_mock: la georreferenciacion del Lote % fallo (%); se sigue con los demas.',
        v_lote, v_err;
    END;

    SELECT estado INTO v_estado
    FROM bdm_datos.geo_lote_control_mock
    WHERE lote = v_lote;

    IF v_estado = 'cargado' THEN
      v_cargados := v_cargados + 1;
    END IF;

    v_i := v_i + 1;
  END LOOP;

  RAISE INFO 'sp_rcn_geo_02_buscar_resultados_mock: % fila(s) en el archivo de vuelta; % Lote(s) con resultados, % cargado(s); % Lote(s) esperaban respuesta.',
    v_filas_geo, v_n, v_cargados, v_en_espera;

  DROP TABLE IF EXISTS bdm_tempo.stg_mock_geo_lotes_con_resultado;

EXCEPTION WHEN OTHERS THEN
  v_err := LEFT(SQLERRM, 2000);
  RAISE INFO 'sp_rcn_geo_02_buscar_resultados_mock: busqueda de resultados interrumpida (%); el proceso continua.',
    v_err;
END;
$$;
