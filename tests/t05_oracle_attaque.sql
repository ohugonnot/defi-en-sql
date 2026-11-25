INSERT INTO jeton (symbole) VALUES ('WETH'), ('FOO'), ('BAR');
SELECT frapper(c, j, 1e30) FROM unnest(ARRAY['alice', 'bob']) c, unnest(ARRAY['WETH', 'FOO', 'BAR']) j;
-- Pool 1 FOO/WETH is deep and funds the attacker. Pool 2 BAR/WETH is thin: BAR costs 0.1 WETH. Fees 0.2 %.
SELECT creer_pool('FOO', 'WETH', 2), creer_pool('BAR', 'WETH', 2);
SELECT creer_pret_pool('WETH'), creer_pret_pool('BAR');
SET SESSION AUTHORIZATION alice;
SELECT ajouter_liquidite(1, 10000e18, 1000e18), ajouter_liquidite(2, 10e18, 1e18);
SET SESSION AUTHORIZATION bob;
SELECT deposer('WETH', 100e18);
RESET SESSION AUTHORIZATION;

-- One observation per block for 60 blocks: the 720 s window is full.
SELECT observer(2);
DO $$
BEGIN
  FOR i IN 1..60 LOOP PERFORM avancer_bloc(1); PERFORM observer(2); END LOOP;
  PERFORM avancer_bloc(1);
END $$;

CREATE FUNCTION attaque() RETURNS void LANGUAGE plpgsql AS $$
DECLARE bar numeric;
BEGIN
  PERFORM flash_swap(1, 0, 99e18);
  bar := echanger(2, 'WETH', 99e18);
  PERFORM deposer('BAR', 0.2e18);
  PERFORM emprunter('WETH', 100e18);
  PERFORM echanger(2, 'BAR', bar - 0.2e18);
  PERFORM transferer(caisse(1), 'WETH', div_haut(99e18 * 1000, 998));
END $$;

SELECT assert_egal(prix_instantane('BAR'), 0.1e18, 'avant l''attaque : BAR vaut 0,1 WETH');
-- UQ112x112 truncates, so the average of a constant price can read one wei low.
SELECT assert_egal(prix_moyen('BAR'), 99999999999999999::numeric, 'avant l''attaque : prix moyen sur 720 s = 0,1 WETH moins 1 wei');
SELECT reserve0 * reserve1 AS k_flash_avant FROM pool WHERE id = 1 \gset

-- Same script, average price: the manipulation weighs 0 s of the window in its own block.
SET SESSION AUTHORIZATION mallory;
\set ON_ERROR_STOP off
SELECT attaque();
\set ON_ERROR_STOP on
SELECT assert_egal(:'LAST_ERROR_MESSAGE', 'ACCOUNT_UNHEALTHY', 'attaque, prix moyen : refusee par ACCOUNT_UNHEALTHY');

-- Limit of the average: the manipulation is held one block, then read at the next block.
RESET SESSION AUTHORIZATION;
SELECT reserve0 AS bar_honnete, reserve1 AS weth_honnete FROM pool WHERE id = 2 \gset
SELECT div(:'weth_honnete'::numeric * 1e18, :'bar_honnete'::numeric) AS spot_honnete \gset
BEGIN;
SET LOCAL SESSION AUTHORIZATION alice;
SELECT echanger(2, 'WETH', 99e18);
RESET SESSION AUTHORIZATION;
SELECT avancer_bloc(1);
SELECT prix_moyen('BAR') AS moyen_bloc_suivant, prix_instantane('BAR') AS spot_bloc_suivant \gset
ROLLBACK;
SELECT div(99e18 * 998 * :'bar_honnete'::numeric, :'weth_honnete'::numeric * 1000 + 99e18 * 998) AS bar_sorti \gset
SELECT div((:'weth_honnete'::numeric + 99e18) * 2::numeric ^ 112, :'bar_honnete'::numeric - :'bar_sorti'::numeric) AS uq_manipule,
       div(:'weth_honnete'::numeric * 2::numeric ^ 112, :'bar_honnete'::numeric) AS uq_honnete \gset
SELECT assert_egal(:'moyen_bloc_suivant'::numeric,
                   div((:'uq_honnete'::numeric * 708 + :'uq_manipule'::numeric * 12) * 1e18, 720 * 2::numeric ^ 112),
                   'limite du prix moyen : (708 s a 0,1 + 12 s au prix manipule) sur 720 s, au wei');
SELECT assert_egal(:'moyen_bloc_suivant'::numeric, 16731999999999999970::numeric, 'limite du prix moyen : valeur lue au bloc suivant');
SELECT assert_egal(:'spot_bloc_suivant'::numeric, 998019999999999998222::numeric, 'limite du prix moyen : prix instantane manipule');
SELECT assert_vrai(:'moyen_bloc_suivant'::numeric > 100 * :'spot_honnete'::numeric,
                   'limite du prix moyen : tenue un bloc, la manipulation passe a travers (plus de 100 fois le vrai prix)');
SELECT assert_vrai(:'moyen_bloc_suivant'::numeric < :'spot_bloc_suivant'::numeric,
                   'limite du prix moyen : le prix moyen reste sous le prix instantane manipule');

-- Same script, instantaneous price: one transaction, accepted, the vault is emptied.
UPDATE config SET oracle = 'instantane';
SELECT solde_de('mallory', 'WETH') AS initial_attaquant \gset
SET SESSION AUTHORIZATION mallory;
BEGIN;
SELECT attaque();
COMMIT;
RESET SESSION AUTHORIZATION;
SELECT assert_egal((SELECT count(*) FROM flash_swap), 1::bigint, 'attaque, prix instantane : COMMIT accepte, flash swap rembourse');
SELECT assert_egal(solde_de('mallory', 'WETH') - :'initial_attaquant'::numeric, 99777142654372389578::numeric, 'attaque, prix instantane : gain exact de l''attaquant, parti de 0');
SELECT assert_egal(solde_de('pret:WETH', 'WETH'), 0::numeric, 'attaque, prix instantane : pool de pret WETH vide');
SELECT assert_vrai(NOT est_sain('mallory'), 'attaque, prix instantane : dette impayee, compte malsain une fois le prix revenu');
SELECT assert_vrai(reserve0 * reserve1 >= :'k_flash_avant'::numeric, 'attaque, prix instantane : K du pool qui a prete >= K d''avant')
  FROM pool WHERE id = 1;
