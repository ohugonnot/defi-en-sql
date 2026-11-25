package diff

import "testing"

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
