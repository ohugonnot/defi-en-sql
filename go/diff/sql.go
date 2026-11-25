package diff

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"math/big"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// Names never cross modele_$$ and t_$$_* of scripts/run-tests.sh, which share the cluster.
var (
	prefixeBases = "diff_" + aleatoireHex()
	verrou       sync.Mutex
	compteur     int
	gabarits     []string
)

func aleatoireHex() string {
	octets := make([]byte, 4)
	if _, err := rand.Read(octets); err != nil {
		panic(err)
	}
	return hex.EncodeToString(octets)
}

// nomSuivant draws a fresh database name; ids are only unique within the process, the prefix covers the others.
func nomSuivant(genre string) string {
	verrou.Lock()
	defer verrou.Unlock()
	compteur++
	return fmt.Sprintf("%s_%s%d", prefixeBases, genre, compteur)
}

type sourceSQL struct{ nom, texte string }

// lireSourcesSQL reads the project's SQL files in load order. Tests run from go/diff.
func lireSourcesSQL() ([]sourceSQL, error) {
	chemins, err := filepath.Glob(filepath.Join("..", "..", "sql", "*.sql"))
	if err != nil {
		return nil, err
	}
	if len(chemins) == 0 {
		return nil, errors.New("aucun fichier sql/*.sql trouvé")
	}
	var sources []sourceSQL
	for _, chemin := range chemins {
		contenu, err := os.ReadFile(chemin)
		if err != nil {
			return nil, err
		}
		sources = append(sources, sourceSQL{nom: filepath.Base(chemin), texte: string(contenu)})
	}
	return sources, nil
}

// delaiOperation makes a hung statement fail instead of waiting for the 10 minutes of go test.
const delaiOperation = 30 * time.Second

func contexte() (context.Context, context.CancelFunc) {
	return context.WithTimeout(context.Background(), delaiOperation)
}

// connecter reads the server from PGHOST; no t.Skip, a silent skip in CI would be a hole.
func connecter(base, role string) (*pgx.Conn, error) {
	if os.Getenv("PGHOST") == "" {
		return nil, errors.New("PGHOST absent : lancer make diff")
	}
	cfg, err := pgx.ParseConfig("")
	if err != nil {
		return nil, err
	}
	cfg.Database, cfg.User = base, role
	ctx, annuler := contexte()
	defer annuler()
	conn, err := pgx.ConnectConfig(ctx, cfg)
	if err != nil {
		return nil, fmt.Errorf("connexion à %s en tant que %s : %w", base, role, err)
	}
	return conn, nil
}

func creerGabarit(sources []sourceSQL) (string, error) {
	nom := nomSuivant("g")
	admin, err := connecter("postgres", "postgres")
	if err != nil {
		return "", err
	}
	defer admin.Close(context.Background())
	ctx, annuler := contexte()
	defer annuler()
	if _, err := admin.Exec(ctx, "CREATE DATABASE "+pgx.Identifier{nom}.Sanitize()); err != nil {
		return "", fmt.Errorf("création du gabarit %s : %w", nom, err)
	}
	verrou.Lock()
	gabarits = append(gabarits, nom)
	verrou.Unlock()

	if err := chargerSources(nom, sources); err != nil {
		return "", errors.Join(err, supprimerBase(nom))
	}
	return nom, nil
}

// chargerSources closes its connection before returning: a database cannot be cloned while a session sits in it.
func chargerSources(base string, sources []sourceSQL) error {
	conn, err := connecter(base, "postgres")
	if err != nil {
		return err
	}
	defer conn.Close(context.Background())
	ctx, annuler := contexte()
	defer annuler()
	if _, err := conn.Exec(ctx, "CREATE EXTENSION dblink"); err != nil {
		return fmt.Errorf("extension dblink : %w", err)
	}
	for _, source := range sources {
		// Simple protocol: a file holds many statements.
		if _, err := conn.PgConn().Exec(ctx, source.texte).ReadAll(); err != nil {
			return fmt.Errorf("%s : %w", source.nom, err)
		}
	}
	return nil
}

var (
	unGabarit     sync.Once
	gabaritCache  string
	gabaritErreur error
)

// gabaritIntact is the template of the unmodified SQL, built once per process.
func gabaritIntact() (string, error) {
	unGabarit.Do(func() {
		sources, err := lireSourcesSQL()
		if err != nil {
			gabaritErreur = err
			return
		}
		gabaritCache, gabaritErreur = creerGabarit(sources)
	})
	return gabaritCache, gabaritErreur
}

func supprimerBase(nom string) error {
	admin, err := connecter("postgres", "postgres")
	if err != nil {
		return err
	}
	defer admin.Close(context.Background())
	ctx, annuler := contexte()
	defer annuler()
	_, err = admin.Exec(ctx, "DROP DATABASE IF EXISTS "+pgx.Identifier{nom}.Sanitize()+" WITH (FORCE)")
	return err
}

// supprimerGabarits drops every template this process created.
func supprimerGabarits() error {
	verrou.Lock()
	aSupprimer := gabarits
	gabarits = nil
	verrou.Unlock()
	var erreurs []error
	for _, nom := range aSupprimer {
		erreurs = append(erreurs, supprimerBase(nom))
	}
	return errors.Join(erreurs...)
}

type moteurSQL struct {
	base string
	// admin (postgres) sets up and reads; trader (alice) is the caller, as session_user.
	admin, trader *pgx.Conn
	pool          int32
}

func nouveauMoteurSQL(gabarit string) (*moteurSQL, error) {
	m := &moteurSQL{base: nomSuivant("s")}
	admin, err := connecter("postgres", "postgres")
	if err != nil {
		return nil, err
	}
	ctx, annuler := contexte()
	defer annuler()
	_, err = admin.Exec(ctx, "CREATE DATABASE "+pgx.Identifier{m.base}.Sanitize()+" TEMPLATE "+pgx.Identifier{gabarit}.Sanitize())
	admin.Close(context.Background())
	if err != nil {
		return nil, fmt.Errorf("clonage du gabarit %s : %w", gabarit, err)
	}
	if err := m.initialiser(); err != nil {
		return nil, errors.Join(fmt.Errorf("initialisation de %s : %w", m.base, err), m.Close())
	}
	return m, nil
}

func (m *moteurSQL) initialiser() error {
	var err error
	if m.admin, err = connecter(m.base, "postgres"); err != nil {
		return err
	}
	if m.trader, err = connecter(m.base, "alice"); err != nil {
		return err
	}
	ctx, annuler := contexte()
	defer annuler()
	offre := offreInitiale().String()
	if _, err := m.admin.Exec(ctx, "INSERT INTO jeton (symbole) VALUES ('T0'), ('T1')"); err != nil {
		return err
	}
	for _, symbole := range []string{"T0", "T1"} {
		if _, err := m.admin.Exec(ctx, "SELECT frapper('alice', $1, $2::numeric)", symbole, offre); err != nil {
			return err
		}
	}
	return m.admin.QueryRow(ctx, "SELECT creer_pool('T0', 'T1')").Scan(&m.pool)
}

func (m *moteurSQL) Close() error {
	var erreurs []error
	for _, conn := range []*pgx.Conn{m.admin, m.trader} {
		if conn != nil {
			erreurs = append(erreurs, conn.Close(context.Background()))
		}
	}
	return errors.Join(append(erreurs, supprimerBase(m.base))...)
}

func (m *moteurSQL) poserReserves(reserve0, reserve1 *big.Int) error {
	ctx, annuler := contexte()
	defer annuler()
	_, err := m.trader.Exec(ctx, "SELECT ajouter_liquidite($1, $2::numeric, $3::numeric)", m.pool, reserve0.String(), reserve1.String())
	return wrap("ajouter_liquidite", err)
}

func (m *moteurSQL) transfererAPaire(jeton int, montant *big.Int) error {
	ctx, annuler := contexte()
	defer annuler()
	_, err := m.trader.Exec(ctx, "SELECT transferer(caisse($1), $2, $3::numeric)", m.pool, fmt.Sprintf("T%d", jeton), montant.String())
	return wrap("transferer", err)
}

func (m *moteurSQL) echanger(sortie0, sortie1 *big.Int) error {
	ctx, annuler := contexte()
	defer annuler()
	_, err := m.trader.Exec(ctx, "SELECT swap($1, $2::numeric, $3::numeric)", m.pool, sortie0.String(), sortie1.String())
	return wrap("swap", err)
}

const (
	requeteSortieJeton0 = "SELECT montant_sortie($2::numeric, reserve0, reserve1, frais_pour_mille)::text FROM pool WHERE id = $1"
	requeteSortieJeton1 = "SELECT montant_sortie($2::numeric, reserve1, reserve0, frais_pour_mille)::text FROM pool WHERE id = $1"
)

func (m *moteurSQL) montantSortie(jetonEntree int, entree *big.Int) (*big.Int, error) {
	requete := requeteSortieJeton0
	if jetonEntree == 1 {
		requete = requeteSortieJeton1
	}
	var texte string
	ctx, annuler := contexte()
	defer annuler()
	if err := m.trader.QueryRow(ctx, requete, m.pool, entree.String()).Scan(&texte); err != nil {
		return nil, wrap("montant_sortie", err)
	}
	return parseEntier(texte)
}

func (m *moteurSQL) etat() (Etat, error) {
	var lus [6]string
	ctx, annuler := contexte()
	defer annuler()
	err := m.admin.QueryRow(ctx, `
		SELECT reserve0::text, reserve1::text,
		       solde_de(caisse(id), jeton0)::text, solde_de(caisse(id), jeton1)::text,
		       solde_de('alice', jeton0)::text, solde_de('alice', jeton1)::text
		FROM pool WHERE id = $1`, m.pool).
		Scan(&lus[0], &lus[1], &lus[2], &lus[3], &lus[4], &lus[5])
	if err != nil {
		return Etat{}, wrap("lecture de l'état", err)
	}
	var n [6]*big.Int
	for i, texte := range lus {
		if n[i], err = parseEntier(texte); err != nil {
			return Etat{}, err
		}
	}
	return Etat{Reserve0: n[0], Reserve1: n[1], SoldePaire0: n[2], SoldePaire1: n[3], SoldeTrader0: n[4], SoldeTrader1: n[5]}, nil
}

func parseEntier(texte string) (*big.Int, error) {
	n, ok := new(big.Int).SetString(texte, 10)
	if !ok {
		return nil, fmt.Errorf("entier invalide %q", texte)
	}
	return n, nil
}

func wrap(operation string, err error) error {
	if err == nil {
		return nil
	}
	return fmt.Errorf("%s : %w", operation, err)
}

// raisonSQL returns the message of a business refusal (RAISE EXCEPTION, P0001), or the code and message of any other server error.
func raisonSQL(err error) string {
	if err == nil {
		return ""
	}
	var erreurPG *pgconn.PgError
	if !errors.As(err, &erreurPG) {
		return "erreur non SQL : " + err.Error()
	}
	if erreurPG.Code == "P0001" {
		return erreurPG.Message
	}
	return erreurPG.Code + " " + erreurPG.Message
}
