# Design

[Back to the README](../../README.en.md) · [Français](../CONCEPTION.md)

Three parts: the design rules, the differences from the chain, what is out of scope.

## Design rules

- **Never `/` on an amount.**
  - On `numeric`, `/` rounds to nearest: `trunc(2e18::numeric/3)` gives ...667, `div(2e18, 3)` gives ...666.
  - Every division goes through `div_bas` and `div_haut`, and `make test` fails if a `grep` finds a `/` in `sql/`.
- **`sqrt()` rounds too**: `floor(sqrt(n²-1))` gives `n` for `n = 1000000000000000007`. `racine_entiere` corrects the guess with two loops.
- **Rounding**:
  - swap output down;
  - deposit and liquidity shares minted down;
  - withdrawal down;
  - debt shares, debt and amount repaid up;
  - borrowing cap down;
  - shares seized in a liquidation down;
  - close factor maximum down.

  The pool never pays a wei too much. The direction for seized shares is a POC choice (Aave rounds to nearest), `t10_arrondis_pret` tests it.
- **Interest**: simple over the elapsed period, compounded at each booking, 31,536,000 s year. This is Compound's model: Aave v2 compounds every second. A single `UPDATE` on `pret_pool` books the interest of every depositor and borrower, thanks to deposit and debt shares.
- **Rates**: base 1%, optimal gap 8 points, excess gap 51 points, kink at 80% (the value the book reads on the dashboard of the Aave v2 ETH pool), so 9% at the kink and 60% at 100%.
- **LTV and liquidation threshold** are one value (`taux_garantie`), like the book's `collateralRate`. Aave keeps them apart.
- **Simulated time**: `chaine` only moves through `avancer_bloc`. No `now()`, no `sleep`, fixed seed.
- **`msg.sender` is `session_user`**. Tests switch identity with `SET SESSION AUTHORIZATION`. Entry points are `SECURITY DEFINER` with a pinned `search_path`, `EXECUTE` revoked from `PUBLIC` then granted from a list.
- **Locks**: each public function takes `FOR UPDATE` on the rows it changes, but the danger also comes from the rows it reads: an account's health depends on its positions in every vault.
  - So `emprunter`, `retirer`, `deposer`, `rembourser` and `liquider` (for the debtor) take the account's row (`compte` table, changed on every call) before any vault lock, then the vault locks in key order.
  - Full order: the WETH price pools `FOR SHARE` (by `id`), the account row, the `chaine` row `FOR SHARE`, then the vaults in key order.
  - `liquider` also takes the liquidator's row, both in name order: the seizure credits his own account, and a liquidator whose snapshot predates it would otherwise judge an account that became healthy again (`t07` (k), mutations M44, M47 and M49: the account that became healthy is played in first and second position, in its own call and in the stale liquidator's, not the order of the two rows).
  - Cost: two liquidations by the same liquidator, on disjoint debtors and vaults, serialize on his account row (a wait in `READ COMMITTED`, `40001` in `REPEATABLE READ` and `SERIALIZABLE`).
  - `40001` and `40P01` are errors to retry: the aborted transaction wrote nothing, the state stays consistent.
  - In `READ COMMITTED` the second session waits then re-reads fresh state; in `REPEATABLE READ` and `SERIALIZABLE` it gets `40001` and the caller retries.
  - An advisory lock would not be enough: it makes the session wait without refreshing the snapshot (`t07` (d) and (e), mutations M5 and M6).
  - `deposer` and `rembourser` take it too: without it, a liquidator whose snapshot predates a top-up in a vault it does not lock would judge the account on the old state and seize collateral from a healthy account (`t07` (h), mutations M29 and M30).
- **Flash swap flag**: `flash_swap` sets `pool.flash_en_cours`; `swap`, `echanger`, `ajouter_liquidite`, `retirer_liquidite` and `flash_swap` raise `UniswapV2: LOCKED` while it is true, and the `COMMIT` check clears it. Comparing reserves was not enough: an attacker restores them during the loan, then draws LP shares through `ajouter_liquidite` and `retirer_liquidite` (`t02`, mutations M8 and M9).
- **Clock and prices**:
  - the `chaine` row is read in the caller's snapshot. So `pool_verrouille`, `verrouiller_prets` and `observer` take `FOR SHARE` on it, and `verrouiller_compte` takes it on the WETH pools that give the prices;
  - a `REPEATABLE READ` or `SERIALIZABLE` snapshot older than a block, or than a swap on those pools, gets `40001` instead of acting on a stale hour or price (`t07` (f) and (g), mutations M10 to M13);
  - the price pools are taken before the account row, otherwise a liquidation funded by a swap (which holds the pool) deadlocks with the debtor's repayment (`t07` (i), mutation M34);
  - the counterpart: `avancer_bloc` waits for open transactions that hold this lock, with no bound while new transactions keep taking it.
- **Collateral with no price**:
  - a collateral that cannot be valued (`PAS_DE_PRIX`, or `PAS_ENCORE_OBSERVE` for a listed vault whose pool has no observation old enough yet to cover the window) is worth 0 in `v_compte` (`prix_garantie`). It gives no borrowing power, stays withdrawable, and blocks neither `liquider` nor the `v_compte_malsain` view;
  - debt is still valued strictly: borrowing a token with no price raises `PAS_DE_PRIX`, and `liquider` only seizes priced collateral (`t03`, `t04`, `t09`, mutations M14, M55 to M57);
  - a maintenance gap in an established series stays `OBSERVATIONS_INSUFFISANTES`: the price remains an error and liquidation is blocked, as for any price error, instead of seizing on a 0 (`t09`, mutations M62 and M63);
  - an account with no debt reads prices to withdraw: under `SERIALIZABLE` it can get a `40001` to replay, like an indebted account;
  - an account with no debt is never unhealthy (its debt is zero), but `retirer` raises for it too if one of its collaterals has a gap (exact rule in the next bullet).
- **Oracle maintenance**:
  - the operating invariant is that the pool of every listed vault is observed at least every 3 blocks (36 s), because the window tolerates only 24 s of slack on its oldest observation (the job of the book's maintenance script);
  - without it, a single public observation (`observer` is open to everyone) is enough to "establish" a series: a debtor holding an unmaintained token can then block his own liquidation and the whole `v_compte_malsain` view, until about `fenetre - 24` s after maintenance resumes;
  - while the gap lasts, `emprunter` and `retirer` raise for any account that has a position in the gapped token, as a deposit or as a debt. Only withdrawing the whole deposit in that token passes, if the account has no debt in it and the rest covers its debt;
  - `deposer` and `rembourser` pass, and an account with no position in that token is not affected, except to borrow the gapped token itself (`t09`);
  - the POC keeps these semantics (an oracle error blocks, the value 0 is reserved for the bootstrap) and does not lengthen the window; `t09` shows the limit and the recovery;
  - `observer` records nothing while a reserve is 0, as the Uniswap v2 cumulative price does: otherwise an observation of the empty pool dilutes the average price (`t09`, mutation M65).

## Differences from the chain

- A cancelled Ethereum transaction pays its gas and stays in the block. Here a cancelled transaction leaves no trace in the business state; only sequences advance.
- Uniswap checks K at the end of the `swap` call. Here the flash swap is checked at the end of the transaction (`COMMIT`), which is wider: several calls can be chained before repaying.
- The pool is shut during a flash swap: a second loan, a swap, a deposit or a withdrawal of liquidity before the check is rejected with `UniswapV2: LOCKED` (a false positive for the second loan).
  - The flag holds until the trigger check, normally at `COMMIT`.
  - `SET CONSTRAINTS flash_swap_rembourse IMMEDIATE` runs that check earlier: on an unrepaid loan the error arrives at that moment (and comes back at `COMMIT` if it was swallowed); on a repaid loan the flag drops and the pool reopens within the same transaction.
  - `IMMEDIATE` lasts until the end of the transaction: a second flash swap is checked at once, so it must be prepaid or the mode set back to `DEFERRED`.
  - Since the check of a prepaid loan runs inside `flash_swap`, the flag is raised before the `INSERT`: raised after, the check would clear it and the function would raise it again, leaving the pool shut for good (`t02`, mutation M33).
  - It is a flag (`pool.flash_en_cours`), not a comparison of reserves, which an attacker can restore during the loan (`t02`, mutations M8 and M9).
- A role that opens a transaction and does nothing can freeze a pool (`observer`, `echanger`), a vault (`accumuler`) or a third party's account (`liquider`), and `avancer_bloc` also waits for open transactions that hold the clock lock. On chain a transaction is atomic and instantaneous: nobody holds a lock between two blocks. Neither `lock_timeout` nor `idle_in_transaction_session_timeout` is set.
- `deposer` and `rembourser` take the account lock (and the `FOR SHARE` on the WETH pools): a concurrent liquidation of the same account can make its deposit or repayment fail with `40001` in `REPEATABLE READ` and `SERIALIZABLE`, to be retried.
- A superuser can disable a trigger. `t06_droits` shows it. On chain, deployed code has no superuser.
- The owner of the `SECURITY DEFINER` functions is a superuser, for POC simplicity. `06_droits.sql` creates demo roles in the cluster.
- The 1000 minimum shares go to `0x...dEaD`, like the book; Uniswap sends them to `address(0)`.
- A liquidity deposit credits the announced amounts, not `balance - reserve`, and without the router's `quote`: the excess of an unbalanced deposit stays in the pool for the other holders.
- Cumulative prices do not wrap modulo 2^256 (an overflow raises an error) and the timestamp is not truncated to `uint32`.

## Out of scope

- Protocol fee (`_mintFee`).
- Factory and multi-hop router (so no router `deadline` or `quote`).
- Reserve factor.
- Tokens with different decimals (18 everywhere).
- Staking.
- Bad debt.
- First-depositor defence in the lending pool.

Account names (`session_user`) share their space with the system accounts (`pool:N`, `pret:X`, the burn address): a role named `pret:WETH` would own the vault's cash box. Only an administrator creates roles, so this is out of scope.
