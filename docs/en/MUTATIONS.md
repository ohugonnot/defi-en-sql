# Mutations

[Back to the README](../../README.en.md) · [Français](../MUTATIONS.md)

The table lists 76 rows: 65 M codes (M1 to M65) and 11 R codes (R01, R02, R03, R04, R05, R06, R12, R14, R18, R19, R24), which is why there are fewer M codes than mutations. In `scripts/mutation.sh`, `total` is incremented on each call to `muter`, one call per sabotage, and no code groups several sabotages: M5 removes a line in five functions but remains a single sabotage. The R numbers have gaps (R07 to R11, R13, R15 to R17 and R20 to R23 are not in the script).

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
