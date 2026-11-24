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
SELECT sortie AS sortie_b FROM dblink_get_result('b') AS t(sortie numeric) \gset
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
