# Chiffres mesurés

[Retour au README](../README.md) · [English](en/NUMBERS.md)

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

