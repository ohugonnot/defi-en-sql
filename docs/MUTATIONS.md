# Mutations

[Retour au README](../README.md) · [English](en/MUTATIONS.md)

La table liste 76 lignes, soit 65 codes M (M1 à M65) et 11 codes R (R01, R02, R03, R04, R05, R06, R12, R14, R18, R19, R24), d'où moins de codes M que de mutations. Dans `scripts/mutation.sh`, `total` est incrémenté à chaque appel de `muter`, un appel par sabotage, et aucun code ne regroupe plusieurs sabotages : M5 retire une ligne dans cinq fonctions, mais reste un seul sabotage. Les numéros R ont des trous (R07 à R11, R13, R15 à R17 et R20 à R23 ne sont pas dans le script).

`make mutation` casse le code à 76 endroits, un à la fois, sur une copie. Chacune doit faire rougir le test prévu sur une assertion nommée (une erreur brute ne compte pas) ; d'autres tests peuvent rougir en plus.

| | Sabotage | Test qui rougit |
|---|---|---|
| M1 | `montant_sortie` arrondit au plus proche au lieu de `div_bas` | `t01_amm` (aussi `t02`, `t04`, `t07`, `t08`, `t10`) |
| M2 | le trigger différé du flash swap est supprimé | `t02_flash_swap` (aussi `t06`) |
| M3 | le prêt lit le prix instantané malgré `config.oracle = 'moyen'` | `t05_oracle_attaque` |
| M4 | `FOR UPDATE` retiré de `pool_verrouille` : le second échange est rejeté par K au lieu d'être recalculé | `t07_concurrence` |
| M5 | ligne de compte retirée d'`emprunter`, `retirer`, `deposer`, `rembourser`, `liquider` | `t07_concurrence` (d) |
| M6 | ligne de compte remplacée par un verrou advisory : en `REPEATABLE READ`, le retrait lit l'état d'avant l'emprunt | `t07_concurrence` (e) |
| M7 | `emprunter` perd son `search_path` | `t06_droits` |
| M8 | `pool_verrouille` ne refuse plus un pool en flash swap : la réentrée par `ajouter_liquidite` ou `retirer_liquidite` passe | `t02_flash_swap` |
| M9 | le contrôle du `COMMIT` ne baisse plus le drapeau de prêt : le pool reste fermé | `t02_flash_swap` |
| M10 | `pool_verrouille` ne verrouille plus l'horloge : un échange agit à l'heure d'un instantané périmé | `t07_concurrence` (f) |
| M11 | `verrouiller_prets` ne verrouille plus l'horloge : intérêts facturés à l'heure périmée | `t07_concurrence` (f) |
| M12 | `observer` ne verrouille plus l'horloge | `t07_concurrence` (f) |
| M13 | le contrôle de santé ne verrouille plus les pools de prix : dette validée au prix périmé | `t07_concurrence` (g) |
| M14 | le plafond d'emprunt lit `prix()` au lieu de `prix_garantie()` : un collatéral sans prix bloque la santé des comptes | `t03_pret` (aussi `t04`, `t09`) |
| M15 | `est_sain` rend vrai même avec une dette | `t03_pret` (aussi `t04`, `t05`, `t07`, `t09`, `t10`, `t11`) |
| M16 | `echanger` sans garde sur un pool vide : division par zéro brute | `t01_amm` |
| M17 | `retirer_liquidite` sans garde sur un pool sans parts : division par zéro brute | `t01_amm` |
| M18 | `retirer` sans garde sur un coffre sans dépôt : division par zéro brute | `t03_pret` |
| M19 | `rembourser` sans garde sur un coffre sans dette : division par zéro brute | `t03_pret` |
| M20 | `deplacer` ne lève plus `SOLDE_INSUFFISANT` | `t01_amm` (aussi `t03`) |
| M21 | `retirer_liquidite` ne lève plus `PARTS_INSUFFISANTES` | `t01_amm` |
| M22 | `retirer` ne lève plus `PARTS_INSUFFISANTES` | `t03_pret` |
| M23 | `rembourser` ne lève plus `PARTS_INSUFFISANTES` | `t03_pret` |
| M24 | `liquider` ne lève plus `COLLATERAL_INSUFFISANT` | `t04_liquidation` |
| M25 | `rembourser` ne comptabilise plus les intérêts | `t11_accumulation_interets` |
| M26 | `retirer` ne comptabilise plus les intérêts | `t11_accumulation_interets` |
| M27 | `deposer` ne comptabilise plus les intérêts | `t11_accumulation_interets` (aussi `t07`) |
| M28 | un privilège `TRUNCATE` accordé à tous sur `observation` | `t06_droits` |
| M29 | `deposer` ne prend plus la ligne du compte : liquidation sur l'état d'avant un dépôt dans un troisième coffre | `t07_concurrence` (h) |
| M30 | `rembourser` ne prend plus la ligne du compte : liquidation sur l'état d'avant un remboursement dans un troisième coffre | `t07_concurrence` (h) |
| M31 | `transferer` accepte une caisse de coffre | `t03_pret` |
| M32 | `prix_instantane` sans garde sur un pool vide : division par zéro brute | `t09_oracle_fraicheur` |
| M33 | `flash_swap` pose le drapeau après l'`INSERT` : en mode `IMMEDIATE` le pool reste fermé pour de bon | `t02_flash_swap` |
| M34 | `verrouiller_compte` prend la ligne du compte avant les pools de prix : interblocage avec une liquidation | `t07_concurrence` (i) |
| M35 | `liquider` sans garde sur un coffre de collatéral sans dépôt : division par zéro brute | `t04_liquidation` |
| M36 | privilège `UPDATE` de colonne accordé à tous sur `part_lp` | `t06_droits` |
| M37 | `TRIGGER` et `REFERENCES` accordés à tous sur `solde` | `t06_droits` |
| M38 | `USAGE` et `UPDATE` des séquences accordés à tous | `t06_droits` |
| M39 | `transferer` ne refuse que la caisse du coffre WETH | `t03_pret` |
| M40 | privilège `UPDATE` accordé à `bob` sur `solde` (un rôle nommé, pas seulement `alice`) | `t06_droits` |
| M41 | `MAINTAIN` accordé à tous sur `pool` | `t06_droits` |
| M42 | `liquider` ne refuse plus zéro part avant le test de santé (`ACCOUNT_HEALTHY` à la place de `PARTS_NULLES`) | `t04_liquidation` |
| M43 | `liquider` sans garde sur un collatéral à prix nul : division par zéro brute | `t04_liquidation` |
| M44 | `liquider` ne prend plus la ligne de compte du liquidateur : liquidation d'un compte renfloué par sa propre saisie | `t07_concurrence` (k) |
| M45 | `EXECUTE` sur une fonction interne accordé à `bob` | `t06_droits` |
| M46 | `CREATE` sur le schéma accordé à `bob` | `t06_droits` |
| M47 | `liquider` ne prend plus la ligne de compte la plus grande par nom (le compte renfloué a le plus grand nom) | `t07_concurrence` (k) |
| M48 | `liquider` compare les noms sans collation fixée (nom à collation explicite : `42P22`) | `t04_liquidation` |
| M49 | `liquider` ne prend la ligne du liquidateur que si son nom est le plus petit des deux (seconde ligne remplacée par le débiteur) | `t07_concurrence` (k) |
| M50 | `liquider` juge la santé du débiteur avant de prendre les lignes de compte | `t07_concurrence` (h bis, cas `READ COMMITTED` de la liquidation) |
| M51 | `liquider` sans garde sur un débiteur sans position dans un coffre de dette qui porte la dette d'un tiers : saisie sans remboursement | `t04_liquidation` |
| M52 | `liquider` ne comptabilise plus les intérêts du coffre de dette | `t11_accumulation_interets` |
| M53 | `liquider` ne comptabilise plus les intérêts du coffre de collatéral | `t11_accumulation_interets` |
| M54 | `liquider` ne refuse que sur le total de parts de dette du coffre, pas sur l'absence de position du débiteur | `t04_liquidation` |
| M55 | `prix_garantie` ne couvre pas `PAS_ENCORE_OBSERVE` : un coffre listé mais pas encore observé bloque de nouveau | `t09_oracle_fraicheur` |
| M56 | la dette est valorisée par `prix_garantie` : un jeton sans prix s'emprunte gratuitement | `t03_pret` |
| M57 | `prix_garantie` avale toute erreur, pas seulement un prix absent | `t09_oracle_fraicheur` |
| M58 | intérêts arrondis au plus proche au lieu du plafond (`div_bas(x + d/2, d)`) | `t11_accumulation_interets` |
| M59 | maximum du close factor arrondi vers le haut | `t10_arrondis_pret` |
| M60 | parts frappées par `ajouter_liquidite` arrondies vers le haut sur la branche T1 | `t01_amm` |
| M61 | `v_compte_malsain` en `>=` : emprunter exactement le plafond devient malsain | `t03_pret` |
| M62 | `prix_garantie` convertit aussi `OBSERVATIONS_INSUFFISANTES` en 0 : un trou de maintenance rend liquidable un compte sain | `t09_oracle_fraicheur` |
| M63 | `prix_moyen` traite tout manque d'observations comme un amorçage : un trou de maintenance vaut 0 | `t09_oracle_fraicheur` |
| M64 | `v_compte_malsain` tolère un wei de dette au dessus du plafond | `t03_pret` |
| M65 | `observer` enregistre un pool vide : une observation à réserves nulles dilue le prix moyen | `t09_oracle_fraicheur` |
| R01 | `retirer` ne vérifie plus la santé du compte | `t10_arrondis_pret` (aussi `t03`, `t07`) |
| R02 | fraîcheur du prix moyen non contrôlée | `t09_oracle_fraicheur` |
| R03 | parts saisies en liquidation arrondies vers le haut | `t10_arrondis_pret` |
| R04 | parts de dette arrondies vers le bas à l'emprunt | `t10_arrondis_pret` |
| R05 | montant du remboursement arrondi vers le bas | `t10_arrondis_pret` |
| R06 | dette valorisée (`v_compte`) arrondie vers le bas | `t10_arrondis_pret` |
| R12 | montant du retrait arrondi vers le haut | `t10_arrondis_pret` |
| R14 | `emprunter` ne réserve plus les intérêts avant le nouveau prêt | `t10_arrondis_pret` |
| R18 | dette lue (`v_position`) arrondie vers le bas | `t10_arrondis_pret` |
| R19 | plafond d'emprunt (`v_compte`) arrondi vers le haut | `t10_arrondis_pret` |
| R24 | `swap` sans `INSUFFICIENT_LIQUIDITY` | `t01_amm` |

Les R sont les survivants d'une première relecture indépendante : 22 mutants avaient été testés, 14 survivaient, les 11 ci-dessus sont maintenant tués. M8 à M65 couvrent les correctifs des relectures suivantes. Restent non couverts : `FOR UPDATE` et `ORDER BY` de `verrouiller_prets`, le `FOR UPDATE` de `liquider`, l'ordre des deux lignes de compte de `liquider`.

La sortie de M1 :

```
M1 montant_sortie arrondit au plus proche (round de a / b) au lieu de div_bas
  ROUGE t01_amm.sql : ... ECHEC vecteur Uniswap 2 : montant_sortie au wei pres : attendu 453305446940074565, obtenu 453305446940074566
  ROUGE t02_flash_swap.sql : ... ERROR:  UniswapV2: K
  ROUGE t04_liquidation.sql : ... ERROR:  UniswapV2: K
  ROUGE t07_concurrence.sql : ... ECHEC perte : Bob est servi au prix d'origine : attendu 2851015155847869602, obtenu 2851015155847869603
  ROUGE t08_sandwich.sql : ... ERROR:  UniswapV2: K
  ROUGE t10_arrondis_pret.sql : ... ERROR:  UniswapV2: K
  ECHEC : 6 fichier(s) rouge(s)
  -> tuee par t01_amm.sql
```

Un wei d'écart sur le vecteur 2 suffit. Les autres fichiers rougissent parce que `echanger` contrôle K sur la sortie arrondie.
