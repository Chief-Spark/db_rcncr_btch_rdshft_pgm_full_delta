# db_rcncr_btch_rdshft_pgm — Programas Unificación por escenario

Paquete **type: program** — un SP por escenario + orquestadores por regla.

## Orden de deploy (`deploy.par`)

1. R1: `sp_unificacion_r1_*` + `sp_unificacion_regla1`
2. R2: `sp_unificacion_r2_*` + `sp_unificacion_regla2`
3. R3: `sp_unificacion_r3_geo` + `sp_unificacion_regla3`

## Uso

```sql
CALL bdm_datos.sp_unificacion_regla1();
CALL bdm_datos.sp_unificacion_regla2();
CALL bdm_datos.sp_unificacion_regla3();
```

## Prerrequisitos

`_strct` desplegado (vistas `v_xpm_*`).

## QA DEV

Paridad R2 = 72.448 absorciones (2026-09-04).

## Documentación

Mapa interactivo y checklist Manuel (repo `_dt`): `../db_rcncr_btch_rdshft_dt/docs/MAPA_UNIFICACION_EDF_VIEWS_NEGOCIO.html`
