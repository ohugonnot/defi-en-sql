# Conception

[Retour au README](../README.md) · [English](en/DESIGN.md)

Trois parties : les règles de conception, les écarts avec la chaîne, ce qui est hors périmètre.

## Règles de conception

- **Jamais de `/` sur un montant.**
  - Sur `numeric`, `/` arrondit au plus proche : `trunc(2e18::numeric/3)` rend ...667, `div(2e18, 3)` rend ...666.
  - Toutes les divisions passent par `div_bas` et `div_haut`, et `make test` échoue si un `grep` trouve un `/` dans `sql/`.
- **`sqrt()` arrondit aussi** : `floor(sqrt(n²-1))` rend `n` pour `n = 1000000000000000007`. `racine_entiere` corrige l'estimation par deux boucles.
- **Arrondis** :
  - sortie d'échange vers le bas ;
  - parts de dépôt et de liquidité frappées vers le bas ;
  - retrait vers le bas ;
  - parts de dette, dette et montant remboursé vers le haut ;
  - plafond d'emprunt vers le bas ;
  - parts saisies en liquidation vers le bas ;
  - maximum du close factor vers le bas.

  Le pool ne paie jamais un wei de trop. Le sens des parts saisies est un choix du POC (Aave arrondit au plus proche), `t10_arrondis_pret` le teste.
- **Intérêts** : simples sur la période écoulée, composés à chaque réservation, année de 31 536 000 s. C'est le modèle de Compound : Aave v2 compose à la seconde. Un seul `UPDATE` sur `pret_pool` réserve les intérêts de tous les déposants et emprunteurs, grâce aux parts de dépôt et de dette.
- **Taux** : base 1 %, écart optimal 8 points, écart d'excès 51 points, coude à 80 % (la valeur que le livre relève sur le tableau de bord du pool ETH d'Aave v2), soit 9 % au coude et 60 % à 100 %.
- **LTV et seuil de liquidation** sont une seule valeur (`taux_garantie`), comme le `collateralRate` du livre. Aave les distingue.
- **Temps simulé** : `chaine` n'avance que par `avancer_bloc`. Pas de `now()`, pas de `sleep`, graine fixée.
- **`msg.sender` est `session_user`**. Les tests changent d'identité par `SET SESSION AUTHORIZATION`. Les points d'entrée sont `SECURITY DEFINER` avec un `search_path` figé, `EXECUTE` retiré à `PUBLIC` puis accordé à une liste.
- **Verrous** : chaque fonction publique prend `FOR UPDATE` sur les lignes qu'elle modifie, mais le danger vient aussi des lignes qu'elle lit : la santé d'un compte dépend de ses positions dans tous les coffres.
  - `emprunter`, `retirer`, `deposer`, `rembourser` et `liquider` (pour le débiteur) prennent donc la ligne du compte avant tout verrou de coffre (table `compte`, modifiée à chaque appel), puis les verrous de coffre dans l'ordre des clés.
  - En `READ COMMITTED`, la seconde session attend puis relit l'état frais ; en `REPEATABLE READ` et `SERIALIZABLE`, elle reçoit `40001` et l'appelant rejoue.
  - Un verrou advisory ne suffirait pas : il fait attendre sans rafraîchir l'instantané (`t07` (d) et (e), mutations M5 et M6).
  - `deposer` et `rembourser` la prennent aussi : sans cela, un liquidateur dont l'instantané précède un renflouement dans un coffre qu'il ne verrouille pas jugerait le compte sur l'ancien état et saisirait du collatéral à un compte sain (`t07` (h), mutations M29 et M30).
  - Ordre complet : les pools WETH de prix en `FOR SHARE` (par `id`), la ligne du compte, la ligne `chaine` en `FOR SHARE`, puis les coffres dans l'ordre des clés.
  - `liquider` prend aussi la ligne du liquidateur, les deux dans l'ordre des noms : la saisie crédite son propre compte, et un liquidateur dont l'instantané précède cette saisie jugerait sinon un compte redevenu sain (`t07` (k), mutations M44, M47 et M49 : le compte renfloué est joué en première et en seconde position, chez lui comme chez le liquidateur périmé, pas l'ordre des deux lignes).
  - Coût : deux liquidations d'un même liquidateur, sur des débiteurs et des coffres disjoints, se sérialisent sur sa ligne de compte (attente en `READ COMMITTED`, `40001` en `REPEATABLE READ` et `SERIALIZABLE`).
  - `40001` et `40P01` sont des erreurs à rejouer : la transaction annulée n'a rien écrit, l'état reste cohérent.
- **Drapeau de flash swap** : `flash_swap` pose `pool.flash_en_cours` ; `swap`, `echanger`, `ajouter_liquidite`, `retirer_liquidite` et `flash_swap` lèvent `UniswapV2: LOCKED` tant qu'il est vrai, et le contrôle du `COMMIT` le baisse. Comparer les réserves ne suffisait pas : un attaquant les restaure pendant le prêt, puis tire des parts LP par `ajouter_liquidite` et `retirer_liquidite` (`t02`, mutations M8 et M9).
- **Horloge et prix** :
  - la ligne `chaine` est lue dans l'instantané de l'appelant. `pool_verrouille`, `verrouiller_prets` et `observer` prennent donc `FOR SHARE` dessus, et `verrouiller_compte` le prend sur les pools WETH qui donnent les prix ;
  - un instantané `REPEATABLE READ` ou `SERIALIZABLE` plus vieux qu'un bloc, ou qu'un échange sur ces pools, reçoit `40001` au lieu d'agir sur une heure ou un prix périmés (`t07` (f) et (g), mutations M10 à M13) ;
  - les pools de prix sont pris avant la ligne du compte, sinon une liquidation financée par un échange (qui tient le pool) s'interbloque avec le remboursement du débiteur (`t07` (i), mutation M34) ;
  - contrepartie : `avancer_bloc` attend la fin des transactions ouvertes qui tiennent ce verrou, sans borne tant que de nouvelles transactions le reprennent.
- **Collatéral sans prix** :
  - un collatéral qu'on ne sait pas évaluer (`PAS_DE_PRIX`, ou `PAS_ENCORE_OBSERVE` pour un coffre listé dont le pool n'a pas encore d'observation assez ancienne pour couvrir la fenêtre) vaut 0 dans `v_compte` (`prix_garantie`). Il ne donne aucune capacité d'emprunt, reste retirable, et ne bloque ni `liquider` ni la vue `v_compte_malsain` ;
  - la dette reste évaluée strictement : emprunter un jeton sans prix lève `PAS_DE_PRIX`, et `liquider` ne saisit que du collatéral coté (`t03`, `t04`, `t09`, mutations M14, M55 à M57) ;
  - un trou de maintenance dans une série établie reste `OBSERVATIONS_INSUFFISANTES` : le prix reste une erreur et la liquidation est bloquée, comme pour toute erreur de prix, au lieu de saisir sur un 0 (`t09`, mutations M62 et M63) ;
  - un compte sans dette lit les prix pour retirer : en `SERIALIZABLE` il peut recevoir un `40001` à rejouer, comme un compte endetté ;
  - un compte sans dette n'est jamais malsain (sa dette est nulle), mais `retirer` lève aussi pour lui si l'un de ses collatéraux est troué (règle exacte dans la puce suivante).
- **Maintenance de l'oracle** :
  - l'invariant d'exploitation est que le pool de chaque coffre listé est observé au moins tous les 3 blocs (36 s), car la fenêtre ne tolère que 24 s d'écart sur son observation la plus ancienne (le rôle du script de maintenance du livre) ;
  - sans lui, une seule observation publique (`observer` est ouvert à tous) suffit à « établir » une série : un débiteur qui détient un jeton non maintenu peut alors bloquer sa propre liquidation et toute la vue `v_compte_malsain`, jusqu'à environ `fenetre - 24` s après la reprise de la maintenance ;
  - tant que dure le trou, `emprunter` et `retirer` lèvent pour tout compte qui a une position dans le jeton troué, en dépôt ou en dette. Seul le retrait de tout le dépôt dans ce jeton passe, si le compte n'y a pas de dette et que le reste couvre sa dette ;
  - `deposer` et `rembourser` passent, et un compte sans position dans ce jeton n'est pas touché, sauf pour emprunter le jeton troué lui-même (`t09`) ;
  - le POC garde cette sémantique (une erreur d'oracle bloque, la valeur 0 est réservée à l'amorçage) et ne rallonge pas la fenêtre ; `t09` montre la limite et la reprise ;
  - `observer` n'enregistre rien tant qu'une réserve est nulle, comme le cumul d'Uniswap v2 : sinon une observation du pool vide dilue le prix moyen (`t09`, mutation M65).

## Écarts avec la chaîne

- Une transaction Ethereum annulée paie son gaz et reste dans le bloc. Ici une transaction annulée ne laisse aucune trace dans l'état métier ; seules les séquences avancent.
- Uniswap contrôle K à la fin de l'appel `swap`. Ici le flash swap est contrôlé à la fin de la transaction (`COMMIT`), ce qui est plus large : on peut enchaîner plusieurs appels avant de rembourser.
- Le pool est fermé pendant un flash swap : un second emprunt, un échange, un dépôt ou un retrait de liquidité avant le contrôle est rejeté par `UniswapV2: LOCKED` (un faux positif pour le second emprunt).
  - Le drapeau tient jusqu'au contrôle du trigger, normalement au `COMMIT`.
  - `SET CONSTRAINTS flash_swap_rembourse IMMEDIATE` lance ce contrôle plus tôt : sur un prêt non remboursé l'erreur arrive à cet instant (et revient au `COMMIT` si elle a été avalée) ; sur un prêt remboursé le drapeau tombe et le pool se rouvre dans la même transaction.
  - Le mode `IMMEDIATE` dure jusqu'à la fin de la transaction : un second flash swap y est contrôlé aussitôt, donc il faut l'avoir prépayé ou être repassé en `DEFERRED`.
  - Comme le contrôle d'un prêt prépayé part à l'intérieur de `flash_swap`, le drapeau est posé avant l'`INSERT` : posé après, le contrôle le baisserait puis la fonction le relèverait, et le pool resterait fermé pour de bon (`t02`, mutation M33).
  - C'est un drapeau (`pool.flash_en_cours`), pas une comparaison de réserves, qu'un attaquant peut restaurer pendant le prêt (`t02`, mutations M8 et M9).
- Un rôle qui ouvre une transaction et ne fait rien peut geler un pool (`observer`, `echanger`), un coffre (`accumuler`) ou le compte d'un tiers (`liquider`), et `avancer_bloc` attend aussi les transactions ouvertes qui tiennent le verrou de l'horloge. Sur la chaîne une transaction est atomique et instantanée : personne ne tient un verrou entre deux blocs. Ni `lock_timeout` ni `idle_in_transaction_session_timeout` ne sont posés.
- `deposer` et `rembourser` prennent le verrou du compte (et le `FOR SHARE` des pools WETH) : une liquidation concurrente sur le même compte peut donc faire échouer son dépôt ou son remboursement en `40001` en `REPEATABLE READ` et `SERIALIZABLE`, à rejouer.
- Un superuser peut désactiver un trigger. `t06_droits` le montre. Sur la chaîne, le code déployé n'a pas de superuser.
- Le propriétaire des fonctions `SECURITY DEFINER` est un superuser, par simplicité de POC. `06_droits.sql` crée des rôles de démonstration dans le cluster.
- Les 1000 parts minimales vont sur `0x...dEaD`, comme le livre ; Uniswap les envoie à `address(0)`.
- Le dépôt de liquidité crédite les montants annoncés, pas `balance - reserve`, et sans `quote` de router : l'excédent d'un dépôt déséquilibré reste dans le pool au profit des autres porteurs.
- Les prix cumulés ne s'enroulent pas modulo 2^256 (un dépassement lève une erreur) et l'horodatage n'est pas tronqué à `uint32`.

## Hors périmètre

- Frais de protocole (`_mintFee`).
- Factory et router multi-sauts (donc ni `deadline` ni `quote` du router).
- Reserve factor.
- Jetons à décimales différentes (18 partout).
- Staking.
- Créance irrécouvrable.
- Défense du premier déposant dans le pool de prêt.

Les noms de compte (`session_user`) partagent l'espace des comptes système (`pool:N`, `pret:X`, l'adresse de burn) : un rôle nommé `pret:WETH` posséderait la caisse du coffre. Seul un administrateur crée des rôles, donc c'est hors périmètre.
