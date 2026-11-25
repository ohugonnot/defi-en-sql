package diff

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"os"
	"testing"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"
)

// initCodeHashPaire is the constant hardcoded in UniswapV2Library.pairFor.
const initCodeHashPaire = "96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f"

var sha256Artefacts = map[string]string{
	"UniswapV2Pair":    "bb00cb1d64deea4159731b5957eeb8354531a110fb9120b9ef14edbc950e0736",
	"UniswapV2Factory": "7e666780d3ddf601a17c97dcc6a414dd77f5eae13fb37fce7e0bd282f4f61406",
	"ERC20":            "7917faf747fc7f3023bfe102bde224ecce2f261c5993b0a5f2308f95789ff530",
}

func TestProvenance_EmpreinteArtefacts(t *testing.T) {
	for nom, attendu := range sha256Artefacts {
		contenu, err := os.ReadFile(cheminArtefact(nom))
		if err != nil {
			t.Fatalf("%s : %v", nom, err)
		}
		somme := sha256.Sum256(contenu)
		if obtenu := hex.EncodeToString(somme[:]); obtenu != attendu {
			t.Errorf("sha256(%s.json) = %s, attendu %s : artefact modifié", nom, obtenu, attendu)
		}
	}
}

func TestProvenance_InitCodeHashPaire(t *testing.T) {
	paire, err := chargerArtefact("UniswapV2Pair")
	if err != nil {
		t.Fatal(err)
	}
	if obtenu := hex.EncodeToString(crypto.Keccak256(paire.creation)); obtenu != initCodeHashPaire {
		t.Errorf("keccak256(bytecode de création de la paire) = %s, attendu %s", obtenu, initCodeHashPaire)
	}
}

// The factory deploys the pair from the creation code embedded in its own bytecode.
// This links the code that actually runs to the constant of the library.
func TestProvenance_AdresseCreatePair(t *testing.T) {
	m, err := nouveauMoteurEVM()
	if err != nil {
		t.Fatal(err)
	}
	defer m.Close()

	token0, token1 := m.jetonA, m.jetonB
	if bytes.Compare(token0[:], token1[:]) > 0 {
		token0, token1 = token1, token0
	}
	sel := crypto.Keccak256(token0[:], token1[:])
	attendue := crypto.CreateAddress2(m.factory, [32]byte(sel), common.Hex2Bytes(initCodeHashPaire))
	if m.paire != attendue {
		t.Errorf("adresse de createPair = %s, adresse CREATE2 calculée = %s", m.paire, attendue)
	}
}
