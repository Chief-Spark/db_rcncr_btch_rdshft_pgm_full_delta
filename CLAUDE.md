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

**EL `[REDSHIFT:419]` NO SALE: ES DEL PIPELINE, NO DEL REPO.** Lo cierra una
prueba que no admite lectura alternativa: **STRCT desplego verde un dia y al
siguiente fallo identico, con el mismo paquete y sin un commit de por medio.**
Cuatro hipotesis mias cayeron por buscar la causa en el repo. Escalado a
DevSecOps. El paquete esta verificado contra el remoto de Bitbucket: 151
archivos bajo `deploy/redshift/SLCOPRBA-1353/`.

**EL CLUSTER DE DEV YA NO SE PAUSA: ESTA SIEMPRE ARRIBA (SLCOPRBA-1355).**
Hasta ahora esta seccion decia que se pausaba a diario sobre las 19:00 de
Bogota y que ahi terminaba la ventana de despliegue. **Ya no hay ventana**: se
puede lanzar a cualquier hora. Lo que sigue en pie es el dato historico, que
es lo unico que esa nota aportaba al 419: el #372, el #373 y el #374 se
lanzaron entre las 18:00 y las 19:00 **con el cluster arriba**, de modo que la
pausa nunca explico esos fallos.

**LO QUE SE COMPROBO SOBRE EL 419, Y LO QUE NO.**
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

## El ciclo GEO mock: que se certifica y que no (SLCOPRBA-1355)

**Los cinco criterios GEO estaban bloqueados por permisos, no por logica.** El
rol IAM `rcncr-batch-redshift-geo` no esta asociado al cluster DEV, de modo
que ni el `UNLOAD` escribe en S3 ni el `COPY` lee. Eso tumbaba CA-01 y dejaba
CA-02..CA-05 sin forma de ejercitarse.

**La salida fue sustituir el viaje a S3, no simular mal el resto.** Cuatro
piezas nuevas y un interruptor:

| Pieza | Que es |
|---|---|
| `s3_enabled` en `geo_config_mock` | vale `'0'` y hace que `sp_geo_exportar_insumo_mock` **omita** el `UNLOAD`. El Lote queda en `exportado` en vez de `fallido`, y **CA-01 se desbloquea solo**: el evaluador ya tenia `WHEN lc.estado = 'exportado' THEN 'PASSED'` |
| `bdm_stage.mock_geo_respuesta` | **es el archivo de vuelta**, con las mismas 32 columnas crudas del contrato |
| `sp_geo_simular_arcgis_mock` | el doble del sistema EXTERNO. No es un port, y el nombre lo dice |
| `sp_geo_cargar_georreferenciacion_mock` | espejo del cargador. **Difiere en UNA sentencia**: el `COPY` pasa a `INSERT ... SELECT` |
| `sp_geo_reenganchar_r3_mock` | espejo del reenganche. Solo cambian tres nombres |

El alcance del tablero paso de **45 a 50** criterios.

**CERRADO EN REDSHIFT REAL: job DEV/DATABASE #402, tablero en 50 de 50 y
cero pendientes.** Los cinco pasaron con estos numeros: `CA-01` Lote
`exportado` con 103.000 candidatos; `CA-02` 14.000 geocodificadas y 89.000
`U`; `CA-03` Lote `cargado` con `fase_fallo` y `ultimo_error` en NULL;
`CA-04` 14.000 aptas entraron a la Regla 3; `CA-05` cero aptas y Regla 3
omitida sin excepcion. Y lo que mas importaba: **`tipo 3 = 5000 contra 5000`
antes del ciclo**, con `R3-01..R3-10` intactos.

**Con eso, GEO ENTRO EN EL GATE.** `sp_cert_asercion_final.sql` ya no lleva
`bloque <> 'GEO'`: un FAILED en cualquiera de los cinco tumba el build.

**Y SE RETIRO EL BLOQUE QUE LOS DABA POR BLOQUEADOS.**
`sp_cert_evaluar_criterios_mock` insertaba `CA-02..CA-05` como BLOQUEADO en
cada fase. Con el ciclo mock certificandolos, esas filas eran falsas: el
titular daba PASSED y el pivote por fase seguia diciendo BLOQUEADO en el
mismo informe. **Un tablero que se contradice a si mismo no se cree ni cuando
acierta.** Ahora los escribe solo `sp_cert_geo_mock`, con `modo = 'GEO'`, y
el pivote tiene su columna `geo` -- columna aparte, no una quinta fase, porque
el ciclo GEO corre una vez y no por fase.

**LO QUE SIGUE SIN CERTIFICARSE, y hay que repetirlo cada vez que alguien lea
el 50/50:** que el `UNLOAD` escriba de verdad en S3 y que el `COPY` lo lea.
Son dos sentencias cuyo riesgo es de permisos. Todo lo demas -- gates de
estado y de conteo, conciliacion de tipos, los tres rechazos, los tres
`UPDATE` por Status y las dos ramas del reenganche -- es el mismo SQL.

**EL CABLEADO YA EXISTIA Y NADIE LO SABIA.**
`02b_vistas_insumo_mock.sql` define `v_mock_ubicacion_estandarizada` con un
`COALESCE` de la latitud propia con la de `geo_atributos_mock` por `LEFT
JOIN`. O sea que lo que el cargador mock escribe entra en la Regla 3 por el
mismo camino que en produccion. Faltaba quien escribiera, no por donde.

**LA TRAMPA QUE CASI CUESTA EL TABLERO DE UNIFICACION.** Un simulador que
geocodificara las ~103.000 ubicaciones candidatas le daria a la Regla 3
coordenadas que antes no tenia, apareceria con pares nuevos y moveria los
conteos exactos de `R3-02`..`R3-10`, que estan en PASSED. Certificar GEO
rompiendo Unificacion no es certificar. Por eso el modo `'M'` **solo devuelve
geocodificada la ubicacion que YA tenia coordenadas en el mock, y con esas
mismas coordenadas**. El insumo de la Regla 3 queda byte a byte igual.

**Y UNA DE ORDEN:** el ciclo GEO mock corre **entre la convergencia y el
tablero**, nunca dentro del e2e. El cargador mueve el Lote a `cargado` y CA-01
exige verlo en `exportado`: metido dentro, CA-01 se caeria por un efecto de
orden y no por un defecto.

**Al generar un espejo por sustitucion, anclar el corte de cabecera a
principio de linea.** Un `t.index('CREATE OR REPLACE PROCEDURE')` engancha la
primera aparicion, que esta **dentro de un comentario** (`-- Objeto en
bdm_datos; idempotente (CREATE OR REPLACE PROCEDURE).`), parte la linea en dos
y deja un `)` suelto. Lo caza el chequeo de parentesis de `validar.sh`, no el
de sintaxis.

`rollback.par` es el reverso exacto de `deploy.par`, modulo el prefijo
`NN_rollback_` en los archivos numerados. Todo archivo sin prefijo numerico
conserva su nombre en `RevSQL/`.

## Novedades (P0035): el tercer proceso, arrancado por Ubicacion

**Novedades NO depende de las Fases 1-3 del Ordenamiento.** Buscados
`MATERIALIZA`, `CTA_ATRIBUTOS`, `CTA_TOTALES`, `CONCAT_ATRIBUTOS`,
`CALC_UBICACIONES`, `UBIC_DIRECCIONES` y `FINAL_UBIC` en los 406 KB de
`Novedad.sql`: **cero coincidencias**. Lo unico que toma del Ordenamiento es
`ORDEN_PRIORIDAD` (`Novedad.sql:8347`), que `sp_ordenamiento_consolidacion_edf`
ya escribe. Eso es lo que desbloqueo la vertiente: no faltaba F1-F3.

El legado son **diez** SPs en `Novedad.sql`, no nueve -- existe tambien
`PRO_Novedad_Linea_PICalculados_Ctls` (`:4066`), que el `111.BTQ` no invoca y
el `140.BTQ` si -- mas cuatro scripts de malla. `Mosaic` queda fuera por
decision legal, y **no toca Ubicacion**: su predicado aparece una sola vez en
todo el archivo, en `:2482`, dentro de `Info_Basica`.

**SE EMPIEZA POR UBICACION PORQUE ES PRODUCTOR PURO.** No lee ninguna temporal
ajena y cinco de los demas dependen de sus dos salidas: `Catalogo` (`:288`),
`Contact` (`:615`), `Historial` (`:1721`), `PICalculados_Ctls` (`:4808`) y
`Ubi_Agregada`, que las usa en once puntos. **Por eso las dos salidas son
contrato publico y su DDL esta pinada en `strct`**: `stg_nov_ubica_etapa_9`
con 42 columnas y `stg_nov_ubica_etapa_2` con 15. Un `CTAS` dejaria que el
tipo lo infiriera la consulta y el contrato cambiaria sin avisar.

**EL SP NO INSERTA EN `MAT_INFO_UBICACION`, y conviene saberlo antes de
buscarlo.** Termina en las dos etapas; la carga la hacen los TPT:
`etapa_9 -> Vstg_Reconocer_Info_Ubica (120.TPT:86-176) -> WHERE Severidad <> -1
(130.TPT:215) -> UPSERT (130.TPT:573-703)`. Por eso el port son dos piezas.

| Pieza | Donde |
|---|---|
| Contratos, tabla final y control | `30_ddl_novedades.sql`, `30b` mock, `31_ddl_nov_control.sql`, `31b` mock |
| Tablero de 32 criterios | `33_ddl_cert_criterios_nov.sql` |
| El port y su espejo | `sp_novedades_ubicacion_{edf,mock}.sql` |
| La pieza de los TPT | `sp_novedades_cargar_mat_ubicacion_{edf,mock}.sql` |
| Control y orquestador | `sp_nov_control_*`, `sp_novedades_ciclo_edf.sql`, `sp_novedades_mock_ciclo.sql` |
| Evaluador y tablero | `sp_cert_evaluar_criterios_nov_mock.sql`, `validacion_certificacion_nov.sql` |
| Lo que hay que pedir | `docs/PETICION_CATALOGOS_NOVEDADES.md` |

**EL CATALOGO DE CRITERIOS SALE DEL CODIGO, NO DE UN DOCUMENTO.** Unificacion
y Ordenamiento tienen su RF; Novedades no. Cada criterio cita la linea del
legado de la que sale, y si algun dia aparece un documento funcional hay que
revisarlo contra el.

**SEIS TRAMPAS DEL LEGADO, LOCALIZADAS Y PORTADAS LITERALES:**

| Que | Donde |
|---|---|
| `FLAG_OP` referencia el alias de una columna definida **dos lineas despues**. Teradata lo resuelve, **Redshift no**: hay que repetir el `CASE` | `Novedad.sql:8392-8396` |
| `V_CARGA_FULL` lee `REC_MTDAT.LOG_TD` con el esquema **hardcodeado**, ignorando el parametro | `:7366-7372` |
| Centinelas de nulo inconsistentes: `''` y `'-1'` en la etapa 9, `'SV'` en las agregaciones, y la etapa 2 une por igualdad en esas tres columnas | `:8354`, `:8374`, `:8502-8504`, `:8649-8651` |
| La homologacion de fuente **jamas se aplica**: el `COALESCE` interno nunca da NULL, asi que todo sale `'CAM'` | `:8635` |
| `TMP_UBICA_ETAPA_0` es **codigo muerto**: se crea, se analiza y se borra sin que nadie la lea. No se porta | `:7514`, `:8723` |
| **`FLAG_OP = 'E'` es codigo muerto, y con el la unica via de BAJA.** La etapa 1 anti-une `V_BLOQUEO` y la etapa 9 vuelve a unirla por la MISMA llave para preguntar por `FECHA_BLOQUEO`: lo que sobrevivio no esta en la tabla, asi que nunca da TRUE | `:7590-7594` contra `:8393`, `:8416` |

**LA SEXTA ARRASTRA AL TPT Y CAMBIA DOS CRITERIOS.** `Severidad = 2` -- el
borrado -- sale UNICAMENTE de `WHEN STG.FLAG_OP = 'E' THEN 2`
(`120.TPT:163`), de modo que **el UPSERT de `130.TPT` nunca borra una fila: el
AS-IS solo inserta y actualiza.** `NOV-UB-13` y `NOV-UB-15` decian "el mock no
siembra ubicaciones bloqueadas", como si faltara un arquetipo. **Era falso, y
ningun arquetipo lo desbloquea**: verifican una rama que el legado no puede
tomar. Ahora exigen cero bajas, que es la paridad real, y estan en PASSED.

**Y DE PASO CORRIGIO UNA DIVERGENCIA NUESTRA.** Nuestro filtro de la etapa 1
era `COALESCE(rpu.bloqueado, 0) = 0`, que excluye la FILA; el legado excluye el
ID entero. No es lo mismo porque **`cod_dw_persona_ubic` NO es unico en el
datashare** (568.657 filas para 142.067 ids, ~4:1): una hermana sin bloquear
pasaba y el `MAX(bloqueado)` de la etapa 9 le ponia `'E'`. Eramos mas anchos
que el legado. Hoy es un anti-join, igual que el original. **En el mock no
cambia nada**, porque alli el id es unico por construccion.

**Y CINCO COLUMNAS QUE EL LEGADO DEJA EN BLANCO POR ESA RUTA**, que no son un
defecto del port: `REPORTADO_DESDE`, `ULTIMO_REPORTE`, `FUENTE`,
`NUMERO_REPORTES` y `NUMERO_ENTIDADES` salen NULL y 0 **literales**
(`:8358-8363`). Sus valores reales viven en la etapa 2, que esa ruta no
consume.

**DECISION CERRADA (SLCOPRBA-1355): esas cinco NO se pueblan, y el `'CAM'` de
la fuente NO se corrige.** Se reproduce el legado tal cual. Dejan de ser
divergencias abiertas: son el comportamiento esperado, y `NOV-UB-09` verifica
que SIGAN en blanco. No volver a abrirlas como si fueran un defecto.

**EL CONTROL DE DELTA NO ES UN PORT: ES DISENO NUEVO, y el motivo es que el
del legado esta INOPERATIVO.** `111.BTQ:64-65` hace
`DELETE FROM LOG_TD WHERE Nombre_Proceso = 'P0035_Extractor_Novedades'` **al
inicio de cada corrida**, y el watermark que los SP leen es
`MAX(FECHA_HORA_FIN)` de esa misma tabla (`Novedad.sql:242-247`): se
autodestruye, devuelve NULL y **toda corrida del AS-IS es FULL**. Ademas
`140.BTQ` declara `FncUpdate_LogTD` (`:47-61`) y **no la llama** (`:853-858`).
`nov_control` se construye sobre el patron de `unif_control`, que si funciona.

**UN FAN-OUT QUE SE PAGO Y NO HAY QUE VOLVER A PAGAR.** Derivar la clase de la
ubicacion de `v_xpm_contacto_canal` **multiplica la salida por tres**: esa
vista tiene una fila por canal y no una por ubicacion. Medido en el banco:
219.000 filas para 73.000 ids. La clase sale del tipo de la **propia**
ubicacion, nunca de un join. Y en nuestro modelo **toda fila de RPU es una
direccion**: los telefonos, celulares y correos viven en `contacto_canal`, que
es otra tabla y otro grano, de modo que portar las clases TEL, CEL y EMAIL
exige traerla con `UNION ALL` como filas adicionales.

**`bdm_stage.mock_ord_prioridad` NO LA LLENA NADIE.** Esta declarada en
`05_ddl_ordenamiento_mock.sql` y la trunca `reset_mock.sql`, pero no hay un
solo `INSERT` contra ella en los tres repos, de modo que
`v_mock_rpu_post_unificacion.orden_prioridad` es **NULL siempre**. El
Ordenamiento mock escribe en `bdm_datos.rpu_orden_prioridad`, la tabla REAL,
porque el mock reutiliza `sp_ordenamiento_consolidacion_edf`. Novedades lee de
ahi en las dos vias, y esa es la unica linea que el espejo mock no sustituye.
Defecto preexistente de esa vista, anotado y no corregido.

**ORDEN EN LA BATERIA:** Novedades corre **despues** del Ordenamiento de cada
fase, porque la etapa 1 filtra por orden de prioridad no nulo (`:7593`). Al
reves saldria vacio por un efecto de secuencia y no por un defecto -- la misma
leccion que el ciclo GEO.

**NOVEDADES YA ESTA EN EL GATE (job DEV/DATABASE #409).** Se cumplio la
condicion que esta seccion exigia -- primero verde en Redshift real, el gate en
el commit siguiente --: el #409 cerro los quince `NOV-UB-01..15` con cero
FAILED. `sp_cert_asercion_final` tiene ya su rama `NOVEDADES` y
`run_cert_asercion_final.sql` **lo llama DOS VECES**, con `'UNIFICACION'` y con
`'NOVEDADES'`. No se cambio a `'TODO'` a proposito: eso encenderia Ordenamiento
de rebote, que es otra decision. Un FAILED en cualquier `NOV-UB` tumba el build.

**Y EL #409 DEJO UN DEFECTO QUE EL TABLERO NO VEIA: EL WATERMARK SALIA DEL
RELOJ.** El orquestador cerraba la corrida pasando `v_fecha` como watermark
nuevo, y `v_fecha` es `CURRENT_DATE` cuando el Framework no manda FECHA. Con la
frontera en hoy y las relaciones fechadas en el pasado, el DELTA solo recogia
la rama `fecha IS NULL`: **daba PASSED sin haber mirado la ventana**, y la
mutacion de la fase 3 (fecha `2026-06-15`) era invisible.

Corregido copiando el bloque de `16_sp_unificacion_ciclo.sql:375-392`:
`MAX(fecha_relacion_persona_ubicaci)` del universo procesado, siembra en FULL,
`GREATEST` en DELTA. **La leccion vale para todo lo que acote por fecha: el
watermark sale del MAX del DATO, nunca de la fecha de ejecucion.** Y
`NOV-UB-12` ya no cuenta cambios a secas -- desglosa cuantos entran por fecha y
cuantos por fecha nula, y exige que los primeros sean > 0. Un criterio que no
separa las dos ramas deja pasar justo esto.

**LO QUE FALTA, Y ES PETICION, NO CODIGO:** nueve catalogos que el SP consume
y no se entregaron (`TIPO`, `ZONA`, `TIPO_IDENTIFICACION`, `INDICATIVO` y
`TIPO_CUENTA` salen NULL por eso), las cuatro columnas del contrato GEO sin
pinar (`BARRIO`, `ESTRATO`, `LOCALIDAD`, `CODIGO_POSTAL`), y el reexport de
`V_Geografia` y `V_Cod_Entrega_Dato`, que **llegaron truncados a 1000 filas
exactas**. Detalle en `docs/PETICION_CATALOGOS_NOVEDADES.md`.

**UN RIESGO HEREDADO QUE TOCA LO YA DESPLEGADO.** El mapeo mide que `id` no es
unico por fila en `xpm_location_val_contactinformations`: 568.657 filas contra
142.067 `id` distintos, ~4:1. Nuestras vistas asignan
`cod_dw_persona_ubic = ci.id`, que colapsa datos de contacto; la llave deberia
derivarse de `(id, index)`. **Afecta a Unificacion, que ya esta desplegada y
certificada.** No se toca aqui: se anota y se eleva.

## Convenciones de codigo

- **UTF-8 sin BOM. ASCII sin acentos**, a proposito, en todo el repo.
  **El paquete esta limpio y el chequeo 2 de `validar.sh` ya lo EXIGE entero**
  (SLCOPRBA-1355: 58 archivos y 157 lineas, todas comentarios -- 9 en strct,
  37 en pgm, 12 en dt). Dos cosas que conviene saber si se vuelve a tocar:
  **`docs/` y `README.md` quedan fuera a proposito**, porque son prosa en
  castellano y ahi los acentos son correctos; y **habia mojibake** (UTF-8 ya
  leido una vez como cp1252) en `02_vistas_insumo_edf_views.sql`, que hay que
  **decodificar con `cp1252` ANTES de transliterar**. Con `latin-1` la
  conversion revienta en silencio en cuanto la linea lleva un caracter
  tipografico -- una flecha, una raya o una comilla curva, que no existen en
  latin-1 --, la reparacion se salta y el acento acaba convertido en `A3`.
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
- **Subconsulta escalar en la proyeccion, y `EXISTS` correlacionado dentro de
  ella: Redshift las RECHAZA**, no es que sean poco fiables:
  `XX000: This type of correlated subquery pattern is not supported due to
  internal error`. Y el error salta en EJECUCION, no al crear el
  procedimiento. **TERCER PUNTO CIEGO DEL BANCO**, hermano de `DELTA` y del
  `RAISE`: PostgreSQL las ejecuta sin una queja, de modo que la bateria local
  dio verde y el tablero salio 12 de 15 -- y Redshift tumbo el job
  DEV/DATABASE #407 en `NOV-UB-14`. La salida es **materializar los conteos**
  en una tabla de apoyo y unirla con `CROSS JOIN`; un `LEFT JOIN` contra un
  `SELECT DISTINCT` sustituye al `EXISTS`. Es lo que ya hacia el evaluador del
  Ordenamiento y lo que no aplique aqui.
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
toda entrada tenga su archivo, `WHERE` en `UPDATE`/`DELETE`, `LISTAGG` con el
mismo `WITHIN GROUP` por `SELECT`, las reservadas de Redshift como
identificador (8), los `RAISE` con expresiones (9) y **las subconsultas en la
lista de un `SELECT` (10)**. Sale distinto de cero si algo falla.

El 10 cierra la terna de los puntos ciegos del banco: `DELTA` -> 8, `RAISE` ->
9, subconsulta correlacionada en la proyeccion -> 10. **Es AVISO y no falla**:
una subconsulta no correlacionada ahi es legitima y se usa. Lleva la cuenta de
parentesis y solo mira las que abren entre un `SELECT` y su `FROM`, de modo que
`FROM (SELECT ...)`, `JOIN (SELECT ...)` e `IN (SELECT ...)` del `WHERE` no
avisan.

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
