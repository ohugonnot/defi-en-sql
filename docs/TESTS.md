# Ce qui est testé

[Retour au README](../README.md) · [English](en/TESTS.md)

Un fichier de test par mécanisme, dans [`tests/`](../tests/). Chaque section dit ce que le fichier prouve.

## `t01_amm`

- Les 7 `swapTestCases` de `UniswapV2Pair.spec.ts` (commit `4dd59067c76dea4a0e8e4bfdda41877a6b16dedc`) au wei près, avec un wei de plus refusé par le contrôle de K.
- Les 4 `optimisticTestCases`.
- Sur 10 000 échanges tirés avec une graine fixe (plus de 9 000 exécutés, les autres tombent sur une sortie nulle ou une réserve vidée) :
  - `montant_sortie` ne rend jamais une sortie que K refuse ;
  - les réserves égalent les soldes de la caisse ;
  - la somme des soldes par jeton ne bouge pas.
- Parts LP : dépôt limité par T1 sur un ratio non entier, parts frappées vers le bas.
- Minimum de sortie, `INSUFFICIENT_LIQUIDITY`, plafond `uint112`.

## `t02_flash_swap`

- Les jetons sortent d'abord, le remboursement est contrôlé au `COMMIT`.
- Non remboursé : `COMMIT` refusé.
- Remboursé : accepté, K a grandi.
- Un wei de moins : refusé.
- Sortie nulle : refusée.
- Rentrer dans le pool pendant le prêt (`echanger`, `swap`, dépôt ou retrait de liquidité, second flash swap) : `UniswapV2: LOCKED`.
- Le drapeau retombe après le `COMMIT` et le pool échange à nouveau, y compris quand le contrôle est lancé plus tôt par `SET CONSTRAINTS ... IMMEDIATE` sur un prêt prépayé (sans quoi le pool restait fermé pour de bon).

## `t03_pret`

- Courbe de taux.
- Intérêts réservés par un seul `UPDATE` sur `pret_pool`, et 0 ligne modifiée dans `pret_position`.
- Composition.
- 10 000 allers-retours dépôt/retrait dont aucun ne rapporte un wei.
- Remboursement.
- Coffre sans dépôt ou sans dette : erreur métier, pas de division par zéro.
- Un dépôt sans prix vaut 0 :
  - il est retirable, avec ou sans dette ;
  - la vue des comptes malsains ne lève pas ;
  - emprunter un jeton sans prix reste refusé (`PAS_DE_PRIX`).
- Emprunter exactement le plafond passe, un wei de plus est refusé.
- `SOLDE_INSUFFISANT` et `PARTS_INSUFFISANTES`.
- `transferer` refuse la caisse de n'importe quel coffre (jouée par un non superuser).
- La somme des parts des positions égale les totaux du coffre.

## `t04_liquidation`

- Compte sain : non liquidable. Il devient malsain après la chute du prix.
- Prime de liquidation.
- Close factor, aussi sur un coffre de dette où le débiteur n'a aucune position.
- `COLLATERAL_INSUFFISANT`, aussi sur un coffre de collatéral sans dépôt.
- Zéro part refusé (`PARTS_NULLES`).
- Collatéral à prix nul (`PAS_DE_PRIX`).
- 1 wei d'un collatéral sans prix déposé par un débiteur malsain : il reste liquidable.
- Nom du débiteur à collation explicite : accepté.
- Totaux du coffre après liquidation.

## `t05_oracle_attaque`

- La même attaque en une transaction : acceptée avec le prix instantané, refusée (`ACCOUNT_UNHEALTHY`) avec le prix moyen.
- La limite du prix moyen.

## `t06_droits`

- `alice` ne peut pas écrire dans les tables (42501) mais appelle `echanger()`.
- La liste exacte de ce qu'elle peut exécuter.
- Les `SECURITY DEFINER` ont un `search_path` figé.
- Pour tout rôle ordinaire (ni superuser ni `pg_*`) :
  - aucun privilège d'écriture, de trigger, de référence ni de maintenance sur aucune relation, par table ni par colonne ;
  - aucun usage des séquences ;
  - aucune création d'objet dans le schéma ;
  - aucune fonction interne exécutable.
- Un superuser peut tout, même éteindre le trigger différé.

## `t07_concurrence`

- (a) Une vraie mise à jour perdue entre deux sessions `dblink` en `READ COMMITTED`, avec une fonction naïve définie dans le test.
- (b) `echanger()` : le second échange attend le verrou puis est recalculé, les deux sont appliqués.
- (c) `REPEATABLE READ` : erreur 40001.
- (d) Écriture croisée sur un compte : emprunter tout le WETH pendant que le même compte retire tout son COL.
- (e) La même écriture croisée en `REPEATABLE READ` : `40001`.
- (f) L'horloge : un instantané `REPEATABLE READ` ou `SERIALIZABLE` antérieur à un bloc reçoit `40001` dans `echanger`, `deposer` et `observer`.
- (g) Le prix : un instantané antérieur à un échange sur le pool WETH reçoit `40001` dans `emprunter`, en `REPEATABLE READ` et en `SERIALIZABLE`.
- (h) Un liquidateur dont l'instantané précède un dépôt ou un remboursement du débiteur dans un troisième coffre reçoit `40001`, en `REPEATABLE READ` et `SERIALIZABLE`.
- (h bis) En `READ COMMITTED`, `liquider` attend la ligne du compte pendant que le débiteur dépose dans un autre coffre, puis juge le compte sain : `ACCOUNT_HEALTHY`, aucune part saisie.
- (i) L'ordre des verrous : un liquidateur qui tient un pool puis demande la ligne du compte ne s'interbloque pas avec le remboursement du débiteur. Entrelacement déterministe, sans `sleep`.
- (j) Le cycle miroir : un liquidateur qui tient les pools puis demande un pool en `FOR UPDATE`, contre le remboursement du débiteur, donne exactement une victime `40P01` (en pratique le remboursement, qui attend le premier). L'autre aboutit, son effet est vérifié et l'état reste entier.
- (k) Un liquidateur malsain renfloué par sa propre saisie ne peut pas être liquidé par une session dont l'instantané précède la saisie : `40001` en `REPEATABLE READ` et `SERIALIZABLE`, le compte renfloué ayant un nom plus petit puis plus grand que l'autre compte de chaque appel.

## `t08_sandwich`

- Victime sans minimum : elle reçoit moins.
- Front-run démesuré avec 1 % de minimum : la victime échoue.
- Front-run calibré au wei : la victime reçoit exactement son minimum et l'attaquant gagne quand même.
- Un wei de plus : la victime échoue.

## `t09_oracle_fraicheur`

- Un pool vide n'a pas de prix (`PAS_DE_PRIX`).
- Le prix moyen refuse sans observation, avec une observation trop jeune (684 s, seuil à 696 s) ou sortie de la fenêtre (744 s).
- Un coffre de collatéral listé mais jamais observé vaut 0 : le débiteur malsain reste liquidable sous le prix moyen.
- Seule l'absence de prix devient 0, une division par zéro est relancée.
- Un trou de 3 blocs dans une série établie (compte sain à deux collatéraux) reste une erreur `OBSERVATIONS_INSUFFISANTES` : `liquider` est refusé, pas de saisie sur un 0.
- Limite assumée : un compte malsain qui détient ce jeton troué n'est pas liquidable, et le redevient quand la maintenance a repris depuis 696 s.
- La cadence est épinglée : observé tous les 3 blocs, jamais d'erreur ; tous les 4 blocs, des erreurs.
- Une observation du pool vide n'est pas enregistrée : la dette n'est pas évaluée sur un prix dilué (`PAS_ENCORE_OBSERVE`).

## `t10_arrondis_pret`

- Chaque sens d'arrondi du prêt, sur des ratios qui ne sont pas des entiers (deux emprunteurs, intérêts, prix à un tiers) :
  - parts de dette ;
  - dette lue ;
  - montant remboursé ;
  - retrait ;
  - plafond et dette valorisés ;
  - parts saisies en liquidation sur un coffre dont l'indice dépasse 1.
- Retirer tout son collatéral avec une dette est refusé.
- Close factor sur un nombre impair de parts de dette : le maximum arrondi vers le bas est accepté, une part de plus est refusée.

## `t11_accumulation_interets`

- `rembourser`, `retirer`, `deposer` et `liquider` réservent eux-mêmes les intérêts, sans appel préalable à `accumuler`.
- Après un an, 100 parts de dette valent 109 et la dette totale tombe à 763.
- Une heure plus tard : intérêts recalculés hors de la vue, au wei, avec le plafond exact `div(x + d - 1, d)`.
- Un pas de 5 s dont le reste est sous la moitié sépare le plafond de l'arrondi au plus proche.

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

Les comptes malsains (`sql/05_liquidation.sql:13-24`) :

```sql
CREATE VIEW v_compte AS
SELECT v.compte,
       SUM(CASE WHEN v.depot > 0
                THEN div_bas(div_bas(v.depot * prix_garantie(v.jeton), 1e18) * v.taux_garantie, 1e18) ELSE 0 END) AS max_empruntable,
       SUM(CASE WHEN v.dette > 0
                THEN div_haut(v.dette * prix(v.jeton), 1e18) ELSE 0 END) AS dette
FROM v_position v
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

