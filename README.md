# defi-en-sql

[English version](README.en.md)

Les mécanismes de *Building Full Stack DeFi Applications* (Samuel Zhou, Packt, 2024) rejoués en SQL pur sur PostgreSQL 18 : un échange à la Uniswap v2, un flash swap, un pool de prêt façon Aave v2 / Compound, la liquidation, l'attaque par manipulation de prix et sa parade, les droits, la concurrence, le sandwich. Chaque mécanisme a son fichier de test, et 16 mutations vérifient que les tests voient les défauts les plus coûteux (liste plus bas, avec ce qu'elles ne couvrent pas).

Le dépôt accompagne un article de blog. Les montants sont en `NUMERIC(78,0)` (le plus grand `uint256` tient dans 78 chiffres), les identifiants SQL sont en français.

## Lancer

Docker suffit (compose v2). Rien n'est publié sur la machine hôte, et la base vit dans un `tmpfs`.

```
make test
```

Dernière ligne de la sortie :

```
OK : 10 fichiers, 188 assertions, 0 echec
```

`make mutation` applique 18 sabotages un par un sur une copie de `sql/` et exige que chacun fasse rougir le test prévu. `make down` arrête et supprime le conteneur.

## Ce qui est testé

| Fichier | Ce qu'il prouve |
|---|---|
| `t01_amm` | Les 7 `swapTestCases` de `UniswapV2Pair.spec.ts` (commit `4dd59067c76dea4a0e8e4bfdda41877a6b16dedc`) au wei près, avec un wei de plus refusé par le contrôle de K. Les 4 `optimisticTestCases`. Sur 10 000 échanges tirés avec une graine fixe (plus de 9 000 exécutés, les autres tombent sur une sortie nulle ou une réserve vidée), `montant_sortie` ne rend jamais une sortie que K refuse, les réserves égalent les soldes de la caisse, la somme des soldes par jeton ne bouge pas. Parts LP, minimum de sortie, `INSUFFICIENT_LIQUIDITY`, plafond `uint112`. |
| `t02_flash_swap` | Les jetons sortent d'abord, le remboursement est contrôlé au `COMMIT`. Non remboursé : `COMMIT` refusé. Remboursé : accepté, K a grandi. Un wei de moins : refusé. Sortie nulle : refusée. Rentrer dans le pool pendant le prêt : `UniswapV2: LOCKED`. |
| `t03_pret` | Courbe de taux, intérêts réservés par un seul `UPDATE` sur `pret_pool` et 0 ligne modifiée dans `pret_position`, composition, 10 000 allers-retours dépôt/retrait dont aucun ne rapporte un wei, remboursement. |
| `t04_liquidation` | Compte sain non liquidable, malsain après la chute du prix, prime de liquidation, close factor. |
| `t05_oracle_attaque` | La même attaque en une transaction : acceptée avec le prix instantané, refusée (`ACCOUNT_UNHEALTHY`) avec le prix moyen. Et la limite du prix moyen. |
| `t06_droits` | `alice` ne peut pas écrire dans les tables (42501) mais appelle `echanger()`. La liste exacte de ce qu'elle peut exécuter. Les `SECURITY DEFINER` ont un `search_path` figé. Un superuser peut tout, même éteindre le trigger différé. |
| `t07_concurrence` | (a) Une vraie mise à jour perdue entre deux sessions `dblink` en `READ COMMITTED`, avec une fonction naïve définie dans le test. (b) `echanger()` : le second échange attend le verrou puis est recalculé, les deux sont appliqués. (c) `REPEATABLE READ` : erreur 40001. (d) Écriture croisée sur un compte : emprunter tout le WETH pendant que le même compte retire tout son COL. Entrelacement déterministe, sans `sleep`. |
| `t08_sandwich` | Victime sans minimum : elle reçoit moins. Front-run démesuré avec 1 % de minimum : la victime échoue. Front-run calibré au wei : la victime reçoit exactement son minimum et l'attaquant gagne quand même. Un wei de plus : la victime échoue. |
| `t09_oracle_fraicheur` | Le prix moyen refuse sans observation, avec une observation trop jeune (684 s, seuil à 696 s) ou sortie de la fenêtre (744 s). |
| `t10_arrondis_pret` | Chaque sens d'arrondi du prêt, sur des ratios qui ne sont pas des entiers (deux emprunteurs, intérêts, prix à un tiers) : parts de dette, dette lue, montant remboursé, retrait, plafond et dette valorisés, parts saisies en liquidation sur un coffre dont l'indice dépasse 1. Retirer tout son collatéral avec une dette est refusé. |

## Extraits

Sortie d'un échange, arrondie vers le bas (`sql/01_amm.sql:38-43`) :

```sql
CREATE FUNCTION montant_sortie(entree numeric, reserve_entree numeric, reserve_sortie numeric,
                               frais_pour_mille int DEFAULT 3) RETURNS numeric
  LANGUAGE sql IMMUTABLE AS $$
  SELECT div_bas(entree * (1000 - frais_pour_mille) * reserve_sortie,
                 reserve_entree * 1000 + entree * (1000 - frais_pour_mille))
$$;
```

L'échange, avec le minimum de sortie (`sql/01_amm.sql:98-112`) :

```sql
CREATE FUNCTION echanger(id_pool int, jeton_entree text, entree uint256, sortie_min uint256 DEFAULT 0)
  RETURNS numeric LANGUAGE plpgsql AS $$
DECLARE
  p pool := pool_verrouille(id_pool);
  achat_de_jeton1 boolean := jeton_entree = p.jeton0;
  sortie numeric;
BEGIN
  IF NOT achat_de_jeton1 AND jeton_entree <> p.jeton1 THEN RAISE EXCEPTION 'JETON_INCONNU'; END IF;
  sortie := CASE WHEN achat_de_jeton1
                 THEN montant_sortie(entree, p.reserve0, p.reserve1, p.frais_pour_mille)
                 ELSE montant_sortie(entree, p.reserve1, p.reserve0, p.frais_pour_mille) END;
  IF sortie < sortie_min THEN RAISE EXCEPTION 'INSUFFICIENT_OUTPUT_AMOUNT'; END IF;
  PERFORM deplacer(session_user::text, caisse(id_pool), jeton_entree, entree);
  PERFORM swap(id_pool, CASE WHEN achat_de_jeton1 THEN 0 ELSE sortie END,
                        CASE WHEN achat_de_jeton1 THEN sortie ELSE 0 END);
```

Le flash swap : le contrôle est différé au `COMMIT` (`sql/02_flash_swap.sql:24-38`) :

```sql
CREATE FUNCTION verifier_flash_swap() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE p pool := pool_verrouille(NEW.pool_id);
BEGIN
  -- Reserves moved since the loan: someone re-entered the pool (the "lock" of UniswapV2Pair).
  IF p.reserve0 <> NEW.reserve0_avant OR p.reserve1 <> NEW.reserve1_avant THEN
    RAISE EXCEPTION 'UniswapV2: LOCKED';
  END IF;
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
- **Arrondis** : sortie d'échange vers le bas, parts de dépôt et de liquidité frappées vers le bas, retrait vers le bas, parts de dette, dette et montant remboursé vers le haut, plafond d'emprunt vers le bas, parts saisies en liquidation vers le bas. Le pool ne paie jamais un wei de trop. Le sens des parts saisies est un choix du POC (Aave arrondit au plus proche), `t10_arrondis_pret` le teste.
- **Intérêts** : simples sur la période écoulée, composés à chaque réservation, année de 31 536 000 s. C'est le modèle de Compound : Aave v2 compose à la seconde. Un seul `UPDATE` sur `pret_pool` réserve les intérêts de tous les déposants et emprunteurs, grâce aux parts de dépôt et de dette.
- **Taux** : base 1 %, écart optimal 8 points, écart d'excès 51 points, coude à 80 % (la valeur que le livre relève sur le tableau de bord du pool ETH d'Aave v2), soit 9 % au coude et 60 % à 100 %.
- **LTV et seuil de liquidation** sont une seule valeur (`taux_garantie`), comme le `collateralRate` du livre. Aave les distingue.
- **Temps simulé** : `chaine` n'avance que par `avancer_bloc`. Pas de `now()`, pas de `sleep`, graine fixée.
- **`msg.sender` est `session_user`**. Les tests changent d'identité par `SET SESSION AUTHORIZATION`. Les points d'entrée sont `SECURITY DEFINER` avec un `search_path` figé, `EXECUTE` retiré à `PUBLIC` puis accordé à une liste.
- **Verrous** : chaque fonction publique prend `FOR UPDATE` sur les lignes qu'elle modifie, mais le danger vient aussi des lignes qu'elle lit : la santé d'un compte dépend de ses positions dans tous les coffres. `emprunter`, `retirer` et `liquider` (pour le débiteur) prennent donc d'abord la ligne du compte dans la table `compte` (elle est modifiée à chaque appel), puis les verrous de coffre dans l'ordre des clés. En `READ COMMITTED`, la seconde session attend puis relit l'état frais ; en `REPEATABLE READ` et `SERIALIZABLE`, elle reçoit `40001` et l'appelant rejoue. Un verrou advisory ne suffirait pas : il fait attendre sans rafraîchir l'instantané (`t07` (d) et (e), mutations M5 et M6).

## Mutations

`make mutation` casse le code à 18 endroits, un à la fois, sur une copie. Chacune doit faire rougir le test prévu ; d'autres tests peuvent rougir en plus.

| | Sabotage | Test qui rougit |
|---|---|---|
| M1 | `montant_sortie` arrondit au plus proche au lieu de `div_bas` | `t01_amm` (aussi `t07`, `t08`, `t10`) |
| M2 | le trigger différé du flash swap est supprimé | `t02_flash_swap` (aussi `t06`) |
| M3 | le prêt lit le prix instantané malgré `config.oracle = 'moyen'` | `t05_oracle_attaque` |
| M4 | `FOR UPDATE` retiré de `pool_verrouille` : le second échange est rejeté par K au lieu d'être recalculé | `t07_concurrence` |
| M5 | ligne de compte retirée d'`emprunter`, `retirer`, `liquider` | `t07_concurrence` (d) |
| M6 | ligne de compte remplacée par un verrou advisory : en `REPEATABLE READ`, le retrait lit l'état d'avant l'emprunt | `t07_concurrence` (e) |
| M7 | `emprunter` perd son `search_path` | `t06_droits` |
| R01 | `retirer` ne vérifie plus la santé du compte | `t10_arrondis_pret` (aussi `t07`) |
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

Les R sont les survivants d'une relecture indépendante : 22 mutants avaient été testés, 14 survivaient, les 11 ci-dessus sont maintenant tués. Restent non couverts : `FOR UPDATE` et `ORDER BY` de `verrouiller_prets`, le `FOR UPDATE` de `liquider`, et dans M5 seuls `emprunter` contre `retirer` sont exercés en parallèle.

La sortie de M1 :

```
M1 montant_sortie arrondit au plus proche (round de a / b) au lieu de div_bas
  ROUGE t01_amm.sql : ... ECHEC vecteur Uniswap 2 : montant_sortie au wei pres : attendu 453305446940074565, obtenu 453305446940074566
  ROUGE t07_concurrence.sql : ... ECHEC perte : Bob est servi au prix d'origine : attendu 2851015155847869602, obtenu 2851015155847869603
  ROUGE t08_sandwich.sql : ... ERROR:  UniswapV2: K
  ROUGE t10_arrondis_pret.sql : ... ERROR:  UniswapV2: K
  -> tuee par t01_amm.sql
```

Un wei d'écart sur le vecteur 2 suffit. Les autres fichiers rougissent parce que `echanger` contrôle K sur la sortie arrondie.

## Hors périmètre

Frais de protocole (`_mintFee`), factory et router multi-sauts (donc ni `deadline` ni `quote` du router), reserve factor, jetons à décimales différentes (18 partout), staking, créance irrécouvrable, défense du premier déposant dans le pool de prêt.

## Écarts avec la chaîne

- Une transaction Ethereum annulée paie son gaz et reste dans le bloc. Ici une transaction annulée ne laisse aucune trace dans l'état métier ; seules les séquences avancent.
- Uniswap contrôle K à la fin de l'appel `swap`. Ici le flash swap est contrôlé à la fin de la transaction (`COMMIT`), ce qui est plus large : on peut enchaîner plusieurs appels avant de rembourser.
- Un flash swap par pool et par transaction : un second emprunt sur le même pool, avant le remboursement, est rejeté par `UniswapV2: LOCKED` (un faux positif). `LOCKED` est surtout un message de diagnostic : K refuserait de toute façon une réentrée.
- Un superuser peut désactiver un trigger. `t06_droits` le montre. Sur la chaîne, le code déployé n'a pas de superuser.
- Le propriétaire des fonctions `SECURITY DEFINER` est un superuser, par simplicité de POC. `06_droits.sql` crée des rôles de démonstration dans le cluster.
- Les 1000 parts minimales vont sur `0x...dEaD`, comme le livre ; Uniswap les envoie à `address(0)`.
- Le dépôt de liquidité crédite les montants annoncés, pas `balance - reserve`, et sans `quote` de router : l'excédent d'un dépôt déséquilibré reste dans le pool au profit des autres porteurs.
- Les prix cumulés ne s'enroulent pas modulo 2^256 (un dépassement lève une erreur) et l'horodatage n'est pas tronqué à `uint32`.

## Limites

- 18 mutations seulement : elles montrent que les tests voient ces défauts, pas qu'ils les voient tous.
- Mesuré sur PostgreSQL 18.6. L'image est `postgres:18`, donc une version 18.x plus récente peut être tirée. Les pièges de `/` et de `sqrt()` sont eux-mêmes des assertions de `t01`.
- La CI GitHub Actions (`.github/workflows/ci.yml`) est écrite mais n'a jamais été exécutée : seul `make test` et `make mutation` en local sont mesurés.
- Le garde-fou contre `/` ne scanne que `sql/`, ligne à ligne, et pas les chaînes. `numeric(78,0)` arrondit sans erreur une valeur fractionnaire (`0.5` devient `1`), un chemin que ce garde-fou ne voit pas.
- Les verrous et la ligne de compte évitent la corruption (attente en `READ COMMITTED`, `40001` à rejouer en `REPEATABLE READ` et `SERIALIZABLE`), pas tous les interblocages : un `transferer` vers un coffre pendant un `emprunter` du même compte, ou `observer` puis `echanger` dans une transaction, peuvent s'interbloquer. PostgreSQL en détecte un et annule une des deux transactions. Aucun test de deadlock.
- Le livre ne publie pas `liquidate` : la liquidation reprend le close factor et la prime d'Aave v2, mais rembourse par parts (le `repayByShare` du livre) là où Aave prend un montant `debtToCover`, et lève `COLLATERAL_INSUFFISANT` là où Aave plafonne au collatéral disponible.

## Licence

MIT, Odilon Hugonnot, 2026.
