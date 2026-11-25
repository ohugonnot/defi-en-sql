package diff

import (
	"errors"
	"math/big"
	"testing"
)

func TestHorloge_ChaqueBlocEstDateDeLaGenesePlusSonNumero(t *testing.T) {
	m, err := nouveauMoteurEVM()
	if err != nil {
		t.Fatal(err)
	}
	defer m.Close()

	// The deployment already sealed several blocks, the loop adds more.
	for range 4 {
		heure, numero, err := m.tete()
		if err != nil {
			t.Fatal(err)
		}
		if attendue := dateGenese + numero; heure != attendue {
			t.Fatalf("bloc %d : horodatage %d, attendu %d (genèse + numéro)", numero, heure, attendue)
		}
		m.commit()
	}
}

func TestMoteurEVM_Etat(t *testing.T) {
	m, err := nouveauMoteurEVM()
	if err != nil {
		t.Fatal(err)
	}
	defer m.Close()
	reserve0, reserve1 := wei(t, "5000000000000000000"), wei(t, "10000000000000000000")
	if err := m.poserReserves(reserve0, reserve1); err != nil {
		t.Fatal(err)
	}
	obtenu, err := m.etat()
	if err != nil {
		t.Fatal(err)
	}
	offre := offreInitiale()
	attendu := Etat{
		Reserve0: reserve0, Reserve1: reserve1, SoldePaire0: reserve0, SoldePaire1: reserve1,
		SoldeTrader0: new(big.Int).Sub(offre, reserve0), SoldeTrader1: new(big.Int).Sub(offre, reserve1),
	}
	if err := comparer("obtenu", "attendu", obtenu, attendu); err != nil {
		t.Fatal(err)
	}
}

func TestRaisonEVM_ErreurSansRevert(t *testing.T) {
	if raison := raisonEVM(nil); raison != "" {
		t.Errorf("nil rend %q", raison)
	}
	if raison := raisonEVM(errors.New("x")); raison != "erreur non décodée : x" {
		t.Errorf("erreur sans revert rend %q", raison)
	}
}
