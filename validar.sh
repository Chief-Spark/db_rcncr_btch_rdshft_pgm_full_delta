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
ROOT="deploy/redshift"
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
# 2. ASCII en lo que ESTE cambio anade
#    (no en todo el repo: hay cabeceras generadas con acentos de antes)
# ------------------------------------------------------------
echo "2) ASCII en las lineas anadidas"
ADDED=$( { git diff "$BASE" -- "$ROOT" 2>/dev/null | grep '^+' | grep -v '^+++'
           git ls-files --others --exclude-standard "$ROOT" 2>/dev/null \
             | while read -r f; do sed 's/^/+/' "$f"; done
         } | grep -nP '[^\x00-\x7F]' )
if [ -n "$ADDED" ]; then bad "lineas anadidas con no-ASCII:"; echo "$ADDED" | head -20 | sed 's/^/        /'
else ok "solo ASCII"; fi

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
    """Quita comentarios y literales para contar simbolos de verdad."""
    s = re.sub(r'/\*.*?\*/', ' ', s, flags=re.S)
    s = re.sub(r'--[^\n]*', ' ', s)
    s = re.sub(r"'(?:''|[^'])*'", "''", s)
    return s

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

echo
if [ $FAIL -ne 0 ]; then echo "RESULTADO: FALLA"; exit 1; fi
[ $WARN -ne 0 ] && echo "RESULTADO: OK (con avisos)" || echo "RESULTADO: OK"
exit 0
