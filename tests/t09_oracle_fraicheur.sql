INSERT INTO jeton (symbole) VALUES ('WETH'), ('BAR');
SELECT frapper('alice', j, 1e30) FROM unnest(ARRAY['WETH', 'BAR']) j;
SELECT creer_pool('BAR', 'WETH');
SET SESSION AUTHORIZATION alice;
SELECT ajouter_liquidite(1, 10e18, 1e18);
RESET SESSION AUTHORIZATION;

SELECT assert_leve('SELECT prix_moyen(''BAR'')', 'PAS_ENCORE_OBSERVE', 'prix moyen sans aucune observation : refuse');

-- The oldest observation must be at least window minus two blocks old (720 - 24 = 696 s, 58 blocks).
SELECT observer(1);
SELECT avancer_bloc(57);
SELECT assert_leve('SELECT prix_moyen(''BAR'')', 'PAS_ENCORE_OBSERVE', 'observation vieille de 684 s : refuse');
SELECT avancer_bloc(1);
SELECT assert_vrai(0.1e18 - prix_moyen('BAR') BETWEEN 0 AND 1, 'observation vieille de 696 s : acceptee, prix constant a 1 wei pres');

-- Past the window the observation no longer counts.
SELECT avancer_bloc(4);
SELECT assert_leve('SELECT prix_moyen(''BAR'')', 'OBSERVATIONS_INSUFFISANTES', 'observation vieille de 744 s, hors fenetre : refuse');

-- A pool with no liquidity yet has no price: a named error, not a raw division by zero.
INSERT INTO jeton (symbole) VALUES ('ZZZ');
SELECT creer_pool('ZZZ', 'WETH');
SELECT assert_leve('SELECT prix_instantane(''ZZZ'')', 'PAS_DE_PRIX', 'prix instantane d''un pool vide : PAS_DE_PRIX');

-- Lending under the average price. NEW has a price pool that nobody has observed yet, so it has no average: it is worth 0.
INSERT INTO jeton (symbole) VALUES ('NEW');
SELECT frapper('bob', 'WETH', 100e18), frapper('alice', 'NEW', 1), frapper('liquidateur', 'WETH', 10e18);
SELECT creer_pret_pool('WETH'), creer_pret_pool('BAR'), creer_pret_pool('NEW');
SELECT creer_pool('NEW', 'WETH');
SELECT observer(1);
SELECT avancer_bloc(58);
SET SESSION AUTHORIZATION bob;
SELECT deposer('WETH', 100e18);
SET SESSION AUTHORIZATION alice;
SELECT deposer('BAR', 10e18);
SELECT emprunter('WETH', 0.7e18);
RESET SESSION AUTHORIZATION;
UPDATE pret_pool SET taux_garantie = 0.5e18 WHERE jeton = 'BAR';
SET SESSION AUTHORIZATION alice;
SELECT deposer('NEW', 1);
SELECT assert_leve('SELECT prix(''NEW'')', 'PAS_ENCORE_OBSERVE', 'coffre liste mais jamais observe : prix refuse');
SELECT assert_passe('SELECT prix_garantie(''NEW'')', 'coffre jamais observe : prix_garantie ne leve pas');
SELECT assert_egal(prix_garantie('NEW'), 0::numeric, 'coffre jamais observe : prix_garantie vaut 0');
SELECT assert_egal(prix_garantie('BAR'), prix_moyen('BAR'), 'coffre observe : prix_garantie rend le prix moyen');
SELECT assert_passe('SELECT est_sain(''alice'')', 'collateral jamais observe : est_sain ne leve pas');
SELECT assert_vrai(NOT est_sain('alice'), 'collateral jamais observe : alice est malsaine');
SET SESSION AUTHORIZATION liquidateur;
SELECT assert_passe('SELECT liquider(''alice'', ''WETH'', ''BAR'', 100000000000000000)', 'collateral jamais observe : alice reste liquidable');

-- Only a missing price is turned into 0: any other error goes up. A zero-second window divides by zero.
RESET SESSION AUTHORIZATION;
UPDATE config SET fenetre = 0;
SELECT observer(1);
SELECT assert_leve('SELECT prix_garantie(''BAR'')', '22012', 'prix_garantie : une autre erreur que prix absent est relancee, pas avalee');
UPDATE config SET fenetre = 720;

-- A maintenance gap in an established series is not a bootstrap: the price stays an error, so a sound account is not liquidated on a 0.
INSERT INTO jeton (symbole) VALUES ('GAP'), ('STB');
SELECT frapper('alice', 'GAP', 1000e18), frapper('alice', 'STB', 1000e18), frapper('mallory', 'GAP', 10e18), frapper('mallory', 'STB', 10e18),
       frapper('liquidateur', 'WETH', 20e18), frapper('alice', 'WETH', 2000e18);
SELECT creer_pret_pool('GAP'), creer_pret_pool('STB');
SELECT creer_pool('GAP', 'WETH') AS pool_gap \gset
SELECT creer_pool('STB', 'WETH') AS pool_stb \gset
SET SESSION AUTHORIZATION alice;
SELECT ajouter_liquidite(:pool_gap, 1000e18, 1000e18), ajouter_liquidite(:pool_stb, 1000e18, 1000e18);
RESET SESSION AUTHORIZATION;
SELECT assert_egal(:pool_gap::int + 1, :pool_stb::int, 'les pools GAP et STB se suivent (ids 4 et 5, codes en dur ci dessous)');
DO $$ BEGIN FOR i IN 1..70 LOOP PERFORM avancer_bloc(1); PERFORM observer(4); PERFORM observer(5); END LOOP; END $$;
SET SESSION AUTHORIZATION mallory;
SELECT deposer('GAP', 10e18), deposer('STB', 10e18);
SELECT emprunter('WETH', 10e18);
RESET SESSION AUTHORIZATION;
SELECT assert_vrai(est_sain('mallory'), 'serie etablie : mallory (20 WETH de collateral, 10 de dette) est saine');
-- GAP misses 3 blocks while STB is observed all along, then maintenance is perfect again: GAP's window now starts inside the gap.
DO $$ BEGIN FOR i IN 1..3 LOOP PERFORM avancer_bloc(1); PERFORM observer(5); END LOOP; END $$;
DO $$ BEGIN FOR i IN 1..58 LOOP PERFORM avancer_bloc(1); PERFORM observer(4); PERFORM observer(5); END LOOP; END $$;
SELECT assert_leve('SELECT prix(''GAP'')', 'OBSERVATIONS_INSUFFISANTES', 'trou de 3 blocs dans une serie etablie : prix refuse');
SELECT assert_leve('SELECT prix_garantie(''GAP'')', 'OBSERVATIONS_INSUFFISANTES', 'trou de 3 blocs : prix_garantie ne le convertit pas en 0');
SET SESSION AUTHORIZATION liquidateur;
SELECT assert_leve('SELECT liquider(''mallory'', ''WETH'', ''STB'', 5000000000000000000)', 'OBSERVATIONS_INSUFFISANTES',
                   'trou de maintenance : un compte sain n''est pas liquidable');
RESET SESSION AUTHORIZATION;

-- Who is hit while GAP has a gap: an account with a position in GAP raises on emprunter and retirer. Withdrawing the whole GAP
-- deposit passes when the rest covers the debt, deposer and rembourser pass, and an account with no GAP position is untouched.
SELECT frapper('mallory', 'GAP', 1);
SELECT parts_depot AS parts_gap_mallory FROM pret_position WHERE compte = 'mallory' AND jeton = 'GAP' \gset
BEGIN;
SET LOCAL SESSION AUTHORIZATION mallory;
SELECT assert_leve('SELECT emprunter(''WETH'', 1)', 'OBSERVATIONS_INSUFFISANTES', 'trou : emprunter leve pour un detenteur de GAP');
SELECT assert_leve('SELECT retirer(''STB'', 1)', 'OBSERVATIONS_INSUFFISANTES', 'trou : retirer un autre coffre leve pour un detenteur de GAP');
SELECT assert_leve('SELECT retirer(''GAP'', 1)', 'OBSERVATIONS_INSUFFISANTES', 'trou : un retrait partiel de GAP leve');
SELECT assert_passe('SELECT rembourser(''WETH'', 5000000000000000000)', 'trou : rembourser passe');
SELECT assert_passe(format('SELECT retirer(''GAP'', %s)', :'parts_gap_mallory'), 'trou : le retrait de tout le depot GAP passe si le reste couvre la dette');
ROLLBACK;
BEGIN;
SET LOCAL SESSION AUTHORIZATION mallory;
SELECT assert_passe('SELECT deposer(''GAP'', 1)', 'trou : deposer passe');
ROLLBACK;
BEGIN;
SET LOCAL SESSION AUTHORIZATION bob;
SELECT assert_passe('SELECT retirer(''WETH'', 1)', 'trou : un compte sans position dans GAP n''est pas touche');
ROLLBACK;

-- Limit kept on purpose: while a held collateral has a gap in its series, its holder cannot be liquidated.
-- One public observation of an unmaintained pool is enough to create such a gap (README, oracle maintenance).
RESET SESSION AUTHORIZATION;
UPDATE pret_pool SET taux_garantie = 0.4e18 WHERE jeton IN ('GAP', 'STB');
SET SESSION AUTHORIZATION liquidateur;
SELECT assert_leve('SELECT liquider(''mallory'', ''WETH'', ''STB'', 5000000000000000000)', 'OBSERVATIONS_INSUFFISANTES',
                   'trou de maintenance : un compte malsain qui detient le jeton troue n''est pas liquidable');
RESET SESSION AUTHORIZATION;
SELECT avancer_bloc(1);
SELECT observer(4), observer(5);
SET SESSION AUTHORIZATION liquidateur;
SELECT assert_passe('SELECT liquider(''mallory'', ''WETH'', ''STB'', 1000000000000000000)',
                    'maintenance reprise depuis 696 s : la liquidation du compte malsain passe');
RESET SESSION AUTHORIZATION;

-- An observation of an empty pool must not start the window: the cumulated price does not run while a reserve is 0.
INSERT INTO jeton (symbole) VALUES ('DIL');
SELECT frapper('alice', 'DIL', 20000e18);
SELECT creer_pret_pool('DIL');
SELECT creer_pool('DIL', 'WETH') AS pool_dil \gset
SELECT observer(:pool_dil);
SELECT assert_egal(count(*), 0::bigint, 'observer sur un pool vide : aucune observation enregistree') FROM observation WHERE pool_id = :pool_dil;
SELECT avancer_bloc(50);
SET SESSION AUTHORIZATION alice;
SELECT ajouter_liquidite(:pool_dil, 10000e18, 1000e18);
SELECT deposer('DIL', 1000e18);
RESET SESSION AUTHORIZATION;
SELECT avancer_bloc(8);
SET SESSION AUTHORIZATION bob;
SELECT assert_leve('SELECT emprunter(''DIL'', 50000000000000000000)', 'PAS_ENCORE_OBSERVE',
                   'pool vide observe puis rempli : la dette n''est pas evaluee sur un prix dilue');
RESET SESSION AUTHORIZATION;
-- Positive case: observed at every block for 70 blocks (840 s), so the first funded observation has left the window
-- and the price rests on the maintenance alone.
SELECT observer(:pool_dil), set_config('t09.pool_dil', :'pool_dil', false);
DO $$ BEGIN FOR i IN 1..70 LOOP PERFORM avancer_bloc(1); PERFORM observer(current_setting('t09.pool_dil')::int); END LOOP; END $$;
SELECT assert_vrai(0.1e18 - prix_moyen('DIL') BETWEEN 0 AND 1, 'pool maintenu a chaque bloc : prix moyen = prix reel, a 1 wei pres');

-- Cadence: the oldest observation must be 696 to 720 s old, three block positions, so a pool is observed every 3 blocks at most.
INSERT INTO jeton (symbole) VALUES ('CAD3'), ('CAD4');
SELECT frapper('alice', 'CAD3', 1000e18), frapper('alice', 'CAD4', 1000e18);
SELECT creer_pool('CAD3', 'WETH') AS pool_cad3, creer_pool('CAD4', 'WETH') AS pool_cad4 \gset
SELECT assert_egal(:pool_cad3::int, 7, 'CAD3 est le pool 7 (code en dur ci dessous)');
SELECT assert_egal(:pool_cad4::int, 8, 'CAD4 est le pool 8 (code en dur ci dessous)');
SET SESSION AUTHORIZATION alice;
SELECT ajouter_liquidite(7, 1000e18, 100e18), ajouter_liquidite(8, 1000e18, 100e18);
RESET SESSION AUTHORIZATION;
DO $$
DECLARE erreurs3 int := 0; erreurs4 int := 0;
BEGIN
  FOR i IN 1..181 LOOP
    PERFORM avancer_bloc(1);
    IF i % 3 = 0 THEN PERFORM observer(7); END IF;
    IF i % 4 = 0 THEN PERFORM observer(8); END IF;
    IF i > 70 THEN
      BEGIN PERFORM prix_moyen('CAD3'); EXCEPTION WHEN raise_exception THEN erreurs3 := erreurs3 + 1; END;
      BEGIN PERFORM prix_moyen('CAD4'); EXCEPTION WHEN raise_exception THEN erreurs4 := erreurs4 + 1; END;
    END IF;
  END LOOP;
  PERFORM assert_egal(erreurs3, 0, 'pool observe tous les 3 blocs : le prix moyen ne leve jamais sur 111 blocs');
  PERFORM assert_vrai(erreurs4 > 0, format('pool observe tous les 4 blocs : le prix moyen leve (%s fois sur 111 blocs)', erreurs4));
END $$;

