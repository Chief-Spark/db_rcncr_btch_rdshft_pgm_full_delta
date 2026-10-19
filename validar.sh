#!/usr/bin/env bash
# ============================================================
# validar.sh - comprobaciones locales antes de empujar.
#
# POR QUE EXISTE: hasta ahora estos chequeos se rehacian a mano en cada tanda
# y el unico juez real era Jenkins, que tarda. Aqui salen en segundos y los
# puede correr cualquiera, no solo quien escribio el cambio.
#
# Sale 0 si todo pasa, 1 si algo falla. Los WARN no tumban: son para mirar.
#
# Uso:  ./validar.sh            (compara contra HEAD)
#       ./validar.sh origin/main
# ============================================================
set -uo pipefail
cd "$(dirname "$0")" || exit 1

BASE="${1:-HEAD}"
ROOT="deploy/redshift/SLCOPRBA-1353"
FAIL=0
WARN=0

ok()   { printf '  \033[32mOK\033[0m    %s\n' "$1"; }
bad()  { printf '  \033[31mFALLA\033[0m %s\n' "$1"; FAIL=1; }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$1"; WARN=1; }

echo "=== validar.sh  ($(basename "$PWD"), base=$BASE) ==="

[ -d "$ROOT" ] || { echo "No existe $ROOT"; exit 1; }

# ------------------------------------------------------------
# 1. BOM  [REDSHIFT:207]
# ------------------------------------------------------------
echo "1) BOM en .sql y .par"
BOMS=$(find "$ROOT" -name '*.sql' -o -name '*.par' | while read -r f; do
  [ "$(head -c3 "$f" | od -An -tx1 | tr -d ' \n')" = "efbbbf" ] && echo "$f"
done)
if [ -n "$BOMS" ]; then bad "archivos con BOM:"; echo "$BOMS" | sed 's/^/        /'
else ok "sin BOM"; fi

# ------------------------------------------------------------
# 2. ASCII: TOTAL en el paquete, incremental fuera de el
# ------------------------------------------------------------
echo "2) ASCII"
# El paquete se exige ENTERO y ya no como aspiracion: se limpio en
# SLCOPRBA-1355 (58 archivos, 157 lineas, todas comentarios) y hoy no tiene
# un solo byte no-ASCII, de modo que la regla se puede hacer cumplir. Es lo
# que viaja a Redshift, asi que es donde importa.
# docs/ y README.md quedan FUERA del barrido total a proposito: son prosa en
# castellano y ahi los acentos son correctos. Para esos, y para cualquier
# archivo nuevo, sigue el chequeo incremental sobre lo que el cambio anade,
# que es lo que caza un acento recien escrito (se colo uno asi, SLCOPRBA-1355).
PAQ=$(LC_ALL=C grep -rlP '[^\x00-\x7F]' "$ROOT" 2>/dev/null)
# docs/ y README.md quedan fuera TAMBIEN del incremental, no solo del barrido
# total. Antes solo estaban exentos del total, de modo que un documento NUEVO
# en docs/ -- prosa en castellano, donde los acentos son CORRECTOS -- tumbaba
# el validador. Era una contradiccion con la politica escrita, no un hallazgo:
# la caza la hizo PETICION_CATALOGOS_NOVEDADES.md (SLCOPRBA-1355).
ADDED=$( { git diff "$BASE" -- . ':(exclude)docs/**' ':(exclude)README.md' 2>/dev/null \
             | grep '^+' | grep -v '^+++'
           git ls-files --others --exclude-standard 2>/dev/null \
             | grep -v '^docs/' | grep -v '^README\.md$' \
             | while read -r f; do sed 's/^/+/' "$f"; done
         } | grep -nP '[^\x00-\x7F]' )
if [ -n "$PAQ" ]; then bad "no-ASCII en el paquete:"; echo "$PAQ" | head -20 | sed 's/^/        /'
elif [ -n "$ADDED" ]; then bad "lineas anadidas con no-ASCII:"; echo "$ADDED" | head -20 | sed 's/^/        /'
else ok "paquete ASCII puro; nada no-ASCII en lo anadido"; fi

# ------------------------------------------------------------
# 3-8. El resto, en un solo recorrido
# ------------------------------------------------------------
python3 - "$ROOT" <<'PY'
import os, re, sys, collections

root = sys.argv[1]
sqls = []
for d, _, fs in os.walk(root):
    for f in fs:
        if f.endswith('.sql'):
            sqls.append(os.path.join(d, f))
sqls.sort()

def strip_noise(s):
    """Quita comentarios y literales para contar simbolos de verdad.

    Escaner de caracteres, no regex. La version con regex tachaba los
    comentarios ANTES que los literales, de modo que un ' -- ' dentro de una
    cadena se tomaba por comentario y se comia el resto de la linea: dio un
    falso desbalance de parentesis. El orden correcto no se puede expresar con
    dos sustituciones independientes, porque cada construccion puede contener
    la marca de la otra."""
    out = []
    i, n = 0, len(s)
    while i < n:
        c = s[i]
        if c == "'":                                   # literal
            i += 1
            while i < n:
                if s[i] == "'":
                    if i + 1 < n and s[i+1] == "'":    # comilla escapada
                        i += 2; continue
                    i += 1; break
                i += 1
            out.append("''")
            continue
        if c == '-' and i + 1 < n and s[i+1] == '-':   # comentario de linea
            j = s.find('\n', i)
            if j < 0:
                break
            i = j
            continue
        if c == '/' and i + 1 < n and s[i+1] == '*':   # comentario de bloque
            j = s.find('*/', i + 2)
            i = n if j < 0 else j + 2
            out.append(' ')
            continue
        out.append(c)
        i += 1
    return ''.join(out)

GREEN, RED, YEL, OFF = '\033[32m', '\033[31m', '\033[33m', '\033[0m'
fail = warn = False
def ok(m):   print(f'  {GREEN}OK{OFF}    {m}')
def bad(m):
    global fail; fail = True; print(f'  {RED}FALLA{OFF} {m}')
def wrn(m):
    global warn; warn = True; print(f'  {YEL}WARN{OFF}  {m}')

# ---- 3. $$ balanceados ----
print('3) $$ balanceados')
off = [f for f in sqls if strip_noise(open(f, encoding='utf-8', errors='replace').read()).count('$$') % 2]
bad('impares: ' + ', '.join(off)) if off else ok(f'{len(sqls)} archivos')

# ---- 4. parentesis balanceados ----
print('4) parentesis balanceados')
off = []
for f in sqls:
    t = strip_noise(open(f, encoding='utf-8', errors='replace').read())
    a, c = t.count('('), t.count(')')
    if a != c:
        off.append(f'{f} ({a}/{c})')
bad('desbalanceados: ' + '; '.join(off)) if off else ok(f'{len(sqls)} archivos')

# ---- 7. UPDATE/DELETE con WHERE  [REDSHIFT:232] ----
print('5) UPDATE/DELETE con WHERE  [REDSHIFT:232]')
off = []
for f in sqls:
    t = strip_noise(open(f, encoding='utf-8', errors='replace').read())
    for st in t.split(';'):
        s = st.strip()
        if re.match(r'^(UPDATE|DELETE\s+FROM)\b', s, re.I) and not re.search(r'\bWHERE\b', s, re.I):
            off.append(f'{f}: {" ".join(s.split())[:70]}')
bad('sin WHERE:\n        ' + '\n        '.join(off)) if off else ok('todos acotados')

# ---- 8. LISTAGG con el mismo WITHIN GROUP  (leccion del job #341) ----
print('6) LISTAGG con el mismo WITHIN GROUP por sentencia')
off = []
for f in sqls:
    t = strip_noise(open(f, encoding='utf-8', errors='replace').read())
    for st in t.split(';'):
        if st.upper().count('LISTAGG') < 2:
            continue
        wg = {' '.join(m.split()).upper()
              for m in re.findall(r'WITHIN\s+GROUP\s*\(\s*ORDER\s+BY(.*?)\)', st, re.I | re.S)}
        if len(wg) > 1:
            off.append(f'{f}: {len(wg)} clausulas distintas -> revisar si estan en el MISMO SELECT')
if off:
    wrn('revisar a mano:\n        ' + '\n        '.join(off))
else:
    ok('sin mezcla')

sys.exit(2 if fail else (3 if warn else 0))
PY
RC=$?
[ $RC -eq 2 ] && FAIL=1
[ $RC -eq 3 ] && WARN=1

# ------------------------------------------------------------
# 7. .par: paridad, reverso y que toda entrada tenga su archivo  [REDSHIFT:219]
# ------------------------------------------------------------
echo "7) deploy.par / rollback.par  [REDSHIFT:219, leccion #5]"
D="$ROOT/deploy.par"; R="$ROOT/rollback.par"
if [ ! -f "$D" ] || [ ! -f "$R" ]; then
  warn "no hay deploy.par/rollback.par en $ROOT"
else
  ND=$(grep -cve '^[[:space:]]*$' "$D"); NR=$(grep -cve '^[[:space:]]*$' "$R")
  if [ "$ND" -ne "$NR" ]; then bad "paridad rota: deploy=$ND, rollback=$NR"
  else ok "paridad $ND/$ND"; fi

  MISS=""
  while read -r e; do [ -z "$e" ] && continue
    [ -f "$ROOT/SQL/$e" ] || MISS="$MISS\n        deploy.par -> SQL/$e"
  done < "$D"
  while read -r e; do [ -z "$e" ] && continue
    [ -f "$ROOT/RevSQL/$e" ] || MISS="$MISS\n        rollback.par -> RevSQL/$e"
  done < "$R"
  if [ -n "$MISS" ]; then bad "entradas sin archivo:$(printf "$MISS")"
  else ok "toda entrada tiene su archivo"; fi

  # ---- y AL REVES: todo archivo tiene su entrada ----
  # Lo caro de este chequeo es que lo contrario pasaba inadvertido. El paquete
  # llevaba RevSQL/rollback_ordenamiento_edf.sql sin una sola linea en
  # rollback.par ni una referencia en los tres repos: entro con el movimiento
  # del 418 y viajaba a Bitbucket duplicando nueve DROP que ya cubren los
  # archivos por SP. Un rollback a medias es peor que ninguno, y nada lo veia:
  # el chequeo de arriba mira que toda ENTRADA tenga archivo, no al reves.
  #
  # EN UN REPO 'data' NO ES UN FALLO Y POR ESO SE LEE global.type. En dt hay 20
  # runners y validaciones que existen para correrse A MANO en DBeaver y que el
  # .par no lista a proposito. En structure y program no: ahi todo archivo lo
  # aplica el pipeline o no lo aplica nadie.
  TIPO=$(sed -nE 's/^[[:space:]]*type:[[:space:]]*([a-z]+).*/\1/p' .jenkins.yml 2>/dev/null | head -1)
  HUERF=""
  for d in SQL RevSQL; do
    [ "$d" = SQL ] && par="$D" || par="$R"
    for f in "$ROOT/$d"/*; do
      [ -f "$f" ] || continue
      b=$(basename "$f")
      grep -qxF "$b" "$par" || HUERF="$HUERF\n        $d/$b"
    done
  done
  if [ -z "$HUERF" ]; then ok "todo archivo tiene su entrada"
  elif [ "$TIPO" = data ]; then
    warn "archivos sin entrada en el .par ($(printf "$HUERF" | grep -c .) en un repo data: se corren a mano)"
  else
    bad "archivos sin entrada en el .par:$(printf "$HUERF")"
  fi

  # reverso exacto, normalizando el prefijo NN_rollback_
  norm() { sed -E 's/^([0-9]+[a-z]?)_rollback_/\1_/; s/^rollback_//'; }
  if diff -q <(grep -ve '^[[:space:]]*$' "$D" | norm) \
             <(grep -ve '^[[:space:]]*$' "$R" | norm | tac) >/dev/null 2>&1; then
    ok "rollback es el reverso exacto"
  else
    warn "rollback no es reverso exacto (puede ser legitimo: hay entradas idempotentes que se re-ejecutan hacia adelante)"
    diff <(grep -ve '^[[:space:]]*$' "$D" | norm) \
         <(grep -ve '^[[:space:]]*$' "$R" | norm | tac) | head -10 | sed 's/^/        /'
  fi
fi

# ------------------------------------------------------------
# 8. Palabras reservadas de Redshift usadas como identificador
#
# EL PUNTO CIEGO DEL BANCO. PostgreSQL acepta varias palabras que Redshift
# reserva, de modo que una corrida local verde no dice nada sobre esto.
# Lo pago el job DEV/DATABASE #366: un alias "AS delta" en el CTAS de
# bdm_tempo.stg_cert_ord_arq tumbo el deploy de pgm en el archivo 73 de 74.
#   42601: syntax error at or near "delta" in context "(g.delta"
# DELTA viene de los codificados DELTA / DELTA32K.
# ------------------------------------------------------------
echo "8) palabras reservadas de Redshift como identificador  [REDSHIFT:112]"
RESERVADAS='delta|delta32k|raw|encode|top|tag|percent|parallel|offline|recover|sysdate|distkey|sortkey|credentials|lzo|lzop|bytedict|runlength|text255|text32k|aes128|aes256|mostly13|mostly16|mostly32'
RES_HIT=$(grep -rniE "\\bAS[[:space:]]+($RESERVADAS)[[:space:]]*(,|$)" "$ROOT/SQL" "$ROOT/RevSQL" 2>/dev/null \
          | grep -viE 'AS[[:space:]]+(varchar|integer|decimal|date|bigint|float|timestamp)' || true)
RES_COL=$(grep -rniE "^[[:space:]]+($RESERVADAS)[[:space:]]+(VARCHAR|INTEGER|BIGINT|DECIMAL|DATE|FLOAT|SMALLINT|TIMESTAMP)" \
          "$ROOT/SQL" "$ROOT/RevSQL" 2>/dev/null || true)
if [ -n "$RES_HIT$RES_COL" ]; then
  bad "reservadas de Redshift usadas como identificador:"
  printf '%s\n%s\n' "$RES_HIT" "$RES_COL" | grep -v '^$' | head -10 | sed 's|^|        |'
else
  ok "ninguna reservada usada como alias ni como columna"
fi

echo "9) argumentos de RAISE con expresiones o literales  [REDSHIFT:112]"
# El RAISE de Redshift admite VARIABLES, no expresiones:
#   RAISE level 'format' [, variable [, ...]];
# Una funcion en la lista es error de SINTAXIS en el propio CREATE. PostgreSQL
# si las admite, asi que el banco local no lo ve. Tumbo el job #367.
# UN LITERAL DE CADENA TAMPOCO VALE, y es el mismo error con otra cara:
#   RAISE EXCEPTION '%: ...', 'nombre_del_sp', v_x;   <-- 42601
# El nombre va DENTRO de la cadena de formato. Tumbo el job #419, y el chequeo
# no lo veia porque un literal no lleva parentesis: por eso ahora se mira
# tambien si queda una comilla en la cola.
# Se une cada sentencia hasta su ';', se BORRA la cadena de formato (que lleva
# parentesis propios: "criterio(s)") y se mira si queda un '(' en la cola.
RAISE_HIT=$(find "$ROOT/SQL" "$ROOT/RevSQL" -name '*.sql' 2>/dev/null | sort | while read -r f; do
  awk -v q="'" -v ARCH="$f" '
    { linea = $0 }
    buf == "" && linea ~ /^[[:space:]]*--/ { next }
    buf != "" || linea ~ /[Rr][Aa][Ii][Ss][Ee][[:space:]]/ {
      if (buf == "") ini = FNR
      buf = buf " " linea
      if (linea ~ /;/) {
        cola = buf
        sub("^[^" q "]*" q "([^" q "]|" q q ")*" q, "", cola)
        if (index(cola, "(") > 0 || index(cola, q) > 0) printf "%s:%d: %s\n", ARCH, ini, substr(buf, 1, 120)
        buf = ""
      }
    }
  ' "$f"
done)
if [ -n "$RAISE_HIT" ]; then
  bad "RAISE con expresiones o literales en los argumentos (Redshift solo admite variables):"
  printf '%s\n' "$RAISE_HIT" | head -10 | sed 's|^|        |'
else
  ok "ningun RAISE pasa una expresion ni un literal como argumento"
fi

# ------------------------------------------------------------
# 10. Subconsulta en la LISTA del SELECT
#
# TERCER PUNTO CIEGO DEL BANCO, hermano de DELTA (chequeo 8) y del RAISE
# (chequeo 9). Redshift RECHAZA una subconsulta escalar en la proyeccion
# cuando lleva dentro un EXISTS correlacionado:
#   XX000: This type of correlated subquery pattern is not supported
#          due to internal error
# y el error salta en EJECUCION, no al crear el procedimiento. PostgreSQL la
# ejecuta sin una queja, de modo que la bateria local dio verde y Redshift
# tumbo el job DEV/DATABASE #407 en NOV-UB-14. La salida es materializar los
# conteos en una tabla de apoyo y unirla con CROSS JOIN.
#
# ES AVISO Y NO FALLA, A PROPOSITO: una subconsulta no correlacionada en la
# proyeccion es SQL legitimo y aqui se usa. Lo que hace falta no es prohibirla
# sino que nadie la escriba sin mirar si esta correlacionada.
#
# COMO SE DETECTA: se recorre el token y se lleva la cuenta de parentesis.
# A cada profundidad se marca si estamos entre un SELECT y su FROM; un '('
# seguido de SELECT abierto DENTRO de esa franja es una subconsulta en la
# lista. Asi no se confunde con FROM (SELECT ...), JOIN (SELECT ...) ni
# IN (SELECT ...) del WHERE, que son los tres usos sanos y frecuentes.
# ------------------------------------------------------------
echo "10) subconsulta en la lista del SELECT  [REDSHIFT:XX000]"
SUB_HIT=$(find "$ROOT/SQL" "$ROOT/RevSQL" -name '*.sql' 2>/dev/null | sort | while read -r f; do
  awk -v ARCH="$f" '
    {
      linea = $0
      sub(/--.*$/, "", linea)            # comentario de linea
      gsub(/\047[^\047]*\047/, " ", linea)  # literales: sus parentesis no cuentan
      gsub(/\(/, " ( ", linea)
      gsub(/\)/, " ) ", linea)
      n = split(linea, t, /[ \t,;]+/)
      for (i = 1; i <= n; i++) {
        tok = toupper(t[i])
        if (tok == "") continue
        if (tok == "(") {
          sig = ""
          for (j = i + 1; j <= n; j++) if (t[j] != "") { sig = toupper(t[j]); break }
          if (sig == "SELECT" && proj[prof] == 1)
            printf "%s:%d: %s\n", ARCH, FNR, substr($0, 1, 110)
          prof++
          proj[prof] = 0
        } else if (tok == ")") {
          proj[prof] = 0
          if (prof > 0) prof--
        } else if (tok == "SELECT") {
          proj[prof] = 1
        } else if (tok == "FROM") {
          proj[prof] = 0
        }
      }
    }
  ' "$f"
done)
if [ -n "$SUB_HIT" ]; then
  warn "subconsulta en la lista del SELECT (revisar si esta CORRELACIONADA; si lo esta, materializar y CROSS JOIN):"
  printf '%s\n' "$SUB_HIT" | head -10 | sed 's|^|        |'
else
  ok "ninguna subconsulta en la lista de un SELECT"
fi

echo
if [ $FAIL -ne 0 ]; then echo "RESULTADO: FALLA"; exit 1; fi
[ $WARN -ne 0 ] && echo "RESULTADO: OK (con avisos)" || echo "RESULTADO: OK"
exit 0
