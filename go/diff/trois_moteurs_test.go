package diff

import (
	"errors"
	"fmt"
	"math/big"
	"testing"
)

// optimisticTestCases of UniswapV2Pair.spec.ts, in the spec's column order: input and output are both token0.
var optimisticTestCases = []struct{ sortie, reserve0, reserve1, entree string }{
	{"997000000000000000", "5000000000000000000", "10000000000000000000", "1000000000000000000"},
	{"997000000000000000", "10000000000000000000", "5000000000000000000", "1000000000000000000"},
	{"997000000000000000", "5000000000000000000", "5000000000000000000", "1000000000000000000"},
	{"1000000000000000000", "5000000000000000000", "5000000000000000000", "1003009027081243732"},
}

type cas struct {
	nom                                string
	entree, reserve0, reserve1, sortie *big.Int
	jetonEntree, jetonSortie           int
}

// inverse is the mirror image: reserves and tokens swapped, same numbers. Not an official vector.
func (c cas) inverse() cas {
	c.reserve0, c.reserve1 = c.reserve1, c.reserve0
	c.jetonEntree, c.jetonSortie = 1-c.jetonEntree, 1-c.jetonSortie
	return c
}

func casOfficiels(t *testing.T) []cas {
	t.Helper()
	var tous []cas
	for i, v := range swapTestCases {
		tous = append(tous, cas{
			nom:    fmt.Sprintf("swap_%d", i+1),
			entree: wei(t, v.entree), reserve0: wei(t, v.reserve0), reserve1: wei(t, v.reserve1), sortie: wei(t, v.sortieAttendue),
			jetonEntree: 0, jetonSortie: 1,
		})
	}
	for i, v := range optimisticTestCases {
		tous = append(tous, cas{
			nom:    fmt.Sprintf("optimiste_%d", i+1),
			entree: wei(t, v.entree), reserve0: wei(t, v.reserve0), reserve1: wei(t, v.reserve1), sortie: wei(t, v.sortie),
			jetonEntree: 0, jetonSortie: 0,
		})
	}
	return tous
}

func troisMoteurs(t *testing.T, gabarit string) (*moteurEVM, *moteurSQL, *modele) {
	t.Helper()
	evm, err := nouveauMoteurEVM()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(evm.Close)
	sql, err := nouveauMoteurSQL(gabarit)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := sql.Close(); err != nil {
			t.Error(err)
		}
	})
	return evm, sql, nouveauModele()
}

func etats(evm *moteurEVM, sql *moteurSQL, mod *modele) (e, s, m Etat, err error) {
	if e, err = evm.etat(); err != nil {
		return
	}
	if s, err = sql.etat(); err != nil {
		return
	}
	return e, s, mod.etat(), nil
}

func egaux(e, s, m Etat) error {
	if err := comparer("evm", "sql", e, s); err != nil {
		return err
	}
	return comparer("evm", "modele", e, m)
}

// verifierEgaux reads the three states and requires them equal.
func verifierEgaux(evm *moteurEVM, sql *moteurSQL, mod *modele) error {
	e, s, m, err := etats(evm, sql, mod)
	if err != nil {
		return err
	}
	return egaux(e, s, m)
}

// echangerSurTrois runs the same swap on the three engines and requires the same refusal reason, or none.
func echangerSurTrois(evm *moteurEVM, sql *moteurSQL, mod *modele, sortie0, sortie1 *big.Int) (raison string, err error) {
	raisonE := raisonEVM(evm.echanger(sortie0, sortie1))
	raisonS := raisonSQL(sql.echanger(sortie0, sortie1))
	raisonM := raisonModele(mod.echanger(sortie0, sortie1))
	return raisonE, comparerRefus(raisonE, raisonS, raisonM)
}

func (c cas) sorties(sortie *big.Int) (sortie0, sortie1 *big.Int) {
	sorties := [2]*big.Int{big.NewInt(0), big.NewInt(0)}
	sorties[c.jetonSortie] = sortie
	return sorties[0], sorties[1]
}

// derouler plays one case on the three engines and returns the first disagreement, prefixed by its step.
func derouler(evm *moteurEVM, sql *moteurSQL, mod *modele, c cas) error {
	etape := "les réserves"
	if err := errors.Join(evm.poserReserves(c.reserve0, c.reserve1), sql.poserReserves(c.reserve0, c.reserve1), mod.poserReserves(c.reserve0, c.reserve1)); err != nil {
		return fmt.Errorf("pendant %s : %w", etape, err)
	}
	if err := verifierEgaux(evm, sql, mod); err != nil {
		return fmt.Errorf("après %s : %w", etape, err)
	}

	etape = "l'entrée"
	if err := errors.Join(evm.transfererAPaire(evm.jeton(c.jetonEntree), c.entree), sql.transfererAPaire(c.jetonEntree, c.entree), mod.transfererAPaire(c.jetonEntree, c.entree)); err != nil {
		return fmt.Errorf("pendant %s : %w", etape, err)
	}
	if err := verifierEgaux(evm, sql, mod); err != nil {
		return fmt.Errorf("après %s : %w", etape, err)
	}

	if c.jetonSortie != c.jetonEntree {
		etape = "le devis"
		e, s, m, err := etats(evm, sql, mod)
		if err != nil {
			return fmt.Errorf("avant %s : %w", etape, err)
		}
		// The bytecode has no quote: its value is the official vector, proved maximal by the K check below.
		e.Sortie = c.sortie
		if s.Sortie, err = sql.montantSortie(c.jetonEntree, c.entree); err != nil {
			return fmt.Errorf("pendant %s : %w", etape, err)
		}
		m.Sortie = mod.montantSortie(c.jetonEntree, c.entree)
		if err := egaux(e, s, m); err != nil {
			return fmt.Errorf("après %s : %w", etape, err)
		}
	}

	etape = "le refus de sortie + 1"
	avantE, avantS, avantM, err := etats(evm, sql, mod)
	if err != nil {
		return fmt.Errorf("avant %s : %w", etape, err)
	}
	sortie0, sortie1 := c.sorties(new(big.Int).Add(c.sortie, big.NewInt(1)))
	raison, err := echangerSurTrois(evm, sql, mod, sortie0, sortie1)
	if err != nil {
		return fmt.Errorf("après %s : %w", etape, err)
	}
	if raison != "UniswapV2: K" {
		return fmt.Errorf("après %s : refus %q, attendu %q", etape, raison, "UniswapV2: K")
	}
	apresE, apresS, apresM, err := etats(evm, sql, mod)
	if err != nil {
		return fmt.Errorf("après %s : %w", etape, err)
	}
	if err := errors.Join(egaux(apresE, apresS, apresM), comparer("evm avant", "evm après", avantE, apresE),
		comparer("sql avant", "sql après", avantS, apresS), comparer("modele avant", "modele après", avantM, apresM)); err != nil {
		return fmt.Errorf("après %s : %w", etape, err)
	}

	etape = "l'échange"
	sortie0, sortie1 = c.sorties(c.sortie)
	if raison, err := echangerSurTrois(evm, sql, mod, sortie0, sortie1); err != nil || raison != "" {
		return fmt.Errorf("après %s : refus %q, %v", etape, raison, err)
	}
	if err := verifierEgaux(evm, sql, mod); err != nil {
		return fmt.Errorf("après %s : %w", etape, err)
	}
	return nil
}

func TestTroisMoteurs_Echanges(t *testing.T) {
	gabarit, err := gabaritIntact()
	if err != nil {
		t.Fatal(err)
	}
	for _, c := range casOfficiels(t) {
		for _, orientation := range []struct {
			sens string
			cas
		}{{"direct", c}, {"inverse", c.inverse()}} {
			t.Run(c.nom+"/"+orientation.sens, func(t *testing.T) {
				evm, sql, mod := troisMoteurs(t, gabarit)
				if err := derouler(evm, sql, mod, orientation.cas); err != nil {
					t.Fatal(err)
				}
			})
		}
	}
}

func TestTroisMoteurs_Refus(t *testing.T) {
	gabarit, err := gabaritIntact()
	if err != nil {
		t.Fatal(err)
	}
	cinq, dix := "5000000000000000000", "10000000000000000000"
	cas := []struct {
		nom, sortie0, sortie1, attendu string
	}{
		{"sortie_nulle", "0", "0", "UniswapV2: INSUFFICIENT_OUTPUT_AMOUNT"},
		{"sortie_egale_reserve1", "0", dix, "UniswapV2: INSUFFICIENT_LIQUIDITY"},
		{"sortie_egale_reserve0", cinq, "0", "UniswapV2: INSUFFICIENT_LIQUIDITY"},
		{"sans_entree", "0", "1", "UniswapV2: INSUFFICIENT_INPUT_AMOUNT"},
	}
	for _, c := range cas {
		t.Run(c.nom, func(t *testing.T) {
			evm, sql, mod := troisMoteurs(t, gabarit)
			if err := errors.Join(evm.poserReserves(wei(t, cinq), wei(t, dix)), sql.poserReserves(wei(t, cinq), wei(t, dix)), mod.poserReserves(wei(t, cinq), wei(t, dix))); err != nil {
				t.Fatal(err)
			}
			avantE, avantS, avantM, err := etats(evm, sql, mod)
			if err != nil {
				t.Fatal(err)
			}
			raison, err := echangerSurTrois(evm, sql, mod, wei(t, c.sortie0), wei(t, c.sortie1))
			if err != nil {
				t.Fatal(err)
			}
			if raison != c.attendu {
				t.Fatalf("refus %q, attendu %q", raison, c.attendu)
			}
			apresE, apresS, apresM, err := etats(evm, sql, mod)
			if err != nil {
				t.Fatal(err)
			}
			if err := errors.Join(egaux(apresE, apresS, apresM), comparer("evm avant", "evm après", avantE, apresE),
				comparer("sql avant", "sql après", avantS, apresS), comparer("modele avant", "modele après", avantM, apresM)); err != nil {
				t.Fatal(err)
			}
		})
	}
}

// On an empty pool every output would also fail the liquidity check: the output check must come first.
func TestTroisMoteurs_RefusSurPoolVide(t *testing.T) {
	gabarit, err := gabaritIntact()
	if err != nil {
		t.Fatal(err)
	}
	evm, sql, mod := troisMoteurs(t, gabarit)
	raison, err := echangerSurTrois(evm, sql, mod, big.NewInt(0), big.NewInt(0))
	if err != nil {
		t.Fatal(err)
	}
	if attendu := "UniswapV2: INSUFFICIENT_OUTPUT_AMOUNT"; raison != attendu {
		t.Fatalf("refus %q, attendu %q", raison, attendu)
	}
}
