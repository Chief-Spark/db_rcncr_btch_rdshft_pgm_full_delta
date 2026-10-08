-- ============================================================
-- sp_ordenamiento_validar_mock.sql
-- Ejecuta matriz CA-O01..CA-O12 → bdm_stage.mock_ord_ca_result
-- ============================================================

CREATE OR REPLACE PROCEDURE bdm_datos.sp_ordenamiento_validar_mock()
NONATOMIC
LANGUAGE plpgsql
AS $$
BEGIN
TRUNCATE TABLE bdm_stage.mock_ord_ca_result;

-- CA-O01: hay scores DIR/TEL/EMA (CEL también en mock)
INSERT INTO bdm_stage.mock_ord_ca_result (criterio_ca, estado, detalle)
SELECT 'CA-O01',
       CASE WHEN COUNT(DISTINCT canal) >= 3 THEN 'PASSED' ELSE 'FAILED' END,
       'canales_distintos=' || COUNT(DISTINCT canal)::VARCHAR
         || ' scores=' || COUNT(*)::VARCHAR
FROM bdm_stage.mock_ord_score;

-- CA-O02: betas 47 en catálogo real (compartido) — si no hay permiso, marcar FAILED
INSERT INTO bdm_stage.mock_ord_ca_result (criterio_ca, estado, detalle)
SELECT 'CA-O02',
       CASE WHEN COUNT(*) = 47 THEN 'PASSED' ELSE 'FAILED' END,
       'beta_ordenamiento n=' || COUNT(*)::VARCHAR
FROM bdm_datos.beta_ordenamiento;

-- CA-O03: hijas con orden = 0
INSERT INTO bdm_stage.mock_ord_ca_result (criterio_ca, estado, detalle)
SELECT 'CA-O03',
       CASE WHEN COUNT(*) = 0 THEN 'PASSED' ELSE 'FAILED' END,
       'hijas_con_orden=' || COUNT(*)::VARCHAR
FROM bdm_stage.mock_ord_rpu r
JOIN bdm_stage.mock_ord_prioridad p
  ON p.cod_dw_persona_ubic = r.cod_dw_persona_ubic
WHERE COALESCE(r.ind_unificacion, 0) = 1;

-- CA-O04: RANK-01 persona 20001 — lugar 1 tiene score máximo
INSERT INTO bdm_stage.mock_ord_ca_result (criterio_ca, estado, detalle)
SELECT 'CA-O04',
       CASE WHEN MAX(CASE WHEN lugar = 1 THEN score END)
                 = MAX(score)
            AND COUNT(*) = 2 THEN 'PASSED' ELSE 'FAILED' END,
       '20001 DIR scores distintos + lugar1=max'
FROM bdm_stage.mock_ord_score
WHERE id_buro_persona = 20001 AND canal = 'DIR';

-- CA-O05: F3-02 hija 91019 sin score
INSERT INTO bdm_stage.mock_ord_ca_result (criterio_ca, estado, detalle)
SELECT 'CA-O05',
       CASE WHEN COUNT(*) = 0 THEN 'PASSED' ELSE 'FAILED' END,
       'scores_hija_91019=' || COUNT(*)::VARCHAR
FROM bdm_stage.mock_ord_score
WHERE cod_dw_persona_ubic = 91019;

-- CA-O06: canales independientes (20001 tiene DIR/TEL/EMA con lugar 1 propio)
INSERT INTO bdm_stage.mock_ord_ca_result (criterio_ca, estado, detalle)
SELECT 'CA-O06',
       CASE WHEN COUNT(DISTINCT canal) >= 3 THEN 'PASSED' ELSE 'FAILED' END,
       '20001 canales con lugar1=' || COUNT(DISTINCT canal)::VARCHAR
FROM bdm_stage.mock_ord_score
WHERE id_buro_persona = 20001 AND lugar = 1;

-- CA-O07: orden_prioridad = lugar DIR (20001)
INSERT INTO bdm_stage.mock_ord_ca_result (criterio_ca, estado, detalle)
SELECT 'CA-O07',
       CASE WHEN COUNT(*) = 0 THEN 'PASSED' ELSE 'FAILED' END,
       'mismatches_orden_vs_lugar=' || COUNT(*)::VARCHAR
FROM bdm_stage.mock_ord_score s
JOIN bdm_stage.mock_ord_prioridad p
  ON p.cod_dw_persona_ubic = s.cod_dw_persona_ubic
 AND p.id_buro_persona = s.id_buro_persona
WHERE s.id_buro_persona = 20001
  AND s.canal = 'DIR'
  AND p.orden_prioridad <> s.lugar;

-- CA-O08: empate 20010 — dos DIR mismo score
INSERT INTO bdm_stage.mock_ord_ca_result (criterio_ca, estado, detalle)
SELECT 'CA-O08',
       CASE WHEN COUNT(*) = 2
             AND MIN(score) = MAX(score) THEN 'PASSED' ELSE 'FAILED' END,
       '20010 n=' || COUNT(*)::VARCHAR || ' score=' || MIN(score)::VARCHAR
FROM bdm_stage.mock_ord_score
WHERE id_buro_persona = 20010 AND canal = 'DIR';

-- CA-O09: TEL-02 — 20013 ambos TEL mismo score
INSERT INTO bdm_stage.mock_ord_ca_result (criterio_ca, estado, detalle)
SELECT 'CA-O09',
       CASE WHEN COUNT(*) = 2
             AND MIN(score) = MAX(score) THEN 'PASSED' ELSE 'FAILED' END,
       '20013 TEL scores iguales (TEL020 no mueve)'
FROM bdm_stage.mock_ord_score
WHERE id_buro_persona = 20013 AND canal = 'TEL';

-- CA-O10: EMA-03 — 20014 ambos EMA mismo score
INSERT INTO bdm_stage.mock_ord_ca_result (criterio_ca, estado, detalle)
SELECT 'CA-O10',
       CASE WHEN COUNT(*) = 2
             AND MIN(score) = MAX(score) THEN 'PASSED' ELSE 'FAILED' END,
       '20014 EMA scores iguales (003/007 fuera SUM)'
FROM bdm_stage.mock_ord_score
WHERE id_buro_persona = 20014 AND canal = 'EMA';

-- CA-O11: CEL-02 — 20012 score 220 (default)
INSERT INTO bdm_stage.mock_ord_ca_result (criterio_ca, estado, detalle)
SELECT 'CA-O11',
       CASE WHEN COUNT(*) = 1 AND MIN(score) = 220.0000 THEN 'PASSED' ELSE 'FAILED' END,
       '20012 CEL score=' || COALESCE(MIN(score)::VARCHAR, 'NULL')
FROM bdm_stage.mock_ord_score
WHERE id_buro_persona = 20012 AND canal = 'CEL';

-- CA-O12: 20003 tres lugares
INSERT INTO bdm_stage.mock_ord_ca_result (criterio_ca, estado, detalle)
SELECT 'CA-O12',
       CASE WHEN COUNT(*) = 3
             AND MIN(lugar) = 1 AND MAX(lugar) = 3 THEN 'PASSED' ELSE 'FAILED' END,
       '20003 DIR n=' || COUNT(*)::VARCHAR
FROM bdm_stage.mock_ord_score
WHERE id_buro_persona = 20003 AND canal = 'DIR';
END;
$$;
-- SLCOPRBA-1355: re-DPLY DEV post DROP SCHEMA strct #256
