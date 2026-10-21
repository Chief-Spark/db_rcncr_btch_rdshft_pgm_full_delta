import re
import os
# Raiz del paquete, derivada de la ubicacion de este script: el repo se
# clona en sitios distintos y una ruta absoluta lo rompe al primer traslado.
_RAIZ = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                     "deploy", "redshift", "SLCOPRBA-1353")
B = os.path.join(_RAIZ, "SQL") + os.sep

# Las sustituciones van de MAS LARGA a MAS CORTA donde una es prefijo de otra,
# y las que podrian engancharse entre si llevan \b. Es la leccion de
# nov_control contra nov_control_etapa, que produjo nov_control_mock_etapa_mock.
SUST = [
    # procedimientos
    ("bdm_datos.sp_novedades_cargar_mat_acteco_edf",   "bdm_datos.sp_novedades_cargar_mat_acteco_mock"),
    ("bdm_datos.sp_novedades_actividad_economica_edf", "bdm_datos.sp_novedades_actividad_economica_mock"),
    # vistas de insumo
    ("bdm_tempo.v_xpm_relacion_persona_ubicacion",     "bdm_tempo.v_mock_relacion_persona_ubicacion"),
    ("bdm_tempo.v_xpm_reporte_relacion_persona_ubica", "bdm_tempo.v_mock_reporte_relacion_persona_ubica"),
    ("bdm_tempo.v_xpm_actividad_economica_persona",     "bdm_tempo.v_mock_actividad_economica_persona"),
    ("bdm_tempo.v_xpm_ciiu_persona",                   "bdm_tempo.v_mock_ciiu_persona"),
    # contrato y tabla final
    ("bdm_tempo.stg_nov_acteco_etapa_1",               "bdm_tempo.stg_nov_acteco_etapa_1_mock"),
    ("bdm_datos.mat_info_actividad_economica",         "bdm_datos.mat_info_actividad_economica_mock"),
    # staging intermedio: cambia de nombre A PROPOSITO. Real y mock comparten
    # el esquema bdm_tempo y una corrida pisaria a la otra.
    ("bdm_tempo.stg_nov_acteco_maxid",                 "bdm_tempo.stg_mock_nov_acteco_maxid"),
    ("bdm_tempo.stg_nov_acteco_pers",                  "bdm_tempo.stg_mock_nov_acteco_pers"),
    ("bdm_tempo.stg_nov_acteco_flag",                  "bdm_tempo.stg_mock_nov_acteco_flag"),
    ("bdm_tempo.stg_nov_acteco_viva",                  "bdm_tempo.stg_mock_nov_acteco_viva"),
    ("bdm_tempo.stg_nov_acteco_sev",                   "bdm_tempo.stg_mock_nov_acteco_sev"),
]

CAB = ("-- {titulo} (ESPEJO MOCK)\n"
       "-- Espejo de {src}. Generado por SUSTITUCION DE\n"
       "-- FUENTES: no se edita a mano. Regenerar con\n"
       "-- tools/gen_novedades_espejo_acteco.py.\n"
       "-- Solo cambian los nombres de los objetos: _edf -> _mock en los\n"
       "-- procedimientos, v_xpm_* -> v_mock_*, sufijo _mock en el contrato y\n"
       "-- en la tabla final, y stg_nov_* -> stg_mock_nov_* en el staging.\n"
       "-- El diff contra el real debe salir vacio modulo esos nombres.\n\n")


def espejo(src, dst, titulo):
    t = open(B + src, encoding="ascii").read()
    # EL CORTE VA ANCLADO A PRINCIPIO DE LINEA: la cabecera del real nombra
    # procedimientos en prosa y un index() engancharia la primera aparicion,
    # partiria la linea en dos y dejaria un parentesis suelto.
    m = re.search(r'^CREATE OR REPLACE PROCEDURE', t, re.M)
    cuerpo = t[m.start():]
    for a, b in SUST:
        cuerpo = cuerpo.replace(a, b)
    open(B + dst, "w", encoding="ascii").write(CAB.format(titulo=titulo, src=src) + cuerpo)
    print("ok", dst, sum(1 for _ in open(B + dst)), "lineas")


espejo("sp_novedades_actividad_economica_edf.sql",
       "sp_novedades_actividad_economica_mock.sql",
       "Novedades - dominio ACTIVIDAD ECONOMICA")
espejo("sp_novedades_cargar_mat_acteco_edf.sql",
       "sp_novedades_cargar_mat_acteco_mock.sql",
       "Novedades - carga de la tabla final del dominio ACTIVIDAD ECONOMICA")
