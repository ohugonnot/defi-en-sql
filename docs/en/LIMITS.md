# Limits

[Back to the README](../../README.en.md) · [Français](../LIMITES.md)

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
  - between two plain autocommit calls, two calls that move balances in opposite directions: `transferer` from A to B against B to A, or `transferer` to a pool's cash box against any call that pays that token from that cash box (`echanger`, `retirer_liquidite`, `swap`, `flash_swap`).
    - For the cash box, this happens for the same account in two sessions (one gives to the cash box while the other swaps), and with three sessions when the account paid by the cash box transfers that token to the donor at the same time (alice gives to the cash box, bob swaps, bob transfers to alice).
    - Still for the cash box, sessions of entirely different accounts did not deadlock.
    - Replayed with `pgbench`: the cash box pays to the account, `transferer` takes the two balances in the other order.
- A third party with no stake can target an account by name: `liquider(victim, ..., 1)` ends in `ACCOUNT_HEALTHY` but took the account row first. If the target chains its calls in less than `deadlock_timeout` (1 s), the third party is the one aborted; a third party already holding the `FOR SHARE` in an open transaction (`emprunter(token, 0)`) aborts the target even with no pause.
- Tested: the lock order of `t07` (i) (mutation M34) and the cycle of `t07` (j), where the victim is in practice the repayment, because it waits first. The other cycles are not.
- Liquidation takes Aave v2's close factor and bonus, and repays by shares like the [`liquidate` in the book's repository](https://github.com/PacktPublishing/Building-Full-Stack-DeFi-Application/blob/45d9e354916a032b40352cd4c2332025077b6f36/defi-apps/src/backend/contracts/AssetPool.sol#L767) where Aave takes an amount `debtToCover`. Beyond the close factor, it raises `CLOSE_FACTOR` where the book caps the shares. It raises `COLLATERAL_INSUFFISANT` where Aave caps at the available collateral.
