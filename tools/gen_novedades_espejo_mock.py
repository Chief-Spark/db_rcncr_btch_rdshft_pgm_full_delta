import re
import os
# Raiz del paquete, derivada de la ubicacion de este script: el repo se
# clona en sitios distintos y una ruta absoluta lo rompe al primer traslado.
_RAIZ = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                     "deploy", "redshift", "SLCOPRBA-1353")
B = os.path.join(_RAIZ, "SQL") + os.sep
t = open(B + "sp_novedades_ubicacion_edf.sql", encoding="ascii").read()

# La cabecera del espejo se escribe entera; el corte va ANCLADO A PRINCIPIO DE
# LINEA. Un t.index('CREATE OR REPLACE PROCEDURE') engancharia la primera
# aparicion, que puede estar dentro de un comentario, partiria la linea en dos
# y dejaria un parentesis suelto (leccion SLCOPRBA-1355).
m = re.search(r'^CREATE OR REPLACE PROCEDURE', t, re.M)
cuerpo = t[m.start():]

SUST = [
    ("bdm_datos.sp_novedades_ubicacion_edf",            "bdm_datos.sp_novedades_ubicacion_mock"),
    ("bdm_tempo.v_xpm_relacion_persona_ubicacion",      "bdm_tempo.v_mock_relacion_persona_ubicacion"),
    ("bdm_tempo.v_xpm_ubicacion_estandarizada",         "bdm_tempo.v_mock_ubicacion_estandarizada"),
    ("bdm_tempo.v_xpm_direccion_fisica",                "bdm_tempo.v_mock_direccion_fisica"),
    ("bdm_tempo.v_xpm_contacto_canal",                  "bdm_tempo.v_mock_contacto_canal"),
    ("bdm_tempo.v_xpm_reporte_relacion_persona_ubica",  "bdm_tempo.v_mock_reporte_relacion_persona_ubica"),
    ("bdm_datos.geo_atributos",                         "bdm_datos.geo_atributos_mock"),
    ("bdm_datos.mat_info_ubicacion",                    "bdm_datos.mat_info_ubicacion_mock"),
    ("bdm_tempo.stg_nov_ubica_etapa_9",                 "bdm_tempo.stg_nov_ubica_etapa_9_mock"),
    ("bdm_tempo.stg_nov_ubica_etapa_2",                 "bdm_tempo.stg_nov_ubica_etapa_2_mock"),
    ("bdm_tempo.stg_nov_flag_op_ubica",                 "bdm_tempo.stg_mock_nov_flag_op_ubica"),
    ("bdm_tempo.stg_nov_ubica_e1",                      "bdm_tempo.stg_mock_nov_ubica_e1"),
    ("bdm_tempo.stg_nov_ubica_e3",                      "bdm_tempo.stg_mock_nov_ubica_e3"),
    ("bdm_tempo.stg_nov_ubica_e4",                      "bdm_tempo.stg_mock_nov_ubica_e4"),
    ("bdm_tempo.stg_nov_ubica_e6",                      "bdm_tempo.stg_mock_nov_ubica_e6"),
    ("bdm_tempo.stg_nov_ubica_agr",                     "bdm_tempo.stg_mock_nov_ubica_agr"),
]
for a, b in SUST:
    cuerpo = cuerpo.replace(a, b)

CAB = """-- Novedades - dominio UBICACION (ESPEJO MOCK)
-- Espejo de sp_novedades_ubicacion_edf.sql. Generado por SUSTITUCION DE
-- FUENTES: no se edita a mano. Regenerar con
-- tools/gen_novedades_espejo_mock.py.
--
-- LO UNICO QUE CAMBIA SON LOS NOMBRES DE LOS OBJETOS QUE LEE Y ESCRIBE:
--   v_xpm_*            -> v_mock_*
--   v_rpu_post_unif.   -> v_mock_rpu_post_unificacion
--   geo_atributos      -> geo_atributos_mock
--   mat_info_ubicacion -> mat_info_ubicacion_mock
--   stg_nov_ubica_etapa_N -> ..._mock   (los dos contratos)
--   stg_nov_*             -> stg_mock_nov_*  (el staging intermedio)
-- El staging intermedio tambien cambia de nombre A PROPOSITO: real y mock
-- comparten el esquema bdm_tempo y una corrida pisaria a la otra.
--
-- La logica, los comentarios y las cinco divergencias documentadas son los
-- del archivo real. El diff entre los dos debe salir vacio modulo esta
-- cabecera y la lista de sustituciones de arriba.

"""
open(B + "sp_novedades_ubicacion_mock.sql", "w", encoding="ascii").write(CAB + cuerpo)
print("ok")
