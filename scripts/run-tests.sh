#!/usr/bin/env bash
# Runs inside the postgres container. SQL_DIR / TESTS selectable for the mutation script.
set -uo pipefail
cd "$(dirname "$0")/.."
sql_dir=${SQL_DIR:-sql}
modele=modele_$$
psql_base=(psql -X -q -U postgres -v ON_ERROR_STOP=1)
tmp=$(mktemp -d)
trap 'for d in "${bases[@]:-}"; do [ -n "$d" ] && psql -X -q -U postgres -d postgres -c "DROP DATABASE IF EXISTS \"$d\" WITH (FORCE)" >/dev/null 2>&1; done; rm -rf "$tmp"' EXIT
bases=()

if [ -z "${SKIP_DIVISION_CHECK:-}" ]; then
  # A "/" on numeric rounds to nearest. Any hit here is a bug.
  if grep -nE '(^|[^/*])/([^/*]|$)' "$sql_dir"/*.sql; then
    echo "ECHEC : division par / dans $sql_dir (utiliser div_bas ou div_haut)"; exit 1
  fi
fi

bases+=("$modele")
"${psql_base[@]}" -d postgres -c "CREATE DATABASE \"$modele\"" || exit 1
"${psql_base[@]}" -d "$modele" -c "CREATE EXTENSION dblink" || exit 1
for f in "$sql_dir"/*.sql; do
  "${psql_base[@]}" -d "$modele" -f "$f" >/dev/null || { echo "ECHEC : chargement de $f"; exit 1; }
done

read -ra tests <<< "${TESTS:-}"
[ "${#tests[@]}" = 0 ] && tests=(tests/t*.sql)
for t in "${tests[@]}"; do
  base=t_$$_$(basename "$t" .sql)
  bases+=("$base")
  "${psql_base[@]}" -d postgres -c "CREATE DATABASE \"$base\" TEMPLATE \"$modele\"" || exit 1
done

lancer() {
  local t=$1 base=t_$$_$(basename "$1" .sql)
  psql -X -q -U postgres -d "$base" -v ON_ERROR_STOP=1 -v VERBOSITY=terse -o /dev/null -f "$t" 2> "$tmp/$(basename "$t").log"
  echo $? > "$tmp/$(basename "$t").code"
}
for t in "${tests[@]}"; do lancer "$t" & done
wait

total=0; rouges=0
for t in "${tests[@]}"; do
  nom=$(basename "$t")
  code=$(cat "$tmp/$nom.code")
  verts=$(grep -c 'NOTICE:  ok' "$tmp/$nom.log")
  if [ "$code" = 0 ]; then
    echo "vert  $nom ($verts assertions)"; total=$((total + verts))
  else
    rouges=$((rouges + 1))
    # Tests expect some errors on purpose: the failing assertion says ECHEC, else the last error is the cause.
    diagnostic=$(grep 'ECHEC' "$tmp/$nom.log" | head -n 1)
    [ -z "$diagnostic" ] && diagnostic=$(grep 'ERROR' "$tmp/$nom.log" | tail -n 1)
    echo "ROUGE $nom : $diagnostic"
  fi
done
if [ "$rouges" = 0 ]; then echo "OK : ${#tests[@]} fichiers, $total assertions, 0 echec"; else echo "ECHEC : $rouges fichier(s) rouge(s)"; exit 1; fi
