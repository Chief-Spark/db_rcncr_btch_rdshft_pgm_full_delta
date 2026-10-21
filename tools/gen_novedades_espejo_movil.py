import re
import os
# Raiz del paquete, derivada de la ubicacion de este script: el repo se
# clona en sitios distintos y una ruta absoluta lo rompe al primer traslado.
_RAIZ = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                     "deploy", "redshift", "SLCOPRBA-1353")
B = os.path.join(_RAIZ, "SQL") + os.sep

# TODO VA CON \b. Leccion de nov_control contra nov_control_etapa.
SUST = [
    (r'bdm_datos\.sp_novedades_movilidad_edf',
     'bdm_datos.sp_novedades_movilidad_mock'),
    (r'bdm_datos\.mat_info_movilidad\b', 'bdm_datos.mat_info_movilidad_mock'),
    (r'bdm_datos\.nov_movilidad_foto\b', 'bdm_datos.nov_movilidad_foto_mock'),
    (r'bdm_datos\.mat_info_basica\b',    'bdm_datos.mat_info_basica_mock'),
    (r'bdm_tempo\.stg_nov_ubica_etapa_9\b',
     'bdm_tempo.stg_nov_ubica_etapa_9_mock'),
    # Las tres temporales cambian de NOMBRE y no de sufijo: real y mock
    # comparten bdm_tempo y una corrida pisaria a la otra.
    (r'bdm_tempo\.stg_nov_movil_(hoy|prev|evento)\b',
     r'bdm_tempo.stg_mock_nov_movil_\1'),
]

CAB = ("-- Novedades - dominio MOVILIDAD (ESPEJO MOCK)\n"
       "-- Espejo del real. Generado por\n"
       "-- SUSTITUCION DE FUENTES: no se edita a mano. Regenerar con\n"
       "-- tools/gen_novedades_espejo_movil.py.\n"
       "-- Cambian: el procedimiento, la tabla final, la foto, la etapa 9 de\n"
       "-- Ubicacion, mat_info_basica y las tres temporales (que cambian de\n"
       "-- nombre, no de sufijo). El diff contra el real debe salir vacio\n"
       "-- modulo esos nombres. Las justificaciones viven en el real.\n\n")


def espejo(src, dst):
    t = open(B + src, encoding="ascii").read()
    # EL CORTE VA ANCLADO A PRINCIPIO DE LINEA: la cabecera del real nombra el
    # procedimiento en prosa y un index() engancharia la primera aparicion.
    m = re.search(r'^CREATE OR REPLACE PROCEDURE', t, re.M)
    cuerpo = t[m.start():]
    for pat, rep in SUST:
        cuerpo = re.sub(pat, rep, cuerpo)
    open(B + dst, "w", encoding="ascii").write(CAB + cuerpo)
    print("ok", dst, sum(1 for _ in open(B + dst)), "lineas")


espejo("sp_novedades_movilidad_edf.sql", "sp_novedades_movilidad_mock.sql")
