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
  # Killed only by a named assertion (its ECHEC line), not by a raw error that a refactoring could move.
  if echo "$sortie" | grep -q "^ROUGE $test_attendu.*ECHEC"; then
    echo "  -> tuee par $test_attendu"; tuees=$((tuees + 1))
  else
    echo "  -> SURVIVANTE : $test_attendu n'a pas echoue sur une assertion nommee"
  fi
}

m1() {
  perl -0pi -e 's/SELECT div_bas\((.*?),\n\s+(.*?)\)\n\$\$/SELECT round(($1) \/ ($2))\n\$\$/s' 01_amm.sql
}
m2() { sed -i '/^CREATE CONSTRAINT TRIGGER/,/;$/d' 02_flash_swap.sql; }
m3() { sed -i "s/WHEN 'moyen' THEN prix_moyen(un_jeton)/WHEN 'moyen' THEN prix_instantane(un_jeton)/" 04_oracle.sql; }
m4() { sed -i 's/ FOR UPDATE;/;/' 01_amm.sql; }
m5() { sed -i '/^  PERFORM verrouiller_compte/d' 03_pret.sql 05_liquidation.sql; }
m7() { echo 'ALTER FUNCTION emprunter(text, uint256) RESET search_path;' >> 06_droits.sql; }
m8() { sed -i '/IF p.flash_en_cours THEN/d' 01_amm.sql; }
m9() { sed -i '/UPDATE pool SET flash_en_cours = false/d' 02_flash_swap.sql; }
m10() { sed -i '/PERFORM 1 FROM chaine FOR SHARE;/d' 01_amm.sql; }
m11() { sed -i '/PERFORM 1 FROM chaine FOR SHARE;/d' 03_pret.sql; }
m12() { sed -i '/PERFORM 1 FROM chaine FOR SHARE;/d' 04_oracle.sql; }
m13() { sed -i "/FROM pool WHERE jeton0 = 'WETH'/d" 03_pret.sql; }
m14() { sed -i 's/prix_garantie(v.jeton)/prix(v.jeton)/' 05_liquidation.sql; }
m15() { sed -i 's/SELECT NOT EXISTS (SELECT 1 FROM v_compte_malsain/SELECT true OR NOT EXISTS (SELECT 1 FROM v_compte_malsain/' 05_liquidation.sql; }
m16() { sed -i '/IF p.reserve0 = 0 OR p.reserve1 = 0 THEN/d' 01_amm.sql; }
m17() { sed -i '/IF p.parts_total = 0 THEN RAISE/d' 01_amm.sql; }
m18() { sed -i '/IF a.parts_depot_total = 0 THEN RAISE/d' 03_pret.sql; }
m19() { sed -i '/IF a.parts_dette_total = 0 THEN RAISE/d' 03_pret.sql; }
m20() { sed -i "/IF NOT FOUND THEN RAISE EXCEPTION 'SOLDE_INSUFFISANT'/d" 00_socle.sql; }
m21() { sed -i "/CREATE FUNCTION retirer_liquidite(/,/END \$\$;/{/IF NOT FOUND THEN RAISE EXCEPTION 'PARTS_INSUFFISANTES'/d}" 01_amm.sql; }
m22() { sed -i "/CREATE FUNCTION retirer(/,/END \$\$;/{/IF NOT FOUND THEN RAISE EXCEPTION 'PARTS_INSUFFISANTES'/d}" 03_pret.sql; }
m23() { sed -i "/CREATE FUNCTION rembourser(/,/END \$\$;/{/IF NOT FOUND THEN RAISE EXCEPTION 'PARTS_INSUFFISANTES'/d}" 03_pret.sql; }
m24() { sed -i "/IF NOT FOUND THEN RAISE EXCEPTION 'COLLATERAL_INSUFFISANT'/d" 05_liquidation.sql; }
m25() { sed -i '/CREATE FUNCTION rembourser(/,/END \$\$;/{/PERFORM accumuler/d}' 03_pret.sql; }
m26() { sed -i '/CREATE FUNCTION retirer(/,/END \$\$;/{/PERFORM accumuler/d}' 03_pret.sql; }
m27() { sed -i '/CREATE FUNCTION deposer(/,/END \$\$;/{/PERFORM accumuler/d}' 03_pret.sql; }
m28() { echo 'GRANT TRUNCATE ON observation TO PUBLIC;' >> 06_droits.sql; }
m29() { sed -i '/CREATE FUNCTION deposer(/,/END \$\$;/{/PERFORM verrouiller_compte/d}' 03_pret.sql; }
m30() { sed -i '/CREATE FUNCTION rembourser(/,/END \$\$;/{/PERFORM verrouiller_compte/d}' 03_pret.sql; }
m31() { sed -i "/IF vers LIKE 'pret:%' THEN/d" 00_socle.sql; }
m32() { sed -i 's/IF p.id IS NULL OR p.reserve0 = 0 OR p.reserve1 = 0 THEN/IF p.id IS NULL THEN/' 04_oracle.sql; }
m33() { perl -0pi -e 's/(  UPDATE pool SET flash_en_cours = true WHERE id = id_pool;\n)(  INSERT INTO flash_swap[^\n]*\n[^\n]*\n)/$2$1/' 02_flash_swap.sql; }
m34() { perl -0pi -e 's/(  PERFORM 1 FROM pool WHERE jeton0 = \x27WETH\x27[^\n]*\n)(  INSERT INTO compte[^\n]*\n[^\n]*\n)/$2$1/' 03_pret.sql; }
m35() { sed -i "/IF a_collat.depot_total = 0 THEN/d" 05_liquidation.sql; }
m36() { echo 'GRANT UPDATE (parts) ON part_lp TO PUBLIC;' >> 06_droits.sql; }
m37() { echo 'GRANT TRIGGER, REFERENCES ON solde TO PUBLIC;' >> 06_droits.sql; }
m38() { echo 'GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO PUBLIC;' >> 06_droits.sql; }
m39() { sed -i "s/IF vers LIKE 'pret:%' THEN/IF vers = 'pret:WETH' THEN/" 00_socle.sql; }
m40() { echo 'GRANT UPDATE ON solde TO bob;' >> 06_droits.sql; }
m41() { echo 'GRANT MAINTAIN ON pool TO PUBLIC;' >> 06_droits.sql; }
m42() { sed -i "/IF parts = 0 THEN RAISE EXCEPTION 'PARTS_NULLES'/d" 05_liquidation.sql; }
m43() { sed -i "/IF prix(jeton_collateral) = 0 THEN/d" 05_liquidation.sql; }
m44() { perl -0pi -e 's/  PERFORM verrouiller_compte\(LEAST\(debiteur COLLATE "C", session_user::text\)\);\n  PERFORM verrouiller_compte\(GREATEST\(debiteur COLLATE "C", session_user::text\)\);/  PERFORM verrouiller_compte(debiteur);/' 05_liquidation.sql; }
m45() { echo 'GRANT EXECUTE ON FUNCTION deplacer TO bob;' >> 06_droits.sql; }
m46() { echo 'GRANT CREATE ON SCHEMA public TO bob;' >> 06_droits.sql; }
m47() { sed -i '/PERFORM verrouiller_compte(GREATEST(debiteur/d' 05_liquidation.sql; }
m48() { sed -i 's/debiteur COLLATE "C"/debiteur/g' 05_liquidation.sql; }
m49() { sed -i 's/  PERFORM verrouiller_compte(GREATEST(debiteur COLLATE "C", session_user::text));/  PERFORM verrouiller_compte(debiteur);/' 05_liquidation.sql; }
m50() { perl -0pi -e 's/(  PERFORM verrouiller_compte\(LEAST[^\n]*\n  PERFORM verrouiller_compte\(GREATEST[^\n]*\n)(.*?)(  IF est_sain\(debiteur\)[^\n]*\n)/$2$3$1/s' 05_liquidation.sql; }
m51() { sed -i 's/IF parts_max IS NULL OR parts > parts_max THEN/IF parts > parts_max THEN/' 05_liquidation.sql; }
m52() { sed -i '/PERFORM accumuler(jeton_dette)/d' 05_liquidation.sql; }
m53() { sed -i '/PERFORM accumuler(jeton_collateral)/d' 05_liquidation.sql; }
m54() { sed -i 's/IF parts_max IS NULL OR parts > parts_max THEN/IF a_dette.parts_dette_total = 0 OR parts > parts_max THEN/' 05_liquidation.sql; }
m55() { sed -i "s/IF SQLERRM IN ('PAS_DE_PRIX', 'PAS_ENCORE_OBSERVE')/IF SQLERRM = 'PAS_DE_PRIX'/" 04_oracle.sql; }
m56() { sed -i 's/THEN div_haut(v.dette \* prix(v.jeton)/THEN div_haut(v.dette * prix_garantie(v.jeton)/' 05_liquidation.sql; }
m57() { sed -i "s/IF SQLERRM IN ('PAS_DE_PRIX', 'PAS_ENCORE_OBSERVE')/IF true/" 04_oracle.sql; }
m58() {
  perl -0pi -e 's/div_haut\((p\.total_emprunte \* t\.taux_emprunt \* \(c\.horodatage - p\.horodatage_interets\)),\n(\s+)1e18 \* 31536000\)/div_bas($1 + 15768000e18,\n$2 1e18 * 31536000)/' 03_pret.sql
}
m59() { sed -i 's/SELECT div_bas(parts_dette \* dette_pool.close_factor, 1e18)/SELECT div_haut(parts_dette * dette_pool.close_factor, 1e18)/' 05_liquidation.sql; }
m60() { sed -i 's/div_bas(montant1 \* p.parts_total, p.reserve1))/div_haut(montant1 * p.parts_total, p.reserve1))/' 01_amm.sql; }
m61() { sed -i 's/WHERE dette > max_empruntable/WHERE dette >= max_empruntable/' 05_liquidation.sql; }
m62() { sed -i "s/IF SQLERRM IN ('PAS_DE_PRIX', 'PAS_ENCORE_OBSERVE')/IF SQLERRM IN ('PAS_DE_PRIX', 'PAS_ENCORE_OBSERVE', 'OBSERVATIONS_INSUFFISANTES')/" 04_oracle.sql; }
m63() { sed -i 's/IF NOT EXISTS (SELECT 1 FROM observation$/IF true OR NOT EXISTS (SELECT 1 FROM observation/' 04_oracle.sql; }
m65() { sed -i '/IF p.reserve0 = 0 OR p.reserve1 = 0 THEN RETURN; END IF;/d' 04_oracle.sql; }
m64() { sed -i 's/WHERE dette > max_empruntable/WHERE dette > max_empruntable + 1/' 05_liquidation.sql; }
r01() { sed -i '/CREATE FUNCTION retirer(/,/END \$\$;/{/IF NOT est_sain/d}' 03_pret.sql; }
r02() { sed -i 's/IF NOT FOUND OR maintenant - debut.horodatage < fenetre_secondes - 24 THEN/IF false THEN/' 04_oracle.sql; }
r03() { sed -i 's/parts_saisies := div_bas(/parts_saisies := div_haut(/' 05_liquidation.sql; }
r04() { sed -i '/CREATE FUNCTION emprunter(/,/END \$\$;/s/div_haut(montant/div_bas(montant/' 03_pret.sql; }
r05() { sed -i '/CREATE FUNCTION rembourser(/,/END \$\$;/s/montant := div_haut/montant := div_bas/' 03_pret.sql; }
r06() { sed -i 's/THEN div_haut(v.dette/THEN div_bas(v.dette/' 05_liquidation.sql; }
r12() { sed -i '/CREATE FUNCTION retirer(/,/END \$\$;/s/montant := div_bas/montant := div_haut/' 03_pret.sql; }
r14() { sed -i '/CREATE FUNCTION emprunter(/,/END \$\$;/{/PERFORM accumuler/d}' 03_pret.sql; }
r18() { sed -i 's/ELSE div_haut(pos.parts_dette/ELSE div_bas(pos.parts_dette/' 05_liquidation.sql; }
r19() { sed -i 's/THEN div_bas(div_bas(v.depot/THEN div_haut(div_bas(v.depot/' 05_liquidation.sql; }
r24() { sed -i "/CREATE FUNCTION swap/,/END \$\$;/s/IF sortie0 >= p.reserve0 OR sortie1 >= p.reserve1 THEN RAISE EXCEPTION 'INSUFFICIENT_LIQUIDITY'; END IF;//" 01_amm.sql; }

m6() {
  perl -0pi -e 's/INSERT INTO compte \(nom, version\) VALUES \(un_compte, 1\)\n\s+ON CONFLICT[^\n]*\n/PERFORM pg_advisory_xact_lock(hashtext(\x27compte:\x27 || un_compte));\n/' 03_pret.sql
}

muter "M1 montant_sortie arrondit au plus proche (round de a / b) au lieu de div_bas" t01_amm.sql m1
muter "M2 trigger differe du flash swap supprime" t02_flash_swap.sql m2
muter "M3 le pret lit le prix instantane malgre config.oracle = moyen" t05_oracle_attaque.sql m3
muter "M4 FOR UPDATE retire de pool_verrouille (le second echange est rejete par K au lieu d'etre recalcule)" t07_concurrence.sql m4
muter "M5 verrou par compte retire d'emprunter, retirer, deposer, rembourser et liquider (ecriture croisee)" t07_concurrence.sql m5
muter "M6 ligne de compte remplacee par un verrou advisory (REPEATABLE READ passe l'ecriture croisee)" t07_concurrence.sql m6
muter "M7 emprunter perd son search_path" t06_droits.sql m7
muter "M8 pool_verrouille ne refuse plus un pool en flash swap (reentree par ajouter ou retirer la liquidite)" t02_flash_swap.sql m8
muter "M9 le controle au COMMIT ne baisse plus le drapeau de pret" t02_flash_swap.sql m9
muter "M10 pool_verrouille ne verrouille plus l'horloge (echange sur l'heure d'un instantane perime)" t07_concurrence.sql m10
muter "M11 verrouiller_prets ne verrouille plus l'horloge (interets factures a l'heure perimee)" t07_concurrence.sql m11
muter "M12 observer ne verrouille plus l'horloge" t07_concurrence.sql m12
muter "M13 le controle de sante ne verrouille plus les pools de prix (dette validee au prix perime)" t07_concurrence.sql m13
muter "M14 le plafond d'emprunt lit prix() : un collateral sans prix bloque la sante des comptes" t03_pret.sql m14
muter "M15 est_sain rend vrai meme avec une dette" t03_pret.sql m15
muter "M16 echanger sans garde sur un pool vide (division par zero brute)" t01_amm.sql m16
muter "M17 retirer_liquidite sans garde sur un pool sans parts (division par zero brute)" t01_amm.sql m17
muter "M18 retirer sans garde sur un coffre sans depot (division par zero brute)" t03_pret.sql m18
muter "M19 rembourser sans garde sur un coffre sans dette (division par zero brute)" t03_pret.sql m19
muter "M20 deplacer ne leve plus SOLDE_INSUFFISANT" t01_amm.sql m20
muter "M21 retirer_liquidite ne leve plus PARTS_INSUFFISANTES" t01_amm.sql m21
muter "M22 retirer ne leve plus PARTS_INSUFFISANTES" t03_pret.sql m22
muter "M23 rembourser ne leve plus PARTS_INSUFFISANTES" t03_pret.sql m23
muter "M24 liquider ne leve plus COLLATERAL_INSUFFISANT" t04_liquidation.sql m24
muter "M25 rembourser ne comptabilise plus les interets" t11_accumulation_interets.sql m25
muter "M26 retirer ne comptabilise plus les interets" t11_accumulation_interets.sql m26
muter "M27 deposer ne comptabilise plus les interets" t11_accumulation_interets.sql m27
muter "M28 un privilege TRUNCATE accorde a tous sur observation" t06_droits.sql m28
muter "M29 deposer ne prend plus la ligne du compte (liquidation sur l'etat d'avant un depot dans un troisieme coffre)" t07_concurrence.sql m29
muter "M30 rembourser ne prend plus la ligne du compte (liquidation sur l'etat d'avant un remboursement dans un troisieme coffre)" t07_concurrence.sql m30
muter "M31 transferer accepte une caisse de coffre" t03_pret.sql m31
muter "M32 prix_instantane sans garde sur un pool vide (division par zero brute)" t09_oracle_fraicheur.sql m32
muter "M33 flash_swap pose le drapeau apres l'INSERT (le mode IMMEDIATE gele le pool)" t02_flash_swap.sql m33
muter "M34 verrouiller_compte prend la ligne du compte avant les pools de prix (interblocage avec une liquidation)" t07_concurrence.sql m34
muter "M35 liquider sans garde sur un coffre de collateral sans depot (division par zero brute)" t04_liquidation.sql m35
muter "M36 un privilege UPDATE de colonne accorde a tous sur part_lp" t06_droits.sql m36
muter "M37 TRIGGER et REFERENCES accordes a tous sur solde" t06_droits.sql m37
muter "M38 USAGE et UPDATE des sequences accordes a tous" t06_droits.sql m38
muter "M39 transferer ne refuse que la caisse du coffre WETH" t03_pret.sql m39
muter "M40 un privilege UPDATE accorde a bob sur solde (un role nomme, pas seulement alice)" t06_droits.sql m40
muter "M41 MAINTAIN accorde a tous sur pool" t06_droits.sql m41
muter "M42 liquider ne refuse plus zero part avant le test de sante (ACCOUNT_HEALTHY a la place de PARTS_NULLES)" t04_liquidation.sql m42
muter "M43 liquider sans garde sur un collateral a prix nul (division par zero brute)" t04_liquidation.sql m43
muter "M44 liquider ne prend plus la ligne de compte du liquidateur (liquidation d'un compte renfloue par sa propre saisie)" t07_concurrence.sql m44
muter "M45 EXECUTE sur une fonction interne accorde a bob" t06_droits.sql m45
muter "M46 CREATE sur le schema accorde a bob" t06_droits.sql m46
muter "M47 liquider ne prend plus la ligne de compte la plus grande par nom (le compte renfloue a le plus grand nom)" t07_concurrence.sql m47
muter "M48 liquider compare les noms sans collation fixee (nom a collation explicite : 42P22)" t04_liquidation.sql m48
muter "M49 liquider ne prend la ligne du liquidateur que si son nom est le plus petit (seconde ligne remplacee par le debiteur)" t07_concurrence.sql m49
muter "M50 liquider juge la sante du debiteur avant de prendre les lignes de compte (READ COMMITTED : saisie sur un compte renfloue)" t07_concurrence.sql m50
muter "M51 liquider sans garde sur un debiteur sans position dans le coffre de dette (saisie sans remboursement)" t04_liquidation.sql m51
muter "M52 liquider ne comptabilise plus les interets du coffre de dette" t11_accumulation_interets.sql m52
muter "M53 liquider ne comptabilise plus les interets du coffre de collateral" t11_accumulation_interets.sql m53
muter "M54 liquider ne refuse que sur le total de parts de dette du coffre, pas sur l'absence de position du debiteur" t04_liquidation.sql m54
muter "M55 prix_garantie ne couvre pas PAS_ENCORE_OBSERVE (coffre liste mais pas encore observe)" t09_oracle_fraicheur.sql m55
muter "M56 la dette est valorisee par prix_garantie : un jeton non cote s'emprunte gratuitement" t03_pret.sql m56
muter "M57 prix_garantie avale toute erreur, pas seulement un prix absent" t09_oracle_fraicheur.sql m57
muter "M58 les interets sont arrondis au plus proche au lieu du plafond" t11_accumulation_interets.sql m58
muter "M59 le maximum du close factor est arrondi vers le haut" t10_arrondis_pret.sql m59
muter "M60 les parts frappees par ajouter_liquidite sont arrondies vers le haut sur la branche T1" t01_amm.sql m60
muter "M61 v_compte_malsain compte un emprunt exactement au plafond comme malsain" t03_pret.sql m61
muter "M62 prix_garantie convertit aussi OBSERVATIONS_INSUFFISANTES en 0 (un trou de maintenance rend liquidable un compte sain)" t09_oracle_fraicheur.sql m62
muter "M63 prix_moyen traite tout manque d'observations comme un amorcage (un trou de maintenance vaut 0)" t09_oracle_fraicheur.sql m63
muter "M64 v_compte_malsain tolere un wei de dette au dessus du plafond" t03_pret.sql m64
muter "M65 observer enregistre un pool vide (une observation a reserves nulles dilue le prix moyen)" t09_oracle_fraicheur.sql m65
muter "R01 retirer ne verifie plus la sante du compte" t10_arrondis_pret.sql r01
muter "R02 fraicheur du prix moyen non controlee" t09_oracle_fraicheur.sql r02
muter "R03 parts saisies en liquidation arrondies vers le haut" t10_arrondis_pret.sql r03
muter "R04 parts de dette arrondies vers le bas a l'emprunt" t10_arrondis_pret.sql r04
muter "R05 montant du remboursement arrondi vers le bas" t10_arrondis_pret.sql r05
muter "R06 dette valorisee (v_compte) arrondie vers le bas" t10_arrondis_pret.sql r06
muter "R12 montant du retrait arrondi vers le haut" t10_arrondis_pret.sql r12
muter "R14 emprunter ne reserve plus les interets avant le nouveau pret" t10_arrondis_pret.sql r14
muter "R18 dette lue (v_position) arrondie vers le bas" t10_arrondis_pret.sql r18
muter "R19 plafond d'emprunt (v_compte) arrondi vers le haut" t10_arrondis_pret.sql r19
muter "R24 swap sans INSUFFICIENT_LIQUIDITY" t01_amm.sql r24

echo "$tuees mutations tuees sur $total"
[ "$tuees" = "$total" ]
