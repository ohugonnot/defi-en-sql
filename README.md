# defi-en-sql

[![ci](https://github.com/ohugonnot/defi-en-sql/actions/workflows/ci.yml/badge.svg)](https://github.com/ohugonnot/defi-en-sql/actions/workflows/ci.yml)

[English version](README.en.md)

Un échange à la Uniswap v2, un flash swap, un pool de prêt façon Aave v2 / Compound, la liquidation, l'attaque d'oracle et sa parade, le sandwich, rejoués au wei en SQL pur sur PostgreSQL 18. Les mécanismes suivent *Building Full Stack DeFi Applications* (Samuel Zhou, Packt, 2024).
Chaque mécanisme a son fichier de test, avec des assertions au wei près, et 76 mutations, des défauts choisis et injectés un par un, doivent chacune faire rougir son test.
Les pièges d'un contrat (arrondis, réentrée, prix manipulable) ont chacun leur test, et la base en ajoute un que la chaîne n'a pas : les accès concurrents, traités par verrous et niveaux d'isolation.

Les montants sont en `NUMERIC(78,0)` (le plus grand `uint256` tient dans 78 chiffres), les identifiants SQL sont en français.

## Ce que ça prouve

- Les arrondis de l'échange tiennent au wei : les 7 vecteurs d'Uniswap v2 passent, et sur 10 000 tirages à graine fixe (plus de 9 000 échanges exécutés), aucune sortie que l'invariant K = x·y refuse, réserves égales aux soldes ([`t01_amm`](tests/t01_amm.sql)).
- Un flash swap non remboursé est refusé au `COMMIT`, et rentrer dans le pool pendant le prêt lève `UniswapV2: LOCKED` ([`t02_flash_swap`](tests/t02_flash_swap.sql)).
- L'attaque d'oracle en une transaction passe avec le prix instantané et est refusée avec le prix moyen (TWAP d'Uniswap v2) ([`t05_oracle_attaque`](tests/t05_oracle_attaque.sql)).
- Une mise à jour perdue entre deux sessions est reproduite avec une version naïve de l'échange écrite dans le test, et les verrous de `echanger()` l'empêchent : le second échange attend, puis est recalculé au wei ([`t07_concurrence`](tests/t07_concurrence.sql) (a) et (b)).
- Un rôle ordinaire n'écrit dans aucune table : il appelle seulement les points d'entrée autorisés ([`t06_droits`](tests/t06_droits.sql)).

## Lancer

Docker suffit (compose v2). Rien n'est publié sur la machine hôte, et la base vit dans un `tmpfs`.

```
make test
```

Dernière ligne de la sortie :

```
OK : 11 fichiers, 319 assertions, 0 echec
```

`make mutation` applique 76 sabotages un par un sur une copie de `sql/` et exige que chacun fasse rougir le test prévu sur une assertion nommée (une ligne `ECHEC`), pas sur une erreur brute. `make down` arrête et supprime le conteneur.

## Les tests

| Fichier | Ce qu'il prouve |
|---|---|
| [`t01_amm`](tests/t01_amm.sql) | Échange à la Uniswap v2 : vecteurs de référence au wei, 10 000 tirages à graine fixe, parts LP. |
| [`t02_flash_swap`](tests/t02_flash_swap.sql) | Flash swap : remboursement contrôlé au `COMMIT`, pool fermé pendant le prêt. |
| [`t03_pret`](tests/t03_pret.sql) | Pool de prêt : courbe de taux, intérêts par parts, plafond d'emprunt, erreurs métier. |
| [`t04_liquidation`](tests/t04_liquidation.sql) | Liquidation : compte malsain, prime, close factor, gardes sur les parts saisies. |
| [`t05_oracle_attaque`](tests/t05_oracle_attaque.sql) | Manipulation de prix : acceptée au prix instantané, refusée au prix moyen. |
| [`t06_droits`](tests/t06_droits.sql) | Droits : un rôle ordinaire n'écrit nulle part et n'appelle que les points d'entrée. |
| [`t07_concurrence`](tests/t07_concurrence.sql) | Concurrence : mise à jour perdue, écritures croisées, ordre des verrous, interblocages. |
| [`t08_sandwich`](tests/t08_sandwich.sql) | Sandwich : ce que le minimum de sortie plafonne, et ce qu'il laisse passer. |
| [`t09_oracle_fraicheur`](tests/t09_oracle_fraicheur.sql) | Prix moyen : fraîcheur, fenêtre, coffre jamais observé, trou de maintenance. |
| [`t10_arrondis_pret`](tests/t10_arrondis_pret.sql) | Le sens d'arrondi de la dette, du remboursement, du retrait, du plafond et des parts saisies, sur des ratios non entiers. |
| [`t11_accumulation_interets`](tests/t11_accumulation_interets.sql) | `rembourser`, `retirer`, `deposer` et `liquider` réservent eux-mêmes les intérêts, vérifiés au wei. |

## Trois trouvailles

- **`/` et `sqrt()` arrondissent au plus proche dans PostgreSQL, là où Solidity et le `Math.sqrt` d'Uniswap v2 tronquent.** `trunc(2e18::numeric/3)` rend ...667, `div(2e18, 3)` rend ...666. `floor(sqrt(n²-1))` rend `n` pour `n = 1000000000000000007`. Toutes les divisions passent par `div_bas` et `div_haut`, et `make test` échoue si un `grep` trouve un `/` dans `sql/`. Les deux pièges sont des assertions de `t01`.
- **L'attaque d'oracle.** En une transaction, le prix instantané de BAR passe de 0,1 à 998,02 WETH et l'attaquant gagne 99,78 WETH : acceptée avec le prix instantané, refusée (`ACCOUNT_UNHEALTHY`) avec le prix moyen. La limite : si la manipulation tient un bloc, le prix moyen lu au bloc suivant vaut environ 167 fois le vrai prix ([`t05_oracle_attaque`](tests/t05_oracle_attaque.sql)).
- **La mise à jour perdue.** Avec une version naïve de l'échange écrite dans le test, Bob échange 2, puis Alice, qui avait lu avant lui, échange 1 : elle reçoit 1662497915624478906 au lieu de 891276464876788046 sur les vraies réserves, l'entrée de Bob disparaît des réserves, et le K des soldes réels tombe 12,2 % sous 5e37. Avec `echanger()`, le second échange attend le verrou puis est recalculé. En `REPEATABLE READ`, il reçoit l'erreur de sérialisation `40001`, que l'appelant doit rejouer ([`t07_concurrence`](tests/t07_concurrence.sql) (a), (b) et (c)).

## Pour aller plus loin

- [`docs/TESTS.md`](docs/TESTS.md) : ce que chaque fichier de test prouve, et des extraits de code.
- [`docs/CHIFFRES.md`](docs/CHIFFRES.md) : les valeurs mesurées, chacune une assertion au wei.
- [`docs/CONCEPTION.md`](docs/CONCEPTION.md) : règles de conception, écarts avec la chaîne, hors périmètre.
- [`docs/MUTATIONS.md`](docs/MUTATIONS.md) : les 76 sabotages, le test qui rougit pour chacun, et ce qu'ils ne couvrent pas.
- [`docs/LIMITES.md`](docs/LIMITES.md) : ce que le dépôt ne prouve pas, dont les interblocages restants.

## Liens

- L'article du blog qui accompagne le dépôt : https://www.web-developpeur.com/blog/defi-en-pur-sql-postgresql
- La fiche du livre : https://www.web-developpeur.com/bibliotheque/full-stack-defi-applications/

## Licence

MIT, Odilon Hugonnot, 2026.
