import re
import os
# Raiz del paquete, derivada de la ubicacion de este script: el repo se
# clona en sitios distintos y una ruta absoluta lo rompe al primer traslado.
_RAIZ = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                     "deploy", "redshift", "SLCOPRBA-1353")
B = os.path.join(_RAIZ, "SQL") + os.sep

# TODO VA CON \b Y POR EXPRESION REGULAR, no con replace de cadena. Es la
# leccion de nov_control contra nov_control_etapa, que sin \b daba
# nov_control_mock_etapa_mock.
SUST = [
    (r'bdm_datos\.sp_novedades_contactabilidad_edf',
     'bdm_datos.sp_novedades_contactabilidad_mock'),
    (r'bdm_datos\.mat_info_contactabilidad\b',
     'bdm_datos.mat_info_contactabilidad_mock'),
    (r'bdm_tempo\.stg_nov_ubica_etapa_9\b',
     'bdm_tempo.stg_nov_ubica_etapa_9_mock'),
    (r'bdm_tempo\.v_xpm_relacion_persona_ubicacion\b',
     'bdm_tempo.v_mock_relacion_persona_ubicacion'),
    (r'bdm_tempo\.v_xpm_reporte_relacion_persona_ubica\b',
     'bdm_tempo.v_mock_reporte_relacion_persona_ubica'),
]

CAB = ("-- Novedades - dominio CONTACTABILIDAD (ESPEJO MOCK)\n"
       "-- Espejo del real. Generado por\n"
       "-- SUSTITUCION DE FUENTES: no se edita a mano. Regenerar con\n"
       "-- tools/gen_novedades_espejo_contact.py.\n"
       "-- Solo cambian los nombres de los objetos: _edf -> _mock en el\n"
       "-- procedimiento y en la tabla final, sufijo _mock en la etapa 9 de\n"
       "-- Ubicacion y v_xpm_* -> v_mock_* en las dos vistas de insumo. El diff\n"
       "-- contra el real debe salir vacio modulo esos nombres.\n"
       "-- La justificacion de D-NOV-08 vive en el archivo real.\n\n")


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


espejo("sp_novedades_contactabilidad_edf.sql",
       "sp_novedades_contactabilidad_mock.sql")
