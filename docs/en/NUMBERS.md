# Measured numbers

[Back to the README](../../README.en.md) · [Français](../CHIFFRES.md)

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

