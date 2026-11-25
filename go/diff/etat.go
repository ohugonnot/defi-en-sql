package diff

import (
	"fmt"
	"math/big"
)

// Etat is what the three engines must agree on after every operation.
type Etat struct {
	Reserve0, Reserve1         *big.Int
	SoldePaire0, SoldePaire1   *big.Int
	SoldeTrader0, SoldeTrader1 *big.Int
	// Sortie is the largest output for the pending input, as this engine gives it. nil when no quote applies.
	Sortie *big.Int
}

func comparer(nomA, nomB string, a, b Etat) error {
	champs := []struct {
		nom  string
		a, b *big.Int
	}{
		{"Reserve0", a.Reserve0, b.Reserve0},
		{"Reserve1", a.Reserve1, b.Reserve1},
		{"SoldePaire0", a.SoldePaire0, b.SoldePaire0},
		{"SoldePaire1", a.SoldePaire1, b.SoldePaire1},
		{"SoldeTrader0", a.SoldeTrader0, b.SoldeTrader0},
		{"SoldeTrader1", a.SoldeTrader1, b.SoldeTrader1},
		{"Sortie", a.Sortie, b.Sortie},
	}
	for _, champ := range champs {
		if !memeValeur(champ.a, champ.b) {
			return fmt.Errorf("%s : %s=%s, %s=%s", champ.nom, nomA, texte(champ.a), nomB, texte(champ.b))
		}
	}
	return nil
}

func memeValeur(a, b *big.Int) bool {
	if a == nil || b == nil {
		return a == b
	}
	return a.Cmp(b) == 0
}

func texte(n *big.Int) string {
	if n == nil {
		return "<nil>"
	}
	return n.String()
}

func comparerRefus(raisonEVM, raisonSQL, raisonModele string) error {
	if raisonEVM == "" && raisonSQL == "" && raisonModele == "" {
		return nil
	}
	for _, ligne := range tableRefus {
		if ligne.evm == raisonEVM && ligne.sql == raisonSQL && ligne.evm == raisonModele {
			return nil
		}
	}
	return fmt.Errorf("Erreur : evm=%q, sql=%q, modele=%q : absente de la table des refus", raisonEVM, raisonSQL, raisonModele)
}

// refus pairs the wording of the bytecode with the wording of the SQL engine; the model words a refusal as the bytecode does.
type refus struct{ evm, sql string }

var tableRefus = []refus{
	{"UniswapV2: INSUFFICIENT_OUTPUT_AMOUNT", "INSUFFICIENT_OUTPUT_AMOUNT"},
	{"UniswapV2: INSUFFICIENT_LIQUIDITY", "INSUFFICIENT_LIQUIDITY"},
	{"UniswapV2: INSUFFICIENT_INPUT_AMOUNT", "INSUFFICIENT_INPUT_AMOUNT"},
	{"UniswapV2: K", "UniswapV2: K"},
}
