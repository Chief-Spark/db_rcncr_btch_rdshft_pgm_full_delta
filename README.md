# Reconocer Redshift — paquete PGM (programas)

Unificación de direcciones, Ordenamiento, GEO y Novedades de Experian
Reconocer, migrados de Teradata a Amazon Redshift.

**`type: program` · `order: 2` · se despliega ENTRE `strct` y `dt`.**

Sólo procedimientos almacenados. Ninguna tabla y ningún dato.

## Qué hay en el paquete

| Ruta | Contenido |
|---|---|
| `deploy/redshift/SLCOPRBA-1353/deploy.par` | el orden de despliegue, una línea por archivo |
| `deploy/redshift/SLCOPRBA-1353/SQL/` | 116 procedimientos |
| `deploy/redshift/SLCOPRBA-1353/rollback.par` | el reverso exacto, en orden inverso |
| `deploy/redshift/SLCOPRBA-1353/RevSQL/` | un `DROP PROCEDURE` por archivo |

De esos 116, **51 son espejos `_mock`**: la batería de certificación corre
contra datos sembrados, nunca contra el datashare. Cada espejo se genera por
sustitución de fuentes a partir de su original y el `diff` entre los dos debe
salir vacío salvo esos nombres.

## Dos reglas que no se negocian

1. **La firma de un orquestador no se toca.** El Framework Batch exige seis
   parámetros `VARCHAR` en este orden: `in_solicitud`, `in_nit_suscriptor`,
   `in_path_archivo`, `in_nemotecnico` (= MODO), `in_id_facturacion` (= LOTE),
   `in_fecha_ejecucion` (= FECHA). Los tres primeros no se usan y aun así
   forman parte de la firma.
2. **`NONATOMIC` en toda la cadena de `CALL`.** Mezclar modos rompe con
   *"created in one transaction mode cannot be invoked from another"*.

El rollback usa `DROP PROCEDURE nombre(<firma exacta>)` **sin `IF EXISTS`**:
Redshift no lo admite y da `syntax error at or near "EXISTS"`.

## Orden de despliegue

**`strct` → `pgm` → `dt`.** Un deploy verde de `pgm` garantiza que los 116
cuerpos parsean en Redshift: `CREATE OR REPLACE PROCEDURE` difiere la
semántica, no la sintaxis.

## Convenciones que el pipeline exige

| Código | Causa |
|---|---|
| `REDSHIFT:112` | error SQL durante el deploy — es lo único que tumba el build |
| `REDSHIFT:207` | BOM en un `.par` — van en UTF-8 **sin** BOM |
| `REDSHIFT:219` | un archivo de `RevSQL/` con basename distinto al de `rollback.par` |
| `REDSHIFT:232` | `UPDATE`/`DELETE` de nivel superior sin `WHERE` |
| `JENKINS:104/105` | rama sin el ID de la subtarea |

## De dónde sale esto

Este repositorio es **sólo de despliegue**. El trabajo, la bitácora de
divergencias contra el legado, el banco de pruebas local y los validadores
viven en el repositorio de GitHub del equipo; aquí llega únicamente
`deploy/redshift/` y este `.jenkins.yml`.
