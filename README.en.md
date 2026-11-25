# defi-en-sql

[Version française](README.md)

The mechanisms of *Building Full Stack DeFi Applications* (Samuel Zhou, Packt, 2024) replayed in plain SQL on PostgreSQL 18: a Uniswap v2 style swap, a flash swap, an Aave v2 / Compound style lending pool, liquidation, the price manipulation attack and its fix, permissions, concurrency, the sandwich. Each mechanism has its own test file, and 76 mutations check that the tests see the costliest faults (list below, with what they do not cover).

The repo backs a blog article. Amounts are `NUMERIC(78,0)` (the largest `uint256` fits in 78 digits). SQL identifiers are in French.

## Run

Docker is enough (compose v2). Nothing is published on the host, and the database lives in a `tmpfs`.

```
make test
```

Last line of the output:

```
OK : 11 fichiers, 319 assertions, 0 echec
```

`make mutation` applies 76 sabotages one by one to a copy of `sql/` and requires each one to turn the expected test red on a named assertion (an `ECHEC` line), not on a raw error. `make down` stops and removes the container.

## What is tested

| File | What it proves |
|---|---|
| `t01_amm` | The 7 `swapTestCases` of `UniswapV2Pair.spec.ts` (commit `4dd59067c76dea4a0e8e4bfdda41877a6b16dedc`) to the wei, with one wei more refused by the K check. The 4 `optimisticTestCases`. Over 10,000 swaps drawn with a fixed seed (more than 9,000 executed, the rest hit a zero output or an emptied reserve), `montant_sortie` never returns an output that K refuses, reserves equal the vault balances, the sum of balances per token does not move. LP shares (a deposit limited by T1 on a ratio that is not a whole number: shares minted rounded down), minimum output, `INSUFFICIENT_LIQUIDITY`, `uint112` cap. |
| `t02_flash_swap` | Tokens leave first, repayment is checked at `COMMIT`. Not repaid: `COMMIT` refused. Repaid: accepted, K grew. One wei short: refused. Zero output: refused. Re-entering the pool during the loan (`echanger`, `swap`, adding or removing liquidity, a second flash swap): `UniswapV2: LOCKED`. The flag drops after the `COMMIT` and the pool trades again, also when the check is run earlier by `SET CONSTRAINTS ... IMMEDIATE` on a prepaid loan (without that, the pool stayed shut for good). |
| `t03_pret` | Rate curve, interest booked by a single `UPDATE` on `pret_pool` and 0 rows changed in `pret_position`, compounding, 10,000 deposit/withdraw round trips and none gains a wei, repayment. A vault with no deposit or no debt: a named error, no division by zero. A deposit with no price is worth 0: withdrawable with or without a debt, the view of unhealthy accounts does not raise, while borrowing a token with no price stays refused (`PAS_DE_PRIX`). Borrowing exactly up to the cap is accepted, one wei more is refused. `SOLDE_INSUFFISANT` and `PARTS_INSUFFISANTES`. `transferer` refuses the cash box of any vault (played by a non superuser). The shares held by positions add up to the vault totals. |
| `t04_liquidation` | A healthy account cannot be liquidated, it becomes unhealthy after the price drop, liquidation bonus, close factor (also on a debt vault where the debtor has no position), `COLLATERAL_INSUFFISANT` (also on a collateral vault with no deposit), zero shares refused (`PARTS_NULLES`), collateral priced at 0 (`PAS_DE_PRIX`), 1 wei of an unpriced collateral deposited by an unhealthy debtor (it stays liquidatable), a debtor name with an explicit collation accepted, vault totals after a liquidation. |
| `t05_oracle_attaque` | The same attack in one transaction: accepted with the instantaneous price, refused (`ACCOUNT_UNHEALTHY`) with the average price. And the limit of the average price. |
| `t06_droits` | `alice` cannot write to the tables (42501) but can call `echanger()`. The exact list of what she can execute. The `SECURITY DEFINER` functions have a pinned `search_path`. For every ordinary role (neither superuser nor `pg_*`): no write, trigger, reference or maintenance privilege on any relation, per table or per column, no use of the sequences, no object creation in the schema, no internal function executable. A superuser can do anything, even switch off the deferred trigger. |
| `t07_concurrence` | (a) A real lost update between two `dblink` sessions in `READ COMMITTED`, with a naive function defined in the test. (b) `echanger()`: the second swap waits for the lock then is recomputed, both apply. (c) `REPEATABLE READ`: error 40001. (d) Write skew on one account: borrowing all the WETH while the same account withdraws all its COL. (e) The same write skew in `REPEATABLE READ`: `40001`. (f) The clock: a `REPEATABLE READ` or `SERIALIZABLE` snapshot taken before a block gets `40001` in `echanger`, `deposer` and `observer`. (g) The price: a snapshot older than a swap on the WETH pool gets `40001` in `emprunter`, in `REPEATABLE READ` and in `SERIALIZABLE`. (h) A liquidator whose snapshot predates a deposit or repayment by the debtor in a third vault gets `40001`, in `REPEATABLE READ` and `SERIALIZABLE`. (h bis) In `READ COMMITTED`, `liquider` waits for the account row while the debtor deposits in another vault, then judges the account healthy: `ACCOUNT_HEALTHY`, no share seized. (i) Lock order: a liquidator that holds a pool then asks for the account row does not deadlock with the debtor's repayment. Deterministic interleaving, no `sleep`. (j) The mirror cycle: a liquidator that holds the pools then asks a pool `FOR UPDATE`, against the debtor's repayment, gives exactly one `40P01` victim (in practice the repayment, which waits first); the other goes through, its effect is checked and the state stays whole. (k) An unhealthy liquidator made healthy by his own seizure cannot be liquidated by a session whose snapshot predates the seizure: `40001` in `REPEATABLE READ` and `SERIALIZABLE`, with the account that became healthy sorting before, then after, the other account of each call. |
| `t08_sandwich` | Victim without a minimum: she receives less. Oversized front-run with a 1% minimum: the victim fails. Front-run calibrated to the wei: the victim receives exactly her minimum and the attacker still gains. One wei more: the victim fails. |
| `t09_oracle_fraicheur` | A pool with no liquidity has no price (`PAS_DE_PRIX`). The average price refuses without an observation, with an observation too young (684 s, threshold 696 s) or out of the window (744 s). A collateral vault that is listed but never observed is worth 0: the unhealthy debtor stays liquidatable under the average price. Only a missing price becomes 0, a division by zero is raised again. A 3-block gap in an established series (a sound account with two collaterals) stays an `OBSERVATIONS_INSUFFISANTES` error: `liquider` is refused, no seizure on a 0. Accepted limit: an unhealthy account holding that gapped token is not liquidatable, and becomes so again once maintenance has resumed for 696 s. The cadence is pinned (observed every 3 blocks: never an error; every 4 blocks: errors). An observation of the empty pool is not recorded: the debt is not valued at a diluted price (`PAS_ENCORE_OBSERVE`). |
| `t10_arrondis_pret` | Every rounding direction of the lending side, on ratios that are not whole numbers (two borrowers, interest, a price of one third): debt shares, debt read back, amount repaid, withdrawal, valued cap and debt, shares seized in a liquidation on a vault whose index is above 1. Withdrawing all collateral with a debt open is refused. Close factor on an odd number of debt shares: the maximum rounded down is accepted, one share more is refused. |
| `t11_accumulation_interets` | `rembourser`, `retirer`, `deposer` and `liquider` book the interest themselves, with no prior call to `accumuler`: after a year, 100 debt shares are worth 109 and the total debt falls to 763; an hour later, interest recomputed outside the view, to the wei, with the exact ceiling `div(x + d - 1, d)`. A 5 s step whose remainder is below half separates the ceiling from rounding to nearest. |

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

Unhealthy accounts (`sql/05_liquidation.sql:13-23`):

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

## Measured numbers

Each value in this table is a to-the-wei assertion of the test shown.

| What | Value | Test |
|---|---|---|
| 7 Uniswap outputs (input, reserves) | 1662497915624478906, 453305446940074565, 2851015155847869602, 831248957812239453, 906610893880149131, 987158034397061298, 996006981039903216 | `t01_amm` |
| Cost of repaying 1 borrowed token (0.3%) | 1003009027081243732 | `t01_amm`, `t02_flash_swap` |
| K of the 5 / 10 pool, Alice swaps 1 then Bob swaps 2, one after the other | from 5e37 to 50062559425822493440000000000000000000, reserves (8e18, 6257819928227811680) | `t07_concurrence` (b) |
| Lost update: Bob swaps 2, Alice (who had read before) swaps 1 | Bob receives 2851015155847869602, Alice 1662497915624478906 (against 891276464876788046 on the real reserves), `reserve0` stays at 6e18 instead of 8e18, K of the real balances 43891895428221211936000000000000000000, 12.2% below 5e37 | `t07_concurrence` (a) |
| Instantaneous BAR price after buying with 99 WETH (0.1 before) | 998019999999999998222 (998.02 WETH) | `t05_oracle_attaque` |
| Average price before the attack, on a constant price of 0.1 | 99999999999999999 (0.1 minus one wei, UQ112x112 truncation) | `t05_oracle_attaque` |
| Average price read at the next block, manipulation held one block | 16731999999999999970 (about 167 times the true price) | `t05_oracle_attaque` |
| Attacker gain, instantaneous price, starting from 0 | 99777142654372389578 WETH (99.78), the `pret:WETH` vault is empty | `t05_oracle_attaque` |
| Rate at 80% utilisation | 9% borrower, 7.2% lender | `t03_pret` |
| One year at 9% on 800 borrowed | 72 WETH of interest, a deposit share is worth 1.072, withdrawing 100 shares returns 107.2 | `t03_pret` |
| Sandwich, victim without a minimum | receives 63956986828671189740 instead of 90661089388014913158 (about 29.5% less), the attacker gains 30321924020611214716 T0 | `t08_sandwich` |
| Sandwich, calibrated front-run, victim with a 1% minimum | the victim receives exactly her minimum, the attacker gains 1060722693965933599 T0 (about 1.06) | `t08_sandwich` |

The POC's pool depths are not the book's: the attack gains are not comparable to the ones it reports (BAR price from 0.1 to 0.1058, gain above 100 ETH). The mechanism is the same.

The sandwich: the minimum caps the loss (here 1%), it does not remove the sandwich. A front-run that is too big makes the victim fail, a calibrated one goes through. On Ethereum a sandwich often goes out as an atomic bundle: if the victim fails, the bundle is not included and the attacker pays nothing. "The attacker loses the fees" only holds for a naive attacker in the public mempool. The POC has no `deadline` (the router's).

## Design rules

- **Never `/` on an amount.** On `numeric`, `/` rounds to nearest: `trunc(2e18::numeric/3)` gives ...667, `div(2e18, 3)` gives ...666. Every division goes through `div_bas` and `div_haut`, and `make test` fails if a `grep` finds a `/` in `sql/`.
- **`sqrt()` rounds too**: `floor(sqrt(n²-1))` gives `n` for `n = 1000000000000000007`. `racine_entiere` corrects the guess with two loops.
- **Rounding**: swap output down, deposit and liquidity shares minted down, withdrawal down, debt shares, debt and amount repaid up, borrowing cap down, shares seized in a liquidation down, close factor maximum down. The pool never pays a wei too much. The direction for seized shares is a POC choice (Aave rounds to nearest), `t10_arrondis_pret` tests it.
- **Interest**: simple over the elapsed period, compounded at each booking, 31,536,000 s year. This is Compound's model: Aave v2 compounds every second. A single `UPDATE` on `pret_pool` books the interest of every depositor and borrower, thanks to deposit and debt shares.
- **Rates**: base 1%, optimal gap 8 points, excess gap 51 points, kink at 80% (the value the book reads on the dashboard of the Aave v2 ETH pool), so 9% at the kink and 60% at 100%.
- **LTV and liquidation threshold** are one value (`taux_garantie`), like the book's `collateralRate`. Aave keeps them apart.
- **Simulated time**: `chaine` only moves through `avancer_bloc`. No `now()`, no `sleep`, fixed seed.
- **`msg.sender` is `session_user`**. Tests switch identity with `SET SESSION AUTHORIZATION`. Entry points are `SECURITY DEFINER` with a pinned `search_path`, `EXECUTE` revoked from `PUBLIC` then granted from a list.
- **Locks**: each public function takes `FOR UPDATE` on the rows it changes, but the danger also comes from the rows it reads: an account's health depends on its positions in every vault. So `emprunter`, `retirer`, `deposer`, `rembourser` and `liquider` (for the debtor) take the account's row (`compte` table, changed on every call) before any vault lock, then the vault locks in key order. Full order: the WETH price pools `FOR SHARE` (by `id`), the account row, the `chaine` row `FOR SHARE`, then the vaults in key order. `liquider` also takes the liquidator's row, both in name order: the seizure credits his own account, and a liquidator whose snapshot predates it would otherwise judge an account that became healthy again (`t07` (k), mutations M44, M47 and M49: the account that became healthy is played in first and second position, in its own call and in the stale liquidator's, not the order of the two rows). Cost: two liquidations by the same liquidator, on disjoint debtors and vaults, serialize on his account row (a wait in `READ COMMITTED`, `40001` in `REPEATABLE READ` and `SERIALIZABLE`). `40001` and `40P01` are errors to retry: the aborted transaction wrote nothing, the state stays consistent. In `READ COMMITTED` the second session waits then re-reads fresh state; in `REPEATABLE READ` and `SERIALIZABLE` it gets `40001` and the caller retries. An advisory lock would not be enough: it makes the session wait without refreshing the snapshot (`t07` (d) and (e), mutations M5 and M6). `deposer` and `rembourser` take it too: without it, a liquidator whose snapshot predates a top-up in a vault it does not lock would judge the account on the old state and seize collateral from a healthy account (`t07` (h), mutations M29 and M30).
- **Flash swap flag**: `flash_swap` sets `pool.flash_en_cours`; `swap`, `echanger`, `ajouter_liquidite`, `retirer_liquidite` and `flash_swap` raise `UniswapV2: LOCKED` while it is true, and the `COMMIT` check clears it. Comparing reserves was not enough: an attacker restores them during the loan, then draws LP shares through `ajouter_liquidite` and `retirer_liquidite` (`t02`, mutations M8 and M9).
- **Clock and prices**: the `chaine` row is read in the caller's snapshot. So `pool_verrouille`, `verrouiller_prets` and `observer` take `FOR SHARE` on it, and `verrouiller_compte` takes it on the WETH pools that give the prices. A `REPEATABLE READ` or `SERIALIZABLE` snapshot older than a block, or than a swap on those pools, gets `40001` instead of acting on a stale hour or price (`t07` (f) and (g), mutations M10 to M13). The price pools are taken before the account row, otherwise a liquidation funded by a swap (which holds the pool) deadlocks with the debtor's repayment (`t07` (i), mutation M34). The counterpart: `avancer_bloc` waits for open transactions that hold this lock, with no bound while new transactions keep taking it.
- **Collateral with no price**: a collateral that cannot be valued (`PAS_DE_PRIX`, or `PAS_ENCORE_OBSERVE` for a listed vault whose pool has no observation old enough yet to cover the window) is worth 0 in `v_compte` (`prix_garantie`). It gives no borrowing power, stays withdrawable, and blocks neither `liquider` nor the `v_compte_malsain` view. Debt is still valued strictly: borrowing a token with no price raises `PAS_DE_PRIX`, and `liquider` only seizes priced collateral (`t03`, `t04`, `t09`, mutations M14, M55 to M57). A maintenance gap in an established series stays `OBSERVATIONS_INSUFFISANTES`: the price remains an error and liquidation is blocked, as for any price error, instead of seizing on a 0 (`t09`, mutations M62 and M63). An account with no debt reads prices to withdraw: under `SERIALIZABLE` it can get a `40001` to replay, like an indebted account. An account with no debt is never unhealthy (its debt is zero), but `retirer` raises for it too if one of its collaterals has a gap (exact rule in the next bullet).
- **Oracle maintenance**: the operating invariant is that the pool of every listed vault is observed at least every 3 blocks (36 s), because the window tolerates only 24 s of slack on its oldest observation (the job of the book's maintenance script). Without it, a single public observation (`observer` is open to everyone) is enough to "establish" a series: a debtor holding an unmaintained token can then block his own liquidation and the whole `v_compte_malsain` view, until about `fenetre - 24` s after maintenance resumes. While the gap lasts, `emprunter` and `retirer` raise for any account that has a position in the gapped token, as a deposit or as a debt. Only withdrawing the whole deposit in that token passes, if the account has no debt in it and the rest covers its debt. `deposer` and `rembourser` pass, and an account with no position in that token is not affected, except to borrow the gapped token itself (`t09`). The POC keeps these semantics (an oracle error blocks, the value 0 is reserved for the bootstrap) and does not lengthen the window; `t09` shows the limit and the recovery. `observer` records nothing while a reserve is 0, as the Uniswap v2 cumulative price does: otherwise an observation of the empty pool dilutes the average price (`t09`, mutation M65).

## Mutations

`make mutation` breaks the code in 76 places, one at a time, on a copy. Each must turn the expected test red on a named assertion (a raw error does not count); other tests may go red too.

| | Sabotage | Test that goes red |
|---|---|---|
| M1 | `montant_sortie` rounds to nearest instead of `div_bas` | `t01_amm` (also `t02`, `t04`, `t07`, `t08`, `t10`) |
| M2 | the flash swap deferred trigger is removed | `t02_flash_swap` (also `t06`) |
| M3 | lending reads the instantaneous price despite `config.oracle = 'moyen'` | `t05_oracle_attaque` |
| M4 | `FOR UPDATE` removed from `pool_verrouille`: the second swap is rejected by K instead of being recomputed | `t07_concurrence` |
| M5 | per-account row removed from `emprunter`, `retirer`, `deposer`, `rembourser`, `liquider` | `t07_concurrence` (d) |
| M6 | account row replaced by an advisory lock: in `REPEATABLE READ`, the withdraw reads the state from before the borrow | `t07_concurrence` (e) |
| M7 | `emprunter` loses its `search_path` | `t06_droits` |
| M8 | `pool_verrouille` no longer refuses a pool in a flash swap: re-entry through `ajouter_liquidite` or `retirer_liquidite` goes through | `t02_flash_swap` |
| M9 | the `COMMIT` check no longer clears the loan flag: the pool stays shut | `t02_flash_swap` |
| M10 | `pool_verrouille` no longer locks the clock: a swap acts on the hour of a stale snapshot | `t07_concurrence` (f) |
| M11 | `verrouiller_prets` no longer locks the clock: interest booked at the stale hour | `t07_concurrence` (f) |
| M12 | `observer` no longer locks the clock | `t07_concurrence` (f) |
| M13 | the health check no longer locks the price pools: a debt validated at the stale price | `t07_concurrence` (g) |
| M14 | the borrowing cap reads `prix()` instead of `prix_garantie()`: a collateral with no price blocks the health of accounts | `t03_pret` (also `t04`, `t09`) |
| M15 | `est_sain` returns true even with a debt | `t03_pret` (also `t04`, `t05`, `t07`, `t09`, `t10`, `t11`) |
| M16 | `echanger` without a guard on an empty pool: raw division by zero | `t01_amm` |
| M17 | `retirer_liquidite` without a guard on a pool with no shares: raw division by zero | `t01_amm` |
| M18 | `retirer` without a guard on a vault with no deposit: raw division by zero | `t03_pret` |
| M19 | `rembourser` without a guard on a vault with no debt: raw division by zero | `t03_pret` |
| M20 | `deplacer` no longer raises `SOLDE_INSUFFISANT` | `t01_amm` (also `t03`) |
| M21 | `retirer_liquidite` no longer raises `PARTS_INSUFFISANTES` | `t01_amm` |
| M22 | `retirer` no longer raises `PARTS_INSUFFISANTES` | `t03_pret` |
| M23 | `rembourser` no longer raises `PARTS_INSUFFISANTES` | `t03_pret` |
| M24 | `liquider` no longer raises `COLLATERAL_INSUFFISANT` | `t04_liquidation` |
| M25 | `rembourser` no longer books the interest | `t11_accumulation_interets` |
| M26 | `retirer` no longer books the interest | `t11_accumulation_interets` |
| M27 | `deposer` no longer books the interest | `t11_accumulation_interets` (also `t07`) |
| M28 | a `TRUNCATE` privilege granted to everyone on `observation` | `t06_droits` |
| M29 | `deposer` no longer takes the account row: liquidation on the state from before a deposit in a third vault | `t07_concurrence` (h) |
| M30 | `rembourser` no longer takes the account row: liquidation on the state from before a repayment in a third vault | `t07_concurrence` (h) |
| M31 | `transferer` accepts a vault cash box | `t03_pret` |
| M32 | `prix_instantane` without a guard on an empty pool: raw division by zero | `t09_oracle_fraicheur` |
| M33 | `flash_swap` raises the flag after the `INSERT`: in `IMMEDIATE` mode the pool stays shut for good | `t02_flash_swap` |
| M34 | `verrouiller_compte` takes the account row before the price pools: deadlock with a liquidation | `t07_concurrence` (i) |
| M35 | `liquider` without a guard on a collateral vault with no deposit: raw division by zero | `t04_liquidation` |
| M36 | column `UPDATE` privilege granted to everyone on `part_lp` | `t06_droits` |
| M37 | `TRIGGER` and `REFERENCES` granted to everyone on `solde` | `t06_droits` |
| M38 | `USAGE` and `UPDATE` of the sequences granted to everyone | `t06_droits` |
| M39 | `transferer` only refuses the WETH vault cash box | `t03_pret` |
| M40 | `UPDATE` granted to `bob` on `solde` (a named role, not only `alice`) | `t06_droits` |
| M41 | `MAINTAIN` granted to everyone on `pool` | `t06_droits` |
| M42 | `liquider` no longer refuses zero shares before the health check (`ACCOUNT_HEALTHY` instead of `PARTS_NULLES`) | `t04_liquidation` |
| M43 | `liquider` with no guard on a collateral priced at 0: raw division by zero | `t04_liquidation` |
| M44 | `liquider` no longer takes the liquidator's account row: liquidation of an account made healthy by its own seizure | `t07_concurrence` (k) |
| M45 | `EXECUTE` on an internal function granted to `bob` | `t06_droits` |
| M46 | `CREATE` on the schema granted to `bob` | `t06_droits` |
| M47 | `liquider` no longer takes the account row that sorts last by name (the made-healthy account has the last name) | `t07_concurrence` (k) |
| M48 | `liquider` compares names without a pinned collation (a name with an explicit collation: `42P22`) | `t04_liquidation` |
| M49 | `liquider` takes the liquidator's row only when his name is the smaller of the two (second row replaced by the debtor) | `t07_concurrence` (k) |
| M50 | `liquider` judges the debtor's health before taking the account rows | `t07_concurrence` (h bis, the `READ COMMITTED` case of the liquidation) |
| M51 | `liquider` with no guard on a debtor with no position in a debt vault that carries a third party's debt: a seizure without repayment | `t04_liquidation` |
| M52 | `liquider` no longer books the interest of the debt vault | `t11_accumulation_interets` |
| M53 | `liquider` no longer books the interest of the collateral vault | `t11_accumulation_interets` |
| M54 | `liquider` only refuses on the vault's total debt shares, not on the debtor having no position | `t04_liquidation` |
| M55 | `prix_garantie` does not cover `PAS_ENCORE_OBSERVE`: a vault that is listed but not yet observed blocks again | `t09_oracle_fraicheur` |
| M56 | debt is valued by `prix_garantie`: a token with no price can be borrowed for free | `t03_pret` |
| M57 | `prix_garantie` swallows every error, not only a missing price | `t09_oracle_fraicheur` |
| M58 | interest rounded to nearest instead of the ceiling (`div_bas(x + d/2, d)`) | `t11_accumulation_interets` |
| M59 | close factor maximum rounded up | `t10_arrondis_pret` |
| M60 | shares minted by `ajouter_liquidite` rounded up on the T1 branch | `t01_amm` |
| M61 | `v_compte_malsain` with `>=`: borrowing exactly up to the cap becomes unhealthy | `t03_pret` |
| M62 | `prix_garantie` also turns `OBSERVATIONS_INSUFFISANTES` into 0: a maintenance gap makes a sound account liquidatable | `t09_oracle_fraicheur` |
| M63 | `prix_moyen` treats any lack of observations as a bootstrap: a maintenance gap is worth 0 | `t09_oracle_fraicheur` |
| M64 | `v_compte_malsain` tolerates one wei of debt above the cap | `t03_pret` |
| M65 | `observer` records an empty pool: an observation with zero reserves dilutes the average price | `t09_oracle_fraicheur` |
| R01 | `retirer` no longer checks account health | `t10_arrondis_pret` (also `t03`, `t07`) |
| R02 | freshness of the average price not checked | `t09_oracle_fraicheur` |
| R03 | shares seized in a liquidation rounded up | `t10_arrondis_pret` |
| R04 | debt shares rounded down at borrow | `t10_arrondis_pret` |
| R05 | repayment amount rounded down | `t10_arrondis_pret` |
| R06 | valued debt (`v_compte`) rounded down | `t10_arrondis_pret` |
| R12 | withdrawal amount rounded up | `t10_arrondis_pret` |
| R14 | `emprunter` no longer books interest before the new loan | `t10_arrondis_pret` |
| R18 | debt read back (`v_position`) rounded down | `t10_arrondis_pret` |
| R19 | borrowing cap (`v_compte`) rounded up | `t10_arrondis_pret` |
| R24 | `swap` without `INSUFFICIENT_LIQUIDITY` | `t01_amm` |

The R rows are the survivors of a first independent review: 22 mutants were tried, 14 survived, the 11 above are now killed. M8 to M65 cover the fixes of the following reviews. Still uncovered: `FOR UPDATE` and `ORDER BY` in `verrouiller_prets`, the `FOR UPDATE` in `liquider`, the order of the two account rows in `liquider`.

The M1 output:

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

One wei off on vector 2 is enough. The other files go red because `echanger` checks K on the rounded output.

## Out of scope

Protocol fee (`_mintFee`), factory and multi-hop router (so no router `deadline` or `quote`), reserve factor, tokens with different decimals (18 everywhere), staking, bad debt, first-depositor defence in the lending pool. Account names (`session_user`) share their space with the system accounts (`pool:N`, `pret:X`, the burn address): a role named `pret:WETH` would own the vault's cash box. Only an administrator creates roles, so this is out of scope.

## Differences from the chain

- A cancelled Ethereum transaction pays its gas and stays in the block. Here a cancelled transaction leaves no trace in the business state; only sequences advance.
- Uniswap checks K at the end of the `swap` call. Here the flash swap is checked at the end of the transaction (`COMMIT`), which is wider: several calls can be chained before repaying.
- The pool is shut during a flash swap: a second loan, a swap, a deposit or a withdrawal of liquidity before the check is rejected with `UniswapV2: LOCKED` (a false positive for the second loan). The flag holds until the trigger check, normally at `COMMIT`. `SET CONSTRAINTS flash_swap_rembourse IMMEDIATE` runs that check earlier: on an unrepaid loan the error arrives at that moment (and comes back at `COMMIT` if it was swallowed); on a repaid loan the flag drops and the pool reopens within the same transaction. `IMMEDIATE` lasts until the end of the transaction: a second flash swap is checked at once, so it must be prepaid or the mode set back to `DEFERRED`. Since the check of a prepaid loan runs inside `flash_swap`, the flag is raised before the `INSERT`: raised after, the check would clear it and the function would raise it again, leaving the pool shut for good (`t02`, mutation M33). It is a flag (`pool.flash_en_cours`), not a comparison of reserves, which an attacker can restore during the loan (`t02`, mutations M8 and M9).
- A role that opens a transaction and does nothing can freeze a pool (`observer`, `echanger`), a vault (`accumuler`) or a third party's account (`liquider`), and `avancer_bloc` also waits for open transactions that hold the clock lock. On chain a transaction is atomic and instantaneous: nobody holds a lock between two blocks. Neither `lock_timeout` nor `idle_in_transaction_session_timeout` is set.
- `deposer` and `rembourser` take the account lock (and the `FOR SHARE` on the WETH pools): a concurrent liquidation of the same account can make its deposit or repayment fail with `40001` in `REPEATABLE READ` and `SERIALIZABLE`, to be retried.
- A superuser can disable a trigger. `t06_droits` shows it. On chain, deployed code has no superuser.
- The owner of the `SECURITY DEFINER` functions is a superuser, for POC simplicity. `06_droits.sql` creates demo roles in the cluster.
- The 1000 minimum shares go to `0x...dEaD`, like the book; Uniswap sends them to `address(0)`.
- A liquidity deposit credits the announced amounts, not `balance - reserve`, and without the router's `quote`: the excess of an unbalanced deposit stays in the pool for the other holders.
- Cumulative prices do not wrap modulo 2^256 (an overflow raises an error) and the timestamp is not truncated to `uint32`.

## Limits

- Only 76 mutations: they show the tests see those faults, not that they see all of them.
- Measured on PostgreSQL 18.6. The image is `postgres:18`, so a newer 18.x may be pulled. The `/` and `sqrt()` traps are themselves assertions in `t01`.
- The GitHub Actions CI (`.github/workflows/ci.yml`) runs `make test` then `make mutation` on every push and pull request.
- The guard against `/` only scans `sql/`, line by line, and not strings. `numeric(78,0)` silently rounds a fractional value (`0.5` becomes `1`), a path this guard does not see.
- Locks and the account row prevent corruption (a wait in `READ COMMITTED`, a `40001` to retry in `REPEATABLE READ` and `SERIALIZABLE`), not every deadlock. PostgreSQL detects one and aborts the transaction whose wait exceeds `deadlock_timeout` first, so the one that has waited longest: the caller retries (`40P01`) and the state stays consistent. A cycle appears as soon as a transaction of several calls takes a lock in the reverse order of another:
  - a WETH pool `FOR SHARE` (any lending function, `observer`) then `FOR UPDATE` (`echanger`);
  - two WETH pools: two `echanger` by decreasing `id` against one lending call, or `echanger` then a lending call on two different pools;
  - two vaults in reverse key order (key order only holds inside one call);
  - an account row then a pool: a liquidator that holds the pools and the debtor's row then wants `echanger`, against a `rembourser`, a `deposer`, an `emprunter` or a `retirer` by the debtor, or against another `liquider` of the same debtor. The liquidator's own row gives the same cycle shapes on his account;
  - from account row to account row: `deposer` then `liquider` in one transaction, against the opposite `liquider` in autocommit (`40P01`), when the account of the transaction has the larger name of the two, since `liquider` also takes the liquidator's row;
  - between two plain autocommit calls, two calls that move balances in opposite directions: `transferer` from A to B against B to A, or `transferer` to a pool's cash box against any call that pays that token from that cash box (`echanger`, `retirer_liquidite`, `swap`, `flash_swap`). For the cash box, this happens for the same account in two sessions (one gives to the cash box while the other swaps), and with three sessions when the account paid by the cash box transfers that token to the donor at the same time (alice gives to the cash box, bob swaps, bob transfers to alice). Still for the cash box, sessions of entirely different accounts did not deadlock. Replayed with `pgbench`: the cash box pays to the account, `transferer` takes the two balances in the other order.
- A third party with no stake can target an account by name: `liquider(victim, ..., 1)` ends in `ACCOUNT_HEALTHY` but took the account row first. If the target chains its calls in less than `deadlock_timeout` (1 s), the third party is the one aborted; a third party already holding the `FOR SHARE` in an open transaction (`emprunter(token, 0)`) aborts the target even with no pause.
- Tested: the lock order of `t07` (i) (mutation M34) and the cycle of `t07` (j), where the victim is in practice the repayment, because it waits first. The other cycles are not.
- Liquidation takes Aave v2's close factor and bonus, and repays by shares like the [`liquidate` in the book's repository](https://github.com/PacktPublishing/Building-Full-Stack-DeFi-Application/blob/45d9e354916a032b40352cd4c2332025077b6f36/defi-apps/src/backend/contracts/AssetPool.sol#L767) where Aave takes an amount `debtToCover`. Beyond the close factor, it raises `CLOSE_FACTOR` where the book caps the shares. It raises `COLLATERAL_INSUFFISANT` where Aave caps at the available collateral.

## Licence

MIT, Odilon Hugonnot, 2026.
