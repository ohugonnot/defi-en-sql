#!/usr/bin/env bash
# Runs inside the postgres container. Each mutation edits a COPY of sql/ and must turn the expected test red.
set -uo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
tuees=0
total=0

muter() {
  local nom=$1 test_attendu=$2; shift 2
  total=$((total + 1))
  rm -rf "$work/sql" && cp -r sql "$work/sql"
  ( cd "$work/sql" && "$@" )
  if diff -rq sql "$work/sql" >/dev/null; then echo "$nom : mutation sans effet, script a corriger"; return; fi
  local sortie
  sortie=$(SQL_DIR="$work/sql" SKIP_DIVISION_CHECK=1 bash scripts/run-tests.sh 2>&1)
  echo "$nom"
  echo "$sortie" | grep -E '^(ROUGE|ECHEC)' | sed 's/^/  /'
  if echo "$sortie" | grep -q "^ROUGE $test_attendu"; then
    echo "  -> tuee par $test_attendu"; tuees=$((tuees + 1))
  else
    echo "  -> SURVIVANTE : $test_attendu est reste vert"
  fi
}

m1() {
  perl -0pi -e 's/SELECT div_bas\((.*?),\n\s+(.*?)\)\n\$\$/SELECT round(($1) \/ ($2))\n\$\$/s' 01_amm.sql
}
m2() { sed -i '/^CREATE CONSTRAINT TRIGGER/,/;$/d' 02_flash_swap.sql; }
m3() { sed -i "s/WHEN 'moyen' THEN prix_moyen(un_jeton)/WHEN 'moyen' THEN prix_instantane(un_jeton)/" 04_oracle.sql; }
m4() { sed -i 's/ FOR UPDATE;/;/' 01_amm.sql; }

m5() { sed -i '/^  PERFORM verrouiller_compte/d' 03_pret.sql 05_liquidation.sql; }
m6() {
  perl -0pi -e 's/INSERT INTO compte \(nom, version\) VALUES \(un_compte, 1\)\n\s+ON CONFLICT[^\n]*\n/SELECT pg_advisory_xact_lock(hashtext(\x27compte:\x27 || un_compte))\n/' 03_pret.sql
}
m7() { echo 'ALTER FUNCTION emprunter(text, uint256) RESET search_path;' >> 06_droits.sql; }
r01() { sed -i '/CREATE FUNCTION retirer(/,/END \$\$;/{/IF NOT est_sain/d}' 03_pret.sql; }
r14() { sed -i '/CREATE FUNCTION emprunter(/,/END \$\$;/{/PERFORM accumuler/d}' 03_pret.sql; }
r04() { sed -i '/CREATE FUNCTION emprunter(/,/END \$\$;/s/div_haut(montant/div_bas(montant/' 03_pret.sql; }
r05() { sed -i '/CREATE FUNCTION rembourser(/,/END \$\$;/s/montant := div_haut/montant := div_bas/' 03_pret.sql; }
r12() { sed -i '/CREATE FUNCTION retirer(/,/END \$\$;/s/montant := div_bas/montant := div_haut/' 03_pret.sql; }
r18() { sed -i 's/ELSE div_haut(pos.parts_dette/ELSE div_bas(pos.parts_dette/' 05_liquidation.sql; }
r06() { sed -i 's/SUM(div_haut(v.dette/SUM(div_bas(v.dette/' 05_liquidation.sql; }
r19() { sed -i 's/SUM(div_bas(div_bas(v.depot/SUM(div_haut(div_bas(v.depot/' 05_liquidation.sql; }
r03() { sed -i 's/parts_saisies := div_bas(/parts_saisies := div_haut(/' 05_liquidation.sql; }
r02() { sed -i 's/IF NOT FOUND OR maintenant - debut.horodatage < fenetre_secondes - 24 THEN/IF false THEN/' 04_oracle.sql; }
r24() { sed -i "/CREATE FUNCTION swap/,/END \$\$;/s/IF sortie0 >= p.reserve0 OR sortie1 >= p.reserve1 THEN RAISE EXCEPTION 'INSUFFICIENT_LIQUIDITY'; END IF;//" 01_amm.sql; }

muter "M1 montant_sortie arrondit au plus proche (round de a / b) au lieu de div_bas" t01_amm.sql m1
muter "M2 trigger differe du flash swap supprime" t02_flash_swap.sql m2
muter "M3 le pret lit le prix instantane malgre config.oracle = moyen" t05_oracle_attaque.sql m3
muter "M4 FOR UPDATE retire de pool_verrouille (le second echange est rejete par K au lieu d'etre recalcule)" t07_concurrence.sql m4
muter "M5 verrou par compte retire d'emprunter, retirer et liquider (ecriture croisee)" t07_concurrence.sql m5
muter "M6 ligne de compte remplacee par un verrou advisory (REPEATABLE READ passe l'ecriture croisee)" t07_concurrence.sql m6
muter "M7 emprunter perd son search_path" t06_droits.sql m7
muter "R01 retirer ne verifie plus la sante du compte" t10_arrondis_pret.sql r01
muter "R14 emprunter ne reserve plus les interets avant le nouveau pret" t10_arrondis_pret.sql r14
muter "R04 parts de dette arrondies vers le bas a l'emprunt" t10_arrondis_pret.sql r04
muter "R05 montant du remboursement arrondi vers le bas" t10_arrondis_pret.sql r05
muter "R12 montant du retrait arrondi vers le haut" t10_arrondis_pret.sql r12
muter "R18 dette lue (v_position) arrondie vers le bas" t10_arrondis_pret.sql r18
muter "R06 dette valorisee (v_compte) arrondie vers le bas" t10_arrondis_pret.sql r06
muter "R19 plafond d'emprunt (v_compte) arrondi vers le haut" t10_arrondis_pret.sql r19
muter "R03 parts saisies en liquidation arrondies vers le haut" t10_arrondis_pret.sql r03
muter "R02 fraicheur du prix moyen non controlee" t09_oracle_fraicheur.sql r02
muter "R24 swap sans INSUFFICIENT_LIQUIDITY" t01_amm.sql r24

echo "$tuees mutations tuees sur $total"
[ "$tuees" = "$total" ]
