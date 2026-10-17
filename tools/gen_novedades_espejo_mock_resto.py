import re
import os
# Raiz del paquete, derivada de la ubicacion de este script: el repo se
# clona en sitios distintos y una ruta absoluta lo rompe al primer traslado.
_RAIZ = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                     "deploy", "redshift", "SLCOPRBA-1353")
B = os.path.join(_RAIZ, "SQL") + os.sep

SUST = [
    # procedimientos
    ("bdm_datos.sp_novedades_cargar_mat_ubicacion_edf", "bdm_datos.sp_novedades_cargar_mat_ubicacion_mock"),
    ("bdm_datos.sp_novedades_ubicacion_edf",            "bdm_datos.sp_novedades_ubicacion_mock"),
    ("bdm_datos.sp_novedades_ciclo_edf",                "bdm_datos.sp_novedades_mock_ciclo"),
    # el nombre suelto, para que el RAISE del log no mienta sobre quien corre
    ("sp_novedades_ciclo_edf:",                         "sp_novedades_mock_ciclo:"),
    ("bdm_datos.nov_control_etapa_marcar",              "bdm_datos.nov_control_mock_etapa_marcar"),
    ("bdm_datos.nov_control_abrir",                     "bdm_datos.nov_control_mock_abrir"),
    ("bdm_datos.nov_control_cerrar",                    "bdm_datos.nov_control_mock_cerrar"),
    # tablas
    ("bdm_datos.mat_info_ubicacion",                    "bdm_datos.mat_info_ubicacion_mock"),
    ("bdm_tempo.stg_nov_ubica_etapa_9",                 "bdm_tempo.stg_nov_ubica_etapa_9_mock"),
    ("bdm_tempo.stg_nov_ubica_etapa_2",                 "bdm_tempo.stg_nov_ubica_etapa_2_mock"),
]
# \b impide que nov_control enganche el prefijo de nov_control_etapa
TAB = [(r'\bbdm_datos\.nov_control_etapa\b', 'bdm_datos.nov_control_etapa_mock'),
       (r'\bbdm_datos\.nov_control\b',       'bdm_datos.nov_control_mock')]

def espejo(src, dst, cab):
    t = open(B + src, encoding="ascii").read()
    m = re.search(r'^CREATE OR REPLACE PROCEDURE', t, re.M)
    cuerpo = t[m.start():]
    for a, b in SUST:
        cuerpo = cuerpo.replace(a, b)
    for pat, rep in TAB:
        cuerpo = re.sub(pat, rep, cuerpo)
    open(B + dst, "w", encoding="ascii").write(cab + cuerpo)

CAB = ("-- {titulo} (ESPEJO MOCK)\n"
       "-- Espejo de {src}. Generado por SUSTITUCION DE\n"
       "-- FUENTES: no se edita a mano. Regenerar con scratchpad/gen_nov_mocks2.py.\n"
       "-- Solo cambian los nombres de los objetos: _edf -> _mock en los\n"
       "-- procedimientos, y sufijo _mock en las tablas que lee y escribe.\n"
       "-- El diff contra el real debe salir vacio modulo esos nombres.\n\n")

espejo("sp_nov_control_abrir_cerrar.sql", "sp_nov_control_mock_abrir_cerrar.sql",
       CAB.format(titulo="Novedades - control de corrida", src="sp_nov_control_abrir_cerrar.sql"))
espejo("sp_novedades_cargar_mat_ubicacion_edf.sql", "sp_novedades_cargar_mat_ubicacion_mock.sql",
       CAB.format(titulo="Novedades - carga de la tabla final del dominio UBICACION",
                  src="sp_novedades_cargar_mat_ubicacion_edf.sql"))
espejo("sp_novedades_ciclo_edf.sql", "sp_novedades_mock_ciclo.sql",
       CAB.format(titulo="Novedades - orquestador del ciclo", src="sp_novedades_ciclo_edf.sql"))
print("ok")
