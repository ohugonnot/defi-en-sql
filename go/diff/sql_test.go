package diff

import (
	"context"
	"math/big"
	"testing"
)

func nouveauMoteurDeTest(t *testing.T) *moteurSQL {
	t.Helper()
	gabarit, err := gabaritIntact()
	if err != nil {
		t.Fatal(err)
	}
	m, err := nouveauMoteurSQL(gabarit)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := m.Close(); err != nil {
			t.Error(err)
		}
	})
	return m
}

func TestMoteurSQL_EtatInitial(t *testing.T) {
	m := nouveauMoteurDeTest(t)
	etat, err := m.etat()
	if err != nil {
		t.Fatal(err)
	}
	zero, offre := new(big.Int), offreInitiale()
	attendu := Etat{Reserve0: zero, Reserve1: zero, SoldePaire0: zero, SoldePaire1: zero, SoldeTrader0: offre, SoldeTrader1: offre}
	if err := comparer("obtenu", "attendu", etat, attendu); err != nil {
		t.Fatal(err)
	}
}

func TestMoteurSQL_UneBaseParScenario(t *testing.T) {
	a, b := nouveauMoteurDeTest(t), nouveauMoteurDeTest(t)
	if err := a.poserReserves(wei(t, "5000000000000000000"), wei(t, "10000000000000000000")); err != nil {
		t.Fatal(err)
	}
	etatB, err := b.etat()
	if err != nil {
		t.Fatal(err)
	}
	if etatB.Reserve0.Sign() != 0 {
		t.Errorf("la seconde base voit Reserve0 = %s, attendu 0", etatB.Reserve0)
	}
	if a.base == b.base {
		t.Errorf("les deux moteurs partagent la base %s", a.base)
	}
}

func TestMoteurSQL_LAppelantEstAlice(t *testing.T) {
	m := nouveauMoteurDeTest(t)
	var appelant string
	if err := m.trader.QueryRow(context.Background(), "SELECT session_user").Scan(&appelant); err != nil {
		t.Fatal(err)
	}
	if appelant != "alice" {
		t.Fatalf("session_user %q, attendu alice", appelant)
	}
}

// moteurAvecEntree is a pool at 5e18/10e18 with 1e18 of token0 already sent to it.
func moteurAvecEntree(t *testing.T) *moteurSQL {
	t.Helper()
	m := nouveauMoteurDeTest(t)
	if err := m.poserReserves(wei(t, "5000000000000000000"), wei(t, "10000000000000000000")); err != nil {
		t.Fatal(err)
	}
	if err := m.transfererAPaire(0, wei(t, "1000000000000000000")); err != nil {
		t.Fatal(err)
	}
	return m
}

func TestMoteurSQL_RefusK(t *testing.T) {
	m := moteurAvecEntree(t)
	avant, err := m.etat()
	if err != nil {
		t.Fatal(err)
	}
	err = m.echanger(big.NewInt(0), wei(t, "1662497915624478907"))
	if raison := raisonSQL(err); raison != "UniswapV2: K" {
		t.Fatalf("refus %q (erreur %v), attendu \"UniswapV2: K\"", raison, err)
	}
	apres, err := m.etat()
	if err != nil {
		t.Fatal(err)
	}
	if err := comparer("avant", "après", avant, apres); err != nil {
		t.Fatalf("un échange refusé a changé l'état : %v", err)
	}
}

func TestMoteurSQL_MontantSortie(t *testing.T) {
	m := moteurAvecEntree(t)
	sortie, err := m.montantSortie(0, wei(t, "1000000000000000000"))
	if err != nil {
		t.Fatal(err)
	}
	if attendu := wei(t, "1662497915624478906"); sortie.Cmp(attendu) != 0 {
		t.Fatalf("montantSortie %s, attendu %s", sortie, attendu)
	}
}
