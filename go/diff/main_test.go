package diff

import (
	"context"
	"fmt"
	"os"
	"testing"
)

func TestMain(m *testing.M) {
	code := m.Run()
	if err := supprimerGabarits(); err != nil {
		fmt.Fprintln(os.Stderr, "nettoyage des gabarits :", err)
		code = 1
	}
	verrou.Lock()
	aCreeDesBases := compteur > 0
	verrou.Unlock()
	if !aCreeDesBases {
		os.Exit(code)
	}
	// Counts only this process's prefix: a global sweep would kill a concurrent run.
	restantes, err := compterBasesDuProcessus()
	if err != nil || restantes != 0 {
		fmt.Fprintf(os.Stderr, "bases %s* restantes : %d (erreur %v)\n", prefixeBases, restantes, err)
		code = 1
	}
	os.Exit(code)
}

func compterBasesDuProcessus() (int, error) {
	admin, err := connecter("postgres", "postgres")
	if err != nil {
		return 0, err
	}
	defer admin.Close(context.Background())
	ctx, annuler := contexte()
	defer annuler()
	var nombre int
	err = admin.QueryRow(ctx, "SELECT count(*) FROM pg_database WHERE starts_with(datname, $1)", prefixeBases).Scan(&nombre)
	return nombre, err
}
