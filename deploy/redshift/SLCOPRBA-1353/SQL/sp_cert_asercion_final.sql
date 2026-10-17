-- ============================================================
-- sp_cert_asercion_final.sql
-- SLCOPRBA-1355: la pieza que convierte el tablero en un GATE.
-- UTF-8 sin BOM, sin acentos.
--
-- POR QUE EXISTE, Y POR QUE NO EXISTIA:
--   hasta hoy la cadena de certificacion era SOLO INFORME. Ni
--   sp_unificacion_mock_gate_arq, ni sp_cert_evaluar_criterios_mock, ni el
--   gate de convergencia, ni ninguno de los scripts de validacion contienen
--   un solo RAISE: escriben PASSED o FAILED en una tabla y el job sigue
--   VERDE. El titular 45 | 45 | 0 es un numero que alguien tiene que leer.
--   Funciono porque lo leiamos en cada corrida, no porque el pipeline lo
--   exigiera.
--
--   Lo unico que tumba Jenkins hoy es un error SQL durante el deploy
--   ([REDSHIFT:112]). Este procedimiento usa exactamente ese mecanismo: si
--   quedan criterios en FAILED, lanza una excepcion y el job cae.
--
-- QUE CUENTA COMO FALLO, Y QUE NO:
--   solo FAILED. Un criterio puede legitimamente no estar en PASSED:
--     NO_IMPLEMENTADO  la funcionalidad no existe y esta declarado
--     SIN_DATO         implementado, pero la bateria no lo ejercita
--     BLOQUEADO        depende de un insumo externo que no tenemos
--     FUERA_DE_ALCANCE requiere acta del area funcional
--     REVISION_MANUAL  el documento y el legado dicen cosas distintas
--     NO_APLICA        correcto para esa fase
--   Ninguno de esos es un defecto del codigo. FAILED si: significa que la
--   consulta verifico el criterio y NO se cumple. Eso es lo que debe parar
--   la linea.
--
-- ALCANCE ACTIVO HOY: 'UNIFICACION'.
--   Ordenamiento NO se asercion todavia a proposito: su tablero acaba de
--   nacer y arrastra defectos reales ya identificados (el ranking empata sin
--   desempate, EMA024 es constante, cuatro divisores desalineados). Encender
--   el gate antes de corregirlos solo serviria para dejar el job en rojo sin
--   informacion nueva. Se enciende anadiendo 'ORDENAMIENTO' a la llamada del
--   .par de dt en cuanto esos defectos esten corregidos; el procedimiento ya
--   lo soporta.
--
-- NONATOMIC (leccion #13). Rollback: DROP PROCEDURE con firma exacta
-- (#12/#14).
-- ============================================================

CREATE OR REPLACE PROCEDURE bdm_datos.sp_cert_asercion_final(
    p_alcance VARCHAR   -- UNIFICACION | ORDENAMIENTO | TODO
)
NONATOMIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_unif_n     INTEGER := 0;
    v_unif_lista VARCHAR(2000) := 'ninguno';
    v_ord_n      INTEGER := 0;
    v_ord_lista  VARCHAR(2000) := 'ninguno';
    v_gate_n     INTEGER := 0;
    v_gate_lista VARCHAR(2000) := 'ninguno';
BEGIN

    -- --------------------------------------------------------
    -- Unificacion: los 51 criterios menos GOB-03, que es el alcance que QA
    -- puede probar hoy (mismo recorte que el titular).
    --
    -- SLCOPRBA-1355: GEO ENTRA EN EL GATE. Antes decia "menos GEO y GOB-03"
    -- y el WHERE llevaba bloque <> 'GEO', escrito asi a proposito: no se
    -- pone como gate algo que no ha corrido nunca. Ya corrio -- job
    -- DEV/DATABASE #402, los cinco criterios en PASSED sobre Redshift real
    -- con el tablero en 50/50 --, de modo que el motivo desaparecio. Desde
    -- aqui, un FAILED en CA-01..CA-05 tumba el build, que es lo que
    -- significa certificar.
    -- --------------------------------------------------------
    IF p_alcance IN ('UNIFICACION', 'TODO') THEN
        SELECT COUNT(*),
               COALESCE(NULLIF(LISTAGG(c.criterio, ', ') WITHIN GROUP (ORDER BY c.criterio), ''), 'ninguno')
          INTO v_unif_n, v_unif_lista
          FROM      bdm_datos.cert_criterio c
          JOIN      bdm_datos.v_cert_ultimo r ON r.criterio = c.criterio
         WHERE c.criterio <> 'GOB-03'
           AND r.estado    = 'FAILED';

        -- El gate por arquetipo: sus FAILED son aserciones duras sobre la
        -- matriz mock y no siempre se reflejan en un criterio del documento.
        SELECT COUNT(*),
               COALESCE(NULLIF(LISTAGG(g.criterio_ca, ', ') WITHIN GROUP (ORDER BY g.criterio_ca), ''), 'ninguno')
          INTO v_gate_n, v_gate_lista
          FROM bdm_stage.mock_unif_ca_result g
         WHERE g.estado = 'FAILED';
    END IF;

    -- --------------------------------------------------------
    -- Ordenamiento: los criterios del RF que el evaluador si verifica.
    -- --------------------------------------------------------
    IF p_alcance IN ('ORDENAMIENTO', 'TODO') THEN
        SELECT COUNT(*),
               COALESCE(NULLIF(LISTAGG(c.criterio, ', ') WITHIN GROUP (ORDER BY c.criterio), ''), 'ninguno')
          INTO v_ord_n, v_ord_lista
          FROM      bdm_datos.cert_criterio_ord c
          JOIN      bdm_datos.v_cert_ord_ultimo r ON r.criterio = c.criterio
         WHERE r.estado = 'FAILED';
    END IF;

    -- --------------------------------------------------------
    -- El veredicto. Un solo RAISE con todo lo que fallo, para que el log de
    -- Jenkins diga QUE hay que mirar sin tener que abrir la base.
    --
    -- SIETE ARGUMENTOS Y NI UN PARENTESIS: el RAISE de Redshift admite
    -- VARIABLES, no expresiones. La gramatica es
    --   RAISE level 'format' [, variable [, ...]];
    -- y una funcion en la lista es un error de SINTAXIS en el propio CREATE:
    --   42601: syntax error at or near "NULLIF"
    -- Tumbo el job DEV/DATABASE #367 en el archivo 74 de 74. PostgreSQL si
    -- admite expresiones ahi, de modo que el banco local no puede verlo: es
    -- el segundo punto ciego del banco, hermano de DELTA.
    -- Por eso el NULLIF que evitaba imprimir '[]' vive ahora en los SELECT
    -- de arriba, que son SQL normal, y no aqui.
    -- --------------------------------------------------------
    IF (v_unif_n + v_ord_n + v_gate_n) > 0 THEN
        RAISE EXCEPTION
          'CERTIFICACION EN ROJO (alcance %). Unificacion: % criterio(s) FAILED [%]. Gate por arquetipo: % FAILED [%]. Ordenamiento: % criterio(s) FAILED [%]. Revisar el detalle en cert_resultado / cert_resultado_ord / mock_unif_ca_result.',
          p_alcance,
          v_unif_n, v_unif_lista,
          v_gate_n, v_gate_lista,
          v_ord_n,  v_ord_lista;
    END IF;

    RAISE INFO 'CERTIFICACION OK (alcance %): ningun criterio en FAILED.', p_alcance;

END;
$$;
