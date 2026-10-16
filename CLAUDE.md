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

**EL BANCO YA NO ES EL GATE.** Desde que el pipeline de Jenkins despliega y
corre la bateria **en Redshift real** (job DEV/DATABASE #370: e2e completo,
tablero y asercion final), la prueba que manda es esa. El banco se queda como
**chequeo previo de dos minutos** -- `./banco.sh fase pgm`, que compila los 74
archivos y verifica los 80 objetos -- y ahi es donde sigue siendo rentable:
caza en dos minutos lo que en Jenkins cuesta commit, push, traslado y job, y
sin dejar DEV a medias. La bateria larga de 45 minutos se corre cuando
interesa una hipotesis barata, no para certificar.

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

**EL TRASLADO A BITBUCKET LLEVA SOLO `deploy/redshift/`.** Nada de
`CLAUDE.md`, `validar.sh`, `docs/` ni `banco/`: Bitbucket es el repo de
despliegue y Jenkins solo lee `sourcePath`, `orderFile` y `sqlFolder`, todos
dentro del paquete. La secuencia de `./migra418.sh traslado <id>` ya lo hace
bien; **la linea de `git checkout ... -- validar.sh CLAUDE.md` fue un anadido
mio y es un error**: ensucia el diff que alguien tiene que revisar. Decision
del equipo, SLCOPRBA-1355. Consecuencia asumida: los chequeos de `validar.sh`
viven solo en el repo de trabajo; si alguna vez hacen falta del lado de
Bitbucket, el sitio es un paso del pipeline, no el repo.

**EL `[REDSHIFT:419]` NO SALE Y EL JOB MUERE: LO VERIFICADO Y LO QUE NO.**
Cuando el detector encuentra el paquete imprime
`[REDSHIFT:419] Paquete detectado en 'deploy/redshift/<id>'`; cuando no, cae
en silencio a la ruta legacy y el job muere con
`NoSuchFileException: .../deploy/redshift/deploy.par`, antes del stage de
despliegue y **sin tocar DEV**. Eso esta comprobado en los jobs #372, #373 y
#374, que fallan los tres con la misma firma.

**La causa raiz NO esta establecida, y tres explicaciones mias ya cayeron.**
Estan aqui para que nadie las vuelva a pagar:

| Hipotesis | Estado |
|---|---|
| "El paquete desaparecio de la rama" | falsa segun `git ls-files`: 151 archivos, ruta correcta. Pero ojo al parrafo de abajo: esa comprobacion no valia |
| "El commit no toca `deploy/redshift/`" | **sostenida solo para el #372** (`6a125a7` cambiaba unicamente `CLAUDE.md` y `validar.sh`): un commit asi tumba el build en vez de no hacer nada |
| "Un `push --force` deja a Jenkins sin changeset" | **caida con el #374**, que fallo igual |

**LA LECCION QUE SI VALE, Y ES DE METODO: `git ls-files` NO SIRVE PARA ESTO.**
Lee el indice local; Jenkins construye el remoto de Bitbucket. La comprobacion
correcta es
`git ls-tree -r --name-only origin/<rama> -- deploy/redshift`, y hay que
correrla **despues del push**, en el clon de Bitbucket.

**Y hay un modo de fallo real en la secuencia del traslado** (`migra418.sh:88-92`):
`git rm -r --cached deploy/redshift` borra el paquete del indice *antes* de que
`git checkout github/<rama> -- deploy/redshift` lo reponga. PowerShell no
encadena con `&&`, asi que si la copia falla, el `git commit` y el `git push`
siguientes se ejecutan igual y **suben el borrado**. Verificar con
`git ls-files` entre el `checkout` y el `commit`, y con `git ls-tree` contra el
remoto despues del `push`.

**Nunca reescribir la rama de Bitbucket entre despliegues**, y repuesto lo que
falte, seguir siempre con un commit normal hacia adelante que toque un archivo
del paquete.

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
  **CUALES TIENEN ESPEJO Y CUALES NO, que es donde se falla:**
  `sp_ordenamiento_preparar_insumos_edf` **SI** tiene su `_mock`; los cuatro
  `sp_ordenamiento_scoring_*_edf` y `sp_ordenamiento_consolidacion_edf`
  **NO** -- el mock reutiliza los reales. Anadir una columna al insumo real
  y no al espejo tumba la bateria entera en el primer ciclo con
  `column "..." does not exist`, y pasa `validar.sh` sin una queja porque es
  un error semantico, no de sintaxis. Ya se pago (SLCOPRBA-1355). El
  `diff` de la rama tocada entre los dos archivos tiene que salir vacio.

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
- **`DELTA` es palabra reservada en Redshift** -- viene de los codificados
  `DELTA` / `DELTA32K` -- **y en PostgreSQL no lo es**. Un `AS delta` pasa el
  banco entero sin una queja y Redshift lo rechaza al desplegar:
  `42601: syntax error at or near "delta" in context "(g.delta"`. Tumbo el job
  DEV/DATABASE #366 en el archivo 73 de 74. Es el punto ciego del banco en
  estado puro, y por eso `validar.sh` lleva ahora el chequeo 8, que barre la
  familia entera (`RAW`, `ENCODE`, `TOP`, `TAG`, `PERCENT`, `SYSDATE`,
  `DISTKEY`, `SORTKEY`, `LZO`, `BYTEDICT`, `MOSTLY13`...).
- **El `RAISE` de Redshift admite VARIABLES, no expresiones.** La gramatica
  es `RAISE level 'format' [, variable [, ...]];` y una funcion en la lista
  de argumentos es un error de **sintaxis** en el propio `CREATE`:
  `42601: syntax error at or near "NULLIF"`. PostgreSQL si admite cualquier
  expresion ahi, de modo que el banco la ejecuta sin una queja: **segundo
  punto ciego del banco**, hermano de `DELTA`, y en el mismo sitio -- tumbo
  el job DEV/DATABASE #367 en el archivo 74 de 74, el siguiente al que mato
  al #366. La salida es mover la expresion al `SELECT` que alimenta la
  variable, que es SQL normal. `validar.sh` lleva el chequeo 9, que une cada
  sentencia `RAISE` hasta su `;`, descarta la cadena de formato (lleva
  parentesis propios) y falla si queda un `(` en la cola.
- `CREATE OR REPLACE PROCEDURE` **difiere la SEMANTICA, no la SINTAXIS.**
  *(Esta linea decia antes, en redondo, que "no compila el cuerpo: los errores
  salen en la primera invocacion". El job #366 lo desmiente a medias, y el
  #367 lo confirma: su error de sintaxis salto en el `CREATE` sin que el
  procedimiento llegara a invocarse nunca.)*
  Una tabla o columna que no existe si espera a la primera invocacion; un
  error de sintaxis salta en el propio `CREATE`. La consecuencia buena: un
  deploy verde de `pgm` SI garantiza que los 74 cuerpos parsean en Redshift.
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
| `sector_financiero` vale **0 siempre** | su catalogo se carga de la vista REAL del datashare (`02_catalogos_ordenamiento.sql:16`) y no tiene variante mock | `DIR010FI` y `EMA016` quedan clavadas en la categoria minima |
| `coincidencia_geo` esta **fijado al literal 0** | `preparar_insumos_edf.sql:303` | solo afecta a `TEL020`, que **no entra en la suma del score** ni en el legado (`Caracteristicas.txt:2830-2834`) ni en nuestro port: sin impacto en el ranking |
| ~~No existe `'POSPAGO'`~~ **CAIDA (SLCOPRBA-1355)** | no era un limite del mock: `CEL019` no mira `'POSPAGO'` en el legado, es `MAX(V_Tipo_Cuenta_Ord.Valor)` (`Caracteristicas.txt:112`). El catalogo de 44 pesos ya esta cargado | ninguna. `CEL019` esta portada y certificada por el ARQ 85 |

**CUATRO caracteristicas salieron de esa tabla al leer el legado
(SLCOPRBA-1355).** Ninguna estaba donde decia estar:

| Decia | Dice el legado | Cita |
|---|---|---|
| `CEL014` clavada por `'POSPAGO'` | cuota de la ventana `> 24` sobre `Total_Reportes_24m` | `Caracteristicas.txt:2450-2453` |
| `CEL017` clavada por `sector_financiero` | cuota de `(12, 24]` sobre `Total_Reportes_24 - _12` | `:2459-2463` |
| `TEL017` clavada por `sector_financiero` | cuota de reportes `'RES'` sobre `Total_Reportes_Telefono` | `:2296-2299` |
| `TEL010` constante por `coincidencia_geo` | cuota de la ventana `<= 12` sobre `Total_Reportes_12` | `:2972-2977` |

Eran invenciones nuestras, no limites del mock, y las cuatro son portables hoy
sin datashare. Las dos de CEL liberaron **165,97 puntos de beta** (124,48 +
41,49).

**Y luego cayeron DOS MAS, que es lo que cierra la familia.** `CEL019` y
`EMA021` tampoco estaban bloqueadas: estaban **mal**. No les faltaba dato,
calculaban otra cosa, y ese numero entraba en la suma con beta completa.

| | Hacia | Dice el legado | Cita |
|---|---|---|---|
| `CEL019` | `% de filas con tipo_cuenta = 'POSPAGO'` | `MAX(V_Tipo_Cuenta_Ord.Valor)` sobre las cuentas del celular | `Caracteristicas.txt:112` |
| `EMA021` | `COUNT(*)` | banderas 50/25/12/8/5 por tipo de cuenta, maximo 100 | `:235` |

Las dos estan portadas y certificadas (ARQ 85 y ARQ 86): **299,79 puntos de
beta** que estaban midiendo ruido. Lo que las desbloqueo no fue el datashare
sino leerlas: `location.val.accounttype` ya venia en `xpm_location`, una de
las 19 columnas de las que solo leiamos cuatro. El volcado de
`V_Tipo_Cuenta_Ord` (44 filas) llego despues y solo hacia falta para `CEL019`.

**Tres trampas que costaron el rato y conviene no volver a pagar:**

1. **`MAX(tco.valor)` no lleva `COALESCE`.** El fallo de catalogo da NULL, las
   tres ramas del `CASE` de categoria evaluan UNKNOWN y la fila cae al
   `ELSE 0`: categoria **cero**. Un `COALESCE(..., 0)` la metaria por
   `WHEN cel019 < 35 THEN 1` y regalaria 46,68 puntos a cada celular sin
   cuenta.
2. **La asimetria del `'23'` en `EMA021` es del legado.** Cuatro de sus cinco
   ramas castean a INTEGER; la del 23 compara la cadena cruda. Se porta
   literal.
3. **Un fallo de catalogo es invisible.** "Sin cuenta", "tipo ausente del
   catalogo" y "tipo de peso minimo" terminan los tres en categoria 0, sin
   error y sin perder la fila. El catalogo no trae los tipos 17, 25, 26, 34,
   37, 50 y 51, y el datashare entrega justo `'17'`, `'34'` y `'51'`.

**`CEL019` topa en categoria 3 y divide por 4**, de modo que aporta como mucho
el 75% de su beta. Es defecto del legado y se porta tal cual. **`CEL006` tiene
el mismo defecto** (`caracteristicas_lf.txt:333-338`); las otras nueve del
canal llegan a 4, incluidas las binarias `CEL015`, `CEL017` y `CEL023`, que
saltan 1 -> 4 a proposito. La convencion se entendia y estas dos se escaparon:
si se abre ticket, van juntas.

**Y TEL tiene sus propios contadores por ventana**, al contrario de lo que
afirma el commit `630284f`: `REC_STAGE.calculo_total` (`:1674-1690`) define
`Total_Reportes_3/6/12` por `(Cod_Pin_Persona, Id_Buro_Persona)`. No hay `_24`
ni `_24m` y no se llaman `NUM_TOTAL_REPORTE*`, que es por lo que una busqueda
por ese nombre no da con ellos.

**Moraleja, que es la que importa:** una caracteristica que sale constante en el
mock no prueba que le falte un catalogo. Antes de anotarla como limite
estructural hay que leer su formula en el legado. De las tres filas de esta
tabla, dos cayeron enteras y la tercera se quedo sin consecuencia.

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

### La auditoria de los 42 buckets: que quedo bloqueado y por que

Auditados los cuatro canales contra `Caracteristicas.txt` (SLCOPRBA-1355).
**Los 42 umbrales y los 42 divisores COINCIDEN**, rama por rama y operador
por operador, incluido el `/3` singular de `TEL019` y los heterogeneos de DIR
(2, 3, 4, 5 y 6). Lo que divergia eran formulas, y en EMA las cuatro
categorizaciones. Corregidos 618 puntos de beta. Lo que **no** se puede
tocar, para no volver a investigarlo:

| Bloqueado | Por que | Puntos |
|---|---|---|
| `DIR034FI` | el legado suma un **importe**, `CO00END005` (`:2589`); es de la Fase 2 | 90,32 |
| `DIR050TO` | grano por direccion y medida `CO00MOR037/038 > 0` (`:3119-3125`): Fase 2 | 75,48 |
| `DIR010FI` y `DIR013OT` | el divisor del legado excluye `'NO VALIDA'` (`:1950-1954`) | 137,21 |
| `TEL023` y `CEL020` | el legado usa `Cod_Suscriptor`; nosotros `id_buro_suscriptor`, que es cubeta de hash | ruido hasta F2 |

**El divisor de DIR NO es portable hoy, aunque lo parezca.**
`descripcion_gestion` no existe en el lado de direcciones: la unica que hay
(`preparar_insumos_edf.sql:362-365`) se deriva del heuristico *"son >=7
digitos numericos?"*, y `stg_insumo_direccion` ni siquiera sale de esa rama
-- viene de `stg_rpu_post_unificacion` (`:252`). Aplicarla marcaria
`'NO VALIDA'` a **todas** las direcciones, el divisor caeria a 0 y las dos
caracteristicas irian a categoria 0 en el universo entero. Seria cambiar un
error por uno peor.

**Tres cosas estructurales que no son buckets y tambien estan bloqueadas:**

1. **Falta el filtro `WHERE CO01TEL022_cat > 0` del ranking de TEL**
   (`:1213`). No es "falta una linea": `TEL022` solo es no-NULL si hay una
   ciudad con `COINCIDENCIA = 1`, y `coincidencia_geo` esta clavado al
   literal 0 (`preparar_insumos_edf.sql:369`). **Portarlo hoy dejaria el
   canal TEL vacio.** Espera a que GEO entregue coincidencia.
2. **Falta la sobrescritura a `999999` por CONTACTABILIDAD en CEL**
   (`:2907`): un celular verificado (`Severidad_ = 1 AND Severidad2_ = 1 AND
   Descripcion_Fuente = 'CONTACTABILIDAD'`) va **siempre primero** en el
   legado. No cambia puntos, cambia el ranking entero. Necesita
   `VstgUbiContactabilidad`, que no esta en el datashare.
3. **`descripcion_gestion` es una sintesis nuestra** y no el estado de
   gestion por reporte del legado. Afecta a cinco de las diez de TEL que
   suman. Es insumo, no scoring.

### El grano de TEL: la llave es el TELEFONO, y YA ESTA PORTADA

**Esta seccion se ha corregido TRES veces. Las dos primeras versiones decian
cosas distintas y las dos estaban mal; la tercera decia que la llave correcta
"hay que rehacerla", y para entonces ya estaba rehecha. Lo de abajo esta
verificado en el codigo y en datos de Redshift real (job DEV/DATABASE #370).**

En el canal TEL del legado, la columna `Direccion_Fisica` **no contiene una
direccion: contiene el numero de telefono.** La prueba que no admite lectura
alternativa es el nombre del divisor: `REC_STAGE.Calculo_Meses2`
(`Caracteristicas.txt:2252-2262`) agrupa por
`(Cod_Pin_Persona, Id_Buro_Persona, Direccion_Fisica)` y llama al resultado
**`Total_Reportes_Telefono`**. El canal EMA lo hace explicito con un alias:
`TML.Direccion_Fisica as Email` (`:2764`).

**Y nosotros agrupamos por el telefono, que es lo correcto.**
`sp_ordenamiento_scoring_tel_edf.sql:76` agrupa por
`(id_buro_persona, t.telefono)`; la direccion entra como `MIN(...)` de
arrastre. Lo confirman tres cosas independientes:

- los datos de DEV: el canal da `lugar_max = 2`, o sea **rankea de verdad**;
- los ARQ 89 y 90, que miden deltas **entre dos telefonos de la misma
  persona** y estan en PASSED;
- la auditoria de los 11 buckets del canal (SLCOPRBA-1355), que ademas
  encontro los tres granos conviviendo bien: persona para TEL001/006/010,
  telefono para TEL017/019, maximo-entre-telefonos para TEL023/025.

No queda nada que rehacer aqui. Detalle en
`docs/AUDITORIA_SEMANTICA_ORDENAMIENTO_F4.md`.

**Moraleja, que es la que vale para toda esta bitacora: una seccion que
afirma que algo esta roto envejece peor que el codigo.** Antes de abrir
trabajo a partir de una nota, leer el SP.

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
