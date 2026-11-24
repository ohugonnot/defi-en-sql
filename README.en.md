# defi-en-sql

[Version française](README.md)

The mechanisms of *Building Full Stack DeFi Applications* (Samuel Zhou, Packt, 2024) replayed in plain SQL on PostgreSQL 18: a Uniswap v2 style swap, a flash swap, an Aave v2 / Compound style lending pool, liquidation, the price manipulation attack and its fix, permissions, concurrency, the sandwich. Each mechanism has its own test file, and 16 mutations check that the tests see the costliest faults (list below, with what they do not cover).

The repo backs a blog article. Amounts are `NUMERIC(78,0)` (the largest `uint256` fits in 78 digits). SQL identifiers are in French.

## Run

Docker is enough (compose v2). Nothing is published on the host, and the database lives in a `tmpfs`.

```
make test
```

Last line of the output:

```
OK : 10 fichiers, 188 assertions, 0 echec
```

`make mutation` applies 18 sabotages one by one to a copy of `sql/` and requires each one to turn the expected test red. `make down` stops and removes the container.

## What is tested

| File | What it proves |
|---|---|
| `t01_amm` | The 7 `swapTestCases` of `UniswapV2Pair.spec.ts` (commit `4dd59067c76dea4a0e8e4bfdda41877a6b16dedc`) to the wei, with one wei more refused by the K check. The 4 `optimisticTestCases`. Over 10,000 swaps drawn with a fixed seed (more than 9,000 executed, the rest hit a zero output or an emptied reserve), `montant_sortie` never returns an output that K refuses, reserves equal the vault balances, the sum of balances per token does not move. LP shares, minimum output, `INSUFFICIENT_LIQUIDITY`, `uint112` cap. |
| `t02_flash_swap` | Tokens leave first, repayment is checked at `COMMIT`. Not repaid: `COMMIT` refused. Repaid: accepted, K grew. One wei short: refused. Zero output: refused. Re-entering the pool during the loan: `UniswapV2: LOCKED`. |
| `t03_pret` | Rate curve, interest booked by a single `UPDATE` on `pret_pool` and 0 rows changed in `pret_position`, compounding, 10,000 deposit/withdraw round trips and none gains a wei, repayment. |
| `t04_liquidation` | A healthy account cannot be liquidated, it becomes unhealthy after the price drop, liquidation bonus, close factor. |
| `t05_oracle_attaque` | The same attack in one transaction: accepted with the instantaneous price, refused (`ACCOUNT_UNHEALTHY`) with the average price. And the limit of the average price. |
| `t06_droits` | `alice` cannot write to the tables (42501) but can call `echanger()`. The exact list of what she can execute. The `SECURITY DEFINER` functions have a pinned `search_path`. A superuser can do anything, even switch off the deferred trigger. |
| `t07_concurrence` | (a) A real lost update between two `dblink` sessions in `READ COMMITTED`, with a naive function defined in the test. (b) `echanger()`: the second swap waits for the lock then is recomputed, both apply. (c) `REPEATABLE READ`: error 40001. (d) Write skew on one account: borrowing all the WETH while the same account withdraws all its COL. Deterministic interleaving, no `sleep`. |
| `t08_sandwich` | Victim without a minimum: she receives less. Oversized front-run with a 1% minimum: the victim fails. Front-run calibrated to the wei: the victim receives exactly her minimum and the attacker still gains. One wei more: the victim fails. |
| `t09_oracle_fraicheur` | The average price refuses without an observation, with an observation too young (684 s, threshold 696 s) or out of the window (744 s). |
| `t10_arrondis_pret` | Every rounding direction of the lending side, on ratios that are not whole numbers (two borrowers, interest, a price of one third): debt shares, debt read back, amount repaid, withdrawal, valued cap and debt, shares seized in a liquidation on a vault whose index is above 1. Withdrawing all collateral with a debt open is refused. |

## Excerpts

Swap output, rounded down (`sql/01_amm.sql:38-43`):

```sql
CREATE FUNCTION montant_sortie(entree numeric, reserve_entree numeric, reserve_sortie numeric,
                               frais_pour_mille int DEFAULT 3) RETURNS numeric
  LANGUAGE sql IMMUTABLE AS $$
  SELECT div_bas(entree * (1000 - frais_pour_mille) * reserve_sortie,
                 reserve_entree * 1000 + entree * (1000 - frais_pour_mille))
$$;
```

The swap, with the minimum output (`sql/01_amm.sql:98-112`):

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

The flash swap: the check is deferred to `COMMIT` (`sql/02_flash_swap.sql:24-38`):

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
- **Rounding**: swap output down, deposit and liquidity shares minted down, withdrawal down, debt shares, debt and amount repaid up, borrowing cap down, shares seized in a liquidation down. The pool never pays a wei too much. The direction for seized shares is a POC choice (Aave rounds to nearest), `t10_arrondis_pret` tests it.
- **Interest**: simple over the elapsed period, compounded at each booking, 31,536,000 s year. This is Compound's model: Aave v2 compounds every second. A single `UPDATE` on `pret_pool` books the interest of every depositor and borrower, thanks to deposit and debt shares.
- **Rates**: base 1%, optimal gap 8 points, excess gap 51 points, kink at 80% (the value the book reads on the dashboard of the Aave v2 ETH pool), so 9% at the kink and 60% at 100%.
- **LTV and liquidation threshold** are one value (`taux_garantie`), like the book's `collateralRate`. Aave keeps them apart.
- **Simulated time**: `chaine` only moves through `avancer_bloc`. No `now()`, no `sleep`, fixed seed.
- **`msg.sender` is `session_user`**. Tests switch identity with `SET SESSION AUTHORIZATION`. Entry points are `SECURITY DEFINER` with a pinned `search_path`, `EXECUTE` revoked from `PUBLIC` then granted from a list.
- **Locks**: each public function takes `FOR UPDATE` on the rows it changes, but the danger also comes from the rows it reads: an account's health depends on its positions in every vault. So `emprunter`, `retirer` and `liquider` (for the debtor) first take the account's row in the `compte` table (changed on every call), then the vault locks in key order. In `READ COMMITTED` the second session waits then re-reads fresh state; in `REPEATABLE READ` and `SERIALIZABLE` it gets `40001` and the caller retries. An advisory lock would not be enough: it makes the session wait without refreshing the snapshot (`t07` (d) and (e), mutations M5 and M6).

## Mutations

`make mutation` breaks the code in 18 places, one at a time, on a copy. Each must turn the expected test red; other tests may go red too.

| | Sabotage | Test that goes red |
|---|---|---|
| M1 | `montant_sortie` rounds to nearest instead of `div_bas` | `t01_amm` (also `t07`, `t08`, `t10`) |
| M2 | the flash swap deferred trigger is removed | `t02_flash_swap` (also `t06`) |
| M3 | lending reads the instantaneous price despite `config.oracle = 'moyen'` | `t05_oracle_attaque` |
| M4 | `FOR UPDATE` removed from `pool_verrouille`: the second swap is rejected by K instead of being recomputed | `t07_concurrence` |
| M5 | per-account row removed from `emprunter`, `retirer`, `liquider` | `t07_concurrence` (d) |
| M6 | account row replaced by an advisory lock: in `REPEATABLE READ`, the withdraw reads the state from before the borrow | `t07_concurrence` (e) |
| M7 | `emprunter` loses its `search_path` | `t06_droits` |
| R01 | `retirer` no longer checks account health | `t10_arrondis_pret` (also `t07`) |
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

The R rows are the survivors of an independent review: 22 mutants were tried, 14 survived, the 11 above are now killed. Still uncovered: `FOR UPDATE` and `ORDER BY` in `verrouiller_prets`, the `FOR UPDATE` in `liquider`, and within M5 only `emprunter` against `retirer` runs in parallel.

The M1 output:

```
M1 montant_sortie arrondit au plus proche (round de a / b) au lieu de div_bas
  ROUGE t01_amm.sql : ... ECHEC vecteur Uniswap 2 : montant_sortie au wei pres : attendu 453305446940074565, obtenu 453305446940074566
  ROUGE t07_concurrence.sql : ... ECHEC perte : Bob est servi au prix d'origine : attendu 2851015155847869602, obtenu 2851015155847869603
  ROUGE t08_sandwich.sql : ... ERROR:  UniswapV2: K
  ROUGE t10_arrondis_pret.sql : ... ERROR:  UniswapV2: K
  -> tuee par t01_amm.sql
```

One wei off on vector 2 is enough. The other files go red because `echanger` checks K on the rounded output.

## Out of scope

Protocol fee (`_mintFee`), factory and multi-hop router (so no router `deadline` or `quote`), reserve factor, tokens with different decimals (18 everywhere), staking, bad debt, first-depositor defence in the lending pool.

## Differences from the chain

- A cancelled Ethereum transaction pays its gas and stays in the block. Here a cancelled transaction leaves no trace in the business state; only sequences advance.
- Uniswap checks K at the end of the `swap` call. Here the flash swap is checked at the end of the transaction (`COMMIT`), which is wider: several calls can be chained before repaying.
- One flash swap per pool and per transaction: a second loan on the same pool before repayment is rejected with `UniswapV2: LOCKED` (a false positive). `LOCKED` is mostly a diagnostic message: K would refuse a re-entry anyway.
- A superuser can disable a trigger. `t06_droits` shows it. On chain, deployed code has no superuser.
- The owner of the `SECURITY DEFINER` functions is a superuser, for POC simplicity. `06_droits.sql` creates demo roles in the cluster.
- The 1000 minimum shares go to `0x...dEaD`, like the book; Uniswap sends them to `address(0)`.
- A liquidity deposit credits the announced amounts, not `balance - reserve`, and without the router's `quote`: the excess of an unbalanced deposit stays in the pool for the other holders.
- Cumulative prices do not wrap modulo 2^256 (an overflow raises an error) and the timestamp is not truncated to `uint32`.

## Limits

- Only 18 mutations: they show the tests see those faults, not that they see all of them.
- Measured on PostgreSQL 18.6. The image is `postgres:18`, so a newer 18.x may be pulled. The `/` and `sqrt()` traps are themselves assertions in `t01`.
- The GitHub Actions CI (`.github/workflows/ci.yml`) is written but has never been run: only `make test` and `make mutation` locally are measured.
- The guard against `/` only scans `sql/`, line by line, and not strings. `numeric(78,0)` silently rounds a fractional value (`0.5` becomes `1`), a path this guard does not see.
- Locks and the account row prevent corruption (a wait in `READ COMMITTED`, a `40001` to retry in `REPEATABLE READ` and `SERIALIZABLE`), not every deadlock: a `transferer` to a vault during an `emprunter` of the same account, or `observer` then `echanger` in one transaction, can deadlock. PostgreSQL detects one and aborts one of the two transactions. No deadlock test.
- The book does not publish `liquidate`: liquidation takes Aave v2's close factor and bonus, but repays by shares (the book's `repayByShare`) where Aave takes an amount `debtToCover`, and raises `COLLATERAL_INSUFFISANT` where Aave caps at the available collateral.

## Licence

MIT, Odilon Hugonnot, 2026.
