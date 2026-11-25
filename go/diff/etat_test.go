package diff

import (
	"errors"
	"fmt"
	"math/big"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5/pgconn"
)

func etatDeTest(valeur int64) Etat {
	n := func() *big.Int { return big.NewInt(valeur) }
	return Etat{Reserve0: n(), Reserve1: n(), SoldePaire0: n(), SoldePaire1: n(), SoldeTrader0: n(), SoldeTrader1: n()}
}

func TestComparer_EtatsEgaux(t *testing.T) {
	if err := comparer("a", "b", etatDeTest(5), etatDeTest(5)); err != nil {
		t.Fatalf("états identiques, erreur %v", err)
	}
}

func TestComparer_NommeLeChampEnEcart(t *testing.T) {
	champs := []struct {
		nom  string
		pose func(*Etat, *big.Int)
	}{
		{"Reserve0", func(e *Etat, n *big.Int) { e.Reserve0 = n }},
		{"Reserve1", func(e *Etat, n *big.Int) { e.Reserve1 = n }},
		{"SoldePaire0", func(e *Etat, n *big.Int) { e.SoldePaire0 = n }},
		{"SoldePaire1", func(e *Etat, n *big.Int) { e.SoldePaire1 = n }},
		{"SoldeTrader0", func(e *Etat, n *big.Int) { e.SoldeTrader0 = n }},
		{"SoldeTrader1", func(e *Etat, n *big.Int) { e.SoldeTrader1 = n }},
		{"Sortie", func(e *Etat, n *big.Int) { e.Sortie = n }},
	}
	for _, champ := range champs {
		t.Run(champ.nom, func(t *testing.T) {
			a, b := etatDeTest(5), etatDeTest(5)
			champ.pose(&a, big.NewInt(5))
			champ.pose(&b, big.NewInt(6))
			err := comparer("a", "b", a, b)
			attendu := champ.nom + " : a=5, b=6"
			if err == nil || err.Error() != attendu {
				t.Fatalf("erreur %v, attendu %q", err, attendu)
			}
		})
	}
}

func TestComparer_UnSeulNilEstUnEcart(t *testing.T) {
	a, b := etatDeTest(5), etatDeTest(5)
	b.Sortie = big.NewInt(6)
	err := comparer("a", "b", a, b)
	if attendu := "Sortie : a=<nil>, b=6"; err == nil || err.Error() != attendu {
		t.Fatalf("erreur %v, attendu %q", err, attendu)
	}
}

func TestEgaux_NommeLeMoteurEnEcart(t *testing.T) {
	e, autre := etatDeTest(5), etatDeTest(5)
	autre.Reserve0 = big.NewInt(6)
	if err := egaux(e, e, e); err != nil {
		t.Fatalf("trois états identiques, erreur %v", err)
	}
	if err, attendu := egaux(e, e, autre), "Reserve0 : evm=5, modele=6"; err == nil || err.Error() != attendu {
		t.Errorf("modèle en écart : erreur %v, attendu %q", err, attendu)
	}
	if err, attendu := egaux(e, autre, e), "Reserve0 : evm=5, sql=6"; err == nil || err.Error() != attendu {
		t.Errorf("SQL en écart : erreur %v, attendu %q", err, attendu)
	}
}

func TestComparerRefus_AucunRefus(t *testing.T) {
	if err := comparerRefus("", "", ""); err != nil {
		t.Fatalf("erreur %v, attendu nil", err)
	}
}

func TestComparerRefus_PairesListees(t *testing.T) {
	for _, ligne := range tableRefus {
		t.Run(ligne.evm, func(t *testing.T) {
			if err := comparerRefus(ligne.evm, ligne.sql, ligne.evm); err != nil {
				t.Fatalf("paire listée refusée : %v", err)
			}
		})
	}
}

func TestComparerRefus_PaireAbsente(t *testing.T) {
	cas := []struct{ nom, evm, sql, modele string }{
		{"libelle_sql_inconnu", "UniswapV2: K", "INSUFFICIENT_LIQUIDITY", "UniswapV2: K"},
		{"sql_accepte", "UniswapV2: K", "", "UniswapV2: K"},
		{"evm_accepte", "", "UniswapV2: K", "UniswapV2: K"},
		{"modele_en_desaccord", "UniswapV2: K", "UniswapV2: K", "UniswapV2: INSUFFICIENT_LIQUIDITY"},
		{"modele_accepte", "UniswapV2: K", "UniswapV2: K", ""},
		{"sql_refuse_seul", "", "UniswapV2: K", ""},
		{"modele_refuse_seul", "", "", "UniswapV2: K"},
	}
	for _, c := range cas {
		t.Run(c.nom, func(t *testing.T) {
			err := comparerRefus(c.evm, c.sql, c.modele)
			if err == nil || !strings.Contains(err.Error(), "absente de la table des refus") {
				t.Fatalf("erreur %v, attendu « absente de la table des refus »", err)
			}
		})
	}
}

func TestRaisonSQL(t *testing.T) {
	if raison := raisonSQL(nil); raison != "" {
		t.Errorf("nil rend %q", raison)
	}
	metier := fmt.Errorf("swap : %w", &pgconn.PgError{Code: "P0001", Message: "UniswapV2: K"})
	if raison := raisonSQL(metier); raison != "UniswapV2: K" {
		t.Errorf("P0001 rend %q", raison)
	}
	contrainte := fmt.Errorf("swap : %w", &pgconn.PgError{Code: "23514", Message: "violates check"})
	if raison := raisonSQL(contrainte); raison != "23514 violates check" {
		t.Errorf("23514 rend %q", raison)
	}
	if raison := raisonSQL(errors.New("x")); raison != "erreur non SQL : x" {
		t.Errorf("erreur non SQL rend %q", raison)
	}
}
