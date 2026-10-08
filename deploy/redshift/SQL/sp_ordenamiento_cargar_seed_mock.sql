-- ============================================================
-- sp_ordenamiento_cargar_seed_mock.sql
-- Carga personas MOCK 20001-20014 (HTML / CA-O01..CA-O12)
-- Schema: bdm_datos (tablas mock en bdm_stage)
-- ============================================================

CREATE OR REPLACE PROCEDURE bdm_datos.sp_ordenamiento_cargar_seed_mock()
NONATOMIC
LANGUAGE plpgsql
AS $$
BEGIN
TRUNCATE TABLE bdm_stage.mock_ord_escenario;
TRUNCATE TABLE bdm_stage.mock_ord_rpu;
TRUNCATE TABLE bdm_stage.mock_ord_score;
TRUNCATE TABLE bdm_stage.mock_ord_prioridad;

-- Catálogo escenario → criterio
INSERT INTO bdm_stage.mock_ord_escenario
  (id_buro_persona, cod_escenario, criterio_ca, descripcion, es_html_ejemplo) VALUES
(20001, 'RANK-01',     'CA-O04', '2 DIR scores distintos → lugar 1/2', 1),
(20001, 'SALIDA',      'CA-O07', 'orden_prioridad = lugar DIR', 1),
(20002, 'DIR-1',       'CA-O01', '1 DIR trivial lugar 1', 1),
(20003, 'RANK-MULTI',  'CA-O12', '3 DIR lugares 1/2/3', 1),
(20004, 'TEL-RANK',    'CA-O06', 'TEL válido vs NO VALIDA', 1),
(20005, 'TEL-1',       'CA-O01', '1 TEL lugar 1', 1),
(20006, 'CEL-RANK',    'CA-O01', '2 CEL operadores distintos', 1),
(20007, 'CEL-1',       'CA-O01', '1 CEL lugar 1', 1),
(20008, 'EMA-RANK',    'CA-O06', '2 EMA ranking independiente', 1),
(20009, 'EMA-1',       'CA-O01', '1 EMA lugar 1', 1),
(20010, 'RANK-02',     'CA-O08', '2 DIR mismo score (empate)', 1),
(20011, 'F3-02',       'CA-O05', 'Padre score / hija sin score ni orden', 1),
(20011, 'HIJAS-GATE',  'CA-O03', 'Hija no tiene orden_prioridad', 1),
(20012, 'CEL-02',      'CA-O11', 'Prefijo sin catálogo → default 0.22', 1),
(20013, 'TEL-02',      'CA-O09', 'Solo cambia TEL020 → mismo score', 1),
(20014, 'EMA-03',      'CA-O10', 'Solo cambian EMA003/007 → mismo score', 1);

-- RPUs
INSERT INTO bdm_stage.mock_ord_rpu
  (id_buro_persona, cod_pin_persona, cod_dw_persona_ubic, ind_unificacion, etiqueta) VALUES
-- 20001 RANK-01
(20001, 90001, 91001, NULL, 'casa'),
(20001, 90001, 91002, NULL, 'oficina'),
-- 20002
(20002, 90002, 91003, NULL, 'unica_dir'),
-- 20003
(20003, 90003, 91004, NULL, 'dir_a'),
(20003, 90003, 91005, NULL, 'dir_b'),
(20003, 90003, 91006, NULL, 'dir_c'),
-- 20004 TEL
(20004, 90004, 91007, NULL, 'tel_valida_dir'),
(20004, 90004, 91008, NULL, 'tel_novalida_dir'),
-- 20005
(20005, 90005, 91009, NULL, 'tel_unica'),
-- 20006 CEL
(20006, 90006, 91010, NULL, 'cel_310'),
(20006, 90006, 91011, NULL, 'cel_320'),
-- 20007
(20007, 90007, 91012, NULL, 'cel_unica'),
-- 20008 EMA
(20008, 90008, 91013, NULL, 'ema_gmail'),
(20008, 90008, 91014, NULL, 'ema_corp'),
-- 20009
(20009, 90009, 91015, NULL, 'ema_unica'),
-- 20010 empate
(20010, 90010, 91016, NULL, 'empate_a'),
(20010, 90010, 91017, NULL, 'empate_b'),
-- 20011 F3-02 padre + hija
(20011, 90011, 91018, NULL, 'padre_ganador'),
(20011, 90011, 91019, 1,    'hija_unif'),
-- 20012 CEL-02
(20012, 90012, 91020, NULL, 'cel_prefijo_999'),
-- 20013 TEL-02 (dos contactos TEL, mismo score)
(20013, 90013, 91021, NULL, 'tel_base'),
(20013, 90013, 91022, NULL, 'tel_solo_tel020'),
-- 20014 EMA-03
(20014, 90014, 91023, NULL, 'ema_base'),
(20014, 90014, 91024, NULL, 'ema_solo_excluidas');

-- Scores
INSERT INTO bdm_stage.mock_ord_score
  (id_buro_persona, cod_dw_persona_ubic, cod_pin_persona, canal, score, lugar, nota) VALUES
-- 20001 DIR
(20001, 91001, 90001, 'DIR', 850.0000, 1, 'RANK-01 mayor'),
(20001, 91002, 90001, 'DIR', 700.0000, 2, 'RANK-01 menor'),
(20001, 91001, 90001, 'TEL', 400.0000, 1, 'canal aparte'),
(20001, 91001, 90001, 'EMA', 300.0000, 1, 'canal aparte'),
-- 20002
(20002, 91003, 90002, 'DIR', 640.0000, 1, 'unica'),
-- 20003
(20003, 91006, 90003, 'DIR', 900.0000, 1, 'mejor'),
(20003, 91004, 90003, 'DIR', 750.0000, 2, 'media'),
(20003, 91005, 90003, 'DIR', 600.0000, 3, 'menor'),
-- 20004 TEL
(20004, 91007, 90004, 'TEL', 420.0000, 1, 'VALIDA'),
(20004, 91008, 90004, 'TEL', 210.0000, 2, 'NO VALIDA'),
(20004, 91007, 90004, 'DIR', 650.0000, 1, 'dir ancla'),
-- 20005
(20005, 91009, 90005, 'TEL', 380.0000, 1, 'unica'),
-- 20006 CEL
(20006, 91010, 90006, 'CEL', 620.0000, 1, 'prefijo 310 catalogo'),
(20006, 91011, 90006, 'CEL', 480.0000, 2, 'prefijo 320'),
-- 20007
(20007, 91012, 90007, 'CEL', 500.0000, 1, 'unica'),
-- 20008 EMA
(20008, 91013, 90008, 'EMA', 350.0000, 1, 'gmail'),
(20008, 91014, 90008, 'EMA', 280.0000, 2, 'corp'),
-- 20009
(20009, 91015, 90009, 'EMA', 290.0000, 1, 'unica'),
-- 20010 empate (mismo score)
(20010, 91016, 90010, 'DIR', 777.0000, 1, 'empate — ROW_NUMBER'),
(20010, 91017, 90010, 'DIR', 777.0000, 2, 'empate — mismo score'),
-- 20011 solo padre
(20011, 91018, 90011, 'DIR', 639.7849, 1, 'padre; hija 91019 sin fila'),
(20011, 91018, 90011, 'TEL', 376.5281, 1, 'padre'),
(20011, 91018, 90011, 'EMA', 281.7705, 1, 'padre'),
-- 20012 CEL-02 default
(20012, 91020, 90012, 'CEL', 220.0000, 1, 'default 0.22 → cel018=22'),
-- 20013 TEL-02: ambos contactos mismo score (TEL020 no suma)
(20013, 91021, 90013, 'TEL', 376.5000, 1, 'base'),
(20013, 91022, 90013, 'TEL', 376.5000, 2, 'mismo score pese a TEL020'),
-- 20014 EMA-03: mismo score
(20014, 91023, 90014, 'EMA', 281.7705, 1, 'base'),
(20014, 91024, 90014, 'EMA', 281.7705, 2, 'mismo score pese a EMA003/007');

-- orden_prioridad solo ganadoras DIR (no hijas)
INSERT INTO bdm_stage.mock_ord_prioridad
  (id_buro_persona, cod_dw_persona_ubic, orden_prioridad) VALUES
(20001, 91001, 1),
(20001, 91002, 2),
(20002, 91003, 1),
(20003, 91006, 1),
(20003, 91004, 2),
(20003, 91005, 3),
(20004, 91007, 1),
(20010, 91016, 1),
(20010, 91017, 2),
(20011, 91018, 1);
-- 91019 hija: INTENCIONALMENTE sin fila en mock_ord_prioridad
END;
$$;
-- SLCOPRBA-1355: re-DPLY DEV post DROP SCHEMA strct #256
