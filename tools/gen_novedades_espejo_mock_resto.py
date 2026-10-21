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
    # Dominio ACTIVIDAD ECONOMICA. Sin estas cuatro, el espejo del ciclo
    # llamaba a los SP REALES y leia el contrato REAL: el mock escribia en
    # mat_info_actividad_economica en vez de en su _mock. Es exactamente la
    # trampa de paridad que la bitacora da por pagada, y se volvio a pagar.
    ("bdm_datos.sp_novedades_cargar_mat_acteco_edf",    "bdm_datos.sp_novedades_cargar_mat_acteco_mock"),
    ("bdm_datos.sp_novedades_actividad_economica_edf",  "bdm_datos.sp_novedades_actividad_economica_mock"),
    # Dominio UBICACION AGREGADA. El cargador va ANTES que el SP de etapas:
    # su nombre contiene al otro y un replace de cadena los confundiria.
    ("bdm_datos.sp_novedades_cargar_mat_ubi_agregada_edf", "bdm_datos.sp_novedades_cargar_mat_ubi_agregada_mock"),
    ("bdm_datos.sp_novedades_ubi_agregada_edf",         "bdm_datos.sp_novedades_ubi_agregada_mock"),
    # La tabla de Severidad que el cargador deja viva y el orquestador lee y
    # borra. Cambia de nombre, no de sufijo: real y mock comparten bdm_tempo.
    ("bdm_tempo.stg_nov_ubiagr_sev",                    "bdm_tempo.stg_mock_nov_ubiagr_sev"),
    ("bdm_tempo.stg_nov_acteco_etapa_1",                "bdm_tempo.stg_nov_acteco_etapa_1_mock"),
    # Dominio CONTACTABILIDAD. Sin estas dos el espejo del ciclo llamaria al
    # SP real y contaria filas de la tabla real: la misma trampa de paridad
    # que ya se pago con ACTIVIDAD ECONOMICA.
    ("bdm_datos.sp_novedades_contactabilidad_edf",      "bdm_datos.sp_novedades_contactabilidad_mock"),
    ("bdm_datos.mat_info_contactabilidad",              "bdm_datos.mat_info_contactabilidad_mock"),
    ("bdm_datos.mat_info_actividad_economica",          "bdm_datos.mat_info_actividad_economica_mock"),
    ("bdm_datos.sp_rcn_ctl_nov_etapa_marcar",              "bdm_datos.nov_control_mock_etapa_marcar"),
    ("bdm_datos.sp_rcn_ctl_nov_abrir",                     "bdm_datos.nov_control_mock_abrir"),
    ("bdm_datos.sp_rcn_ctl_nov_cerrar",                    "bdm_datos.nov_control_mock_cerrar"),
    # vistas de insumo. El orquestador lee la relacion persona-ubicacion para
    # calcular el watermark nuevo, igual que hace 16_sp_unificacion_ciclo.sql,
    # asi que el espejo tiene que apuntar a la vista mock como el resto.
    ("bdm_tempo.v_xpm_relacion_persona_ubicacion",      "bdm_tempo.v_mock_relacion_persona_ubicacion"),
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
       "-- FUENTES: no se edita a mano. Regenerar con\n"
       "-- tools/gen_novedades_espejo_mock_resto.py.\n"
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
