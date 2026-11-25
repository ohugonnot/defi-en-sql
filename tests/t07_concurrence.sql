INSERT INTO jeton (symbole) VALUES ('T0'), ('T1');
SELECT frapper(c, j, 100e18) FROM unnest(ARRAY['alice', 'bob', 'mallory']) c, unnest(ARRAY['T0', 'T1']) j;
SELECT creer_pool('T0', 'T1') FROM generate_series(1, 3);
SET SESSION AUTHORIZATION mallory;
SELECT ajouter_liquidite(n, 5e18, 10e18) FROM generate_series(1, 3) n;
RESET SESSION AUTHORIZATION;

-- (a) A real lost update. Bob and Alice both read pool 1, compute on what they read, then write reserves
-- computed from their own reading instead of the balances. Bob commits first, Alice overwrites him.
CREATE FUNCTION echanger_naif(id_pool int, entree numeric) RETURNS numeric
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE lu pool; sortie numeric;
BEGIN
  SELECT * INTO lu FROM pool WHERE id = id_pool;
  sortie := montant_sortie(entree, lu.reserve0, lu.reserve1);
  PERFORM deplacer(session_user::text, caisse(id_pool), lu.jeton0, entree);
  PERFORM deplacer(caisse(id_pool), session_user::text, lu.jeton1, sortie);
  UPDATE pool SET reserve0 = lu.reserve0 + entree, reserve1 = lu.reserve1 - sortie WHERE id = id_pool;
  RETURN sortie;
END $$;
GRANT EXECUTE ON FUNCTION echanger_naif TO alice, bob;

-- The result of a pending dblink call, or a named failure when the remote call raised.
CREATE FUNCTION resultat_ou_echec(connexion text, message text) RETURNS numeric LANGUAGE plpgsql AS $$
DECLARE valeur numeric;
BEGIN
  SELECT t.sortie INTO valeur FROM dblink_get_result(connexion) AS t(sortie numeric);
  RETURN valeur;
EXCEPTION WHEN OTHERS THEN
  RAISE EXCEPTION 'ECHEC % : erreur % (%)', message, SQLSTATE, SQLERRM;
END $$;

SELECT dblink_connect('a', 'dbname=' || current_database() || ' user=alice'),
       dblink_connect('b', 'dbname=' || current_database() || ' user=bob');
SELECT pid AS pid_a FROM dblink('a', 'SELECT pg_backend_pid()') AS t(pid int) \gset
SELECT pid AS pid_b FROM dblink('b', 'SELECT pg_backend_pid()') AS t(pid int) \gset
SELECT reserve0 * reserve1 AS k_avant FROM pool WHERE id = 1 \gset
SELECT dblink_exec('b', 'BEGIN');
SELECT sortie AS sortie_bob FROM dblink('b', 'SELECT echanger_naif(1, 2000000000000000000)') AS t(sortie numeric) \gset
SELECT dblink_send_query('a', 'SELECT echanger_naif(1, 1000000000000000000)');
SELECT attendre_blocage('a', :pid_a);
SELECT dblink_exec('b', 'COMMIT');
SELECT sortie AS sortie_alice FROM dblink_get_result('a') AS t(sortie numeric) \gset
SELECT dblink_get_result('a') IS NULL;
SELECT assert_egal(:'sortie_bob'::numeric, 2851015155847869602::numeric, 'perte : Bob est servi au prix d''origine');
SELECT assert_egal(:'sortie_alice'::numeric, 1662497915624478906::numeric, 'perte : Alice est servie au meme prix d''origine, perime');
SELECT assert_egal(montant_sortie(1e18, 7e18, 10e18 - :'sortie_bob'::numeric), 891276464876788046::numeric,
                   'perte : sur les reserves apres Bob, Alice recevrait 891276464876788046, pas 1662497915624478906');
SELECT assert_egal(reserve0, 6e18, 'perte : l''echange de Bob a disparu des reserves') FROM pool WHERE id = 1;
SELECT assert_egal(solde_de('pool:1', 'T0') - reserve0, 2e18, 'perte : ses 2e18 sont dans la caisse, hors reserves') FROM pool WHERE id = 1;
SELECT assert_egal(solde_de('pool:1', 'T0') * solde_de('pool:1', 'T1'), 43891895428221211936000000000000000000::numeric,
                   'perte : K des soldes reels');
SELECT assert_vrai(solde_de('pool:1', 'T0') * solde_de('pool:1', 'T1') < :'k_avant'::numeric,
                   'perte : K des soldes reels < K d''avant (environ 12,2 % de moins)');

-- (b) echanger(): Bob blocks on Alice's row lock, then both swaps apply one after the other.
SELECT reserve0 AS r0, reserve1 AS r1 FROM pool WHERE id = 2 \gset
SELECT montant_sortie(1e18, :'r0'::numeric, :'r1'::numeric) AS sortie_a_attendue,
       montant_sortie(2e18, :'r0'::numeric + 1e18, :'r1'::numeric - montant_sortie(1e18, :'r0'::numeric, :'r1'::numeric)) AS sortie_b_attendue \gset
SELECT dblink_exec('a', 'BEGIN');
SELECT sortie AS sortie_a FROM dblink('a', 'SELECT echanger(2, ''T0'', 1000000000000000000)') AS t(sortie numeric) \gset
SELECT dblink_send_query('b', 'SELECT echanger(2, ''T0'', 2000000000000000000)');
SELECT attendre_blocage('b', :pid_b);
SELECT dblink_exec('a', 'COMMIT');
SELECT resultat_ou_echec('b', 'concurrence : le second echange aboutit') AS sortie_b \gset
SELECT dblink_get_result('b') IS NULL;
SELECT assert_egal(:'sortie_a'::numeric, :'sortie_a_attendue'::numeric, 'concurrence : swap d''Alice au prix d''origine');
SELECT assert_egal(:'sortie_b'::numeric, :'sortie_b_attendue'::numeric, 'concurrence : Bob recalcule sur les reserves d''Alice, au wei');
SELECT assert_egal(reserve0, :'r0'::numeric + 3e18, 'concurrence : reserve0 contient les deux entrees') FROM pool WHERE id = 2;
SELECT assert_egal(reserve1, :'r1'::numeric - :'sortie_a'::numeric - :'sortie_b'::numeric, 'concurrence : reserve1 a perdu les deux sorties')
  FROM pool WHERE id = 2;
SELECT assert_vrai(reserve0 * reserve1 >= :'r0'::numeric * :'r1'::numeric, 'concurrence : K apres >= K avant') FROM pool WHERE id = 2;
SELECT assert_egal(reserve1, 6257819928227811680::numeric, 'concurrence : reserves finales (8e18, 6257819928227811680)') FROM pool WHERE id = 2;
SELECT assert_egal(reserve0 * reserve1, 50062559425822493440000000000000000000::numeric, 'concurrence : K passe de 5e37 a 5,006e37') FROM pool WHERE id = 2;
SELECT assert_vrai(reserve0 = solde_de('pool:2', 'T0') AND reserve1 = solde_de('pool:2', 'T1'), 'concurrence : reserves = soldes de la caisse')
  FROM pool WHERE id = 2;

-- (c) REPEATABLE READ: a snapshot taken before Bob's commit cannot lock the row he changed.
SELECT dblink_exec('a', 'BEGIN ISOLATION LEVEL REPEATABLE READ');
SELECT * FROM dblink('a', 'SELECT 1') AS t(x int);
SELECT * FROM dblink('b', 'SELECT echanger(3, ''T0'', 2000000000000000000)') AS t(sortie numeric);
SELECT assert_leve($q$SELECT * FROM dblink('a', 'SELECT echanger(3, ''T0'', 1000000000000000000)') AS t(sortie numeric)$q$,
                   '40001', 'REPEATABLE READ : erreur de serialisation 40001');
SELECT dblink_exec('a', 'ROLLBACK');
SELECT assert_egal(reserve0, 7e18, 'REPEATABLE READ : seul le swap de Bob est applique') FROM pool WHERE id = 3;

-- (d) Write skew on one account. Alice borrows all the WETH while, in parallel, she withdraws all her COL.
-- Each call checks her health on a snapshot that misses the other: only the per-account lock stops it.
INSERT INTO jeton (symbole) VALUES ('WETH'), ('COL');
SELECT frapper('alice', 'COL', 2000e18), frapper('bob', 'WETH', 1000e18), frapper('mallory', 'COL', 1e24), frapper('mallory', 'WETH', 1e24);
SELECT creer_pool('COL', 'WETH') AS pool_prix \gset
SELECT creer_pret_pool('WETH'), creer_pret_pool('COL');
UPDATE config SET oracle = 'instantane';
SET SESSION AUTHORIZATION mallory;
SELECT ajouter_liquidite(:pool_prix, 1e24, 1e24);
SET SESSION AUTHORIZATION bob;
SELECT deposer('WETH', 1000e18);
SET SESSION AUTHORIZATION alice;
SELECT deposer('COL', 1250e18);
RESET SESSION AUTHORIZATION;
SELECT assert_egal(max_empruntable, 1000e18, 'ecriture croisee : 1250 COL a 1 WETH, plafond 0,8 = 1000 WETH') FROM v_compte WHERE compte = 'alice';
SELECT dblink_connect('c', 'dbname=' || current_database() || ' user=alice'),
       dblink_connect('d', 'dbname=' || current_database() || ' user=alice');
SELECT pid AS pid_d FROM dblink('d', 'SELECT pg_backend_pid()') AS t(pid int) \gset
SELECT dblink_exec('c', 'BEGIN');
SELECT parts AS parts_empruntees FROM dblink('c', 'SELECT emprunter(''WETH'', 1000000000000000000000)') AS t(parts numeric) \gset
SELECT dblink_exec('d', 'BEGIN');
SELECT dblink_send_query('d', 'SELECT retirer(''COL'', 1250000000000000000000)');
SELECT attendre_blocage('d', :pid_d);
SELECT assert_vrai(EXISTS (SELECT 1 FROM pg_locks WHERE pid = :pid_d AND locktype IN ('transactionid', 'advisory') AND NOT granted),
                   'ecriture croisee : le retrait attend l''autre appel sur le compte');
SELECT dblink_exec('c', 'COMMIT');
SELECT assert_leve($q$SELECT * FROM dblink_get_result('d') AS t(montant numeric)$q$, 'ACCOUNT_UNHEALTHY',
                   'ecriture croisee : le retrait echoue une fois l''emprunt visible');
SELECT dblink_disconnect('d');
SELECT assert_egal(parts_depot, 1250e18, 'ecriture croisee : les 1250 COL sont toujours deposes')
  FROM pret_position WHERE compte = 'alice' AND jeton = 'COL';
SELECT assert_egal(solde_de('alice', 'WETH'), 1000e18, 'ecriture croisee : les 1000 WETH empruntes sont a alice');
SELECT assert_vrai(est_sain('alice'), 'ecriture croisee : le compte reste sain');

-- (e) Same skew in REPEATABLE READ. Both snapshots are taken before the borrow commits, so waiting is not enough:
-- the withdraw must fail with 40001 instead of checking the account on the old state.
SELECT frapper('liquidateur', 'COL', 1250e18), frapper('mallory', 'WETH', 1000e18);
SET SESSION AUTHORIZATION mallory;
SELECT deposer('WETH', 1000e18);
SET SESSION AUTHORIZATION liquidateur;
SELECT deposer('COL', 1250e18);
RESET SESSION AUTHORIZATION;
SELECT dblink_connect('e', 'dbname=' || current_database() || ' user=liquidateur'),
       dblink_connect('f', 'dbname=' || current_database() || ' user=liquidateur');
SELECT dblink_exec('e', 'BEGIN ISOLATION LEVEL REPEATABLE READ'), dblink_exec('f', 'BEGIN ISOLATION LEVEL REPEATABLE READ');
SELECT * FROM dblink('e', 'SELECT 1') AS t(x int), dblink('f', 'SELECT 1') AS u(y int);
SELECT * FROM dblink('e', 'SELECT emprunter(''WETH'', 1000000000000000000000)') AS t(parts numeric);
SELECT dblink_exec('e', 'COMMIT');
SELECT assert_leve($q$SELECT * FROM dblink('f', 'SELECT retirer(''COL'', 1250000000000000000000)') AS t(montant numeric)$q$,
                   '40001', 'REPEATABLE READ : le retrait echoue en 40001 apres l''emprunt');
SELECT dblink_exec('f', 'ROLLBACK');
SELECT assert_egal(parts_depot, 1250e18, 'REPEATABLE READ : les 1250 COL sont toujours deposes')
  FROM pret_position WHERE compte = 'liquidateur' AND jeton = 'COL';
SELECT assert_vrai(est_sain('liquidateur'), 'REPEATABLE READ : le compte reste sain');

-- (f) The clock row. A REPEATABLE READ or SERIALIZABLE snapshot taken before a block passes must not act on the old
-- time: the call would stamp interest and price accumulators with the stale hour (a free window for an oracle attack).
CREATE FUNCTION refuse_en_40001(connexion text, appel text, message text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM dblink_exec(connexion, 'SAVEPOINT s');
  PERFORM assert_leve(format($q$SELECT * FROM dblink(%L, %L) AS t(x text)$q$, connexion, appel), '40001', message);
  PERFORM dblink_exec(connexion, 'ROLLBACK TO s');
END $$;

SELECT dblink_exec('a', 'BEGIN ISOLATION LEVEL REPEATABLE READ');
SELECT * FROM dblink('a', 'SELECT 1') AS t(x int);
SELECT avancer_bloc(1);
SELECT refuse_en_40001('a', 'SELECT echanger(2, ''T0'', 10000000000000000)', 'REPEATABLE READ : echanger sur l''heure perimee');
SELECT refuse_en_40001('a', 'SELECT deposer(''WETH'', 1000000000000000)', 'REPEATABLE READ : deposer sur l''heure perimee');
SELECT refuse_en_40001('a', 'SELECT observer(2)', 'REPEATABLE READ : observer sur l''heure perimee');
SELECT dblink_exec('a', 'ROLLBACK');

SELECT dblink_exec('a', 'BEGIN ISOLATION LEVEL SERIALIZABLE');
SELECT * FROM dblink('a', 'SELECT 1') AS t(x int);
SELECT avancer_bloc(1);
SELECT refuse_en_40001('a', 'SELECT echanger(2, ''T0'', 10000000000000000)', 'SERIALIZABLE : echanger sur l''heure perimee');
SELECT refuse_en_40001('a', 'SELECT deposer(''WETH'', 1000000000000000)', 'SERIALIZABLE : deposer sur l''heure perimee');
SELECT refuse_en_40001('a', 'SELECT observer(2)', 'SERIALIZABLE : observer sur l''heure perimee');
SELECT dblink_exec('a', 'ROLLBACK');

-- (g) The price row. The health check prices the collateral from the WETH pools: a snapshot older than a trade on
-- them must fail with 40001, not validate a debt against the old price (oracle 'instantane' here).
-- Alice: 3250 COL at 1 WETH, limit 2600, debt 1000. A 1400 loan is fine at that price, not after COL loses 17 %.
SELECT frapper('alice', 'COL', 2000e18), frapper('bob', 'WETH', 2000e18), frapper('mallory', 'COL', 1e23);
SET SESSION AUTHORIZATION alice;
SELECT deposer('COL', 2000e18);
SET SESSION AUTHORIZATION bob;
SELECT deposer('WETH', 2000e18);
RESET SESSION AUTHORIZATION;
SELECT assert_egal(max_empruntable, 2600e18, 'prix perime : plafond d''alice 2600 WETH au prix d''avant') FROM v_compte WHERE compte = 'alice';
SELECT dblink_connect('m', 'dbname=' || current_database() || ' user=mallory');
SELECT dblink_exec('a', 'BEGIN ISOLATION LEVEL REPEATABLE READ');
SELECT * FROM dblink('a', 'SELECT 1') AS t(x int);
SELECT * FROM dblink('m', format('SELECT echanger(%s, ''COL'', 100000000000000000000000)', :pool_prix)) AS t(sortie numeric);
SELECT refuse_en_40001('a', 'SELECT emprunter(''WETH'', 1400000000000000000000)', 'REPEATABLE READ : emprunter sur le prix perime');
SELECT dblink_exec('a', 'ROLLBACK');
SELECT assert_vrai(max_empruntable < 2400e18, 'prix perime : le plafond d''alice est tombe sous 2400 WETH') FROM v_compte WHERE compte = 'alice';
SELECT assert_leve($q$SELECT * FROM dblink('a', 'SELECT emprunter(''WETH'', 1400000000000000000000)') AS t(parts numeric)$q$,
                   'ACCOUNT_UNHEALTHY', 'READ COMMITTED : le meme emprunt est refuse au prix courant');
-- Same in SERIALIZABLE, with a loan that is healthy at the price of the snapshot and at the current one.
SELECT frapper('mallory', 'COL', 1e22);
SELECT dblink_exec('a', 'BEGIN ISOLATION LEVEL SERIALIZABLE');
SELECT * FROM dblink('a', 'SELECT 1') AS t(x int);
SELECT * FROM dblink('m', format('SELECT echanger(%s, ''COL'', 10000000000000000000000)', :pool_prix)) AS t(sortie numeric);
SELECT refuse_en_40001('a', 'SELECT emprunter(''WETH'', 1000000000000000000)', 'SERIALIZABLE : emprunter sur le prix perime');
SELECT dblink_exec('a', 'ROLLBACK');

-- (h) A deposit or a repayment changes an account's health in a vault the liquidator does not lock. Without the
-- account row, a liquidator whose snapshot predates it judges the account on the old state and seizes collateral.
DO $$
DECLARE nom text;
BEGIN
  FOREACH nom IN ARRAY ARRAY['debiteur_a', 'debiteur_b', 'debiteur_c', 'debiteur_d', 'debiteur_e'] LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = nom) THEN
      EXECUTE format('CREATE ROLE %I LOGIN IN ROLE utilisateur', nom);
    END IF;
  END LOOP;
END $$;
INSERT INTO jeton (symbole) VALUES ('HCOL'), ('HTRI');
SELECT frapper('mallory', 'HCOL', 1.1e24), frapper('mallory', 'HTRI', 1e24), frapper('mallory', 'WETH', 2e24),
       frapper('bob', 'WETH', 4000e18), frapper('bob', 'HTRI', 1000e18), frapper('liquidateur', 'WETH', 1000e18);
SELECT frapper(d, j, 1000e18) FROM unnest(ARRAY['debiteur_a', 'debiteur_b', 'debiteur_c', 'debiteur_d', 'debiteur_e']) d, unnest(ARRAY['HCOL', 'HTRI']) j;
SELECT creer_pool('HCOL', 'WETH') AS pool_hcol \gset
SELECT creer_pool('HTRI', 'WETH') AS pool_htri \gset
SELECT creer_pret_pool('HCOL'), creer_pret_pool('HTRI');
SET SESSION AUTHORIZATION mallory;
SELECT ajouter_liquidite(:pool_hcol, 1e24, 1e24), ajouter_liquidite(:pool_htri, 1e24, 1e24);
SET SESSION AUTHORIZATION bob;
SELECT deposer('WETH', 4000e18), deposer('HTRI', 1000e18);
-- a and b borrow 780 against 1000 HCOL (limit 800); c and d owe 700 WETH and 80 HTRI.
SET SESSION AUTHORIZATION debiteur_a;
SELECT deposer('HCOL', 1000e18), emprunter('WETH', 780e18);
SET SESSION AUTHORIZATION debiteur_b;
SELECT deposer('HCOL', 1000e18), emprunter('WETH', 780e18);
SET SESSION AUTHORIZATION debiteur_c;
SELECT deposer('HCOL', 1000e18), emprunter('WETH', 700e18), emprunter('HTRI', 80e18);
SET SESSION AUTHORIZATION debiteur_d;
SELECT deposer('HCOL', 1000e18), emprunter('WETH', 700e18), emprunter('HTRI', 80e18);
-- e borrows like a and b, for the READ COMMITTED case.
SET SESSION AUTHORIZATION debiteur_e;
SELECT deposer('HCOL', 1000e18), emprunter('WETH', 780e18);
-- HCOL loses about 5 %: the limit falls to about 761.
SET SESSION AUTHORIZATION mallory;
SELECT echanger(:pool_hcol, 'HCOL', 25000000000000000000000);
RESET SESSION AUTHORIZATION;
SELECT assert_vrai(NOT est_sain('debiteur_a') AND NOT est_sain('debiteur_b') AND NOT est_sain('debiteur_c') AND NOT est_sain('debiteur_d') AND NOT est_sain('debiteur_e'),
                   'liquidation concurrente : les cinq debiteurs sont malsains');
SELECT dblink_connect('l', 'dbname=' || current_database() || ' user=liquidateur'),
       dblink_connect('da', 'dbname=' || current_database() || ' user=debiteur_a'),
       dblink_connect('db', 'dbname=' || current_database() || ' user=debiteur_b'),
       dblink_connect('dc', 'dbname=' || current_database() || ' user=debiteur_c'),
       dblink_connect('dd', 'dbname=' || current_database() || ' user=debiteur_d'),
       dblink_connect('de', 'dbname=' || current_database() || ' user=debiteur_e');

-- Outcome of a call as text: 'ok' or 'SQLSTATE message', so a test can name a deadlock instead of failing on it.
CREATE FUNCTION issue_de_appel(connexion text, appel text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  PERFORM * FROM dblink(connexion, appel) AS t(r numeric);
  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN RETURN SQLSTATE || ' ' || SQLERRM;
END $$;
CREATE FUNCTION issue_de_resultat(connexion text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE issue text := 'ok';
BEGIN
  BEGIN
    PERFORM * FROM dblink_get_result(connexion) AS t(r numeric);
  EXCEPTION WHEN OTHERS THEN issue := SQLSTATE || ' ' || SQLERRM;
  END;
  PERFORM * FROM dblink_get_result(connexion) AS t(r numeric);
  RETURN issue;
END $$;

SELECT dblink_exec('l', 'BEGIN ISOLATION LEVEL REPEATABLE READ');
SELECT * FROM dblink('l', 'SELECT 1') AS t(x int);
SELECT * FROM dblink('da', 'SELECT deposer(''HTRI'', 1000000000000000000000)') AS t(parts numeric);
SELECT refuse_en_40001('l', 'SELECT liquider(''debiteur_a'', ''WETH'', ''HCOL'', 300000000000000000000)', 'REPEATABLE READ : liquider apres un depot dans un troisieme coffre');
SELECT dblink_exec('l', 'ROLLBACK');

SELECT dblink_exec('l', 'BEGIN ISOLATION LEVEL SERIALIZABLE');
SELECT * FROM dblink('l', 'SELECT 1') AS t(x int);
SELECT * FROM dblink('db', 'SELECT deposer(''HTRI'', 1000000000000000000000)') AS t(parts numeric);
SELECT refuse_en_40001('l', 'SELECT liquider(''debiteur_b'', ''WETH'', ''HCOL'', 300000000000000000000)', 'SERIALIZABLE : liquider apres un depot dans un troisieme coffre');
SELECT dblink_exec('l', 'ROLLBACK');

SELECT dblink_exec('l', 'BEGIN ISOLATION LEVEL REPEATABLE READ');
SELECT * FROM dblink('l', 'SELECT 1') AS t(x int);
SELECT * FROM dblink('dc', 'SELECT rembourser(''HTRI'', 80000000000000000000)') AS t(montant numeric);
SELECT refuse_en_40001('l', 'SELECT liquider(''debiteur_c'', ''WETH'', ''HCOL'', 300000000000000000000)', 'REPEATABLE READ : liquider apres un remboursement dans un troisieme coffre');
SELECT dblink_exec('l', 'ROLLBACK');
SELECT dblink_exec('l', 'BEGIN ISOLATION LEVEL SERIALIZABLE');
SELECT * FROM dblink('l', 'SELECT 1') AS t(x int);
SELECT * FROM dblink('dd', 'SELECT rembourser(''HTRI'', 80000000000000000000)') AS t(montant numeric);
SELECT refuse_en_40001('l', 'SELECT liquider(''debiteur_d'', ''WETH'', ''HCOL'', 300000000000000000000)', 'SERIALIZABLE : liquider apres un remboursement dans un troisieme coffre');
SELECT dblink_exec('l', 'ROLLBACK');
SELECT assert_vrai(est_sain('debiteur_a') AND est_sain('debiteur_b') AND est_sain('debiteur_c') AND est_sain('debiteur_d'),
                   'liquidation concurrente : les quatre comptes sont sains apres leur renflouement');

-- (h bis) In READ COMMITTED the liquidation waits for the debtor's account row, then must judge the account on the fresh state:
-- the lock comes before the health check, or the debtor's top-up commits and the liquidation still seizes.
SELECT pid AS pid_l FROM dblink('l', 'SELECT pg_backend_pid()') AS t(pid int) \gset
SELECT dblink_exec('de', 'BEGIN');
SELECT * FROM dblink('de', 'SELECT deposer(''HTRI'', 1000000000000000000000)') AS t(parts numeric);
SELECT dblink_send_query('l', 'SELECT liquider(''debiteur_e'', ''WETH'', ''HCOL'', 300000000000000000000)');
SELECT attendre_blocage('l', :pid_l);
SELECT dblink_exec('de', 'COMMIT');
SELECT issue_de_resultat('l') AS issue_rc \gset
SELECT assert_vrai(:'issue_rc' LIKE '%ACCOUNT_HEALTHY', 'READ COMMITTED : la liquidation attend le compte puis le juge sain');
SELECT assert_vrai(est_sain('debiteur_e'), 'READ COMMITTED : le depot du debiteur l''a renfloue');
SELECT assert_vrai(NOT EXISTS (SELECT 1 FROM pret_position WHERE compte = 'liquidateur' AND jeton = 'HCOL'),
                   'READ COMMITTED : aucune part saisie a un compte sain');

-- (i) Lock order. The liquidator holds a WETH pool (a swap that funds the liquidation) and then asks for the debtor's
-- account row; the debtor's repayment must not hold that row while it waits for the pool, or the two deadlock.
SELECT pid AS pid_dc FROM dblink('dc', 'SELECT pg_backend_pid()') AS t(pid int) \gset
SELECT dblink_exec('l', 'BEGIN');
SELECT * FROM dblink('l', format('SELECT echanger(%s, ''WETH'', 10000000000000000)', :pool_hcol)) AS t(sortie numeric);
SELECT dblink_send_query('dc', 'SELECT rembourser(''WETH'', 1000000000000000000)');
SELECT attendre_blocage('dc', :pid_dc);
SELECT issue_de_appel('l', 'SELECT liquider(''debiteur_c'', ''WETH'', ''HCOL'', 1000000000000000000)') AS issue_i \gset
SELECT assert_vrai(:'issue_i' NOT LIKE '40P01%', 'ordre des verrous : interblocage');
SELECT assert_vrai(:'issue_i' LIKE '%ACCOUNT_HEALTHY', 'ordre des verrous : la liquidation n''attend pas le remboursement');
SELECT dblink_exec('l', 'ROLLBACK');
SELECT issue_de_resultat('dc') AS issue_dc \gset
SELECT assert_egal(:'issue_dc', 'ok', 'ordre des verrous : le remboursement attend le pool puis aboutit');

-- (j) The mirror cycle, accepted and documented: the liquidator holds the WETH pools (FOR SHARE) and the debtor's account
-- row, then asks a pool FOR UPDATE; the debtor's repayment shares the pools and waits for the row. One of the two is
-- the victim with 40P01 (the one whose deadlock_timeout expires first), the other goes through, the state stays whole.
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'debiteur_j') THEN CREATE ROLE debiteur_j LOGIN IN ROLE utilisateur; END IF;
END $$;
SELECT frapper('debiteur_j', 'HCOL', 1000e18), frapper('mallory', 'HCOL', 3e23), frapper('liquidateur', 'HCOL', 50e18);
SET SESSION AUTHORIZATION debiteur_j;
SELECT deposer('HCOL', 1000e18), emprunter('WETH', 500e18);
SET SESSION AUTHORIZATION mallory;
SELECT echanger(:pool_hcol, 'HCOL', 300000000000000000000000);
RESET SESSION AUTHORIZATION;
SELECT assert_vrai(NOT est_sain('debiteur_j'), 'interblocage : le debiteur est malsain');
SELECT sum(montant) AS weth_avant FROM solde WHERE jeton = 'WETH' \gset
SELECT (SELECT parts_dette FROM pret_position WHERE compte = 'debiteur_j' AND jeton = 'WETH') AS dette_avant,
       (SELECT reserve0 FROM pool WHERE id = :pool_hcol) AS reserve_avant \gset
SELECT dblink_connect('dj', 'dbname=' || current_database() || ' user=debiteur_j');
SELECT pid AS pid_dj FROM dblink('dj', 'SELECT pg_backend_pid()') AS t(pid int) \gset
SELECT dblink_exec('l', 'BEGIN');
SELECT * FROM dblink('l', 'SELECT liquider(''debiteur_j'', ''WETH'', ''HCOL'', 100000000000000000000)') AS t(montant numeric);
SELECT dblink_send_query('dj', 'SELECT rembourser(''WETH'', 1000000000000000000)');
SELECT attendre_blocage('dj', :pid_dj);
SELECT dblink_send_query('l', format('SELECT echanger(%s, ''HCOL'', 50000000000000000000)', :pool_hcol));
SELECT issue_de_resultat('dj') AS issue_debiteur, issue_de_resultat('l') AS issue_liquidateur \gset
SELECT dblink_exec('l', 'COMMIT');
SELECT assert_vrai((:'issue_debiteur' LIKE '40P01%') <> (:'issue_liquidateur' LIKE '40P01%'), 'interblocage : exactement une victime 40P01');
SELECT assert_vrai(:'issue_debiteur' = 'ok' OR :'issue_liquidateur' = 'ok', 'interblocage : l''autre transaction aboutit');
SELECT assert_vrai(
         CASE WHEN :'issue_liquidateur' = 'ok'
              THEN dette = :'dette_avant'::numeric - 100e18 AND reserve = :'reserve_avant'::numeric + 50e18
              ELSE dette < :'dette_avant'::numeric AND dette > :'dette_avant'::numeric - 100e18 AND reserve = :'reserve_avant'::numeric END,
         'interblocage : seul l''effet du gagnant est visible')
  FROM (SELECT (SELECT parts_dette FROM pret_position WHERE compte = 'debiteur_j' AND jeton = 'WETH') AS dette,
               (SELECT reserve0 FROM pool WHERE id = :pool_hcol) AS reserve) etat;
SELECT assert_egal(sum(montant), :'weth_avant'::numeric, 'interblocage : le WETH est conserve') FROM solde WHERE jeton = 'WETH';
SELECT assert_vrai(count(*) > 0 AND bool_and(p.parts_depot_total = coalesce(s.depot, 0) AND p.parts_dette_total = coalesce(s.dette, 0)),
                   'interblocage : somme des parts des positions = totaux des vaults')
  FROM pret_pool p LEFT JOIN (SELECT jeton, sum(parts_depot) AS depot, sum(parts_dette) AS dette FROM pret_position GROUP BY jeton) s USING (jeton);

-- (k) A liquidator who is himself unhealthy and is made healthy by the collateral he seizes. A liquidator whose snapshot
-- predates that seizure must not liquidate him on the old state: liquider locks the liquidator's account row too.
-- The debiteur_* accounts sort before the stale liquidator ('liquidateur'), the tiers_* ones after, and each a_tiers_* debtor sorts before its tiers_* liquidator: each row is played in both lock positions.
DO $$
DECLARE nom text;
BEGIN
  FOREACH nom IN ARRAY ARRAY['debiteur_f', 'debiteur_g', 'debiteur_h', 'debiteur_i', 'tiers_f', 'a_tiers_g', 'tiers_h', 'a_tiers_i'] LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = nom) THEN
      EXECUTE format('CREATE ROLE %I LOGIN IN ROLE utilisateur', nom);
    END IF;
  END LOOP;
END $$;
INSERT INTO jeton (symbole) VALUES ('KC'), ('XD'), ('YC');
SELECT frapper('mallory', j, 1.1e24) FROM unnest(ARRAY['KC', 'XD', 'YC']) j;
SELECT frapper('mallory', 'WETH', 5e24), frapper('mallory', 'WETH', 4000e18), frapper('bob', 'XD', 4000e18),
       frapper('liquidateur', 'WETH', 1000e18), frapper('debiteur_f', 'XD', 1000e18), frapper('debiteur_h', 'XD', 1000e18),
       frapper('tiers_f', 'XD', 1000e18), frapper('tiers_h', 'XD', 1000e18);
SELECT frapper(d, 'KC', 1000e18) FROM unnest(ARRAY['debiteur_f', 'debiteur_h', 'tiers_f', 'tiers_h']) d;
SELECT frapper(d, 'YC', 1000e18) FROM unnest(ARRAY['debiteur_g', 'debiteur_i', 'a_tiers_g', 'a_tiers_i']) d;
SELECT creer_pool('KC', 'WETH') AS pool_kc \gset
SELECT creer_pool('XD', 'WETH') AS pool_xd \gset
SELECT creer_pool('YC', 'WETH') AS pool_yc \gset
SELECT creer_pret_pool('KC'), creer_pret_pool('XD'), creer_pret_pool('YC');
SET SESSION AUTHORIZATION mallory;
SELECT ajouter_liquidite(:pool_kc, 1e24, 1e24), ajouter_liquidite(:pool_xd, 1e24, 1e24), ajouter_liquidite(:pool_yc, 1e24, 1e24);
SELECT deposer('WETH', 4000e18);
SET SESSION AUTHORIZATION bob;
SELECT deposer('XD', 4000e18);
-- f and h borrow 780 WETH against 1000 KC (limit 800); g and i borrow 780 XD against 1000 YC.
SET SESSION AUTHORIZATION debiteur_f;
SELECT deposer('KC', 1000e18), emprunter('WETH', 780e18);
SET SESSION AUTHORIZATION debiteur_h;
SELECT deposer('KC', 1000e18), emprunter('WETH', 780e18);
SET SESSION AUTHORIZATION debiteur_g;
SELECT deposer('YC', 1000e18), emprunter('XD', 780e18);
SET SESSION AUTHORIZATION debiteur_i;
SELECT deposer('YC', 1000e18), emprunter('XD', 780e18);
SET SESSION AUTHORIZATION tiers_f;
SELECT deposer('KC', 1000e18), emprunter('WETH', 780e18);
SET SESSION AUTHORIZATION tiers_h;
SELECT deposer('KC', 1000e18), emprunter('WETH', 780e18);
SET SESSION AUTHORIZATION a_tiers_g;
SELECT deposer('YC', 1000e18), emprunter('XD', 780e18);
SET SESSION AUTHORIZATION a_tiers_i;
SELECT deposer('YC', 1000e18), emprunter('XD', 780e18);
SET SESSION AUTHORIZATION mallory;
SELECT echanger(:pool_kc, 'KC', 25000000000000000000000), echanger(:pool_yc, 'YC', 25000000000000000000000);
RESET SESSION AUTHORIZATION;
SELECT assert_vrai(bool_and(NOT est_sain(c)), 'liquidateur renfloue : les huit comptes sont malsains')
  FROM unnest(ARRAY['debiteur_f', 'debiteur_g', 'debiteur_h', 'debiteur_i', 'tiers_f', 'a_tiers_g', 'tiers_h', 'a_tiers_i']) c;
SELECT dblink_connect('df', 'dbname=' || current_database() || ' user=debiteur_f'),
       dblink_connect('dh', 'dbname=' || current_database() || ' user=debiteur_h'),
       dblink_connect('tf', 'dbname=' || current_database() || ' user=tiers_f'),
       dblink_connect('th', 'dbname=' || current_database() || ' user=tiers_h');

SELECT dblink_exec('l', 'BEGIN ISOLATION LEVEL REPEATABLE READ');
SELECT * FROM dblink('l', 'SELECT 1') AS t(x int);
SELECT * FROM dblink('df', 'SELECT liquider(''debiteur_g'', ''XD'', ''YC'', 390000000000000000000)') AS t(montant numeric);
SELECT assert_vrai(est_sain('debiteur_f'), 'REPEATABLE READ : la saisie a renfloue le liquidateur');
SELECT refuse_en_40001('l', 'SELECT liquider(''debiteur_f'', ''WETH'', ''KC'', 300000000000000000000)', 'REPEATABLE READ : liquider un liquidateur renfloue par sa propre saisie');
SELECT dblink_exec('l', 'ROLLBACK');

SELECT dblink_exec('l', 'BEGIN ISOLATION LEVEL SERIALIZABLE');
SELECT * FROM dblink('l', 'SELECT 1') AS t(x int);
SELECT * FROM dblink('dh', 'SELECT liquider(''debiteur_i'', ''XD'', ''YC'', 390000000000000000000)') AS t(montant numeric);
SELECT assert_vrai(est_sain('debiteur_h'), 'SERIALIZABLE : la saisie a renfloue le liquidateur');
SELECT refuse_en_40001('l', 'SELECT liquider(''debiteur_h'', ''WETH'', ''KC'', 300000000000000000000)', 'SERIALIZABLE : liquider un liquidateur renfloue par sa propre saisie');
SELECT dblink_exec('l', 'ROLLBACK');

SELECT dblink_exec('l', 'BEGIN ISOLATION LEVEL REPEATABLE READ');
SELECT * FROM dblink('l', 'SELECT 1') AS t(x int);
SELECT * FROM dblink('tf', 'SELECT liquider(''a_tiers_g'', ''XD'', ''YC'', 390000000000000000000)') AS t(montant numeric);
SELECT assert_vrai(est_sain('tiers_f'), 'REPEATABLE READ, nom apres le liquidateur : la saisie a renfloue le liquidateur');
SELECT refuse_en_40001('l', 'SELECT liquider(''tiers_f'', ''WETH'', ''KC'', 300000000000000000000)', 'REPEATABLE READ, nom apres le liquidateur : liquider un liquidateur renfloue par sa propre saisie');
SELECT dblink_exec('l', 'ROLLBACK');

SELECT dblink_exec('l', 'BEGIN ISOLATION LEVEL SERIALIZABLE');
SELECT * FROM dblink('l', 'SELECT 1') AS t(x int);
SELECT * FROM dblink('th', 'SELECT liquider(''a_tiers_i'', ''XD'', ''YC'', 390000000000000000000)') AS t(montant numeric);
SELECT assert_vrai(est_sain('tiers_h'), 'SERIALIZABLE, nom apres le liquidateur : la saisie a renfloue le liquidateur');
SELECT refuse_en_40001('l', 'SELECT liquider(''tiers_h'', ''WETH'', ''KC'', 300000000000000000000)', 'SERIALIZABLE, nom apres le liquidateur : liquider un liquidateur renfloue par sa propre saisie');
SELECT dblink_exec('l', 'ROLLBACK');
