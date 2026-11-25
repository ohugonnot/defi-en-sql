package diff

import (
	"math/big"
	"testing"
)

func TestModele_VecteursOfficiels(t *testing.T) {
	for _, c := range casOfficiels(t) {
		for _, o := range []struct {
			sens string
			cas
		}{{"direct", c}, {"inverse", c.inverse()}} {
			orientation := o.cas
			t.Run(c.nom+"/"+o.sens, func(t *testing.T) {
				mod := nouveauModele()
				if err := mod.poserReserves(orientation.reserve0, orientation.reserve1); err != nil {
					t.Fatal(err)
				}
				if err := mod.transfererAPaire(orientation.jetonEntree, orientation.entree); err != nil {
					t.Fatal(err)
				}
				avant := mod.etat()
				devis := mod.montantSortie(orientation.jetonEntree, orientation.entree)

				sortie := [2]*big.Int{big.NewInt(0), big.NewInt(0)}
				sortie[orientation.jetonSortie] = new(big.Int).Add(orientation.sortie, big.NewInt(1))
				err := mod.echanger(sortie[0], sortie[1])
				if raison := raisonModele(err); raison != "UniswapV2: K" {
					t.Fatalf("sortie + 1 : refus %q, attendu \"UniswapV2: K\"", raison)
				}
				if err := comparer("avant", "après", avant, mod.etat()); err != nil {
					t.Fatalf("refus sans effet attendu : %v", err)
				}

				sortie[orientation.jetonSortie] = orientation.sortie
				if err := mod.echanger(sortie[0], sortie[1]); err != nil {
					t.Fatalf("sortie %s refusée : %v", orientation.sortie, err)
				}
				reserves := [2]*big.Int{new(big.Int).Set(orientation.reserve0), new(big.Int).Set(orientation.reserve1)}
				reserves[orientation.jetonEntree].Add(reserves[orientation.jetonEntree], orientation.entree)
				reserves[orientation.jetonSortie].Sub(reserves[orientation.jetonSortie], orientation.sortie)
				soldesTrader := [2]*big.Int{
					new(big.Int).Sub(offreInitiale(), orientation.reserve0),
					new(big.Int).Sub(offreInitiale(), orientation.reserve1),
				}
				soldesTrader[orientation.jetonEntree].Sub(soldesTrader[orientation.jetonEntree], orientation.entree)
				soldesTrader[orientation.jetonSortie].Add(soldesTrader[orientation.jetonSortie], orientation.sortie)
				attendu := Etat{
					Reserve0: reserves[0], Reserve1: reserves[1], SoldePaire0: reserves[0], SoldePaire1: reserves[1],
					SoldeTrader0: soldesTrader[0], SoldeTrader1: soldesTrader[1],
				}
				if err := comparer("obtenu", "attendu", mod.etat(), attendu); err != nil {
					t.Error(err)
				}

				if orientation.jetonEntree != orientation.jetonSortie {
					if devis.Cmp(orientation.sortie) != 0 {
						t.Errorf("devis %s, attendu %s", devis, orientation.sortie)
					}
				}
			})
		}
	}
}

func TestModele_Refus(t *testing.T) {
	cinq, dix := wei(t, "5000000000000000000"), wei(t, "10000000000000000000")
	cas := []struct {
		nom              string
		sortie0, sortie1 *big.Int
		attendu          string
	}{
		{"sortie_nulle", big.NewInt(0), big.NewInt(0), "UniswapV2: INSUFFICIENT_OUTPUT_AMOUNT"},
		{"sortie_egale_reserve1", big.NewInt(0), dix, "UniswapV2: INSUFFICIENT_LIQUIDITY"},
		{"sortie_egale_reserve0", cinq, big.NewInt(0), "UniswapV2: INSUFFICIENT_LIQUIDITY"},
		{"sans_entree", big.NewInt(0), big.NewInt(1), "UniswapV2: INSUFFICIENT_INPUT_AMOUNT"},
	}
	for _, c := range cas {
		t.Run(c.nom, func(t *testing.T) {
			mod := nouveauModele()
			if err := mod.poserReserves(cinq, dix); err != nil {
				t.Fatal(err)
			}
			avant := mod.etat()
			if raison := raisonModele(mod.echanger(c.sortie0, c.sortie1)); raison != c.attendu {
				t.Errorf("refus %q, attendu %q", raison, c.attendu)
			}
			if err := comparer("avant", "après", avant, mod.etat()); err != nil {
				t.Errorf("refus sans effet attendu : %v", err)
			}
		})
	}
}

func TestModele_TransfertAuDelaDuSolde(t *testing.T) {
	mod := nouveauModele()
	trop := new(big.Int).Add(offreInitiale(), big.NewInt(1))
	if raison := raisonModele(mod.transfererAPaire(0, trop)); raison != "ds-math-sub-underflow" {
		t.Fatalf("refus %q, attendu \"ds-math-sub-underflow\"", raison)
	}
}
