# defi-en-sql

[English version](README.en.md)

Les mécanismes de *Building Full Stack DeFi Applications* (Samuel Zhou, Packt, 2024) rejoués en SQL pur sur PostgreSQL 18 : un échange à la Uniswap v2, un flash swap, un pool de prêt façon Aave v2 / Compound, la liquidation, l'attaque par manipulation de prix et sa parade, les droits, la concurrence, le sandwich. Chaque mécanisme a son fichier de test, et 76 mutations vérifient que les tests voient les défauts les plus coûteux (liste plus bas, avec ce qu'elles ne couvrent pas).

Le dépôt accompagne un article de blog. Les montants sont en `NUMERIC(78,0)` (le plus grand `uint256` tient dans 78 chiffres), les identifiants SQL sont en français.

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

## Ce qui est testé

| Fichier | Ce qu'il prouve |
|---|---|
| `t01_amm` | Les 7 `swapTestCases` de `UniswapV2Pair.spec.ts` (commit `4dd59067c76dea4a0e8e4bfdda41877a6b16dedc`) au wei près, avec un wei de plus refusé par le contrôle de K. Les 4 `optimisticTestCases`. Sur 10 000 échanges tirés avec une graine fixe (plus de 9 000 exécutés, les autres tombent sur une sortie nulle ou une réserve vidée), `montant_sortie` ne rend jamais une sortie que K refuse, les réserves égalent les soldes de la caisse, la somme des soldes par jeton ne bouge pas. Parts LP (dépôt limité par T1 sur un ratio non entier : parts frappées vers le bas), minimum de sortie, `INSUFFICIENT_LIQUIDITY`, plafond `uint112`. |
| `t02_flash_swap` | Les jetons sortent d'abord, le remboursement est contrôlé au `COMMIT`. Non remboursé : `COMMIT` refusé. Remboursé : accepté, K a grandi. Un wei de moins : refusé. Sortie nulle : refusée. Rentrer dans le pool pendant le prêt (`echanger`, `swap`, dépôt ou retrait de liquidité, second flash swap) : `UniswapV2: LOCKED`. Le drapeau retombe après le `COMMIT` et le pool échange à nouveau, y compris quand le contrôle est lancé plus tôt par `SET CONSTRAINTS ... IMMEDIATE` sur un prêt prépayé (sans quoi le pool restait fermé pour de bon). |
| `t03_pret` | Courbe de taux, intérêts réservés par un seul `UPDATE` sur `pret_pool` et 0 ligne modifiée dans `pret_position`, composition, 10 000 allers-retours dépôt/retrait dont aucun ne rapporte un wei, remboursement. Coffre sans dépôt ou sans dette : erreur métier, pas de division par zéro. Un dépôt sans prix vaut 0 : retirable avec ou sans dette, la vue des comptes malsains ne lève pas, alors qu'emprunter un jeton sans prix reste refusé (`PAS_DE_PRIX`). Emprunter exactement le plafond passe, un wei de plus est refusé. `SOLDE_INSUFFISANT` et `PARTS_INSUFFISANTES`. `transferer` refuse la caisse de n'importe quel coffre (jouée par un non superuser). La somme des parts des positions égale les totaux du coffre. |
| `t04_liquidation` | Compte sain non liquidable, malsain après la chute du prix, prime de liquidation, close factor (aussi sur un coffre de dette où le débiteur n'a aucune position), `COLLATERAL_INSUFFISANT` (aussi sur un coffre de collatéral sans dépôt), zéro part refusé (`PARTS_NULLES`), collatéral à prix nul (`PAS_DE_PRIX`), 1 wei d'un collatéral sans prix déposé par un débiteur malsain (il reste liquidable), nom du débiteur à collation explicite accepté, totaux du coffre après liquidation. |
| `t05_oracle_attaque` | La même attaque en une transaction : acceptée avec le prix instantané, refusée (`ACCOUNT_UNHEALTHY`) avec le prix moyen. Et la limite du prix moyen. |
| `t06_droits` | `alice` ne peut pas écrire dans les tables (42501) mais appelle `echanger()`. La liste exacte de ce qu'elle peut exécuter. Les `SECURITY DEFINER` ont un `search_path` figé. Pour tout rôle ordinaire (ni superuser ni `pg_*`) : aucun privilège d'écriture, de trigger, de référence ni de maintenance sur aucune relation, par table ni par colonne, aucun usage des séquences, aucune création d'objet dans le schéma, aucune fonction interne exécutable. Un superuser peut tout, même éteindre le trigger différé. |
| `t07_concurrence` | (a) Une vraie mise à jour perdue entre deux sessions `dblink` en `READ COMMITTED`, avec une fonction naïve définie dans le test. (b) `echanger()` : le second échange attend le verrou puis est recalculé, les deux sont appliqués. (c) `REPEATABLE READ` : erreur 40001. (d) Écriture croisée sur un compte : emprunter tout le WETH pendant que le même compte retire tout son COL. (e) La même écriture croisée en `REPEATABLE READ` : `40001`. (f) L'horloge : un instantané `REPEATABLE READ` ou `SERIALIZABLE` antérieur à un bloc reçoit `40001` dans `echanger`, `deposer` et `observer`. (g) Le prix : un instantané antérieur à un échange sur le pool WETH reçoit `40001` dans `emprunter`, en `REPEATABLE READ` et en `SERIALIZABLE`. (h) Un liquidateur dont l'instantané précède un dépôt ou un remboursement du débiteur dans un troisième coffre reçoit `40001`, en `REPEATABLE READ` et `SERIALIZABLE`. (h bis) En `READ COMMITTED`, `liquider` attend la ligne du compte pendant que le débiteur dépose dans un autre coffre, puis juge le compte sain : `ACCOUNT_HEALTHY`, aucune part saisie. (i) L'ordre des verrous : un liquidateur qui tient un pool puis demande la ligne du compte ne s'interbloque pas avec le remboursement du débiteur. Entrelacement déterministe, sans `sleep`. (j) Le cycle miroir : un liquidateur qui tient les pools puis demande un pool en `FOR UPDATE`, contre le remboursement du débiteur, donne exactement une victime `40P01` (en pratique le remboursement, qui attend le premier) ; l'autre aboutit, son effet est vérifié et l'état reste entier. (k) Un liquidateur malsain renfloué par sa propre saisie ne peut pas être liquidé par une session dont l'instantané précède la saisie : `40001` en `REPEATABLE READ` et `SERIALIZABLE`, le compte renfloué ayant un nom plus petit puis plus grand que l'autre compte de chaque appel. |
| `t08_sandwich` | Victime sans minimum : elle reçoit moins. Front-run démesuré avec 1 % de minimum : la victime échoue. Front-run calibré au wei : la victime reçoit exactement son minimum et l'attaquant gagne quand même. Un wei de plus : la victime échoue. |
| `t09_oracle_fraicheur` | Un pool vide n'a pas de prix (`PAS_DE_PRIX`). Le prix moyen refuse sans observation, avec une observation trop jeune (684 s, seuil à 696 s) ou sortie de la fenêtre (744 s). Un coffre de collatéral listé mais jamais observé vaut 0 : le débiteur malsain reste liquidable sous le prix moyen. Seule l'absence de prix devient 0, une division par zéro est relancée. Un trou de 3 blocs dans une série établie (compte sain à deux collatéraux) reste une erreur `OBSERVATIONS_INSUFFISANTES` : `liquider` est refusé, pas de saisie sur un 0. Limite assumée : un compte malsain qui détient ce jeton troué n'est pas liquidable, et le redevient quand la maintenance a repris depuis 696 s. La cadence est épinglée (observé tous les 3 blocs : jamais d'erreur ; tous les 4 blocs : des erreurs). Une observation du pool vide n'est pas enregistrée : la dette n'est pas évaluée sur un prix dilué (`PAS_ENCORE_OBSERVE`). |
| `t10_arrondis_pret` | Chaque sens d'arrondi du prêt, sur des ratios qui ne sont pas des entiers (deux emprunteurs, intérêts, prix à un tiers) : parts de dette, dette lue, montant remboursé, retrait, plafond et dette valorisés, parts saisies en liquidation sur un coffre dont l'indice dépasse 1. Retirer tout son collatéral avec une dette est refusé. Close factor sur un nombre impair de parts de dette : le maximum arrondi vers le bas est accepté, une part de plus est refusée. |
| `t11_accumulation_interets` | `rembourser`, `retirer`, `deposer` et `liquider` réservent eux-mêmes les intérêts, sans appel préalable à `accumuler` : après un an, 100 parts de dette valent 109 et la dette totale tombe à 763 ; une heure plus tard, intérêts recalculés hors de la vue, au wei, avec le plafond exact `div(x + d - 1, d)`. Un pas de 5 s dont le reste est sous la moitié sépare le plafond de l'arrondi au plus proche. |

## Extraits

Sortie d'un échange, arrondie vers le bas (`sql/01_amm.sql:43-48`) :

```sql
CREATE FUNCTION montant_sortie(entree numeric, reserve_entree numeric, reserve_sortie numeric,
                               frais_pour_mille int DEFAULT 3) RETURNS numeric
  LANGUAGE sql IMMUTABLE AS $$
  SELECT div_bas(entree * (1000 - frais_pour_mille) * reserve_sortie,
                 reserve_entree * 1000 + entree * (1000 - frais_pour_mille))
$$;
```

L'échange, avec le minimum de sortie (`sql/01_amm.sql:103-120`) :

```sql
CREATE FUNCTION echanger(id_pool int, jeton_entree text, entree uint256, sortie_min uint256 DEFAULT 0)
  RETURNS numeric LANGUAGE plpgsql AS $$
DECLARE
  p pool := pool_verrouille(id_pool);
  achat_de_jeton1 boolean := jeton_entree = p.jeton0;
  sortie numeric;
BEGIN
  IF NOT achat_de_jeton1 AND jeton_entree <> p.jeton1 THEN RAISE EXCEPTION 'JETON_INCONNU'; END IF;
  IF p.reserve0 = 0 OR p.reserve1 = 0 THEN RAISE EXCEPTION 'INSUFFICIENT_LIQUIDITY'; END IF;
  sortie := CASE WHEN achat_de_jeton1
                 THEN montant_sortie(entree, p.reserve0, p.reserve1, p.frais_pour_mille)
                 ELSE montant_sortie(entree, p.reserve1, p.reserve0, p.frais_pour_mille) END;
  IF sortie < sortie_min THEN RAISE EXCEPTION 'INSUFFICIENT_OUTPUT_AMOUNT'; END IF;
  PERFORM deplacer(session_user::text, caisse(id_pool), jeton_entree, entree);
  PERFORM swap(id_pool, CASE WHEN achat_de_jeton1 THEN 0 ELSE sortie END,
                        CASE WHEN achat_de_jeton1 THEN sortie ELSE 0 END);
  RETURN sortie;
END $$;
```

Le flash swap : le contrôle est différé au `COMMIT` (`sql/02_flash_swap.sql:24-37`) :

```sql
CREATE FUNCTION verifier_flash_swap() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE p pool;
BEGIN
  -- The row is already locked by flash_swap in this transaction; pool_verrouille would refuse the flag.
  SELECT * INTO p FROM pool WHERE id = NEW.pool_id;
  UPDATE pool SET flash_en_cours = false WHERE id = NEW.pool_id;
  PERFORM valider_swap(p, NEW.sortie0, NEW.sortie1);
  RETURN NULL;
END $$;

CREATE CONSTRAINT TRIGGER flash_swap_rembourse
  AFTER INSERT ON flash_swap
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION verifier_flash_swap();
```

La courbe de taux (`sql/03_pret.sql:35-43`) :

```sql
-- Borrow rate at a given utilisation: a gentle line up to the kink, a steep one after it.
CREATE FUNCTION taux_emprunt(utilisation numeric, p pret_pool) RETURNS numeric
  LANGUAGE sql IMMUTABLE AS $$
  SELECT p.taux_base + CASE WHEN utilisation <= p.utilisation_optimale
    THEN div_bas(p.ecart_optimal * utilisation, p.utilisation_optimale)
    ELSE p.ecart_optimal + div_bas(p.ecart_exces * (utilisation - p.utilisation_optimale),
                                   1e18 - p.utilisation_optimale)
  END
$$;
```

Les comptes malsains (`sql/05_liquidation.sql:13-23`) :

```sql
CREATE VIEW v_compte AS
SELECT v.compte,
       SUM(div_bas(div_bas(v.depot * x.prix, 1e18) * v.taux_garantie, 1e18)) AS max_empruntable,
       SUM(div_haut(v.dette * x.prix, 1e18)) AS dette
FROM v_position v
CROSS JOIN LATERAL (SELECT prix(v.jeton) AS prix) x
WHERE v.depot > 0 OR v.dette > 0
GROUP BY v.compte;

CREATE VIEW v_compte_malsain AS
SELECT * FROM v_compte WHERE dette > max_empruntable;
```

L'attaque, en une transaction (`tests/t05_oracle_attaque.sql:20-29`) :

```sql
CREATE FUNCTION attaque() RETURNS void LANGUAGE plpgsql AS $$
DECLARE bar numeric;
BEGIN
  PERFORM flash_swap(1, 0, 99e18);
  bar := echanger(2, 'WETH', 99e18);
  PERFORM deposer('BAR', 0.2e18);
  PERFORM emprunter('WETH', 100e18);
  PERFORM echanger(2, 'BAR', bar - 0.2e18);
  PERFORM transferer(caisse(1), 'WETH', div_haut(99e18 * 1000, 998));
END $$;
```

La version naïve qui perd une mise à jour (`tests/t07_concurrence.sql:8-20`) :

```sql
-- (a) A real lost update. Bob and Alice both read pool 1, compute on what they read, then write reserves
-- computed from their own reading instead of the balances. Bob commits first, Alice overwrites him.
CREATE FUNCTION echanger_naif(id_pool int, entree numeric) RETURNS numeric
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE lu pool; sortie numeric;
BEGIN
  SELECT * INTO lu FROM pool WHERE id = id_pool;
  sortie := montant_sortie(entree, lu.reserve0, lu.reserve1);
  PERFORM deplacer(session_user::text, caisse(id_pool), lu.jeton0, entree);
  PERFORM deplacer(caisse(id_pool), session_user::text, lu.jeton1, sortie);
  UPDATE pool SET reserve0 = lu.reserve0 + entree, reserve1 = lu.reserve1 - sortie WHERE id = id_pool;
  RETURN sortie;
END $$;
```

## Chiffres mesurés

Chaque valeur de ce tableau est une assertion au wei du test indiqué.

| Quoi | Valeur | Test |
|---|---|---|
| 7 sorties Uniswap (entrée, réserves) | 1662497915624478906, 453305446940074565, 2851015155847869602, 831248957812239453, 906610893880149131, 987158034397061298, 996006981039903216 | `t01_amm` |
| Coût de rembourser 1 jeton emprunté (0,3 %) | 1003009027081243732 | `t01_amm`, `t02_flash_swap` |
| K du pool 5 / 10, Alice échange 1 puis Bob échange 2, l'un après l'autre | de 5e37 à 50062559425822493440000000000000000000, réserves (8e18, 6257819928227811680) | `t07_concurrence` (b) |
| Mise à jour perdue : Bob échange 2, Alice (qui avait lu avant) échange 1 | Bob reçoit 2851015155847869602, Alice 1662497915624478906 (contre 891276464876788046 sur les vraies réserves), `reserve0` reste à 6e18 au lieu de 8e18, K des soldes réels 43891895428221211936000000000000000000, soit 12,2 % sous 5e37 | `t07_concurrence` (a) |
| Prix instantané de BAR après l'achat avec 99 WETH (0,1 avant) | 998019999999999998222 (998,02 WETH) | `t05_oracle_attaque` |
| Prix moyen avant l'attaque, sur un prix constant de 0,1 | 99999999999999999 (0,1 moins un wei, troncature UQ112x112) | `t05_oracle_attaque` |
| Prix moyen lu au bloc suivant, manipulation tenue un bloc | 16731999999999999970 (environ 167 fois le vrai prix) | `t05_oracle_attaque` |
| Gain de l'attaquant, prix instantané, parti de 0 | 99777142654372389578 WETH (99,78), la caisse `pret:WETH` est vide | `t05_oracle_attaque` |
| Taux à 80 % d'utilisation | 9 % emprunteur, 7,2 % prêteur | `t03_pret` |
| Un an à 9 % sur 800 empruntés | 72 WETH d'intérêts, une part de dépôt vaut 1,072, retirer 100 parts rend 107,2 | `t03_pret` |
| Sandwich, victime sans minimum | reçoit 63956986828671189740 au lieu de 90661089388014913158 (environ 29,5 % de moins), l'attaquant gagne 30321924020611214716 T0 | `t08_sandwich` |
| Sandwich, front-run calibré, victime avec 1 % de minimum | la victime reçoit exactement son minimum, l'attaquant gagne 1060722693965933599 T0 (environ 1,06) | `t08_sandwich` |

Les profondeurs de pools du POC ne sont pas celles du livre : les gains de l'attaque ne sont pas comparables à ceux qu'il annonce (prix de BAR de 0,1 à 0,1058, gain supérieur à 100 ETH). Le mécanisme, lui, est le même.

Le sandwich : le minimum plafonne la perte (ici 1 %), il ne supprime pas le sandwich. Un front-run trop gros fait échouer la victime, un front-run calibré passe. Sur Ethereum, un sandwich part souvent en bundle atomique : si la victime échoue, le bundle n'est pas inclus et l'attaquant ne paie rien. « L'attaquant perd les frais » ne vaut que pour un attaquant naïf dans le mempool public. Le POC n'a pas de `deadline` (celui du router).

## Règles de conception

- **Jamais de `/` sur un montant.** Sur `numeric`, `/` arrondit au plus proche : `trunc(2e18::numeric/3)` rend ...667, `div(2e18, 3)` rend ...666. Toutes les divisions passent par `div_bas` et `div_haut`, et `make test` échoue si un `grep` trouve un `/` dans `sql/`.
- **`sqrt()` arrondit aussi** : `floor(sqrt(n²-1))` rend `n` pour `n = 1000000000000000007`. `racine_entiere` corrige l'estimation par deux boucles.
- **Arrondis** : sortie d'échange vers le bas, parts de dépôt et de liquidité frappées vers le bas, retrait vers le bas, parts de dette, dette et montant remboursé vers le haut, plafond d'emprunt vers le bas, parts saisies en liquidation vers le bas, maximum du close factor vers le bas. Le pool ne paie jamais un wei de trop. Le sens des parts saisies est un choix du POC (Aave arrondit au plus proche), `t10_arrondis_pret` le teste.
- **Intérêts** : simples sur la période écoulée, composés à chaque réservation, année de 31 536 000 s. C'est le modèle de Compound : Aave v2 compose à la seconde. Un seul `UPDATE` sur `pret_pool` réserve les intérêts de tous les déposants et emprunteurs, grâce aux parts de dépôt et de dette.
- **Taux** : base 1 %, écart optimal 8 points, écart d'excès 51 points, coude à 80 % (la valeur que le livre relève sur le tableau de bord du pool ETH d'Aave v2), soit 9 % au coude et 60 % à 100 %.
- **LTV et seuil de liquidation** sont une seule valeur (`taux_garantie`), comme le `collateralRate` du livre. Aave les distingue.
- **Temps simulé** : `chaine` n'avance que par `avancer_bloc`. Pas de `now()`, pas de `sleep`, graine fixée.
- **`msg.sender` est `session_user`**. Les tests changent d'identité par `SET SESSION AUTHORIZATION`. Les points d'entrée sont `SECURITY DEFINER` avec un `search_path` figé, `EXECUTE` retiré à `PUBLIC` puis accordé à une liste.
- **Verrous** : chaque fonction publique prend `FOR UPDATE` sur les lignes qu'elle modifie, mais le danger vient aussi des lignes qu'elle lit : la santé d'un compte dépend de ses positions dans tous les coffres. `emprunter`, `retirer`, `deposer`, `rembourser` et `liquider` (pour le débiteur) prennent donc la ligne du compte avant tout verrou de coffre (table `compte`, modifiée à chaque appel), puis les verrous de coffre dans l'ordre des clés. En `READ COMMITTED`, la seconde session attend puis relit l'état frais ; en `REPEATABLE READ` et `SERIALIZABLE`, elle reçoit `40001` et l'appelant rejoue. Un verrou advisory ne suffirait pas : il fait attendre sans rafraîchir l'instantané (`t07` (d) et (e), mutations M5 et M6). `deposer` et `rembourser` la prennent aussi : sans cela, un liquidateur dont l'instantané précède un renflouement dans un coffre qu'il ne verrouille pas jugerait le compte sur l'ancien état et saisirait du collatéral à un compte sain (`t07` (h), mutations M29 et M30). Ordre complet : les pools WETH de prix en `FOR SHARE` (par `id`), la ligne du compte, la ligne `chaine` en `FOR SHARE`, puis les coffres dans l'ordre des clés. `liquider` prend aussi la ligne du liquidateur, les deux dans l'ordre des noms : la saisie crédite son propre compte, et un liquidateur dont l'instantané précède cette saisie jugerait sinon un compte redevenu sain (`t07` (k), mutations M44, M47 et M49 : le compte renfloué est joué en première et en seconde position, chez lui comme chez le liquidateur périmé, pas l'ordre des deux lignes). Coût : deux liquidations d'un même liquidateur, sur des débiteurs et des coffres disjoints, se sérialisent sur sa ligne de compte (attente en `READ COMMITTED`, `40001` en `REPEATABLE READ` et `SERIALIZABLE`). `40001` et `40P01` sont des erreurs à rejouer : la transaction annulée n'a rien écrit, l'état reste cohérent.
- **Drapeau de flash swap** : `flash_swap` pose `pool.flash_en_cours` ; `swap`, `echanger`, `ajouter_liquidite`, `retirer_liquidite` et `flash_swap` lèvent `UniswapV2: LOCKED` tant qu'il est vrai, et le contrôle du `COMMIT` le baisse. Comparer les réserves ne suffisait pas : un attaquant les restaure pendant le prêt, puis tire des parts LP par `ajouter_liquidite` et `retirer_liquidite` (`t02`, mutations M8 et M9).
- **Horloge et prix** : la ligne `chaine` est lue dans l'instantané de l'appelant. `pool_verrouille`, `verrouiller_prets` et `observer` prennent donc `FOR SHARE` dessus, et `verrouiller_compte` le prend sur les pools WETH qui donnent les prix. Un instantané `REPEATABLE READ` ou `SERIALIZABLE` plus vieux qu'un bloc, ou qu'un échange sur ces pools, reçoit `40001` au lieu d'agir sur une heure ou un prix périmés (`t07` (f) et (g), mutations M10 à M13). Les pools de prix sont pris avant la ligne du compte, sinon une liquidation financée par un échange (qui tient le pool) s'interbloque avec le remboursement du débiteur (`t07` (i), mutation M34). Contrepartie : `avancer_bloc` attend la fin des transactions ouvertes qui tiennent ce verrou, sans borne tant que de nouvelles transactions le reprennent.
- **Collatéral sans prix** : un collatéral qu'on ne sait pas évaluer (`PAS_DE_PRIX`, ou `PAS_ENCORE_OBSERVE` pour un coffre listé dont le pool n'a pas encore d'observation assez ancienne pour couvrir la fenêtre) vaut 0 dans `v_compte` (`prix_garantie`). Il ne donne aucune capacité d'emprunt, reste retirable, et ne bloque ni `liquider` ni la vue `v_compte_malsain`. La dette reste évaluée strictement : emprunter un jeton sans prix lève `PAS_DE_PRIX`, et `liquider` ne saisit que du collatéral coté (`t03`, `t04`, `t09`, mutations M14, M55 à M57). Un trou de maintenance dans une série établie reste `OBSERVATIONS_INSUFFISANTES` : le prix reste une erreur et la liquidation est bloquée, comme pour toute erreur de prix, au lieu de saisir sur un 0 (`t09`, mutations M62 et M63). Un compte sans dette lit les prix pour retirer : en `SERIALIZABLE` il peut recevoir un `40001` à rejouer, comme un compte endetté. Un compte sans dette n'est jamais malsain (sa dette est nulle), mais `retirer` lève aussi pour lui si l'un de ses collatéraux est troué (règle exacte dans la puce suivante).
- **Maintenance de l'oracle** : l'invariant d'exploitation est que le pool de chaque coffre listé est observé au moins tous les 3 blocs (36 s), car la fenêtre ne tolère que 24 s d'écart sur son observation la plus ancienne (le rôle du script de maintenance du livre). Sans lui, une seule observation publique (`observer` est ouvert à tous) suffit à « établir » une série : un débiteur qui détient un jeton non maintenu peut alors bloquer sa propre liquidation et toute la vue `v_compte_malsain`, jusqu'à environ `fenetre - 24` s après la reprise de la maintenance. Tant que dure le trou, `emprunter` et `retirer` lèvent pour tout compte qui a une position dans le jeton troué, en dépôt ou en dette. Seul le retrait de tout le dépôt dans ce jeton passe, si le compte n'y a pas de dette et que le reste couvre sa dette. `deposer` et `rembourser` passent, et un compte sans position dans ce jeton n'est pas touché, sauf pour emprunter le jeton troué lui-même (`t09`). Le POC garde cette sémantique (une erreur d'oracle bloque, la valeur 0 est réservée à l'amorçage) et ne rallonge pas la fenêtre ; `t09` montre la limite et la reprise. `observer` n'enregistre rien tant qu'une réserve est nulle, comme le cumul d'Uniswap v2 : sinon une observation du pool vide dilue le prix moyen (`t09`, mutation M65).

## Mutations

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

## Hors périmètre

Frais de protocole (`_mintFee`), factory et router multi-sauts (donc ni `deadline` ni `quote` du router), reserve factor, jetons à décimales différentes (18 partout), staking, créance irrécouvrable, défense du premier déposant dans le pool de prêt. Les noms de compte (`session_user`) partagent l'espace des comptes système (`pool:N`, `pret:X`, l'adresse de burn) : un rôle nommé `pret:WETH` posséderait la caisse du coffre. Seul un administrateur crée des rôles, donc c'est hors périmètre.

## Écarts avec la chaîne

- Une transaction Ethereum annulée paie son gaz et reste dans le bloc. Ici une transaction annulée ne laisse aucune trace dans l'état métier ; seules les séquences avancent.
- Uniswap contrôle K à la fin de l'appel `swap`. Ici le flash swap est contrôlé à la fin de la transaction (`COMMIT`), ce qui est plus large : on peut enchaîner plusieurs appels avant de rembourser.
- Le pool est fermé pendant un flash swap : un second emprunt, un échange, un dépôt ou un retrait de liquidité avant le contrôle est rejeté par `UniswapV2: LOCKED` (un faux positif pour le second emprunt). Le drapeau tient jusqu'au contrôle du trigger, normalement au `COMMIT`. `SET CONSTRAINTS flash_swap_rembourse IMMEDIATE` lance ce contrôle plus tôt : sur un prêt non remboursé l'erreur arrive à cet instant (et revient au `COMMIT` si elle a été avalée) ; sur un prêt remboursé le drapeau tombe et le pool se rouvre dans la même transaction. Le mode `IMMEDIATE` dure jusqu'à la fin de la transaction : un second flash swap y est contrôlé aussitôt, donc il faut l'avoir prépayé ou être repassé en `DEFERRED`. Comme le contrôle d'un prêt prépayé part à l'intérieur de `flash_swap`, le drapeau est posé avant l'`INSERT` : posé après, le contrôle le baisserait puis la fonction le relèverait, et le pool resterait fermé pour de bon (`t02`, mutation M33). C'est un drapeau (`pool.flash_en_cours`), pas une comparaison de réserves, qu'un attaquant peut restaurer pendant le prêt (`t02`, mutations M8 et M9).
- Un rôle qui ouvre une transaction et ne fait rien peut geler un pool (`observer`, `echanger`), un coffre (`accumuler`) ou le compte d'un tiers (`liquider`), et `avancer_bloc` attend aussi les transactions ouvertes qui tiennent le verrou de l'horloge. Sur la chaîne une transaction est atomique et instantanée : personne ne tient un verrou entre deux blocs. Ni `lock_timeout` ni `idle_in_transaction_session_timeout` ne sont posés.
- `deposer` et `rembourser` prennent le verrou du compte (et le `FOR SHARE` des pools WETH) : une liquidation concurrente sur le même compte peut donc faire échouer son dépôt ou son remboursement en `40001` en `REPEATABLE READ` et `SERIALIZABLE`, à rejouer.
- Un superuser peut désactiver un trigger. `t06_droits` le montre. Sur la chaîne, le code déployé n'a pas de superuser.
- Le propriétaire des fonctions `SECURITY DEFINER` est un superuser, par simplicité de POC. `06_droits.sql` crée des rôles de démonstration dans le cluster.
- Les 1000 parts minimales vont sur `0x...dEaD`, comme le livre ; Uniswap les envoie à `address(0)`.
- Le dépôt de liquidité crédite les montants annoncés, pas `balance - reserve`, et sans `quote` de router : l'excédent d'un dépôt déséquilibré reste dans le pool au profit des autres porteurs.
- Les prix cumulés ne s'enroulent pas modulo 2^256 (un dépassement lève une erreur) et l'horodatage n'est pas tronqué à `uint32`.

## Limites

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
  - entre deux appels simples en autocommit, deux appels qui déplacent des soldes en sens opposés : `transferer` de A vers B contre B vers A, ou `transferer` vers la caisse d'un pool contre tout appel qui paie ce jeton depuis cette caisse (`echanger`, `retirer_liquidite`, `swap`, `flash_swap`). Pour la caisse, cela arrive pour un même compte dans deux sessions (l'une donne à la caisse pendant que l'autre échange), et à trois sessions quand le compte payé par la caisse transfère en même temps ce jeton vers le donateur (alice donne à la caisse, bob échange, bob transfère vers alice). Toujours pour la caisse, des sessions de comptes tous différents ne se sont pas interbloquées. Rejoué avec `pgbench` : la caisse paie vers le compte, `transferer` prend les deux soldes dans l'autre ordre.
- Un tiers sans mise peut cibler un compte par son nom : `liquider(victime, ..., 1)` finit en `ACCOUNT_HEALTHY` mais a pris la ligne du compte avant. Si la cible enchaîne ses appels en moins de `deadlock_timeout` (1 s), c'est le tiers qui est annulé ; un tiers qui tient déjà le `FOR SHARE` dans une transaction ouverte (`emprunter(jeton, 0)`) annule la cible même sans pause.
- Testés : l'ordre des verrous de `t07` (i) (mutation M34) et le cycle de `t07` (j), où la victime est en pratique le remboursement, parce qu'il attend le premier. Les autres cycles ne le sont pas.
- Le livre ne publie pas `liquidate` : la liquidation reprend le close factor et la prime d'Aave v2, mais rembourse par parts (le `repayByShare` du livre) là où Aave prend un montant `debtToCover`, et lève `COLLATERAL_INSUFFISANT` là où Aave plafonne au collatéral disponible.

## Licence

MIT, Odilon Hugonnot, 2026.
