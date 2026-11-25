package diff

import (
	"context"
	"crypto/ecdsa"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"os"
	"path/filepath"
	"strings"

	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/accounts/abi/bind"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/eth/ethconfig"
	"github.com/ethereum/go-ethereum/ethclient/simulated"
	"github.com/ethereum/go-ethereum/node"
	"github.com/ethereum/go-ethereum/params"
	"github.com/ethereum/go-ethereum/rpc"
)

// The simulated backend seals each block at max(wall clock, parent + 1 s).
// A genesis far in the future keeps the wall clock behind, so every block
// advances by exactly one second, whatever the machine's speed.
const dateGenese = 4_000_000_000

// go-ethereum's public test key: fixed so contract addresses, hence token order, are reproducible.
const cleTraderHex = "b71c71a67e1177ad4e901695e1b4b9ee17ae16c6668d313eac2f96dbcda3f291"

func puissance10(exposant int64) *big.Int {
	return new(big.Int).Exp(big.NewInt(10), big.NewInt(exposant), nil)
}

type artefact struct {
	abi      abi.ABI
	creation []byte
}

func cheminArtefact(nom string) string {
	// Go tests run from the package directory.
	return filepath.Join("..", "testdata", "uniswap-v2-core", nom+".json")
}

func chargerArtefact(nom string) (artefact, error) {
	contenu, err := os.ReadFile(cheminArtefact(nom))
	if err != nil {
		return artefact{}, err
	}
	var brut struct {
		ABI      json.RawMessage `json:"abi"`
		Bytecode string          `json:"bytecode"`
	}
	if err := json.Unmarshal(contenu, &brut); err != nil {
		return artefact{}, fmt.Errorf("%s : %w", nom, err)
	}
	contratABI, err := abi.JSON(strings.NewReader(string(brut.ABI)))
	if err != nil {
		return artefact{}, fmt.Errorf("%s : %w", nom, err)
	}
	return artefact{abi: contratABI, creation: common.FromHex(brut.Bytecode)}, nil
}

// moteurEVM runs the official Uniswap v2 bytecode on a simulated chain.
// One funded account (trader) owns all the tokens and sends every transaction.
type moteurEVM struct {
	backend *simulated.Backend
	client  simulated.Client
	cle     *ecdsa.PrivateKey
	trader  common.Address

	factory, jetonA, jetonB, paire common.Address
	// jeton0 and jeton1 follow the pair's own order (token0 < token1 by address).
	jeton0, jeton1 *bind.BoundContract
	contratPaire   *bind.BoundContract
}

func nouveauMoteurEVM() (*moteurEVM, error) {
	cle, err := crypto.HexToECDSA(cleTraderHex)
	if err != nil {
		return nil, err
	}
	trader := crypto.PubkeyToAddress(cle.PublicKey)
	backend := simulated.NewBackend(
		types.GenesisAlloc{trader: {Balance: puissance10(21)}},
		func(_ *node.Config, conf *ethconfig.Config) { conf.Genesis.Timestamp = dateGenese },
	)
	m := &moteurEVM{backend: backend, client: backend.Client(), cle: cle, trader: trader}
	if err := m.deployer(); err != nil {
		backend.Close()
		return nil, err
	}
	return m, nil
}

func (m *moteurEVM) Close() { m.backend.Close() }

func (m *moteurEVM) commit() { m.backend.Commit() }

// tete returns the timestamp and number of the latest block.
func (m *moteurEVM) tete() (heure, numero uint64, err error) {
	tete, err := m.client.HeaderByNumber(context.Background(), nil)
	if err != nil {
		return 0, 0, err
	}
	return tete.Time, tete.Number.Uint64(), nil
}

func (m *moteurEVM) deployer() error {
	artFactory, err := chargerArtefact("UniswapV2Factory")
	if err != nil {
		return err
	}
	artJeton, err := chargerArtefact("ERC20")
	if err != nil {
		return err
	}
	artPaire, err := chargerArtefact("UniswapV2Pair")
	if err != nil {
		return err
	}

	var factory *bind.BoundContract
	if m.factory, factory, err = m.deployerContrat(artFactory, m.trader); err != nil {
		return fmt.Errorf("factory : %w", err)
	}
	supply := puissance10(24) // far below the uint112 reserve limit
	if m.jetonA, _, err = m.deployerContrat(artJeton, supply); err != nil {
		return fmt.Errorf("jeton A : %w", err)
	}
	if m.jetonB, _, err = m.deployerContrat(artJeton, supply); err != nil {
		return fmt.Errorf("jeton B : %w", err)
	}

	if err := m.envoyer(factory, "createPair", m.jetonA, m.jetonB); err != nil {
		return err
	}
	if m.paire, err = appeler[common.Address](factory, "getPair", m.jetonA, m.jetonB); err != nil {
		return err
	}
	m.contratPaire = bind.NewBoundContract(m.paire, artPaire.abi, m.client, m.client, m.client)

	token0, err := appeler[common.Address](m.contratPaire, "token0")
	if err != nil {
		return err
	}
	m.jeton0 = bind.NewBoundContract(m.jetonA, artJeton.abi, m.client, m.client, m.client)
	m.jeton1 = bind.NewBoundContract(m.jetonB, artJeton.abi, m.client, m.client, m.client)
	if token0 == m.jetonB {
		m.jeton0, m.jeton1 = m.jeton1, m.jeton0
	}
	return nil
}

func (m *moteurEVM) deployerContrat(art artefact, args ...any) (common.Address, *bind.BoundContract, error) {
	opts, err := m.options()
	if err != nil {
		return common.Address{}, nil, err
	}
	adresse, tx, contrat, err := bind.DeployContract(opts, art.abi, art.creation, m.client, args...)
	if err != nil {
		return common.Address{}, nil, err
	}
	return adresse, contrat, m.sceller(tx)
}

func (m *moteurEVM) options() (*bind.TransactOpts, error) {
	return bind.NewKeyedTransactorWithChainID(m.cle, params.AllDevChainProtocolChanges.ChainID)
}

// envoyer sends a transaction and seals it in its own block.
// A call that would revert usually fails at gas estimation and is never mined;
// the receipt check covers the rest.
func (m *moteurEVM) envoyer(contrat *bind.BoundContract, methode string, args ...any) error {
	opts, err := m.options()
	if err != nil {
		return err
	}
	tx, err := contrat.Transact(opts, methode, args...)
	if err != nil {
		return fmt.Errorf("%s : %w", methode, err)
	}
	if err := m.sceller(tx); err != nil {
		return fmt.Errorf("%s : %w", methode, err)
	}
	return nil
}

func (m *moteurEVM) sceller(tx *types.Transaction) error {
	m.commit()
	recu, err := m.client.TransactionReceipt(context.Background(), tx.Hash())
	if err != nil {
		return err
	}
	if recu.Status != types.ReceiptStatusSuccessful {
		return fmt.Errorf("transaction %s échouée", tx.Hash())
	}
	return nil
}

func appeler[T any](contrat *bind.BoundContract, methode string, args ...any) (T, error) {
	var zero T
	var lus []any
	if err := contrat.Call(nil, &lus, methode, args...); err != nil {
		return zero, fmt.Errorf("%s : %w", methode, err)
	}
	if len(lus) == 0 {
		return zero, fmt.Errorf("%s : aucune valeur rendue", methode)
	}
	valeur, ok := lus[0].(T)
	if !ok {
		return zero, fmt.Errorf("%s : type %T, attendu %T", methode, lus[0], zero)
	}
	return valeur, nil
}

// poserReserves funds the pair with both tokens, then mints liquidity shares.
func (m *moteurEVM) poserReserves(reserve0, reserve1 *big.Int) error {
	if err := m.transfererAPaire(m.jeton0, reserve0); err != nil {
		return err
	}
	if err := m.transfererAPaire(m.jeton1, reserve1); err != nil {
		return err
	}
	return m.envoyer(m.contratPaire, "mint", m.trader)
}

func (m *moteurEVM) transfererAPaire(jeton *bind.BoundContract, montant *big.Int) error {
	return m.envoyer(jeton, "transfer", m.paire, montant)
}

func (m *moteurEVM) echanger(sortie0, sortie1 *big.Int) error {
	return m.envoyer(m.contratPaire, "swap", sortie0, sortie1, m.trader, []byte{})
}

func (m *moteurEVM) reserves() (reserve0, reserve1 *big.Int, err error) {
	var lus []any
	if err := m.contratPaire.Call(nil, &lus, "getReserves"); err != nil {
		return nil, nil, fmt.Errorf("getReserves : %w", err)
	}
	if len(lus) != 3 {
		return nil, nil, fmt.Errorf("getReserves : %d valeurs rendues, attendu 3", len(lus))
	}
	reserve0, ok0 := lus[0].(*big.Int)
	reserve1, ok1 := lus[1].(*big.Int)
	if !ok0 || !ok1 {
		return nil, nil, fmt.Errorf("getReserves : types %T, %T, attendu *big.Int", lus[0], lus[1])
	}
	return reserve0, reserve1, nil
}

// raisonRevert returns the require message of a rejected call, or "" if err carries none.
func raisonRevert(err error) string {
	var donnees rpc.DataError
	if !errors.As(err, &donnees) {
		return ""
	}
	hexe, ok := donnees.ErrorData().(string)
	if !ok {
		return ""
	}
	raison, errDecode := abi.UnpackRevert(common.FromHex(hexe))
	if errDecode != nil {
		return ""
	}
	return raison
}
