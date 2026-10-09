-- SLCOPRBA-1355 (M5): gate de convergencia FULL -> DELTA1 -> DELTA2 -> FULL2.
--
-- Lee las huellas que dejo sp_unif_gate_convergencia_snapshot y escribe un
-- veredicto por criterio en bdm_stage.mock_unif_ca_result.
--
-- POR QUE ESTE GATE EXISTE
--   El motor persiste la direccion generada con ind_unificacion NULL, y las
--   vistas de insumo la exponen con UNION ALL. Por lo tanto la direccion
--   generada VUELVE A ENTRAR al insumo de la corrida siguiente. El legado
--   tolera eso porque al final de la carga marca los hijos con
--   IND_UNIFICACION = 1 sobre la tabla real
--   (P0020_UNIFICACION_DIRECCION_130.TPT, quinta pasada, lineas 281-292) y el
--   filtro de estado del insumo los saca para siempre. Aqui NO se puede: el
--   datashare es de solo lectura y las vistas exponen ind_unificacion como
--   CAST(NULL AS INTEGER) fijo. Este gate mide las consecuencias en vez de
--   suponerlas.
--
-- Simulacion previa de la cascada (FULL -> DELTA -> DELTA -> FULL) sobre el
-- arquetipo E7 ('BR 5' padre, 'AP 301 TO 2' y 'AP 302 CS 4' hijos):
--
--   FULL    u2->u1, u3->u1              y genera 'BR 5 TO 2 CS 4 AP 301'
--   DELTA1  u1->G, u2->G, u3->G         y NO genera nada
--   DELTA2  igual que DELTA1            (converge)
--
--   En DELTA1 la direccion GENERADA pasa a ser el padre: esc2 captura a 'BR 5'
--   porque es substring del complemento generado, y esc4 captura a los otros
--   dos porque el generado tiene el conteo maximo (su complemento contiene
--   TODOS los tokens del grupo).
--
-- Por eso se esperan FALLOS en CA-C01, CA-C06, CA-C07 y CA-C08 mientras no se
-- resuelva la realimentacion. No son fallos del gate: son el hallazgo.
CREATE OR REPLACE PROCEDURE bdm_datos.sp_unif_gate_convergencia_evaluar()
NONATOMIC
LANGUAGE plpgsql
AS $$
BEGIN

  TRUNCATE TABLE bdm_stage.mock_unif_ca_result;

  -- CA-C01  El FULL es reproducible: un FULL de reproceso debe reconstruir el
  --         mismo estado que el primero. Si falla, el FULL no esta partiendo de
  --         un insumo limpio o no esta regenerando lo que borro.
  INSERT INTO bdm_stage.mock_unif_ca_result (criterio_ca, estado, detalle)
  SELECT 'CA-C01',
         CASE WHEN COUNT(*) = 0                      THEN 'NOT_RUN'
              WHEN SUM(CASE WHEN a.filas = b.filas
                             AND COALESCE(a.checksum, 0) = COALESCE(b.checksum, 0)
                            THEN 0 ELSE 1 END) = 0   THEN 'PASSED'
              ELSE 'FAILED' END,
         'objetos comparados=' || CAST(COUNT(*) AS VARCHAR) || ' ' ||
         COALESCE(LISTAGG(CASE WHEN a.filas <> b.filas
                                 OR COALESCE(a.checksum,0) <> COALESCE(b.checksum,0)
                               THEN a.objeto || '(FULL ' || CAST(a.filas AS VARCHAR)
                                    || ' vs FULL2 ' || CAST(b.filas AS VARCHAR) || ')'
                          END, ' ') WITHIN GROUP (ORDER BY a.objeto), 'sin diferencias')
  FROM       bdm_stage.mock_unif_convergencia a
  INNER JOIN bdm_stage.mock_unif_convergencia b
          ON b.objeto = a.objeto AND b.etiqueta = 'FULL2'
  WHERE a.etiqueta = 'FULL';

  -- CA-C02..C04  Convergencia: la segunda DELTA no debe cambiar nada.
  INSERT INTO bdm_stage.mock_unif_ca_result (criterio_ca, estado, detalle)
  SELECT CASE a.objeto WHEN 'unificacion_direccion_mock'     THEN 'CA-C02'
                       WHEN 'direccion_fisica_generada_mock' THEN 'CA-C03'
                       ELSE 'CA-C04' END,
         CASE WHEN a.filas = b.filas
               AND COALESCE(a.checksum, 0) = COALESCE(b.checksum, 0)
              THEN 'PASSED' ELSE 'FAILED' END,
         a.objeto || ': DELTA1 filas=' || CAST(a.filas AS VARCHAR)
                  || ' / DELTA2 filas=' || CAST(b.filas AS VARCHAR)
                  || ' | checksum ' || CASE WHEN COALESCE(a.checksum,0) = COALESCE(b.checksum,0)
                                            THEN 'igual' ELSE 'DISTINTO' END
  FROM       bdm_stage.mock_unif_convergencia a
  INNER JOIN bdm_stage.mock_unif_convergencia b
          ON b.objeto = a.objeto AND b.etiqueta = 'DELTA2'
  WHERE a.etiqueta = 'DELTA1';

  -- CA-C05  Sin cascada: la direccion generada no debe generar mas direcciones.
  INSERT INTO bdm_stage.mock_unif_ca_result (criterio_ca, estado, detalle)
  SELECT 'CA-C05',
         CASE WHEN COUNT(*) = 0        THEN 'NOT_RUN'
              WHEN MAX(b.filas) <= MAX(a.filas) THEN 'PASSED'
              ELSE 'FAILED' END,
         'direcciones generadas DELTA1=' || CAST(MAX(a.filas) AS VARCHAR)
                            || ' DELTA2=' || CAST(MAX(b.filas) AS VARCHAR)
  FROM       bdm_stage.mock_unif_convergencia a
  INNER JOIN bdm_stage.mock_unif_convergencia b
          ON b.objeto = a.objeto AND b.etiqueta = 'DELTA2'
  WHERE a.etiqueta = 'DELTA1'
    AND a.objeto = 'direccion_fisica_generada_mock';

  -- CA-C06  Un hijo, un padre. La Clave_Unificacion es el PAR
  --         (cod_dw_persona_ubic, cod_dw_direccion_unificada), de modo que el
  --         UPSERT por clave NO impide que una direccion acabe con dos padres:
  --         basta que una corrida posterior le asigne otro. Si esto falla, cada
  --         DELTA acumula parentescos contradictorios.
  INSERT INTO bdm_stage.mock_unif_ca_result (criterio_ca, estado, detalle)
  SELECT 'CA-C06',
         CASE WHEN COUNT(*) = 0 THEN 'PASSED' ELSE 'FAILED' END,
         'direcciones con mas de un padre=' || CAST(COUNT(*) AS VARCHAR)
  FROM ( SELECT u.cod_dw_persona_ubic
           FROM bdm_datos.unificacion_direccion_mock u
          GROUP BY u.cod_dw_persona_ubic
         HAVING COUNT(DISTINCT u.cod_dw_direccion_unificada) > 1 ) dup;

  -- CA-C07  Sin padres huerfanos: todo cod_dw_direccion_unificada debe existir
  --         como relacion, real o generada. Un FULL de reproceso que borra las
  --         generadas y no las vuelve a crear deja aqui referencias colgando.
  INSERT INTO bdm_stage.mock_unif_ca_result (criterio_ca, estado, detalle)
  SELECT 'CA-C07',
         CASE WHEN COUNT(*) = 0 THEN 'PASSED' ELSE 'FAILED' END,
         'padres inexistentes=' || CAST(COUNT(*) AS VARCHAR)
  FROM ( SELECT DISTINCT u.cod_dw_direccion_unificada
           FROM bdm_datos.unificacion_direccion_mock u
          WHERE u.cod_dw_direccion_unificada IS NOT NULL
            AND NOT EXISTS ( SELECT 1
                               FROM bdm_tempo.v_mock_relacion_persona_ubicacion r
                              WHERE r.cod_dw_persona_ubic = u.cod_dw_direccion_unificada )
            AND NOT EXISTS ( SELECT 1
                               FROM bdm_datos.rpu_generada_mock g
                              WHERE g.cod_dw_persona_ubic = u.cod_dw_direccion_unificada )
       ) huerf;

  -- CA-C08  La DELTA no altera el estado del FULL. Es el criterio que distingue
  --         "converge" de "converge a lo correcto": CA-C02 puede pasar y este
  --         fallar, lo que significa que el estado estable NO es el del FULL.
  INSERT INTO bdm_stage.mock_unif_ca_result (criterio_ca, estado, detalle)
  SELECT 'CA-C08',
         CASE WHEN COUNT(*) = 0                      THEN 'NOT_RUN'
              WHEN SUM(CASE WHEN a.filas = b.filas
                             AND COALESCE(a.checksum, 0) = COALESCE(b.checksum, 0)
                            THEN 0 ELSE 1 END) = 0   THEN 'PASSED'
              ELSE 'FAILED' END,
         COALESCE(LISTAGG(CASE WHEN a.filas <> b.filas
                                 OR COALESCE(a.checksum,0) <> COALESCE(b.checksum,0)
                               THEN a.objeto || '(FULL ' || CAST(a.filas AS VARCHAR)
                                    || ' vs DELTA1 ' || CAST(b.filas AS VARCHAR) || ')'
                          END, ' ') WITHIN GROUP (ORDER BY a.objeto), 'sin diferencias')
  FROM       bdm_stage.mock_unif_convergencia a
  INNER JOIN bdm_stage.mock_unif_convergencia b
          ON b.objeto = a.objeto AND b.etiqueta = 'DELTA1'
  WHERE a.etiqueta = 'FULL';

END;
$$;
