package diff

import (
	"fmt"
	"math/big"
	"testing"
)

func wei(t *testing.T, texte string) *big.Int {
	t.Helper()
	n, ok := new(big.Int).SetString(texte, 10)
	if !ok {
		t.Fatalf("entier invalide %q", texte)
	}
	return n
}

// swapTestCases of UniswapV2Pair.spec.ts: the input is always token0.
var swapTestCases = []struct {
	entree, reserve0, reserve1, sortieAttendue string
}{
	{"1000000000000000000", "5000000000000000000", "10000000000000000000", "1662497915624478906"},
	{"1000000000000000000", "10000000000000000000", "5000000000000000000", "453305446940074565"},
	{"2000000000000000000", "5000000000000000000", "10000000000000000000", "2851015155847869602"},
	{"2000000000000000000", "10000000000000000000", "5000000000000000000", "831248957812239453"},
	{"1000000000000000000", "10000000000000000000", "10000000000000000000", "906610893880149131"},
	{"1000000000000000000", "100000000000000000000", "100000000000000000000", "987158034397061298"},
	{"1000000000000000000", "1000000000000000000000", "1000000000000000000000", "996006981039903216"},
}

// paireAvecEntree returns a fresh pair holding the reserves, with the input already sent to it.
func paireAvecEntree(t *testing.T, entree, reserve0, reserve1 *big.Int) *moteurEVM {
	t.Helper()
	m, err := nouveauMoteurEVM()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(m.Close)
	if err := m.poserReserves(reserve0, reserve1); err != nil {
		t.Fatal(err)
	}
	if err := m.transfererAPaire(m.jeton0, entree); err != nil {
		t.Fatal(err)
	}
	return m
}

func TestEchange_SortieAttendueEstLaPlusGrandeAcceptee(t *testing.T) {
	for i, cas := range swapTestCases {
		t.Run(fmt.Sprintf("cas_%d", i+1), func(t *testing.T) {
			entree, reserve0, reserve1, sortie := wei(t, cas.entree), wei(t, cas.reserve0), wei(t, cas.reserve1), wei(t, cas.sortieAttendue)

			m := paireAvecEntree(t, entree, reserve0, reserve1)
			if err := m.echanger(big.NewInt(0), sortie); err != nil {
				t.Fatalf("la sortie attendue %s est refusée : %v", sortie, err)
			}
			obtenu0, obtenu1, err := m.reserves()
			if err != nil {
				t.Fatal(err)
			}
			attendu0, attendu1 := new(big.Int).Add(reserve0, entree), new(big.Int).Sub(reserve1, sortie)
			if obtenu0.Cmp(attendu0) != 0 || obtenu1.Cmp(attendu1) != 0 {
				t.Errorf("réserves (%s, %s), attendues (%s, %s)", obtenu0, obtenu1, attendu0, attendu1)
			}

			refus := paireAvecEntree(t, entree, reserve0, reserve1).echanger(big.NewInt(0), new(big.Int).Add(sortie, big.NewInt(1)))
			if refus == nil {
				t.Fatal("sortie + 1 wei acceptée, attendu un refus \"UniswapV2: K\"")
			}
			if raison := raisonRevert(refus); raison != "UniswapV2: K" {
				t.Errorf("sortie + 1 wei refusée avec %q (erreur %v), attendu \"UniswapV2: K\"", raison, refus)
			}
		})
	}
}
