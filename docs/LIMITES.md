# Limites

[Retour au README](../README.md) · [English](en/LIMITS.md)

- 76 mutations seulement : elles montrent que les tests voient ces défauts, pas qu'ils les voient tous.
- Mesuré sur PostgreSQL 18.6. L'image est `postgres:18`, donc une version 18.x plus récente peut être tirée. Les pièges de `/` et de `sqrt()` sont eux-mêmes des assertions de `t01`.
- La CI GitHub Actions (`.github/workflows/ci.yml`) lance `make test` puis `make mutation` à chaque `push` et à chaque pull request.
- Le garde-fou contre `/` ne scanne que `sql/`, ligne à ligne, et pas les chaînes. `numeric(78,0)` arrondit sans erreur une valeur fractionnaire (`0.5` devient `1`), un chemin que ce garde-fou ne voit pas.
- Les verrous et la ligne de compte évitent la corruption (attente en `READ COMMITTED`, `40001` à rejouer en `REPEATABLE READ` et `SERIALIZABLE`), pas tous les interblocages. PostgreSQL en détecte un et annule la transaction dont l'attente dépasse `deadlock_timeout` en premier, donc celle qui attend depuis le plus longtemps : l'appelant rejoue (`40P01`) et l'état reste cohérent. Un cycle naît dès qu'une transaction de plusieurs appels reprend un verrou dans l'ordre inverse d'une autre :
  - un pool WETH en `FOR SHARE` (toute fonction de prêt, `observer`) puis en `FOR UPDATE` (`echanger`) ;
  - deux pools WETH : deux `echanger` par `id` décroissant contre un appel de prêt, ou `echanger` puis prêt sur deux pools différents ;
  - deux coffres dans l'ordre inverse des clés (l'ordre des clés ne vaut qu'à l'intérieur d'un appel) ;
  - la ligne d'un compte puis un pool : un liquidateur qui tient les pools et la ligne du débiteur puis veut `echanger`, contre un `rembourser`, un `deposer`, un `emprunter` ou un `retirer` du débiteur, ou contre un autre `liquider` du même débiteur. La ligne du liquidateur donne les mêmes formes de cycle sur son compte ;
  - de ligne de compte à ligne de compte : `deposer` puis `liquider` dans une transaction, contre un `liquider` inverse en autocommit (`40P01`), quand le compte de la transaction a le plus grand nom des deux, depuis que `liquider` prend aussi la ligne du liquidateur ;
  - entre deux appels simples en autocommit, deux appels qui déplacent des soldes en sens opposés : `transferer` de A vers B contre B vers A, ou `transferer` vers la caisse d'un pool contre tout appel qui paie ce jeton depuis cette caisse (`echanger`, `retirer_liquidite`, `swap`, `flash_swap`).
    - Pour la caisse, cela arrive pour un même compte dans deux sessions (l'une donne à la caisse pendant que l'autre échange), et à trois sessions quand le compte payé par la caisse transfère en même temps ce jeton vers le donateur (alice donne à la caisse, bob échange, bob transfère vers alice).
    - Toujours pour la caisse, des sessions de comptes tous différents ne se sont pas interbloquées.
    - Rejoué avec `pgbench` : la caisse paie vers le compte, `transferer` prend les deux soldes dans l'autre ordre.
- Un tiers sans mise peut cibler un compte par son nom : `liquider(victime, ..., 1)` finit en `ACCOUNT_HEALTHY` mais a pris la ligne du compte avant. Si la cible enchaîne ses appels en moins de `deadlock_timeout` (1 s), c'est le tiers qui est annulé ; un tiers qui tient déjà le `FOR SHARE` dans une transaction ouverte (`emprunter(jeton, 0)`) annule la cible même sans pause.
- Testés : l'ordre des verrous de `t07` (i) (mutation M34) et le cycle de `t07` (j), où la victime est en pratique le remboursement, parce qu'il attend le premier. Les autres cycles ne le sont pas.
- La liquidation reprend le close factor et la prime d'Aave v2, et rembourse par parts comme le [`liquidate` du dépôt du livre](https://github.com/PacktPublishing/Building-Full-Stack-DeFi-Application/blob/45d9e354916a032b40352cd4c2332025077b6f36/defi-apps/src/backend/contracts/AssetPool.sol#L767) là où Aave prend un montant `debtToCover`. Au-delà du close factor, elle lève `CLOSE_FACTOR` là où le livre plafonne les parts. Elle lève `COLLATERAL_INSUFFISANT` là où Aave plafonne au collatéral disponible.
