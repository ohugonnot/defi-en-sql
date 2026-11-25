package diff

import (
	"errors"
	"fmt"
	"math/big"
	"regexp"
	"strings"
	"testing"
)

var motifM1 = regexp.MustCompile(`(?s)SELECT div_bas\((.*?),\n\s+(.*?)\)\n\$\$`)

// muterM1 is the M1 of scripts/mutation.sh applied in memory: the files on disk are never written.
func muterM1(sources []sourceSQL) ([]sourceSQL, error) {
	mutees := append([]sourceSQL(nil), sources...)
	for i, source := range mutees {
		if source.nom != "01_amm.sql" {
			continue
		}
		trouvees := motifM1.FindAllStringSubmatchIndex(source.texte, -1)
		if len(trouvees) != 1 {
			return nil, fmt.Errorf("M1 : mutation sans effet (%d occurrences)", len(trouvees))
		}
		t := trouvees[0]
		dividende, diviseur := source.texte[t[2]:t[3]], source.texte[t[4]:t[5]]
		// Built by hand: ReplaceAllString would read the $ of "$$" as a group reference.
		mutees[i].texte = source.texte[:t[0]] + "SELECT round((" + dividende + ") / (" + diviseur + "))\n$$" + source.texte[t[1]:]
		return mutees, nil
	}
	return nil, errors.New("M1 : mutation sans effet (01_amm.sql absent)")
}

// M1 of scripts/mutation.sh: montant_sortie rounds to nearest instead of down. swap() does not call it, only the quote changes.
// Only the vectors whose fractional part is at least 0.5 are touched.
func TestMordant_M1_ArrondiAuPlusProche(t *testing.T) {
	sources, err := lireSourcesSQL()
	if err != nil {
		t.Fatal(err)
	}
	mutees, err := muterM1(sources)
	if err != nil {
		t.Fatal(err)
	}
	gabarit, err := creerGabarit(mutees)
	if err != nil {
		t.Fatal(err)
	}
	// TestMain drops it too, but not after a panic that skips it.
	t.Cleanup(func() {
		if err := supprimerBase(gabarit); err != nil {
			t.Error(err)
		}
	})
	visees := map[string]bool{"swap_2": true, "swap_3": true, "swap_5": true, "swap_6": true}
	for _, c := range casOfficiels(t) {
		if !visees[c.nom] {
			continue
		}
		for _, orientation := range []struct {
			sens string
			cas
		}{{"direct", c}, {"inverse", c.inverse()}} {
			t.Run(c.nom+"/"+orientation.sens, func(t *testing.T) {
				evm, sql, mod := troisMoteurs(t, gabarit)
				err := derouler(evm, sql, mod, orientation.cas)
				if err == nil {
					t.Fatal("M1 survivante : aucune comparaison n'a échoué")
				}
				attendu := fmt.Sprintf("Sortie : evm=%s, sql=%s", orientation.sortie, new(big.Int).Add(orientation.sortie, big.NewInt(1)))
				if !strings.Contains(err.Error(), attendu) {
					t.Fatalf("erreur %q, attendu qu'elle contienne %q", err, attendu)
				}
			})
		}
	}
}
