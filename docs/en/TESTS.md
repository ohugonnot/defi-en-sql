# What is tested

[Back to the README](../../README.en.md) · [Français](../TESTS.md)

One test file per mechanism, in [`tests/`](../../tests/). Each section says what the file proves.

## `t01_amm`

- The 7 `swapTestCases` of `UniswapV2Pair.spec.ts` (commit `4dd59067c76dea4a0e8e4bfdda41877a6b16dedc`) to the wei, with one wei more refused by the K check.
- The 4 `optimisticTestCases`.
- Over 10,000 swaps drawn with a fixed seed (more than 9,000 executed, the rest hit a zero output or an emptied reserve):
  - `montant_sortie` never returns an output that K refuses;
  - reserves equal the vault balances;
  - the sum of balances per token does not move.
- LP shares: a deposit limited by T1 on a ratio that is not a whole number, shares minted rounded down.
- Minimum output, `INSUFFICIENT_LIQUIDITY`, `uint112` cap.

## `t02_flash_swap`

- Tokens leave first, repayment is checked at `COMMIT`.
- Not repaid: `COMMIT` refused.
- Repaid: accepted, K grew.
- One wei short: refused.
- Zero output: refused.
- Re-entering the pool during the loan (`echanger`, `swap`, adding or removing liquidity, a second flash swap): `UniswapV2: LOCKED`.
- The flag drops after the `COMMIT` and the pool trades again, also when the check is run earlier by `SET CONSTRAINTS ... IMMEDIATE` on a prepaid loan (without that, the pool stayed shut for good).

## `t03_pret`

- Rate curve.
- Interest booked by a single `UPDATE` on `pret_pool`, and 0 rows changed in `pret_position`.
- Compounding.
- 10,000 deposit/withdraw round trips and none gains a wei.
- Repayment.
- A vault with no deposit or no debt: a named error, no division by zero.
- A deposit with no price is worth 0:
  - it is withdrawable, with or without a debt;
  - the view of unhealthy accounts does not raise;
  - borrowing a token with no price stays refused (`PAS_DE_PRIX`).
- Borrowing exactly up to the cap is accepted, one wei more is refused.
- `SOLDE_INSUFFISANT` and `PARTS_INSUFFISANTES`.
- `transferer` refuses the cash box of any vault (played by a non superuser).
- The shares held by positions add up to the vault totals.

## `t04_liquidation`

- A healthy account cannot be liquidated. It becomes unhealthy after the price drop.
- Liquidation bonus.
- Close factor, also on a debt vault where the debtor has no position.
- `COLLATERAL_INSUFFISANT`, also on a collateral vault with no deposit.
- Zero shares refused (`PARTS_NULLES`).
- Collateral priced at 0 (`PAS_DE_PRIX`).
- 1 wei of an unpriced collateral deposited by an unhealthy debtor: it stays liquidatable.
- A debtor name with an explicit collation: accepted.
- Vault totals after a liquidation.

## `t05_oracle_attaque`

- The same attack in one transaction: accepted with the instantaneous price, refused (`ACCOUNT_UNHEALTHY`) with the average price.
- The limit of the average price.

## `t06_droits`

- `alice` cannot write to the tables (42501) but can call `echanger()`.
- The exact list of what she can execute.
- The `SECURITY DEFINER` functions have a pinned `search_path`.
- For every ordinary role (neither superuser nor `pg_*`):
  - no write, trigger, reference or maintenance privilege on any relation, per table or per column;
  - no use of the sequences;
  - no object creation in the schema;
  - no internal function executable.
- A superuser can do anything, even switch off the deferred trigger.

## `t07_concurrence`

- (a) A real lost update between two `dblink` sessions in `READ COMMITTED`, with a naive function defined in the test.
- (b) `echanger()`: the second swap waits for the lock then is recomputed, both apply.
- (c) `REPEATABLE READ`: error 40001.
- (d) Write skew on one account: borrowing all the WETH while the same account withdraws all its COL.
- (e) The same write skew in `REPEATABLE READ`: `40001`.
- (f) The clock: a `REPEATABLE READ` or `SERIALIZABLE` snapshot taken before a block gets `40001` in `echanger`, `deposer` and `observer`.
- (g) The price: a snapshot older than a swap on the WETH pool gets `40001` in `emprunter`, in `REPEATABLE READ` and in `SERIALIZABLE`.
- (h) A liquidator whose snapshot predates a deposit or repayment by the debtor in a third vault gets `40001`, in `REPEATABLE READ` and `SERIALIZABLE`.
- (h bis) In `READ COMMITTED`, `liquider` waits for the account row while the debtor deposits in another vault, then judges the account healthy: `ACCOUNT_HEALTHY`, no share seized.
- (i) Lock order: a liquidator that holds a pool then asks for the account row does not deadlock with the debtor's repayment. Deterministic interleaving, no `sleep`.
- (j) The mirror cycle: a liquidator that holds the pools then asks a pool `FOR UPDATE`, against the debtor's repayment, gives exactly one `40P01` victim (in practice the repayment, which waits first). The other goes through, its effect is checked and the state stays whole.
- (k) An unhealthy liquidator made healthy by his own seizure cannot be liquidated by a session whose snapshot predates the seizure: `40001` in `REPEATABLE READ` and `SERIALIZABLE`, with the account that became healthy sorting before, then after, the other account of each call.

## `t08_sandwich`

- Victim without a minimum: she receives less.
- Oversized front-run with a 1% minimum: the victim fails.
- Front-run calibrated to the wei: the victim receives exactly her minimum and the attacker still gains.
- One wei more: the victim fails.

## `t09_oracle_fraicheur`

- A pool with no liquidity has no price (`PAS_DE_PRIX`).
- The average price refuses without an observation, with an observation too young (684 s, threshold 696 s) or out of the window (744 s).
- A collateral vault that is listed but never observed is worth 0: the unhealthy debtor stays liquidatable under the average price.
- Only a missing price becomes 0, a division by zero is raised again.
- A 3-block gap in an established series (a sound account with two collaterals) stays an `OBSERVATIONS_INSUFFISANTES` error: `liquider` is refused, no seizure on a 0.
- Accepted limit: an unhealthy account holding that gapped token is not liquidatable, and becomes so again once maintenance has resumed for 696 s.
- The cadence is pinned: observed every 3 blocks, never an error; every 4 blocks, errors.
- An observation of the empty pool is not recorded: the debt is not valued at a diluted price (`PAS_ENCORE_OBSERVE`).

## `t10_arrondis_pret`

- Every rounding direction of the lending side, on ratios that are not whole numbers (two borrowers, interest, a price of one third):
  - debt shares;
  - debt read back;
  - amount repaid;
  - withdrawal;
  - valued cap and debt;
  - shares seized in a liquidation on a vault whose index is above 1.
- Withdrawing all collateral with a debt open is refused.
- Close factor on an odd number of debt shares: the maximum rounded down is accepted, one share more is refused.

## `t11_accumulation_interets`

- `rembourser`, `retirer`, `deposer` and `liquider` book the interest themselves, with no prior call to `accumuler`.
- After a year, 100 debt shares are worth 109 and the total debt falls to 763.
- An hour later: interest recomputed outside the view, to the wei, with the exact ceiling `div(x + d - 1, d)`.
- A 5 s step whose remainder is below half separates the ceiling from rounding to nearest.

## Excerpts

Swap output, rounded down (`sql/01_amm.sql:43-48`):

```sql
CREATE FUNCTION montant_sortie(entree numeric, reserve_entree numeric, reserve_sortie numeric,
                               frais_pour_mille int DEFAULT 3) RETURNS numeric
  LANGUAGE sql IMMUTABLE AS $$
  SELECT div_bas(entree * (1000 - frais_pour_mille) * reserve_sortie,
                 reserve_entree * 1000 + entree * (1000 - frais_pour_mille))
$$;
```

The swap, with the minimum output (`sql/01_amm.sql:103-120`):

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

The flash swap: the check is deferred to `COMMIT` (`sql/02_flash_swap.sql:24-37`):

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

The rate curve (`sql/03_pret.sql:35-43`):

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

Unhealthy accounts (`sql/05_liquidation.sql:13-24`):

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

The attack, in one transaction (`tests/t05_oracle_attaque.sql:20-29`):

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

The naive version that loses an update (`tests/t07_concurrence.sql:8-20`):

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

