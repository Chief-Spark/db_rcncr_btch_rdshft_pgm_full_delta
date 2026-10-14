# Reconocer - repo de PROGRAMAS (pgm)

Unificacion de direcciones y Ordenamiento (scoring de contactabilidad) de
Experian Reconocer, migrados de Teradata a Amazon Redshift.

Este repo tiene `global.type = program`: **solo procedimientos almacenados**.
Se despliega **despues de `strct` y antes de `dt`**.

## Donde esta que

| Pieza | Archivo |
|---|---|
| Orquestador de Unificacion | `16_sp_unificacion_ciclo.sql` (+ `16b` mock) |
| Regla 2, cascada completa | `sp_unificacion_regla2.sql` (+ mock) |
| Los cuatro sitios que crean direcciones | `sp_unificacion_r2_motor_{nit,nivel,cruce,dif}_*.sql` |
| Orquestador de Ordenamiento | `19_sp_ordenamiento_ciclo.sql`, `sp_ordenamiento_ejecucion_mock.sql` |
| Scoring por canal | `sp_ordenamiento_scoring_{dir,tel,cel,ema}_edf.sql` |
| Gate por arquetipo | `sp_unificacion_mock_gate_arq.sql` |
| Evaluador de criterios | `sp_cert_evaluar_criterios_mock.sql` |

## La cascada de la Regla 2 (el orden IMPORTA)

```
esc1/esc2 -> esc3 'L3' -> motor NIT 'X4' -> esc4 'B5' -> motor NIVEL 'A6'
          -> motor DIF 'D9' -> esc5 'C7' -> motor CRUCE 'A8' -> esc6 'E6'
```
Es *starvation by design*: cada etapa lee `ind_unificacion = 'N'` y sella lo que
resuelve. **Cambiar el orden cambia que se unifica con que.** `D9` corre antes
de `esc5` a proposito (divergencia documentada: nuestro `esc5` es mas ancho que
el del legado).

## Ordenamiento: los SP de scoring son compartidos

No hay espejo mock de `sp_ordenamiento_scoring_*_edf` ni de
`sp_ordenamiento_consolidacion_edf`: **el mock reutiliza los reales**. Lo unico
propio del mock es `sp_ordenamiento_preparar_insumos_mock`, que materializa las
MISMAS tablas `bdm_tempo.stg_*` cambiando solo las fuentes. Por eso una
correccion de scoring se hace **una vez** y vale para las dos vias.

## Fuentes de verdad del negocio

- Unificacion: `PRO_UnificacionR2.sql` (legado Teradata).
- Ordenamiento F4: **`Caracteristicas.txt`** (ese archivo *es* el modelo).
  F1-F3: `Prc_Ordenamiento2.sql`.

## Reglas que no se negocian

1. **Nunca cambiar la firma de un SP.** El Framework Batch exige 6 parametros
   VARCHAR en los orquestadores, en este orden: `in_solicitud`,
   `in_nit_suscriptor`, `in_path_archivo`, `in_nemotecnico` (= MODO),
   `in_id_facturacion` (= LOTE), `in_fecha_ejecucion` (= FECHA). Los tres
   primeros no se usan y aun asi forman parte de la firma. Los gates NO usan
   esta firma: van `(VARCHAR, INTEGER)`.
2. **Rama `claude/elegant-carson-tqhcku`.** Nunca empujar a otra sin permiso
   explicito.
3. **No crear pull requests** salvo peticion expresa.
4. **Revisar el codigo de Teradata antes de decidir.** El documento funcional
   se equivoca; el codigo manda. Verificado tres veces en Unificacion y tres
   veces mas en Ordenamiento (EMA014, EMA025, DIR017).
5. **Certificar solo con datos mock.**
6. **Orden de despliegue: strct -> pgm -> dt.**

## El banco de pruebas local

`dt/banco/` replica el job de Jenkins sobre **PostgreSQL 16**, que esta
instalado en el contenedor. Corre los tres `deploy.par` en orden, archivo a
archivo. Existe porque Redshift **no compila el cuerpo de un procedimiento al
crearlo** y Jenkins era el unico modo de ejecutar una linea de SQL.

```
cd dt/banco && ./banco.sh init nueva && ./banco.sh fase strct
./banco.sh foto tras_pgm      # y ./banco.sh desde tras_pgm para re-correr en 2 s
```

**Un verde del banco NO certifica.** Degrada un `[REDSHIFT:112]` de
"desconocido" a "especifico de Redshift". Postgres es mas permisivo que Redshift
en cinco formas y mas estricto en tres; `banco/README.md` las lista una por una,
y la disciplina es: **un fallo local es una hipotesis hasta trazarlo al legado o
a la documentacion de Redshift. Nunca cambiar codigo correcto en Redshift para
contentar a Postgres.**

El banco pone de su lado un `ANALYZE` y unos indices sobre las tablas sembradas.
Es compensacion del motor, no un parche al repo: Redshift resuelve esos joins
por fuerza bruta columnar y Postgres en un nodo no.

## Politicas del pipeline

| Codigo | Causa | Como se evita |
|---|---|---|
| `REDSHIFT:112` | error SQL durante el deploy | **es lo unico que tumba el build hoy** |
| `REDSHIFT:207` | BOM en un `.par` | UTF-8 **sin** BOM |
| `REDSHIFT:219` | basename de `RevSQL/` distinto a la linea de `rollback.par` | mismo nombre, sin sufijo `_rev` |
| `REDSHIFT:232` | `UPDATE`/`DELETE` de nivel superior sin `WHERE` | `WHERE` explicito, o `TRUNCATE` |
| `JENKINS:104/105` | rama sin ID de subtarea | nombrar la rama con la subtarea |

`rollback.par` es el reverso exacto de `deploy.par`, modulo el prefijo
`NN_rollback_` en los archivos numerados. Todo archivo sin prefijo numerico
conserva su nombre en `RevSQL/`.

## Convenciones de codigo

- **UTF-8 sin BOM. ASCII sin acentos**, a proposito, en todo el repo.
- `NONATOMIC` en toda la cadena de `CALL`. Mezclar modos rompe con
  *"P0001: created in one transaction mode cannot be invoked from another"*.
- Rollback de procedimientos: `DROP PROCEDURE nombre(<firma exacta>);`
  **sin `IF EXISTS`** (Redshift da `syntax error at or near "EXISTS"`).
  Tablas y vistas si usan `IF EXISTS`.
- **Nunca `GRANT ... TO PUBLIC`.** Nunca `DROP SCHEMA ... CASCADE` desde
  `strct` (incidente DEV #256): `bdm_datos` es compartido.
- DDL idempotente: `CREATE TABLE IF NOT EXISTS`, `CREATE OR REPLACE VIEW`.
- Vistas con `WITH NO SCHEMA BINDING`, para que el orden de despliegue no las
  rompa.
- Tablas pequenas en `DISTSTYLE ALL`, con la justificacion escrita.
- **Paridad real <-> mock** en todo SP que se toque. El mock se genera por
  sustitucion de fuentes y debe regenerarse identico.

## Trampas de Redshift ya pagadas

- `generate_series` es **leader-node only** -> usar `bdm_stage.mock_numeros`.
- `REGEXP_*` exige patrones **literales**, no derivados de columna.
- `EXISTS` no vale en la lista del `SELECT` (en el `WHERE` si).
- `UPDATE ... FROM`: el destino **no admite alias**.
- `CAST(fecha AS INTEGER)` no existe -> `(anio-1900)*10000 + mes*100 + dia`
  con `DATE_PART`.
- `CASE`/`COALESCE` no mezclan INTEGER y VARCHAR.
- **Todos los `LISTAGG` del MISMO `SELECT` comparten `WITHIN GROUP`** (por
  `SELECT`, no por sentencia). Es lo que tumbo el job #341.
- `LISTAGG(DISTINCT ...)` no convive con `COUNT(DISTINCT ...)` en el mismo
  `SELECT`.
- `COUNT(DISTINCT)` no vale como funcion de ventana -> `MIN()/MAX() OVER`.
- `REPLACE(x, NULL, '')` devuelve **NULL**.
- `SUM()` sobre cero filas devuelve **NULL**, no 0 -> guarda `COUNT(*) = 0`
  primero, y `COALESCE` despues. Sin eso, un criterio vacio sale PASSED.
- Subconsulta escalar en la proyeccion dentro de una agregacion: Redshift no la
  resuelve de forma fiable -> `CROSS JOIN`.
- El `DISTKEY` tiene que ser una columna de la **lista del SELECT**, no un
  alias (job #315).
- El `CAST` de la primera rama de un `UNION ALL` fija el tipo del nodo.
- **`ORDER BY ... DESC` pone `NULLS FIRST` por defecto** (Teradata hace lo
  contrario). Escribir `NULLS LAST` explicito.
- `CREATE OR REPLACE PROCEDURE` **no compila el cuerpo**: los errores salen en
  la primera invocacion.
- **Un literal mas largo que su columna es un `[REDSHIFT:112]`**, y
  `CREATE TABLE IF NOT EXISTS` lo esconde: si la tabla ya existe con la columna
  ancha de una version anterior, el `INSERT` pasa en DEV y falla en el primer
  despliegue sobre ambiente limpio. Encontrado asi con la evidencia de `R2-07`
  (688 caracteres contra `VARCHAR(500)`), que nunca llego a desplegarse.

## Lecciones numeradas (estaban dispersas en cabeceras)

| # | Leccion |
|---|---|
| #5 | `deploy.par` y `rollback.par` con paridad de lineas |
| #7 | Framework Batch: 6 params VARCHAR obligatorios |
| #9 | `.par` en UTF-8 sin BOM y en orden inverso |
| #10 | Redshift no soporta `DROP FUNCTION IF EXISTS`; usar firma exacta y asumir el fallo si no existe |
| #11 | Firma exacta del Framework Batch, en ese orden |
| #12 | Redshift no soporta `DROP PROCEDURE IF EXISTS` |
| #13 | `NONATOMIC` en toda la cadena de `CALL` |
| #14 | El `DROP` debe repetir la firma **exacta** del `CREATE`, incluido el `INOUT` |

*(#1-#4, #6 y #8 no estan citadas en ningun archivo del repo: se perdieron.)*

## Antes de empujar

```
./validar.sh
```
Chequea ASCII, BOM, `$$` y parentesis balanceados, simetria de los `.par`, que
toda entrada tenga su archivo, `WHERE` en `UPDATE`/`DELETE`, y `LISTAGG` con el
mismo `WITHIN GROUP` por `SELECT`. Sale distinto de cero si algo falla.

## Como responder en este proyecto

Corto, claro y contundente. Quien lee necesita decidir, no leer.

- **La conclusion primero**, en negrita. Luego la evidencia.
- **Tablas** en vez de prosa cuando hay mas de dos cosas que comparar.
- **Maximo 15 lineas**, salvo entregables (un plan, un informe, un documento).
- **Cita `archivo:linea`** al afirmar algo del codigo. Una afirmacion sin cita
  es una hipotesis, y hay que decir que lo es.
- No recapitular lo ya dicho. No narrar lo que se va a hacer: hacerlo y
  reportar.
- No enumerar opciones que no se van a tomar. Recomendar una.
- Nada de disculpas ni de rumiar errores propios: corregir en una linea y
  seguir.
- Un hallazgo son tres lineas: **que** es, **donde** esta, **que impacto**
  tiene. Si hay varios, tabla.

Y lo que mas importa en este proyecto: **si una afirmacion anterior resulta
falsa, corregirla en cuanto se sepa, sin preambulo.** Ha pasado ya con el gate
que se creia que tumbaba el build y no lo hacia.

## Ordenamiento: lo que el mock NO puede ejercitar

Cuatro limites estructurales, descubiertos auditando la cadena de siembra. No
son defectos a corregir: son el motivo por el que ciertos criterios se quedan
en SIN_DATO, y conviene no volver a investigarlos.

| Limite | Causa | Consecuencia |
|---|---|---|
| `sector_financiero` vale **0 siempre** | su catalogo se carga de la vista REAL del datashare (`02_catalogos_ordenamiento.sql:16`) y no tiene variante mock | `DIR010FI`, `TEL017` y `EMA016` quedan clavadas en la categoria minima |
| `coincidencia_geo` esta **fijado al literal 0** | `preparar_insumos_edf.sql:234` | `TEL010` aporta una constante y `TEL020` no entra en la suma: ninguno discrimina |
| No existe `'POSPAGO'` | `catalogo_tipo_cuenta_tel` solo trae `PREPAGO` y `FIJA` (`02_catalogos_ordenamiento.sql:27-32`) | `CEL019` es constante: 186,72 puntos de beta inmovilizados |

**Dos filas de esa tabla eran falsas y se corrigieron (SLCOPRBA-1355).** Decian
que `CEL014` estaba clavada por `'POSPAGO'` y `CEL017` por `sector_financiero`.
**El legado no mira ninguna de las dos cosas**: `CO01CEL014` es la cuota de la
ventana `> 24` meses sobre `Total_Reportes_24m` (`Caracteristicas.txt:2450-2453`)
y `CO01CEL017` la de la ventana `(12, 24]` sobre
`Total_Reportes_24 - Total_Reportes_12` (`:2459-2463`). Eran invenciones
nuestras, no limites del mock. Portarlas bien libero **165,97 puntos de beta**
(124,48 + 41,49). `CEL019` si depende de verdad del tipo de cuenta
(`:1285-1290`, `MAX(TCO.Valor)` sobre `V_Tipo_Cuenta_Ord`) y sigue bloqueada.

**Moraleja, que es la que importa:** una caracteristica que sale constante en el
mock no prueba que le falte un catalogo. Antes de anotarla como limite
estructural hay que leer su formula en el legado. Dos de las tres filas de esta
tabla no sobrevivieron a esa lectura.

### Dos trampas al sembrar arquetipos de Ordenamiento

**Las fechas tienen que ser relativas, no literales.** El insumo calcula
`meses_reporte` con `DATEDIFF(month, fecha, CURRENT_DATE)`, asi que un literal
significa una cosa hoy y otra el mes que viene: **el score deriva con el
calendario** y un criterio que hoy pasa falla solo. Usar
`DATEADD(month, -N, CURRENT_DATE)` y elegir N lejos de los umbrales de ventana
(3, 6, 12 y 24 meses).

**`score_ordenamiento` no se trunca nunca.** Su unica limpieza es
`DELETE ... WHERE id_buro_persona IN (stg_ord_personas_alcance)`. Un arquetipo
sembrado fuera de la ventana del watermark conservaria para siempre el score de
la primera corrida. Sembrar con `fecha_relacion_persona_ubicaci = '2026-03-01'`,
que es el watermark y el predicado es inclusivo.

### Criterios que miden deltas, no scores absolutos

Los arquetipos del Ordenamiento (ARQ 80..84, banda `9800000..9849999`) se
certifican por la **diferencia de score entre las dos filas de cada persona**,
nunca por el valor absoluto. El delta es exactamente
`(diferencia de categoria / divisor) * beta` y es inmune a todo lo que las dos
filas comparten: la fecha, el catalogo financiero, el numero de reportes y el
de direcciones. Un score absoluto depende de las cuatro cosas y el criterio se
caeria solo.

### El colapso de TEL NO es un limite del mock: es un defecto de produccion

`direccion_fisica` sale de `COALESCE(ref.dir_ref, ...)` y `dir_ref` es
`MIN(texto_ubicacion)` agregado **por persona**
(`sp_ordenamiento_preparar_insumos_edf.sql:127`) -- **en el SP REAL, no solo en
el mock**. Si la persona tiene una sola ubicacion estandarizada, que es el caso
normal, todos sus telefonos reciben el mismo valor y colapsan en un grupo:
**una fila de score, `lugar = 1` siempre, nada que ordenar.**

El legado agrupa por la direccion fisica **de cada fila de reporte**, de modo
que una persona con N direcciones produce N grupos y el ranking elige entre
ellos. Ese es el proposito del canal.

Arrastra cinco caracteristicas mas: `TEL001`, `TEL006`, `TEL010`, `TEL023` y
`TEL025` son en el legado *cuotas del grupo contra el total de la persona*. Con
grupo = persona valen trivialmente 100 o 0.

Detalle completo en `docs/AUDITORIA_SEMANTICA_ORDENAMIENTO_F4.md`.

### `sector_financiero` no es un catalogo provisional: hoy es ruido

La fila de la tabla de arriba dice por que vale 0 en el mock. Lo que faltaba
saber es que **en produccion tampoco significa nada**.
`02_catalogos_ordenamiento.sql:12-17` lo carga como
`CASE WHEN id_buro_suscriptor >= 901 THEN 1 ELSE 0 END`, y
`02_vistas_insumo_edf_views.sql:326-333` define `id_buro_suscriptor` como un
`COALESCE` cuyo **ultimo recurso** es
`MOD(ABS(FNV_HASH(pin || ':' || ci.id)), 9998) + 1`. Para todo reporte sin
`counterpartyidnumber`, el sector sale de una cubeta de hash. Y la misma columna
alimenta `EMA015`, que hace `COUNT(DISTINCT id_buro_suscriptor)`: cuenta cubetas
de hash como si fueran suscriptores.

El `Sector` del legado toma valores en `{CO, CC, RE, FI, OT}` con grano **por
cuenta** (`PRO_ORD_CTA_TOTALES_PERSONAS_2.sql:378-396`,
`PRIMARY INDEX (Cod_DW_Cta)`). Una bandera 0/1 no distingue `'FI'` de `'OT'`.
Matiz favorable: **diez de las once ramas dependen solo del `cod_suscriptor`**,
no de la cuenta; solo `portafolio = 'CO'` necesita el tipo de cuenta. Con el
`cod_suscriptor` de seis digitos se reproduciria casi todo sin esperar a F2.
Detalle y peticion en `docs/PETICION_DATASHARE_F1_F3_ORDENAMIENTO.md`.

### La clave de particion del ranking NO es una divergencia

El legado particiona por `(Id_Buro_Persona, Cod_Pin_Persona)` en los cuatro
canales (`Caracteristicas.txt` `:72` EMA, `:79` CEL, `:88` DIR, `:105` TEL) y
nosotros solo por `id_buro_persona`. **Pero son la misma llave**:
`02_vistas_insumo_edf_views.sql:22-23` define
`id_buro_persona = FNV_HASH(xpm.pin)` y `cod_pin_persona = CAST(xpm.pin AS BIGINT)`.
Una es el hash de la otra, asi que particionar por el par es equivalente y
nuestro port es fiel. No hay nada que corregir.

Lo unico que deja: el par solo difiere **cuando `FNV_HASH` colisiona**, y ahi el
nuestro fusionaria dos personas en un ranking. Es el riesgo del gate de colision
que se documento en `01d_ddl_direccion_generada.sql:54` y nunca se construyo.
Queda en la bitacora, no es trabajo abierto.
