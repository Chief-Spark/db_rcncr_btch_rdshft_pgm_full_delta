import re
import os
# Raiz del paquete, derivada de la ubicacion de este script: el repo se
# clona en sitios distintos y una ruta absoluta lo rompe al primer traslado.
_RAIZ = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                     "deploy", "redshift", "SLCOPRBA-1353")
B = os.path.join(_RAIZ, "SQL") + os.sep

# TODO VA CON \b Y POR EXPRESION REGULAR, no con replace de cadena. Aqui hay
# nombres que son prefijo de otros -- stg_nov_ubiagr_a1 lo es de _a10 y de
# _a11 -- y un replace a secas produciria stg_mock_nov_ubiagr_a10 a partir de
# a1 mas un '0' suelto. Es la misma leccion que nov_control contra
# nov_control_etapa, que dio nov_control_mock_etapa_mock.
SUST = [
    # procedimiento
    (r'bdm_datos\.sp_novedades_ubi_agregada_edf',
     'bdm_datos.sp_novedades_ubi_agregada_mock'),
    # las dos etapas de Ubicacion que lee, y su propia etapa de salida
    (r'bdm_tempo\.stg_nov_ubica_etapa_9\b', 'bdm_tempo.stg_nov_ubica_etapa_9_mock'),
    (r'bdm_tempo\.stg_nov_ubica_etapa_2\b', 'bdm_tempo.stg_nov_ubica_etapa_2_mock'),
    (r'bdm_tempo\.stg_nov_ubiagr_etapa_final\b',
     'bdm_tempo.stg_nov_ubiagr_etapa_final_mock'),
    # las 16 intermedias cambian de nombre A PROPOSITO, no de sufijo: real y
    # mock comparten el esquema bdm_tempo y una corrida pisaria a la otra.
    (r'bdm_tempo\.stg_nov_ubiagr_(a\d+|r\d+|final1)\b',
     r'bdm_tempo.stg_mock_nov_ubiagr_\1'),
]

CAB = ("-- Novedades - dominio UBICACION AGREGADA (ESPEJO MOCK)\n"
       "-- Espejo de sp_novedades_ubi_agregada_edf.sql. Generado por\n"
       "-- SUSTITUCION DE FUENTES: no se edita a mano. Regenerar con\n"
       "-- tools/gen_novedades_espejo_ubiagr.py.\n"
       "-- Solo cambian los nombres de los objetos: _edf -> _mock en el\n"
       "-- procedimiento, sufijo _mock en las dos etapas de entrada y en la de\n"
       "-- salida, y stg_nov_ubiagr_* -> stg_mock_nov_ubiagr_* en las 16\n"
       "-- intermedias. El diff contra el real debe salir vacio modulo esos\n"
       "-- nombres.\n\n")


def espejo(src, dst):
    t = open(B + src, encoding="ascii").read()
    # EL CORTE VA ANCLADO A PRINCIPIO DE LINEA: la cabecera del real nombra
    # procedimientos en prosa y un index() engancharia la primera aparicion,
    # partiria la linea en dos y dejaria un parentesis suelto.
    m = re.search(r'^CREATE OR REPLACE PROCEDURE', t, re.M)
    cuerpo = t[m.start():]
    for pat, rep in SUST:
        cuerpo = re.sub(pat, rep, cuerpo)
    open(B + dst, "w", encoding="ascii").write(CAB + cuerpo)
    print("ok", dst, sum(1 for _ in open(B + dst)), "lineas")


espejo("sp_novedades_ubi_agregada_edf.sql", "sp_novedades_ubi_agregada_mock.sql")
