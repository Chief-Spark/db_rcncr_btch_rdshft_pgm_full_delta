import re
import os
# Raiz del paquete, derivada de la ubicacion de este script: el repo se
# clona en sitios distintos y una ruta absoluta lo rompe al primer traslado.
_RAIZ = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                     "deploy", "redshift", "SLCOPRBA-1353")
B = os.path.join(_RAIZ, "SQL") + os.sep

# EL ORDEN IMPORTA Y VA CON \b. stg_distancias_delta es PREFIJO de
# stg_distancias_delta_dedup: la alternativa larga tiene que ir primero o el
# replace produce stg_mock_distancias_delta_dedup a partir del corto mas un
# '_dedup' suelto. Es la leccion de nov_control contra nov_control_etapa.
SUST = [
    (r'bdm_datos\.sp_geo_cargar_distancias',
     'bdm_datos.sp_geo_cargar_distancias_mock'),
    (r'bdm_datos\.geo_distancias\b',    'bdm_datos.geo_distancias_mock'),
    (r'bdm_datos\.geo_lote_control\b',  'bdm_datos.geo_lote_control_mock'),
    (r'bdm_datos\.geo_config\b',        'bdm_datos.geo_config_mock'),
    (r'bdm_tempo\.stg_arcgis_distancias\b',
     'bdm_tempo.stg_mock_arcgis_distancias'),
    (r'bdm_tempo\.stg_distancias_delta_dedup\b',
     'bdm_tempo.stg_mock_distancias_delta_dedup'),
    (r'bdm_tempo\.stg_distancias_delta\b',
     'bdm_tempo.stg_mock_distancias_delta'),
    (r'bdm_tempo\.stg_distancias_prev\b',
     'bdm_tempo.stg_mock_distancias_prev'),
    # EL DESTINO DEL RENAME VA SIN ESQUEMA, de modo que las reglas de arriba
    # no lo alcanzan. Sin esta linea el espejo renombraba la temporal mock al
    # nombre REAL y la corrida siguiente leia la tabla equivocada.
    (r'RENAME TO stg_distancias_delta\b', 'RENAME TO stg_mock_distancias_delta'),
    # El origen alternativo del contrato: en el real es la temporal que llena
    # sp_rcn_geo_02_buscar_resultados; en mock es el archivo de vuelta.
    (r'bdm_tempo\.stg_geo_distancias_crudo\b', 'bdm_stage.mock_geo_distancias'),
]

CAB = """-- ============================================================
-- sp_geo_cargar_distancias_mock  (Reconocer / GEO MOCK - d7)
-- (repo pgm / db_rcncr_btch_rdshft_pgm). UTF-8 sin BOM, sin acentos.
--
-- ESPEJO MOCK de sp_geo_cargar_distancias. Generado por SUSTITUCION DE
-- FUENTES: no se edita a mano. Regenerar con
-- tools/gen_geo_espejo_distancias.py. Mapa:
--     geo_distancias            -> geo_distancias_mock
--     geo_lote_control          -> geo_lote_control_mock
--     geo_config                -> geo_config_mock
--     stg_arcgis_distancias     -> stg_mock_arcgis_distancias
--     stg_distancias_*          -> stg_mock_distancias_*
--     stg_geo_distancias_crudo  -> bdm_stage.mock_geo_distancias
--
-- DIFIERE DEL REAL EN EL ORIGEN Y EN NADA MAS. El real ya traia DOS
-- ORIGENES para el mismo contrato -- COPY cuando in_s3_path empieza por
-- 's3://' y lectura de una temporal en cualquier otro caso --, de modo que
-- el espejo no necesita tocar el COPY: basta que la rama alternativa lea
-- bdm_stage.mock_geo_distancias, que ES el archivo de vuelta con las mismas
-- 12 columnas crudas del contrato Salida_Distancias. A partir de ahi todo es
-- identico: gate de estado del Lote, gate de conteo, conciliacion de tipos
-- con validacion antes de castear, rechazo de filas invalidas, deduplicacion
-- por la clave 1:N, snapshot y reemplazo atomico del delta.
--
-- POR QUE EXISTE: hasta hoy la via mock NO TENIA DISTANCIAS -- 03b lo decia
-- en redondo: "sigue sin haber geo_distancias_mock: las distancias no entran
-- en ninguno de los cinco criterios GEO" --, y sin ellas la tabla dominio
-- mat_info_punto_interes (d7) saldria VACIA en la bateria. Una tabla vacia
-- no prueba nada: es la leccion de "un DELTA en cero no prueba que no haya
-- cambios".
--
-- LO QUE ESTO NO CERTIFICA, igual que en georreferenciacion: que el COPY
-- real lea de verdad un archivo de S3. Es una sentencia y su riesgo es de
-- permisos.
-- ============================================================

"""


def espejo(src, dst):
    t = open(B + src, encoding="ascii").read()
    # EL CORTE VA ANCLADO A PRINCIPIO DE LINEA: la cabecera del real nombra el
    # procedimiento en prosa y un index() engancharia la primera aparicion,
    # partiria la linea en dos y dejaria un parentesis suelto.
    m = re.search(r'^CREATE OR REPLACE PROCEDURE', t, re.M)
    cuerpo = t[m.start():]
    for pat, rep in SUST:
        cuerpo = re.sub(pat, rep, cuerpo)
    open(B + dst, "w", encoding="ascii").write(CAB + cuerpo)
    print("ok", dst, sum(1 for _ in open(B + dst)), "lineas")


espejo("sp_geo_cargar_distancias.sql", "sp_geo_cargar_distancias_mock.sql")
