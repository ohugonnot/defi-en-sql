package diff

import (
	"errors"
	"math/big"
)

// A model of UniswapV2Pair.swap and ERC20.transfer. No uint112 or uint256 bound: unreachable with a supply of 1e24.
type modele struct {
	reserve     [2]*big.Int
	soldePaire  [2]*big.Int
	soldeTrader [2]*big.Int
}

// Input share left after the 0.3% fee, per thousand.
const entreeNetteDeFrais = 997

func nouveauModele() *modele {
	m := &modele{}
	for i := range 2 {
		m.reserve[i] = new(big.Int)
		m.soldePaire[i] = new(big.Int)
		m.soldeTrader[i] = offreInitiale()
	}
	return m
}

func (m *modele) poserReserves(reserve0, reserve1 *big.Int) error {
	for i, montant := range []*big.Int{reserve0, reserve1} {
		if err := m.transfererAPaire(i, montant); err != nil {
			return err
		}
	}
	// shares are modelled in T3
	for i := range 2 {
		m.reserve[i] = new(big.Int).Set(m.soldePaire[i])
	}
	return nil
}

func (m *modele) transfererAPaire(jeton int, montant *big.Int) error {
	if m.soldeTrader[jeton].Cmp(montant) < 0 {
		return errors.New("ds-math-sub-underflow")
	}
	m.soldeTrader[jeton] = new(big.Int).Sub(m.soldeTrader[jeton], montant)
	m.soldePaire[jeton] = new(big.Int).Add(m.soldePaire[jeton], montant)
	return nil
}

// echanger follows UniswapV2Pair.swap line by line, on copies, and commits only at the end.
func (m *modele) echanger(sortie0, sortie1 *big.Int) error {
	sortie := [2]*big.Int{sortie0, sortie1}
	if sortie0.Sign() == 0 && sortie1.Sign() == 0 {
		return errors.New("UniswapV2: INSUFFICIENT_OUTPUT_AMOUNT")
	}
	if sortie0.Cmp(m.reserve[0]) >= 0 || sortie1.Cmp(m.reserve[1]) >= 0 {
		return errors.New("UniswapV2: INSUFFICIENT_LIQUIDITY")
	}

	var soldePaire, soldeTrader, entree [2]*big.Int
	for i := range 2 {
		soldePaire[i] = new(big.Int).Sub(m.soldePaire[i], sortie[i])
		soldeTrader[i] = new(big.Int).Add(m.soldeTrader[i], sortie[i])
		reste := new(big.Int).Sub(m.reserve[i], sortie[i])
		entree[i] = new(big.Int)
		if soldePaire[i].Cmp(reste) > 0 {
			entree[i].Sub(soldePaire[i], reste)
		}
	}
	if entree[0].Sign() == 0 && entree[1].Sign() == 0 {
		return errors.New("UniswapV2: INSUFFICIENT_INPUT_AMOUNT")
	}

	var ajuste [2]*big.Int
	for i := range 2 {
		ajuste[i] = new(big.Int).Sub(new(big.Int).Mul(soldePaire[i], big.NewInt(1000)), new(big.Int).Mul(entree[i], big.NewInt(3)))
	}
	apres := new(big.Int).Mul(ajuste[0], ajuste[1])
	avant := new(big.Int).Mul(new(big.Int).Mul(m.reserve[0], m.reserve[1]), big.NewInt(1_000_000))
	if apres.Cmp(avant) < 0 {
		return errors.New("UniswapV2: K")
	}

	m.soldePaire, m.soldeTrader = soldePaire, soldeTrader
	m.reserve = [2]*big.Int{new(big.Int).Set(soldePaire[0]), new(big.Int).Set(soldePaire[1])}
	return nil
}

// closed form of the largest output the K check accepts; same expression as UniswapV2Library.getAmountOut
func (m *modele) montantSortie(jetonEntree int, entree *big.Int) *big.Int {
	reserveEntree, reserveSortie := m.reserve[jetonEntree], m.reserve[1-jetonEntree]
	net := new(big.Int).Mul(entree, big.NewInt(entreeNetteDeFrais))
	numerateur := new(big.Int).Mul(net, reserveSortie)
	denominateur := new(big.Int).Add(new(big.Int).Mul(reserveEntree, big.NewInt(1000)), net)
	return numerateur.Quo(numerateur, denominateur)
}

func (m *modele) etat() Etat {
	copie := func(n *big.Int) *big.Int { return new(big.Int).Set(n) }
	return Etat{
		Reserve0: copie(m.reserve[0]), Reserve1: copie(m.reserve[1]),
		SoldePaire0: copie(m.soldePaire[0]), SoldePaire1: copie(m.soldePaire[1]),
		SoldeTrader0: copie(m.soldeTrader[0]), SoldeTrader1: copie(m.soldeTrader[1]),
	}
}

func raisonModele(err error) string {
	if err == nil {
		return ""
	}
	return err.Error()
}
