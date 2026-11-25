# defi-en-sql

[![ci](https://github.com/ohugonnot/defi-en-sql/actions/workflows/ci.yml/badge.svg)](https://github.com/ohugonnot/defi-en-sql/actions/workflows/ci.yml)

[Version française](README.md)

A Uniswap v2 style swap, a flash swap, an Aave v2 / Compound style lending pool, liquidation, the oracle attack and its fix, the sandwich, replayed to the wei in plain SQL on PostgreSQL 18. The mechanisms follow *Building Full Stack DeFi Applications* (Samuel Zhou, Packt, 2024).
Each mechanism has its own test file, with to-the-wei assertions, and 76 mutations, chosen faults injected one at a time, must each turn their test red.
The traps of a contract (rounding, re-entrancy, a manipulable price) each have their test, and the database adds one the chain does not have: concurrent access, handled with locks and isolation levels.

Amounts are `NUMERIC(78,0)` (the largest `uint256` fits in 78 digits). SQL identifiers are in French.

## What it proves

- Swap rounding holds to the wei: the 7 Uniswap v2 vectors pass, and over 10,000 fixed-seed draws (more than 9,000 swaps executed), no output that the K = x·y invariant rejects, reserves equal to balances ([`t01_amm`](tests/t01_amm.sql)).
- An unrepaid flash swap is refused at `COMMIT`, and re-entering the pool during the loan raises `UniswapV2: LOCKED` ([`t02_flash_swap`](tests/t02_flash_swap.sql)).
- The oracle attack in one transaction goes through with the instantaneous price and is refused with the average price (Uniswap v2 TWAP) ([`t05_oracle_attaque`](tests/t05_oracle_attaque.sql)).
- A lost update between two sessions is reproduced with a naive swap written in the test, and the locks in `echanger()` prevent it: the second swap waits, then is recomputed to the wei ([`t07_concurrence`](tests/t07_concurrence.sql) (a) and (b)).
- An ordinary role writes to no table: it only calls the allowed entry points ([`t06_droits`](tests/t06_droits.sql)).

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

## The tests

| File | What it proves |
|---|---|
| [`t01_amm`](tests/t01_amm.sql) | Uniswap v2 style swap: reference vectors to the wei, 10,000 fixed-seed draws, LP shares. |
| [`t02_flash_swap`](tests/t02_flash_swap.sql) | Flash swap: repayment checked at `COMMIT`, pool shut during the loan. |
| [`t03_pret`](tests/t03_pret.sql) | Lending pool: rate curve, interest by shares, borrowing cap, named errors. |
| [`t04_liquidation`](tests/t04_liquidation.sql) | Liquidation: unhealthy account, bonus, close factor, guards on seized shares. |
| [`t05_oracle_attaque`](tests/t05_oracle_attaque.sql) | Price manipulation: accepted at the instantaneous price, refused at the average price. |
| [`t06_droits`](tests/t06_droits.sql) | Permissions: an ordinary role writes nowhere and only calls the entry points. |
| [`t07_concurrence`](tests/t07_concurrence.sql) | Concurrency: lost update, write skew, lock order, deadlocks. |
| [`t08_sandwich`](tests/t08_sandwich.sql) | Sandwich: what the minimum output caps, and what it lets through. |
| [`t09_oracle_fraicheur`](tests/t09_oracle_fraicheur.sql) | Average price: freshness, window, a vault never observed, a maintenance gap. |
| [`t10_arrondis_pret`](tests/t10_arrondis_pret.sql) | The rounding direction of debt, repayment, withdrawal, cap and seized shares, on non-whole ratios. |
| [`t11_accumulation_interets`](tests/t11_accumulation_interets.sql) | `rembourser`, `retirer`, `deposer` and `liquider` book the interest themselves, checked to the wei. |

## Three findings

- **`/` and `sqrt()` round to nearest in PostgreSQL, where Solidity and Uniswap v2's `Math.sqrt` truncate.** `trunc(2e18::numeric/3)` gives ...667, `div(2e18, 3)` gives ...666. `floor(sqrt(n²-1))` gives `n` for `n = 1000000000000000007`. Every division goes through `div_bas` and `div_haut`, and `make test` fails if a `grep` finds a `/` in `sql/`. Both traps are assertions in `t01`.
- **The oracle attack.** In one transaction, the instantaneous BAR price goes from 0.1 to 998.02 WETH and the attacker gains 99.78 WETH: accepted with the instantaneous price, refused (`ACCOUNT_UNHEALTHY`) with the average price. The limit: if the manipulation is held for one block, the average price read at the next block is about 167 times the true price ([`t05_oracle_attaque`](tests/t05_oracle_attaque.sql)).
- **The lost update.** With a naive swap written in the test, Bob swaps 2, then Alice, who had read before him, swaps 1: she receives 1662497915624478906 instead of 891276464876788046 on the real reserves, Bob's input vanishes from the reserves, and the K of the real balances ends 12.2% below 5e37. With `echanger()`, the second swap waits for the lock then is recomputed. In `REPEATABLE READ`, it gets the serialization error `40001`, which the caller must retry ([`t07_concurrence`](tests/t07_concurrence.sql) (a), (b) and (c)).

## Going further

- [`docs/en/TESTS.md`](docs/en/TESTS.md): what each test file proves, and code excerpts.
- [`docs/en/NUMBERS.md`](docs/en/NUMBERS.md): the measured values, each one a to-the-wei assertion.
- [`docs/en/DESIGN.md`](docs/en/DESIGN.md): design rules, differences from the chain, out of scope.
- [`docs/en/MUTATIONS.md`](docs/en/MUTATIONS.md): the 76 sabotages, the test that goes red for each, and what they do not cover.
- [`docs/en/LIMITS.md`](docs/en/LIMITS.md): what the repo does not prove, including the remaining deadlocks.

## Links

- The blog article that goes with the repo: https://www.web-developpeur.com/en/blog/defi-en-pur-sql-postgresql
- The book's page: https://www.web-developpeur.com/en/library/full-stack-defi-applications/

## Licence

MIT, Odilon Hugonnot, 2026.
